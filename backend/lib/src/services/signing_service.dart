import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../app.dart';
import '../signing/cms.dart';
import '../signing/pades.dart';
import '../signing/pkcs12.dart';
import '../signing/x509.dart';

final _log = Logger('assinatura');

/// Assinatura eletrônica dos arquivos legais (Portaria 671/2021): CAdES
/// destacada (.p7s) no AFD e no AEJ e PAdES no comprovante em PDF.
///
/// Usa o certificado configurado em `SIGNING_CERT_PATH`/`SIGNING_CERT_BASE64`
/// (A1 .pfx da ICP-Brasil) ou, na falta dele, um autoassinado persistido em
/// `STORAGE_DIR/signing` — suficiente para testes, não para a fiscalização.
class SigningService {
  final App app;
  SigningService(this.app);

  Future<SigningIdentity>? _identity;

  Future<SigningIdentity> identity() => _identity ??= _load().catchError((Object e) {
        _identity = null;
        throw e;
      });

  bool get configured => app.config.signingCertPath != null || app.config.signingCertBase64 != null;

  Future<SigningIdentity> _load() async {
    final c = app.config;
    if (configured) {
      final bytes = c.signingCertBase64 != null
          ? base64.decode(c.signingCertBase64!.replaceAll(RegExp(r'\s'), ''))
          : await File(c.signingCertPath!).readAsBytes();
      final text = latin1.decode(bytes, allowInvalid: true);
      final id = text.contains('-----BEGIN')
          ? SigningIdentity.fromPem(text)
          : Pkcs12.parse(bytes, c.signingCertPassword);
      final cert = id.certificate;
      _log.info('Certificado de assinatura: ${cert.subject} (válido até ${cert.notAfter.toIso8601String()})');
      if (cert.notAfter.isBefore(app.now())) _log.severe('O certificado de assinatura está VENCIDO');
      if (!cert.isIcpBrasil) _log.warning('O certificado de assinatura não é da ICP-Brasil');
      return id;
    }
    final file = File(p.join(c.storageDir, 'signing', 'autoassinado.pem'));
    if (await file.exists()) return SigningIdentity.fromPem(await file.readAsString());
    _log.warning('SIGNING_CERT_PATH não definido: gerando certificado autoassinado '
        '(não válido para a fiscalização do trabalho)');
    final id = await SigningIdentity.selfSigned(commonName: 'PontoMax REP-P (autoassinado)', now: app.now());
    await file.parent.create(recursive: true);
    await file.writeAsString(id.toPem());
    if (!Platform.isWindows) await Process.run('chmod', ['600', file.path]);
    return id;
  }

  /// Assinatura CAdES destacada (conteúdo do arquivo `.p7s`).
  Future<Uint8List> detached(List<int> content) async =>
      CmsSigner(await identity()).signDetached(content, signingTime: app.now());

  /// Assinatura PAdES para documentos gerados com o pacote `pdf`.
  Future<PadesSignature> pades(String reason) async =>
      PadesSignature(CmsSigner(await identity()), signingTime: app.now(), reason: reason);

  Future<Map<String, Object?>> info() async {
    final cert = (await identity()).certificate;
    return {
      'configured': configured,
      'self_signed': cert.isSelfSigned,
      'icp_brasil': cert.isIcpBrasil,
      'subject': cert.subjectCommonName ?? cert.subject,
      'issuer': cert.issuerCommonName ?? cert.issuer,
      'serial': cert.serialHex,
      'not_before': cert.notBefore.toIso8601String(),
      'not_after': cert.notAfter.toIso8601String(),
      'expired': cert.notAfter.isBefore(app.now()),
    };
  }
}
