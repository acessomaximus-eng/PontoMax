import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// Dados do usuário logado e do vínculo ativo.
class Me {
  final UserAccount user;
  final List<Membership> memberships;
  final Member? member;
  final Company? company;
  final int unreadNotifications;
  final int unreadMessages;
  final int pendingRequests;

  const Me({
    required this.user,
    required this.memberships,
    this.member,
    this.company,
    this.unreadNotifications = 0,
    this.unreadMessages = 0,
    this.pendingRequests = 0,
  });

  Role get role => member?.role ?? Role.employee;
  bool get isManager => role.isManager;
  bool get isAdmin => role.isAdmin;
  int get offset => company?.utcOffsetMinutes ?? -180;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
    user: UserAccount.fromJson((j['user'] as Map).cast()),
    memberships: [
      for (final m in j['memberships'] as List)
        Membership.fromJson((m as Map).cast()),
    ],
    member: j['member'] == null
        ? null
        : Member.fromJson((j['member'] as Map).cast()),
    company: j['company'] == null
        ? null
        : Company.fromJson((j['company'] as Map).cast()),
    unreadNotifications: j['unread_notifications'] as int? ?? 0,
    unreadMessages: j['unread_messages'] as int? ?? 0,
    pendingRequests: j['pending_requests'] as int? ?? 0,
  );
}

enum SessionStatus { loading, signedOut, signedIn, kiosk }

class SessionState {
  final SessionStatus status;
  final Me? me;
  final String? error;
  const SessionState(this.status, {this.me, this.error});
}

/// Diferença entre o relógio do servidor e o local (Portaria 671: relógio
/// sincronizado com a hora legal brasileira).
class ServerClock {
  static Duration offset = Duration.zero;
  static bool synced = false;

  static DateTime nowUtc() => DateTime.now().toUtc().add(offset);

  static void sync(DateTime serverUtc, Duration rtt) {
    offset = serverUtc.add(rtt ~/ 2).difference(DateTime.now().toUtc());
    synced = true;
  }

  /// "Relógio de parede" no fuso da empresa.
  static DateTime wall(int offsetMinutes) =>
      TimeFmt.toWall(nowUtc(), offsetMinutes);
}

final apiProvider = Provider<ApiClient>((ref) => ApiClient());

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

/// Atalho para o usuário logado (lança se não houver).
final meProvider = Provider<Me>((ref) {
  final s = ref.watch(sessionProvider);
  final me = s.me;
  if (me == null) throw StateError('Sem sessão');
  return me;
});

class SessionController extends Notifier<SessionState> {
  static const _kAccess = 'pontomax.access';
  static const _kRefresh = 'pontomax.refresh';
  static const _kCompany = 'pontomax.company';
  static const _kDevice = 'pontomax.device_token';

  ApiClient get api => ref.read(apiProvider);

  @override
  SessionState build() {
    Future.microtask(_restore);
    return const SessionState(SessionStatus.loading);
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    api.onTokens = (a, r) {
      prefs.setString(_kAccess, a);
      prefs.setString(_kRefresh, r);
    };
    api.onSessionExpired = () => logout(expired: true);
    final device = prefs.getString(_kDevice);
    if (device != null) {
      api.deviceToken = device;
      state = const SessionState(SessionStatus.kiosk);
      return;
    }
    api.accessToken = prefs.getString(_kAccess);
    api.refreshToken = prefs.getString(_kRefresh);
    api.companyId = prefs.getString(_kCompany);
    if (api.accessToken == null) {
      state = const SessionState(SessionStatus.signedOut);
      return;
    }
    try {
      await refreshMe();
    } on ApiException catch (e) {
      if (e.isNetwork) {
        state = SessionState(SessionStatus.signedOut, error: e.message);
      } else {
        await logout();
      }
    }
  }

  Future<void> syncClock() async {
    try {
      final sw = Stopwatch()..start();
      final t = await api.getMap('/time');
      sw.stop();
      ServerClock.sync(DateTime.parse(t['utc'] as String), sw.elapsed);
    } catch (e) {
      debugPrint('Falha ao sincronizar relógio: $e');
    }
  }

  Future<void> refreshMe() async {
    final j = await api.getMap('/me');
    final me = Me.fromJson(j);
    if (me.company != null) api.companyId = me.company!.id;
    state = SessionState(SessionStatus.signedIn, me: me);
    unawaited(syncClock());
  }

  Future<void> _applyTokens(Map<String, dynamic> j) async {
    final prefs = await SharedPreferences.getInstance();
    api.accessToken = j['access_token'] as String;
    api.refreshToken = j['refresh_token'] as String;
    await prefs.setString(_kAccess, api.accessToken!);
    await prefs.setString(_kRefresh, api.refreshToken!);
    final memberships = j['memberships'] as List;
    final saved = prefs.getString(_kCompany);
    final hasSaved = memberships.any((m) => (m as Map)['company_id'] == saved);
    api.companyId = hasSaved
        ? saved
        : (memberships.isEmpty
              ? null
              : (memberships.first as Map)['company_id'] as String);
    if (api.companyId != null) await prefs.setString(_kCompany, api.companyId!);
    await refreshMe();
  }

  Future<void> login(String email, String password) async {
    final j = await api.post('/auth/login', {
      'email': email,
      'password': password,
    }) as Map;
    await _applyTokens(j.cast());
  }

  Future<void> register(Map<String, dynamic> data) async {
    final j = await api.post('/auth/register', data) as Map;
    await _applyTokens(j.cast());
  }

  Future<void> switchCompany(String companyId) async {
    final prefs = await SharedPreferences.getInstance();
    api.companyId = companyId;
    await prefs.setString(_kCompany, companyId);
    state = SessionState(SessionStatus.loading, me: state.me);
    await refreshMe();
  }

  Future<void> logout({bool expired = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final refresh = api.refreshToken;
    if (refresh != null && !expired) {
      try {
        await api.post('/auth/logout', {'refresh_token': refresh});
      } catch (_) {}
    }
    api.accessToken = null;
    api.refreshToken = null;
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
    state = SessionState(
      SessionStatus.signedOut,
      error: expired ? 'Sua sessão expirou. Entre novamente.' : null,
    );
  }

  /// Ativa este aparelho como quiosque (sai da conta pessoal).
  Future<void> activateKiosk(String code, String platform) async {
    final j = await api.post('/kiosk/activate', {
      'code': code,
      'platform': platform,
    }) as Map;
    final prefs = await SharedPreferences.getInstance();
    api.deviceToken = j['device_token'] as String;
    await prefs.setString(_kDevice, api.deviceToken!);
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
    api.accessToken = null;
    state = const SessionState(SessionStatus.kiosk);
  }

  Future<void> deactivateKiosk() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDevice);
    api.deviceToken = null;
    state = const SessionState(SessionStatus.signedOut);
  }
}
