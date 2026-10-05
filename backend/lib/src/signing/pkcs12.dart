import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'der.dart';
import 'x509.dart';

class Pkcs12Exception implements Exception {
  final String message;
  const Pkcs12Exception(this.message);
  @override
  String toString() => message;
}

/// Leitura de certificados A1 (.pfx/.p12) — formato atual do OpenSSL 3
/// (PBES2/AES + PBKDF2) e o legado (3DES e RC2 com SHA-1), usado pela maioria
/// das autoridades certificadoras da ICP-Brasil e pelo Windows.
abstract final class Pkcs12 {
  static SigningIdentity parse(List<int> pfx, String password) {
    final DerNode root;
    try {
      root = DerNode.parse(pfx);
    } on FormatException {
      throw const Pkcs12Exception('Arquivo de certificado inválido (esperado .pfx/.p12)');
    }
    final authSafe = root[1];
    if (authSafe[0].oid != Oids.data) {
      throw const Pkcs12Exception('Certificado .pfx protegido por chave pública não é suportado');
    }
    final authContent = authSafe[1][0].octets;
    if (root.length > 2) _verifyMac(root[2], authContent, password);

    final keys = <RSAPrivateKey>[];
    final certs = <X509Certificate>[];
    for (final info in DerNode.parse(authContent).children) {
      final Uint8List safeContents;
      switch (info[0].oid) {
        case Oids.data:
          safeContents = info[1][0].octets;
        case Oids.encryptedData:
          final eci = info[1][0][1];
          safeContents = _decrypt(eci[1], eci[2].octets, password);
        default:
          continue;
      }
      for (final bag in DerNode.parse(safeContents).children) {
        final value = bag[1][0];
        switch (bag[0].oid) {
          case Oids.keyBag:
            keys.add(RsaKeys.fromPkcs8(value));
          case Oids.shroudedKeyBag:
            keys.add(RsaKeys.fromPkcs8(DerNode.parse(_decrypt(value[0], value[1].octets, password))));
          case Oids.certBag:
            if (value[0].oid == Oids.x509Certificate) certs.add(X509Certificate.parse(value[1][0].octets));
        }
      }
    }
    if (keys.isEmpty) throw const Pkcs12Exception('O arquivo não contém a chave privada');
    try {
      return SigningIdentity.match(keys.first, certs);
    } on FormatException catch (e) {
      throw Pkcs12Exception(e.message);
    }
  }

  static Uint8List _bmpPassword(String password) {
    final out = <int>[];
    for (final c in password.codeUnits) {
      out
        ..add(c >> 8)
        ..add(c & 0xff);
    }
    return Uint8List.fromList([...out, 0, 0]);
  }

  static Digest _digest(String oid) => switch (oid) {
        Oids.sha1 || Oids.hmacWithSha1 => SHA1Digest(),
        Oids.sha256 || Oids.hmacWithSha256 => SHA256Digest(),
        Oids.sha512 || Oids.hmacWithSha512 => SHA512Digest(),
        _ => throw Pkcs12Exception('Algoritmo de hash não suportado ($oid)'),
      };

  static void _verifyMac(DerNode macData, Uint8List content, String password) {
    final digestOid = macData[0][0][0].oid;
    final expected = macData[0][1].octets;
    final salt = macData[1].octets;
    final iterations = macData.length > 2 ? macData[2].intValue : 1;
    final kdfDigest = _digest(digestOid);
    final gen = PKCS12ParametersGenerator(kdfDigest)..init(_bmpPassword(password), salt, iterations);
    final key = gen.generateDerivedMacParameters(kdfDigest.digestSize);
    final macDigest = _digest(digestOid);
    final mac = (HMac(macDigest, macDigest.byteLength)..init(key)).process(content);
    if (!Der.equalBytes(mac, expected)) throw const Pkcs12Exception('Senha do certificado incorreta');
  }

  static Uint8List _decrypt(DerNode algorithm, Uint8List data, String password) {
    final oid = algorithm[0].oid;
    switch (oid) {
      case Oids.pbes2:
        final kdf = algorithm[1][0];
        final scheme = algorithm[1][1];
        if (kdf[0].oid != Oids.pbkdf2) throw const Pkcs12Exception('Derivação de chave não suportada');
        final p = kdf[1];
        final salt = p[0].octets;
        final iterations = p[1].intValue;
        int? keyLength;
        var prf = Oids.hmacWithSha1;
        for (final extra in p.children.skip(2)) {
          if (extra.tag == 0x02) keyLength = extra.intValue;
          if (extra.tag == 0x30) prf = extra[0].oid;
        }
        final (BlockCipher engine, int size) = switch (scheme[0].oid) {
          Oids.aes128Cbc => (AESEngine(), 16),
          Oids.aes192Cbc => (AESEngine(), 24),
          Oids.aes256Cbc => (AESEngine(), 32),
          Oids.desEde3Cbc => (DESedeEngine(), 24),
          final other => throw Pkcs12Exception('Cifra não suportada ($other)'),
        };
        final digest = _digest(prf);
        final kdfFn = PBKDF2KeyDerivator(HMac(digest, digest.byteLength))
          ..init(Pbkdf2Parameters(salt, iterations, keyLength ?? size));
        final key = kdfFn.process(Uint8List.fromList(utf8.encode(password)));
        return _cbc(engine, KeyParameter(key), scheme[1].octets, data);
      case Oids.pbeSha3Des:
        return _pkcs12Pbe(algorithm, data, password, DESedeEngine(), 24);
      case Oids.pbeShaRc2128:
        return _pkcs12Pbe(algorithm, data, password, RC2Engine(), 16, rc2Bits: 128);
      case Oids.pbeShaRc240:
        return _pkcs12Pbe(algorithm, data, password, RC2Engine(), 5, rc2Bits: 40);
      default:
        throw Pkcs12Exception('Criptografia do certificado não suportada ($oid)');
    }
  }

  static Uint8List _pkcs12Pbe(DerNode algorithm, Uint8List data, String password, BlockCipher engine, int keyLength,
      {int? rc2Bits}) {
    final salt = algorithm[1][0].octets;
    final iterations = algorithm[1][1].intValue;
    final gen = PKCS12ParametersGenerator(SHA1Digest())..init(_bmpPassword(password), salt, iterations);
    final derived = gen.generateDerivedParametersWithIV(keyLength, 8);
    final key = (derived.parameters as KeyParameter).key;
    return _cbc(engine, rc2Bits == null ? KeyParameter(key) : RC2Parameters(key, bits: rc2Bits), derived.iv, data);
  }

  static Uint8List _cbc(BlockCipher engine, CipherParameters key, Uint8List iv, Uint8List data) {
    final cbc = CBCBlockCipher(engine)..init(false, ParametersWithIV(key, iv));
    final size = cbc.blockSize;
    if (data.isEmpty || data.length % size != 0) throw const Pkcs12Exception('Senha do certificado incorreta');
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += size) {
      cbc.processBlock(data, off, out, off);
    }
    final pad = out.last;
    if (pad < 1 || pad > size || out.sublist(out.length - pad).any((b) => b != pad)) {
      throw const Pkcs12Exception('Senha do certificado incorreta');
    }
    return Uint8List.sublistView(out, 0, out.length - pad);
  }
}
