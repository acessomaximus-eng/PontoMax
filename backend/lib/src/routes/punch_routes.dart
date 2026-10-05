import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/session.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';
import '../services/punch_service.dart';

class PunchRoutes {
  final App app;
  PunchRoutes(this.app);
  Mappers get map => Mappers(app);

  Router get router => Router()
    ..get('/time', _time)
    ..post('/punches', _punch)
    ..post('/punches/sync', _sync)
    ..get('/punches', _list)
    ..get('/punches/today', _today)
    ..post('/punches/manual', _manual)
    ..get('/punches/<id>', _get)
    ..get('/punches/<id>/receipt', _receipt)
    ..get('/punches/<id>/receipt.pdf', _receiptPdf)
    ..post('/punches/<id>/disregard', _disregard)
    ..post('/punches/<id>/restore', _restore)
    ..delete('/punches/<id>', _delete);

  /// Hora oficial do servidor (sincronização do relógio do app).
  Future<Response> _time(Request req) async {
    final now = app.now();
    return jsonResponse({
      'utc': now.toIso8601String(),
      'epoch_ms': now.millisecondsSinceEpoch,
      'default_offset_minutes': -180,
    });
  }

  PunchInput _input(MemberContext ctx, Map<String, dynamic> body, Request req, {String? memberId}) {
    final clientTime = body.optStr('punched_at') == null ? null : DateTime.tryParse(body.optStr('punched_at')!);
    return PunchInput(
      companyId: ctx.companyId,
      memberId: memberId ?? ctx.memberId,
      source: PunchSource.fromCode(body.optStr('source') ?? 'mobile'),
      method: PunchMethod.fromCode(body.optStr('method') ?? 'app'),
      offline: body.optBool('offline') ?? false,
      clientTime: clientTime,
      clientId: body.optStr('client_id'),
      lat: body.optDouble('lat'),
      lng: body.optDouble('lng'),
      accuracy: body.optDouble('accuracy'),
      photoFileId: optUuid(body.optStr('photo_file_id'), 'photo_file_id'),
      qrToken: body.optStr('qr_token'),
      note: body.optStr('note'),
      ip: req.clientIp,
      userAgent: req.headers['user-agent'],
    );
  }

  Future<Response> _punch(Request req) async {
    final ctx = await app.sessions.member(req);
    final body = await readJson(req);
    final source = PunchSource.fromCode(body.optStr('source') ?? 'mobile');
    if (source == PunchSource.device || source == PunchSource.other) {
      throw const ApiError.badRequest('Coletor inválido para marcação pelo colaborador');
    }
    final row = await app.punches.register(_input(ctx, body, req));
    return created({
      'punch': map.punch(row, ctx.offset),
      'receipt': (await app.punches.receipt(row['id'] as String, ctx.companyId)).toJsonMap(),
    });
  }

  /// Sincroniza marcações feitas off-line (idempotente por `client_id`).
  Future<Response> _sync(Request req) async {
    final ctx = await app.sessions.member(req);
    final body = await readJson(req);
    final items = body['punches'];
    if (items is! List) throw const ApiError.badRequest('Lista de marcações obrigatória');
    if (items.length > 200) throw const ApiError.badRequest('Máximo de 200 marcações por sincronização');
    final results = <Map<String, Object?>>[];
    for (final item in items) {
      final data = (item as Map).cast<String, dynamic>();
      final clientId = data['client_id']?.toString();
      if (clientId == null) {
        results.add({'client_id': null, 'ok': false, 'error': 'client_id obrigatório'});
        continue;
      }
      try {
        final row = await app.punches.register(_input(ctx, {...data, 'offline': true}, req));
        results.add({'client_id': clientId, 'ok': true, 'punch': map.punch(row, ctx.offset)});
      } on ApiError catch (e) {
        results.add({'client_id': clientId, 'ok': false, 'error': e.message, 'code': e.code});
      }
    }
    return jsonResponse({'results': results});
  }

  Future<Response> _list(Request req) async {
    final ctx = await app.sessions.member(req);
    final memberId = optUuid(req.q('member_id'), 'member_id');
    if (!ctx.isManager && memberId != null && memberId != ctx.memberId) throw const ApiError.forbidden();
    final effectiveMember = ctx.isManager ? memberId : ctx.memberId;
    final today = LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset));
    final from = req.qDate('from') ?? today.addDays(-30);
    final to = req.qDate('to') ?? today;
    final rows = await app.db.query(
      '''
      $punchSelectSql
      WHERE p.company_id = @c AND (@m::uuid IS NULL OR p.member_id = @m::uuid)
        AND p.punched_at >= @s AND p.punched_at < @e
        AND (@outside = false OR p.inside_geofence = false)
        ${ctx.scopeSql('m')}
      ORDER BY p.punched_at DESC
      LIMIT @limit''',
      {
        ...ctx.scopeParams,
        'c': ctx.companyId,
        'm': effectiveMember,
        's': TimeFmt.fromWall(from.toDateTime(), ctx.offset),
        'e': TimeFmt.fromWall(to.addDays(1).toDateTime(), ctx.offset),
        'outside': req.q('outside') == 'true',
        'limit': req.qInt('limit', 500).clamp(1, 5000),
      },
    );
    return jsonResponse([for (final r in rows) map.punch(r, ctx.offset)]);
  }

  /// Resumo do dia do colaborador logado (tela inicial do app).
  Future<Response> _today(Request req) async {
    final ctx = await app.sessions.member(req);
    final wallNow = TimeFmt.toWall(app.now(), ctx.offset);
    final today = LocalDate.fromDateTime(wallNow);
    final tsCtx = await app.timesheets.context(ctx.memberId);
    final result = await app.timesheets.period(ctx.memberId, today.addDays(-1), today, ctx: tsCtx);
    // Se a jornada de ontem ainda está aberta (turno noturno), ela é a "atual".
    final yesterday = result.days.first;
    final current = (yesterday.open && yesterday.punches.isNotEmpty) ? yesterday : result.days.last;
    final rows = await app.db.query(
      '$punchSelectSql WHERE p.member_id = @m AND p.punched_at >= @s ORDER BY p.punched_at',
      {'m': ctx.memberId, 's': TimeFmt.fromWall(current.date.toDateTime().subtract(const Duration(hours: 6)), ctx.offset)},
    );
    final (ws, we) = JourneyCalculator(schedule: tsCtx.schedule).windowFor(current.date);
    final dayPunches = [
      for (final r in rows)
        if (!TimeFmt.toWall(r['punched_at'] as DateTime, ctx.offset).isBefore(ws) &&
            TimeFmt.toWall(r['punched_at'] as DateTime, ctx.offset).isBefore(we))
          map.punch(r, ctx.offset),
    ];
    final valid = dayPunches.where((p) => p['disregarded'] != true).length;
    String? nextExpected;
    final t = current.template;
    if (t.hasFixedTimes) {
      final idx = valid ~/ 2;
      if (idx < t.intervals.length) {
        nextExpected = TimeFmt.hm(valid.isEven ? t.intervals[idx].start : t.intervals[idx].end);
      }
    }
    return jsonResponse({
      'date': current.date.toString(),
      'server_time': app.now().toIso8601String(),
      'offset_minutes': ctx.offset,
      'punches': dayPunches,
      'day': current.toJson(),
      'working': valid.isOdd,
      'next_label': valid.isEven ? 'Entrada' : (valid == 1 && t.intervals.length > 1 ? 'Saída para intervalo' : 'Saída'),
      'next_expected': nextExpected,
      'schedule': tsCtx.schedule.toJson(),
    });
  }

  Future<Response> _get(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final row = await app.db.one('$punchSelectSql WHERE p.id = @id AND p.company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (row == null) throw const ApiError.notFound('Marcação não encontrada');
    await ctx.ensureCanSee(app.db, row['member_id'] as String);
    return jsonResponse(map.punch(row, ctx.offset));
  }

  Future<Response> _receipt(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final row = await app.db.one('SELECT member_id FROM punches WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (row == null) throw const ApiError.notFound('Marcação não encontrada');
    await ctx.ensureCanSee(app.db, row['member_id'] as String);
    final r = await app.punches.receipt(id, ctx.companyId);
    return jsonResponse(r.toJsonMap());
  }

  Future<Response> _receiptPdf(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final row = await app.db.one('SELECT member_id FROM punches WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (row == null) throw const ApiError.notFound('Marcação não encontrada');
    await ctx.ensureCanSee(app.db, row['member_id'] as String);
    final r = await app.punches.receipt(id, ctx.companyId);
    final pdf = await app.reports.receiptPdf(r);
    return fileResponse(pdf, contentType: 'application/pdf', filename: 'comprovante-${r.nsr}.pdf', inline: true);
  }

  /// Inclusão manual pelo gestor (tratamento do ponto).
  Future<Response> _manual(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final memberId = requireUuid(body.str('member_id'), 'member_id');
    final member = await app.db.one('SELECT id FROM members WHERE id = @id AND company_id = @c',
        {'id': memberId, 'c': ctx.companyId});
    if (member == null) throw const ApiError.notFound('Colaborador não encontrado');
    await ctx.ensureCanSee(app.db, memberId);
    final date = body.date('date');
    final minutes = TimeFmt.parseHm(body.str('time', label: 'horário'));
    final reason = body.str('reason', label: 'justificativa');
    final wall = date.toDateTime().add(Duration(minutes: minutes));
    await app.closings.ensureOpen(ctx.companyId, date);
    if (TimeFmt.fromWall(wall, ctx.offset).isAfter(app.now())) {
      throw const ApiError.badRequest('Não é possível incluir marcações no futuro');
    }
    final row = await app.db.tx((tx) async {
      final row = await app.punches.include(
        db: tx,
        companyId: ctx.companyId,
        memberId: memberId,
        wall: wall,
        offset: ctx.offset,
        reason: reason,
        createdBy: ctx.memberId,
      );
      await app.audit.log(
        db: tx,
        companyId: ctx.companyId,
        userId: ctx.user.id,
        action: 'include',
        entity: 'punch',
        entityId: row['id'] as String,
        data: body,
        ip: req.clientIp,
      );
      await app.notifications.notify(memberId,
          db: tx,
          title: 'Marcação incluída',
          body: 'O gestor incluiu uma marcação em ${date.toBr()} às ${TimeFmt.hm(minutes)}: $reason',
          type: 'punch_included');
      return row;
    });
    return created(map.punch(row, ctx.offset));
  }

  /// Bloqueia o tratamento de marcações em período fechado.
  Future<void> _ensurePunchOpen(MemberContext ctx, String id) async {
    final p = await app.db.one('SELECT punched_at, member_id FROM punches WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (p == null) throw const ApiError.notFound('Marcação não encontrada');
    await ctx.ensureCanSee(app.db, p['member_id'] as String);
    final date = LocalDate.fromDateTime(TimeFmt.toWall(p['punched_at'] as DateTime, ctx.offset));
    await app.closings.ensureOpen(ctx.companyId, date);
  }

  Future<Response> _disregard(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    await _ensurePunchOpen(ctx, id);
    final body = await readJson(req);
    final reason = body.str('reason', label: 'justificativa');
    final row = await app.db.one(
      'UPDATE punches SET disregarded = true, disregard_reason = @r, disregarded_by = @by '
      'WHERE id = @id AND company_id = @c RETURNING id',
      {'id': requireUuid(id), 'c': ctx.companyId, 'r': reason, 'by': ctx.memberId},
    );
    if (row == null) throw const ApiError.notFound('Marcação não encontrada');
    await app.audit.log(
        companyId: ctx.companyId, userId: ctx.user.id, action: 'disregard', entity: 'punch', entityId: id, data: body, ip: req.clientIp);
    final full = await app.db.one('$punchSelectSql WHERE p.id = @id', {'id': id});
    return jsonResponse(map.punch(full!, ctx.offset));
  }

  Future<Response> _restore(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    await _ensurePunchOpen(ctx, id);
    final row = await app.db.one(
      'UPDATE punches SET disregarded = false, disregard_reason = NULL, disregarded_by = NULL '
      'WHERE id = @id AND company_id = @c RETURNING id',
      {'id': requireUuid(id), 'c': ctx.companyId},
    );
    if (row == null) throw const ApiError.notFound('Marcação não encontrada');
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'restore', entity: 'punch', entityId: id, ip: req.clientIp);
    final full = await app.db.one('$punchSelectSql WHERE p.id = @id', {'id': id});
    return jsonResponse(map.punch(full!, ctx.offset));
  }

  /// Exclui apenas marcações incluídas manualmente (originais são imutáveis).
  Future<Response> _delete(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    await _ensurePunchOpen(ctx, id);
    final row = await app.db.one('SELECT origin FROM punches WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (row == null) throw const ApiError.notFound('Marcação não encontrada');
    if (row['origin'] == 'O') {
      throw const ApiError.conflict('Marcações originais não podem ser excluídas (Portaria 671). Use "desconsiderar".');
    }
    await app.db.execute('DELETE FROM punches WHERE id = @id', {'id': id});
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'punch', entityId: id, ip: req.clientIp);
    return noContent();
  }
}

extension ReceiptJson on PunchReceipt {
  Map<String, Object?> toJsonMap() => {
        'title': PunchReceipt.title,
        'nsr': nsr,
        'hash': hash,
        'fields': [for (final (k, v) in fields()) {'label': k, 'value': v}],
        'text': toText(),
      };
}
