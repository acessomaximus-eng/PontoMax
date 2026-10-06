import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resolução do endereço da API.
///
/// * Web: mesma origem do site (`/api/v1`), pois o backend serve o app em `/app/`.
/// * Mobile/desktop: `--dart-define=API_URL=https://...` ou o valor salvo
///   pelo usuário na tela de login ("Servidor").
class AppConfig {
  static const _definedUrl = String.fromEnvironment('API_URL');
  static const _prefKey = 'pontomax.api_url';

  static String? _override;

  static String get defaultApiUrl {
    if (_definedUrl.isNotEmpty) return _normalize(_definedUrl);
    if (kIsWeb) {
      final base = Uri.base;
      final port = base.hasPort ? ':${base.port}' : '';
      return '${base.scheme}://${base.host}$port/api/v1';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8080/api/v1';
    }
    return 'http://localhost:8080/api/v1';
  }

  static String get apiUrl => _override ?? defaultApiUrl;

  /// Origem do servidor (para URLs relativas de arquivos).
  static String get serverOrigin {
    final u = Uri.parse(apiUrl);
    final port = u.hasPort ? ':${u.port}' : '';
    return '${u.scheme}://${u.host}$port';
  }

  static String resolveUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('http')) return url;
    return '$serverOrigin$url';
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved != null && saved.isNotEmpty) _override = saved;
  }

  /// Endereço em rede local (onde `http://` sem criptografia é aceito).
  static bool isLocalHost(String host) {
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final p = host.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((x) => x == null)) return false;
    final (a, b) = (p[0]!, p[1]!);
    return a == 10 ||
        a == 127 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31);
  }

  /// Valida o endereço digitado. Retorna a mensagem de erro, se houver.
  static String? validateServer(String url) {
    final uri = Uri.tryParse(_normalize(url.trim()));
    if (uri == null || uri.host.isEmpty) return 'Endereço inválido';
    if (uri.scheme == 'http' && !isLocalHost(uri.host)) {
      return 'Use https:// para servidores na internet '
          '(http só é aceito na rede local)';
    }
    return null;
  }

  static Future<void> setApiUrl(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    if (url == null || url.trim().isEmpty) {
      _override = null;
      await prefs.remove(_prefKey);
    } else {
      _override = _normalize(url.trim());
      await prefs.setString(_prefKey, _override!);
    }
  }

  static String _normalize(String url) {
    var u = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    if (!u.startsWith('http')) {
      // "192.168.0.10:8080" → http na rede local; demais → https.
      final host = Uri.tryParse('http://$u')?.host ?? '';
      u = '${isLocalHost(host) ? 'http' : 'https'}://$u';
    }
    if (!u.endsWith('/api/v1')) u = '$u/api/v1';
    return u;
  }

  /// Coletor do AFD conforme a plataforma.
  static String get punchSource {
    if (kIsWeb) return 'browser';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return 'mobile';
      default:
        return 'desktop';
    }
  }

  static bool get isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static const appVersion = '0.1.0';
}
