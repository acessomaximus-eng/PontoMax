import '../time/local_date.dart';
import '../validators/documents.dart';

/// Conteúdo do Comprovante de Registro de Ponto do Trabalhador
/// (Portaria 671, art. 80 e Anexo IX para REP-P).
class PunchReceipt {
  final String employerName;
  final String employerDocument;
  final String? employerCnoCaepf;
  final String? location;
  final String inpiNumber;
  final String employeeName;
  final String employeeCpf;
  final DateTime punchWall;
  final int offsetMinutes;
  final int nsr;
  final String hash;
  final String collectorLabel;
  final bool offline;
  final double? latitude;
  final double? longitude;

  const PunchReceipt({
    required this.employerName,
    required this.employerDocument,
    this.employerCnoCaepf,
    this.location,
    required this.inpiNumber,
    required this.employeeName,
    required this.employeeCpf,
    required this.punchWall,
    required this.offsetMinutes,
    required this.nsr,
    required this.hash,
    required this.collectorLabel,
    required this.offline,
    this.latitude,
    this.longitude,
  });

  static const title = 'Comprovante de Registro de Ponto do Trabalhador';

  /// Linhas (rótulo, valor) na ordem de exibição.
  List<(String, String)> fields() => [
        ('Empregador', employerName),
        (
          Documents.onlyAlnum(employerDocument).length == 11 ? 'CPF' : 'CNPJ',
          Documents.formatDocument(employerDocument),
        ),
        if (employerCnoCaepf != null && employerCnoCaepf!.isNotEmpty)
          ('CNO/CAEPF', employerCnoCaepf!),
        if (location != null && location!.isNotEmpty)
          ('Local de prestação de serviço', location!),
        ('Nº de registro do REP-P (INPI)', inpiNumber),
        ('Trabalhador', employeeName),
        ('CPF do trabalhador', Documents.formatCpf(employeeCpf)),
        (
          'Data e horário',
          '${LocalDate.fromDateTime(punchWall).toBr()} '
              '${TimeFmt.clock(punchWall)} (UTC${TimeFmt.offset(offsetMinutes, colon: true)})',
        ),
        ('NSR', nsr.toString().padLeft(9, '0')),
        ('Coletor', '$collectorLabel${offline ? ' (off-line)' : ''}'),
        if (latitude != null && longitude != null)
          (
            'Localização',
            '${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}'
          ),
        ('Código hash (SHA-256)', hash),
      ];

  String toText() {
    final b = StringBuffer()
      ..writeln(title)
      ..writeln('=' * title.length);
    for (final (k, v) in fields()) {
      b.writeln('$k: $v');
    }
    return b.toString();
  }
}
