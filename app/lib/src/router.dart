import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/auth_pages.dart';
import 'features/chat/chat_pages.dart';
import 'features/common/qr_scanner_page.dart';
import 'features/employee/employee_pages.dart';
import 'features/employee/home_page.dart';
import 'features/kiosk/kiosk_pages.dart';
import 'features/manager/approvals_reports.dart';
import 'features/manager/dashboard_page.dart';
import 'features/manager/integrations_page.dart';
import 'features/manager/schedule_pages.dart';
import 'features/manager/settings_pages.dart';
import 'features/manager/team_pages.dart';
import 'state/session.dart';
import 'widgets/app_shell.dart';

/// Ponte entre o estado da sessão (Riverpod) e o `refreshListenable` do GoRouter.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen(sessionProvider, (prev, next) {
      if (prev?.status != next.status ||
          prev?.me?.company?.id != next.me?.company?.id) {
        notifyListeners();
      }
    });
  }
}

const _public = {'/login', '/cadastro', '/esqueci', '/reset', '/kiosk/ativar'};
const _managerOnly = [
  '/painel',
  '/mapa',
  '/equipe',
  '/aprovacoes',
  '/relatorios',
  '/escalas',
  '/feriados',
  '/perimetros',
  '/dispositivos',
  '/cadastros',
  '/empresa',
  '/auditoria',
  '/integracoes',
];

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _SessionListenable(ref);
  return GoRouter(
    initialLocation: '/ponto',
    refreshListenable: listenable,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      switch (session.status) {
        case SessionStatus.loading:
          return loc == '/carregando' ? null : '/carregando';
        case SessionStatus.kiosk:
          return loc == '/kiosk' ? null : '/kiosk';
        case SessionStatus.signedOut:
          return _public.contains(loc) ? null : '/login';
        case SessionStatus.signedIn:
          final me = session.me!;
          if (_public.contains(loc) ||
              loc == '/carregando' ||
              loc == '/kiosk') {
            return me.isManager ? '/painel' : '/ponto';
          }
          if (!me.isManager &&
              _managerOnly.any((p) => loc == p || loc.startsWith('$p/'))) {
            return '/ponto';
          }
          return null;
      }
    },
    routes: [
      GoRoute(path: '/carregando', builder: (_, _) => const _Splash()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/cadastro', builder: (_, _) => const RegisterPage()),
      GoRoute(path: '/esqueci', builder: (_, _) => const ForgotPage()),
      GoRoute(
        path: '/reset',
        builder: (_, s) =>
            ResetPage(token: s.uri.queryParameters['token'] ?? ''),
      ),
      GoRoute(
        path: '/kiosk/ativar',
        builder: (_, _) => const KioskActivatePage(),
      ),
      GoRoute(path: '/kiosk', builder: (_, _) => const KioskPage()),
      GoRoute(path: '/escanear', builder: (_, _) => const QrScannerPage()),
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/ponto', builder: (_, _) => const HomePage()),
          GoRoute(path: '/espelho', builder: (_, _) => const MyTimesheetPage()),
          GoRoute(
            path: '/solicitacoes',
            builder: (_, _) => const MyRequestsPage(),
          ),
          GoRoute(path: '/banco', builder: (_, _) => const BankPage()),
          GoRoute(
            path: '/comprovantes',
            builder: (_, _) => const ReceiptsPage(),
          ),
          GoRoute(path: '/notas', builder: (_, _) => const NotesPage()),
          GoRoute(
            path: '/notificacoes',
            builder: (_, _) => const NotificationsPage(),
          ),
          GoRoute(path: '/perfil', builder: (_, _) => const ProfilePage()),
          GoRoute(path: '/mais', builder: (_, _) => const MorePage()),
          GoRoute(path: '/chat', builder: (_, _) => const ConversationsPage()),
          GoRoute(
            path: '/chat/:id',
            builder: (_, s) => ChatPage(
              memberId: s.pathParameters['id']!,
              name: s.uri.queryParameters['name'] ?? 'Conversa',
            ),
          ),
          GoRoute(path: '/painel', builder: (_, _) => const DashboardPage()),
          GoRoute(path: '/mapa', builder: (_, _) => const LiveMapPage()),
          GoRoute(path: '/equipe', builder: (_, _) => const TeamPage()),
          GoRoute(
            path: '/equipe/novo',
            builder: (_, _) => const MemberFormPage(),
          ),
          GoRoute(
            path: '/equipe/:id',
            builder: (_, s) =>
                MemberDetailPage(memberId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/equipe/:id/editar',
            builder: (_, s) =>
                MemberFormPage(memberId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/aprovacoes',
            builder: (_, _) => const ApprovalsPage(),
          ),
          GoRoute(path: '/relatorios', builder: (_, _) => const ReportsPage()),
          GoRoute(path: '/escalas', builder: (_, _) => const SchedulesPage()),
          GoRoute(
            path: '/escalas/nova',
            builder: (_, _) => const ScheduleEditorPage(),
          ),
          GoRoute(
            path: '/escalas/:id',
            builder: (_, s) =>
                ScheduleEditorPage(scheduleId: s.pathParameters['id']),
          ),
          GoRoute(path: '/feriados', builder: (_, _) => const HolidaysPage()),
          GoRoute(
            path: '/perimetros',
            builder: (_, _) => const GeofencesPage(),
          ),
          GoRoute(
            path: '/dispositivos',
            builder: (_, _) => const DevicesPage(),
          ),
          GoRoute(path: '/cadastros', builder: (_, _) => const CatalogsPage()),
          GoRoute(path: '/empresa', builder: (_, _) => const CompanyPage()),
          GoRoute(path: '/auditoria', builder: (_, _) => const AuditPage()),
          GoRoute(
            path: '/integracoes',
            builder: (_, _) => const IntegrationsPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(),
      body: Center(child: Text('Página não encontrada: ${state.uri}')),
    ),
  );
});

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fingerprint, size: 72, color: Color(0xFF1E40AF)),
          SizedBox(height: 16),
          CircularProgressIndicator(),
        ],
      ),
    ),
  );
}
