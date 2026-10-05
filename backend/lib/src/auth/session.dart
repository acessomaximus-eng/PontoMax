import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';

import '../app.dart';
import '../db/database.dart';
import '../http/http_utils.dart';
import 'crypto_utils.dart';

/// Usuário autenticado.
class AuthUser {
  final String id;
  final String name;
  final String email;
  final String? cpf;
  final bool superAdmin;
  const AuthUser(this.id, this.name, this.email, this.cpf, this.superAdmin);
}

/// Contexto do usuário dentro de uma empresa (vínculo ativo).
class MemberContext {
  final AuthUser user;
  final String memberId;
  final String companyId;
  final Role role;
  final Row company;
  final Row member;

  const MemberContext({
    required this.user,
    required this.memberId,
    required this.companyId,
    required this.role,
    required this.company,
    required this.member,
  });

  int get offset => company['utc_offset_minutes'] as int;
  CompanySettings get settings =>
      CompanySettings.fromJson((company['settings'] as Map).cast<String, Object?>());
  bool get isManager => role.isManager;
  bool get isAdmin => role.isAdmin;

  void requireManager() {
    if (!isManager) throw const ApiError.forbidden('Apenas gestores podem realizar esta ação');
  }

  void requireAdmin() {
    if (!isAdmin) throw const ApiError.forbidden('Apenas administradores podem realizar esta ação');
  }

  /// Colaborador pode ver apenas os próprios dados; gestor vê todos.
  void requireSelfOrManager(String memberId) {
    if (memberId != this.memberId && !isManager) throw const ApiError.forbidden();
  }
}

/// Dispositivo (quiosque) autenticado.
class DeviceContext {
  final String deviceId;
  final String companyId;
  final Row device;
  final Row company;
  const DeviceContext(this.deviceId, this.companyId, this.device, this.company);
  int get offset => company['utc_offset_minutes'] as int;
  CompanySettings get settings =>
      CompanySettings.fromJson((company['settings'] as Map).cast<String, Object?>());
}

class SessionService {
  final App app;
  SessionService(this.app);

  String issueAccessToken(String userId) {
    final jwt = JWT({'sub': userId, 'typ': 'access'}, issuer: 'pontomax');
    return jwt.sign(SecretKey(app.config.jwtSecret), expiresIn: app.config.accessTokenTtl);
  }

  Future<String> issueRefreshToken(Db db, String userId, {String? userAgent}) async {
    final token = randomToken(32);
    await db.execute(
      'INSERT INTO refresh_tokens (user_id, token_hash, expires_at, user_agent) '
      'VALUES (@u, @h, @e, @ua)',
      {
        'u': userId,
        'h': sha256Hex(token),
        'e': app.now().add(app.config.refreshTokenTtl),
        'ua': userAgent,
      },
    );
    return token;
  }

  /// Valida o token de acesso e retorna o usuário.
  Future<AuthUser> authenticate(Request req) async {
    final cached = req.context['pontomax.user'];
    if (cached is AuthUser) return cached;
    final header = req.headers['authorization'] ?? '';
    String? token;
    if (header.startsWith('Bearer ')) token = header.substring(7).trim();
    token ??= req.url.queryParameters['access_token'];
    if (token == null || token.isEmpty) throw const ApiError.unauthorized();
    String userId;
    try {
      final jwt = JWT.verify(token, SecretKey(app.config.jwtSecret), issuer: 'pontomax');
      final payload = jwt.payload as Map;
      if (payload['typ'] != 'access') throw const ApiError.unauthorized();
      userId = payload['sub'] as String;
    } on JWTExpiredException {
      throw const ApiError(401, 'token_expired', 'Sessão expirada');
    } on JWTException {
      throw const ApiError.unauthorized('Token inválido');
    }
    final row = await app.db.one(
      'SELECT id, name, email, cpf, super_admin FROM users WHERE id = @id',
      {'id': userId},
    );
    if (row == null) throw const ApiError.unauthorized();
    return AuthUser(row['id'] as String, row['name'] as String, row['email'] as String,
        row['cpf'] as String?, row['super_admin'] as bool);
  }

  /// Resolve o vínculo ativo pelo cabeçalho `X-Company-Id` (ou o primeiro).
  Future<MemberContext> member(Request req) async {
    final user = await authenticate(req);
    final companyId = req.headers['x-company-id'] ?? req.url.queryParameters['company_id'];
    final row = await app.db.one(
      '''
      SELECT m.*, row_to_json(c.*)::jsonb AS company_json
      FROM members m JOIN companies c ON c.id = m.company_id
      WHERE m.user_id = @u AND m.active
        AND (@c::uuid IS NULL OR m.company_id = @c::uuid)
      ORDER BY m.created_at
      LIMIT 1''',
      {'u': user.id, 'c': optUuid(companyId, 'company_id')},
    );
    if (row == null) {
      throw const ApiError(403, 'no_membership', 'Você não possui vínculo ativo com esta empresa');
    }
    final company = (row.remove('company_json') as Map).cast<String, dynamic>();
    return MemberContext(
      user: user,
      memberId: row['id'] as String,
      companyId: row['company_id'] as String,
      role: Role.fromCode(row['role'] as String),
      company: company,
      member: row,
    );
  }

  Future<DeviceContext> device(Request req) async {
    final header = req.headers['authorization'] ?? '';
    if (!header.startsWith('Device ')) throw const ApiError.unauthorized('Dispositivo não autenticado');
    final token = header.substring(7).trim();
    final row = await app.db.one(
      '''
      SELECT d.*, row_to_json(c.*)::jsonb AS company_json
      FROM devices d JOIN companies c ON c.id = d.company_id
      WHERE d.token_hash = @h AND d.active''',
      {'h': sha256Hex(token)},
    );
    if (row == null) throw const ApiError.unauthorized('Dispositivo inválido ou desativado');
    final company = (row.remove('company_json') as Map).cast<String, dynamic>();
    await app.db.execute('UPDATE devices SET last_seen_at = now() WHERE id = @id', {'id': row['id']});
    return DeviceContext(row['id'] as String, row['company_id'] as String, row, company);
  }
}
