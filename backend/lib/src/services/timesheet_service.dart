import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../app.dart';
import '../db/database.dart';
import '../http/http_utils.dart';

/// Dados carregados para apurar um colaborador.
class MemberTimesheetContext {
  final Row member;
  final Row company;
  final ScheduleDefinition schedule;
  final int offset;
  MemberTimesheetContext(this.member, this.company, this.schedule, this.offset);

  CompanySettings get settings => CompanySettings.fromJson((company['settings'] as Map).cast<String, Object?>());
}

class BankSummary {
  final int initial;
  final int computed;
  final int manual;
  final Map<String, int> monthly;
  final LocalDate since;
  final List<Row> entries;
  final BankLedgerResult ledger;
  final int validityMonths;
  const BankSummary(this.initial, this.computed, this.manual, this.monthly, this.since, this.entries, this.ledger,
      this.validityMonths);

  /// Saldo atual (sem os créditos vencidos, que devem ser pagos).
  int get balance => ledger.balance;
}

/// Dados de um colaborador carregados em lote (relatórios da empresa), para
/// apurar sem novas consultas ao banco.
class MemberPreload {
  final List<Holiday> holidays;
  final List<Absence> absences;

  /// Marcações ordenadas por horário (inclusive desconsideradas).
  final List<EnginePunch> punches;
  final List<Row>? bankEntries;
  const MemberPreload(this.holidays, this.absences, this.punches, this.bankEntries);

  /// Marcações usadas na apuração de `[from, to]` (mesma janela de [TimesheetService.punches]).
  List<EnginePunch> punchesFor(LocalDate from, LocalDate to) {
    final start = from.addDays(-2).toDateTime();
    final end = to.addDays(3).toDateTime();
    return [
      for (final p in punches)
        if (!p.time.isBefore(start) && p.time.isBefore(end)) p,
    ];
  }
}

/// Apuração de um colaborador em um relatório da empresa.
class MemberPeriod {
  final MemberTimesheetContext ctx;
  final PeriodResult result;
  final BankSummary? bank;
  const MemberPeriod(this.ctx, this.result, this.bank);

  String get memberId => ctx.member['id'] as String;
}

/// Adapta o motor de cálculo do núcleo aos dados do banco.
class TimesheetService {
  final App app;
  TimesheetService(this.app);

  /// Colaboradores apurados por lote de consultas nos relatórios da empresa.
  static const batchSize = 50;

  Future<MemberTimesheetContext> context(String memberId, {String? companyId}) async {
    final m = await app.db.one(
      '''
      SELECT m.*, u.name, u.cpf, u.email
      FROM members m JOIN users u ON u.id = m.user_id
      WHERE m.id = @m AND (@c::uuid IS NULL OR m.company_id = @c::uuid)''',
      {'m': requireUuid(memberId, 'member_id'), 'c': companyId},
    );
    if (m == null) throw const ApiError.notFound('Colaborador não encontrado');
    final company = (await app.db.one('SELECT * FROM companies WHERE id = @c', {'c': m['company_id']}))!;
    final schedule = await scheduleFor(m['company_id'] as String, m['schedule_id'] as String?, company);
    return MemberTimesheetContext(m, company, schedule, company['utc_offset_minutes'] as int);
  }

  /// Escala do colaborador, ou a padrão da empresa, ou 44h comercial.
  Future<ScheduleDefinition> scheduleFor(String companyId, String? scheduleId, Row company) async {
    final settings = (company['settings'] as Map?) ?? {};
    final id = scheduleId ?? settings['default_schedule_id'] as String?;
    Row? row;
    if (id != null) {
      row = await app.db.one('SELECT * FROM schedules WHERE id = @id', {'id': id});
    }
    row ??= await app.db.one(
      'SELECT * FROM schedules WHERE company_id = @c AND active ORDER BY created_at LIMIT 1',
      {'c': companyId},
    );
    if (row == null) return ScheduleDefinition.standard44();
    return ScheduleDefinition.fromJson({
      ...(row['definition'] as Map).cast<String, Object?>(),
      'id': row['id'],
      'name': row['name'],
    });
  }

  /// Resolve escalas da empresa com uma única consulta (mesma regra de [scheduleFor]).
  Future<ScheduleDefinition Function(String?)> scheduleResolver(String companyId, Row company) async {
    final rows = await app.db.query(
      'SELECT * FROM schedules WHERE company_id = @c ORDER BY created_at',
      {'c': companyId},
    );
    final byId = {for (final r in rows) r['id'] as String: r};
    final fallback = rows.where((r) => r['active'] == true).firstOrNull;
    final defaultId = ((company['settings'] as Map?) ?? {})['default_schedule_id'] as String?;
    final cache = <String, ScheduleDefinition>{};
    return (scheduleId) {
      final id = scheduleId ?? defaultId;
      final row = (id == null ? null : byId[id]) ?? fallback;
      if (row == null) return ScheduleDefinition.standard44();
      return cache[row['id'] as String] ??= ScheduleDefinition.fromJson({
        ...(row['definition'] as Map).cast<String, Object?>(),
        'id': row['id'],
        'name': row['name'],
      });
    };
  }

  Future<List<Holiday>> holidays(String companyId, LocalDate from, LocalDate to) async {
    final rows = await app.db.query(
      'SELECT date, name, recurring FROM holidays WHERE company_id = @c AND (recurring OR date BETWEEN @f AND @t)',
      {'c': companyId, 'f': from.toString(), 't': to.toString()},
    );
    final result = <Holiday>[];
    for (final r in rows) {
      final d = LocalDate.fromDateTime(r['date'] as DateTime);
      if (r['recurring'] == true) {
        for (var y = from.year; y <= to.year; y++) {
          final candidate = LocalDate(y, d.month, d.month == 2 && d.day == 29 ? 28 : d.day);
          if (candidate >= from && candidate <= to) result.add(Holiday(candidate, r['name'] as String));
        }
      } else {
        result.add(Holiday(d, r['name'] as String));
      }
    }
    return result;
  }

  Future<List<Absence>> absences(String memberId, LocalDate from, LocalDate to) async {
    final rows = await app.db.query(
      'SELECT * FROM absences WHERE member_id = @m AND start_date <= @t AND end_date >= @f',
      {'m': memberId, 'f': from.toString(), 't': to.toString()},
    );
    return [for (final r in rows) _absence(r)];
  }

  Absence _absence(Row r) => Absence(
        start: LocalDate.fromDateTime(r['start_date'] as DateTime),
        end: LocalDate.fromDateTime(r['end_date'] as DateTime),
        type: AbsenceType.fromCode(r['type'] as String?),
        minutesPerDay: r['minutes_per_day'] as int?,
        reason: r['reason'] as String?,
      );

  EnginePunch _punch(Row r, int offset) => EnginePunch(
        TimeFmt.toWall(r['punched_at'] as DateTime, offset),
        id: r['id'] as String,
        origin: PunchOrigin.fromCode(r['origin'] as String?),
        disregarded: r['disregarded'] as bool,
      );

  Future<List<EnginePunch>> punches(String memberId, LocalDate from, LocalDate to, int offset) async {
    final start = TimeFmt.fromWall(from.addDays(-2).toDateTime(), offset);
    final end = TimeFmt.fromWall(to.addDays(3).toDateTime(), offset);
    final rows = await app.db.query(
      'SELECT id, punched_at, origin, disregarded FROM punches '
      'WHERE member_id = @m AND punched_at >= @s AND punched_at < @e ORDER BY punched_at',
      {'m': memberId, 's': start, 'e': end},
    );
    return [for (final r in rows) _punch(r, offset)];
  }

  LocalDate? _date(Object? v) => v is DateTime ? LocalDate.fromDateTime(v) : null;

  /// Apura o período `[from, to]` de um colaborador.
  Future<PeriodResult> period(String memberId, LocalDate from, LocalDate to,
      {MemberTimesheetContext? ctx, MemberPreload? preload}) async {
    if (to < from) throw const ApiError.badRequest('Período inválido');
    if (to.differenceInDays(from) > 400) throw const ApiError.badRequest('Período máximo de 400 dias');
    final c = ctx ?? await context(memberId);
    final companyId = c.member['company_id'] as String;
    final calc = JourneyCalculator(
      schedule: c.schedule,
      holidays: preload?.holidays ?? await holidays(companyId, from.addDays(-1), to.addDays(1)),
      absences: preload?.absences ?? await absences(memberId, from, to),
      admission: _date(c.member['admission_date']),
      dismissal: _date(c.member['dismissal_date']),
    );
    return calc.calculate(
      from: from,
      to: to,
      punches: preload?.punchesFor(from, to) ?? await punches(memberId, from, to, c.offset),
      now: TimeFmt.toWall(app.now(), c.offset),
    );
  }

  /// Saldo do banco de horas desde a admissão (ou criação do vínculo).
  Future<BankSummary> bank(String memberId, {MemberTimesheetContext? ctx, MemberPreload? preload}) async {
    final c = ctx ?? await context(memberId);
    final today = _today(c.offset);
    final since = _bankSince(c, today);

    final monthly = <String, int>{};
    final movements = <BankMovement>[];
    var computed = 0;
    var cursor = since;
    while (cursor <= today) {
      var end = cursor.addDays(399);
      if (end > today) end = today;
      final result = await period(memberId, cursor, end, ctx: c, preload: preload);
      for (final d in result.days) {
        if (d.bankDelta == 0) continue;
        computed += d.bankDelta;
        movements.add(BankMovement(d.date, d.bankDelta));
        final key = d.date.toString().substring(0, 7);
        monthly[key] = (monthly[key] ?? 0) + d.bankDelta;
      }
      cursor = end.addDays(1);
    }
    final entries = preload?.bankEntries ??
        await app.db.query(
          '$_bankEntriesSql WHERE b.member_id = @m ORDER BY b.date DESC, b.created_at DESC',
          {'m': memberId},
        );
    var manual = 0;
    for (final e in entries) {
      manual += e['minutes'] as int;
      movements.add(BankMovement(
        LocalDate.fromDateTime(e['date'] as DateTime),
        e['minutes'] as int,
        payment: e['type'] == BankEntryType.payment.code,
      ));
      final key = LocalDate.fromDateTime(e['date'] as DateTime).toString().substring(0, 7);
      monthly[key] = (monthly[key] ?? 0) + (e['minutes'] as int);
    }
    final initial = c.member['initial_bank_minutes'] as int? ?? 0;
    if (initial != 0) movements.add(BankMovement(since, initial));
    final validity = c.settings.bankValidityMonths;
    final ledger = BankLedger.compute(movements, validityMonths: validity, today: today);
    return BankSummary(initial, computed, manual, monthly, since, entries, ledger, validity);
  }

  static const _bankEntriesSql = '''
      SELECT b.*, u.name AS created_by_name FROM bank_entries b
      LEFT JOIN members cm ON cm.id = b.created_by LEFT JOIN users u ON u.id = cm.user_id''';

  LocalDate _today(int offset) => LocalDate.fromDateTime(TimeFmt.toWall(app.now(), offset));

  /// Início da apuração automática do banco: admissão (ou criação do vínculo),
  /// início do banco na empresa e no máximo os últimos 2 anos.
  LocalDate _bankSince(MemberTimesheetContext c, LocalDate today) {
    final created = LocalDate.fromDateTime(TimeFmt.toWall(c.member['created_at'] as DateTime, c.offset));
    var since = _date(c.member['admission_date']) ?? created;
    final settings = (c.company['settings'] as Map?) ?? {};
    final bankStart = LocalDate.tryParse(settings['bank_start_date'] as String?);
    if (bankStart != null && bankStart > since) since = bankStart;
    final limit = today.addDays(-730);
    if (since < limit) since = limit;
    return since;
  }

  /// Apura vários colaboradores da empresa com poucas consultas (em lotes de
  /// [batchSize]), na ordem de [memberIds]. IDs inexistentes são ignorados.
  Future<List<MemberPeriod>> periodMany(String companyId, List<String> memberIds, LocalDate from, LocalDate to,
      {bool includeBank = false, int batch = batchSize}) async {
    if (memberIds.isEmpty) return const [];
    if (to < from) throw const ApiError.badRequest('Período inválido');
    final company = await app.db.one('SELECT * FROM companies WHERE id = @c', {'c': companyId});
    if (company == null) throw const ApiError.notFound('Empresa não encontrada');
    final offset = company['utc_offset_minutes'] as int;
    final today = _today(offset);
    final schedule = await scheduleResolver(companyId, company);
    final out = <MemberPeriod>[];
    for (var i = 0; i < memberIds.length; i += batch) {
      final ids = memberIds.sublist(i, i + batch > memberIds.length ? memberIds.length : i + batch);
      final rows = await app.db.query(
        '''
        SELECT m.*, u.name, u.cpf, u.email
        FROM members m JOIN users u ON u.id = m.user_id
        WHERE m.company_id = @c AND m.id = ANY(@ids::uuid[])''',
        {'c': companyId, 'ids': ids},
      );
      final byId = {for (final r in rows) r['id'] as String: r};
      final contexts = [
        for (final id in ids)
          if (byId[id] case final m?) MemberTimesheetContext(m, company, schedule(m['schedule_id'] as String?), offset),
      ];
      if (contexts.isEmpty) continue;
      final present = [for (final c in contexts) c.member['id'] as String];

      // Intervalo coberto: o período pedido e, com banco, desde o início do banco até hoje.
      var start = from, end = to;
      if (includeBank) {
        for (final c in contexts) {
          final since = _bankSince(c, today);
          if (since < start) start = since;
        }
        if (today > end) end = today;
      }
      final hol = await holidays(companyId, start.addDays(-1), end.addDays(1));
      final absences = <String, List<Absence>>{};
      for (final r in await app.db.query(
        'SELECT * FROM absences WHERE member_id = ANY(@ids::uuid[]) AND start_date <= @t AND end_date >= @f',
        {'ids': present, 'f': start.toString(), 't': end.toString()},
      )) {
        (absences[r['member_id'] as String] ??= []).add(_absence(r));
      }
      // Uma linha por colaborador com as marcações em arrays: decodificar
      // milhares de linhas individuais é o gargalo dos relatórios grandes.
      final punches = <String, List<EnginePunch>>{};
      for (final r in await app.db.query(
        '''
        SELECT member_id,
          array_agg(floor(extract(epoch FROM punched_at) * 1000000)::bigint ORDER BY punched_at) AS t,
          array_agg(id::text ORDER BY punched_at) AS i,
          array_agg(origin ORDER BY punched_at) AS o,
          array_agg(disregarded ORDER BY punched_at) AS d
        FROM punches
        WHERE member_id = ANY(@ids::uuid[]) AND punched_at >= @s AND punched_at < @e
        GROUP BY member_id''',
        {
          'ids': present,
          's': TimeFmt.fromWall(start.addDays(-2).toDateTime(), offset),
          'e': TimeFmt.fromWall(end.addDays(3).toDateTime(), offset),
        },
      )) {
        final t = r['t'] as List, ids = r['i'] as List, o = r['o'] as List, d = r['d'] as List;
        punches[r['member_id'] as String] = [
          for (var k = 0; k < t.length; k++)
            EnginePunch(
              TimeFmt.toWall(DateTime.fromMicrosecondsSinceEpoch(t[k] as int, isUtc: true), offset),
              id: ids[k] as String,
              origin: PunchOrigin.fromCode(o[k] as String?),
              disregarded: d[k] as bool,
            ),
        ];
      }
      final entries = <String, List<Row>>{};
      if (includeBank) {
        for (final r in await app.db.query(
          '$_bankEntriesSql WHERE b.member_id = ANY(@ids::uuid[]) ORDER BY b.date DESC, b.created_at DESC',
          {'ids': present},
        )) {
          (entries[r['member_id'] as String] ??= []).add(r);
        }
      }
      for (final c in contexts) {
        final id = c.member['id'] as String;
        final preload = MemberPreload(hol, absences[id] ?? const [], punches[id] ?? const [], entries[id] ?? const []);
        out.add(MemberPeriod(
          c,
          await period(id, from, to, ctx: c, preload: preload),
          includeBank ? await bank(id, ctx: c, preload: preload) : null,
        ));
      }
    }
    return out;
  }

  /// Hash do espelho (para assinatura eletrônica do colaborador).
  String timesheetHash(PeriodResult r, String memberId) {
    final payload = jsonEncode({'member': memberId, ...r.toJson()});
    return sha256.convert(utf8.encode(payload)).toString();
  }
}
