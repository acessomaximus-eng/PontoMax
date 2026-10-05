import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../services/reminders.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/common.dart';
import '../common/receipt_sheet.dart';
import '../common/timesheet_view.dart';
import 'request_form.dart';

// ---------------------------------------------------------------------------
// Espelho
// ---------------------------------------------------------------------------

class MyTimesheetPage extends StatelessWidget {
  const MyTimesheetPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Espelho de ponto')),
    body: const TimesheetView(),
  );
}

// ---------------------------------------------------------------------------
// Solicitações
// ---------------------------------------------------------------------------

class MyRequestsPage extends ConsumerWidget {
  const MyRequestsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(requestsProvider((mine: true, status: null)));
    return Scaffold(
      appBar: AppBar(title: const Text('Minhas solicitações')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showRequestForm(context),
        icon: const Icon(Icons.add),
        label: const Text('Nova solicitação'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(requestsProvider),
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(requestsProvider),
          builder: (list) => list.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 80),
                    EmptyState(
                      icon: Icons.assignment_outlined,
                      title: 'Nenhuma solicitação',
                      message: 'Esqueceu de bater o ponto, precisa enviar um atestado ou pedir folga? Toque em "Nova solicitação".',
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (c, i) => Constrained(
                    maxWidth: 800,
                    child: RequestCard(request: list[i], mine: true),
                  ),
                ),
        ),
      ),
    );
  }
}

class RequestCard extends ConsumerWidget {
  final TimeRequest request;
  final bool mine;
  final Widget? actions;
  const RequestCard({
    super.key,
    required this.request,
    this.mine = false,
    this.actions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final period = r.endDate != null && r.endDate != r.date
        ? '${r.date.toBr()} a ${r.endDate!.toBr()}'
        : r.date.toBr();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.brand.withValues(alpha: 0.1),
                  child: Icon(requestTypeIcon(r.type), color: AppColors.brand),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mine ? r.type.label : (r.memberName ?? ''),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        mine ? period : '${r.type.label} • $period',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusChip(r.status.label, color: requestStatusColor(r.status)),
              ],
            ),
            const SizedBox(height: 10),
            Text(r.reason),
            if (r.times.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final t in r.times)
                    Chip(label: Text(t), visualDensity: VisualDensity.compact),
                ],
              ),
            ],
            if (r.minutes != null)
              Text(
                'Horas por dia: ${hm(r.minutes!)}',
                style: const TextStyle(fontSize: 13),
              ),
            if (r.attachmentUrl != null)
              TextButton.icon(
                onPressed: () =>
                    launchUrl(Uri.parse(AppConfig.resolveUrl(r.attachmentUrl))),
                icon: const Icon(Icons.attachment),
                label: const Text('Ver anexo'),
              ),
            if (r.reviewNote != null || r.reviewerName != null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${r.reviewerName ?? 'Gestor'}: ${r.reviewNote ?? r.status.label}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            if (mine && r.status == RequestStatus.pending)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () async {
                    if (!await confirm(
                      context,
                      'Cancelar solicitação',
                      'Deseja cancelar esta solicitação?',
                    )) {
                      return;
                    }
                    if (!context.mounted) return;
                    await runAction(
                      context,
                      () => ref
                          .read(apiProvider)
                          .post('/requests/${r.id}/cancel'),
                      success: 'Solicitação cancelada',
                    );
                    ref.invalidate(requestsProvider);
                  },
                  child: const Text('Cancelar'),
                ),
              ),
            ?actions,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Banco de horas
// ---------------------------------------------------------------------------

class BankPage extends ConsumerWidget {
  final String? memberId;
  const BankPage({super.key, this.memberId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(bankProvider(memberId));
    return Scaffold(
      appBar: AppBar(title: const Text('Banco de horas')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(bankProvider(memberId)),
        builder: (d) => BankView(data: d),
      ),
    );
  }
}

class BankView extends StatelessWidget {
  final Map<String, dynamic> data;
  const BankView({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final balance = data['balance'] as int;
    final monthly = [
      for (final m in data['monthly'] as List)
        (m as Map).cast<String, dynamic>(),
    ];
    final entries = [
      for (final e in data['entries'] as List)
        BankEntry.fromJson((e as Map).cast()),
    ];
    final positive = balance >= 0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Constrained(
          maxWidth: 800,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                color: (positive ? AppColors.accent : AppColors.danger)
                    .withValues(alpha: 0.08),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Text(
                        'Saldo atual',
                        style: TextStyle(color: AppColors.muted),
                      ),
                      Text(
                        hm(balance, signed: true),
                        style: TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w900,
                          color: positive ? AppColors.accent : AppColors.danger,
                        ),
                      ),
                      Text(
                        positive
                            ? 'Horas a compensar a seu favor'
                            : 'Horas devidas à empresa',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Apurado desde ${LocalDate.parse(data['since'] as String).toBr()} • '
                        'Regime: ${CompensationRegime.fromCode(data['regime'] as String?).label}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if ((data['validity_months'] as int? ?? 0) > 0 &&
                  ((data['expired'] as int? ?? 0) > 0 ||
                      (data['expiring_soon'] as int? ?? 0) > 0))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ResponsiveGrid(
                    minItemWidth: 220,
                    children: [
                      if ((data['expired'] as int) > 0)
                        StatCard(
                          label: 'Vencido — a pagar como extra',
                          value: hm(data['expired'] as int),
                          icon: Icons.event_busy_outlined,
                          color: AppColors.danger,
                          hint:
                              'Validade de ${data['validity_months']} meses (art. 59 CLT)',
                        ),
                      if ((data['expiring_soon'] as int) > 0)
                        StatCard(
                          label: 'Vence nos próximos 30 dias',
                          value: hm(data['expiring_soon'] as int),
                          icon: Icons.hourglass_bottom,
                          color: AppColors.warning,
                          hint: 'Compense ou registre o pagamento',
                        ),
                    ],
                  ),
                ),
              ResponsiveGrid(
                minItemWidth: 180,
                children: [
                  StatCard(
                    label: 'Saldo inicial',
                    value: hm(data['initial'] as int, signed: true),
                    icon: Icons.flag_outlined,
                    color: AppColors.muted,
                  ),
                  StatCard(
                    label: 'Apurado pelo ponto',
                    value: hm(data['computed'] as int, signed: true),
                    icon: Icons.calculate_outlined,
                  ),
                  StatCard(
                    label: 'Lançamentos manuais',
                    value: hm(data['manual'] as int, signed: true),
                    icon: Icons.edit_note,
                    color: AppColors.info,
                  ),
                ],
              ),
              if (monthly.isNotEmpty) ...[
                const SectionTitle('Movimentação por mês'),
                Card(
                  child: Column(
                    children: [
                      for (final m in monthly)
                        ListTile(
                          dense: true,
                          title: Text(
                            capitalize(
                              monthLabel(LocalDate.parse('${m['month']}-01')),
                            ),
                          ),
                          trailing: Text(
                            hm(m['minutes'] as int, signed: true),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: (m['minutes'] as int) >= 0
                                  ? AppColors.accent
                                  : AppColors.danger,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (entries.isNotEmpty) ...[
                const SectionTitle('Lançamentos manuais'),
                Card(
                  child: Column(
                    children: [
                      for (final e in entries)
                        ListTile(
                          title: Text(e.type.label),
                          subtitle: Text(
                            '${e.date.toBr()}${e.description.isEmpty ? '' : ' • ${e.description}'}',
                          ),
                          trailing: Text(
                            hm(e.minutes, signed: true),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Comprovantes
// ---------------------------------------------------------------------------

class ReceiptsPage extends ConsumerStatefulWidget {
  const ReceiptsPage({super.key});
  @override
  ConsumerState<ReceiptsPage> createState() => _ReceiptsPageState();
}

class _ReceiptsPageState extends ConsumerState<ReceiptsPage> {
  late LocalDate _month;

  @override
  void initState() {
    super.initState();
    _month = LocalDate.fromDateTime(
      ServerClock.wall(ref.read(meProvider).offset),
    ).firstDayOfMonth;
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final q = (
      memberId: me.member?.id,
      from: _month,
      to: _month.lastDayOfMonth,
      outside: false,
    );
    final data = ref.watch(punchesProvider(q));
    return Scaffold(
      appBar: AppBar(title: const Text('Comprovantes de ponto')),
      body: Column(
        children: [
          MonthSelector(
            month: _month,
            onChanged: (d) => setState(() => _month = d),
          ),
          Expanded(
            child: AsyncView(
              value: data,
              onRetry: () => ref.invalidate(punchesProvider(q)),
              builder: (list) {
                final receipts = list.where((p) => p.nsr != null).toList();
                if (receipts.isEmpty) {
                  return const EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'Sem comprovantes neste mês',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: receipts.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final p = receipts[i];
                    return Constrained(
                      maxWidth: 800,
                      child: ListTile(
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: Text(
                          '${LocalDate.fromDateTime(p.wall).toBr()} às ${TimeFmt.clock(p.wall)}',
                        ),
                        subtitle: Text(
                          'NSR ${p.nsr} • ${p.source.label}${p.disregarded ? ' • desconsiderada' : ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showReceiptById(context, p.id),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bloco de notas
// ---------------------------------------------------------------------------

class NotesPage extends ConsumerWidget {
  const NotesPage({super.key});

  static const colors = {
    'default': Colors.white,
    'yellow': Color(0xFFFEF9C3),
    'green': Color(0xFFDCFCE7),
    'blue': Color(0xFFDBEAFE),
    'pink': Color(0xFFFCE7F3),
  };

  Future<void> _edit(BuildContext context, WidgetRef ref, [Note? note]) async {
    final title = TextEditingController(text: note?.title);
    final body = TextEditingController(text: note?.body);
    var color = note?.color ?? 'default';
    var pinned = note?.pinned ?? false;
    final save = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(note == null ? 'Nova nota' : 'Editar nota'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Título'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: body,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Anotação'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final e in colors.entries)
                      GestureDetector(
                        onTap: () => set(() => color = e.key),
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: e.value,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color == e.key
                                  ? AppColors.brand
                                  : Colors.black12,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Fixar',
                      onPressed: () => set(() => pinned = !pinned),
                      icon: Icon(
                        pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            if (note != null)
              TextButton(
                onPressed: () async {
                  await ref.read(apiProvider).delete('/notes/${note.id}');
                  if (c.mounted) Navigator.pop(c, false);
                  ref.invalidate(notesProvider);
                },
                child: const Text(
                  'Excluir',
                  style: TextStyle(color: AppColors.danger),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    if (save != true || !context.mounted) return;
    final payload = {
      'title': title.text,
      'body': body.text,
      'color': color,
      'pinned': pinned,
    };
    await runAction(context, () async {
      final api = ref.read(apiProvider);
      if (note == null) {
        await api.post('/notes', payload);
      } else {
        await api.put('/notes/${note.id}', payload);
      }
    });
    ref.invalidate(notesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(notesProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Bloco de notas')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref),
        child: const Icon(Icons.add),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(notesProvider),
        builder: (notes) => notes.isEmpty
            ? const EmptyState(
                icon: Icons.sticky_note_2_outlined,
                title: 'Nenhuma anotação',
                message: 'Guarde lembretes sobre sua jornada.',
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ResponsiveGrid(
                    minItemWidth: 240,
                    children: [
                      for (final n in notes)
                        Card(
                          color: dark ? null : colors[n.color],
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => _edit(context, ref, n),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          n.title,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (n.pinned)
                                        const Icon(Icons.push_pin, size: 16),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    n.body,
                                    maxLines: 6,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    n.updatedAt == null
                                        ? ''
                                        : relativeTime(n.updatedAt!),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Notificações
// ---------------------------------------------------------------------------

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(notificationsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notificações'),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.read(apiProvider).post('/notifications/read-all');
              ref.invalidate(notificationsProvider);
              await ref.read(sessionProvider.notifier).refreshMe();
            },
            child: const Text('Marcar todas como lidas'),
          ),
        ],
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(notificationsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.notifications_none,
                title: 'Tudo em dia',
                message: 'Você não tem notificações.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (c, i) {
                  final n = list[i];
                  final unread = n.readAt == null;
                  return Constrained(
                    maxWidth: 800,
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            (unread ? AppColors.brand : AppColors.muted)
                                .withValues(alpha: 0.12),
                        child: Icon(
                          _icon(n.type),
                          color: unread ? AppColors.brand : AppColors.muted,
                        ),
                      ),
                      title: Text(
                        n.title,
                        style: TextStyle(
                          fontWeight: unread
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text('${n.body}\n${relativeTime(n.createdAt)}'),
                      isThreeLine: true,
                      onTap: () async {
                        if (unread) {
                          await ref
                              .read(apiProvider)
                              .post('/notifications/${n.id}/read');
                          ref.invalidate(notificationsProvider);
                          unawaitedRefresh(ref);
                        }
                        if (!context.mounted) return;
                        if (n.type == 'request_created') {
                          context.go('/aprovacoes');
                        } else if (n.type.startsWith('request_')) {
                          context.go('/solicitacoes');
                        } else if (n.type == 'bank_entry') {
                          context.go('/banco');
                        }
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }

  static IconData _icon(String type) => switch (type) {
    'request_created' => Icons.assignment_late_outlined,
    'request_approved' => Icons.check_circle_outline,
    'request_rejected' => Icons.cancel_outlined,
    'punch_included' => Icons.edit_calendar_outlined,
    'bank_entry' => Icons.savings_outlined,
    'timesheet_disagreement' => Icons.report_problem_outlined,
    _ => Icons.notifications_none,
  };
}

void unawaitedRefresh(WidgetRef ref) {
  ref.read(sessionProvider.notifier).refreshMe().catchError((_) {});
}

// ---------------------------------------------------------------------------
// Perfil e "Mais"
// ---------------------------------------------------------------------------

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});
  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  bool? _reminders;
  int _minutes = 5;

  @override
  void initState() {
    super.initState();
    Reminders.enabled().then(
      (v) => mounted ? setState(() => _reminders = v) : null,
    );
    Reminders.minutesBefore().then(
      (v) => mounted ? setState(() => _minutes = v) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final api = ref.read(apiProvider);
    final member = me.member;
    return Scaffold(
      appBar: AppBar(title: const Text('Meu perfil')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Constrained(
            maxWidth: 720,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Avatar(
                          name: me.user.name,
                          url: member?.photoUrl,
                          radius: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                me.user.name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                me.user.email,
                                style: const TextStyle(color: AppColors.muted),
                              ),
                              if (me.user.cpf != null)
                                Text(
                                  'CPF ${Documents.formatCpf(me.user.cpf)}',
                                  style: const TextStyle(
                                    color: AppColors.muted,
                                  ),
                                ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                children: [
                                  StatusChip(
                                    me.role.label,
                                    color: AppColors.brand,
                                  ),
                                  if (member?.departmentName != null)
                                    StatusChip(
                                      member!.departmentName!,
                                      color: AppColors.info,
                                    ),
                                  if (member?.positionName != null)
                                    StatusChip(
                                      member!.positionName!,
                                      color: AppColors.muted,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SectionTitle('Empresa'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.apartment_rounded),
                        title: Text(me.company?.name ?? '-'),
                        subtitle: Text(
                          '${me.memberships.length} empresa(s) vinculada(s)',
                        ),
                        trailing: me.memberships.length > 1
                            ? const Icon(Icons.swap_horiz)
                            : null,
                        onTap: me.memberships.length > 1
                            ? () => showCompanyPicker(context, ref, me)
                            : null,
                      ),
                      if (member?.scheduleName != null)
                        ListTile(
                          leading: const Icon(Icons.schedule),
                          title: const Text('Escala'),
                          subtitle: Text(member!.scheduleName!),
                        ),
                      if (member?.registration != null)
                        ListTile(
                          leading: const Icon(Icons.badge_outlined),
                          title: const Text('Matrícula'),
                          subtitle: Text(member!.registration!),
                        ),
                    ],
                  ),
                ),
                if (member?.badgeCode != null) ...[
                  const SectionTitle('Crachá digital (quiosque)'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          QrImageView(
                            data: member!.badgeCode!,
                            size: 180,
                            backgroundColor: Colors.white,
                          ),
                          Text(
                            member.badgeCode!,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const Text(
                            'Apresente este código no leitor do quiosque para registrar o ponto.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SectionTitle('Lembretes de ponto'),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        value: _reminders ?? true,
                        title: const Text('Avisar antes de cada marcação'),
                        subtitle: Text(
                          Reminders.supported
                              ? 'Notificações conforme sua escala'
                              : 'Disponível no aplicativo para celular',
                        ),
                        onChanged: Reminders.supported
                            ? (v) async {
                                setState(() => _reminders = v);
                                if (v) await Reminders.requestPermission();
                                await Reminders.configure(
                                  enabled: v,
                                  minutesBefore: _minutes,
                                );
                              }
                            : null,
                      ),
                      ListTile(
                        title: const Text('Antecedência'),
                        trailing: DropdownButton<int>(
                          value: _minutes,
                          items: [
                            for (final m in const [0, 5, 10, 15, 30])
                              DropdownMenuItem(value: m, child: Text('$m min')),
                          ],
                          onChanged: (v) async {
                            if (v == null) return;
                            setState(() => _minutes = v);
                            await Reminders.configure(
                              enabled: _reminders ?? true,
                              minutesBefore: v,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionTitle('Segurança'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.password),
                        title: const Text('Alterar senha'),
                        onTap: () => _changePassword(context),
                      ),
                      ListTile(
                        leading: const Icon(Icons.pin_outlined),
                        title: const Text('PIN do quiosque'),
                        subtitle: Text(
                          member?.hasPin == true ? 'Definido' : 'Não definido',
                        ),
                        onTap: () async {
                          final pin = await promptText(
                            context,
                            'Novo PIN (4 a 6 dígitos)',
                            label: 'PIN',
                          );
                          if (pin == null || !context.mounted) return;
                          await runAction(
                            context,
                            () => api.put('/me/pin', {'pin': pin}),
                            success: 'PIN atualizado',
                          );
                          unawaitedRefresh(ref);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  onPressed: () => ref.read(sessionProvider.notifier).logout(),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sair'),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    'PontoMax ${AppConfig.appVersion} • ${AppConfig.apiUrl}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Alterar senha'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Senha atual'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Nova senha'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runAction(
      context,
      () => ref.read(apiProvider).put('/me/password', {
        'current_password': current.text,
        'new_password': next.text,
      }),
      success: 'Senha alterada',
    );
  }
}

/// Menu "Mais" (celular): acesso a todas as áreas.
class MorePage extends ConsumerWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final bottom = bottomItems(me).map((i) => i.path).toSet();
    return Scaffold(
      appBar: AppBar(title: const Text('Mais')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Avatar(name: me.user.name, url: me.member?.photoUrl),
              title: Text(
                me.user.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text('${me.role.label} • ${me.company?.name ?? ''}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/perfil'),
            ),
          ),
          if (me.memberships.length > 1) ...[
            const SizedBox(height: 8),
            CompanySwitcher(me: me),
          ],
          for (final g in navGroups(me)) ...[
            SectionTitle(g.title),
            Card(
              child: Column(
                children: [
                  for (final item in g.items.where(
                    (i) => !bottom.contains(i.path),
                  ))
                    ListTile(
                      leading: Icon(item.icon),
                      title: Text(item.label),
                      trailing: (item.badge?.call(me) ?? 0) > 0
                          ? Badge(label: Text('${item.badge!(me)}'))
                          : const Icon(Icons.chevron_right),
                      onTap: () => context.push(item.path),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => ref.read(sessionProvider.notifier).logout(),
            icon: const Icon(Icons.logout),
            label: const Text('Sair'),
          ),
        ],
      ),
    );
  }
}
