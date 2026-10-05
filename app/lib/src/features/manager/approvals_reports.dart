import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../services/file_service.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../employee/employee_pages.dart';

/// Aprovação de solicitações (ajustes, atestados, abonos, folgas, férias).
class ApprovalsPage extends ConsumerWidget {
  const ApprovalsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Aprovações'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Pendentes'),
              Tab(text: 'Histórico'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _RequestList(status: 'pending'),
            _RequestList(status: null),
          ],
        ),
      ),
    );
  }
}

class _RequestList extends ConsumerWidget {
  final String? status;
  const _RequestList({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = (mine: false, status: status);
    final data = ref.watch(requestsProvider(q));
    final api = ref.read(apiProvider);

    Future<void> refresh() async {
      ref.invalidate(requestsProvider);
      await ref.read(sessionProvider.notifier).refreshMe();
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(requestsProvider(q)),
        builder: (list) {
          final items = status == null
              ? list.where((r) => r.status != RequestStatus.pending).toList()
              : list;
          if (items.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: 60),
                EmptyState(
                  icon: Icons.task_alt,
                  title: status == 'pending'
                      ? 'Nenhuma solicitação pendente'
                      : 'Sem histórico',
                  message: status == 'pending'
                      ? 'Tudo aprovado por aqui. 🎉'
                      : null,
                ),
              ],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (c, i) {
              final r = items[i];
              return Constrained(
                maxWidth: 860,
                child: RequestCard(
                  request: r,
                  actions: r.status != RequestStatus.pending
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: () =>
                                    context.push('/equipe/${r.memberId}'),
                                icon: const Icon(Icons.calendar_month_outlined),
                                label: const Text('Ver espelho'),
                              ),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.danger,
                                ),
                                onPressed: () async {
                                  final note = await promptText(
                                    context,
                                    'Recusar solicitação',
                                    label: 'Motivo da recusa',
                                  );
                                  if (note == null || !context.mounted) return;
                                  await runAction(
                                    context,
                                    () => api.post('/requests/${r.id}/reject', {
                                      'note': note,
                                    }),
                                    success: 'Solicitação recusada',
                                  );
                                  await refresh();
                                },
                                icon: const Icon(Icons.close),
                                label: const Text('Recusar'),
                              ),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                ),
                                onPressed: () async {
                                  final note = await promptText(
                                    context,
                                    'Aprovar solicitação',
                                    label: 'Observação (opcional)',
                                    required: false,
                                  );
                                  if (note == null || !context.mounted) return;
                                  await runAction(
                                    context,
                                    () => api.post(
                                      '/requests/${r.id}/approve',
                                      {'note': note},
                                    ),
                                    success: 'Solicitação aprovada',
                                  );
                                  await refresh();
                                },
                                icon: const Icon(Icons.check),
                                label: const Text('Aprovar'),
                              ),
                            ],
                          ),
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Relatórios e exportações (resumo, folha, AFD, AEJ).
class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key});
  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  late LocalDate _anchor;

  @override
  void initState() {
    super.initState();
    _anchor = LocalDate.fromDateTime(
      ServerClock.wall(ref.read(meProvider).offset),
    ).addMonths(-1);
  }

  (LocalDate, LocalDate) _period(Me me) =>
      (me.company?.settings ?? const CompanySettings()).periodFor(_anchor);

  Future<void> _download(String path, String mime) async {
    final me = ref.read(meProvider);
    final (from, to) = _period(me);
    await runAction(context, () async {
      final (bytes, name) = await ref
          .read(apiProvider)
          .download(
            path,
            query: {'from': from.toString(), 'to': to.toString()},
          );
      await saveAndOpen(bytes, name ?? path.split('/').last, mime);
    }, success: 'Arquivo gerado');
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final (from, to) = _period(me);
    final summary = ref.watch(summaryProvider((from: from, to: to)));
    return Scaffold(
      appBar: AppBar(title: const Text('Relatórios e exportações')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Constrained(
            maxWidth: 1200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    MonthSelector(
                      month: _anchor,
                      onChanged: (d) => setState(() => _anchor = d),
                    ),
                    const Spacer(),
                    Text(
                      '${from.toBr()} a ${to.toBr()}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
                const SectionTitle('Exportações'),
                ResponsiveGrid(
                  minItemWidth: 260,
                  children: [
                    _ExportCard(
                      icon: Icons.table_chart_outlined,
                      title: 'Resumo do período (CSV)',
                      subtitle: 'Horas trabalhadas, extras, faltas, noturno e banco por colaborador',
                      onTap: () =>
                          _download('/reports/summary.csv', 'text/csv'),
                    ),
                    _ExportCard(
                      icon: Icons.payments_outlined,
                      title: 'Integração com a folha (CSV)',
                      subtitle: 'Eventos HE50, HE100, adicional noturno e faltas em horas decimais',
                      onTap: () =>
                          _download('/reports/payroll.csv', 'text/csv'),
                    ),
                    _ExportCard(
                      icon: Icons.list_alt_outlined,
                      title: 'Marcações detalhadas (CSV)',
                      subtitle: 'NSR, local, perímetro, coletor e hash de cada marcação',
                      onTap: () =>
                          _download('/reports/punches.csv', 'text/csv'),
                    ),
                    _ExportCard(
                      icon: Icons.gavel_outlined,
                      title: 'AFD — Arquivo Fonte de Dados',
                      subtitle:
                          'Portaria 671, leiaute 003 (REP-P) para fiscalização',
                      onTap: () => _download('/reports/afd', 'text/plain'),
                    ),
                    _ExportCard(
                      icon: Icons.description_outlined,
                      title: 'AEJ — Arquivo Eletrônico de Jornada',
                      subtitle: 'Jornadas tratadas, ausências e banco de horas',
                      onTap: () => _download('/reports/aej', 'text/plain'),
                    ),
                  ],
                ),
                _ClosingsSection(from: from, to: to),
                const SectionTitle('Resumo por colaborador'),
                AsyncView(
                  value: summary,
                  onRetry: () =>
                      ref.invalidate(summaryProvider((from: from, to: to))),
                  builder: (d) {
                    final rows = [
                      for (final r in d['rows'] as List)
                        (r as Map).cast<String, dynamic>(),
                    ];
                    if (rows.isEmpty) {
                      return const EmptyState(
                        icon: Icons.insert_chart_outlined,
                        title: 'Sem dados no período',
                      );
                    }
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          showCheckboxColumn: false,
                          headingRowColor: WidgetStatePropertyAll(
                            AppColors.brand.withValues(alpha: 0.06),
                          ),
                          columns: const [
                            DataColumn(label: Text('Colaborador')),
                            DataColumn(label: Text('Previsto'), numeric: true),
                            DataColumn(
                              label: Text('Trabalhado'),
                              numeric: true,
                            ),
                            DataColumn(label: Text('Extras'), numeric: true),
                            DataColumn(
                              label: Text('Faltas/atrasos'),
                              numeric: true,
                            ),
                            DataColumn(label: Text('Noturno'), numeric: true),
                            DataColumn(
                              label: Text('Banco (saldo)'),
                              numeric: true,
                            ),
                            DataColumn(label: Text('Faltas'), numeric: true),
                            DataColumn(label: Text('Alertas'), numeric: true),
                          ],
                          rows: [
                            for (final r in rows)
                              DataRow(
                                onSelectChanged: (_) =>
                                    context.push('/equipe/${r['member_id']}'),
                                cells: [
                                  DataCell(Text(r['name'] as String)),
                                  DataCell(Text(hm(r['expected'] as int))),
                                  DataCell(Text(hm(r['worked'] as int))),
                                  DataCell(
                                    Text(
                                      hm(
                                        r['overtime_total'] as int,
                                        dashIfZero: true,
                                      ),
                                      style: const TextStyle(
                                        color: AppColors.accent,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      hm(r['deficit'] as int, dashIfZero: true),
                                      style: const TextStyle(
                                        color: AppColors.danger,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      hm(
                                        r['night_minutes'] as int,
                                        dashIfZero: true,
                                      ),
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      hm(
                                        r['bank_balance'] as int? ?? 0,
                                        signed: true,
                                      ),
                                    ),
                                  ),
                                  DataCell(Text('${r['absences']}')),
                                  DataCell(Text('${r['issues']}')),
                                ],
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ExportCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 32, color: AppColors.brand),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.download_outlined),
          ],
        ),
      ),
    ),
  );
}

/// Fechamento de período (trava o tratamento do ponto após enviar a folha).
class _ClosingsSection extends ConsumerWidget {
  final LocalDate from;
  final LocalDate to;
  const _ClosingsSection({required this.from, required this.to});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final data = ref.watch(closingsProvider);
    final api = ref.read(apiProvider);
    final today = LocalDate.fromDateTime(ServerClock.wall(me.offset));
    final list = data.value ?? const [];
    final closed = list.any(
      (c) =>
          LocalDate.parse(c['start_date'] as String) <= to &&
          LocalDate.parse(c['end_date'] as String) >= from,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Fechamento de período',
          trailing: closed
              ? const StatusChip(
                  'Fechado',
                  color: AppColors.info,
                  icon: Icons.lock_outline,
                )
              : FilledButton.tonalIcon(
                  onPressed: to >= today
                      ? null
                      : () async {
                          final ok = await confirm(
                            context,
                            'Fechar período',
                            'Após o fechamento de ${from.toBr()} a ${to.toBr()}, inclusões, desconsiderações, abonos, '
                                'aprovações e lançamentos no banco de horas ficam bloqueados até a reabertura.',
                            ok: 'Fechar período',
                          );
                          if (!ok || !context.mounted) return;
                          await runAction(
                            context,
                            () => api.post('/closings', {
                              'from': from.toString(),
                              'to': to.toString(),
                            }),
                            success: 'Período fechado',
                          );
                          ref.invalidate(closingsProvider);
                          ref.invalidate(timesheetProvider);
                        },
                  icon: const Icon(Icons.lock_outline),
                  label: Text(
                    to >= today ? 'Período em andamento' : 'Fechar período',
                  ),
                ),
        ),
        if (list.isNotEmpty)
          Card(
            child: Column(
              children: [
                for (final c in list.take(6))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.lock_outline),
                    title: Text(
                      '${LocalDate.parse(c['start_date'] as String).toBr()} a '
                      '${LocalDate.parse(c['end_date'] as String).toBr()}',
                    ),
                    subtitle: Text(
                      'Fechado ${c['closed_by_name'] != null ? 'por ${c['closed_by_name']} ' : ''}'
                      '${relativeTime(DateTime.parse(c['created_at'] as String))}',
                    ),
                    trailing: me.isAdmin
                        ? TextButton(
                            onPressed: () async {
                              final ok = await confirm(
                                context,
                                'Reabrir período',
                                'O tratamento do ponto voltará a ser permitido. A reabertura fica registrada na auditoria.',
                                ok: 'Reabrir',
                                destructive: true,
                              );
                              if (!ok || !context.mounted) return;
                              await runAction(
                                context,
                                () => api.delete('/closings/${c['id']}'),
                                success: 'Período reaberto',
                              );
                              ref.invalidate(closingsProvider);
                              ref.invalidate(timesheetProvider);
                            },
                            child: const Text('Reabrir'),
                          )
                        : null,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
