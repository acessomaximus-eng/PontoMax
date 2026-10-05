import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/session.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';
import '../services/report_service.dart';
import '../signing/cms.dart';

/// Espelho de ponto, assinatura, relatórios, exportações legais e dashboard.
class ReportRoutes {
  final App app;
  ReportRoutes(this.app);
  Mappers get map => Mappers(app);

  Router get router => Router()
    ..get('/timesheet', _timesheet)
    ..get('/timesheet.pdf', _timesheetPdf)
    ..post('/timesheet/sign', _sign)
    ..get('/timesheet/signatures', _signatures)
    ..get('/reports/summary', _summary)
    ..get('/reports/summary.csv', _summaryCsv)
    ..get('/reports/payroll.csv', _payrollCsv)
    ..get('/reports/punches.csv', _punchesCsv)
    ..get('/reports/afd', _afd)
    ..get('/reports/aej', _aej)
    ..get('/signature', _signatureInfo)
    ..post('/signature/verify', _verifySignature)
    ..get('/closings', _listClosings)
    ..post('/closings', _close)
    ..delete('/closings/<id>', _reopen)
    ..get('/dashboard', _dashboard)
    ..get('/onboarding', _onboarding)
    ..get('/audit', _audit);

  (LocalDate, LocalDate) _period(Request req, MemberContext ctx) {
    final today = LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset));
    final period = req.q('period'); // AAAA-MM
    if (period != null) {
      final d = LocalDate.tryParse('$period-01');
      if (d == null) throw const ApiError.badRequest('Período inválido (use AAAA-MM)');
      final settings = ctx.settings;
      if (settings.closingDay > 0 && settings.closingDay < 28) {
        return settings.periodFor(LocalDate(d.year, d.month, settings.closingDay));
      }
      return (d.firstDayOfMonth, d.lastDayOfMonth);
    }
    final (defFrom, defTo) = ctx.settings.periodFor(today);
    final from = req.qDate('from') ?? defFrom;
    final to = req.qDate('to') ?? defTo;
    if (to < from) throw const ApiError.badRequest('Período inválido');
    if (to.differenceInDays(from) > 400) throw const ApiError.badRequest('Período máximo de 400 dias');
    return (from, to);
  }

  String _periodKey(LocalDate from, LocalDate to) => '${from.toString()}_${to.toString()}';

  Future<Response> _timesheet(Request req) async {
    final ctx = await app.sessions.member(req);
    final memberId = optUuid(req.q('member_id'), 'member_id') ?? ctx.memberId;
    await ctx.ensureCanSee(app.db, memberId);
    final (from, to) = _period(req, ctx);
    final tsCtx = await app.timesheets.context(memberId, companyId: ctx.companyId);
    final result = await app.timesheets.period(memberId, from, to, ctx: tsCtx);
    final signature = await app.db.one(
      'SELECT * FROM timesheet_signatures WHERE member_id = @m AND period = @p',
      {'m': memberId, 'p': _periodKey(from, to)},
    );
    // Marcações completas (com foto/local) para o tratamento do ponto.
    final punchRows = await app.db.query(
      '$punchSelectSql WHERE p.member_id = @m AND p.punched_at >= @s AND p.punched_at < @e ORDER BY p.punched_at',
      {
        'm': memberId,
        's': TimeFmt.fromWall(from.addDays(-1).toDateTime(), tsCtx.offset),
        'e': TimeFmt.fromWall(to.addDays(2).toDateTime(), tsCtx.offset),
      },
    );
    return jsonResponse({
      ...result.toJson(),
      'member': {
        'id': memberId,
        'name': tsCtx.member['name'],
        'cpf': tsCtx.member['cpf'],
        'registration': tsCtx.member['registration'],
      },
      'schedule': tsCtx.schedule.toJson(),
      'period_key': _periodKey(from, to),
      'signature': signature == null ? null : map.signature(signature),
      'closings': [for (final c in await app.closings.overlapping(ctx.companyId, from, to)) app.closings.toJson(c)],
      'punch_details': [for (final r in punchRows) map.punch(r, tsCtx.offset)],
    });
  }

  Future<Response> _timesheetPdf(Request req) async {
    final ctx = await app.sessions.member(req);
    final memberId = optUuid(req.q('member_id'), 'member_id') ?? ctx.memberId;
    await ctx.ensureCanSee(app.db, memberId);
    final (from, to) = _period(req, ctx);
    final tsCtx = await app.timesheets.context(memberId, companyId: ctx.companyId);
    final result = await app.timesheets.period(memberId, from, to, ctx: tsCtx);
    final signature = await app.db.one(
      'SELECT * FROM timesheet_signatures WHERE member_id = @m AND period = @p',
      {'m': memberId, 'p': _periodKey(from, to)},
    );
    int? balance;
    if (ctx.isManager || ctx.settings.showBankToEmployee) {
      balance = (await app.timesheets.bank(memberId, ctx: tsCtx)).balance;
    }
    final pdf = await app.reports.timesheetPdf(ctx: tsCtx, result: result, signature: signature, bankBalance: balance);
    final name = (tsCtx.member['name'] as String).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return fileResponse(pdf, contentType: 'application/pdf', filename: 'espelho-$name-$from.pdf', inline: true);
  }

  /// Assinatura eletrônica do espelho pelo colaborador.
  Future<Response> _sign(Request req) async {
    final ctx = await app.sessions.member(req);
    final body = await readJson(req);
    final from = body.date('from');
    final to = body.date('to');
    final today = LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset));
    if (to >= today) throw const ApiError.badRequest('Só é possível assinar períodos já encerrados');
    final agreed = body.optBool('agreed') ?? true;
    final comment = body.optStr('comment');
    if (!agreed && comment == null) throw const ApiError.badRequest('Descreva as ressalvas');
    final result = await app.timesheets.period(ctx.memberId, from, to);
    final hash = app.timesheets.timesheetHash(result, ctx.memberId);
    final row = await app.db.one(
      '''
      INSERT INTO timesheet_signatures (company_id, member_id, period, hash, agreed, comment, ip)
      VALUES (@c, @m, @p, @h, @a, @cm, @ip)
      ON CONFLICT (member_id, period) DO NOTHING RETURNING *''',
      {
        'c': ctx.companyId,
        'm': ctx.memberId,
        'p': _periodKey(from, to),
        'h': hash,
        'a': agreed,
        'cm': comment,
        'ip': req.clientIp,
      },
    );
    if (row == null) throw const ApiError.conflict('Este período já foi assinado');
    await app.audit.log(
        companyId: ctx.companyId, userId: ctx.user.id, action: 'sign', entity: 'timesheet', entityId: row['id'] as String,
        data: {'period': _periodKey(from, to), 'agreed': agreed}, ip: req.clientIp);
    if (!agreed) {
      await app.notifications.notifyManagers(ctx.companyId,
          title: 'Espelho assinado com ressalvas',
          body: '${ctx.user.name} (${from.toBr()} a ${to.toBr()}): $comment',
          type: 'timesheet_disagreement',
          data: {'member_id': ctx.memberId});
    }
    return created(map.signature(row));
  }

  Future<Response> _signatures(Request req) async {
    final ctx = await app.sessions.member(req);
    final memberId = ctx.isManager ? optUuid(req.q('member_id'), 'member_id') : ctx.memberId;
    final rows = await app.db.query(
      'SELECT ts.* FROM timesheet_signatures ts JOIN members m ON m.id = ts.member_id '
      'WHERE ts.company_id = @c AND (@m::uuid IS NULL OR ts.member_id = @m::uuid)'
      '${ctx.isManager ? ctx.scopeSql('m') : ''} ORDER BY ts.signed_at DESC LIMIT 500',
      {'c': ctx.companyId, 'm': memberId, if (ctx.isManager) ...ctx.scopeParams},
    );
    return jsonResponse([for (final r in rows) map.signature(r)]);
  }

  Future<Response> _summary(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final (from, to) = _period(req, ctx);
    final rows = await app.reports.summary(ctx.companyId, from, to,
        departmentId: optUuid(req.q('department_id'), 'department_id'),
        includeBank: req.q('bank') == 'true',
        scopeSql: ctx.scopeSql('m'),
        scopeParams: ctx.scopeParams);
    return jsonResponse({'from': from.toString(), 'to': to.toString(), 'rows': rows});
  }

  Future<Response> _summaryCsv(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final (from, to) = _period(req, ctx);
    final rows = await app.reports.summary(ctx.companyId, from, to,
        departmentId: optUuid(req.q('department_id'), 'department_id'),
        includeBank: true,
        scopeSql: ctx.scopeSql('m'),
        scopeParams: ctx.scopeParams);
    return _csv(app.reports.summaryCsv(rows), 'resumo-$from-$to.csv');
  }

  Future<Response> _payrollCsv(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final (from, to) = _period(req, ctx);
    final rows = await app.reports.summary(ctx.companyId, from, to,
        scopeSql: ctx.scopeSql('m'), scopeParams: ctx.scopeParams);
    final codes = ((ctx.company['settings'] as Map)['payroll_codes'] as Map?)?.cast<String, String>() ?? const {};
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'export', entity: 'payroll',
        data: {'from': from.toString(), 'to': to.toString()}, ip: req.clientIp);
    return _csv(app.reports.payrollCsv(rows, codes), 'folha-$from-$to.csv');
  }

  Future<Response> _punchesCsv(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final (from, to) = _period(req, ctx);
    return _csv(
        await app.reports.punchesCsv(ctx.companyId, from, to, ctx.offset,
            scopeSql: ctx.scopeSql('m'), scopeParams: ctx.scopeParams),
        'marcacoes-$from-$to.csv');
  }

  Response _csv(String content, String filename) => fileResponse(
        // BOM para o Excel reconhecer UTF-8.
        [0xEF, 0xBB, 0xBF, ...utf8.encode(content)],
        contentType: 'text/csv; charset=utf-8',
        filename: filename,
      );

  Future<Response> _afd(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireCompanyWide();
    final (from, to) = _period(req, ctx);
    final company = (await app.db.one('SELECT * FROM companies WHERE id = @c', {'c': ctx.companyId}))!;
    final content = await app.reports.afd(company, from, to);
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'export', entity: 'afd',
        data: {'from': from.toString(), 'to': to.toString()}, ip: req.clientIp);
    final doc = Documents.onlyAlnum(company['document'] as String?);
    return _legalFile(req, ReportService.latin1Bytes(content), 'AFD${app.config.inpiNumber}$doc.txt');
  }

  /// Arquivo legal em texto ou, com `signed=true`, ZIP com o arquivo e a
  /// assinatura CAdES destacada (`.p7s`), como entregue à fiscalização.
  Future<Response> _legalFile(Request req, List<int> bytes, String filename) async {
    if (req.url.queryParameters['signed'] != 'true') {
      return fileResponse(bytes, contentType: 'text/plain; charset=iso-8859-1', filename: filename);
    }
    final p7s = await app.signing.detached(bytes);
    final zip = ZipEncoder().encode(Archive()
      ..addFile(ArchiveFile.bytes(filename, bytes))
      ..addFile(ArchiveFile.bytes('$filename.p7s', p7s)));
    return fileResponse(zip, contentType: 'application/zip', filename: filename.replaceAll('.txt', '.zip'));
  }

  Future<Response> _signatureInfo(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireCompanyWide();
    return jsonResponse(await app.signing.info());
  }

  /// Verifica um arquivo e sua assinatura `.p7s` (ambos em base64).
  Future<Response> _verifySignature(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    List<int> b64(String field) {
      try {
        return base64.decode(body.str(field));
      } on FormatException {
        throw ApiError.badRequest('Campo $field deve estar em base64');
      }
    }

    final content = b64('content'), signature = b64('signature');
    return jsonResponse(CmsVerifier.verifyDetached(signature, content).toJson());
  }

  Future<Response> _aej(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireCompanyWide();
    final (from, to) = _period(req, ctx);
    final company = (await app.db.one('SELECT * FROM companies WHERE id = @c', {'c': ctx.companyId}))!;
    final content = await app.reports.aej(company, from, to);
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'export', entity: 'aej',
        data: {'from': from.toString(), 'to': to.toString()}, ip: req.clientIp);
    final doc = Documents.onlyAlnum(company['document'] as String?);
    return _legalFile(req, ReportService.latin1Bytes(content), 'AEJ_$doc${from.toString().replaceAll('-', '')}.txt');
  }

  Future<Response> _listClosings(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final rows = await app.closings.overlapping(ctx.companyId, const LocalDate(2000, 1, 1), const LocalDate(2100, 1, 1));
    return jsonResponse([for (final r in rows.reversed) app.closings.toJson(r)]);
  }

  /// Fecha o período para tratamento (folha enviada).
  Future<Response> _close(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireCompanyWide();
    final body = await readJson(req);
    final from = body.date('from');
    final to = body.date('to');
    if (to < from) throw const ApiError.badRequest('Período inválido');
    final today = LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset));
    if (to >= today) throw const ApiError.badRequest('Só é possível fechar períodos já encerrados');
    if ((await app.closings.overlapping(ctx.companyId, from, to)).isNotEmpty) {
      throw const ApiError.conflict('Parte deste período já está fechada');
    }
    final row = await app.db.one(
      'INSERT INTO period_closings (company_id, start_date, end_date, closed_by, note) VALUES (@c, @f, @t, @by, @n) RETURNING id',
      {'c': ctx.companyId, 'f': from.toString(), 't': to.toString(), 'by': ctx.memberId, 'n': body.optStr('note')},
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'close', entity: 'period',
        entityId: row!['id'] as String, data: body, ip: req.clientIp);
    final full = (await app.closings.overlapping(ctx.companyId, from, to)).first;
    app.webhooks.dispatch(ctx.companyId, 'period.closed', app.closings.toJson(full));
    return created(app.closings.toJson(full));
  }

  /// Reabre um período (somente administradores; fica na auditoria).
  Future<Response> _reopen(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final n = await app.db.execute('DELETE FROM period_closings WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'reopen', entity: 'period', entityId: id, ip: req.clientIp);
    return noContent();
  }

  /// Checklist de configuração inicial da empresa.
  Future<Response> _onboarding(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final c = ctx.company;
    Future<int> count(String sql) async =>
        (await app.db.one('SELECT count(*)::int AS n FROM $sql', {'c': ctx.companyId}))!['n'] as int;
    final members = await count('members WHERE company_id = @c AND active');
    final fences = await count('geofences WHERE company_id = @c AND active');
    final schedules = await count('schedules WHERE company_id = @c AND active');
    final editedSchedules =
        await count("schedules WHERE company_id = @c AND active AND updated_at > created_at + interval '1 second'");
    final devices = await count('devices WHERE company_id = @c');
    final punches = await count('punches WHERE company_id = @c');
    final settings = ctx.settings;
    final steps = [
      {
        'key': 'company',
        'title': 'Complete os dados do empregador',
        'description': 'CNPJ, razão social e endereço aparecem no comprovante, no espelho e no AFD.',
        'route': '/empresa',
        'done': (c['document'] as String? ?? '').isNotEmpty && (c['address'] as String? ?? '').isNotEmpty,
      },
      {
        'key': 'schedule',
        'title': 'Revise as escalas de trabalho',
        'description': 'Ajuste horários, tolerâncias e regime (horas extras, banco de horas ou híbrido).',
        'route': '/escalas',
        'done': schedules > 1 || editedSchedules > 0,
      },
      {
        'key': 'geofence',
        'title': 'Cadastre o local de trabalho (perímetro)',
        'description': 'Valide a localização das marcações pelo celular.',
        'route': '/perimetros',
        'done': fences > 0,
      },
      {
        'key': 'members',
        'title': 'Convide sua equipe',
        'description': 'Cadastre um a um ou importe uma planilha.',
        'route': '/equipe',
        'done': members > 1,
      },
      {
        'key': 'device',
        'title': 'Ative um quiosque (opcional)',
        'description': 'Transforme um tablet em relógio de ponto coletivo com PIN, crachá ou QR Code.',
        'route': '/dispositivos',
        'done': devices > 0,
      },
      {
        'key': 'inpi',
        'title': 'Informe o registro do REP-P no INPI',
        'description': 'Número exibido no comprovante e no cabeçalho do AFD.',
        'route': '/empresa',
        'done': settings.inpiNumber.isNotEmpty || app.config.inpiNumber != '00000000000000000',
      },
      {
        'key': 'first_punch',
        'title': 'Registre a primeira marcação',
        'description': 'Teste pelo app, navegador ou quiosque.',
        'route': '/ponto',
        'done': punches > 0,
      },
    ];
    final done = steps.where((s) => s['done'] == true).length;
    return jsonResponse({'steps': steps, 'done': done, 'total': steps.length});
  }

  /// Indicadores do dia para o gestor.
  Future<Response> _dashboard(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final wallNow = TimeFmt.toWall(app.now(), ctx.offset);
    final today = req.qDate('date') ?? LocalDate.fromDateTime(wallNow);
    final members = await app.db.query(
      '''
      SELECT m.id, m.schedule_id, m.admission_date, m.photo_url, u.name, d.name AS department_name
      FROM members m JOIN users u ON u.id = m.user_id LEFT JOIN departments d ON d.id = m.department_id
      WHERE m.company_id = @c AND m.active${ctx.scopeSql('m')} ORDER BY u.name''',
      {'c': ctx.companyId, ...ctx.scopeParams},
    );
    final dayStart = TimeFmt.fromWall(today.toDateTime(), ctx.offset);
    final dayEnd = TimeFmt.fromWall(today.addDays(1).toDateTime(), ctx.offset);
    final punches = await app.db.query(
      '$punchSelectSql WHERE p.company_id = @c AND p.punched_at >= @s AND p.punched_at < @e AND NOT p.disregarded'
      '${ctx.scopeSql('m')} ORDER BY p.punched_at',
      {'c': ctx.companyId, 's': dayStart, 'e': dayEnd, ...ctx.scopeParams},
    );
    final holidays = await app.timesheets.holidays(ctx.companyId, today, today);
    final absencesToday = await app.db.query(
      'SELECT member_id, type FROM absences WHERE company_id = @c AND start_date <= @d AND end_date >= @d AND minutes_per_day IS NULL',
      {'c': ctx.companyId, 'd': today.toString()},
    );
    final absentIds = {for (final a in absencesToday) a['member_id'] as String};
    final byMember = <String, List<Map<String, dynamic>>>{};
    for (final p in punches) {
      byMember.putIfAbsent(p['member_id'] as String, () => []).add(p);
    }
    final scheduleCache = <String?, ScheduleDefinition>{};
    final status = <Map<String, Object?>>[];
    var working = 0, punched = 0, absent = 0, late = 0, expectedToday = 0, onLeave = 0;
    for (final m in members) {
      final id = m['id'] as String;
      final schedId = m['schedule_id'] as String?;
      final schedule = scheduleCache[schedId] ??= await app.timesheets.scheduleFor(ctx.companyId, schedId, ctx.company);
      final template = schedule.templateFor(today);
      final isWorkday = template.workDay && holidays.isEmpty;
      final list = byMember[id] ?? const [];
      final first = list.isEmpty ? null : TimeFmt.toWall(list.first['punched_at'] as DateTime, ctx.offset);
      String state;
      int? lateMinutes;
      if (absentIds.contains(id)) {
        state = 'leave';
        onLeave++;
      } else if (list.isEmpty) {
        final start = template.firstStart;
        final startTime = start == null ? null : today.toDateTime().add(Duration(minutes: start + schedule.tolerancePerMark));
        if (isWorkday && startTime != null && wallNow.isAfter(startTime)) {
          state = 'absent';
          absent++;
        } else {
          state = isWorkday ? 'expected' : 'off';
        }
      } else {
        punched++;
        state = list.length.isOdd ? 'working' : 'out';
        if (list.length.isOdd) working++;
        final start = template.firstStart;
        if (isWorkday && start != null && first != null) {
          final diff = first.difference(today.toDateTime().add(Duration(minutes: start))).inMinutes;
          if (diff > schedule.tolerancePerMark) {
            lateMinutes = diff;
            late++;
          }
        }
      }
      if (isWorkday) expectedToday++;
      status.add({
        'member_id': id,
        'name': m['name'],
        'department': m['department_name'],
        'photo_url': m['photo_url'],
        'state': state,
        'late_minutes': lateMinutes,
        'expected': template.describe(),
        'punches': [for (final p in list) TimeFmt.clock(TimeFmt.toWall(p['punched_at'] as DateTime, ctx.offset))],
      });
    }
    final pending = await app.db.one(
      "SELECT count(*)::int AS n FROM requests r JOIN members m ON m.id = r.member_id "
      "WHERE r.company_id = @c AND r.status = 'pending'${ctx.scopeSql('m')}",
      {'c': ctx.companyId, ...ctx.scopeParams},
    );
    final outside = punches.where((p) => p['inside_geofence'] == false).length;
    final week = await app.db.query(
      '''
      SELECT (punched_at AT TIME ZONE 'UTC' + make_interval(mins => @off))::date AS day, count(*)::int AS n
      FROM punches WHERE company_id = @c AND punched_at >= @s AND NOT disregarded
      GROUP BY 1 ORDER BY 1''',
      {'c': ctx.companyId, 'off': ctx.offset, 's': TimeFmt.fromWall(today.addDays(-6).toDateTime(), ctx.offset)},
    );
    return jsonResponse({
      'date': today.toString(),
      'holiday': holidays.isEmpty ? null : holidays.first.name,
      'totals': {
        'members': members.length,
        'expected_today': expectedToday,
        'punched': punched,
        'working': working,
        'absent': absent,
        'late': late,
        'on_leave': onLeave,
        'pending_requests': pending!['n'],
        'outside_geofence': outside,
      },
      'members': status,
      'recent_punches': [for (final p in punches.reversed.take(50)) map.punch(p, ctx.offset)],
      'week': [
        for (final w in week)
          {'date': LocalDate.fromDateTime(w['day'] as DateTime).toString(), 'punches': w['n']},
      ],
    });
  }

  Future<Response> _audit(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireCompanyWide();
    final rows = await app.db.query(
      '''
      SELECT a.*, u.name AS actor_name FROM audit_logs a LEFT JOIN users u ON u.id = a.user_id
      WHERE a.company_id = @c AND (@e::text IS NULL OR a.entity = @e::text)
        AND (@before::timestamptz IS NULL OR a.created_at < @before::timestamptz)
      ORDER BY a.created_at DESC LIMIT @limit''',
      {
        'c': ctx.companyId,
        'e': req.q('entity'),
        'before': req.q('before') == null ? null : DateTime.tryParse(req.q('before')!),
        'limit': req.qInt('limit', 100).clamp(1, 500),
      },
    );
    return jsonResponse([for (final r in rows) map.audit(r)]);
  }
}
