import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import 'der.dart';

/// Identificadores de objeto usados em certificados, PKCS#12 e CMS.
abstract final class Oids {
  static const data = '1.2.840.113549.1.7.1';
  static const signedData = '1.2.840.113549.1.7.2';
  static const encryptedData = '1.2.840.113549.1.7.6';
  static const sha1 = '1.3.14.3.2.26';
  static const sha256 = '2.16.840.1.101.3.4.2.1';
  static const sha512 = '2.16.840.1.101.3.4.2.3';
  static const rsaEncryption = '1.2.840.113549.1.1.1';
  static const sha256WithRsa = '1.2.840.113549.1.1.11';
  static const contentType = '1.2.840.113549.1.9.3';
  static const messageDigest = '1.2.840.113549.1.9.4';
  static const signingTime = '1.2.840.113549.1.9.5';
  static const signingCertificateV2 = '1.2.840.113549.1.9.16.2.47';
  static const pbes2 = '1.2.840.113549.1.5.13';
  static const pbkdf2 = '1.2.840.113549.1.5.12';
  static const hmacWithSha1 = '1.2.840.113549.2.7';
  static const hmacWithSha256 = '1.2.840.113549.2.9';
  static const hmacWithSha512 = '1.2.840.113549.2.11';
  static const aes128Cbc = '2.16.840.1.101.3.4.1.2';
  static const aes192Cbc = '2.16.840.1.101.3.4.1.22';
  static const aes256Cbc = '2.16.840.1.101.3.4.1.42';
  static const desEde3Cbc = '1.2.840.113549.3.7';
  static const pbeSha3Des = '1.2.840.113549.1.12.1.3';
  static const pbeShaRc2128 = '1.2.840.113549.1.12.1.5';
  static const pbeShaRc240 = '1.2.840.113549.1.12.1.6';
  static const keyBag = '1.2.840.113549.1.12.10.1.1';
  static const shroudedKeyBag = '1.2.840.113549.1.12.10.1.2';
  static const certBag = '1.2.840.113549.1.12.10.1.3';
  static const x509Certificate = '1.2.840.113549.1.9.22.1';
  static const basicConstraints = '2.5.29.19';
  static const keyUsage = '2.5.29.15';

  static const nameAttributes = {
    '2.5.4.3': 'CN',
    '2.5.4.5': 'serialNumber',
    '2.5.4.6': 'C',
    '2.5.4.7': 'L',
    '2.5.4.8': 'ST',
    '2.5.4.10': 'O',
    '2.5.4.11': 'OU',
    '1.2.840.113549.1.9.1': 'E',
  };
}

/// Certificado X.509 (somente leitura dos campos usados na assinatura).
class X509Certificate {
  final Uint8List der;
  late final DerNode _tbs;
  late final int _o;

  X509Certificate.parse(List<int> bytes) : der = Uint8List.fromList(bytes) {
    final root = DerNode.parse(der);
    _tbs = root[0];
    _o = _tbs[0].tag == 0xa0 ? 1 : 0;
    // Valida a estrutura básica já na leitura.
    publicKey;
    notAfter;
  }

  DerNode get serialNode => _tbs[_o];
  BigInt get serialNumber => serialNode.bigInt;
  DerNode get issuerNode => _tbs[_o + 2];
  DerNode get subjectNode => _tbs[_o + 4];
  DateTime get notBefore => _tbs[_o + 3][0].time;
  DateTime get notAfter => _tbs[_o + 3][1].time;

  String get subject => describeName(subjectNode);
  String get issuer => describeName(issuerNode);
  String? get subjectCommonName => nameAttribute(subjectNode, '2.5.4.3');
  String? get issuerCommonName => nameAttribute(issuerNode, '2.5.4.3');

  bool get isSelfSigned => Der.equalBytes(issuerNode.raw, subjectNode.raw);

  /// Emitido por uma AC da ICP-Brasil (cadeia com "ICP-Brasil" no emissor).
  bool get isIcpBrasil => issuer.contains('ICP-Brasil');

  RSAPublicKey get publicKey {
    final spki = _tbs[_o + 5];
    if (spki[0][0].oid != Oids.rsaEncryption) {
      throw const FormatException('Somente certificados RSA são suportados');
    }
    final k = DerNode.parse(spki[1].bitString);
    return RSAPublicKey(k[0].bigInt, k[1].bigInt);
  }

  Uint8List get sha256 => Uint8List.fromList(crypto.sha256.convert(der).bytes);

  String get serialHex => serialNumber.toRadixString(16).toUpperCase();

  String toPem() => _pem('CERTIFICATE', der);

  static String describeName(DerNode name) => [
        for (final rdn in name.children)
          for (final atv in rdn.children) '${Oids.nameAttributes[atv[0].oid] ?? atv[0].oid}=${atv[1].string}',
      ].join(', ');

  static String? nameAttribute(DerNode name, String oid) {
    for (final rdn in name.children) {
      for (final atv in rdn.children) {
        if (atv[0].oid == oid) return atv[1].string;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is X509Certificate && Der.equalBytes(der, other.der);

  @override
  int get hashCode => Object.hashAll(der.take(64));
}

/// Leitura e escrita de PEM.
abstract final class Pem {
  static final _block = RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END \1-----');

  static List<(String, Uint8List)> decode(String text) => [
        for (final m in _block.allMatches(text))
          (m.group(1)!, base64.decode(m.group(2)!.replaceAll(RegExp(r'\s'), ''))),
      ];
}

String _pem(String label, List<int> der) {
  final b64 = base64.encode(der);
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

/// Chaves RSA (PKCS#1/PKCS#8) e operações de assinatura.
abstract final class RsaKeys {
  static RSAPrivateKey fromPkcs1(DerNode n) => RSAPrivateKey(n[1].bigInt, n[3].bigInt, n[4].bigInt, n[5].bigInt);

  static RSAPrivateKey fromPkcs8(DerNode n) {
    if (n[1][0].oid != Oids.rsaEncryption) throw const FormatException('Somente chaves RSA são suportadas');
    return fromPkcs1(DerNode.parse(n[2].octets));
  }

  /// Chave em PKCS#8 (PEM "PRIVATE KEY"); [publicExponent] do certificado.
  static String toPkcs8Pem(RSAPrivateKey k, BigInt publicExponent) {
    final p = k.p!, q = k.q!, d = k.privateExponent!;
    final pkcs1 = Der.seq([
      Der.smallInt(0),
      Der.integer(k.modulus!),
      Der.integer(publicExponent),
      Der.integer(d),
      Der.integer(p),
      Der.integer(q),
      Der.integer(d % (p - BigInt.one)),
      Der.integer(d % (q - BigInt.one)),
      Der.integer(q.modInverse(p)),
    ]);
    return _pem('PRIVATE KEY', Der.seq([Der.smallInt(0), Der.algorithm(Oids.rsaEncryption), Der.octets(pkcs1)]));
  }

  static Uint8List sign(RSAPrivateKey key, List<int> data) {
    final s = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
    return s.generateSignature(Uint8List.fromList(data)).bytes;
  }

  static bool verify(RSAPublicKey key, List<int> data, List<int> signature, {String digestOid = Oids.sha256}) {
    final (digest, prefix) = switch (digestOid) {
      Oids.sha1 => (SHA1Digest(), '06052b0e03021a'),
      Oids.sha512 => (SHA512Digest(), '0609608648016503040203'),
      _ => (SHA256Digest(), '0609608648016503040201'),
    };
    final s = RSASigner(digest, prefix)..init(false, PublicKeyParameter<RSAPublicKey>(key));
    try {
      return s.verifySignature(Uint8List.fromList(data), RSASignature(Uint8List.fromList(signature)));
    } catch (_) {
      return false;
    }
  }

  static SecureRandom secureRandom() {
    final seed = Random.secure();
    return FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));
  }
}

/// Certificado + chave privada (+ cadeia) usados para assinar.
class SigningIdentity {
  final X509Certificate certificate;
  final RSAPrivateKey privateKey;
  final List<X509Certificate> chain;
  const SigningIdentity(this.certificate, this.privateKey, [this.chain = const []]);

  /// Lê um arquivo PEM com o certificado (e cadeia) e a chave privada.
  factory SigningIdentity.fromPem(String text) {
    final certs = <X509Certificate>[];
    RSAPrivateKey? key;
    for (final (label, der) in Pem.decode(text)) {
      switch (label) {
        case 'CERTIFICATE':
          certs.add(X509Certificate.parse(der));
        case 'PRIVATE KEY':
          key = RsaKeys.fromPkcs8(DerNode.parse(der));
        case 'RSA PRIVATE KEY':
          key = RsaKeys.fromPkcs1(DerNode.parse(der));
        case 'ENCRYPTED PRIVATE KEY':
          throw const FormatException('Chave PEM criptografada: use o arquivo .pfx com a senha');
      }
    }
    if (key == null) throw const FormatException('Chave privada não encontrada no PEM');
    return SigningIdentity.match(key, certs);
  }

  /// Escolhe o certificado correspondente à chave; os demais formam a cadeia.
  factory SigningIdentity.match(RSAPrivateKey key, List<X509Certificate> certs) {
    final own = certs.where((c) => c.publicKey.modulus == key.modulus).firstOrNull;
    if (own == null) throw const FormatException('Nenhum certificado corresponde à chave privada');
    return SigningIdentity(own, key, [for (final c in certs) if (c != own) c]);
  }

  String toPem() =>
      certificate.toPem() + chain.map((c) => c.toPem()).join() + RsaKeys.toPkcs8Pem(privateKey, certificate.publicKey.exponent!);

  /// Gera um certificado autoassinado RSA 2048 (fora do isolate principal).
  static Future<SigningIdentity> selfSigned({required String commonName, String organization = 'PontoMax', DateTime? now}) async {
    final pem = await Isolate.run(() => _selfSignedPem(commonName, organization, now ?? DateTime.now()));
    return SigningIdentity.fromPem(pem);
  }

  static String _selfSignedPem(String commonName, String organization, DateTime now) {
    final rnd = RsaKeys.secureRandom();
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
    final pair = gen.generateKeyPair();
    final pub = pair.publicKey;
    final priv = pair.privateKey;
    final name = Der.seq([
      Der.set([Der.seq([Der.oid('2.5.4.6'), Der.printableString('BR')])]),
      Der.set([Der.seq([Der.oid('2.5.4.10'), Der.utf8String(organization)])]),
      Der.set([Der.seq([Der.oid('2.5.4.3'), Der.utf8String(commonName)])]),
    ]);
    final serial = Der.toBigInt(rnd.nextBytes(16)) | BigInt.one;
    final start = now.toUtc().subtract(const Duration(days: 1));
    final tbs = Der.seq([
      Der.context(0, Der.smallInt(2)),
      Der.integer(serial),
      Der.algorithm(Oids.sha256WithRsa),
      name,
      Der.seq([Der.time(start), Der.time(DateTime.utc(start.year + 10, start.month, start.day))]),
      name,
      Der.seq([
        Der.algorithm(Oids.rsaEncryption),
        Der.bitString(Der.seq([Der.integer(pub.modulus!), Der.integer(pub.exponent!)])),
      ]),
      Der.context(
        3,
        Der.seq([
          Der.seq([Der.oid(Oids.basicConstraints), Der.boolean(true), Der.octets(Der.seq([]))]),
          // digitalSignature + nonRepudiation.
          Der.seq([Der.oid(Oids.keyUsage), Der.boolean(true), Der.octets(Der.bitString([0xc0], unusedBits: 6))]),
        ]),
      ),
    ]);
    final cert = Der.seq([tbs, Der.algorithm(Oids.sha256WithRsa), Der.bitString(RsaKeys.sign(priv, tbs))]);
    return _pem('CERTIFICATE', cert) + RsaKeys.toPkcs8Pem(priv, pub.exponent!);
  }
}
