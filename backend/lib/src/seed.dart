import 'dart:math';

import 'package:logging/logging.dart';
import 'package:pontomax_core/pontomax_core.dart';

import 'app.dart';
import 'db/database.dart';
import 'routes/auth_routes.dart';

final _log = Logger('seed');

/// Dados de demonstração (idempotente).
///
/// Acesso: `admin@pontomax.app` / `pontomax123` (proprietário) e
/// `ana@pontomax.app` / `pontomax123` (colaboradora).
Future<void> seedDemo(App app) async {
  final exists = await app.db.one("SELECT id FROM users WHERE email = 'admin@pontomax.app'");
  if (exists != null) {
    _log.info('Dados de demonstração já existem');
    return;
  }
  _log.info('Criando dados de demonstração...');
  final rnd = Random(42);
  final password = app.passwords.hash('pontomax123');

  await app.db.tx((tx) async {
    final company = await AuthRoutes.createCompany(tx, {
      'name': 'Padaria Pão Dourado',
      'legal_name': 'Pão Dourado Alimentos Ltda',
      'document': Documents.cnpjFromBase('123456780001'),
    });
    final c = company['id'] as String;
    await tx.execute(
      "UPDATE companies SET address = 'Av. Paulista, 1000', city = 'São Paulo', state = 'SP', "
      "settings = settings || '{\"require_geofence\": true, \"reminders\": true}'::jsonb WHERE id = @c",
      {'c': c},
    );

    Future<String> named(String table, String name) async =>
        (await tx.one('INSERT INTO $table (company_id, name) VALUES (@c, @n) RETURNING id', {'c': c, 'n': name}))!['id']
            as String;

    final depAdm = await named('departments', 'Administrativo');
    final depProd = await named('departments', 'Produção');
    final depLoja = await named('departments', 'Loja');
    final posGer = await named('positions', 'Gerente');
    final posPad = await named('positions', 'Padeiro(a)');
    final posAte = await named('positions', 'Atendente');
    final posCai = await named('positions', 'Operador(a) de caixa');

    final defaultSchedule = (await tx.one('SELECT id FROM schedules WHERE company_id = @c', {'c': c}))!['id'] as String;
    final early = ScheduleDefinition(
      name: 'Produção 06h-15h (banco de horas)',
      regime: CompensationRegime.hourBank,
      days: [
        for (var i = 0; i < 6; i++)
          DayTemplate.work([WorkInterval.hm('06:00', '10:00'), WorkInterval.hm('11:00', i == 5 ? '13:00' : '14:20')]),
        DayTemplate.off,
      ],
    );
    final earlyId = (await tx.one('INSERT INTO schedules (company_id, name, definition) VALUES (@c, @n, @d) RETURNING id',
        {'c': c, 'n': early.name, 'd': early.toJson()..remove('id')..remove('name')}))!['id'] as String;
    final nowWall = TimeFmt.toWall(app.now(), -180);
    final today = LocalDate.fromDateTime(nowWall);
    final shift = ScheduleDefinition.twelveByThirtySix(anchor: today.addDays(-30), name: '12x36 Loja 07h-19h', regime: CompensationRegime.hybrid);
    final shiftId = (await tx.one('INSERT INTO schedules (company_id, name, definition) VALUES (@c, @n, @d) RETURNING id',
        {'c': c, 'n': shift.name, 'd': shift.toJson()..remove('id')..remove('name')}))!['id'] as String;

    final fence = (await tx.one(
      "INSERT INTO geofences (company_id, name, lat, lng, radius, address) VALUES (@c, 'Loja Paulista', -23.564224, -46.652857, 200, 'Av. Paulista, 1000 - São Paulo/SP') RETURNING id",
      {'c': c},
    ))!['id'] as String;

    final people = [
      ('Administrador Demo', 'admin@pontomax.app', 'owner', depAdm, posGer, defaultSchedule, '001'),
      ('Bruno Gestor', 'bruno@pontomax.app', 'manager', depLoja, posGer, defaultSchedule, '002'),
      ('Ana Souza', 'ana@pontomax.app', 'employee', depLoja, posAte, defaultSchedule, '003'),
      ('Carlos Lima', 'carlos@pontomax.app', 'employee', depProd, posPad, earlyId, '004'),
      ('Daniela Rocha', 'daniela@pontomax.app', 'employee', depProd, posPad, earlyId, '005'),
      ('Eduardo Alves', 'eduardo@pontomax.app', 'employee', depLoja, posCai, shiftId, '006'),
      ('Fernanda Dias', 'fernanda@pontomax.app', 'employee', depLoja, posAte, defaultSchedule, '007'),
    ];
    final members = <String, (String, String, ScheduleDefinition)>{};
    var cpfBase = 123456700;
    for (final (name, email, role, dep, pos, sched, reg) in people) {
      final cpf = Documents.cpfFromBase('${cpfBase++}');
      final u = (await tx.one(
        'INSERT INTO users (name, email, cpf, password_hash) VALUES (@n, @e, @cpf, @p) RETURNING id',
        {'n': name, 'e': email, 'cpf': cpf, 'p': password},
      ))!['id'] as String;
      final m = (await tx.one(
        '''
        INSERT INTO members (company_id, user_id, role, registration, department_id, position_id, schedule_id,
          admission_date, badge_code, pin_hash)
        VALUES (@c, @u, @role, @reg, @dep, @pos, @sch, @adm, @badge, @pin) RETURNING id''',
        {
          'c': c,
          'u': u,
          'role': role,
          'reg': reg,
          'dep': dep,
          'pos': pos,
          'sch': sched,
          'adm': today.addDays(-60).toString(),
          'badge': 'PMX-$reg',
          'pin': app.passwords.hash('1234'),
        },
      ))!['id'] as String;
      await tx.execute('INSERT INTO member_geofences (member_id, geofence_id) VALUES (@m, @g)', {'m': m, 'g': fence});
      await app.punches.employeeEvent(db: tx, companyId: c, memberId: m, operation: 'I', cpf: cpf, name: name, responsibleCpf: cpf);
      final def = sched == earlyId ? early : (sched == shiftId ? shift : ScheduleDefinition.standard44());
      members[email] = (m, cpf, def);
    }

    // Marcações dos últimos 30 dias com variações realistas.
    var nsr = (await tx.one('SELECT last_nsr FROM companies WHERE id = @c', {'c': c}))!['last_nsr'] as int;
    var hash = '';
    final rows = <(DateTime, String, String)>[];
    for (final entry in members.entries) {
      final (memberId, cpf, def) = entry.value;
      for (var i = 60; i >= 0; i--) {
        final day = today.addDays(-i);
        final t = def.templateFor(day);
        if (!t.workDay || t.intervals.isEmpty) continue;
        if (BrazilHolidays.national(day.year).any((h) => h.date == day)) continue;
        if (i > 0 && rnd.nextDouble() < 0.04) continue; // falta ocasional
        for (var k = 0; k < t.intervals.length; k++) {
          final iv = t.intervals[k];
          final jitterIn = rnd.nextInt(12) - 6 + (rnd.nextDouble() < 0.08 ? 15 : 0);
          final jitterOut = rnd.nextInt(10) - 3 + (rnd.nextDouble() < 0.15 ? 40 : 0);
          final forget = rnd.nextDouble() < 0.02 && k == t.intervals.length - 1;
          final inAt = day.toDateTime().add(Duration(minutes: iv.start + jitterIn));
          final outAt = day.toDateTime().add(Duration(minutes: iv.end + jitterOut));
          if (inAt.isBefore(nowWall)) rows.add((inAt, memberId, cpf));
          if (!forget && outAt.isBefore(nowWall)) rows.add((outAt, memberId, cpf));
        }
      }
    }
    rows.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (wall, memberId, cpf) in rows) {
      nsr++;
      final recorded = wall.add(Duration(seconds: rnd.nextInt(5)));
      final afd = AfdPunch(
        nsr: nsr,
        punchWall: wall,
        cpf: cpf,
        recordedWall: recorded,
        collector: '01',
        offline: false,
        offsetMinutes: -180,
      );
      hash = afd.computeHash(hash);
      await tx.execute(
        '''
        INSERT INTO punches (company_id, member_id, nsr, punched_at, recorded_at, source, method, origin,
          lat, lng, accuracy, inside_geofence, geofence_id, distance, hash)
        VALUES (@c, @m, @nsr, @at, @rec, 'mobile', 'app', 'O', @lat, @lng, 12, true, @g, @dist, @h)''',
        {
          'c': c,
          'm': memberId,
          'nsr': nsr,
          'at': TimeFmt.fromWall(wall, -180),
          'rec': TimeFmt.fromWall(recorded, -180),
          'lat': -23.564224 + (rnd.nextDouble() - 0.5) * 0.001,
          'lng': -46.652857 + (rnd.nextDouble() - 0.5) * 0.001,
          'g': fence,
          'dist': rnd.nextDouble() * 60,
          'h': hash,
        },
      );
    }
    await tx.execute('UPDATE companies SET last_nsr = @n, last_hash = @h WHERE id = @c', {'n': nsr, 'h': hash, 'c': c});

    // Solicitações, mensagens e um quiosque.
    final ana = members['ana@pontomax.app']!.$1;
    final bruno = members['bruno@pontomax.app']!.$1;
    await tx.execute(
      "INSERT INTO requests (company_id, member_id, type, date, times, reason) VALUES (@c, @m, 'forgot_punch', @d, '{18:02}', 'Esqueci de registrar a saída')",
      {'c': c, 'm': ana, 'd': today.addDays(-2).toString()},
    );
    await tx.execute(
      "INSERT INTO requests (company_id, member_id, type, date, reason) VALUES (@c, @m, 'medical', @d, 'Consulta médica — atestado anexo')",
      {'c': c, 'm': members['carlos@pontomax.app']!.$1, 'd': today.addDays(-5).toString()},
    );
    await _message(tx, c, ana, bruno, 'Bom dia, Bruno! Posso trocar minha folga de sábado?');
    await _message(tx, c, bruno, ana, 'Bom dia, Ana! Pode sim, já ajusto na escala.');
    await tx.execute(
      "INSERT INTO devices (company_id, name, geofence_id, activation_code, activation_expires_at) VALUES (@c, 'Tablet da entrada', @g, 'DEMO2026', now() + interval '365 days')",
      {'c': c, 'g': fence},
    );
    await tx.execute(
      "INSERT INTO notes (member_id, title, body, pinned) VALUES (@m, 'Lembrete', 'Levar atestado na segunda-feira.', true)",
      {'m': ana},
    );
  });
  _log.info('Dados de demonstração criados: admin@pontomax.app / pontomax123');
}

Future<void> _message(Db tx, String c, String from, String to, String body) => tx.execute(
      'INSERT INTO messages (company_id, from_member_id, to_member_id, body) VALUES (@c, @f, @t, @b)',
      {'c': c, 'f': from, 't': to, 'b': body},
    );
