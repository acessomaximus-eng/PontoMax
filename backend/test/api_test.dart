import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:pontomax_backend/src/seed.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestApi api;

  setUp(() async => api = await TestApi.create());
  tearDown(() async => api.close());

  group('Autenticação', () {
    test('cadastro, login, refresh e /me', () async {
      final (token, companyId, _) = await api.register();
      final me = await api.get('/me', token: token);
      expect(me.status, 200);
      expect(me.json['company']['id'], companyId);
      expect(me.json['member']['role'], 'owner');

      final login = await api.post('/auth/login', {'email': 'DONO@empresa.com', 'password': 'senha1234'});
      expect(login.status, 200);
      final refresh = await api.post('/auth/refresh', {'refresh_token': login.json['refresh_token']});
      expect(refresh.status, 200);
      // Refresh token é rotacionado (uso único).
      final again = await api.post('/auth/refresh', {'refresh_token': login.json['refresh_token']});
      expect(again.status, 401);
    });

    test('senha incorreta e cadastro duplicado', () async {
      await api.register();
      final bad = await api.post('/auth/login', {'email': 'dono@empresa.com', 'password': 'errada123'});
      expect(bad.status, 401);
      expect(bad.json['error']['code'], 'invalid_credentials');
      final dup = await api.post('/auth/register', {
        'company_name': 'X',
        'name': 'Y',
        'email': 'dono@empresa.com',
        'password': 'senha1234',
      });
      expect(dup.status, 409);
    });

    test('sem token retorna 401', () async {
      expect((await api.get('/members')).status, 401);
    });

    test('redefinição de senha por e-mail', () async {
      await api.register();
      await api.post('/auth/forgot', {'email': 'dono@empresa.com'});
      final mail = api.app.mailer.outbox.last.$3;
      final token = RegExp(r'token=([\w-]+)').firstMatch(mail)!.group(1);
      final r = await api.post('/auth/reset', {'token': token, 'password': 'novaSenha99'});
      expect(r.status, 200);
      await api.login('dono@empresa.com', 'novaSenha99');
    });
  });

  group('Cadastros e permissões', () {
    test('gestor cria colaborador; colaborador não acessa áreas de gestão', () async {
      final (token, company, _) = await api.register();
      final r = await api.post('/members', {
        'name': 'João Colaborador',
        'email': 'joao@empresa.com',
        'cpf': '111.444.777-35',
        'password': 'senha1234',
        'registration': '42',
      }, token: token, company: company);
      expect(r.status, 201, reason: '$r');
      expect(r.json['cpf'], '11144477735');

      final joao = await api.login('joao@empresa.com');
      expect((await api.get('/dashboard', token: joao)).status, 403);
      expect((await api.post('/departments', {'name': 'X'}, token: joao)).status, 403);
      final list = await api.get('/members', token: joao);
      expect(list.status, 200);
      // Colaborador vê dados completos apenas de si mesmo.
      final owner = list.list.firstWhere((m) => m['role'] == 'owner');
      expect(owner.containsKey('cpf'), isFalse);

      final invalid = await api.post('/members', {'name': 'X', 'email': 'x@x.com', 'cpf': '123'}, token: token);
      expect(invalid.status, 400);
    });

    test('departamentos, cargos, feriados, escalas e perímetros', () async {
      final (token, _, _) = await api.register();
      expect((await api.post('/departments', {'name': 'Vendas'}, token: token)).status, 201);
      expect((await api.post('/positions', {'name': 'Vendedor'}, token: token)).status, 201);
      final holidays = await api.get('/holidays?year=${DateTime.now().year}', token: token);
      expect(holidays.list.length, greaterThanOrEqualTo(9));
      final sched = await api.post('/schedules', {
        'name': '12x36',
        'definition': ScheduleDefinition.twelveByThirtySix(anchor: const LocalDate(2026, 10, 1)).toJson(),
      }, token: token);
      expect(sched.status, 201, reason: '$sched');
      final badSched = await api.post('/schedules', {
        'name': 'Ruim',
        'definition': {'type': 'weekly', 'days': []},
      }, token: token);
      expect(badSched.status, 400);
      final fence = await api.post('/geofences', {'name': 'Sede', 'lat': -23.55, 'lng': -46.63, 'radius': 100}, token: token);
      expect(fence.status, 201);
      final schedules = await api.get('/schedules', token: token);
      expect(schedules.list.length, 2);
    });
  });

  group('Marcações (REP-P)', () {
    test('NSR sequencial, hash encadeado, comprovante e AFD válido', () async {
      final (token, company, _) = await api.register();
      final p1 = await api.post('/punches', {'source': 'browser', 'lat': -23.55, 'lng': -46.63}, token: token);
      expect(p1.status, 201, reason: '$p1');
      final punch = p1.json['punch'];
      expect(punch['nsr'], greaterThan(0));
      expect((punch['hash'] as String).length, 64);
      expect(p1.json['receipt']['fields'], isNotEmpty);

      // Anti-duplicidade (menos de 1 minuto).
      final dup = await api.post('/punches', {'source': 'browser'}, token: token);
      expect(dup.status, 409);

      api.clock.advance(const Duration(hours: 4));
      final p2 = await api.post('/punches', {'source': 'mobile'}, token: token);
      expect(p2.status, 201);
      expect(p2.json['punch']['nsr'], (punch['nsr'] as int) + 1);

      final pdf = await api.get('/punches/${punch['id']}/receipt.pdf', token: token);
      expect(pdf.status, 200);
      expect(utf8.decode(pdf.bytes.take(4).toList()), '%PDF');

      final afd = await api.get('/reports/afd?from=2026-10-01&to=2026-10-31', token: token, company: company);
      expect(afd.status, 200);
      final content = latin1.decode(afd.bytes);
      final lines = content.trimRight().split('\r\n');
      expect(lines.first.length, 302);
      expect(lines.where((l) => l.length == 137 && l[9] == '7').length, 2);
      expect(lines.where((l) => l.length == 118 && l[9] == '5').length, 1);
      expect(AfdGenerator.verifyChain(content), isEmpty);

      final aej = await api.get('/reports/aej?from=2026-10-01&to=2026-10-31', token: token);
      expect(aej.status, 200);
      expect(latin1.decode(aej.bytes), contains('99|1|1|1|1|2|'));
    });

    test('perímetro obrigatório bloqueia marcação fora da geocerca', () async {
      final (token, _, _) = await api.register();
      await api.put('/company/settings', {'require_geofence': true}, token: token);
      await api.post('/geofences', {'name': 'Sede', 'lat': -23.550520, 'lng': -46.633308, 'radius': 100}, token: token);
      final noLoc = await api.post('/punches', {'source': 'mobile'}, token: token);
      expect(noLoc.json['error']['code'], 'location_required');
      final out = await api.post('/punches', {'source': 'mobile', 'lat': -23.561414, 'lng': -46.655881}, token: token);
      expect(out.status, 422);
      expect(out.json['error']['code'], 'outside_geofence');
      final inside = await api.post('/punches', {'source': 'mobile', 'lat': -23.5506, 'lng': -46.6334, 'accuracy': 10}, token: token);
      expect(inside.status, 201);
      expect(inside.json['punch']['inside_geofence'], isTrue);
      expect(inside.json['punch']['geofence_name'], 'Sede');
    });

    test('foto obrigatória e upload de arquivo com URL assinada', () async {
      final (token, _, _) = await api.register();
      await api.put('/company/settings', {'require_photo': true}, token: token);
      final noPhoto = await api.post('/punches', {'source': 'mobile'}, token: token);
      expect(noPhoto.json['error']['code'], 'photo_required');
      // PNG 1x1
      final png = base64.decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
      final up = await api.call('POST', '/files', rawBody: png, token: token, headers: {'content-type': 'image/png', 'x-filename': 'selfie.png'});
      expect(up.status, 201, reason: '$up');
      final p = await api.post('/punches', {'source': 'mobile', 'photo_file_id': up.json['id']}, token: token);
      expect(p.status, 201);
      final url = p.json['punch']['photo_url'] as String;
      final file = await api.get(url.replaceFirst('/api/v1', ''));
      expect(file.status, 200);
      expect(file.bytes, png);
    });

    test('sincronização off-line é idempotente', () async {
      final (token, _, _) = await api.register();
      final t = api.clock.value.subtract(const Duration(hours: 2)).toIso8601String();
      final batch = {
        'punches': [
          {'client_id': 'abc-1', 'punched_at': t, 'source': 'mobile'},
        ],
      };
      final r1 = await api.post('/punches/sync', batch, token: token);
      expect(r1.json['results'][0]['ok'], isTrue);
      expect(r1.json['results'][0]['punch']['offline'], isTrue);
      final r2 = await api.post('/punches/sync', batch, token: token);
      expect(r2.json['results'][0]['punch']['id'], r1.json['results'][0]['punch']['id']);
      final tooOld = await api.post('/punches/sync', {
        'punches': [
          {'client_id': 'abc-2', 'punched_at': api.clock.value.subtract(const Duration(days: 9)).toIso8601String()},
        ],
      }, token: token);
      expect(tooOld.json['results'][0]['ok'], isFalse);
    });

    test('tratamento: incluir, desconsiderar e não excluir originais', () async {
      final (token, company, member) = await api.register();
      final p = await api.post('/punches', {'source': 'browser'}, token: token);
      final id = p.json['punch']['id'];
      expect((await api.delete('/punches/$id', token: token)).status, 409);
      final dis = await api.post('/punches/$id/disregard', {'reason': 'Marcação em duplicidade'}, token: token);
      expect(dis.json['disregarded'], isTrue);
      final inc = await api.post('/punches/manual', {
        'member_id': member,
        'date': '2026-10-02',
        'time': '08:00',
        'reason': 'Esquecimento',
      }, token: token, company: company);
      expect(inc.status, 201);
      expect(inc.json['origin'], 'I');
      expect(inc.json['nsr'], isNull);
      expect((await api.delete('/punches/${inc.json['id']}', token: token)).status, 204);
      final audit = await api.get('/audit?entity=punch', token: token);
      expect(audit.list.map((a) => a['action']), containsAll(['disregard', 'include', 'delete']));
    });
  });

  group('Espelho de ponto e banco de horas', () {
    test('apuração do dia com hora extra e PDF do espelho', () async {
      final (token, company, member) = await api.register();
      // Escala padrão 44h: seg 08-12 / 13-18. Segunda, 5/10/2026.
      for (final (h, m) in [(8, 0), (12, 0), (13, 0), (19, 0)]) {
        api.clock.brt(2026, 10, 5, h, m);
        final r = await api.post('/punches', {'source': 'browser'}, token: token);
        expect(r.status, 201, reason: '$r');
      }
      api.clock.brt(2026, 10, 7, 10);
      final ts = await api.get('/timesheet?from=2026-10-05&to=2026-10-06', token: token, company: company);
      expect(ts.status, 200, reason: '$ts');
      final monday = ts.json['days'][0];
      expect(monday['worked'], 600);
      expect(monday['overtime'], {'50': 60});
      expect(ts.json['days'][1]['status'], 'absent');
      expect(ts.json['totals']['deficit'], 540);

      final pdf = await api.get('/timesheet.pdf?member_id=$member&from=2026-10-01&to=2026-10-31', token: token);
      expect(pdf.status, 200);
      expect(utf8.decode(pdf.bytes.take(4).toList()), '%PDF');

      final today = await api.get('/punches/today', token: token);
      expect(today.status, 200);

      final summary = await api.get('/reports/summary?from=2026-10-05&to=2026-10-06&bank=true', token: token);
      expect(summary.json['rows'][0]['overtime_total'], 60);
      final csv = await api.get('/reports/summary.csv?from=2026-10-05&to=2026-10-06', token: token);
      expect(utf8.decode(csv.bytes), contains('01:00'));
      final payroll = await api.get('/reports/payroll.csv?from=2026-10-05&to=2026-10-06', token: token);
      expect(utf8.decode(payroll.bytes), contains('HE50'));
    });

    test('assinatura do espelho e banco de horas manual', () async {
      final (token, _, member) = await api.register();
      api.clock.brt(2026, 11, 3, 9);
      final sign = await api.post('/timesheet/sign', {'from': '2026-10-01', 'to': '2026-10-31', 'agreed': true}, token: token);
      expect(sign.status, 201, reason: '$sign');
      final again = await api.post('/timesheet/sign', {'from': '2026-10-01', 'to': '2026-10-31'}, token: token);
      expect(again.status, 409);
      final ts = await api.get('/timesheet?from=2026-10-01&to=2026-10-31', token: token);
      expect(ts.json['signature'], isNotNull);

      final e = await api.post('/bank/entries', {'member_id': member, 'type': 'credit', 'minutes': 90, 'description': 'Evento'}, token: token);
      expect(e.status, 201);
      final bank = await api.get('/bank', token: token);
      expect(bank.status, 200);
      expect(bank.json['manual'], 90);
    });
  });

  group('Solicitações', () {
    test('colaborador solicita, gestor aprova e a marcação é incluída', () async {
      final (owner, company, _) = await api.register();
      await api.post('/members', {
        'name': 'Maria', 'email': 'maria@empresa.com', 'cpf': '39053344705', 'password': 'senha1234',
      }, token: owner, company: company);
      final maria = await api.login('maria@empresa.com');
      final r = await api.post('/requests', {
        'type': 'forgot_punch',
        'date': '2026-10-02',
        'times': ['08:00', '17:00'],
        'reason': 'Esqueci',
      }, token: maria);
      expect(r.status, 201, reason: '$r');
      final notifications = await api.get('/notifications', token: owner);
      expect(notifications.list.first['type'], 'request_created');

      final ok = await api.post('/requests/${r.json['id']}/approve', {'note': 'ok'}, token: owner);
      expect(ok.json['status'], 'approved');
      final twice = await api.post('/requests/${r.json['id']}/approve', {}, token: owner);
      expect(twice.status, 409);

      final punches = await api.get('/punches?from=2026-10-02&to=2026-10-02', token: maria);
      expect(punches.list.length, 2);
      expect(punches.list.every((p) => p['origin'] == 'I'), isTrue);

      final atestado = await api.post('/requests', {'type': 'medical', 'date': '2026-10-01', 'reason': 'Gripe'}, token: maria);
      await api.post('/requests/${atestado.json['id']}/approve', {}, token: owner);
      final absences = await api.get('/absences', token: maria);
      expect(absences.list.single['type'], 'medical');

      final reject = await api.post('/requests', {'type': 'allowance', 'date': '2026-10-03', 'reason': 'x'}, token: maria);
      final rej = await api.post('/requests/${reject.json['id']}/reject', {'note': 'Sem justificativa'}, token: owner);
      expect(rej.json['status'], 'rejected');
      final mariaNotes = await api.get('/notifications', token: maria);
      expect(mariaNotes.list.map((n) => n['type']), containsAll(['request_approved', 'request_rejected']));
    });
  });

  group('Quiosque e QR Code', () {
    test('ativação, QR dinâmico, PIN e crachá', () async {
      final (owner, company, _) = await api.register();
      final m = await api.post('/members', {
        'name': 'Pedro', 'email': 'pedro@empresa.com', 'cpf': '86288366757', 'password': 'senha1234',
        'registration': '77', 'pin': '4321', 'badge_code': 'CR-77',
      }, token: owner, company: company);
      expect(m.status, 201, reason: '$m');
      final dev = await api.post('/devices', {'name': 'Tablet'}, token: owner);
      final code = dev.json['activation_code'] as String;
      final act = await api.post('/kiosk/activate', {'code': code, 'platform': 'android'});
      expect(act.status, 200, reason: '$act');
      final deviceToken = act.json['device_token'] as String;
      expect((await api.post('/kiosk/activate', {'code': code})).status, 404);

      final bad = await api.post('/kiosk/punch', {'identifier': '77', 'pin': '0000'}, device: deviceToken);
      expect(bad.status, 401);
      final ok = await api.post('/kiosk/punch', {'identifier': '77', 'pin': '4321'}, device: deviceToken);
      expect(ok.status, 201, reason: '$ok');
      expect(ok.json['punch']['source'], 'device');
      api.clock.advance(const Duration(minutes: 5));
      final badge = await api.post('/kiosk/punch', {'badge_code': 'CR-77'}, device: deviceToken);
      expect(badge.json['punch']['method'], 'badge');

      api.clock.advance(const Duration(minutes: 5));
      final qr = await api.get('/kiosk/qr', device: deviceToken);
      final pedro = await api.login('pedro@empresa.com');
      final viaQr = await api.post('/punches', {'source': 'mobile', 'qr_token': qr.json['token']}, token: pedro);
      expect(viaQr.status, 201, reason: '$viaQr');
      expect(viaQr.json['punch']['method'], 'qr');
      api.clock.advance(const Duration(minutes: 5));
      final expired = await api.post('/punches', {'source': 'mobile', 'qr_token': qr.json['token']}, token: pedro);
      expect(expired.json['error']['code'], 'invalid_qr');
    });
  });

  group('Segurança', () {
    test('PIN do quiosque bloqueia após 5 erros', () async {
      final (owner, company, _) = await api.register();
      await api.post('/members', {
        'name': 'Rui', 'email': 'rui@empresa.com', 'cpf': '11144477735', 'password': 'senha1234',
        'registration': '9', 'pin': '2468',
      }, token: owner, company: company);
      final dev = await api.post('/devices', {'name': 'Tablet'}, token: owner);
      final act = await api.post('/kiosk/activate', {'code': dev.json['activation_code']});
      final deviceToken = act.json['device_token'] as String;
      for (var i = 0; i < 5; i++) {
        final r = await api.post('/kiosk/identify', {'identifier': '9', 'pin': '0000'}, device: deviceToken);
        expect(r.status, 401);
      }
      final blocked = await api.post('/kiosk/identify', {'identifier': '9', 'pin': '2468'}, device: deviceToken);
      expect(blocked.status, 429);
      api.clock.advance(const Duration(minutes: 11));
      final ok = await api.post('/kiosk/identify', {'identifier': '9', 'pin': '2468'}, device: deviceToken);
      expect(ok.status, 200);
      expect(ok.json['name'], 'Rui');
    });

    test('usuário de outra empresa é vinculado sem senha provisória', () async {
      final (ownerA, _, _) = await api.register(email: 'a@a.com', company: 'Empresa A');
      final (ownerB, _, _) = await api.register(email: 'b@b.com', company: 'Empresa B', cpf: '39053344705');
      final first = await api.post('/members', {'name': 'Zé', 'email': 'ze@x.com', 'cpf': '86288366757'}, token: ownerA);
      expect(first.json['temporary_password'], isNotNull);
      final second = await api.post('/members', {'name': 'Zé', 'email': 'ze@x.com', 'cpf': '86288366757'}, token: ownerB);
      expect(second.status, 201, reason: '$second');
      expect(second.json['temporary_password'], isNull);
      expect(second.json['existing_user'], isTrue);
      final ze = await api.login('ze@x.com', first.json['temporary_password'] as String);
      final me = await api.get('/me', token: ze);
      expect((me.json['memberships'] as List).length, 2);
    });
  });

  group('Fechamento de período', () {
    test('bloqueia tratamento até a reabertura', () async {
      final (token, company, member) = await api.register();
      api.clock.brt(2026, 11, 3, 9);
      final close = await api.post('/closings', {'from': '2026-10-01', 'to': '2026-10-31'}, token: token);
      expect(close.status, 201, reason: '$close');
      final blocked = await api.post('/punches/manual', {
        'member_id': member, 'date': '2026-10-02', 'time': '08:00', 'reason': 'x',
      }, token: token, company: company);
      expect(blocked.status, 409);
      expect(blocked.json['error']['code'], 'period_closed');
      final bank = await api.post('/bank/entries', {'member_id': member, 'type': 'credit', 'minutes': 30, 'date': '2026-10-10'}, token: token);
      expect(bank.json['error']['code'], 'period_closed');
      final ts = await api.get('/timesheet?from=2026-10-01&to=2026-10-31', token: token);
      expect((ts.json['closings'] as List).length, 1);
      // Fora do período fechado continua liberado.
      final ok = await api.post('/punches/manual', {
        'member_id': member, 'date': '2026-11-02', 'time': '08:00', 'reason': 'x',
      }, token: token);
      expect(ok.status, 201);
      expect((await api.post('/closings', {'from': '2026-10-15', 'to': '2026-11-01'}, token: token)).status, 409);
      final reopen = await api.delete('/closings/${close.json['id']}', token: token);
      expect(reopen.status, 204);
      final after = await api.post('/punches/manual', {
        'member_id': member, 'date': '2026-10-02', 'time': '08:00', 'reason': 'x',
      }, token: token);
      expect(after.status, 201);
    });
  });

  group('Integrações', () {
    test('chave de API somente leitura e revogação', () async {
      final (token, _, _) = await api.register();
      final k = await api.post('/integrations/api-keys', {'name': 'Folha'}, token: token);
      expect(k.status, 201, reason: '$k');
      final key = k.json['key'] as String;
      expect(key, startsWith('pmx_'));
      final members = await api.call('GET', '/members', headers: {'x-api-key': key});
      expect(members.status, 200);
      expect(members.list, isNotEmpty);
      final afd = await api.call('GET', '/reports/afd?from=2026-10-01&to=2026-10-31', headers: {'x-api-key': key});
      expect(afd.status, 200);
      final write = await api.call('POST', '/departments', body: {'name': 'x'}, headers: {'x-api-key': key});
      expect(write.status, 403);
      final notAllowed = await api.call('GET', '/integrations/api-keys', headers: {'x-api-key': key});
      expect(notAllowed.status, 403);
      final keys = await api.get('/integrations/api-keys', token: token);
      expect(keys.list.single.containsKey('key'), isFalse);
      expect(keys.list.single['last_used_at'], isNotNull);
      await api.delete('/integrations/api-keys/${k.json['id']}', token: token);
      final revoked = await api.call('GET', '/members', headers: {'x-api-key': key});
      expect(revoked.status, 401);
      final forged = await api.call('GET', '/members', headers: {'x-api-key': 'pmx_${k.json['prefix']}_falsa'});
      expect(forged.status, 401);
    });

    test('webhook assinado recebe a marcação registrada', () async {
      final received = <(Map<String, String>, String)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        received.add(({
          'event': req.headers.value('x-pontomax-event') ?? '',
          'signature': req.headers.value('x-pontomax-signature') ?? '',
        }, body));
        req.response.statusCode = 200;
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));
      final (token, _, _) = await api.register();
      final hook = await api.post('/integrations/webhooks', {
        'url': 'http://127.0.0.1:${server.port}/hook',
        'events': ['punch.created', 'request.created'],
      }, token: token);
      expect(hook.status, 201, reason: '$hook');
      final secret = hook.json['secret'] as String;
      final test = await api.post('/integrations/webhooks/${hook.json['id']}/test', {}, token: token);
      expect(test.json['ok'], isTrue);
      await api.post('/punches', {'source': 'browser'}, token: token);
      await Future.wait([...api.app.webhooks.pending]);
      final punchEvent = received.firstWhere((r) => r.$1['event'] == 'punch.created');
      final expected = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(punchEvent.$2)).toString();
      expect(punchEvent.$1['signature'], 'sha256=$expected');
      final payload = jsonDecode(punchEvent.$2) as Map;
      expect(payload['data']['nsr'], isNotNull);
      final bad = await api.post('/integrations/webhooks', {'url': 'ftp://x', 'events': ['punch.created']}, token: token);
      expect(bad.status, 400);
      final hooks = await api.get('/integrations/webhooks', token: token);
      expect(hooks.list.single['last_status'], 200);
    });
  });

  group('Chat e notas', () {
    test('mensagens entre colaborador e gestor com long-polling', () async {
      final (owner, company, ownerMember) = await api.register();
      final m = await api.post('/members', {
        'name': 'Lia', 'email': 'lia@empresa.com', 'cpf': '71428793860', 'password': 'senha1234',
      }, token: owner, company: company);
      final lia = await api.login('lia@empresa.com');
      final since = api.clock.value.toIso8601String();
      final waiting = api.get('/chat/${m.json['id']}/messages?after=$since&wait=5', token: owner);
      final sent = await api.post('/chat/$ownerMember/messages', {'body': 'Olá, gestora!'}, token: lia);
      expect(sent.status, 201);
      final received = await waiting;
      expect(received.list.single['body'], 'Olá, gestora!');
      final convs = await api.get('/chat/conversations', token: owner);
      expect(convs.list.first['unread'], 1);
      await api.post('/chat/${m.json['id']}/read', {}, token: owner);

      final note = await api.post('/notes', {'title': 'Lembrar', 'body': 'Atestado'}, token: lia);
      expect(note.status, 201);
      final upd = await api.put('/notes/${note.json['id']}', {'pinned': true}, token: lia);
      expect(upd.json['pinned'], isTrue);
      expect((await api.get('/notes', token: owner)).list, isEmpty);
    });
  });

  group('Dados de demonstração', () {
    test('seed cria empresa completa e dashboard funciona', () async {
      api.clock.brt(2026, 10, 5, 10);
      await seedDemo(api.app);
      await seedDemo(api.app); // idempotente
      final admin = await api.login('admin@pontomax.app', 'pontomax123');
      final dash = await api.get('/dashboard', token: admin);
      expect(dash.status, 200, reason: '$dash');
      expect(dash.json['totals']['members'], 7);
      final afd = await api.get('/reports/afd?from=2026-09-01&to=2026-10-05', token: admin);
      expect(AfdGenerator.verifyChain(latin1.decode(afd.bytes)), isEmpty);
      final summary = await api.get('/reports/summary?from=2026-09-01&to=2026-09-30', token: admin);
      expect((summary.json['rows'] as List).length, 7);
    });
  });
}
