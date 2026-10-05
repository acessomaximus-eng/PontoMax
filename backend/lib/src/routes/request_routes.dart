import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';

/// Solicitações (ajustes, atestados, abonos, folgas, férias), ausências e
/// banco de horas.
class RequestRoutes {
  final App app;
  RequestRoutes(this.app);
  Mappers get map => Mappers(app);

  static const _requestSelect = '''
SELECT r.*, u.name AS member_name, ru.name AS reviewer_name
FROM requests r
JOIN members m ON m.id = r.member_id JOIN users u ON u.id = m.user_id
LEFT JOIN members rm ON rm.id = r.reviewer_id LEFT JOIN users ru ON ru.id = rm.user_id
''';

  static const _absenceSelect = '''
SELECT a.*, u.name AS member_name FROM absences a
JOIN members m ON m.id = a.member_id JOIN users u ON u.id = m.user_id
''';

  Router get router => Router()
    ..get('/requests', _list)
    ..post('/requests', _create)
    ..get('/requests/<id>', _get)
    ..post('/requests/<id>/approve', _approve)
    ..post('/requests/<id>/reject', _reject)
    ..post('/requests/<id>/cancel', _cancel)
    ..get('/absences', _listAbsences)
    ..post('/absences', _createAbsence)
    ..delete('/absences/<id>', _deleteAbsence)
    ..get('/bank', _bank)
    ..post('/bank/entries', _createEntry)
    ..delete('/bank/entries/<id>', _deleteEntry);

  // ---------------------------------------------------------------------------
  // Solicitações
  // ---------------------------------------------------------------------------

  Future<Response> _list(Request req) async {
    final ctx = await app.sessions.member(req);
    final mine = req.q('mine') == 'true' || !ctx.isManager;
    final rows = await app.db.query(
      '''
      $_requestSelect
      WHERE r.company_id = @c AND (@mine = false OR r.member_id = @self)
        AND (@status::text IS NULL OR r.status = @status::text)
        AND (@m::uuid IS NULL OR r.member_id = @m::uuid)
      ORDER BY CASE WHEN r.status = 'pending' THEN 0 ELSE 1 END, r.created_at DESC
      LIMIT @limit''',
      {
        'c': ctx.companyId,
        'mine': mine,
        'self': ctx.memberId,
        'status': req.q('status'),
        'm': optUuid(req.q('member_id'), 'member_id'),
        'limit': req.qInt('limit', 200).clamp(1, 1000),
      },
    );
    return jsonResponse([for (final r in rows) map.request(r)]);
  }

  Future<Response> _get(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final row = await app.db.one('$_requestSelect WHERE r.id = @id AND r.company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (row == null) throw const ApiError.notFound('Solicitação não encontrada');
    ctx.requireSelfOrManager(row['member_id'] as String);
    return jsonResponse(map.request(row));
  }

  Future<Response> _create(Request req) async {
    final ctx = await app.sessions.member(req);
    final body = await readJson(req);
    final type = RequestType.fromCode(body.str('type', label: 'tipo'));
    final date = body.date('date');
    final endDate = body.optDate('end_date');
    if (endDate != null && endDate < date) throw const ApiError.badRequest('Data final anterior à inicial');
    if (endDate != null && endDate.differenceInDays(date) > 60) {
      throw const ApiError.badRequest('Período máximo de 60 dias por solicitação');
    }
    final times = body.strList('times');
    for (final t in times) {
      try {
        TimeFmt.parseHm(t);
      } on FormatException {
        throw ApiError.badRequest('Horário inválido: $t');
      }
    }
    if (type.createsPunches && times.isEmpty) {
      throw const ApiError.badRequest('Informe ao menos um horário para incluir');
    }
    final reason = body.str('reason', label: 'justificativa');
    final today = LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset));
    if (type.createsPunches && date > today) {
      throw const ApiError.badRequest('Não é possível solicitar marcações em datas futuras');
    }
    final attachment = optUuid(body.optStr('attachment_file_id'), 'attachment_file_id');
    // Gestor pode criar solicitação para outro colaborador.
    final memberId = ctx.isManager ? (optUuid(body.optStr('member_id'), 'member_id') ?? ctx.memberId) : ctx.memberId;

    final row = await app.db.tx((tx) async {
      final r = await tx.one(
        '''
        INSERT INTO requests (company_id, member_id, type, date, end_date, times, minutes, reason, attachment_file_id)
        VALUES (@c, @m, @t, @d, @ed, @times, @min, @reason, @att) RETURNING id''',
        {
          'c': ctx.companyId,
          'm': memberId,
          't': type.code,
          'd': date.toString(),
          'ed': endDate?.toString(),
          'times': times,
          'min': body.optInt('minutes'),
          'reason': reason,
          'att': attachment,
        },
      );
      await app.notifications.notifyManagers(
        ctx.companyId,
        db: tx,
        title: 'Nova solicitação: ${type.label}',
        body: '${ctx.user.name} — ${date.toBr()}: $reason',
        type: 'request_created',
        data: {'request_id': r!['id']},
        exceptMemberId: ctx.memberId,
      );
      return (await tx.one('$_requestSelect WHERE r.id = @id', {'id': r['id']}))!;
    });
    app.webhooks.dispatch(ctx.companyId, 'request.created', map.request(row));
    return created(map.request(row));
  }

  Future<Response> _approve(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final row = await app.db.tx((tx) async {
      final r = await tx.one(
        "SELECT * FROM requests WHERE id = @id AND company_id = @c FOR UPDATE",
        {'id': requireUuid(id), 'c': ctx.companyId},
      );
      if (r == null) throw const ApiError.notFound('Solicitação não encontrada');
      if (r['status'] != 'pending') throw const ApiError.conflict('Esta solicitação já foi analisada');
      final type = RequestType.fromCode(r['type'] as String);
      final date = LocalDate.fromDateTime(r['date'] as DateTime);
      final memberId = r['member_id'] as String;
      final endDate = r['end_date'] == null ? date : LocalDate.fromDateTime(r['end_date'] as DateTime);
      await app.closings.ensureOpen(ctx.companyId, date, endDate, tx);

      if (type.createsPunches) {
        final times = body.containsKey('times') ? body.strList('times') : [for (final t in r['times'] as List) t.toString()];
        for (final t in times) {
          await app.punches.include(
            db: tx,
            companyId: ctx.companyId,
            memberId: memberId,
            wall: date.toDateTime().add(Duration(minutes: TimeFmt.parseHm(t))),
            offset: ctx.offset,
            reason: '${type.label}: ${r['reason']}',
            createdBy: ctx.memberId,
            requestId: id,
          );
        }
      }
      if (type.createsAbsence) {
        await tx.execute(
          '''
          INSERT INTO absences (company_id, member_id, type, start_date, end_date, minutes_per_day, reason,
            attachment_file_id, request_id, created_by)
          VALUES (@c, @m, @t, @s, @e, @min, @reason, @att, @req, @by)''',
          {
            'c': ctx.companyId,
            'm': memberId,
            't': type.absenceType!.code,
            's': date.toString(),
            'e': r['end_date'] == null ? date.toString() : LocalDate.fromDateTime(r['end_date'] as DateTime).toString(),
            'min': r['minutes'],
            'reason': r['reason'],
            'att': r['attachment_file_id'],
            'req': id,
            'by': ctx.memberId,
          },
        );
      }
      await tx.execute(
        "UPDATE requests SET status = 'approved', reviewer_id = @by, reviewed_at = now(), review_note = @note WHERE id = @id",
        {'id': id, 'by': ctx.memberId, 'note': body.optStr('note')},
      );
      await app.audit.log(
          db: tx, companyId: ctx.companyId, userId: ctx.user.id, action: 'approve', entity: 'request', entityId: id, data: body, ip: req.clientIp);
      await app.notifications.notify(memberId,
          db: tx,
          title: 'Solicitação aprovada',
          body: '${type.label} de ${date.toBr()} foi aprovada${body.optStr('note') != null ? ': ${body.optStr('note')}' : ''}.',
          type: 'request_approved',
          data: {'request_id': id});
      return (await tx.one('$_requestSelect WHERE r.id = @id', {'id': id}))!;
    });
    app.webhooks.dispatch(ctx.companyId, 'request.approved', map.request(row));
    return jsonResponse(map.request(row));
  }

  Future<Response> _reject(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final note = body.str('note', label: 'motivo da recusa');
    final row = await app.db.tx((tx) async {
      final r = await tx.one(
        "UPDATE requests SET status = 'rejected', reviewer_id = @by, reviewed_at = now(), review_note = @note "
        "WHERE id = @id AND company_id = @c AND status = 'pending' RETURNING *",
        {'id': requireUuid(id), 'c': ctx.companyId, 'by': ctx.memberId, 'note': note},
      );
      if (r == null) throw const ApiError.conflict('Solicitação não encontrada ou já analisada');
      await app.audit.log(
          db: tx, companyId: ctx.companyId, userId: ctx.user.id, action: 'reject', entity: 'request', entityId: id, data: body, ip: req.clientIp);
      await app.notifications.notify(r['member_id'] as String,
          db: tx,
          title: 'Solicitação recusada',
          body: '${RequestType.fromCode(r['type'] as String).label} de ${LocalDate.fromDateTime(r['date'] as DateTime).toBr()}: $note',
          type: 'request_rejected',
          data: {'request_id': id});
      return (await tx.one('$_requestSelect WHERE r.id = @id', {'id': id}))!;
    });
    app.webhooks.dispatch(ctx.companyId, 'request.rejected', map.request(row));
    return jsonResponse(map.request(row));
  }

  Future<Response> _cancel(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final r = await app.db.one(
      "UPDATE requests SET status = 'cancelled' WHERE id = @id AND company_id = @c AND member_id = @m AND status = 'pending' RETURNING id",
      {'id': requireUuid(id), 'c': ctx.companyId, 'm': ctx.memberId},
    );
    if (r == null) throw const ApiError.conflict('Solicitação não encontrada ou já analisada');
    final row = await app.db.one('$_requestSelect WHERE r.id = @id', {'id': id});
    return jsonResponse(map.request(row!));
  }

  // ---------------------------------------------------------------------------
  // Ausências / abonos
  // ---------------------------------------------------------------------------

  Future<Response> _listAbsences(Request req) async {
    final ctx = await app.sessions.member(req);
    final memberId = ctx.isManager ? optUuid(req.q('member_id'), 'member_id') : ctx.memberId;
    final rows = await app.db.query(
      '''
      $_absenceSelect
      WHERE a.company_id = @c AND (@m::uuid IS NULL OR a.member_id = @m::uuid)
        AND (@f::date IS NULL OR a.end_date >= @f::date) AND (@t::date IS NULL OR a.start_date <= @t::date)
      ORDER BY a.start_date DESC LIMIT 500''',
      {'c': ctx.companyId, 'm': memberId, 'f': req.qDate('from')?.toString(), 't': req.qDate('to')?.toString()},
    );
    return jsonResponse([for (final r in rows) map.absence(r)]);
  }

  Future<Response> _createAbsence(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final memberId = requireUuid(body.str('member_id'), 'member_id');
    final start = body.date('start_date');
    final end = body.optDate('end_date') ?? start;
    if (end < start) throw const ApiError.badRequest('Data final anterior à inicial');
    final m = await app.db.one('SELECT id FROM members WHERE id = @id AND company_id = @c', {'id': memberId, 'c': ctx.companyId});
    if (m == null) throw const ApiError.notFound('Colaborador não encontrado');
    await app.closings.ensureOpen(ctx.companyId, start, end);
    final row = await app.db.one(
      '''
      INSERT INTO absences (company_id, member_id, type, start_date, end_date, minutes_per_day, reason, attachment_file_id, created_by)
      VALUES (@c, @m, @t, @s, @e, @min, @reason, @att, @by) RETURNING id''',
      {
        'c': ctx.companyId,
        'm': memberId,
        't': AbsenceType.fromCode(body.str('type', label: 'tipo')).code,
        's': start.toString(),
        'e': end.toString(),
        'min': body.optInt('minutes_per_day'),
        'reason': body.optStr('reason') ?? '',
        'att': optUuid(body.optStr('attachment_file_id'), 'attachment_file_id'),
        'by': ctx.memberId,
      },
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'absence', entityId: row!['id'] as String, data: body);
    final full = await app.db.one('$_absenceSelect WHERE a.id = @id', {'id': row['id']});
    return created(map.absence(full!));
  }

  Future<Response> _deleteAbsence(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final a = await app.db.one('SELECT start_date, end_date FROM absences WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (a == null) throw const ApiError.notFound();
    await app.closings.ensureOpen(ctx.companyId, LocalDate.fromDateTime(a['start_date'] as DateTime),
        LocalDate.fromDateTime(a['end_date'] as DateTime));
    final n = await app.db.execute('DELETE FROM absences WHERE id = @id AND company_id = @c', {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'absence', entityId: id);
    return noContent();
  }

  // ---------------------------------------------------------------------------
  // Banco de horas
  // ---------------------------------------------------------------------------

  Future<Response> _bank(Request req) async {
    final ctx = await app.sessions.member(req);
    final memberId = optUuid(req.q('member_id'), 'member_id') ?? ctx.memberId;
    ctx.requireSelfOrManager(memberId);
    if (!ctx.isManager && !ctx.settings.showBankToEmployee) {
      throw const ApiError.forbidden('A empresa não disponibiliza o banco de horas para consulta');
    }
    final tsCtx = await app.timesheets.context(memberId, companyId: ctx.companyId);
    final summary = await app.timesheets.bank(memberId, ctx: tsCtx);
    final months = summary.monthly.keys.toList()..sort();
    return jsonResponse({
      'member_id': memberId,
      'balance': summary.balance,
      'initial': summary.initial,
      'computed': summary.computed,
      'manual': summary.manual,
      'since': summary.since.toString(),
      'regime': tsCtx.schedule.regime.code,
      'monthly': [for (final k in months.reversed) {'month': k, 'minutes': summary.monthly[k]}],
      'entries': [for (final e in summary.entries) map.bankEntry(e)],
    });
  }

  Future<Response> _createEntry(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final memberId = requireUuid(body.str('member_id'), 'member_id');
    final type = BankEntryType.fromCode(body.str('type', label: 'tipo'));
    var minutes = body.optInt('minutes') ?? 0;
    if (minutes == 0) throw const ApiError.badRequest('Informe a quantidade de minutos');
    if (type == BankEntryType.debit || type == BankEntryType.payment) minutes = -minutes.abs();
    if (type == BankEntryType.credit) minutes = minutes.abs();
    final m = await app.db.one('SELECT id FROM members WHERE id = @id AND company_id = @c', {'id': memberId, 'c': ctx.companyId});
    if (m == null) throw const ApiError.notFound('Colaborador não encontrado');
    final entryDate = body.optDate('date') ?? LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset));
    await app.closings.ensureOpen(ctx.companyId, entryDate);
    final row = await app.db.one(
      'INSERT INTO bank_entries (company_id, member_id, date, minutes, type, description, created_by) '
      'VALUES (@c, @m, @d, @min, @t, @desc, @by) RETURNING *',
      {
        'c': ctx.companyId,
        'm': memberId,
        'd': entryDate.toString(),
        'min': minutes,
        't': type.code,
        'desc': body.optStr('description') ?? '',
        'by': ctx.memberId,
      },
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'bank_entry', entityId: row!['id'] as String, data: body);
    await app.notifications.notify(memberId,
        title: 'Banco de horas atualizado',
        body: '${type.label}: ${TimeFmt.minutes(minutes, signed: true)}${body.optStr('description') != null ? ' — ${body.optStr('description')}' : ''}',
        type: 'bank_entry');
    return created(map.bankEntry(row));
  }

  Future<Response> _deleteEntry(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final e = await app.db.one('SELECT date FROM bank_entries WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (e == null) throw const ApiError.notFound();
    await app.closings.ensureOpen(ctx.companyId, LocalDate.fromDateTime(e['date'] as DateTime));
    final n = await app.db.execute('DELETE FROM bank_entries WHERE id = @id AND company_id = @c', {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'bank_entry', entityId: id);
    return noContent();
  }
}
