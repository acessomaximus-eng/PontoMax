import 'dart:async';

/// Barramento de eventos em memória para long-polling (chat e notificações).
///
/// Em implantações com múltiplas instâncias, substitua por Redis Pub/Sub ou
/// `LISTEN/NOTIFY` do PostgreSQL.
class EventBus {
  final _waiters = <String, List<Completer<String>>>{};

  /// Aguarda um evento para [key] até [timeout]. Retorna o tipo do evento ou
  /// `null` em timeout.
  Future<String?> wait(String key, Duration timeout) async {
    final c = Completer<String>();
    _waiters.putIfAbsent(key, () => []).add(c);
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      _waiters[key]?.remove(c);
      if (_waiters[key]?.isEmpty ?? false) _waiters.remove(key);
    }
  }

  void publish(String key, String event) {
    final list = _waiters.remove(key);
    if (list == null) return;
    for (final c in list) {
      if (!c.isCompleted) c.complete(event);
    }
  }
}
