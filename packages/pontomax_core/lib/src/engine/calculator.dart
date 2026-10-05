import 'dart:math' as math;

import '../models/enums.dart';
import '../time/local_date.dart';
import 'schedule.dart';

/// Marcação usada pelo motor de cálculo. [time] é sempre "relógio de parede"
/// no fuso da empresa (DateTime UTC ingênuo).
class EnginePunch {
  final String? id;
  final DateTime time;
  final PunchOrigin origin;
  final bool disregarded;

  EnginePunch(
    DateTime time, {
    this.id,
    this.origin = PunchOrigin.original,
    this.disregarded = false,
  }) : time = TimeFmt.truncateToMinute(time);

  Map<String, Object?> toJson() => {
        'id': id,
        'time': time.toIso8601String(),
        'origin': origin.code,
        'disregarded': disregarded,
      };
}

class Holiday {
  final LocalDate date;
  final String name;
  const Holiday(this.date, this.name);
}

/// Ausência/abono em um intervalo de datas.
class Absence {
  final LocalDate start;
  final LocalDate end;
  final AbsenceType type;

  /// Minutos abonados por dia (`null` = dia inteiro).
  final int? minutesPerDay;
  final String? reason;

  const Absence({
    required this.start,
    required this.end,
    required this.type,
    this.minutesPerDay,
    this.reason,
  });

  bool covers(LocalDate d) => d >= start && d <= end;
  bool get fullDay => minutesPerDay == null;
}

class WorkedPair {
  final DateTime start;
  final DateTime end;
  const WorkedPair(this.start, this.end);
  int get minutes => end.difference(start).inMinutes;

  Map<String, Object?> toJson() => {
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'minutes': minutes,
      };
}

class DayIssue {
  final IssueType type;

  /// Valor associado (ex.: minutos faltantes de interjornada).
  final int? minutes;
  const DayIssue(this.type, [this.minutes]);

  Map<String, Object?> toJson() =>
      {'type': type.code, 'label': type.label, 'minutes': minutes};
}

/// Resultado do cálculo de um dia.
class DayResult {
  final LocalDate date;
  final DayStatus status;
  final DayTemplate template;
  final String? holidayName;
  final List<EnginePunch> punches;
  final List<WorkedPair> pairs;
  final int expected;
  final int worked;
  final int excused;

  /// Saldo após tolerância (positivo = excedente, negativo = falta/atraso).
  final int balance;

  /// Horas extras por percentual (ex.: {50: 30, 100: 60}).
  final Map<int, int> overtime;

  /// Minutos descontados (faltas/atrasos) no regime de horas extras.
  final int deficit;

  /// Movimento do banco de horas neste dia.
  final int bankDelta;
  final int nightMinutes;
  final int nightMinutesReduced;
  final int late;
  final int earlyLeave;
  final List<DayIssue> issues;

  /// Dia ainda não encerrado (não gera falta).
  final bool open;

  const DayResult({
    required this.date,
    required this.status,
    required this.template,
    this.holidayName,
    required this.punches,
    required this.pairs,
    required this.expected,
    required this.worked,
    required this.excused,
    required this.balance,
    required this.overtime,
    required this.deficit,
    required this.bankDelta,
    required this.nightMinutes,
    required this.nightMinutesReduced,
    required this.late,
    required this.earlyLeave,
    required this.issues,
    required this.open,
  });

  int get overtimeTotal => overtime.values.fold(0, (a, b) => a + b);
  bool get isRestDay => !template.workDay || holidayName != null;
  bool hasIssue(IssueType t) => issues.any((i) => i.type == t);

  Map<String, Object?> toJson() => {
        'date': date.toString(),
        'weekday': date.weekday,
        'status': status.code,
        'status_label': status.label,
        'template': template.toJson(),
        'template_label': template.describe(),
        'holiday': holidayName,
        'punches': [for (final p in punches) p.toJson()],
        'pairs': [for (final p in pairs) p.toJson()],
        'expected': expected,
        'worked': worked,
        'excused': excused,
        'balance': balance,
        'overtime': {for (final e in overtime.entries) '${e.key}': e.value},
        'overtime_total': overtimeTotal,
        'deficit': deficit,
        'bank_delta': bankDelta,
        'night_minutes': nightMinutes,
        'night_minutes_reduced': nightMinutesReduced,
        'late': late,
        'early_leave': earlyLeave,
        'issues': [for (final i in issues) i.toJson()],
        'open': open,
      };
}

class PeriodTotals {
  final int expected;
  final int worked;
  final int excused;
  final Map<int, int> overtime;
  final int deficit;
  final int bankDelta;
  final int nightMinutes;
  final int nightMinutesReduced;
  final int late;
  final int earlyLeave;
  final int absences;
  final int issues;

  const PeriodTotals({
    required this.expected,
    required this.worked,
    required this.excused,
    required this.overtime,
    required this.deficit,
    required this.bankDelta,
    required this.nightMinutes,
    required this.nightMinutesReduced,
    required this.late,
    required this.earlyLeave,
    required this.absences,
    required this.issues,
  });

  int get overtimeTotal => overtime.values.fold(0, (a, b) => a + b);

  factory PeriodTotals.of(Iterable<DayResult> days) {
    var expected = 0, worked = 0, excused = 0, deficit = 0, bank = 0;
    var night = 0, nightR = 0, late = 0, early = 0, absences = 0, issues = 0;
    final overtime = <int, int>{};
    for (final d in days) {
      expected += d.expected;
      worked += d.worked;
      excused += d.excused;
      deficit += d.deficit;
      bank += d.bankDelta;
      night += d.nightMinutes;
      nightR += d.nightMinutesReduced;
      late += d.late;
      early += d.earlyLeave;
      if (d.status == DayStatus.absent) absences++;
      issues += d.issues.length;
      d.overtime
          .forEach((rate, m) => overtime[rate] = (overtime[rate] ?? 0) + m);
    }
    return PeriodTotals(
      expected: expected,
      worked: worked,
      excused: excused,
      overtime: overtime,
      deficit: deficit,
      bankDelta: bank,
      nightMinutes: night,
      nightMinutesReduced: nightR,
      late: late,
      earlyLeave: early,
      absences: absences,
      issues: issues,
    );
  }

  Map<String, Object?> toJson() => {
        'expected': expected,
        'worked': worked,
        'excused': excused,
        'overtime': {for (final e in overtime.entries) '${e.key}': e.value},
        'overtime_total': overtimeTotal,
        'deficit': deficit,
        'bank_delta': bankDelta,
        'night_minutes': nightMinutes,
        'night_minutes_reduced': nightMinutesReduced,
        'late': late,
        'early_leave': earlyLeave,
        'absences': absences,
        'issues': issues,
      };
}

class PeriodResult {
  final LocalDate from;
  final LocalDate to;
  final List<DayResult> days;
  final PeriodTotals totals;

  PeriodResult(this.from, this.to, this.days) : totals = PeriodTotals.of(days);

  Map<String, Object?> toJson() => {
        'from': from.toString(),
        'to': to.toString(),
        'days': [for (final d in days) d.toJson()],
        'totals': totals.toJson(),
      };
}

/// Motor de apuração de jornada conforme CLT.
///
/// Regras implementadas:
/// * Tolerância de 5 min por marcação e 10 min diários (art. 58 §1º, Súmula 366 TST).
/// * Hora noturna reduzida de 52m30s e prorrogação (art. 73, Súmula 60 TST).
/// * Interjornada mínima (art. 66) e intrajornada (art. 71).
/// * Limite de 2h extras diárias (art. 59) — apontado como inconsistência.
/// * Regimes: horas extras, banco de horas e híbrido.
/// * Feriados, folgas, abonos, atestados, férias e afastamentos.
/// * Intervalos pré-assinalados.
class JourneyCalculator {
  final ScheduleDefinition schedule;
  final List<Holiday> holidays;
  final List<Absence> absences;
  final LocalDate? admission;
  final LocalDate? dismissal;

  /// Escalas alternativas por data (troca de escala no período).
  final ScheduleDefinition Function(LocalDate date)? scheduleResolver;

  JourneyCalculator({
    required this.schedule,
    this.holidays = const [],
    this.absences = const [],
    this.admission,
    this.dismissal,
    this.scheduleResolver,
  });

  ScheduleDefinition _scheduleFor(LocalDate d) =>
      scheduleResolver?.call(d) ?? schedule;

  DateTime _windowStart(LocalDate d) =>
      d.toDateTime().add(Duration(minutes: _scheduleFor(d).windowStartFor(d)));

  /// Janela de apuração `[início, fim)` de um dia.
  (DateTime, DateTime) windowFor(LocalDate d) =>
      (_windowStart(d), _windowStart(d.addDays(1)));

  /// Calcula o período `[from, to]`. [punches] pode conter marcações fora do
  /// período (ex.: do dia anterior) — elas são usadas para a interjornada.
  /// [now] é o "relógio de parede" atual no fuso da empresa.
  PeriodResult calculate({
    required LocalDate from,
    required LocalDate to,
    required List<EnginePunch> punches,
    required DateTime now,
  }) {
    final valid = punches.where((p) => !p.disregarded).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    final holidayMap = {for (final h in holidays) h.date: h.name};
    final days = <DayResult>[];

    for (final date in LocalDate.range(from, to)) {
      final (ws, we) = windowFor(date);
      final dayPunches = [
        for (final p in valid)
          if (!p.time.isBefore(ws) && p.time.isBefore(we)) p,
      ];
      DateTime? previousEnd;
      if (dayPunches.isNotEmpty) {
        for (final p in valid) {
          if (p.time.isBefore(ws)) {
            previousEnd = p.time;
          } else {
            break;
          }
        }
      }
      days.add(_calculateDay(
        date: date,
        punches: dayPunches,
        holidayName: holidayMap[date],
        windowStart: ws,
        windowEnd: we,
        now: now,
        previousJourneyEnd: previousEnd,
      ));
    }
    return PeriodResult(from, to, days);
  }

  DayResult _calculateDay({
    required LocalDate date,
    required List<EnginePunch> punches,
    required String? holidayName,
    required DateTime windowStart,
    required DateTime windowEnd,
    required DateTime now,
    required DateTime? previousJourneyEnd,
  }) {
    final sched = _scheduleFor(date);
    final template = sched.templateFor(date);
    final base = date.toDateTime();
    final issues = <DayIssue>[];

    // Fora do vínculo empregatício.
    if ((admission != null && date < admission!) ||
        (dismissal != null && date > dismissal!)) {
      return _empty(
          date, template, DayStatus.notEmployed, holidayName, punches);
    }

    final dayAbsences = absences.where((a) => a.covers(date)).toList();
    final fullAbsence = dayAbsences.where((a) => a.fullDay).firstOrNull;
    final isRestDay = !template.workDay || holidayName != null;
    final future = now.isBefore(windowStart);
    final open = !future && now.isBefore(windowEnd);

    // Marcações pré-assinaladas.
    final effective = [...punches];
    if (sched.preAssignedBreak &&
        template.intervals.length >= 2 &&
        effective.length == 2) {
      for (var i = 0; i < template.intervals.length - 1; i++) {
        final bs = base.add(Duration(minutes: template.intervals[i].end));
        final be = base.add(Duration(minutes: template.intervals[i + 1].start));
        if (effective.first.time.isBefore(bs) &&
            be.isBefore(effective.last.time)) {
          effective.insert(effective.length - 1,
              EnginePunch(bs, origin: PunchOrigin.preAssigned));
          effective.insert(effective.length - 1,
              EnginePunch(be, origin: PunchOrigin.preAssigned));
        }
      }
      effective.sort((a, b) => a.time.compareTo(b.time));
    }

    // Pares entrada/saída.
    final pairs = <WorkedPair>[];
    for (var i = 0; i + 1 < effective.length; i += 2) {
      pairs.add(WorkedPair(effective[i].time, effective[i + 1].time));
    }
    final oddPunches = effective.length.isOdd;
    if (oddPunches && !open) issues.add(const DayIssue(IssueType.missingPunch));
    final worked = pairs.fold<int>(0, (s, p) => s + p.minutes);

    // Horas esperadas.
    var expected = isRestDay ? 0 : template.expectedMinutes;
    if (fullAbsence != null && fullAbsence.type.zeroesExpected) expected = 0;

    // Abonos.
    var excused = 0;
    if (expected > 0) {
      for (final a in dayAbsences) {
        if (!a.type.excuses) continue;
        excused += a.fullDay ? expected : a.minutesPerDay!;
      }
      excused = math.min(excused, math.max(0, expected - worked));
    }

    // Tolerância (art. 58 §1º) e atrasos.
    final rawBalance = worked + excused - expected;
    var late = 0, earlyLeave = 0;
    var withinTolerance = false;
    if (!isRestDay && expected > 0 && pairs.isNotEmpty && !oddPunches) {
      if (template.hasFixedTimes && pairs.length == template.intervals.length) {
        var sum = 0;
        var allSmall = true;
        for (var i = 0; i < pairs.length; i++) {
          final es = base.add(Duration(minutes: template.intervals[i].start));
          final ee = base.add(Duration(minutes: template.intervals[i].end));
          final v1 = pairs[i].start.difference(es).inMinutes.abs();
          final v2 = pairs[i].end.difference(ee).inMinutes.abs();
          sum += v1 + v2;
          if (v1 > sched.tolerancePerMark || v2 > sched.tolerancePerMark) {
            allSmall = false;
          }
        }
        withinTolerance = allSmall && sum <= sched.toleranceDaily;
      } else if (!template.hasFixedTimes) {
        withinTolerance = rawBalance.abs() <= sched.toleranceDaily;
      }
      if (template.hasFixedTimes && !withinTolerance) {
        final es = base.add(Duration(minutes: template.firstStart!));
        final ee = base.add(Duration(minutes: template.lastEnd!));
        late = math.max(0, pairs.first.start.difference(es).inMinutes);
        earlyLeave = math.max(0, ee.difference(pairs.last.end).inMinutes);
      }
    }
    var balance = withinTolerance ? 0 : rawBalance;
    if (excused > 0 && late + earlyLeave > 0) {
      // O abono cobre primeiro atrasos/saídas antecipadas.
      final covered = math.min(excused, late + earlyLeave);
      final lateCovered = math.min(late, covered);
      late -= lateCovered;
      earlyLeave -= math.min(earlyLeave, covered - lateCovered);
    }

    // Dias em andamento ou futuros não geram falta.
    if ((open || future) && balance < 0) {
      balance = 0;
      late = 0;
      earlyLeave = 0;
    }

    // Regime de compensação.
    final overtime = <int, int>{};
    var deficit = 0;
    var bankDelta = 0;
    final positive = math.max(0, balance);
    final negative = math.max(0, -balance);
    final rate =
        isRestDay ? sched.overtimeRateRestDay : sched.overtimeRateWeekday;
    final bankDayOff = dayAbsences.any((a) => a.type == AbsenceType.bankDayOff);

    switch (sched.regime) {
      case CompensationRegime.overtime:
        if (positive > 0) overtime[rate] = positive;
        if (negative > 0) {
          if (sched.deductAbsencesFromBank || bankDayOff) {
            bankDelta = -negative;
          } else {
            deficit = negative;
          }
        }
      case CompensationRegime.hourBank:
        bankDelta = balance;
      case CompensationRegime.hybrid:
        final toBank = math.min(positive, sched.hybridDailyBankLimit);
        if (positive - toBank > 0) overtime[rate] = positive - toBank;
        bankDelta = toBank - negative;
    }

    // Adicional noturno.
    final (night, nightReduced) = _night(pairs, sched);

    // Inconsistências legais.
    if (previousJourneyEnd != null && effective.isNotEmpty) {
      final rest =
          effective.first.time.difference(previousJourneyEnd).inMinutes;
      if (rest < sched.minInterjourney) {
        issues.add(
            DayIssue(IssueType.interjourney, sched.minInterjourney - rest));
      }
    }
    if (pairs.isNotEmpty && !oddPunches) {
      var maxBreak = 0;
      for (var i = 0; i + 1 < pairs.length; i++) {
        maxBreak = math.max(
            maxBreak, pairs[i + 1].start.difference(pairs[i].end).inMinutes);
      }
      // A tolerância por marcação também se aplica ao retorno do intervalo.
      final tol = sched.tolerancePerMark;
      if (worked > 360 && maxBreak < 60 - tol) {
        issues.add(DayIssue(IssueType.intrajourney, 60 - maxBreak));
      } else if (worked > 240 && worked <= 360 && maxBreak < 15 - tol) {
        issues.add(DayIssue(IssueType.intrajourney, 15 - maxBreak));
      }
    }
    final extraToday = positive;
    if (!isRestDay && extraToday > 120) {
      issues.add(DayIssue(IssueType.overtimeLimit, extraToday - 120));
    }
    if (late > 0) issues.add(DayIssue(IssueType.late, late));
    if (earlyLeave > 0) issues.add(DayIssue(IssueType.earlyLeave, earlyLeave));

    // Situação do dia.
    DayStatus status;
    if (effective.isEmpty) {
      if (fullAbsence != null) {
        status = switch (fullAbsence.type) {
          AbsenceType.vacation => DayStatus.vacation,
          AbsenceType.leave => DayStatus.leave,
          AbsenceType.bankDayOff => DayStatus.bankDayOff,
          _ => DayStatus.excused,
        };
      } else if (holidayName != null) {
        status = DayStatus.holiday;
      } else if (!template.workDay) {
        status = DayStatus.dayOff;
      } else if (open || future) {
        status = DayStatus.open;
      } else if (excused >= expected && expected > 0) {
        status = DayStatus.excused;
      } else {
        status = DayStatus.absent;
        issues.add(const DayIssue(IssueType.absent));
      }
    } else if (open) {
      status = DayStatus.open;
    } else if (oddPunches) {
      status = DayStatus.incomplete;
    } else {
      status = DayStatus.normal;
    }

    return DayResult(
      date: date,
      status: status,
      template: template,
      holidayName: holidayName,
      punches: effective,
      pairs: pairs,
      expected: expected,
      worked: worked,
      excused: excused,
      balance: balance,
      overtime: overtime,
      deficit: deficit,
      bankDelta: bankDelta,
      nightMinutes: night,
      nightMinutesReduced: nightReduced,
      late: late,
      earlyLeave: earlyLeave,
      issues: issues,
      open: open || future,
    );
  }

  /// Minutos noturnos (reais, reduzidos).
  (int, int) _night(List<WorkedPair> pairs, ScheduleDefinition sched) {
    if (pairs.isEmpty) return (0, 0);
    var real = 0;
    final nightLen = (sched.nightEnd - sched.nightStart) % 1440;
    DateTime? lastNightWindowEnd;
    for (final p in pairs) {
      // Janelas noturnas que podem tocar o par: a partir do dia anterior.
      var day = LocalDate.fromDateTime(p.start).addDays(-1);
      final lastDay = LocalDate.fromDateTime(p.end);
      while (day <= lastDay) {
        final ns = day.toDateTime().add(Duration(minutes: sched.nightStart));
        final ne = ns.add(Duration(minutes: nightLen));
        final s = p.start.isAfter(ns) ? p.start : ns;
        final e = p.end.isBefore(ne) ? p.end : ne;
        if (e.isAfter(s)) {
          real += e.difference(s).inMinutes;
          lastNightWindowEnd = ne;
        }
        day = day.addDays(1);
      }
    }
    // Súmula 60, II: jornada integralmente noturna e prorrogada.
    if (sched.extendNightShift && lastNightWindowEnd != null) {
      final ns = lastNightWindowEnd.subtract(Duration(minutes: nightLen));
      final first = pairs.first.start;
      final last = pairs.last.end;
      if (!first.isAfter(ns) && last.isAfter(lastNightWindowEnd)) {
        for (final p in pairs) {
          final s = p.start.isAfter(lastNightWindowEnd)
              ? p.start
              : lastNightWindowEnd;
          if (p.end.isAfter(s)) real += p.end.difference(s).inMinutes;
        }
      }
    }
    final reduced = sched.nightReduced ? (real * 60 / 52.5).round() : real;
    return (real, reduced);
  }

  DayResult _empty(LocalDate date, DayTemplate template, DayStatus status,
          String? holidayName, List<EnginePunch> punches) =>
      DayResult(
        date: date,
        status: status,
        template: template,
        holidayName: holidayName,
        punches: punches,
        pairs: const [],
        expected: 0,
        worked: 0,
        excused: 0,
        balance: 0,
        overtime: const {},
        deficit: 0,
        bankDelta: 0,
        nightMinutes: 0,
        nightMinutesReduced: 0,
        late: 0,
        earlyLeave: 0,
        issues: const [],
        open: false,
      );
}
