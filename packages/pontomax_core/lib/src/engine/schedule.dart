import '../models/enums.dart';
import '../time/local_date.dart';

/// Período de trabalho esperado dentro de um dia, em minutos desde a
/// meia-noite do dia da jornada. `end` pode passar de 1440 (vira o dia).
class WorkInterval {
  final int start;
  final int end;

  const WorkInterval(this.start, this.end)
      : assert(end > start, 'O fim deve ser após o início');

  /// Cria a partir de `HH:MM`. Se o fim for menor que o início, considera
  /// que a jornada atravessa a meia-noite.
  factory WorkInterval.hm(String start, String end) {
    final s = TimeFmt.parseHm(start);
    var e = TimeFmt.parseHm(end);
    if (e <= s) e += 1440;
    return WorkInterval(s, e);
  }

  int get duration => end - start;

  List<String> toJson() => [TimeFmt.hm(start), TimeFmt.hm(end)];

  static WorkInterval fromJson(Object json) {
    if (json is List) {
      return WorkInterval.hm(json[0] as String, json[1] as String);
    }
    if (json is Map) {
      return WorkInterval.hm(json['start'] as String, json['end'] as String);
    }
    throw FormatException('Intervalo inválido: $json');
  }

  @override
  String toString() => '${TimeFmt.hm(start)}-${TimeFmt.hm(end)}';

  @override
  bool operator ==(Object other) =>
      other is WorkInterval && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Modelo de um dia da escala.
class DayTemplate {
  /// Dia de trabalho? `false` = folga/DSR.
  final bool workDay;

  /// Períodos de trabalho esperados (ordenados).
  final List<WorkInterval> intervals;

  /// Jornada flexível: carga esperada sem horários fixos.
  final int? flexibleMinutes;

  const DayTemplate({
    required this.workDay,
    this.intervals = const [],
    this.flexibleMinutes,
  });

  static const off = DayTemplate(workDay: false);

  factory DayTemplate.work(List<WorkInterval> intervals) =>
      DayTemplate(workDay: true, intervals: intervals);

  factory DayTemplate.flexible(int minutes) =>
      DayTemplate(workDay: true, flexibleMinutes: minutes);

  bool get hasFixedTimes => workDay && intervals.isNotEmpty;

  int get expectedMinutes {
    if (!workDay) return 0;
    if (flexibleMinutes != null) return flexibleMinutes!;
    return intervals.fold(0, (sum, i) => sum + i.duration);
  }

  int? get firstStart => intervals.isEmpty ? null : intervals.first.start;
  int? get lastEnd => intervals.isEmpty ? null : intervals.last.end;

  Map<String, Object?> toJson() => {
        'work': workDay,
        'intervals': [for (final i in intervals) i.toJson()],
        if (flexibleMinutes != null) 'flexible_minutes': flexibleMinutes,
      };

  factory DayTemplate.fromJson(Map<String, Object?> json) {
    final intervals = [
      for (final i in (json['intervals'] as List? ?? const []))
        WorkInterval.fromJson(i as Object),
    ]..sort((a, b) => a.start.compareTo(b.start));
    return DayTemplate(
      workDay: json['work'] as bool? ?? intervals.isNotEmpty,
      intervals: intervals,
      flexibleMinutes: (json['flexible_minutes'] as num?)?.toInt(),
    );
  }

  String describe() {
    if (!workDay) return 'Folga';
    if (flexibleMinutes != null) {
      return 'Flexível ${TimeFmt.minutes(flexibleMinutes!)}';
    }
    return intervals.map((i) => i.toString()).join(' / ');
  }
}

/// Faixa de hora extra em dias úteis (ex.: até 120 min a 50%, depois 100%).
class OvertimeBand {
  /// Limite acumulado de minutos da faixa (`null` = sem limite).
  final int? upTo;
  final int rate;
  const OvertimeBand(this.upTo, this.rate);

  Map<String, Object?> toJson() => {'up_to': upTo, 'rate': rate};

  factory OvertimeBand.fromJson(Map<String, Object?> j) =>
      OvertimeBand((j['up_to'] as num?)?.toInt(), (j['rate'] as num?)?.toInt() ?? 50);

  @override
  bool operator ==(Object other) => other is OvertimeBand && other.upTo == upTo && other.rate == rate;

  @override
  int get hashCode => Object.hash(upTo, rate);
}

/// Definição completa de uma escala de trabalho e suas regras de cálculo.
class ScheduleDefinition {
  final String id;
  final String name;
  final ScheduleType type;

  /// Semanal: 7 itens (índice 0 = segunda ... 6 = domingo).
  /// Cíclica: N itens que se repetem a partir de [cycleAnchor].
  final List<DayTemplate> days;
  final LocalDate? cycleAnchor;

  /// Tolerância por marcação (art. 58 §1º CLT: 5 min).
  final int tolerancePerMark;

  /// Tolerância diária total (art. 58 §1º CLT: 10 min).
  final int toleranceDaily;

  /// Descanso mínimo entre jornadas (art. 66 CLT: 11h).
  final int minInterjourney;

  final CompensationRegime regime;

  /// Regime híbrido: limite diário de minutos que vão para o banco.
  final int hybridDailyBankLimit;

  /// Percentual de hora extra em dias úteis.
  final int overtimeRateWeekday;

  /// Percentual de hora extra em folgas e feriados.
  final int overtimeRateRestDay;

  /// Faixas progressivas de hora extra em dias úteis (vazio = taxa única).
  final List<OvertimeBand> overtimeBands;

  /// Intervalos pré-assinalados: o colaborador marca só entrada e saída.
  final bool preAssignedBreak;

  /// Aplica a hora noturna reduzida (52min30s) — art. 73 §1º CLT.
  final bool nightReduced;

  /// Prorrogação da jornada noturna (Súmula 60 TST).
  final bool extendNightShift;

  /// Início da janela noturna (padrão 22:00) e fim (padrão 05:00), em minutos.
  final int nightStart;
  final int nightEnd;

  /// Faltas/atrasos debitam o banco mesmo no regime de horas extras.
  final bool deductAbsencesFromBank;

  /// Sobrescreve o início da janela que define a qual dia pertence uma
  /// marcação (minutos relativos à meia-noite; pode ser negativo).
  final int? dayWindowStart;

  const ScheduleDefinition({
    this.id = '',
    this.name = '',
    this.type = ScheduleType.weekly,
    required this.days,
    this.cycleAnchor,
    this.tolerancePerMark = 5,
    this.toleranceDaily = 10,
    this.minInterjourney = 660,
    this.regime = CompensationRegime.overtime,
    this.hybridDailyBankLimit = 120,
    this.overtimeRateWeekday = 50,
    this.overtimeRateRestDay = 100,
    this.overtimeBands = const [],
    this.preAssignedBreak = false,
    this.nightReduced = true,
    this.extendNightShift = true,
    this.nightStart = 22 * 60,
    this.nightEnd = 5 * 60,
    this.deductAbsencesFromBank = false,
    this.dayWindowStart,
  });

  /// Escala comercial padrão: seg-sex 08:00-12:00 / 13:00-17:00 (40h).
  factory ScheduleDefinition.standard44({
    String id = '',
    String name = 'Comercial 44h',
    CompensationRegime regime = CompensationRegime.overtime,
  }) {
    final weekday = DayTemplate.work([
      WorkInterval.hm('08:00', '12:00'),
      WorkInterval.hm('13:00', '18:00'),
    ]);
    final friday = DayTemplate.work([
      WorkInterval.hm('08:00', '12:00'),
      WorkInterval.hm('13:00', '17:00'),
    ]);
    return ScheduleDefinition(
      id: id,
      name: name,
      regime: regime,
      days: [
        weekday,
        weekday,
        weekday,
        weekday,
        friday,
        DayTemplate.off,
        DayTemplate.off
      ],
    );
  }

  /// Escala 12x36 a partir de [anchor] (trabalha no dia âncora).
  factory ScheduleDefinition.twelveByThirtySix({
    required LocalDate anchor,
    String id = '',
    String name = '12x36',
    String start = '07:00',
    String end = '19:00',
    CompensationRegime regime = CompensationRegime.overtime,
  }) {
    return ScheduleDefinition(
      id: id,
      name: name,
      type: ScheduleType.cycle,
      cycleAnchor: anchor,
      regime: regime,
      days: [
        DayTemplate.work([WorkInterval.hm(start, end)]),
        DayTemplate.off,
      ],
    );
  }

  DayTemplate templateFor(LocalDate date) {
    if (days.isEmpty) return DayTemplate.off;
    switch (type) {
      case ScheduleType.weekly:
        return days[(date.weekday - 1) % days.length];
      case ScheduleType.cycle:
        final anchor = cycleAnchor ?? const LocalDate(2024, 1, 1);
        final diff = date.differenceInDays(anchor);
        final idx = ((diff % days.length) + days.length) % days.length;
        return days[idx];
    }
  }

  /// Minuto (relativo à meia-noite de [date]) em que começa a janela de
  /// apuração do dia. Marcações entre o início desta janela e o início da
  /// janela do dia seguinte pertencem a [date].
  int windowStartFor(LocalDate date) {
    if (dayWindowStart != null) return dayWindowStart!;
    final t = templateFor(date);
    final first = t.firstStart;
    if (t.workDay && first != null) return first - 240;
    return _defaultWindowStart;
  }

  int get _defaultWindowStart {
    int? min;
    for (final d in days) {
      final f = d.firstStart;
      if (d.workDay && f != null && (min == null || f < min)) min = f;
    }
    return min == null ? 0 : min - 240;
  }

  /// Distribui [minutes] de hora extra pelas faixas (dias úteis) ou pela
  /// taxa única. Em folgas/feriados usa [overtimeRateRestDay].
  Map<int, int> splitOvertime(int minutes, {required bool restDay}) {
    if (minutes <= 0) return {};
    if (restDay) return {overtimeRateRestDay: minutes};
    if (overtimeBands.isEmpty) return {overtimeRateWeekday: minutes};
    final result = <int, int>{};
    var remaining = minutes;
    var consumed = 0;
    for (final b in overtimeBands) {
      if (remaining <= 0) break;
      final cap = b.upTo == null ? remaining : (b.upTo! - consumed).clamp(0, remaining);
      if (cap <= 0) continue;
      result[b.rate] = (result[b.rate] ?? 0) + cap;
      remaining -= cap;
      consumed += cap;
    }
    if (remaining > 0) {
      final last = overtimeBands.last.rate;
      result[last] = (result[last] ?? 0) + remaining;
    }
    return result;
  }

  /// Carga semanal média (em minutos) — útil para exibição.
  int get weeklyMinutes {
    if (days.isEmpty) return 0;
    final total = days.fold<int>(0, (s, d) => s + d.expectedMinutes);
    return type == ScheduleType.weekly
        ? total
        : (total * 7 / days.length).round();
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'type': type.code,
        'days': [for (final d in days) d.toJson()],
        'cycle_anchor': cycleAnchor?.toString(),
        'tolerance_per_mark': tolerancePerMark,
        'tolerance_daily': toleranceDaily,
        'min_interjourney': minInterjourney,
        'regime': regime.code,
        'hybrid_daily_bank_limit': hybridDailyBankLimit,
        'overtime_rate_weekday': overtimeRateWeekday,
        'overtime_rate_rest_day': overtimeRateRestDay,
        'overtime_bands': [for (final b in overtimeBands) b.toJson()],
        'pre_assigned_break': preAssignedBreak,
        'night_reduced': nightReduced,
        'extend_night_shift': extendNightShift,
        'night_start': TimeFmt.hm(nightStart),
        'night_end': TimeFmt.hm(nightEnd),
        'deduct_absences_from_bank': deductAbsencesFromBank,
        'day_window_start': dayWindowStart,
      };

  factory ScheduleDefinition.fromJson(Map<String, Object?> json) {
    int intOr(String key, int fallback) =>
        (json[key] as num?)?.toInt() ?? fallback;
    int hmOr(String key, int fallback) {
      final v = json[key];
      if (v is String && v.isNotEmpty) return TimeFmt.parseHm(v);
      if (v is num) return v.toInt();
      return fallback;
    }

    return ScheduleDefinition(
      id: json['id']?.toString() ?? '',
      name: json['name'] as String? ?? '',
      type: ScheduleType.fromCode(json['type'] as String?),
      days: [
        for (final d in (json['days'] as List? ?? const []))
          DayTemplate.fromJson((d as Map).cast<String, Object?>()),
      ],
      cycleAnchor: LocalDate.tryParse(json['cycle_anchor'] as String?),
      tolerancePerMark: intOr('tolerance_per_mark', 5),
      toleranceDaily: intOr('tolerance_daily', 10),
      minInterjourney: intOr('min_interjourney', 660),
      regime: CompensationRegime.fromCode(json['regime'] as String?),
      hybridDailyBankLimit: intOr('hybrid_daily_bank_limit', 120),
      overtimeRateWeekday: intOr('overtime_rate_weekday', 50),
      overtimeRateRestDay: intOr('overtime_rate_rest_day', 100),
      overtimeBands: [
        for (final b in (json['overtime_bands'] as List? ?? const []))
          OvertimeBand.fromJson((b as Map).cast<String, Object?>()),
      ],
      preAssignedBreak: json['pre_assigned_break'] as bool? ?? false,
      nightReduced: json['night_reduced'] as bool? ?? true,
      extendNightShift: json['extend_night_shift'] as bool? ?? true,
      nightStart: hmOr('night_start', 22 * 60),
      nightEnd: hmOr('night_end', 5 * 60),
      deductAbsencesFromBank:
          json['deduct_absences_from_bank'] as bool? ?? false,
      dayWindowStart: (json['day_window_start'] as num?)?.toInt(),
    );
  }

  ScheduleDefinition copyWith({
    String? id,
    String? name,
    ScheduleType? type,
    List<DayTemplate>? days,
    LocalDate? cycleAnchor,
    int? tolerancePerMark,
    int? toleranceDaily,
    int? minInterjourney,
    CompensationRegime? regime,
    int? hybridDailyBankLimit,
    int? overtimeRateWeekday,
    int? overtimeRateRestDay,
    List<OvertimeBand>? overtimeBands,
    bool? preAssignedBreak,
    bool? nightReduced,
    bool? extendNightShift,
    bool? deductAbsencesFromBank,
  }) =>
      ScheduleDefinition(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
        days: days ?? this.days,
        cycleAnchor: cycleAnchor ?? this.cycleAnchor,
        tolerancePerMark: tolerancePerMark ?? this.tolerancePerMark,
        toleranceDaily: toleranceDaily ?? this.toleranceDaily,
        minInterjourney: minInterjourney ?? this.minInterjourney,
        regime: regime ?? this.regime,
        hybridDailyBankLimit: hybridDailyBankLimit ?? this.hybridDailyBankLimit,
        overtimeRateWeekday: overtimeRateWeekday ?? this.overtimeRateWeekday,
        overtimeRateRestDay: overtimeRateRestDay ?? this.overtimeRateRestDay,
        overtimeBands: overtimeBands ?? this.overtimeBands,
        preAssignedBreak: preAssignedBreak ?? this.preAssignedBreak,
        nightReduced: nightReduced ?? this.nightReduced,
        extendNightShift: extendNightShift ?? this.extendNightShift,
        nightStart: nightStart,
        nightEnd: nightEnd,
        deductAbsencesFromBank:
            deductAbsencesFromBank ?? this.deductAbsencesFromBank,
        dayWindowStart: dayWindowStart,
      );
}
