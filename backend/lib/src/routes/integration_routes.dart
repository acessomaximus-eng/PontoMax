import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/crypto_utils.dart';
import '../http/http_utils.dart';
import '../services/webhook_service.dart';

/// Integrações: chaves de API (somente leitura) e webhooks.
class IntegrationRoutes {
  final App app;
  IntegrationRoutes(this.app);

  Router get router => Router()
    ..get('/integrations/api-keys', _listKeys)
    ..post('/integrations/api-keys', _createKey)
    ..delete('/integrations/api-keys/<id>', _revokeKey)
    ..get('/integrations/webhooks', _listHooks)
    ..post('/integrations/webhooks', _createHook)
    ..put('/integrations/webhooks/<id>', _updateHook)
    ..delete('/integrations/webhooks/<id>', _deleteHook)
    ..post('/integrations/webhooks/<id>/test', _testHook)
    ..get('/integrations/events', (Request r) async {
      await app.sessions.member(r);
      return jsonResponse([for (final e in webhookEvents.entries) {'event': e.key, 'label': e.value}]);
    });

  Map<String, Object?> _key(Map<String, dynamic> r) => {
        'id': r['id'],
        'name': r['name'],
        'prefix': r['prefix'],
        'created_by_name': r['created_by_name'],
        'last_used_at': r['last_used_at'],
        'revoked_at': r['revoked_at'],
        'created_at': r['created_at'],
      };

  Map<String, Object?> _hook(Map<String, dynamic> r) => {
        'id': r['id'],
        'url': r['url'],
        'events': r['events'],
        'active': r['active'],
        'last_status': r['last_status'],
        'last_error': r['last_error'],
        'last_delivery_at': r['last_delivery_at'],
        'created_at': r['created_at'],
      };

  Future<Response> _listKeys(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final rows = await app.db.query(
      '''
      SELECT k.*, u.name AS created_by_name FROM api_keys k
      JOIN members m ON m.id = k.created_by JOIN users u ON u.id = m.user_id
      WHERE k.company_id = @c ORDER BY k.created_at DESC''',
      {'c': ctx.companyId},
    );
    return jsonResponse([for (final r in rows) _key(r)]);
  }

  /// Cria uma chave. O valor completo só é exibido nesta resposta.
  Future<Response> _createKey(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final body = await readJson(req);
    final name = body.str('name', label: 'nome');
    final prefix = randomCode(8).toLowerCase();
    final key = 'pmx_${prefix}_${randomToken(24).replaceAll('_', '').replaceAll('-', '')}';
    final row = await app.db.one(
      'INSERT INTO api_keys (company_id, name, prefix, key_hash, created_by) VALUES (@c, @n, @p, @h, @by) RETURNING *',
      {'c': ctx.companyId, 'n': name, 'p': prefix, 'h': sha256Hex(key), 'by': ctx.memberId},
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'api_key',
        entityId: row!['id'] as String, data: {'name': name}, ip: req.clientIp);
    return created({..._key(row), 'key': key});
  }

  Future<Response> _revokeKey(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final n = await app.db.execute(
      'UPDATE api_keys SET revoked_at = now() WHERE id = @id AND company_id = @c AND revoked_at IS NULL',
      {'id': requireUuid(id), 'c': ctx.companyId},
    );
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'revoke', entity: 'api_key', entityId: id, ip: req.clientIp);
    return noContent();
  }

  Future<Response> _listHooks(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final rows = await app.db.query('SELECT * FROM webhooks WHERE company_id = @c ORDER BY created_at', {'c': ctx.companyId});
    return jsonResponse([for (final r in rows) _hook(r)]);
  }

  (String, List<String>) _validate(Map<String, dynamic> body, {bool partial = false}) {
    final url = partial ? (body.optStr('url') ?? '') : body.str('url', label: 'URL');
    if (url.isNotEmpty) {
      final u = Uri.tryParse(url);
      if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) {
        throw const ApiError.badRequest('URL inválida (use https://...)');
      }
    }
    final events = body.strList('events');
    if (!partial && events.isEmpty) throw const ApiError.badRequest('Selecione ao menos um evento');
    for (final e in events) {
      if (!webhookEvents.containsKey(e)) throw ApiError.badRequest('Evento desconhecido: $e');
    }
    return (url, events);
  }

  Future<Response> _createHook(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final body = await readJson(req);
    final (url, events) = _validate(body);
    final secret = randomToken(24);
    final row = await app.db.one(
      'INSERT INTO webhooks (company_id, url, events, secret) VALUES (@c, @u, @e, @s) RETURNING *',
      {'c': ctx.companyId, 'u': url, 'e': events, 's': secret},
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'webhook',
        entityId: row!['id'] as String, data: {'url': url, 'events': events}, ip: req.clientIp);
    return created({..._hook(row), 'secret': secret});
  }

  Future<Response> _updateHook(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final body = await readJson(req);
    final (url, events) = _validate(body, partial: true);
    final row = await app.db.one(
      '''
      UPDATE webhooks SET url = COALESCE(NULLIF(@u, ''), url),
        events = CASE WHEN @hasEvents THEN @e::text[] ELSE events END,
        active = COALESCE(@a, active)
      WHERE id = @id AND company_id = @c RETURNING *''',
      {
        'id': requireUuid(id),
        'c': ctx.companyId,
        'u': url,
        'hasEvents': events.isNotEmpty,
        'e': events,
        'a': body.optBool('active'),
      },
    );
    if (row == null) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'update', entity: 'webhook', entityId: id, data: body);
    return jsonResponse(_hook(row));
  }

  Future<Response> _deleteHook(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final n = await app.db.execute('DELETE FROM webhooks WHERE id = @id AND company_id = @c', {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'webhook', entityId: id);
    return noContent();
  }

  /// Envia um evento `ping` imediatamente e retorna o status.
  Future<Response> _testHook(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final row = await app.db.one('SELECT * FROM webhooks WHERE id = @id AND company_id = @c', {'id': requireUuid(id), 'c': ctx.companyId});
    if (row == null) throw const ApiError.notFound();
    final status = await app.webhooks.deliver(row, 'ping', {'message': 'Teste de webhook do PontoMax'}, attempts: 1);
    return jsonResponse({'status': status, 'ok': status >= 200 && status < 300});
  }
}
