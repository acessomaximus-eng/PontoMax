import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pdf/pdf.dart';
// Tipos de baixo nível (PdfDict, PdfString...) usados pela API de assinatura.
// ignore: implementation_imports
import 'package:pdf/src/priv.dart';

import 'cms.dart';

/// Assinatura PAdES (ETSI.CAdES.detached) para o pacote `pdf`, exigida pela
/// Portaria 671 para o comprovante de registro de ponto em PDF.
///
/// O documento é gerado com espaço reservado em /Contents; depois de escrito,
/// a /ByteRange é preenchida e o CMS cobre todo o arquivo exceto a assinatura.
class PadesSignature extends PdfSignatureBase {
  final CmsSigner signer;
  final DateTime signingTime;
  final String reason;
  final String? location;

  /// Bytes reservados para o CMS (cadeia ICP-Brasil completa cabe com folga).
  static const reserved = 16384;
  static const _rangePlaceholder = 9999999999;

  PadesSignature(this.signer, {required this.signingTime, required this.reason, this.location});

  @override
  void preSign(PdfObject object, PdfDict params) {
    params['/Filter'] = const PdfName('/Adobe.PPKLite');
    params['/SubFilter'] = const PdfName('/ETSI.CAdES.detached');
    params['/ByteRange'] = PdfArray([
      const PdfNum(0),
      const PdfNum(_rangePlaceholder),
      const PdfNum(_rangePlaceholder),
      const PdfNum(_rangePlaceholder),
    ]);
    params['/Contents'] = PdfString(Uint8List(reserved), format: PdfStringFormat.binary, encrypted: false);
    params['/M'] = PdfString.fromDate(signingTime, encrypted: false);
    params['/Reason'] = PdfString.fromString(reason, encrypted: false);
    final name = signer.identity.certificate.subjectCommonName;
    if (name != null) params['/Name'] = PdfString.fromString(name, encrypted: false);
    if (location != null) params['/Location'] = PdfString.fromString(location!, encrypted: false);
  }

  @override
  Future<void> sign(PdfObject object, PdfStream os, PdfDict params, int? offsetStart, int? offsetEnd) async {
    final bytes = os.output();
    final segment = latin1.decode(Uint8List.sublistView(bytes, offsetStart!, offsetEnd!));
    final contentsKey = segment.indexOf('/Contents');
    final rangeKey = segment.indexOf('/ByteRange');
    if (contentsKey < 0 || rangeKey < 0) throw StateError('Campos de assinatura não encontrados no PDF');
    final contentsStart = offsetStart + segment.indexOf('<', contentsKey);
    final contentsEnd = offsetStart + segment.indexOf('>', contentsKey) + 1;
    final rangeStart = offsetStart + segment.indexOf('[', rangeKey);
    final rangeEnd = offsetStart + segment.indexOf(']', rangeKey) + 1;

    final total = bytes.length;
    final range = '[0 $contentsStart $contentsEnd ${total - contentsEnd}]';
    final width = rangeEnd - rangeStart;
    if (range.length > width) throw StateError('ByteRange não cabe no espaço reservado');
    os.setBytes(rangeStart, latin1.encode(range.padRight(width)));

    final signed = os.output();
    final digest = crypto.sha256.convert([
      ...Uint8List.sublistView(signed, 0, contentsStart),
      ...Uint8List.sublistView(signed, contentsEnd),
    ]);
    final cms = signer.signDigest(Uint8List.fromList(digest.bytes));
    final hex = cms.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    if (hex.length > contentsEnd - contentsStart - 2) throw StateError('Assinatura maior que o espaço reservado');
    os.setBytes(contentsStart + 1, latin1.encode(hex));
  }
}
