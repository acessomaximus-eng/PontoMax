import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _random = Random.secure();

/// Bytes aleatórios criptograficamente seguros.
Uint8List randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

/// Token aleatório URL-safe.
String randomToken([int bytes = 32]) =>
    base64Url.encode(randomBytes(bytes)).replaceAll('=', '');

/// Código legível (sem caracteres ambíguos), ex.: ativação de quiosque.
String randomCode(int length) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return List.generate(length, (_) => alphabet[_random.nextInt(alphabet.length)]).join();
}

String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

String hmacHex(String secret, String value) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(value)).toString();

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

/// Hash de senha com PBKDF2-HMAC-SHA256.
///
/// Formato: `pbkdf2_sha256$<iterações>$<salt b64>$<hash b64>`.
class PasswordHasher {
  final int iterations;
  const PasswordHasher({this.iterations = 120000});

  String hash(String password) {
    final salt = randomBytes(16);
    final derived = _pbkdf2(utf8.encode(password), salt, iterations, 32);
    return 'pbkdf2_sha256\$$iterations\$${base64.encode(salt)}\$${base64.encode(derived)}';
  }

  bool verify(String password, String? stored) {
    if (stored == null) return false;
    final parts = stored.split('\$');
    if (parts.length != 4 || parts[0] != 'pbkdf2_sha256') return false;
    final iter = int.tryParse(parts[1]);
    if (iter == null) return false;
    final salt = base64.decode(parts[2]);
    final expected = parts[3];
    final derived = _pbkdf2(utf8.encode(password), salt, iter, 32);
    return constantTimeEquals(base64.encode(derived), expected);
  }

  static Uint8List _pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
    final hmac = Hmac(sha256, password);
    final blocks = (length / 32).ceil();
    final out = BytesBuilder();
    for (var block = 1; block <= blocks; block++) {
      final blockBytes = Uint8List(4)..buffer.asByteData().setUint32(0, block);
      var u = hmac.convert([...salt, ...blockBytes]).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }
}

/// Senha provisória legível com letras e números (ex.: `kqmt4821`).
String temporaryPassword() {
  const letters = 'abcdefghjkmnpqrstuvwxyz';
  final l = List.generate(4, (_) => letters[_random.nextInt(letters.length)]).join();
  return '$l${_random.nextInt(9000) + 1000}';
}
