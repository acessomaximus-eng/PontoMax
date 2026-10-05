import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/crypto_utils.dart';
import '../db/database.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';
import 'auth_routes.dart';

/// Cadastro de colaboradores (vínculos).
class MemberRoutes {
  final App app;
  MemberRoutes(this.app);
  Mappers get map => Mappers(app);

  Router get router => Router()
    ..get('/members', _list)
    ..get('/members/<id>', _get)
    ..post('/members', _create)
    ..put('/members/<id>', _update)
    ..post('/members/<id>/dismiss', _dismiss)
    ..post('/members/<id>/reactivate', _reactivate)
    ..post('/members/<id>/reset-password', _resetPassword)
    ..put('/members/<id>/pin', _setPin);

  Future<Response> _list(Request req) async {
    final ctx = await app.sessions.member(req);
    final search = req.q('q');
    final status = req.q('status') ?? 'active';
    final rows = await app.db.query(
      '''
      $memberSelectSql
      WHERE m.company_id = @c
        AND (@status = 'all' OR (@status = 'active' AND m.active) OR (@status = 'inactive' AND NOT m.active))
        AND (@q::text IS NULL OR u.name ILIKE '%' || @q::text || '%' OR u.email ILIKE '%' || @q::text || '%'
             OR u.cpf LIKE '%' || @q::text || '%' OR m.registration ILIKE '%' || @q::text || '%')
        AND (@d::uuid IS NULL OR m.department_id = @d::uuid)
        AND (@isManager OR m.id = @self OR m.role <> 'employee')
      ORDER BY u.name''',
      {
        'c': ctx.companyId,
        'status': status,
        'q': search,
        'd': optUuid(req.q('department_id'), 'department_id'),
        'isManager': ctx.isManager,
        'self': ctx.memberId,
      },
    );
    final list = [for (final r in rows) map.member(r)];
    if (!ctx.isManager) {
      // Colaboradores veem apenas nome/foto dos gestores (para o chat).
      return jsonResponse([
        for (final m in list)
          if (m['id'] == ctx.memberId) m else {'id': m['id'], 'name': m['name'], 'role': m['role'], 'photo_url': m['photo_url']},
      ]);
    }
    return jsonResponse(list);
  }

  Future<Row> _load(String companyId, String id) async {
    final row = await app.db.one('$memberSelectSql WHERE m.id = @id AND m.company_id = @c',
        {'id': requireUuid(id), 'c': companyId});
    if (row == null) throw const ApiError.notFound('Colaborador não encontrado');
    return row;
  }

  Future<Response> _get(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireSelfOrManager(id);
    return jsonResponse(map.member(await _load(ctx.companyId, id)));
  }

  Future<Response> _create(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final name = body.str('name', label: 'nome');
    final email = body.str('email', label: 'e-mail').toLowerCase();
    if (!Documents.isValidEmail(email)) throw const ApiError.badRequest('E-mail inválido');
    final cpf = Documents.onlyDigits(body.optStr('cpf'));
    if (cpf.isEmpty) throw const ApiError.badRequest('CPF é obrigatório (exigido pela Portaria 671)');
    if (!Documents.isValidCpf(cpf)) throw const ApiError.badRequest('CPF inválido');
    final role = Role.fromCode(body.optStr('role') ?? 'employee');
    if (role.isAdmin && !ctx.isAdmin) throw const ApiError.forbidden('Somente administradores podem criar administradores');
    var password = body.optStr('password');
    if (password != null) AuthRoutes.validatePassword(password);
    final generatedPassword = password == null;
    password ??= temporaryPassword();

    var newUser = false;
    final row = await app.db.tx((tx) async {
      var user = await tx.one('SELECT * FROM users WHERE lower(email) = @e', {'e': email});
      final cpfOwner = await tx.one('SELECT id FROM users WHERE cpf = @cpf', {'cpf': cpf});
      if (cpfOwner != null && cpfOwner['id'] != user?['id']) {
        throw const ApiError.conflict('Este CPF já está vinculado a outro usuário');
      }
      if (user == null) {
        user = await tx.one(
          'INSERT INTO users (name, email, cpf, phone, password_hash) VALUES (@n, @e, @cpf, @ph, @p) RETURNING *',
          {'n': name, 'e': email, 'cpf': cpf, 'ph': body.optStr('phone'), 'p': app.passwords.hash(password!)},
        );
        newUser = true;
      } else {
        final dup = await tx.one('SELECT id FROM members WHERE company_id = @c AND user_id = @u',
            {'c': ctx.companyId, 'u': user['id']});
        if (dup != null) throw const ApiError.conflict('Este usuário já é colaborador da empresa');
        if (user['cpf'] == null) {
          await tx.execute('UPDATE users SET cpf = @cpf WHERE id = @id', {'cpf': cpf, 'id': user['id']});
        }
      }
      final pin = body.optStr('pin');
      if (pin != null && !RegExp(r'^\d{4,6}$').hasMatch(pin)) throw const ApiError.badRequest('PIN deve ter 4 a 6 dígitos');
      final member = await tx.one(
        '''
        INSERT INTO members (company_id, user_id, role, registration, department_id, position_id, schedule_id,
          manager_id, admission_date, badge_code, allow_anywhere, esocial_registration, initial_bank_minutes, pin_hash)
        VALUES (@c, @u, @role, @reg, @dep, @pos, @sch, @mgr, @adm, @badge, @any, @esocial, @bank, @pin)
        RETURNING id''',
        {
          'c': ctx.companyId,
          'u': user!['id'],
          'role': role.code,
          'reg': body.optStr('registration'),
          'dep': optUuid(body.optStr('department_id'), 'department_id'),
          'pos': optUuid(body.optStr('position_id'), 'position_id'),
          'sch': optUuid(body.optStr('schedule_id'), 'schedule_id'),
          'mgr': optUuid(body.optStr('manager_id'), 'manager_id'),
          'adm': (body.optDate('admission_date') ?? LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset))).toString(),
          'badge': body.optStr('badge_code'),
          'any': body.optBool('allow_anywhere') ?? false,
          'esocial': body.optStr('esocial_registration'),
          'bank': body.optInt('initial_bank_minutes') ?? 0,
          'pin': pin == null ? null : app.passwords.hash(pin),
        },
      );
      final memberId = member!['id'] as String;
      await _setGeofences(tx, memberId, ctx.companyId, body);
      await app.punches.employeeEvent(
        db: tx,
        companyId: ctx.companyId,
        memberId: memberId,
        operation: 'I',
        cpf: cpf,
        name: name,
        responsibleCpf: ctx.user.cpf,
      );
      await app.audit.log(
        db: tx,
        companyId: ctx.companyId,
        userId: ctx.user.id,
        action: 'create',
        entity: 'member',
        entityId: memberId,
        data: {...body, 'new_user': newUser},
        ip: req.clientIp,
      );
      return (await tx.one('$memberSelectSql WHERE m.id = @id', {'id': memberId}))!;
    });

    // Usuário já existente (outra empresa) mantém a própria senha.
    final showPassword = generatedPassword && newUser;
    final companyName = ctx.company['name'];
    await app.mailer.send(
      to: email,
      subject: 'Você foi convidado para o PontoMax — $companyName',
      text: 'Olá, $name!\n\n$companyName cadastrou você no PontoMax para registro de ponto.\n'
          'Acesse ${app.config.publicUrl}/app e entre com o e-mail $email'
          '${showPassword ? ' e a senha provisória: $password' : newUser ? '' : ' e a sua senha atual'}.\n\n'
          'Baixe também o aplicativo PontoMax no seu celular.',
    );
    app.webhooks.dispatch(ctx.companyId, 'member.created', map.member(row));
    return created({
      ...map.member(row),
      if (showPassword) 'temporary_password': password,
      'existing_user': !newUser,
    });
  }

  Future<void> _setGeofences(Db tx, String memberId, String companyId, Map<String, dynamic> body) async {
    if (!body.containsKey('geofence_ids')) return;
    await tx.execute('DELETE FROM member_geofences WHERE member_id = @m', {'m': memberId});
    for (final g in body.strList('geofence_ids')) {
      final ok = await tx.one('SELECT id FROM geofences WHERE id = @g AND company_id = @c',
          {'g': requireUuid(g, 'geofence_ids'), 'c': companyId});
      if (ok == null) throw const ApiError.badRequest('Perímetro inválido');
      await tx.execute('INSERT INTO member_geofences (member_id, geofence_id) VALUES (@m, @g)', {'m': memberId, 'g': g});
    }
  }

  Future<Response> _update(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final current = await _load(ctx.companyId, id);
    final newRole = body.optStr('role') == null ? null : Role.fromCode(body.optStr('role'));
    final currentRole = Role.fromCode(current['role'] as String);
    if ((newRole?.isAdmin ?? false) || currentRole.isAdmin) {
      if (!ctx.isAdmin) throw const ApiError.forbidden('Somente administradores podem alterar administradores');
    }
    if (currentRole == Role.owner && newRole != null && newRole != Role.owner) {
      final owners = await app.db.one(
          "SELECT count(*)::int AS n FROM members WHERE company_id = @c AND role = 'owner' AND active", {'c': ctx.companyId});
      if ((owners!['n'] as int) <= 1) throw const ApiError.conflict('A empresa precisa de ao menos um proprietário');
    }
    final cpf = body.containsKey('cpf') ? Documents.onlyDigits(body.optStr('cpf')) : null;
    if (cpf != null && cpf.isNotEmpty && !Documents.isValidCpf(cpf)) throw const ApiError.badRequest('CPF inválido');
    final email = body.optStr('email')?.toLowerCase();
    if (email != null && !Documents.isValidEmail(email)) throw const ApiError.badRequest('E-mail inválido');

    bool has(String k) => body.containsKey(k);
    final row = await app.db.tx((tx) async {
      try {
        await tx.execute(
          '''
          UPDATE users SET name = COALESCE(@n, name), email = COALESCE(@e, email),
            cpf = COALESCE(@cpf, cpf), phone = CASE WHEN @hasPhone THEN @ph ELSE phone END, updated_at = now()
          WHERE id = @u''',
          {
            'u': current['user_id'],
            'n': body.optStr('name'),
            'e': email,
            'cpf': (cpf?.isEmpty ?? true) ? null : cpf,
            'hasPhone': has('phone'),
            'ph': body.optStr('phone'),
          },
        );
      } on Exception catch (e) {
        if (e.toString().contains('23505')) throw const ApiError.conflict('E-mail ou CPF já cadastrado para outro usuário');
        rethrow;
      }
      await tx.execute(
        '''
        UPDATE members SET
          role = COALESCE(@role, role),
          registration = CASE WHEN @hasReg THEN @reg ELSE registration END,
          department_id = CASE WHEN @hasDep THEN @dep::uuid ELSE department_id END,
          position_id = CASE WHEN @hasPos THEN @pos::uuid ELSE position_id END,
          schedule_id = CASE WHEN @hasSch THEN @sch::uuid ELSE schedule_id END,
          manager_id = CASE WHEN @hasMgr THEN @mgr::uuid ELSE manager_id END,
          admission_date = COALESCE(@adm::date, admission_date),
          badge_code = CASE WHEN @hasBadge THEN @badge ELSE badge_code END,
          allow_anywhere = COALESCE(@any, allow_anywhere),
          esocial_registration = CASE WHEN @hasEsocial THEN @esocial ELSE esocial_registration END,
          initial_bank_minutes = COALESCE(@bank, initial_bank_minutes),
          photo_url = CASE WHEN @hasPhoto THEN @photo ELSE photo_url END,
          updated_at = now()
        WHERE id = @id''',
        {
          'id': id,
          'role': newRole?.code,
          'hasReg': has('registration'),
          'reg': body.optStr('registration'),
          'hasDep': has('department_id'),
          'dep': optUuid(body.optStr('department_id'), 'department_id'),
          'hasPos': has('position_id'),
          'pos': optUuid(body.optStr('position_id'), 'position_id'),
          'hasSch': has('schedule_id'),
          'sch': optUuid(body.optStr('schedule_id'), 'schedule_id'),
          'hasMgr': has('manager_id'),
          'mgr': optUuid(body.optStr('manager_id'), 'manager_id'),
          'adm': body.optDate('admission_date')?.toString(),
          'hasBadge': has('badge_code'),
          'badge': body.optStr('badge_code'),
          'any': body.optBool('allow_anywhere'),
          'hasEsocial': has('esocial_registration'),
          'esocial': body.optStr('esocial_registration'),
          'bank': body.optInt('initial_bank_minutes'),
          'hasPhoto': has('photo_url'),
          'photo': body.optStr('photo_url'),
        },
      );
      await _setGeofences(tx, id, ctx.companyId, body);
      if (has('name') || has('cpf')) {
        final u = await tx.one('SELECT name, cpf FROM users WHERE id = @u', {'u': current['user_id']});
        await app.punches.employeeEvent(
          db: tx,
          companyId: ctx.companyId,
          memberId: id,
          operation: 'A',
          cpf: u!['cpf'] as String?,
          name: u['name'] as String,
          responsibleCpf: ctx.user.cpf,
        );
      }
      await app.audit.log(
        db: tx,
        companyId: ctx.companyId,
        userId: ctx.user.id,
        action: 'update',
        entity: 'member',
        entityId: id,
        data: body,
        ip: req.clientIp,
      );
      return (await tx.one('$memberSelectSql WHERE m.id = @id', {'id': id}))!;
    });
    return jsonResponse(map.member(row));
  }

  Future<Response> _dismiss(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    if (id == ctx.memberId) throw const ApiError.conflict('Você não pode desligar a si mesmo');
    final body = await readJson(req);
    final current = await _load(ctx.companyId, id);
    if (Role.fromCode(current['role'] as String).isAdmin && !ctx.isAdmin) throw const ApiError.forbidden();
    final date = body.optDate('dismissal_date') ?? LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset));
    await app.db.tx((tx) async {
      await tx.execute('UPDATE members SET active = false, dismissal_date = @d, updated_at = now() WHERE id = @id',
          {'d': date.toString(), 'id': id});
      await app.punches.employeeEvent(
        db: tx,
        companyId: ctx.companyId,
        memberId: id,
        operation: 'E',
        cpf: current['cpf'] as String?,
        name: current['name'] as String,
        responsibleCpf: ctx.user.cpf,
      );
      await app.audit.log(
          db: tx, companyId: ctx.companyId, userId: ctx.user.id, action: 'dismiss', entity: 'member', entityId: id, data: body);
    });
    final dismissed = map.member(await _load(ctx.companyId, id));
    app.webhooks.dispatch(ctx.companyId, 'member.dismissed', dismissed);
    return jsonResponse(dismissed);
  }

  Future<Response> _reactivate(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final current = await _load(ctx.companyId, id);
    await app.db.tx((tx) async {
      await tx.execute('UPDATE members SET active = true, dismissal_date = NULL, updated_at = now() WHERE id = @id', {'id': id});
      await app.punches.employeeEvent(
        db: tx,
        companyId: ctx.companyId,
        memberId: id,
        operation: 'I',
        cpf: current['cpf'] as String?,
        name: current['name'] as String,
        responsibleCpf: ctx.user.cpf,
      );
      await app.audit.log(db: tx, companyId: ctx.companyId, userId: ctx.user.id, action: 'reactivate', entity: 'member', entityId: id);
    });
    return jsonResponse(map.member(await _load(ctx.companyId, id)));
  }

  Future<Response> _resetPassword(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final current = await _load(ctx.companyId, id);
    if (Role.fromCode(current['role'] as String).isAdmin && !ctx.isAdmin) throw const ApiError.forbidden();
    final password = temporaryPassword();
    await app.db.execute('UPDATE users SET password_hash = @p, updated_at = now() WHERE id = @u',
        {'p': app.passwords.hash(password), 'u': current['user_id']});
    await app.db.execute('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = @u AND revoked_at IS NULL',
        {'u': current['user_id']});
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'reset_password', entity: 'member', entityId: id);
    return jsonResponse({'temporary_password': password});
  }

  Future<Response> _setPin(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    await _load(ctx.companyId, id);
    final body = await readJson(req);
    final pin = body.str('pin');
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) throw const ApiError.badRequest('O PIN deve ter de 4 a 6 dígitos');
    await app.db.execute('UPDATE members SET pin_hash = @p WHERE id = @id', {'p': app.passwords.hash(pin), 'id': id});
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'set_pin', entity: 'member', entityId: id);
    return jsonResponse({'ok': true});
  }
}
