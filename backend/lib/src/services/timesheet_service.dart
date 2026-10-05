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

  CompanySettings get settings =>
      CompanySettings.fromJson((company['settings'] as Map).cast<String, Object?>());
}

class BankSummary {
  final int initial;
  final int computed;
  final int manual;
  final Map<String, int> monthly;
  final LocalDate since;
  final List<Row> entries;
  const BankSummary(this.initial, this.computed, this.manual, this.monthly, this.since, this.entries);
  int get balance => initial + computed + manual;
}

/// Adapta o motor de cálculo do núcleo aos dados do banco.
class TimesheetService {
  final App app;
  TimesheetService(this.app);

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
    return [
      for (final r in rows)
        Absence(
          start: LocalDate.fromDateTime(r['start_date'] as DateTime),
          end: LocalDate.fromDateTime(r['end_date'] as DateTime),
          type: AbsenceType.fromCode(r['type'] as String?),
          minutesPerDay: r['minutes_per_day'] as int?,
          reason: r['reason'] as String?,
        ),
    ];
  }

  Future<List<EnginePunch>> punches(String memberId, LocalDate from, LocalDate to, int offset) async {
    final start = TimeFmt.fromWall(from.addDays(-2).toDateTime(), offset);
    final end = TimeFmt.fromWall(to.addDays(3).toDateTime(), offset);
    final rows = await app.db.query(
      'SELECT id, punched_at, origin, disregarded FROM punches '
      'WHERE member_id = @m AND punched_at >= @s AND punched_at < @e ORDER BY punched_at',
      {'m': memberId, 's': start, 'e': end},
    );
    return [
      for (final r in rows)
        EnginePunch(
          TimeFmt.toWall(r['punched_at'] as DateTime, offset),
          id: r['id'] as String,
          origin: PunchOrigin.fromCode(r['origin'] as String?),
          disregarded: r['disregarded'] as bool,
        ),
    ];
  }

  LocalDate? _date(Object? v) => v is DateTime ? LocalDate.fromDateTime(v) : null;

  /// Apura o período `[from, to]` de um colaborador.
  Future<PeriodResult> period(String memberId, LocalDate from, LocalDate to,
      {MemberTimesheetContext? ctx}) async {
    if (to < from) throw const ApiError.badRequest('Período inválido');
    if (to.differenceInDays(from) > 400) throw const ApiError.badRequest('Período máximo de 400 dias');
    final c = ctx ?? await context(memberId);
    final companyId = c.member['company_id'] as String;
    final calc = JourneyCalculator(
      schedule: c.schedule,
      holidays: await holidays(companyId, from.addDays(-1), to.addDays(1)),
      absences: await absences(memberId, from, to),
      admission: _date(c.member['admission_date']),
      dismissal: _date(c.member['dismissal_date']),
    );
    return calc.calculate(
      from: from,
      to: to,
      punches: await punches(memberId, from, to, c.offset),
      now: TimeFmt.toWall(app.now(), c.offset),
    );
  }

  /// Saldo do banco de horas desde a admissão (ou criação do vínculo).
  Future<BankSummary> bank(String memberId, {MemberTimesheetContext? ctx}) async {
    final c = ctx ?? await context(memberId);
    final today = LocalDate.fromDateTime(TimeFmt.toWall(app.now(), c.offset));
    final created = LocalDate.fromDateTime(TimeFmt.toWall(c.member['created_at'] as DateTime, c.offset));
    var since = _date(c.member['admission_date']) ?? created;
    final settings = (c.company['settings'] as Map?) ?? {};
    final bankStart = LocalDate.tryParse(settings['bank_start_date'] as String?);
    if (bankStart != null && bankStart > since) since = bankStart;
    // Limita a apuração automática aos últimos 2 anos.
    final limit = today.addDays(-730);
    if (since < limit) since = limit;

    final monthly = <String, int>{};
    var computed = 0;
    var cursor = since;
    while (cursor <= today) {
      var end = cursor.addDays(399);
      if (end > today) end = today;
      final result = await period(memberId, cursor, end, ctx: c);
      for (final d in result.days) {
        if (d.bankDelta == 0) continue;
        computed += d.bankDelta;
        final key = d.date.toString().substring(0, 7);
        monthly[key] = (monthly[key] ?? 0) + d.bankDelta;
      }
      cursor = end.addDays(1);
    }
    final entries = await app.db.query(
      '''
      SELECT b.*, u.name AS created_by_name FROM bank_entries b
      LEFT JOIN members cm ON cm.id = b.created_by LEFT JOIN users u ON u.id = cm.user_id
      WHERE b.member_id = @m ORDER BY b.date DESC, b.created_at DESC''',
      {'m': memberId},
    );
    var manual = 0;
    for (final e in entries) {
      manual += e['minutes'] as int;
      final key = LocalDate.fromDateTime(e['date'] as DateTime).toString().substring(0, 7);
      monthly[key] = (monthly[key] ?? 0) + (e['minutes'] as int);
    }
    return BankSummary(c.member['initial_bank_minutes'] as int? ?? 0, computed, manual, monthly, since, entries);
  }

  /// Hash do espelho (para assinatura eletrônica do colaborador).
  String timesheetHash(PeriodResult r, String memberId) {
    final payload = jsonEncode({'member': memberId, ...r.toJson()});
    return sha256.convert(utf8.encode(payload)).toString();
  }
}
