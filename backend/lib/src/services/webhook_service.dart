import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../app.dart';
import '../auth/crypto_utils.dart';
import '../db/database.dart';

final _log = Logger('webhooks');

/// Eventos disponíveis para webhooks.
const webhookEvents = {
  'punch.created': 'Marcação registrada',
  'request.created': 'Solicitação criada',
  'request.approved': 'Solicitação aprovada',
  'request.rejected': 'Solicitação recusada',
  'member.created': 'Colaborador cadastrado',
  'member.dismissed': 'Colaborador desligado',
  'period.closed': 'Período fechado',
};

/// Entrega de webhooks assinados com HMAC-SHA256.
///
/// Cabeçalhos: `X-PontoMax-Event`, `X-PontoMax-Delivery` e
/// `X-PontoMax-Signature: sha256=<hex>` (HMAC do corpo com o segredo do webhook).
class WebhookService {
  final App app;
  WebhookService(this.app);

  /// Entregas pendentes (aguardadas nos testes).
  final pending = <Future<void>>[];

  /// Dispara o evento para os webhooks ativos da empresa (assíncrono).
  void dispatch(String companyId, String event, Map<String, Object?> data) {
    final f = _dispatch(companyId, event, data).catchError((Object e, StackTrace st) {
      _log.warning('Falha ao disparar $event', e, st);
    });
    pending.add(f);
    f.whenComplete(() => pending.remove(f));
  }

  Future<void> _dispatch(String companyId, String event, Map<String, Object?> data) async {
    final hooks = await app.db.query(
      'SELECT * FROM webhooks WHERE company_id = @c AND active AND @e = ANY(events)',
      {'c': companyId, 'e': event},
    );
    for (final h in hooks) {
      await deliver(h, event, data);
    }
  }

  /// Entrega com até 3 tentativas. Retorna o status HTTP final (0 = falha de rede).
  Future<int> deliver(Row hook, String event, Map<String, Object?> data, {int attempts = 3}) async {
    final delivery = randomToken(12);
    final body = jsonEncode({
      'id': delivery,
      'event': event,
      'created_at': app.now().toIso8601String(),
      'data': data,
    }, toEncodable: (o) => o is DateTime ? o.toIso8601String() : o.toString());
    final signature = hmacHex(hook['secret'] as String, body);
    var status = 0;
    String? error;
    for (var i = 0; i < attempts; i++) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final req = await client.postUrl(Uri.parse(hook['url'] as String));
        req.headers
          ..contentType = ContentType.json
          ..set('user-agent', 'PontoMax-Webhooks/1.0')
          ..set('x-pontomax-event', event)
          ..set('x-pontomax-delivery', delivery)
          ..set('x-pontomax-signature', 'sha256=$signature');
        req.write(body);
        final res = await req.close().timeout(const Duration(seconds: 15));
        await res.drain<void>();
        client.close();
        status = res.statusCode;
        error = status >= 200 && status < 300 ? null : 'HTTP $status';
        if (error == null) break;
      } catch (e) {
        status = 0;
        error = e.toString();
      }
      if (i < attempts - 1) await Future<void>.delayed(Duration(seconds: 1 << (i * 2)));
    }
    await app.db.execute(
      'UPDATE webhooks SET last_status = @s, last_error = @e, last_delivery_at = now() WHERE id = @id',
      {'s': status, 'e': error, 'id': hook['id']},
    );
    return status;
  }
}
