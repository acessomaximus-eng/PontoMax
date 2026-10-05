import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../time/local_date.dart';
import '../validators/documents.dart';

/// CRC-16/KERMIT (poly 0x1021 refletido, init 0x0000), usado nos registros
/// do AFD. Retorna 4 caracteres hexadecimais maiúsculos.
String crc16Kermit(String data) {
  var crc = 0x0000;
  for (final byte in latin1.encode(_latin1Safe(data))) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
  }
  return (crc & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');
}

String _latin1Safe(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r <= 0xFF ? r : 0x3F);
  }
  return b.toString();
}

/// Formatação de campos de largura fixa do AFD.
abstract final class AfdFmt {
  static String num(Object? value, int width) {
    final s = Documents.onlyAlnum(value?.toString());
    if (s.length > width) return s.substring(s.length - width);
    return s.padLeft(width, '0');
  }

  static String alpha(String? value, int width) {
    final s = _latin1Safe((value ?? '').replaceAll(RegExp(r'[\r\n|]'), ' '));
    if (s.length > width) return s.substring(0, width);
    return s.padRight(width, ' ');
  }

  /// `AAAA-MM-ddThh:mm:00-zzzz` a partir do relógio de parede.
  static String dateTime(DateTime wall, int offsetMinutes) {
    final d = LocalDate.fromDateTime(wall);
    final hh = wall.hour.toString().padLeft(2, '0');
    final mm = wall.minute.toString().padLeft(2, '0');
    return '${d}T$hh:$mm:00${TimeFmt.offset(offsetMinutes)}';
  }

  static String date(LocalDate d) => d.toString();
}

/// Identificação do empregador para o AFD/AEJ.
class AfdEmployer {
  /// `1` = CNPJ, `2` = CPF.
  final String documentType;
  final String document;
  final String cnoCaepf;
  final String name;
  final String location;

  const AfdEmployer({
    required this.documentType,
    required this.document,
    this.cnoCaepf = '',
    required this.name,
    this.location = '',
  });
}

/// Dados do REP-P (programa) que emite o AFD.
class RepInfo {
  /// Número de registro do programa no INPI (17 posições).
  final String inpiNumber;

  /// `1` = CNPJ, `2` = CPF do desenvolvedor.
  final String developerDocumentType;
  final String developerDocument;
  final String softwareName;
  final String softwareVersion;
  final String developerName;
  final String developerEmail;

  const RepInfo({
    this.inpiNumber = '00000000000000000',
    this.developerDocumentType = '1',
    this.developerDocument = '00000000000000',
    this.softwareName = 'PontoMax',
    this.softwareVersion = '1.0.0',
    this.developerName = 'PontoMax',
    this.developerEmail = 'contato@pontomax.app',
  });
}

/// Registro de marcação de ponto do REP-P (tipo 7).
class AfdPunch {
  final int nsr;
  final DateTime punchWall;
  final String cpf;
  final DateTime recordedWall;

  /// Coletor (`01` app mobile, `02` navegador, `03` desktop, `04` dispositivo, `05` outro).
  final String collector;
  final bool offline;
  final int offsetMinutes;

  const AfdPunch({
    required this.nsr,
    required this.punchWall,
    required this.cpf,
    required this.recordedWall,
    required this.collector,
    required this.offline,
    required this.offsetMinutes,
  });

  /// Campos 1 a 7 do registro tipo 7, exatamente como gravados no AFD.
  String fieldsWithoutHash() => [
        AfdFmt.num(nsr, 9),
        '7',
        AfdFmt.dateTime(punchWall, offsetMinutes),
        AfdFmt.num(Documents.onlyDigits(cpf), 12),
        AfdFmt.dateTime(recordedWall, offsetMinutes),
        AfdFmt.num(collector, 2),
        offline ? '1' : '0',
      ].join();

  /// SHA-256 encadeado: campos 1–7 + hash do registro tipo 7 anterior.
  String computeHash(String previousHash) => sha256
      .convert(utf8.encode('${fieldsWithoutHash()}$previousHash'))
      .toString();

  String toLine(String hash) => '${fieldsWithoutHash()}$hash';
}

/// Registro tipo 5 — inclusão (I), alteração (A) ou exclusão (E) de empregado.
class AfdEmployeeEvent {
  final int nsr;
  final DateTime recordedWall;
  final String operation;
  final String cpf;
  final String name;
  final String extra;
  final String responsibleCpf;
  final int offsetMinutes;

  const AfdEmployeeEvent({
    required this.nsr,
    required this.recordedWall,
    required this.operation,
    required this.cpf,
    required this.name,
    this.extra = '',
    required this.responsibleCpf,
    required this.offsetMinutes,
  });

  String toLine() {
    final body = [
      AfdFmt.num(nsr, 9),
      '5',
      AfdFmt.dateTime(recordedWall, offsetMinutes),
      AfdFmt.alpha(operation, 1),
      AfdFmt.num(Documents.onlyDigits(cpf), 12),
      AfdFmt.alpha(name, 52),
      AfdFmt.alpha(extra, 4),
      AfdFmt.num(Documents.onlyDigits(responsibleCpf), 11),
    ].join();
    return '$body${crc16Kermit(body)}';
  }
}

/// Registro tipo 2 — inclusão/alteração da identificação do empregador.
class AfdEmployerEvent {
  final int nsr;
  final DateTime recordedWall;
  final String responsibleCpf;
  final AfdEmployer employer;
  final int offsetMinutes;

  const AfdEmployerEvent({
    required this.nsr,
    required this.recordedWall,
    required this.responsibleCpf,
    required this.employer,
    required this.offsetMinutes,
  });

  String toLine() {
    final body = [
      AfdFmt.num(nsr, 9),
      '2',
      AfdFmt.dateTime(recordedWall, offsetMinutes),
      AfdFmt.num(Documents.onlyDigits(responsibleCpf), 14),
      AfdFmt.alpha(employer.documentType, 1),
      AfdFmt.num(employer.document, 14),
      AfdFmt.num(employer.cnoCaepf, 14),
      AfdFmt.alpha(employer.name, 150),
      AfdFmt.alpha(employer.location, 100),
    ].join();
    return '$body${crc16Kermit(body)}';
  }
}

/// Um registro do AFD já pronto para ordenação por NSR.
class AfdLine {
  final int nsr;
  final int type;
  final String line;
  const AfdLine(this.nsr, this.type, this.line);
}

/// Gerador do Arquivo Fonte de Dados (AFD) — Portaria MTP 671/2021, Anexo V,
/// leiaute 003, para REP-P.
class AfdGenerator {
  final AfdEmployer employer;
  final RepInfo rep;
  final int offsetMinutes;

  const AfdGenerator({
    required this.employer,
    this.rep = const RepInfo(),
    this.offsetMinutes = -180,
  });

  String header({
    required LocalDate start,
    required LocalDate end,
    required DateTime generatedWall,
  }) {
    final body = [
      '000000000',
      '1',
      AfdFmt.alpha(employer.documentType, 1),
      AfdFmt.num(employer.document, 14),
      AfdFmt.num(employer.cnoCaepf, 14),
      AfdFmt.alpha(employer.name, 150),
      AfdFmt.num(rep.inpiNumber, 17),
      AfdFmt.date(start),
      AfdFmt.date(end),
      AfdFmt.dateTime(generatedWall, offsetMinutes),
      '003',
      AfdFmt.alpha(rep.developerDocumentType, 1),
      AfdFmt.num(rep.developerDocument, 14),
      AfdFmt.alpha('', 30),
    ].join();
    return '$body${crc16Kermit(body)}';
  }

  String trailer(Map<int, int> counts) => [
        '999999999',
        for (final type in const [2, 3, 4, 5, 6, 7])
          AfdFmt.num(counts[type] ?? 0, 9),
        '9',
      ].join();

  /// Gera o arquivo completo (linhas separadas por CRLF).
  String generate({
    required LocalDate start,
    required LocalDate end,
    required DateTime generatedWall,
    required List<AfdLine> records,
  }) {
    final sorted = [...records]..sort((a, b) => a.nsr.compareTo(b.nsr));
    final counts = <int, int>{};
    for (final r in sorted) {
      counts[r.type] = (counts[r.type] ?? 0) + 1;
    }
    final lines = [
      header(start: start, end: end, generatedWall: generatedWall),
      for (final r in sorted) r.line,
      trailer(counts),
    ];
    return '${lines.join('\r\n')}\r\n';
  }

  /// Verifica a cadeia de hashes dos registros tipo 7 de um AFD.
  /// Retorna a lista de NSRs cujo hash não confere.
  ///
  /// Para um AFD parcial (período que não começa na primeira marcação), o
  /// primeiro registro é tomado como âncora, a menos que [initialHash] — o
  /// hash do registro tipo 7 anterior ao arquivo — seja informado.
  static List<int> verifyChain(String afd, {String? initialHash}) {
    final broken = <int>[];
    String? previous = initialHash;
    for (final raw in const LineSplitter().convert(afd)) {
      if (raw.length < 137 || raw[9] != '7') continue;
      final fields = raw.substring(0, 73);
      final hash = raw.substring(73, 137);
      if (previous != null) {
        final expected = sha256.convert(utf8.encode('$fields$previous')).toString();
        if (expected != hash) broken.add(int.parse(raw.substring(0, 9)));
      }
      previous = hash;
    }
    return broken;
  }
}
