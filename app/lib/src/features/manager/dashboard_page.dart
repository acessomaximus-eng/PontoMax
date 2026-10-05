import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../config.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

import 'package:shared_preferences/shared_preferences.dart';

const _states = {
  'working': ('Trabalhando', AppColors.accent, Icons.play_circle_outline),
  'out': ('Encerrou/intervalo', AppColors.info, Icons.pause_circle_outline),
  'absent': ('Ausente', AppColors.danger, Icons.error_outline),
  'expected': ('Aguardando entrada', AppColors.warning, Icons.schedule),
  'off': ('Folga', AppColors.muted, Icons.weekend_outlined),
  'leave': ('Afastado/abonado', Color(0xFF6366F1), Icons.healing_outlined),
};

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  String? _filter;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final data = ref.watch(dashboardProvider(null));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Painel'),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: () => ref.invalidate(dashboardProvider),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Mapa',
            onPressed: () => context.go('/mapa'),
            icon: const Icon(Icons.map_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(dashboardProvider),
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(dashboardProvider),
          builder: (d) {
            final totals = (d['totals'] as Map).cast<String, dynamic>();
            final members = [
              for (final m in d['members'] as List)
                (m as Map).cast<String, dynamic>(),
            ];
            final filtered = _filter == null
                ? members
                : _filter == 'late'
                ? members.where((m) => m['late_minutes'] != null).toList()
                : members.where((m) => m['state'] == _filter).toList();
            final recent = [
              for (final p in d['recent_punches'] as List)
                Punch.fromJson((p as Map).cast()),
            ];
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Constrained(
                  maxWidth: 1200,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${capitalize(dateLong(LocalDate.parse(d['date'] as String)))}${d['holiday'] != null ? ' • ${d['holiday']}' : ''}',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        me.company?.name ?? '',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 16),
                      if (me.companyWide) const _OnboardingCard(),
                      ResponsiveGrid(
                        minItemWidth: 200,
                        children: [
                          StatCard(
                            label: 'Trabalhando agora',
                            value: '${totals['working']}',
                            icon: Icons.play_circle_outline,
                            color: AppColors.accent,
                            hint:
                                '${totals['punched']} de ${totals['expected_today']} já registraram',
                            onTap: () => setState(() => _filter = 'working'),
                          ),
                          StatCard(
                            label: 'Ausentes',
                            value: '${totals['absent']}',
                            icon: Icons.person_off_outlined,
                            color: AppColors.danger,
                            onTap: () => setState(() => _filter = 'absent'),
                          ),
                          StatCard(
                            label: 'Atrasos hoje',
                            value: '${totals['late']}',
                            icon: Icons.alarm_outlined,
                            color: AppColors.warning,
                            onTap: () => setState(() => _filter = 'late'),
                          ),
                          StatCard(
                            label: 'Solicitações pendentes',
                            value: '${totals['pending_requests']}',
                            icon: Icons.task_alt,
                            color: AppColors.brand,
                            onTap: () => context.go('/aprovacoes'),
                          ),
                          StatCard(
                            label: 'Fora do perímetro',
                            value: '${totals['outside_geofence']}',
                            icon: Icons.wrong_location_outlined,
                            color: const Color(0xFFEC4899),
                            onTap: () => context.go('/mapa'),
                          ),
                          StatCard(
                            label: 'Afastados/abonados',
                            value: '${totals['on_leave']}',
                            icon: Icons.healing_outlined,
                            color: const Color(0xFF6366F1),
                            hint: '${totals['members']} colaboradores ativos',
                            onTap: () => setState(() => _filter = 'leave'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, c) {
                          final status = _StatusList(
                            members: filtered,
                            filter: _filter,
                            onFilter: (f) => setState(() => _filter = f),
                          );
                          final side = Column(
                            children: [
                              _WeekChart(
                                week: [
                                  for (final w in d['week'] as List)
                                    (w as Map).cast<String, dynamic>(),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _RecentPunches(punches: recent),
                            ],
                          );
                          if (c.maxWidth < 900) {
                            return Column(
                              children: [
                                status,
                                const SizedBox(height: 12),
                                side,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 3, child: status),
                              const SizedBox(width: 12),
                              Expanded(flex: 2, child: side),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatusList extends StatelessWidget {
  final List<Map<String, dynamic>> members;
  final String? filter;
  final ValueChanged<String?> onFilter;
  const _StatusList({
    required this.members,
    required this.filter,
    required this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text(
                'Equipe hoje',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Todos'),
                    selected: filter == null,
                    onSelected: (_) => onFilter(null),
                  ),
                  for (final e in _states.entries) ...[
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text(e.value.$1),
                      selected: filter == e.key,
                      onSelected: (_) => onFilter(e.key),
                    ),
                  ],
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('Atrasados'),
                    selected: filter == 'late',
                    onSelected: (_) => onFilter('late'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (members.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('Ninguém nesta situação.')),
              ),
            for (final m in members)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Avatar(
                  name: m['name'] as String,
                  url: m['photo_url'] as String?,
                ),
                title: Text(
                  m['name'] as String,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  [
                    if (m['department'] != null) m['department'],
                    (m['punches'] as List).isEmpty
                        ? 'Escala: ${m['expected']}'
                        : (m['punches'] as List).join('  '),
                  ].join(' • '),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    StatusChip(
                      _states[m['state']]?.$1 ?? '',
                      color: _states[m['state']]?.$2 ?? AppColors.muted,
                    ),
                    if (m['late_minutes'] != null)
                      Text(
                        '${m['late_minutes']} min de atraso',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.warning,
                        ),
                      ),
                  ],
                ),
                onTap: () => context.push('/equipe/${m['member_id']}'),
              ),
          ],
        ),
      ),
    );
  }
}

class _WeekChart extends StatelessWidget {
  final List<Map<String, dynamic>> week;
  const _WeekChart({required this.week});

  @override
  Widget build(BuildContext context) {
    final maxY = week
        .fold<int>(
          1,
          (m, w) => (w['punches'] as int) > m ? w['punches'] as int : m,
        )
        .toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'Marcações nos últimos 7 dias',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            SizedBox(
              height: 160,
              child: week.isEmpty
                  ? const Center(child: Text('Sem dados'))
                  : BarChart(
                      BarChartData(
                        maxY: maxY * 1.2,
                        gridData: const FlGridData(show: false),
                        borderData: FlBorderData(show: false),
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              getTitlesWidget: (v, meta) {
                                final i = v.toInt();
                                if (i < 0 || i >= week.length) {
                                  return const SizedBox.shrink();
                                }
                                final d = LocalDate.parse(
                                  week[i]['date'] as String,
                                );
                                return Text(
                                  TimeFmt.weekdayShort[d.weekday - 1],
                                  style: const TextStyle(fontSize: 11),
                                );
                              },
                            ),
                          ),
                        ),
                        barGroups: [
                          for (var i = 0; i < week.length; i++)
                            BarChartGroupData(
                              x: i,
                              barRods: [
                                BarChartRodData(
                                  toY: (week[i]['punches'] as int).toDouble(),
                                  width: 18,
                                  color: AppColors.brand,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentPunches extends StatelessWidget {
  final List<Punch> punches;
  const _RecentPunches({required this.punches});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              'Últimas marcações',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          if (punches.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nenhuma marcação hoje.'),
            ),
          for (final p in punches.take(12))
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: p.photoUrl != null
                  ? CircleAvatar(
                      backgroundImage: NetworkImage(
                        AppConfig.resolveUrl(p.photoUrl),
                      ),
                    )
                  : Avatar(name: p.memberName ?? '?', radius: 18),
              title: Text(p.memberName ?? ''),
              subtitle: Text(
                '${p.method.label}${p.geofenceName != null ? ' • ${p.geofenceName}' : ''}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.insideGeofence == false)
                    const Icon(
                      Icons.wrong_location_outlined,
                      color: AppColors.warning,
                      size: 18,
                    ),
                  const SizedBox(width: 4),
                  Text(
                    TimeFmt.clock(p.wall),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// Mapa das marcações do dia com perímetros.
class LiveMapPage extends ConsumerStatefulWidget {
  const LiveMapPage({super.key});
  @override
  ConsumerState<LiveMapPage> createState() => _LiveMapPageState();
}

class _LiveMapPageState extends ConsumerState<LiveMapPage> {
  late LocalDate _date;
  bool _outsideOnly = false;

  @override
  void initState() {
    super.initState();
    _date = LocalDate.fromDateTime(
      ServerClock.wall(ref.read(meProvider).offset),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = (memberId: null, from: _date, to: _date, outside: _outsideOnly);
    final punches = ref.watch(punchesProvider(q));
    final fences = ref.watch(geofencesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mapa de marcações'),
        actions: [
          FilterChip(
            label: const Text('Somente fora do perímetro'),
            selected: _outsideOnly,
            onSelected: (v) => setState(() => _outsideOnly = v),
          ),
          IconButton(
            tooltip: 'Escolher data',
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _date.toDateTime().toLocal(),
                firstDate: DateTime(2020),
                lastDate: DateTime.now(),
              );
              if (d != null) {
                setState(() => _date = LocalDate(d.year, d.month, d.day));
              }
            },
          ),
        ],
      ),
      body: AsyncView(
        value: punches,
        onRetry: () => ref.invalidate(punchesProvider(q)),
        builder: (list) {
          final located = list
              .where((p) => p.lat != null && p.lng != null)
              .toList();
          final fenceList = fences.value ?? const <GeofenceEntity>[];
          final center = located.isNotEmpty
              ? LatLng(located.first.lat!, located.first.lng!)
              : fenceList.isNotEmpty
              ? LatLng(fenceList.first.lat, fenceList.first.lng)
              : const LatLng(-15.79, -47.88);
          return Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: located.isEmpty && fenceList.isEmpty ? 4 : 15,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'app.pontomax',
                  ),
                  CircleLayer(
                    circles: [
                      for (final f in fenceList)
                        CircleMarker(
                          point: LatLng(f.lat, f.lng),
                          radius: f.radius,
                          useRadiusInMeter: true,
                          color: AppColors.brand.withValues(alpha: 0.12),
                          borderColor: AppColors.brand,
                          borderStrokeWidth: 2,
                        ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      for (final p in located)
                        Marker(
                          point: LatLng(p.lat!, p.lng!),
                          width: 120,
                          height: 56,
                          child: Tooltip(
                            message:
                                '${p.memberName} — ${TimeFmt.clock(p.wall)}\n${p.method.label}',
                            child: Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 4,
                                        color: Colors.black26,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    '${(p.memberName ?? '').split(' ').first} ${TimeFmt.clock(p.wall)}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.location_on,
                                  color: p.insideGeofence == false
                                      ? AppColors.danger
                                      : AppColors.accent,
                                  size: 30,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const RichAttributionWidget(
                    attributions: [TextSourceAttribution('© OpenStreetMap')],
                  ),
                ],
              ),
              Positioned(
                left: 12,
                top: 12,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(
                      '${_date.toBr()} • ${located.length} marcação(ões) com localização',
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final onboardingProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.watch(apiProvider).getMap('/onboarding'),
);

/// Checklist de primeiros passos (some quando concluído ou dispensado).
class _OnboardingCard extends ConsumerStatefulWidget {
  const _OnboardingCard();
  @override
  ConsumerState<_OnboardingCard> createState() => _OnboardingCardState();
}

class _OnboardingCardState extends ConsumerState<_OnboardingCard> {
  static const _key = 'pontomax.onboarding_dismissed';
  bool? _dismissed;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _dismissed = p.getBool(_key) ?? false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed != false) return const SizedBox.shrink();
    final data = ref.watch(onboardingProvider).value;
    if (data == null) return const SizedBox.shrink();
    final steps = [
      for (final s in data['steps'] as List) (s as Map).cast<String, dynamic>(),
    ];
    final done = data['done'] as int;
    final total = data['total'] as int;
    if (done >= total) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.rocket_launch_outlined,
                    color: AppColors.brand,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Primeiros passos ($done de $total)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final p = await SharedPreferences.getInstance();
                      await p.setBool(_key, true);
                      if (mounted) setState(() => _dismissed = true);
                    },
                    child: const Text('Dispensar'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: done / total,
                minHeight: 6,
                borderRadius: BorderRadius.circular(6),
              ),
              const SizedBox(height: 8),
              for (final s in steps)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    s['done'] == true
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: s['done'] == true
                        ? AppColors.accent
                        : AppColors.muted,
                  ),
                  title: Text(
                    s['title'] as String,
                    style: TextStyle(
                      decoration: s['done'] == true
                          ? TextDecoration.lineThrough
                          : null,
                      color: s['done'] == true ? AppColors.muted : null,
                    ),
                  ),
                  subtitle: s['done'] == true
                      ? null
                      : Text(s['description'] as String),
                  trailing: s['done'] == true
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: s['done'] == true
                      ? null
                      : () => context.go(s['route'] as String),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
