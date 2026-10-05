import '../engine/schedule.dart';
import '../time/local_date.dart';
import '../validators/documents.dart';
import 'afd.dart';

/// Vínculo (colaborador) no AEJ.
class AejEmployee {
  final String id;
  final String cpf;
  final String name;
  final String? esocialRegistration;
  const AejEmployee({
    required this.id,
    required this.cpf,
    required this.name,
    this.esocialRegistration,
  });
}

/// Horário contratual (registro 04).
class AejContractSchedule {
  final String code;
  final int durationMinutes;
  final List<WorkInterval> intervals;
  const AejContractSchedule(this.code, this.durationMinutes, this.intervals);
}

/// Marcação tratada (registro 05).
class AejPunch {
  final String employeeId;
  final DateTime wall;

  /// `E` entrada, `S` saída, `D` desconsiderada.
  final String type;
  final int sequence;

  /// Fonte: `O`, `I`, `P`, `X`, `T`.
  final String source;
  final String? scheduleCode;
  final String? reason;
  const AejPunch({
    required this.employeeId,
    required this.wall,
    required this.type,
    required this.sequence,
    required this.source,
    this.scheduleCode,
    this.reason,
  });
}

/// Ausência ou movimentação do banco de horas (registro 07).
class AejAbsence {
  final String employeeId;

  /// 1 = DSR, 2 = falta não justificada, 3 = movimento banco de horas,
  /// 4 = folga compensatória de feriado.
  final int type;
  final LocalDate date;
  final int minutes;

  /// Para tipo 3: 1 = inclusão de horas, 2 = compensação.
  final int? bankMovement;
  const AejAbsence({
    required this.employeeId,
    required this.type,
    required this.date,
    required this.minutes,
    this.bankMovement,
  });
}

/// Gerador do Arquivo Eletrônico de Jornada (AEJ) — Portaria 671, Anexo VI.
class AejGenerator {
  final AfdEmployer employer;
  final RepInfo rep;
  final int offsetMinutes;

  const AejGenerator({
    required this.employer,
    this.rep = const RepInfo(),
    this.offsetMinutes = -180,
  });

  String _clean(String? v) =>
      (v ?? '').replaceAll(RegExp(r'[\r\n|]'), ' ').trim();

  String generate({
    required LocalDate start,
    required LocalDate end,
    required DateTime generatedWall,
    required List<AejEmployee> employees,
    required List<AejContractSchedule> schedules,
    required List<AejPunch> punches,
    List<AejAbsence> absences = const [],
  }) {
    final lines = <String>[];
    final counts = List<int>.filled(9, 0);
    void add(int type, List<Object?> fields) {
      counts[type]++;
      lines.add(fields.map((f) => _clean(f?.toString())).join('|'));
    }

    add(1, [
      '01',
      employer.documentType,
      Documents.onlyAlnum(employer.document),
      employer.documentType == '2' ? employer.cnoCaepf : '',
      employer.documentType == '1' ? employer.cnoCaepf : '',
      employer.name,
      start.toString(),
      end.toString(),
      AfdFmt.dateTime(generatedWall, offsetMinutes),
      '001',
    ]);
    add(2, ['02', '1', '3', AfdFmt.num(rep.inpiNumber, 17)]);
    for (final e in employees) {
      add(3, ['03', e.id, Documents.onlyDigits(e.cpf), e.name]);
    }
    for (final s in schedules) {
      add(4, [
        '04',
        s.code,
        s.durationMinutes,
        for (final i in s.intervals) ...[
          _hhmm(i.start),
          _hhmm(i.end),
        ],
      ]);
    }
    final sortedPunches = [...punches]..sort((a, b) {
        final c = a.employeeId.compareTo(b.employeeId);
        return c != 0 ? c : a.wall.compareTo(b.wall);
      });
    for (final p in sortedPunches) {
      add(5, [
        '05',
        p.employeeId,
        AfdFmt.dateTime(p.wall, offsetMinutes),
        '1',
        p.type,
        p.sequence,
        p.source,
        p.scheduleCode ?? '',
        p.reason ?? '',
      ]);
    }
    for (final e in employees) {
      if (e.esocialRegistration != null && e.esocialRegistration!.isNotEmpty) {
        add(6, ['06', e.id, e.esocialRegistration]);
      }
    }
    for (final a in absences) {
      add(7, [
        '07',
        a.employeeId,
        a.type,
        a.date.toString(),
        a.minutes,
        a.bankMovement ?? '',
      ]);
    }
    add(8, [
      '08',
      rep.softwareName,
      rep.softwareVersion,
      rep.developerDocumentType,
      Documents.onlyAlnum(rep.developerDocument),
      rep.developerName,
      rep.developerEmail,
    ]);
    lines.add(['99', for (var i = 1; i <= 8; i++) counts[i]].join('|'));
    return '${lines.join('\r\n')}\r\n';
  }

  static String _hhmm(int minutes) {
    final v = minutes % 1440;
    return '${(v ~/ 60).toString().padLeft(2, '0')}${(v % 60).toString().padLeft(2, '0')}';
  }
}
