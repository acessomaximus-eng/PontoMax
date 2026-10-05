import 'http_utils.dart';

/// Limitador de tentativas em memória (janela deslizante).
///
/// Suficiente para uma instância; com várias instâncias, use Redis.
class RateLimiter {
  final int max;
  final Duration window;
  final String message;
  final _hits = <String, List<DateTime>>{};

  RateLimiter(
    this.max,
    this.window, {
    this.message = 'Muitas tentativas. Aguarde um minuto e tente novamente.',
  });

  /// Registra uma tentativa e lança 429 se o limite foi atingido.
  void check(String key, DateTime now) {
    final list = _prune(key, now);
    if (list.length >= max) throw ApiError(429, 'too_many_requests', message);
    list.add(now);
  }

  /// Lança 429 se o limite foi atingido, sem registrar tentativa.
  void ensure(String key, DateTime now) {
    if (_prune(key, now).length >= max) throw ApiError(429, 'too_many_requests', message);
  }

  /// Registra uma falha (para limitar apenas tentativas erradas).
  void fail(String key, DateTime now) => _prune(key, now).add(now);

  void reset(String key) => _hits.remove(key);

  List<DateTime> _prune(String key, DateTime now) {
    if (_hits.length > 10000) _hits.clear();
    return _hits.putIfAbsent(key, () => [])..removeWhere((t) => now.difference(t) > window);
  }
}
