import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/crypto_utils.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';
import 'auth_routes.dart';

/// Empresa, configurações e cadastros auxiliares (departamentos, cargos,
/// feriados, perímetros, escalas e dispositivos).
class CompanyRoutes {
  final App app;
  CompanyRoutes(this.app);
  Mappers get map => Mappers(app);

  Router get router => Router()
    ..get('/company', _getCompany)
    ..put('/company', _updateCompany)
    ..put('/company/settings', _updateSettings)
    ..post('/companies', _createCompany)
    // Departamentos e cargos
    ..get('/departments', (Request r) => _listNamed(r, 'departments', 'department_id'))
    ..post('/departments', (Request r) => _createNamed(r, 'departments'))
    ..put('/departments/<id>', (Request r, String id) => _updateNamed(r, 'departments', id))
    ..delete('/departments/<id>', (Request r, String id) => _deleteNamed(r, 'departments', id))
    ..get('/positions', (Request r) => _listNamed(r, 'positions', 'position_id'))
    ..post('/positions', (Request r) => _createNamed(r, 'positions'))
    ..put('/positions/<id>', (Request r, String id) => _updateNamed(r, 'positions', id))
    ..delete('/positions/<id>', (Request r, String id) => _deleteNamed(r, 'positions', id))
    // Feriados
    ..get('/holidays', _listHolidays)
    ..post('/holidays', _createHoliday)
    ..post('/holidays/import-national', _importNational)
    ..put('/holidays/<id>', _updateHoliday)
    ..delete('/holidays/<id>', _deleteHoliday)
    // Perímetros
    ..get('/geofences', _listGeofences)
    ..post('/geofences', _createGeofence)
    ..put('/geofences/<id>', _updateGeofence)
    ..delete('/geofences/<id>', _deleteGeofence)
    // Escalas
    ..get('/schedules', _listSchedules)
    ..get('/schedules/<id>', _getSchedule)
    ..post('/schedules', _createSchedule)
    ..put('/schedules/<id>', _updateSchedule)
    ..delete('/schedules/<id>', _deleteSchedule)
    // Dispositivos (quiosques)
    ..get('/devices', _listDevices)
    ..post('/devices', _createDevice)
    ..put('/devices/<id>', _updateDevice)
    ..post('/devices/<id>/activation', _newActivation)
    ..delete('/devices/<id>', _deleteDevice);

  // ---------------------------------------------------------------------------
  // Empresa
  // ---------------------------------------------------------------------------

  Future<Response> _getCompany(Request req) async {
    final ctx = await app.sessions.member(req);
    final row = await app.db.one('SELECT * FROM companies WHERE id = @id', {'id': ctx.companyId});
    return jsonResponse(map.company(row!));
  }

  Future<Response> _updateCompany(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final body = await readJson(req);
    final document = body.containsKey('document') ? Documents.onlyAlnum(body.optStr('document')) : null;
    if (document != null && document.isNotEmpty && !Documents.isValidCnpj(document) && !Documents.isValidCpf(document)) {
      throw const ApiError.badRequest('CNPJ/CPF inválido');
    }
    final offset = body.optInt('utc_offset_minutes');
    if (offset != null && (offset < -300 || offset > -120)) {
      throw const ApiError.badRequest('Fuso horário inválido para o Brasil');
    }
    final row = await app.db.tx((tx) async {
      final row = await tx.one(
        '''
        UPDATE companies SET
          name = COALESCE(@name, name),
          legal_name = COALESCE(@legal, legal_name),
          document = COALESCE(@doc, document),
          document_type = COALESCE(@dtype, document_type),
          cno_caepf = COALESCE(@cno, cno_caepf),
          address = COALESCE(@addr, address),
          city = COALESCE(@city, city),
          state = COALESCE(@state, state),
          timezone = COALESCE(@tz, timezone),
          utc_offset_minutes = COALESCE(@off, utc_offset_minutes),
          updated_at = now()
        WHERE id = @id RETURNING *''',
        {
          'id': ctx.companyId,
          'name': body.optStr('name'),
          'legal': body.optStr('legal_name'),
          'doc': document,
          'dtype': document == null ? null : (document.length == 11 ? '2' : '1'),
          'cno': body.containsKey('cno_caepf') ? Documents.onlyDigits(body.optStr('cno_caepf')) : null,
          'addr': body.optStr('address'),
          'city': body.optStr('city'),
          'state': body.optStr('state'),
          'tz': body.optStr('timezone'),
          'off': offset,
        },
      );
      final identityChanged = ['name', 'legal_name', 'document', 'cno_caepf', 'address', 'city', 'state']
          .any(body.containsKey);
      if (identityChanged) {
        await app.punches.employerEvent(db: tx, companyId: ctx.companyId, responsibleCpf: ctx.user.cpf);
      }
      await app.audit.log(
        db: tx,
        companyId: ctx.companyId,
        userId: ctx.user.id,
        action: 'update',
        entity: 'company',
        entityId: ctx.companyId,
        data: body,
        ip: req.clientIp,
      );
      return row;
    });
    return jsonResponse(map.company(row!));
  }

  Future<Response> _updateSettings(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireAdmin();
    final body = await readJson(req);
    final current = (ctx.company['settings'] as Map).cast<String, Object?>();
    final merged = {...current, ...body};
    // Normaliza pelos campos conhecidos (mantendo extras como default_schedule_id).
    final normalized = {...merged, ...CompanySettings.fromJson(merged).toJson()};
    final closing = normalized['closing_day'] as int;
    if (closing < 0 || closing > 28) throw const ApiError.badRequest('Dia de fechamento deve estar entre 0 e 28');
    final row = await app.db.one(
      'UPDATE companies SET settings = @s, updated_at = now() WHERE id = @id RETURNING *',
      {'s': normalized, 'id': ctx.companyId},
    );
    await app.audit.log(
      companyId: ctx.companyId,
      userId: ctx.user.id,
      action: 'update',
      entity: 'settings',
      data: body,
      ip: req.clientIp,
    );
    return jsonResponse(map.company(row!));
  }

  /// Nova empresa para o mesmo usuário (multiempresa / contadores).
  Future<Response> _createCompany(Request req) async {
    final user = await app.sessions.authenticate(req);
    final body = await readJson(req);
    final name = body.str('name', label: 'nome da empresa');
    final document = Documents.onlyAlnum(body.optStr('document'));
    if (document.isNotEmpty && !Documents.isValidCnpj(document) && !Documents.isValidCpf(document)) {
      throw const ApiError.badRequest('CNPJ/CPF inválido');
    }
    final company = await app.db.tx((tx) async {
      final c = await AuthRoutes.createCompany(tx, {
        'name': name,
        'legal_name': body.optStr('legal_name') ?? name,
        'document': document,
        'document_type': document.length == 11 ? '2' : '1',
      });
      await tx.execute(
        "INSERT INTO members (company_id, user_id, role, admission_date) VALUES (@c, @u, 'owner', @d)",
        {'c': c['id'], 'u': user.id, 'd': LocalDate.fromDateTime(app.now()).toString()},
      );
      await app.punches.employerEvent(db: tx, companyId: c['id'] as String, responsibleCpf: user.cpf);
      return c;
    });
    return created(map.company(company));
  }

  // ---------------------------------------------------------------------------
  // Departamentos / cargos
  // ---------------------------------------------------------------------------

  Future<Response> _listNamed(Request req, String table, String fk) async {
    final ctx = await app.sessions.member(req);
    final rows = await app.db.query(
      'SELECT t.*, (SELECT count(*)::int FROM members m WHERE m.$fk = t.id AND m.active) AS count '
      'FROM $table t WHERE t.company_id = @c ORDER BY t.name',
      {'c': ctx.companyId},
    );
    return jsonResponse([
      for (final r in rows)
        NamedEntity(
          id: r['id'] as String,
          name: r['name'] as String,
          description: r['description'] as String?,
          count: r['count'] as int,
        ).toJson(),
    ]);
  }

  Future<Response> _createNamed(Request req, String table) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final row = await app.db.one(
      'INSERT INTO $table (company_id, name, description) VALUES (@c, @n, @d) RETURNING *',
      {'c': ctx.companyId, 'n': body.str('name', label: 'nome'), 'd': body.optStr('description')},
    );
    await app.audit.log(
        companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: table, entityId: row!['id'] as String, data: body);
    return created(NamedEntity(id: row['id'] as String, name: row['name'] as String, description: row['description'] as String?).toJson());
  }

  Future<Response> _updateNamed(Request req, String table, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final row = await app.db.one(
      'UPDATE $table SET name = COALESCE(@n, name), description = COALESCE(@d, description) '
      'WHERE id = @id AND company_id = @c RETURNING *',
      {'id': requireUuid(id), 'c': ctx.companyId, 'n': body.optStr('name'), 'd': body.optStr('description')},
    );
    if (row == null) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'update', entity: table, entityId: id, data: body);
    return jsonResponse(NamedEntity(id: row['id'] as String, name: row['name'] as String, description: row['description'] as String?).toJson());
  }

  Future<Response> _deleteNamed(Request req, String table, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final n = await app.db.execute('DELETE FROM $table WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: table, entityId: id);
    return noContent();
  }

  // ---------------------------------------------------------------------------
  // Feriados
  // ---------------------------------------------------------------------------

  Future<Response> _listHolidays(Request req) async {
    final ctx = await app.sessions.member(req);
    final year = req.qInt('year', LocalDate.fromDateTime(TimeFmt.toWall(app.now(), ctx.offset)).year);
    final rows = await app.db.query(
      'SELECT * FROM holidays WHERE company_id = @c AND (recurring OR extract(year FROM date) = @y) ORDER BY extract(month FROM date), extract(day FROM date)',
      {'c': ctx.companyId, 'y': year},
    );
    return jsonResponse([for (final r in rows) map.holiday(r)]);
  }

  Future<Response> _createHoliday(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final scope = body.optStr('scope') ?? 'company';
    if (!const {'national', 'state', 'city', 'company'}.contains(scope)) {
      throw const ApiError.badRequest('Abrangência inválida');
    }
    final row = await app.db.one(
      'INSERT INTO holidays (company_id, date, name, scope, recurring) VALUES (@c, @d, @n, @s, @r) RETURNING *',
      {
        'c': ctx.companyId,
        'd': body.date('date').toString(),
        'n': body.str('name', label: 'nome'),
        's': scope,
        'r': body.optBool('recurring') ?? false,
      },
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'holiday', entityId: row!['id'] as String, data: body);
    return created(map.holiday(row));
  }

  Future<Response> _importNational(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final year = body.optInt('year') ?? LocalDate.fromDateTime(app.now()).year;
    final includeOptional = body.optBool('include_optional') ?? false;
    var count = 0;
    for (final h in [...BrazilHolidays.national(year), if (includeOptional) ...BrazilHolidays.optional(year)]) {
      final exists = await app.db.one('SELECT id FROM holidays WHERE company_id = @c AND date = @d',
          {'c': ctx.companyId, 'd': h.date.toString()});
      if (exists != null) continue;
      await app.db.execute(
        "INSERT INTO holidays (company_id, date, name, scope) VALUES (@c, @d, @n, 'national')",
        {'c': ctx.companyId, 'd': h.date.toString(), 'n': h.name},
      );
      count++;
    }
    return jsonResponse({'imported': count});
  }

  Future<Response> _updateHoliday(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final row = await app.db.one(
      '''
      UPDATE holidays SET date = COALESCE(@d::date, date), name = COALESCE(@n, name),
        scope = COALESCE(@s, scope), recurring = COALESCE(@r, recurring)
      WHERE id = @id AND company_id = @c RETURNING *''',
      {
        'id': requireUuid(id),
        'c': ctx.companyId,
        'd': body.optDate('date')?.toString(),
        'n': body.optStr('name'),
        's': body.optStr('scope'),
        'r': body.optBool('recurring'),
      },
    );
    if (row == null) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'update', entity: 'holiday', entityId: id, data: body);
    return jsonResponse(map.holiday(row));
  }

  Future<Response> _deleteHoliday(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final n = await app.db.execute('DELETE FROM holidays WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'holiday', entityId: id);
    return noContent();
  }

  // ---------------------------------------------------------------------------
  // Perímetros (geocercas)
  // ---------------------------------------------------------------------------

  Future<Response> _listGeofences(Request req) async {
    final ctx = await app.sessions.member(req);
    final rows = await app.db.query('SELECT * FROM geofences WHERE company_id = @c ORDER BY name', {'c': ctx.companyId});
    return jsonResponse([for (final r in rows) map.geofence(r)]);
  }

  Map<String, Object?> _geofenceParams(Map<String, dynamic> body, {bool partial = false}) {
    final lat = body.optDouble('lat');
    final lng = body.optDouble('lng');
    final radius = body.optDouble('radius');
    if (!partial && (lat == null || lng == null)) throw const ApiError.badRequest('Latitude e longitude são obrigatórias');
    if (lat != null && (lat < -90 || lat > 90)) throw const ApiError.badRequest('Latitude inválida');
    if (lng != null && (lng < -180 || lng > 180)) throw const ApiError.badRequest('Longitude inválida');
    if (radius != null && (radius < 10 || radius > 50000)) {
      throw const ApiError.badRequest('O raio deve estar entre 10 m e 50 km');
    }
    return {'lat': lat, 'lng': lng, 'radius': radius, 'addr': body.optStr('address'), 'active': body.optBool('active')};
  }

  Future<Response> _createGeofence(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final p = _geofenceParams(body);
    final row = await app.db.one(
      'INSERT INTO geofences (company_id, name, lat, lng, radius, address) '
      'VALUES (@c, @n, @lat, @lng, COALESCE(@radius::float8, 150), COALESCE(@addr, \'\')) RETURNING *',
      {'c': ctx.companyId, 'n': body.str('name', label: 'nome'), ...p}..remove('active'),
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'geofence', entityId: row!['id'] as String, data: body);
    return created(map.geofence(row));
  }

  Future<Response> _updateGeofence(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final p = _geofenceParams(body, partial: true);
    final row = await app.db.one(
      '''
      UPDATE geofences SET name = COALESCE(@n, name), lat = COALESCE(@lat::float8, lat), lng = COALESCE(@lng::float8, lng),
        radius = COALESCE(@radius::float8, radius), address = COALESCE(@addr, address), active = COALESCE(@active, active)
      WHERE id = @id AND company_id = @c RETURNING *''',
      {'id': requireUuid(id), 'c': ctx.companyId, 'n': body.optStr('name'), ...p},
    );
    if (row == null) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'update', entity: 'geofence', entityId: id, data: body);
    return jsonResponse(map.geofence(row));
  }

  Future<Response> _deleteGeofence(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final n = await app.db.execute('DELETE FROM geofences WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'geofence', entityId: id);
    return noContent();
  }

  // ---------------------------------------------------------------------------
  // Escalas
  // ---------------------------------------------------------------------------

  Map<String, Object?> _scheduleJson(Map<String, dynamic> r) => ScheduleEntity(
        id: r['id'] as String,
        name: r['name'] as String,
        definition: {
          ...(r['definition'] as Map).cast<String, Object?>(),
          'id': r['id'],
          'name': r['name'],
        },
        membersCount: r['members_count'] as int? ?? 0,
      ).toJson();

  Future<Response> _listSchedules(Request req) async {
    final ctx = await app.sessions.member(req);
    final rows = await app.db.query(
      'SELECT s.*, (SELECT count(*)::int FROM members m WHERE m.schedule_id = s.id AND m.active) AS members_count '
      'FROM schedules s WHERE s.company_id = @c AND s.active ORDER BY s.name',
      {'c': ctx.companyId},
    );
    return jsonResponse([for (final r in rows) _scheduleJson(r)]);
  }

  Future<Response> _getSchedule(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final row = await app.db.one('SELECT * FROM schedules WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (row == null) throw const ApiError.notFound();
    return jsonResponse(_scheduleJson(row));
  }

  ScheduleDefinition _parseSchedule(Map<String, dynamic> body) {
    final def = body.obj('definition');
    final ScheduleDefinition s;
    try {
      s = ScheduleDefinition.fromJson(def.cast<String, Object?>());
    } on Object catch (e) {
      throw ApiError.badRequest('Escala inválida: $e');
    }
    if (s.days.isEmpty) throw const ApiError.badRequest('A escala precisa de ao menos um dia');
    if (s.type == ScheduleType.weekly && s.days.length != 7) {
      throw const ApiError.badRequest('A escala semanal precisa de 7 dias');
    }
    if (s.type == ScheduleType.cycle && s.cycleAnchor == null) {
      throw const ApiError.badRequest('Informe a data de início do ciclo');
    }
    for (final d in s.days) {
      for (var i = 1; i < d.intervals.length; i++) {
        if (d.intervals[i].start < d.intervals[i - 1].end) {
          throw const ApiError.badRequest('Os intervalos de um dia não podem se sobrepor');
        }
      }
      if (d.expectedMinutes > 16 * 60) throw const ApiError.badRequest('Jornada diária acima de 16 horas');
    }
    return s;
  }

  Future<Response> _createSchedule(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final name = body.str('name', label: 'nome');
    final s = _parseSchedule(body);
    final row = await app.db.one(
      'INSERT INTO schedules (company_id, name, definition) VALUES (@c, @n, @d) RETURNING *',
      {'c': ctx.companyId, 'n': name, 'd': s.toJson()..remove('id')..remove('name')},
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'schedule', entityId: row!['id'] as String, data: {'name': name});
    return created(_scheduleJson(row));
  }

  Future<Response> _updateSchedule(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final s = body.containsKey('definition') ? _parseSchedule(body) : null;
    final row = await app.db.one(
      'UPDATE schedules SET name = COALESCE(@n, name), definition = COALESCE(@d, definition), updated_at = now() '
      'WHERE id = @id AND company_id = @c RETURNING *',
      {
        'id': requireUuid(id),
        'c': ctx.companyId,
        'n': body.optStr('name'),
        'd': s == null ? null : (s.toJson()..remove('id')..remove('name')),
      },
    );
    if (row == null) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'update', entity: 'schedule', entityId: id, data: body);
    return jsonResponse(_scheduleJson(row));
  }

  Future<Response> _deleteSchedule(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final inUse = await app.db.one('SELECT count(*)::int AS n FROM members WHERE schedule_id = @id AND active', {'id': requireUuid(id)});
    if ((inUse!['n'] as int) > 0) {
      throw const ApiError.conflict('Escala em uso por colaboradores. Altere a escala deles antes de excluir.');
    }
    final n = await app.db.execute('UPDATE schedules SET active = false WHERE id = @id AND company_id = @c',
        {'id': id, 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'schedule', entityId: id);
    return noContent();
  }

  // ---------------------------------------------------------------------------
  // Dispositivos (modo quiosque)
  // ---------------------------------------------------------------------------

  static const _deviceSelect =
      'SELECT d.*, g.name AS geofence_name FROM devices d LEFT JOIN geofences g ON g.id = d.geofence_id';

  Future<Response> _listDevices(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final rows = await app.db.query('$_deviceSelect WHERE d.company_id = @c ORDER BY d.name', {'c': ctx.companyId});
    return jsonResponse([
      for (final r in rows)
        map.device({...r, 'activation_code': r['token_hash'] == null ? r['activation_code'] : null}),
    ]);
  }

  Future<Response> _createDevice(Request req) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final code = randomCode(8);
    final row = await app.db.one(
      'INSERT INTO devices (company_id, name, geofence_id, activation_code, activation_expires_at) '
      'VALUES (@c, @n, @g, @code, @exp) RETURNING id',
      {
        'c': ctx.companyId,
        'n': body.str('name', label: 'nome'),
        'g': optUuid(body.optStr('geofence_id'), 'geofence_id'),
        'code': code,
        'exp': app.now().add(const Duration(days: 7)),
      },
    );
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'create', entity: 'device', entityId: row!['id'] as String, data: body);
    final full = await app.db.one('$_deviceSelect WHERE d.id = @id', {'id': row['id']});
    return created(map.device(full!));
  }

  Future<Response> _updateDevice(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final body = await readJson(req);
    final n = await app.db.execute(
      '''
      UPDATE devices SET name = COALESCE(@n, name), active = COALESCE(@a, active),
        geofence_id = CASE WHEN @hasG THEN @g::uuid ELSE geofence_id END
      WHERE id = @id AND company_id = @c''',
      {
        'id': requireUuid(id),
        'c': ctx.companyId,
        'n': body.optStr('name'),
        'a': body.optBool('active'),
        'hasG': body.containsKey('geofence_id'),
        'g': optUuid(body.optStr('geofence_id'), 'geofence_id'),
      },
    );
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'update', entity: 'device', entityId: id, data: body);
    final full = await app.db.one('$_deviceSelect WHERE d.id = @id', {'id': id});
    return jsonResponse(map.device({...full!, 'activation_code': null}));
  }

  /// Gera novo código de ativação (revoga o token atual do quiosque).
  Future<Response> _newActivation(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final code = randomCode(8);
    final n = await app.db.execute(
      'UPDATE devices SET activation_code = @code, activation_expires_at = @exp, token_hash = NULL '
      'WHERE id = @id AND company_id = @c',
      {'id': requireUuid(id), 'c': ctx.companyId, 'code': code, 'exp': app.now().add(const Duration(days: 7))},
    );
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'reactivate', entity: 'device', entityId: id);
    final full = await app.db.one('$_deviceSelect WHERE d.id = @id', {'id': id});
    return jsonResponse(map.device(full!));
  }

  Future<Response> _deleteDevice(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    ctx.requireManager();
    final n = await app.db.execute('DELETE FROM devices WHERE id = @id AND company_id = @c',
        {'id': requireUuid(id), 'c': ctx.companyId});
    if (n == 0) throw const ApiError.notFound();
    await app.audit.log(companyId: ctx.companyId, userId: ctx.user.id, action: 'delete', entity: 'device', entityId: id);
    return noContent();
  }
}
