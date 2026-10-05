import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/crypto_utils.dart';
import '../db/database.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';
import '../http/rate_limiter.dart';
import '../services/punch_service.dart';
import 'punch_routes.dart';

/// Modo quiosque/tablet: vários colaboradores marcam no mesmo aparelho
/// (PIN, crachá, QR Code pessoal) e o aparelho exibe QR dinâmico para
/// marcação pelo celular do colaborador.
class KioskRoutes {
  final App app;

  /// Bloqueia força bruta de PIN: 5 erros por colaborador/dispositivo a cada 10 min.
  final _pinLimiter = RateLimiter(5, const Duration(minutes: 10),
      message: 'Muitas tentativas de PIN. Aguarde 10 minutos ou procure o gestor.');
  KioskRoutes(this.app);
  Mappers get map => Mappers(app);

  Router get router => Router()
    ..post('/kiosk/activate', _activate)
    ..get('/kiosk/me', _me)
    ..get('/kiosk/qr', _qr)
    ..get('/kiosk/members', _members)
    ..post('/kiosk/identify', _identify)
    ..post('/kiosk/punch', _punch)
    ..post('/kiosk/upload', _upload);

  Future<Response> _activate(Request req) async {
    final body = await readJson(req);
    final code = body.str('code', label: 'código de ativação').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final token = randomToken(32);
    final row = await app.db.one(
      '''
      UPDATE devices SET token_hash = @h, activation_code = NULL, activation_expires_at = NULL,
        platform = @p, last_seen_at = now()
      WHERE activation_code = @code AND activation_expires_at > @now AND active
      RETURNING id, company_id''',
      {'h': sha256Hex(token), 'p': body.optStr('platform'), 'code': code, 'now': app.now()},
    );
    if (row == null) throw const ApiError(404, 'invalid_code', 'Código de ativação inválido ou expirado');
    await app.audit.log(companyId: row['company_id'] as String, userId: null, action: 'activate', entity: 'device',
        entityId: row['id'] as String, ip: req.clientIp);
    final info = await _info(row['id'] as String);
    return jsonResponse({'device_token': token, ...info});
  }

  Future<Map<String, Object?>> _info(String deviceId) async {
    final d = await app.db.one(
      'SELECT d.*, g.name AS geofence_name FROM devices d LEFT JOIN geofences g ON g.id = d.geofence_id WHERE d.id = @id',
      {'id': deviceId},
    );
    final c = await app.db.one('SELECT * FROM companies WHERE id = @id', {'id': d!['company_id']});
    return {
      'device': map.device({...d, 'activation_code': null}),
      'company': {
        'id': c!['id'],
        'name': c['name'],
        'utc_offset_minutes': c['utc_offset_minutes'],
        'require_photo': ((c['settings'] as Map)['require_photo'] as bool?) ?? false,
      },
    };
  }

  Future<Response> _me(Request req) async {
    final dev = await app.sessions.device(req);
    return jsonResponse({...await _info(dev.deviceId), 'server_time': app.now().toIso8601String()});
  }

  /// QR Code dinâmico (renova a cada 30 s).
  Future<Response> _qr(Request req) async {
    final dev = await app.sessions.device(req);
    final now = app.now();
    final step = QrToken.stepFor(now);
    final expiresAt = DateTime.fromMillisecondsSinceEpoch((step + 1) * QrToken.stepSeconds * 1000, isUtc: true);
    return jsonResponse({
      'token': QrToken.generate(dev.company['qr_secret'] as String, dev.deviceId, now),
      'expires_at': expiresAt.toIso8601String(),
    });
  }

  /// Lista reduzida para seleção rápida no quiosque.
  Future<Response> _members(Request req) async {
    final dev = await app.sessions.device(req);
    final rows = await app.db.query(
      '''
      SELECT m.id, u.name, m.registration, m.photo_url, (m.pin_hash IS NOT NULL) AS has_pin
      FROM members m JOIN users u ON u.id = m.user_id
      WHERE m.company_id = @c AND m.active ORDER BY u.name''',
      {'c': dev.companyId},
    );
    return jsonResponse([
      for (final r in rows)
        {'id': r['id'], 'name': r['name'], 'registration': r['registration'], 'photo_url': r['photo_url'], 'has_pin': r['has_pin']},
    ]);
  }

  /// Identifica o colaborador por crachá/QR pessoal, ou por matrícula/CPF + PIN.
  Future<Row> _resolve(String companyId, Map<String, dynamic> body, {String? deviceId}) async {
    final badge = body.optStr('badge_code');
    if (badge != null) {
      final m = await app.db.one(
        'SELECT m.id, u.name FROM members m JOIN users u ON u.id = m.user_id WHERE m.company_id = @c AND m.badge_code = @b AND m.active',
        {'c': companyId, 'b': badge},
      );
      if (m == null) throw const ApiError(404, 'unknown_badge', 'Crachá não reconhecido');
      return m;
    }
    final pin = body.str('pin', label: 'PIN');
    final memberId = optUuid(body.optStr('member_id'), 'member_id');
    final identifier = body.optStr('identifier');
    if (memberId == null && identifier == null) throw const ApiError.badRequest('Informe o colaborador');
    final digits = Documents.onlyDigits(identifier);
    final limiterKey = '$deviceId|${memberId ?? identifier}';
    _pinLimiter.ensure(limiterKey, app.now());
    final m = await app.db.one(
      '''
      SELECT m.id, m.pin_hash, u.name FROM members m JOIN users u ON u.id = m.user_id
      WHERE m.company_id = @c AND m.active AND (
        (@id::uuid IS NOT NULL AND m.id = @id::uuid) OR
        (@ident::text IS NOT NULL AND (m.registration = @ident::text OR (@digits <> '' AND u.cpf = @digits))))
      LIMIT 1''',
      {'c': companyId, 'id': memberId, 'ident': identifier, 'digits': digits},
    );
    if (m == null || !app.passwords.verify(pin, m['pin_hash'] as String?)) {
      _pinLimiter.fail(limiterKey, app.now());
      throw const ApiError(401, 'invalid_pin', 'Colaborador ou PIN incorreto');
    }
    _pinLimiter.reset(limiterKey);
    return m;
  }

  Future<Response> _identify(Request req) async {
    final dev = await app.sessions.device(req);
    final m = await _resolve(dev.companyId, await readJson(req), deviceId: dev.deviceId);
    return jsonResponse({'member_id': m['id'], 'name': m['name']});
  }

  Future<Response> _punch(Request req) async {
    final dev = await app.sessions.device(req);
    final body = await readJson(req);
    final m = await _resolve(dev.companyId, body, deviceId: dev.deviceId);
    final method = body.optStr('badge_code') != null ? PunchMethod.badge : PunchMethod.fromCode(body.optStr('method') ?? 'pin');
    final clientTime = body.optStr('punched_at') == null ? null : DateTime.tryParse(body.optStr('punched_at')!);
    final row = await app.punches.register(PunchInput(
      companyId: dev.companyId,
      memberId: m['id'] as String,
      source: PunchSource.device,
      method: method,
      offline: body.optBool('offline') ?? false,
      clientTime: clientTime,
      clientId: body.optStr('client_id'),
      photoFileId: optUuid(body.optStr('photo_file_id'), 'photo_file_id'),
      deviceId: dev.deviceId,
      ip: req.clientIp,
      userAgent: req.headers['user-agent'],
    ));
    final receipt = await app.punches.receipt(row['id'] as String, dev.companyId);
    return created({'punch': map.punch(row, dev.offset), 'receipt': receipt.toJsonMap(), 'name': m['name']});
  }

  Future<Response> _upload(Request req) async {
    final dev = await app.sessions.device(req);
    final bytes = <int>[];
    await for (final chunk in req.read()) {
      bytes.addAll(chunk);
      if (bytes.length > 10 * 1024 * 1024) throw const ApiError.badRequest('Arquivo maior que 10 MB');
    }
    final row = await app.storage.save(
      bytes: bytes,
      contentType: req.headers['content-type'] ?? 'image/jpeg',
      filename: 'kiosk-photo.jpg',
      companyId: dev.companyId,
    );
    return created({'id': row['id']});
  }
}
