import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Token de QR Code dinâmico (estilo TOTP) exibido no quiosque.
///
/// O colaborador escaneia o QR com o celular; o servidor valida que o token
/// foi gerado pelo dispositivo nos últimos [stepSeconds] segundos, o que
/// impede que uma foto do QR seja reutilizada mais tarde.
abstract final class QrToken {
  static const prefix = 'PMX1';
  static const stepSeconds = 30;

  static int stepFor(DateTime instant) =>
      instant.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ stepSeconds;

  static String _sign(String secret, String deviceId, int step) {
    final mac = Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode('$deviceId.$step'));
    return mac.toString().substring(0, 16);
  }

  static String generate(String secret, String deviceId, DateTime instant) {
    final step = stepFor(instant);
    return '$prefix.$deviceId.$step.${_sign(secret, deviceId, step)}';
  }

  /// Retorna o `deviceId` se o token for válido (tolerância de ±[window] passos).
  static String? verify(String secret, String token, DateTime instant,
      {int window = 1}) {
    final parts = token.trim().split('.');
    if (parts.length != 4 || parts[0] != prefix) return null;
    final deviceId = parts[1];
    final step = int.tryParse(parts[2]);
    if (step == null) return null;
    final now = stepFor(instant);
    if ((now - step).abs() > window) return null;
    final expected = _sign(secret, deviceId, step);
    if (!_constantTimeEquals(expected, parts[3])) return null;
    return deviceId;
  }

  /// Extrai o `deviceId` sem validar a assinatura.
  static String? deviceIdOf(String token) {
    final parts = token.trim().split('.');
    if (parts.length != 4 || parts[0] != prefix) return null;
    return parts[1];
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }
}
