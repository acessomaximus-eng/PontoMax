import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/offline_queue.dart';
import '../state/session.dart';
import '../theme.dart';
import 'common.dart';

class NavItem {
  final String path;
  final String label;
  final IconData icon;
  final IconData? selectedIcon;
  final int Function(Me me)? badge;
  const NavItem(
    this.path,
    this.label,
    this.icon, {
    this.selectedIcon,
    this.badge,
  });
}

class NavGroup {
  final String title;
  final List<NavItem> items;
  const NavGroup(this.title, this.items);
}

List<NavGroup> navGroups(Me me) => [
  NavGroup('Meu ponto', [
    const NavItem(
      '/ponto',
      'Registrar ponto',
      Icons.fingerprint,
      selectedIcon: Icons.fingerprint,
    ),
    const NavItem(
      '/espelho',
      'Espelho de ponto',
      Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month,
    ),
    const NavItem(
      '/solicitacoes',
      'Solicitações',
      Icons.assignment_outlined,
      selectedIcon: Icons.assignment,
    ),
    if ((me.company?.settings.showBankToEmployee ?? true) || me.isManager)
      const NavItem(
        '/banco',
        'Banco de horas',
        Icons.savings_outlined,
        selectedIcon: Icons.savings,
      ),
    const NavItem(
      '/comprovantes',
      'Comprovantes',
      Icons.receipt_long_outlined,
      selectedIcon: Icons.receipt_long,
    ),
    const NavItem(
      '/notas',
      'Bloco de notas',
      Icons.sticky_note_2_outlined,
      selectedIcon: Icons.sticky_note_2,
    ),
  ]),
  NavGroup('Comunicação', [
    NavItem(
      '/chat',
      'Work chat',
      Icons.chat_bubble_outline,
      selectedIcon: Icons.chat_bubble,
      badge: (m) => m.unreadMessages,
    ),
    NavItem(
      '/notificacoes',
      'Notificações',
      Icons.notifications_none,
      selectedIcon: Icons.notifications,
      badge: (m) => m.unreadNotifications,
    ),
  ]),
  if (me.isManager)
    NavGroup('Gestão', [
      const NavItem(
        '/painel',
        'Painel',
        Icons.space_dashboard_outlined,
        selectedIcon: Icons.space_dashboard,
      ),
      const NavItem(
        '/mapa',
        'Mapa de marcações',
        Icons.map_outlined,
        selectedIcon: Icons.map,
      ),
      const NavItem(
        '/equipe',
        'Colaboradores',
        Icons.groups_outlined,
        selectedIcon: Icons.groups,
      ),
      NavItem(
        '/aprovacoes',
        'Aprovações',
        Icons.task_alt_outlined,
        selectedIcon: Icons.task_alt,
        badge: (m) => m.pendingRequests,
      ),
      const NavItem(
        '/relatorios',
        'Relatórios e exportações',
        Icons.insert_chart_outlined,
        selectedIcon: Icons.insert_chart,
      ),
    ]),
  if (me.isManager)
    const NavGroup('Configurações', [
      NavItem(
        '/escalas',
        'Escalas e jornadas',
        Icons.schedule_outlined,
        selectedIcon: Icons.schedule,
      ),
      NavItem(
        '/feriados',
        'Feriados',
        Icons.event_outlined,
        selectedIcon: Icons.event,
      ),
      NavItem(
        '/perimetros',
        'Perímetros',
        Icons.share_location_outlined,
        selectedIcon: Icons.share_location,
      ),
      NavItem(
        '/dispositivos',
        'Quiosques',
        Icons.tablet_android_outlined,
        selectedIcon: Icons.tablet_android,
      ),
      NavItem(
        '/cadastros',
        'Departamentos e cargos',
        Icons.account_tree_outlined,
        selectedIcon: Icons.account_tree,
      ),
      NavItem(
        '/empresa',
        'Empresa e regras',
        Icons.business_outlined,
        selectedIcon: Icons.business,
      ),
      NavItem(
        '/auditoria',
        'Auditoria',
        Icons.policy_outlined,
        selectedIcon: Icons.policy,
      ),
    ]),
];

/// Abas inferiores no celular.
List<NavItem> bottomItems(Me me) => me.isManager
    ? [
        const NavItem(
          '/painel',
          'Painel',
          Icons.space_dashboard_outlined,
          selectedIcon: Icons.space_dashboard,
        ),
        const NavItem('/ponto', 'Ponto', Icons.fingerprint),
        const NavItem(
          '/equipe',
          'Equipe',
          Icons.groups_outlined,
          selectedIcon: Icons.groups,
        ),
        NavItem(
          '/aprovacoes',
          'Aprovações',
          Icons.task_alt_outlined,
          selectedIcon: Icons.task_alt,
          badge: (m) => m.pendingRequests,
        ),
        NavItem(
          '/mais',
          'Mais',
          Icons.menu,
          badge: (m) => m.unreadMessages + m.unreadNotifications,
        ),
      ]
    : [
        const NavItem('/ponto', 'Ponto', Icons.fingerprint),
        const NavItem(
          '/espelho',
          'Espelho',
          Icons.calendar_month_outlined,
          selectedIcon: Icons.calendar_month,
        ),
        const NavItem(
          '/solicitacoes',
          'Pedidos',
          Icons.assignment_outlined,
          selectedIcon: Icons.assignment,
        ),
        NavItem(
          '/chat',
          'Chat',
          Icons.chat_bubble_outline,
          selectedIcon: Icons.chat_bubble,
          badge: (m) => m.unreadMessages,
        ),
        NavItem(
          '/mais',
          'Mais',
          Icons.menu,
          badge: (m) => m.unreadNotifications,
        ),
      ];

class AppShell extends ConsumerWidget {
  final Widget child;
  final String location;
  const AppShell({super.key, required this.child, required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final me = session.me;
    if (me == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final pending = ref.watch(offlineQueueProvider).length;

    final banner = pending > 0
        ? MaterialBanner(
            backgroundColor: AppColors.warning.withValues(alpha: 0.15),
            leading: const Icon(
              Icons.cloud_upload_outlined,
              color: AppColors.warning,
            ),
            content: Text(
              '$pending marcação(ões) aguardando envio (registradas sem internet).',
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final n = await ref
                      .read(offlineQueueProvider.notifier)
                      .sync();
                  if (context.mounted) {
                    showSnack(
                      context,
                      n > 0
                          ? '$n marcação(ões) sincronizada(s)'
                          : 'Ainda sem conexão',
                    );
                  }
                },
                child: const Text('Sincronizar'),
              ),
            ],
          )
        : null;

    if (isWide(context)) {
      return Scaffold(
        body: Row(
          children: [
            _SideNav(me: me, location: location),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  ?banner,
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final items = bottomItems(me);
    var index = items.indexWhere((i) => location.startsWith(i.path));
    if (index < 0) index = items.length - 1;
    return Scaffold(
      body: Column(
        children: [
          ?banner,
          Expanded(child: child),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => context.go(items[i].path),
        destinations: [
          for (final item in items)
            NavigationDestination(
              icon: _badge(item.icon, item.badge?.call(me) ?? 0),
              selectedIcon: _badge(
                item.selectedIcon ?? item.icon,
                item.badge?.call(me) ?? 0,
              ),
              label: item.label,
            ),
        ],
      ),
    );
  }

  static Widget _badge(IconData icon, int count) =>
      count > 0 ? Badge(label: Text('$count'), child: Icon(icon)) : Icon(icon);
}

class _SideNav extends ConsumerWidget {
  final Me me;
  final String location;
  const _SideNav({required this.me, required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return SizedBox(
      width: 268,
      child: Material(
        color: t.colorScheme.surface,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.brand,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.fingerprint,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'PontoMax',
                      style: t.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              CompanySwitcher(me: me),
              Expanded(
                // ClipRect + Material: o destaque do item selecionado não vaza ao rolar.
                child: ClipRect(
                  child: Material(
                    type: MaterialType.transparency,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      children: [
                        for (final g in navGroups(me)) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
                            child: Text(
                              g.title.toUpperCase(),
                              style: t.textTheme.labelSmall?.copyWith(
                                color: AppColors.muted,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          for (final item in g.items) _tile(context, item),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                leading: Avatar(
                  name: me.user.name,
                  url: me.member?.photoUrl,
                  radius: 16,
                ),
                title: Text(
                  me.user.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(me.role.label),
                onTap: () => context.go('/perfil'),
                trailing: IconButton(
                  tooltip: 'Sair',
                  icon: const Icon(Icons.logout),
                  onPressed: () => ref.read(sessionProvider.notifier).logout(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, NavItem item) {
    final selected =
        location == item.path || location.startsWith('${item.path}/');
    final count = item.badge?.call(me) ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: Icon(
          selected ? (item.selectedIcon ?? item.icon) : item.icon,
          size: 22,
        ),
        title: Text(
          item.label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        trailing: count > 0 ? Badge(label: Text('$count')) : null,
        onTap: () => context.go(item.path),
      ),
    );
  }
}

/// Troca de empresa (multiempresa).
class CompanySwitcher extends ConsumerWidget {
  final Me me;
  const CompanySwitcher({super.key, required this.me});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = me.company;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.apartment_rounded),
          title: Text(
            company?.name ?? 'Sem empresa',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            me.memberships.length > 1
                ? '${me.memberships.length} empresas'
                : me.role.label,
          ),
          trailing: me.memberships.length > 1
              ? const Icon(Icons.unfold_more)
              : null,
          onTap: me.memberships.length > 1
              ? () => showCompanyPicker(context, ref, me)
              : null,
        ),
      ),
    );
  }
}

Future<void> showCompanyPicker(
  BuildContext context,
  WidgetRef ref,
  Me me,
) async {
  final id = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Escolha a empresa',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ),
          for (final m in me.memberships)
            ListTile(
              leading: const Icon(Icons.apartment_rounded),
              title: Text(m.companyName),
              subtitle: Text(m.role.label),
              trailing: m.companyId == me.company?.id
                  ? const Icon(Icons.check_circle, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(c, m.companyId),
            ),
        ],
      ),
    ),
  );
  if (id != null && id != me.company?.id) {
    await ref.read(sessionProvider.notifier).switchCompany(id);
  }
}
