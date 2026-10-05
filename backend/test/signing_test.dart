import 'dart:convert';
import 'dart:io';

import 'package:pontomax_backend/src/signing/cms.dart';
import 'package:pontomax_backend/src/signing/pkcs12.dart';
import 'package:pontomax_backend/src/signing/x509.dart';
import 'package:test/test.dart';

/// OpenSSL disponível (máquinas de desenvolvimento e CI) para validação cruzada.
final hasOpenssl = () {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

void main() {
  late Directory dir;
  setUpAll(() async => dir = await Directory.systemTemp.createTemp('pmx_sign'));
  tearDownAll(() => dir.delete(recursive: true));

  final content = utf8.encode('0000000001REP-P ... conteúdo do AFD\r\n');

  test('autoassinado: assina e verifica; detecta alteração', () async {
    final id = await SigningIdentity.selfSigned(commonName: 'PontoMax Teste');
    expect(id.certificate.isSelfSigned, isTrue);
    expect(id.certificate.subjectCommonName, 'PontoMax Teste');
    final p7s = CmsSigner(id).signDetached(content, signingTime: DateTime.utc(2026, 10, 5, 12));
    final ok = CmsVerifier.verifyDetached(p7s, content);
    expect(ok.valid, isTrue, reason: ok.error);
    expect(ok.signingTime, DateTime.utc(2026, 10, 5, 12));
    final tampered = [...content]..[3] ^= 1;
    expect(CmsVerifier.verifyDetached(p7s, tampered).valid, isFalse);
    // Ida e volta em PEM.
    final again = SigningIdentity.fromPem(id.toPem());
    expect(again.certificate, id.certificate);
    expect(CmsVerifier.verifyDetached(CmsSigner(again).signDetached(content, signingTime: DateTime.now()), content).valid,
        isTrue);
  });

  for (final legacy in [false, true]) {
    test('lê .pfx ${legacy ? 'legado (3DES/RC2)' : 'atual (AES/PBKDF2)'} e o OpenSSL valida a assinatura', () async {
      final d = dir.path;
      Future<void> run(List<String> args) async {
        final r = await Process.run('openssl', args, workingDirectory: d);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }

      await run(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'k.pem', '-out', 'c.pem', '-days', '30',
          '-subj', '/C=BR/O=ICP-Brasil Teste/CN=EMPRESA TESTE LTDA:12345678000199']);
      await run(['pkcs12', '-export', '-inkey', 'k.pem', '-in', 'c.pem', '-out', 'c.pfx', '-passout', 'pass:s3nh@ç',
        if (legacy) '-legacy']);
      final pfx = await File('$d/c.pfx').readAsBytes();
      expect(() => Pkcs12.parse(pfx, 'errada'), throwsA(isA<Pkcs12Exception>()));
      final id = Pkcs12.parse(pfx, 's3nh@ç');
      expect(id.certificate.subjectCommonName, 'EMPRESA TESTE LTDA:12345678000199');
      expect(id.certificate.isIcpBrasil, isTrue);

      await File('$d/afd.txt').writeAsBytes(content);
      await File('$d/afd.p7s').writeAsBytes(CmsSigner(id).signDetached(content, signingTime: DateTime.now()));
      await run(['cms', '-verify', '-binary', '-inform', 'DER', '-in', 'afd.p7s', '-content', 'afd.txt', '-noverify',
          '-out', '/dev/null']);
      // E o contrário: verificamos uma assinatura gerada pelo OpenSSL.
      await run(['cms', '-sign', '-binary', '-cades', '-md', 'sha256', '-in', 'afd.txt', '-signer', 'c.pem', '-inkey',
          'k.pem', '-outform', 'DER', '-out', 'ossl.p7s']);
      final v = CmsVerifier.verifyDetached(await File('$d/ossl.p7s').readAsBytes(), content);
      expect(v.valid, isTrue, reason: v.error);
    }, skip: hasOpenssl ? false : 'OpenSSL indisponível');
  }
}
