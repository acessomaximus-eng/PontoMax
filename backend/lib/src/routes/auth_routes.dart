import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/crypto_utils.dart';
import '../auth/session.dart';
import '../db/database.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';

/// Limita tentativas de login por IP+e-mail.
class _RateLimiter {
  final int max;
  final Duration window;
  final _hits = <String, List<DateTime>>{};
  _RateLimiter(this.max, this.window);

  void check(String key, DateTime now) {
    final list = _hits.putIfAbsent(key, () => [])..removeWhere((t) => now.difference(t) > window);
    if (list.length >= max) {
      throw const ApiError(429, 'too_many_requests', 'Muitas tentativas. Aguarde um minuto e tente novamente.');
    }
    list.add(now);
    if (_hits.length > 10000) _hits.clear();
  }

  void reset(String key) => _hits.remove(key);
}

class AuthRoutes {
  final App app;
  final _limiter = _RateLimiter(8, const Duration(minutes: 1));
  AuthRoutes(this.app);

  Mappers get map => Mappers(app);

  Router get router => Router()
    ..post('/auth/register', _register)
    ..post('/auth/login', _login)
    ..post('/auth/refresh', _refresh)
    ..post('/auth/logout', _logout)
    ..post('/auth/forgot', _forgot)
    ..post('/auth/reset', _reset)
    ..get('/me', _me)
    ..put('/me', _updateMe)
    ..put('/me/password', _changePassword)
    ..put('/me/pin', _setPin);

  /// Cria empresa + usuário proprietário (onboarding / teste grátis).
  Future<Response> _register(Request req) async {
    final body = await readJson(req);
    final companyName = body.str('company_name', label: 'nome da empresa');
    final name = body.str('name', label: 'seu nome');
    final email = body.str('email', label: 'e-mail').toLowerCase();
    final password = body.str('password', label: 'senha');
    final document = Documents.onlyAlnum(body.optStr('document'));
    final cpf = Documents.onlyDigits(body.optStr('cpf'));
    if (!Documents.isValidEmail(email)) throw const ApiError.badRequest('E-mail inválido');
    _validatePassword(password);
    if (document.isNotEmpty && !Documents.isValidCnpj(document) && !Documents.isValidCpf(document)) {
      throw const ApiError.badRequest('CNPJ/CPF da empresa inválido');
    }
    if (cpf.isNotEmpty && !Documents.isValidCpf(cpf)) throw const ApiError.badRequest('CPF inválido');

    final exists = await app.db.one('SELECT id FROM users WHERE lower(email) = @e', {'e': email});
    if (exists != null) throw const ApiError.conflict('Já existe uma conta com este e-mail');

    final result = await app.db.tx((tx) async {
      final user = (await tx.one(
        'INSERT INTO users (name, email, cpf, phone, password_hash) VALUES (@n, @e, @cpf, @ph, @p) RETURNING *',
        {
          'n': name,
          'e': email,
          'cpf': cpf.isEmpty ? null : cpf,
          'ph': body.optStr('phone'),
          'p': app.passwords.hash(password),
        },
      ))!;
      final company = await createCompany(tx, {
        'name': companyName,
        'document': document,
        'document_type': document.length == 11 ? '2' : '1',
      });
      final member = (await tx.one(
        "INSERT INTO members (company_id, user_id, role, admission_date) VALUES (@c, @u, 'owner', @d) RETURNING id",
        {'c': company['id'], 'u': user['id'], 'd': LocalDate.fromDateTime(app.now()).toString()},
      ))!;
      await app.punches.employerEvent(db: tx, companyId: company['id'] as String, responsibleCpf: cpf);
      await app.punches.employeeEvent(
        db: tx,
        companyId: company['id'] as String,
        memberId: member['id'] as String,
        operation: 'I',
        cpf: cpf,
        name: name,
        responsibleCpf: cpf,
      );
      await app.audit.log(
        db: tx,
        companyId: company['id'] as String,
        userId: user['id'] as String,
        action: 'create',
        entity: 'company',
        entityId: company['id'] as String,
        data: {'name': companyName},
        ip: req.clientIp,
      );
      return user;
    });
    return created(await _sessionPayload(result, req));
  }

  /// Cria a empresa com escala padrão e feriados nacionais.
  static Future<Row> createCompany(Db tx, Map<String, Object?> data) async {
    final company = (await tx.one(
      '''
      INSERT INTO companies (name, legal_name, document_type, document, settings)
      VALUES (@n, @ln, @dt, @d, @s) RETURNING *''',
      {
        'n': data['name'],
        'ln': data['legal_name'] ?? data['name'],
        'dt': data['document_type'] ?? '1',
        'd': data['document'] ?? '',
        's': const CompanySettings().toJson(),
      },
    ))!;
    final schedule = ScheduleDefinition.standard44(name: 'Comercial 44h (seg-sex)');
    final sched = (await tx.one(
      'INSERT INTO schedules (company_id, name, definition) VALUES (@c, @n, @d) RETURNING id',
      {'c': company['id'], 'n': schedule.name, 'd': schedule.toJson()},
    ))!;
    await tx.execute(
      "UPDATE companies SET settings = settings || jsonb_build_object('default_schedule_id', @s::text) WHERE id = @c",
      {'s': sched['id'], 'c': company['id']},
    );
    final year = DateTime.now().year;
    for (final y in [year, year + 1]) {
      for (final h in BrazilHolidays.national(y)) {
        await tx.execute(
          "INSERT INTO holidays (company_id, date, name, scope) VALUES (@c, @d, @n, 'national')",
          {'c': company['id'], 'd': h.date.toString(), 'n': h.name},
        );
      }
    }
    return company;
  }

  Future<Response> _login(Request req) async {
    final body = await readJson(req);
    final email = body.str('email', label: 'e-mail').toLowerCase();
    final password = body.str('password', label: 'senha');
    final key = '${req.clientIp}|$email';
    _limiter.check(key, app.now());
    final user = await app.db.one('SELECT * FROM users WHERE lower(email) = @e', {'e': email});
    if (user == null || !app.passwords.verify(password, user['password_hash'] as String?)) {
      throw const ApiError(401, 'invalid_credentials', 'E-mail ou senha incorretos');
    }
    _limiter.reset(key);
    await app.db.execute('UPDATE users SET last_login_at = now() WHERE id = @id', {'id': user['id']});
    return jsonResponse(await _sessionPayload(user, req));
  }

  Future<Map<String, Object?>> _sessionPayload(Row user, Request req) async {
    final refresh = await app.sessions.issueRefreshToken(app.db, user['id'] as String,
        userAgent: req.headers['user-agent']);
    return {
      'access_token': app.sessions.issueAccessToken(user['id'] as String),
      'refresh_token': refresh,
      'expires_in': app.config.accessTokenTtl.inSeconds,
      'user': map.user(user),
      'memberships': await _memberships(user['id'] as String),
    };
  }

  Future<List<Map<String, Object?>>> _memberships(String userId) async {
    final rows = await app.db.query(
      '''
      SELECT m.id AS member_id, m.company_id, c.name AS company_name, m.role
      FROM members m JOIN companies c ON c.id = m.company_id
      WHERE m.user_id = @u AND m.active ORDER BY c.name''',
      {'u': userId},
    );
    return [
      for (final r in rows)
        Membership(
          memberId: r['member_id'] as String,
          companyId: r['company_id'] as String,
          companyName: r['company_name'] as String,
          role: Role.fromCode(r['role'] as String),
        ).toJson(),
    ];
  }

  Future<Response> _refresh(Request req) async {
    final body = await readJson(req);
    final token = body.str('refresh_token');
    final row = await app.db.one(
      'SELECT * FROM refresh_tokens WHERE token_hash = @h AND revoked_at IS NULL AND expires_at > @now',
      {'h': sha256Hex(token), 'now': app.now()},
    );
    if (row == null) throw const ApiError(401, 'invalid_refresh', 'Sessão expirada. Entre novamente.');
    // Rotação: o token antigo é revogado.
    await app.db.execute('UPDATE refresh_tokens SET revoked_at = now() WHERE id = @id', {'id': row['id']});
    final user = await app.db.one('SELECT * FROM users WHERE id = @id', {'id': row['user_id']});
    if (user == null) throw const ApiError.unauthorized();
    return jsonResponse(await _sessionPayload(user, req));
  }

  Future<Response> _logout(Request req) async {
    final body = await readJson(req);
    final token = body.optStr('refresh_token');
    if (token != null) {
      await app.db.execute('UPDATE refresh_tokens SET revoked_at = now() WHERE token_hash = @h', {'h': sha256Hex(token)});
    }
    return noContent();
  }

  Future<Response> _forgot(Request req) async {
    final body = await readJson(req);
    final email = body.str('email').toLowerCase();
    _limiter.check('forgot|${req.clientIp}', app.now());
    final user = await app.db.one('SELECT id, name, email FROM users WHERE lower(email) = @e', {'e': email});
    if (user != null) {
      final token = randomToken(24);
      await app.db.execute(
        'INSERT INTO password_resets (user_id, token_hash, expires_at) VALUES (@u, @h, @e)',
        {'u': user['id'], 'h': sha256Hex(token), 'e': app.now().add(const Duration(hours: 2))},
      );
      await app.mailer.send(
        to: user['email'] as String,
        subject: 'PontoMax — redefinição de senha',
        text: 'Olá, ${user['name']}!\n\n'
            'Para redefinir sua senha, acesse:\n${app.config.publicUrl}/app/#/reset?token=$token\n\n'
            'O link expira em 2 horas. Se você não solicitou, ignore este e-mail.',
      );
    }
    // Resposta idêntica para não revelar se o e-mail existe.
    return jsonResponse({'ok': true});
  }

  Future<Response> _reset(Request req) async {
    final body = await readJson(req);
    final token = body.str('token');
    final password = body.str('password', label: 'nova senha');
    _validatePassword(password);
    final row = await app.db.one(
      'SELECT * FROM password_resets WHERE token_hash = @h AND used_at IS NULL AND expires_at > @now',
      {'h': sha256Hex(token), 'now': app.now()},
    );
    if (row == null) throw const ApiError.badRequest('Link inválido ou expirado');
    await app.db.tx((tx) async {
      await tx.execute('UPDATE password_resets SET used_at = now() WHERE id = @id', {'id': row['id']});
      await tx.execute('UPDATE users SET password_hash = @p, updated_at = now() WHERE id = @u',
          {'p': app.passwords.hash(password), 'u': row['user_id']});
      await tx.execute('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = @u AND revoked_at IS NULL',
          {'u': row['user_id']});
    });
    return jsonResponse({'ok': true});
  }

  Future<Response> _me(Request req) async {
    final user = await app.sessions.authenticate(req);
    final userRow = (await app.db.one('SELECT * FROM users WHERE id = @id', {'id': user.id}))!;
    MemberContext? ctx;
    try {
      ctx = await app.sessions.member(req);
    } on ApiError catch (e) {
      if (e.code != 'no_membership') rethrow;
    }
    Map<String, Object?>? member;
    Map<String, Object?>? company;
    var unreadNotifications = 0, unreadMessages = 0, pendingRequests = 0;
    if (ctx != null) {
      final m = await app.db.one('$memberSelectSql WHERE m.id = @id', {'id': ctx.memberId});
      member = map.member(m!);
      company = map.company(ctx.company);
      unreadNotifications = (await app.db.one(
        'SELECT count(*)::int AS n FROM notifications WHERE member_id = @m AND read_at IS NULL',
        {'m': ctx.memberId},
      ))!['n'] as int;
      unreadMessages = (await app.db.one(
        'SELECT count(*)::int AS n FROM messages WHERE to_member_id = @m AND read_at IS NULL',
        {'m': ctx.memberId},
      ))!['n'] as int;
      if (ctx.isManager) {
        pendingRequests = (await app.db.one(
          "SELECT count(*)::int AS n FROM requests WHERE company_id = @c AND status = 'pending'",
          {'c': ctx.companyId},
        ))!['n'] as int;
      }
    }
    return jsonResponse({
      'user': map.user(userRow),
      'memberships': await _memberships(user.id),
      'member': member,
      'company': company,
      'unread_notifications': unreadNotifications,
      'unread_messages': unreadMessages,
      'pending_requests': pendingRequests,
      'server_time': app.now().toIso8601String(),
    });
  }

  Future<Response> _updateMe(Request req) async {
    final user = await app.sessions.authenticate(req);
    final body = await readJson(req);
    final cpf = body.containsKey('cpf') ? Documents.onlyDigits(body.optStr('cpf')) : null;
    if (cpf != null && cpf.isNotEmpty && !Documents.isValidCpf(cpf)) {
      throw const ApiError.badRequest('CPF inválido');
    }
    final row = await app.db.one(
      '''
      UPDATE users SET
        name = COALESCE(@n, name),
        phone = CASE WHEN @hasPhone THEN @ph ELSE phone END,
        cpf = CASE WHEN @hasCpf AND (cpf IS NULL OR cpf = '') THEN @cpf ELSE cpf END,
        avatar_url = CASE WHEN @hasAvatar THEN @av ELSE avatar_url END,
        updated_at = now()
      WHERE id = @id RETURNING *''',
      {
        'id': user.id,
        'n': body.optStr('name'),
        'hasPhone': body.containsKey('phone'),
        'ph': body.optStr('phone'),
        'hasCpf': cpf != null && cpf.isNotEmpty,
        'cpf': cpf,
        'hasAvatar': body.containsKey('avatar_url'),
        'av': body.optStr('avatar_url'),
      },
    );
    return jsonResponse(map.user(row!));
  }

  Future<Response> _changePassword(Request req) async {
    final user = await app.sessions.authenticate(req);
    final body = await readJson(req);
    final current = body.str('current_password', label: 'senha atual');
    final next = body.str('new_password', label: 'nova senha');
    _validatePassword(next);
    final row = await app.db.one('SELECT password_hash FROM users WHERE id = @id', {'id': user.id});
    if (!app.passwords.verify(current, row?['password_hash'] as String?)) {
      throw const ApiError.badRequest('Senha atual incorreta');
    }
    await app.db.execute('UPDATE users SET password_hash = @p, updated_at = now() WHERE id = @id',
        {'p': app.passwords.hash(next), 'id': user.id});
    return jsonResponse({'ok': true});
  }

  Future<Response> _setPin(Request req) async {
    final ctx = await app.sessions.member(req);
    final body = await readJson(req);
    final pin = body.str('pin');
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) throw const ApiError.badRequest('O PIN deve ter de 4 a 6 dígitos');
    await app.db.execute('UPDATE members SET pin_hash = @p, updated_at = now() WHERE id = @id',
        {'p': app.passwords.hash(pin), 'id': ctx.memberId});
    return jsonResponse({'ok': true});
  }

  static void _validatePassword(String password) {
    if (password.length < 8) throw const ApiError.badRequest('A senha deve ter pelo menos 8 caracteres');
    if (!RegExp(r'[A-Za-z]').hasMatch(password) || !RegExp(r'\d').hasMatch(password)) {
      throw const ApiError.badRequest('A senha deve conter letras e números');
    }
  }

  static void validatePassword(String password) => _validatePassword(password);
}
