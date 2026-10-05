import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pontomax/src/api/api_client.dart';
import 'package:pontomax/src/features/auth/auth_pages.dart';
import 'package:pontomax/src/state/session.dart';
import 'package:pontomax/src/widgets/common.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('pt_BR');
    SharedPreferences.setMockInitialValues({});
  });

  group('ApiClient', () {
    test('converte erros da API em ApiException', () async {
      final client = ApiClient(
        client: MockClient((req) async => http.Response(
              jsonEncode({
                'error': {'code': 'outside_geofence', 'message': 'Você está fora do perímetro'},
              }),
              422,
              headers: {'content-type': 'application/json'},
            )),
      );
      expect(
        () => client.post('/punches', {}),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'outside_geofence')
            .having((e) => e.status, 'status', 422)),
      );
    });

    test('renova o token expirado e repete a requisição', () async {
      var calls = 0;
      final client = ApiClient(
        client: MockClient((req) async {
          calls++;
          if (req.url.path.endsWith('/auth/refresh')) {
            return http.Response(jsonEncode({'access_token': 'novo', 'refresh_token': 'r2'}), 200);
          }
          if (req.headers['authorization'] == 'Bearer velho') {
            return http.Response(jsonEncode({'error': {'code': 'token_expired', 'message': 'x'}}), 401);
          }
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      )
        ..accessToken = 'velho'
        ..refreshToken = 'r1';
      String? saved;
      client.onTokens = (a, r) => saved = '$a/$r';
      final res = await client.get('/me');
      expect(res['ok'], isTrue);
      expect(saved, 'novo/r2');
      expect(calls, 3);
    });

    test('falha de rede vira ApiException.isNetwork', () async {
      final client = ApiClient(client: MockClient((req) async => throw http.ClientException('offline')));
      try {
        await client.get('/me');
        fail('deveria lançar');
      } on ApiException catch (e) {
        expect(e.isNetwork, isTrue);
      }
    });
  });

  group('Sessão', () {
    test('Me.fromJson identifica perfil e empresa', () {
      final me = Me.fromJson({
        'user': {'id': 'u', 'name': 'Ana', 'email': 'ana@x.com'},
        'memberships': [
          {'member_id': 'm', 'company_id': 'c', 'company_name': 'Padaria', 'role': 'manager'},
        ],
        'member': {'id': 'm', 'company_id': 'c', 'user_id': 'u', 'name': 'Ana', 'email': 'ana@x.com', 'role': 'manager'},
        'company': {'id': 'c', 'name': 'Padaria', 'utc_offset_minutes': -240, 'settings': {'require_photo': true}},
        'unread_messages': 3,
      });
      expect(me.isManager, isTrue);
      expect(me.isAdmin, isFalse);
      expect(me.offset, -240);
      expect(me.company!.settings.requirePhoto, isTrue);
      expect(me.unreadMessages, 3);
    });

    test('relógio do servidor aplica o deslocamento', () {
      ServerClock.sync(DateTime.now().toUtc().add(const Duration(minutes: 10)), Duration.zero);
      final diff = ServerClock.nowUtc().difference(DateTime.now().toUtc()).inMinutes;
      expect(diff, inInclusiveRange(9, 10));
      ServerClock.offset = Duration.zero;
    });
  });

  group('Formatação', () {
    test('horas e datas em pt-BR', () {
      expect(hm(-75, signed: true), '-01:15');
      expect(hm(0, dashIfZero: true), '—');
      expect(capitalize(monthLabel(const LocalDate(2026, 10, 1))), 'Outubro de 2026');
    });
  });

  testWidgets('tela de login exibe os campos e ações', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: LoginPage())));
    await tester.pumpAndSettle();
    expect(find.text('Entrar'), findsWidgets);
    expect(find.text('E-mail'), findsOneWidget);
    expect(find.text('Cadastrar minha empresa'), findsOneWidget);
    expect(find.textContaining('Portaria 671'), findsOneWidget);
  });

  testWidgets('StatCard mostra valor e rótulo', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: StatCard(label: 'Horas extras', value: '02:30', icon: Icons.trending_up)),
    ));
    expect(find.text('02:30'), findsOneWidget);
    expect(find.text('Horas extras'), findsOneWidget);
  });
}
