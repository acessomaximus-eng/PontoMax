import 'package:pontomax_core/pontomax_core.dart';
import 'package:test/test.dart';

DateTime w(int y, int m, int d, int h, int min) =>
    DateTime.utc(y, m, d, h, min);

/// Segunda-feira, 5 de outubro de 2026.
const monday = LocalDate(2026, 10, 5);
final later = DateTime.utc(2026, 12, 31, 12);

List<EnginePunch> punches(LocalDate d, List<String> times,
    {int dayOffset = 0}) {
  final result = <EnginePunch>[];
  var offset = dayOffset;
  int? previous;
  for (final t in times) {
    final m = TimeFmt.parseHm(t);
    if (previous != null && m < previous) offset++;
    previous = m;
    result.add(
        EnginePunch(d.addDays(offset).toDateTime().add(Duration(minutes: m))));
  }
  return result;
}

DayResult day(
  ScheduleDefinition s,
  LocalDate d,
  List<String> times, {
  List<Holiday> holidays = const [],
  List<Absence> absences = const [],
  DateTime? now,
  LocalDate? admission,
}) {
  final calc = JourneyCalculator(
    schedule: s,
    holidays: holidays,
    absences: absences,
    admission: admission,
  );
  return calc
      .calculate(from: d, to: d, punches: punches(d, times), now: now ?? later)
      .days
      .single;
}

void main() {
  final std = ScheduleDefinition.standard44();

  group('Jornada padrão 44h', () {
    test('marcações exatas não geram saldo', () {
      final r = day(std, monday, ['08:00', '12:00', '13:00', '18:00']);
      expect(r.status, DayStatus.normal);
      expect(r.expected, 540);
      expect(r.worked, 540);
      expect(r.balance, 0);
      expect(r.overtime, isEmpty);
      expect(r.deficit, 0);
      expect(r.issues, isEmpty);
    });

    test('variações dentro da tolerância (5/10 min) são desconsideradas', () {
      final r = day(std, monday, ['07:57', '12:03', '13:02', '18:01']);
      expect(r.worked, 540 + 3 + 3 - 2 + 1);
      expect(r.balance, 0);
      expect(r.late, 0);
    });

    test('ultrapassada a tolerância, todo o tempo é computado (Súmula 366)',
        () {
      final r = day(std, monday, ['08:07', '12:00', '13:00', '18:00']);
      expect(r.balance, -7);
      expect(r.deficit, 7);
      expect(r.late, 7);
      expect(r.hasIssue(IssueType.late), isTrue);
    });

    test('soma das variações acima de 10 min também quebra a tolerância', () {
      final r = day(std, monday, ['07:56', '12:04', '12:56', '18:04']);
      // Cada variação ≤ 5, mas soma = 16 > 10.
      expect(r.balance, 16);
      expect(r.overtime[50], 16);
    });

    test('hora extra em dia útil a 50%', () {
      final r = day(std, monday, ['08:00', '12:00', '13:00', '19:00']);
      expect(r.balance, 60);
      expect(r.overtime, {50: 60});
      expect(r.earlyLeave, 0);
    });

    test('mais de 2h extras aponta inconsistência (art. 59)', () {
      final r = day(std, monday, ['08:00', '12:00', '13:00', '21:00']);
      expect(r.overtime[50], 180);
      expect(r.hasIssue(IssueType.overtimeLimit), isTrue);
    });

    test('falta em dia útil', () {
      final r = day(std, monday, []);
      expect(r.status, DayStatus.absent);
      expect(r.deficit, 540);
      expect(r.hasIssue(IssueType.absent), isTrue);
    });

    test('trabalho no sábado (folga) é hora extra a 100%', () {
      final saturday = monday.addDays(5);
      final r = day(std, saturday, ['08:00', '12:00']);
      expect(r.expected, 0);
      expect(r.overtime, {100: 240});
    });

    test('folga sem marcações', () {
      final r = day(std, monday.addDays(6), []);
      expect(r.status, DayStatus.dayOff);
      expect(r.deficit, 0);
    });

    test('feriado trabalhado é hora extra a 100%', () {
      final r = day(std, monday, ['08:00', '12:00'],
          holidays: [const Holiday(monday, 'Feriado municipal')]);
      expect(r.expected, 0);
      expect(r.overtime, {100: 240});
      expect(r.holidayName, 'Feriado municipal');
    });

    test('feriado sem marcações', () {
      final r = day(std, monday, [], holidays: [const Holiday(monday, 'X')]);
      expect(r.status, DayStatus.holiday);
      expect(r.deficit, 0);
    });

    test('marcação ímpar fica incompleta', () {
      final r = day(std, monday, ['08:00', '12:00', '13:00']);
      expect(r.status, DayStatus.incomplete);
      expect(r.hasIssue(IssueType.missingPunch), isTrue);
      expect(r.worked, 240);
    });

    test('intervalo intrajornada inferior a 1h', () {
      final r = day(std, monday, ['08:00', '12:00', '12:30', '17:30']);
      expect(r.hasIssue(IssueType.intrajourney), isTrue);
    });

    test('jornada sem intervalo', () {
      final r = day(std, monday, ['08:00', '17:00']);
      expect(r.hasIssue(IssueType.intrajourney), isTrue);
    });

    test('dia em andamento não gera falta', () {
      final r = day(std, monday, ['08:00'], now: w(2026, 10, 5, 10, 0));
      expect(r.status, DayStatus.open);
      expect(r.deficit, 0);
      expect(r.issues, isEmpty);
    });

    test('dia futuro não gera falta', () {
      final r = day(std, monday, [], now: w(2026, 10, 1, 10, 0));
      expect(r.status, DayStatus.open);
      expect(r.deficit, 0);
    });

    test('antes da admissão não há vínculo', () {
      final r = day(std, monday, [], admission: monday.addDays(1));
      expect(r.status, DayStatus.notEmployed);
      expect(r.expected, 0);
    });
  });

  group('Ausências e abonos', () {
    test('atestado de dia inteiro abona a falta', () {
      final r = day(std, monday, [], absences: [
        const Absence(start: monday, end: monday, type: AbsenceType.medical),
      ]);
      expect(r.status, DayStatus.excused);
      expect(r.excused, 540);
      expect(r.deficit, 0);
    });

    test('férias zeram as horas esperadas', () {
      final r = day(std, monday, [], absences: [
        Absence(
            start: monday, end: monday.addDays(10), type: AbsenceType.vacation),
      ]);
      expect(r.status, DayStatus.vacation);
      expect(r.expected, 0);
      expect(r.deficit, 0);
    });

    test('abono parcial cobre o atraso', () {
      final r = day(std, monday, [
        '10:00',
        '12:00',
        '13:00',
        '18:00'
      ], absences: [
        const Absence(
            start: monday,
            end: monday,
            type: AbsenceType.allowance,
            minutesPerDay: 120),
      ]);
      expect(r.excused, 120);
      expect(r.balance, 0);
      expect(r.late, 0);
      expect(r.deficit, 0);
    });

    test('folga de banco de horas debita o banco mesmo no regime de extras',
        () {
      final r = day(std, monday, [], absences: [
        const Absence(start: monday, end: monday, type: AbsenceType.bankDayOff),
      ]);
      expect(r.status, DayStatus.bankDayOff);
      expect(r.bankDelta, -540);
      expect(r.deficit, 0);
    });
  });

  group('Regimes de compensação', () {
    test('banco de horas acumula crédito e débito', () {
      final s =
          ScheduleDefinition.standard44(regime: CompensationRegime.hourBank);
      expect(
          day(s, monday, ['08:00', '12:00', '13:00', '19:00']).bankDelta, 60);
      expect(
          day(s, monday, ['08:00', '12:00', '13:00', '17:00']).bankDelta, -60);
      final r = day(s, monday, ['08:00', '12:00', '13:00', '19:00']);
      expect(r.overtime, isEmpty);
    });

    test('híbrido: banco até o limite diário e excedente como extra', () {
      final s =
          ScheduleDefinition.standard44(regime: CompensationRegime.hybrid);
      final r = day(s, monday, ['08:00', '12:00', '13:00', '21:00']);
      expect(r.bankDelta, 120);
      expect(r.overtime, {50: 60});
    });

    test('abater faltas do banco no regime de extras', () {
      final s = ScheduleDefinition.standard44()
          .copyWith(deductAbsencesFromBank: true);
      final r = day(s, monday, []);
      expect(r.deficit, 0);
      expect(r.bankDelta, -540);
    });
  });

  group('Jornada noturna', () {
    final night = ScheduleDefinition(
      days:
          List.filled(7, DayTemplate.work([WorkInterval.hm('22:00', '05:00')])),
    );

    test('hora noturna reduzida (52m30s)', () {
      final r = day(night, monday, ['22:00', '05:00']);
      expect(r.worked, 420);
      expect(r.nightMinutes, 420);
      expect(r.nightMinutesReduced, 480);
    });

    test('marcação após a meia-noite pertence ao dia de início da jornada', () {
      final calc = JourneyCalculator(schedule: night);
      final res = calc.calculate(
        from: monday,
        to: monday.addDays(1),
        punches: punches(monday, ['22:00', '05:00']),
        now: later,
      );
      expect(res.days[0].worked, 420);
      expect(res.days[1].worked, 0);
    });

    test('prorrogação da jornada noturna (Súmula 60)', () {
      final r = day(night, monday, ['22:00', '07:00']);
      expect(r.nightMinutes, 540);
    });

    test('jornada diurna com parte noturna', () {
      final r = day(std, monday, ['08:00', '12:00', '13:00', '23:00']);
      expect(r.nightMinutes, 60);
      expect(r.nightMinutesReduced, 69);
    });
  });

  group('Escala 12x36', () {
    final s = ScheduleDefinition.twelveByThirtySix(anchor: monday);

    test('alterna dias de trabalho e folga', () {
      expect(s.templateFor(monday).workDay, isTrue);
      expect(s.templateFor(monday.addDays(1)).workDay, isFalse);
      expect(s.templateFor(monday.addDays(2)).workDay, isTrue);
      expect(s.templateFor(monday.addDays(-1)).workDay, isFalse);
      expect(s.templateFor(monday.addDays(-2)).workDay, isTrue);
    });

    test('12h trabalhadas sem saldo', () {
      final r = day(s, monday, ['07:00', '19:00']);
      expect(r.expected, 720);
      expect(r.balance, 0);
    });
  });

  group('Interjornada', () {
    test('descanso inferior a 11h é apontado', () {
      final calc = JourneyCalculator(schedule: std);
      final res = calc.calculate(
        from: monday,
        to: monday.addDays(1),
        punches: [
          ...punches(monday, ['08:00', '12:00', '13:00', '23:00']),
          ...punches(monday.addDays(1), ['08:00', '12:00', '13:00', '18:00']),
        ],
        now: later,
      );
      final issue = res.days[1].issues
          .firstWhere((i) => i.type == IssueType.interjourney);
      expect(issue.minutes, 120);
    });
  });

  group('Pré-assinalado', () {
    test('insere o intervalo automaticamente', () {
      final s =
          ScheduleDefinition.standard44().copyWith(preAssignedBreak: true);
      final r = day(s, monday, ['08:00', '18:00']);
      expect(r.punches.length, 4);
      expect(r.punches[1].origin, PunchOrigin.preAssigned);
      expect(r.worked, 540);
      expect(r.balance, 0);
    });
  });

  group('Marcações desconsideradas', () {
    test('não entram no cálculo', () {
      final calc = JourneyCalculator(schedule: std);
      final list =
          punches(monday, ['08:00', '08:01', '12:00', '13:00', '18:00']);
      final withDisregard = [
        list[0],
        EnginePunch(list[1].time, disregarded: true),
        ...list.sublist(2),
      ];
      final r = calc
          .calculate(
              from: monday, to: monday, punches: withDisregard, now: later)
          .days
          .single;
      expect(r.status, DayStatus.normal);
      expect(r.worked, 540);
    });
  });

  group('Totais do período', () {
    test('somam os dias', () {
      final calc = JourneyCalculator(schedule: std);
      final res = calc.calculate(
        from: monday,
        to: monday.addDays(6),
        punches: [
          ...punches(monday, ['08:00', '12:00', '13:00', '19:00']),
          ...punches(monday.addDays(1), ['08:00', '12:00', '13:00', '18:00']),
          // quarta: falta
          ...punches(monday.addDays(3), ['08:00', '12:00', '13:00', '18:00']),
          ...punches(monday.addDays(4), ['08:00', '12:00', '13:00', '17:00']),
        ],
        now: later,
      );
      expect(res.totals.absences, 1);
      expect(res.totals.overtime[50], 60);
      expect(res.totals.deficit, 540);
      expect(res.totals.expected, 540 * 4 + 480);
    });
  });

  group('Serialização da escala', () {
    test('ida e volta em JSON', () {
      final s = ScheduleDefinition.twelveByThirtySix(
          anchor: monday, regime: CompensationRegime.hybrid);
      final back = ScheduleDefinition.fromJson(s.toJson());
      expect(back.type, ScheduleType.cycle);
      expect(back.cycleAnchor, monday);
      expect(back.regime, CompensationRegime.hybrid);
      expect(
          back.days.first.intervals.first, WorkInterval.hm('07:00', '19:00'));
      expect(back.days[1].workDay, isFalse);
    });

    test('intervalo que vira a meia-noite', () {
      final i = WorkInterval.hm('22:00', '06:00');
      expect(i.duration, 480);
      expect(WorkInterval.fromJson(i.toJson()), i);
    });
  });
}
