import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'der.dart';
import 'x509.dart';

/// Assinatura CMS no padrão CAdES-BES (RFC 5652 / ETSI EN 319 122), destacada
/// (`.p7s`), como exige a Portaria MTP 671/2021 para o AFD e o AEJ. Também é a
/// estrutura usada dentro do PDF assinado (PAdES).
class CmsSigner {
  final SigningIdentity identity;
  const CmsSigner(this.identity);

  /// Assinatura destacada do conteúdo (arquivo `.p7s`).
  Uint8List signDetached(List<int> content, {required DateTime signingTime}) =>
      signDigest(Uint8List.fromList(crypto.sha256.convert(content).bytes), signingTime: signingTime);

  /// Assina um hash SHA-256 já calculado. No PAdES o horário vai no
  /// dicionário do PDF (/M) e [signingTime] deve ser omitido.
  Uint8List signDigest(Uint8List digest, {DateTime? signingTime}) {
    final cert = identity.certificate;
    final essCertId = Der.seq([
      Der.octets(cert.sha256),
      Der.seq([
        Der.seq([Der.context(4, cert.issuerNode.raw)]),
        cert.serialNode.raw,
      ]),
    ]);
    final attrs = Der.setContent([
      Der.seq([Der.oid(Oids.contentType), Der.set([Der.oid(Oids.data)])]),
      if (signingTime != null) Der.seq([Der.oid(Oids.signingTime), Der.set([Der.time(signingTime)])]),
      Der.seq([Der.oid(Oids.messageDigest), Der.set([Der.octets(digest)])]),
      Der.seq([
        Der.oid(Oids.signingCertificateV2),
        Der.set([Der.seq([Der.seq([essCertId])])]),
      ]),
    ]);
    // A assinatura cobre os atributos codificados como SET OF (tag 0x31).
    final signature = RsaKeys.sign(identity.privateKey, Der.tlv(0x31, attrs));
    final signerInfo = Der.seq([
      Der.smallInt(1),
      Der.seq([cert.issuerNode.raw, cert.serialNode.raw]),
      Der.algorithm(Oids.sha256, withNull: false),
      Der.context(0, attrs),
      Der.algorithm(Oids.sha256WithRsa),
      Der.octets(signature),
    ]);
    final signedData = Der.seq([
      Der.smallInt(1),
      Der.set([Der.algorithm(Oids.sha256, withNull: false)]),
      Der.seq([Der.oid(Oids.data)]),
      Der.context(0, Der.concat([cert.der, for (final c in identity.chain) c.der])),
      Der.set([signerInfo]),
    ]);
    return Der.seq([Der.oid(Oids.signedData), Der.context(0, signedData)]);
  }
}

/// Resultado da verificação de uma assinatura destacada.
class CmsVerification {
  final bool valid;
  final String? error;
  final X509Certificate? certificate;
  final DateTime? signingTime;
  const CmsVerification(this.valid, {this.error, this.certificate, this.signingTime});

  Map<String, Object?> toJson() => {
        'valid': valid,
        if (error != null) 'error': error,
        if (certificate != null) 'signer': certificate!.subjectCommonName ?? certificate!.subject,
        if (certificate != null) 'issuer': certificate!.issuerCommonName ?? certificate!.issuer,
        if (certificate != null) 'icp_brasil': certificate!.isIcpBrasil,
        if (signingTime != null) 'signing_time': signingTime!.toIso8601String(),
      };
}

abstract final class CmsVerifier {
  /// Verifica a integridade (hash) e a assinatura RSA de um `.p7s` destacado.
  /// Não valida a cadeia até a raiz da ICP-Brasil nem revogação.
  static CmsVerification verifyDetached(List<int> p7s, List<int> content) {
    try {
      final root = DerNode.parse(p7s);
      if (root[0].oid != Oids.signedData) return const CmsVerification(false, error: 'Não é uma assinatura CMS');
      final sd = root[1][0];
      final certs = [
        for (final n in sd.children.where((n) => n.tag == 0xa0))
          for (final c in n.children) X509Certificate.parse(c.raw),
      ];
      final si = sd.children.last[0];
      final sid = si[1];
      final cert = certs
          .where((c) => c.serialNumber == sid[1].bigInt && Der.equalBytes(c.issuerNode.raw, sid[0].raw))
          .firstOrNull;
      if (cert == null) return const CmsVerification(false, error: 'Certificado do signatário ausente');
      final digestOid = si[2][0].oid;
      final signedAttrs = si[3];
      if (signedAttrs.tag != 0xa0) return CmsVerification(false, error: 'Sem atributos assinados', certificate: cert);
      Uint8List? messageDigest;
      DateTime? signingTime;
      for (final attr in signedAttrs.children) {
        if (attr[0].oid == Oids.messageDigest) messageDigest = attr[1][0].octets;
        if (attr[0].oid == Oids.signingTime) signingTime = attr[1][0].time;
      }
      final digest = switch (digestOid) {
        Oids.sha1 => crypto.sha1.convert(content).bytes,
        Oids.sha512 => crypto.sha512.convert(content).bytes,
        _ => crypto.sha256.convert(content).bytes,
      };
      if (messageDigest == null || !Der.equalBytes(messageDigest, digest)) {
        return CmsVerification(false, error: 'O arquivo foi alterado após a assinatura', certificate: cert);
      }
      final ok = RsaKeys.verify(cert.publicKey, Der.tlv(0x31, signedAttrs.content), si[5].octets, digestOid: digestOid);
      return CmsVerification(ok,
          error: ok ? null : 'Assinatura inválida', certificate: cert, signingTime: signingTime);
    } on FormatException catch (e) {
      return CmsVerification(false, error: 'Assinatura malformada: ${e.message}');
    }
  }
}
