import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../config.dart';
import '../../services/file_service.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../employee/request_form.dart';
import 'receipt_sheet.dart';

/// Espelho de ponto do período. Para gestores ([canTreat]), permite o
/// tratamento: incluir/desconsiderar marcações e lançar abonos.
class TimesheetView extends ConsumerStatefulWidget {
  final String? memberId;
  final bool canTreat;
  const TimesheetView({super.key, this.memberId, this.canTreat = false});

  @override
  ConsumerState<TimesheetView> createState() => _TimesheetViewState();
}

class _TimesheetViewState extends ConsumerState<TimesheetView> {
  late LocalDate _anchor;

  @override
  void initState() {
    super.initState();
    final me = ref.read(meProvider);
    _anchor = LocalDate.fromDateTime(ServerClock.wall(me.offset));
  }

  PeriodQuery _query(Me me) {
    final settings = me.company?.settings ?? const CompanySettings();
    final (from, to) = settings.periodFor(_anchor);
    return (memberId: widget.memberId, from: from, to: to);
  }

  void _refresh(PeriodQuery q) {
    ref.invalidate(timesheetProvider(q));
    ref.invalidate(todayProvider);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final q = _query(me);
    final data = ref.watch(timesheetProvider(q));
    return RefreshIndicator(
      onRefresh: () async => _refresh(q),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Constrained(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 8,
                  children: [
                    MonthSelector(
                      month: _anchor,
                      onChanged: (d) => setState(() => _anchor = d),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => runAction(context, () async {
                            final (bytes, name) = await ref
                                .read(apiProvider)
                                .download(
                                  '/timesheet.pdf',
                                  query: {
                                    'member_id': widget.memberId,
                                    'from': q.from.toString(),
                                    'to': q.to.toString(),
                                  },
                                );
                            await saveAndOpen(
                              bytes,
                              name ?? 'espelho.pdf',
                              'application/pdf',
                            );
                          }),
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('PDF'),
                        ),
                        if (widget.memberId == null ||
                            widget.memberId == me.member?.id)
                          data.maybeWhen(
                            data: (d) => _SignButton(
                              data: d,
                              query: q,
                              onSigned: () => _refresh(q),
                            ),
                            orElse: () => const SizedBox.shrink(),
                          ),
                      ],
                    ),
                  ],
                ),
                Text(
                  'Período: ${q.from.toBr()} a ${q.to.toBr()}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                AsyncView(
                  value: data,
                  onRetry: () => _refresh(q),
                  builder: (d) => _Content(
                    data: d,
                    canTreat: widget.canTreat,
                    isSelf:
                        widget.memberId == null ||
                        widget.memberId == me.member?.id,
                    onChanged: () => _refresh(q),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SignButton extends ConsumerWidget {
  final Map<String, dynamic> data;
  final PeriodQuery query;
  final VoidCallback onSigned;
  const _SignButton({
    required this.data,
    required this.query,
    required this.onSigned,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final signature = data['signature'] as Map?;
    if (signature != null) {
      return StatusChip(
        signature['agreed'] == true ? 'Assinado' : 'Assinado c/ ressalvas',
        color: AppColors.accent,
        icon: Icons.verified_outlined,
      );
    }
    final today = LocalDate.fromDateTime(ServerClock.wall(me.offset));
    if (query.to >= today) return const SizedBox.shrink();
    return FilledButton.icon(
      onPressed: () => _sign(context, ref),
      icon: const Icon(Icons.draw_outlined),
      label: const Text('Assinar espelho'),
    );
  }

  Future<void> _sign(BuildContext context, WidgetRef ref) async {
    final comment = TextEditingController();
    var agreed = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Assinar espelho de ponto'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Período de ${query.from.toBr()} a ${query.to.toBr()}. A assinatura eletrônica registra data, hora, IP e o hash do espelho.',
              ),
              const SizedBox(height: 12),
              RadioGroup<bool>(
                groupValue: agreed,
                onChanged: (v) => set(() => agreed = v ?? true),
                child: const Column(
                  children: [
                    RadioListTile(
                      value: true,
                      title: Text('Estou de acordo'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile(
                      value: false,
                      title: Text('Assinar com ressalvas'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              if (!agreed)
                TextField(
                  controller: comment,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Descreva as ressalvas',
                  ),
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
              child: const Text('Assinar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final r = await runAction(
      context,
      () => ref.read(apiProvider).post('/timesheet/sign', {
        'from': query.from.toString(),
        'to': query.to.toString(),
        'agreed': agreed,
        if (!agreed) 'comment': comment.text,
      }),
      success: 'Espelho assinado eletronicamente',
    );
    if (r != null) onSigned();
  }
}

class _Content extends ConsumerWidget {
  final Map<String, dynamic> data;
  final bool canTreat;
  final bool isSelf;
  final VoidCallback onChanged;
  const _Content({
    required this.data,
    required this.canTreat,
    required this.isSelf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totals = (data['totals'] as Map).cast<String, dynamic>();
    final days = [
      for (final d in data['days'] as List) (d as Map).cast<String, dynamic>(),
    ];
    final details = {
      for (final p in data['punch_details'] as List? ?? const [])
        (p as Map)['id'] as String: Punch.fromJson(p.cast()),
    };
    final overtime = (totals['overtime'] as Map).cast<String, dynamic>();
    final schedule = (data['schedule'] as Map?)?.cast<String, dynamic>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (schedule != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Escala: ${schedule['name']} • ${CompensationRegime.fromCode(schedule['regime'] as String?).label}',
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ),
        ResponsiveGrid(
          minItemWidth: 210,
          children: [
            StatCard(
              label: 'Trabalhado',
              value: hm(totals['worked'] as int),
              icon: Icons.timer_outlined,
            ),
            StatCard(
              label: 'Previsto',
              value: hm(totals['expected'] as int),
              icon: Icons.event_note_outlined,
              color: AppColors.info,
            ),
            StatCard(
              label: 'Horas extras',
              value: hm(totals['overtime_total'] as int),
              icon: Icons.trending_up,
              color: AppColors.accent,
              hint: overtime.entries
                  .map((e) => '${e.key}%: ${hm(e.value as int)}')
                  .join('  '),
            ),
            StatCard(
              label: 'Faltas/atrasos',
              value: hm(totals['deficit'] as int),
              icon: Icons.trending_down,
              color: AppColors.danger,
              hint: '${totals['absences']} falta(s)',
            ),
            StatCard(
              label: 'Banco de horas',
              value: hm(totals['bank_delta'] as int, signed: true),
              icon: Icons.savings_outlined,
              color: AppColors.warning,
            ),
            StatCard(
              label: 'Noturno',
              value: hm(totals['night_minutes'] as int),
              icon: Icons.nightlight_outlined,
              color: const Color(0xFF6366F1),
              hint: 'Reduzido: ${hm(totals['night_minutes_reduced'] as int)}',
            ),
          ],
        ),
        const SectionTitle('Dias'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < days.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _DayRow(
                  day: days[i],
                  details: details,
                  onTap: () => _openDay(context, ref, days[i], details),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openDay(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> day,
    Map<String, Punch> details,
  ) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => _DaySheet(
        day: day,
        details: details,
        memberId: (data['member'] as Map)['id'] as String,
        canTreat: canTreat,
        isSelf: isSelf,
        onChanged: onChanged,
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  final Map<String, dynamic> day;
  final Map<String, Punch> details;
  final VoidCallback onTap;
  const _DayRow({
    required this.day,
    required this.details,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final date = LocalDate.parse(day['date'] as String);
    final status = DayStatus.fromCode(day['status'] as String?);
    final punches = [
      for (final p in day['punches'] as List)
        (p as Map).cast<String, dynamic>(),
    ];
    final balance = day['balance'] as int;
    final issues = day['issues'] as List;
    final weekend = date.weekday >= 6;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: Column(
                children: [
                  Text(
                    date.day.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: weekend ? AppColors.muted : null,
                    ),
                  ),
                  Text(
                    TimeFmt.weekdayShort[date.weekday - 1],
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (punches.isEmpty && status == DayStatus.open)
                    Text(
                      (day['template'] as Map)['work'] == true
                          ? 'Previsto: ${day['template_label']}'
                          : 'Folga',
                      style: const TextStyle(color: AppColors.muted),
                    )
                  else if (punches.isEmpty)
                    Text(
                      day['holiday'] as String? ?? status.label,
                      style: TextStyle(
                        color: dayStatusColor(status),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final p in punches)
                          _PunchChip(
                            time: TimeFmt.clock(
                              DateTime.parse(
                                '${p['time']}'.replaceAll('Z', ''),
                              ),
                            ),
                            origin: PunchOrigin.fromCode(
                              p['origin'] as String?,
                            ),
                            outside: details[p['id']]?.insideGeofence == false,
                          ),
                      ],
                    ),
                  if (issues.isNotEmpty ||
                      (punches.isNotEmpty &&
                          status != DayStatus.normal &&
                          status != DayStatus.open))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          if (punches.isNotEmpty &&
                              status != DayStatus.normal &&
                              status != DayStatus.open)
                            status.label,
                          for (final i in issues)
                            if ((i as Map)['type'] != 'absent')
                              (i['label'] as String).split(' (').first,
                        ].join(' • '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.warning,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  hm(day['worked'] as int, dashIfZero: true),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (balance != 0)
                  Text(
                    hm(balance, signed: true),
                    style: TextStyle(
                      fontSize: 12,
                      color: balance > 0 ? AppColors.accent : AppColors.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const Icon(Icons.chevron_right, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

class _PunchChip extends StatelessWidget {
  final String time;
  final PunchOrigin origin;
  final bool outside;
  const _PunchChip({
    required this.time,
    required this.origin,
    required this.outside,
  });

  @override
  Widget build(BuildContext context) {
    final color = origin == PunchOrigin.original
        ? (outside ? AppColors.warning : AppColors.brand)
        : AppColors.info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        origin == PunchOrigin.original ? time : '$time ${origin.code}',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _DaySheet extends ConsumerWidget {
  final Map<String, dynamic> day;
  final Map<String, Punch> details;
  final String memberId;
  final bool canTreat;
  final bool isSelf;
  final VoidCallback onChanged;

  const _DaySheet({
    required this.day,
    required this.details,
    required this.memberId,
    required this.canTreat,
    required this.isSelf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = LocalDate.parse(day['date'] as String);
    final status = DayStatus.fromCode(day['status'] as String?);
    final dayPunches = [
      for (final p in day['punches'] as List)
        (p as Map).cast<String, dynamic>(),
    ];
    final ids = {for (final p in dayPunches) p['id']};
    final (ws, we) = (
      date.toDateTime().subtract(const Duration(hours: 6)),
      date.toDateTime().add(const Duration(hours: 30)),
    );
    // Inclui as desconsideradas do mesmo dia (não aparecem no cálculo).
    final disregarded = details.values.where(
      (p) =>
          p.disregarded &&
          p.wall.isAfter(ws) &&
          p.wall.isBefore(we) &&
          LocalDate.fromDateTime(p.wall) == date &&
          !ids.contains(p.id),
    );
    final overtime = (day['overtime'] as Map).cast<String, dynamic>();
    final api = ref.read(apiProvider);

    Future<void> act(Future<void> Function() fn, String ok) async {
      final r = await runAction(context, () async {
        await fn();
        return true;
      }, success: ok);
      if (r == true) {
        onChanged();
        if (context.mounted) Navigator.pop(context);
      }
    }

    Widget punchTile(
      String? id,
      DateTime wall,
      PunchOrigin origin, {
      bool isDisregarded = false,
    }) {
      final p = id == null ? null : details[id];
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: p?.photoUrl != null
            ? CircleAvatar(
                backgroundImage: NetworkImage(
                  AppConfig.resolveUrl(p!.photoUrl),
                ),
              )
            : CircleAvatar(
                child: Icon(
                  origin == PunchOrigin.original
                      ? Icons.fingerprint
                      : Icons.edit_note,
                ),
              ),
        title: Text(
          TimeFmt.clock(wall),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 17,
            decoration: isDisregarded ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text(
          [
            origin.label,
            if (p != null) p.method.label,
            if (p?.geofenceName != null)
              '${p!.insideGeofence == false ? 'fora de ' : ''}${p.geofenceName}',
            if (p?.distance != null && p?.insideGeofence == false)
              '${p!.distance!.round()} m',
            if (p?.offline == true) 'off-line',
            if (p?.nsr != null) 'NSR ${p!.nsr}',
            if (isDisregarded && p?.disregardReason != null)
              'Desconsiderada: ${p!.disregardReason}',
            if (origin != PunchOrigin.original && p?.note != null) p!.note!,
          ].join(' • '),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (p?.nsr != null)
              IconButton(
                tooltip: 'Comprovante',
                icon: const Icon(Icons.receipt_long_outlined),
                onPressed: () => showReceiptById(context, p!.id),
              ),
            if (canTreat && p != null)
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'disregard') {
                    final reason = await promptText(
                      context,
                      'Desconsiderar marcação',
                      label: 'Justificativa',
                    );
                    if (reason != null) {
                      await act(
                        () => api.post('/punches/${p.id}/disregard', {
                          'reason': reason,
                        }),
                        'Marcação desconsiderada',
                      );
                    }
                  } else if (v == 'restore') {
                    await act(
                      () => api.post('/punches/${p.id}/restore'),
                      'Marcação restaurada',
                    );
                  } else if (v == 'delete') {
                    if (await confirm(
                      context,
                      'Excluir inclusão',
                      'Remover esta marcação incluída manualmente?',
                      destructive: true,
                    )) {
                      await act(
                        () => api.delete('/punches/${p.id}'),
                        'Marcação excluída',
                      );
                    }
                  }
                },
                itemBuilder: (_) => [
                  if (!p.disregarded)
                    const PopupMenuItem(
                      value: 'disregard',
                      child: Text('Desconsiderar'),
                    ),
                  if (p.disregarded)
                    const PopupMenuItem(
                      value: 'restore',
                      child: Text('Restaurar'),
                    ),
                  if (p.origin != PunchOrigin.original)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Excluir'),
                    ),
                ],
              ),
          ],
        ),
      );
    }

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (c, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(
              capitalize(dateLong(date)),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                StatusChip(status.label, color: dayStatusColor(status)),
                if (day['holiday'] != null)
                  StatusChip(
                    day['holiday'] as String,
                    color: AppColors.muted,
                    icon: Icons.celebration_outlined,
                  ),
                StatusChip(
                  'Escala: ${day['template_label']}',
                  color: AppColors.info,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _kv('Previsto', hm(day['expected'] as int)),
                _kv('Trabalhado', hm(day['worked'] as int)),
                _kv('Saldo', hm(day['balance'] as int, signed: true)),
                if ((day['excused'] as int) > 0)
                  _kv('Abonado', hm(day['excused'] as int)),
                for (final e in overtime.entries)
                  _kv('Extra ${e.key}%', hm(e.value as int)),
                if ((day['night_minutes'] as int) > 0)
                  _kv('Noturno', hm(day['night_minutes'] as int)),
                if ((day['bank_delta'] as int) != 0)
                  _kv('Banco', hm(day['bank_delta'] as int, signed: true)),
              ],
            ),
            if ((day['issues'] as List).isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final i in day['issues'] as List)
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: AppColors.warning,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${(i as Map)['label']}${i['minutes'] != null ? ' (${hm(i['minutes'] as int)})' : ''}',
                      ),
                    ),
                  ],
                ),
            ],
            const SectionTitle('Marcações'),
            if (dayPunches.isEmpty && disregarded.isEmpty)
              const Text('Nenhuma marcação neste dia.'),
            for (final p in dayPunches)
              punchTile(
                p['id'] as String?,
                DateTime.parse('${p['time']}'.replaceAll('Z', '')),
                PunchOrigin.fromCode(p['origin'] as String?),
              ),
            for (final p in disregarded)
              punchTile(p.id, p.wall, p.origin, isDisregarded: true),
            const SizedBox(height: 16),
            if (canTreat) ...[
              FilledButton.icon(
                onPressed: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: const TimeOfDay(hour: 8, minute: 0),
                    helpText: 'Horário da marcação a incluir',
                  );
                  if (time == null || !context.mounted) return;
                  final reason = await promptText(
                    context,
                    'Justificativa da inclusão',
                    label: 'Ex.: esquecimento',
                  );
                  if (reason == null) return;
                  await act(
                    () => api.post('/punches/manual', {
                      'member_id': memberId,
                      'date': date.toString(),
                      'time':
                          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                      'reason': reason,
                    }),
                    'Marcação incluída',
                  );
                },
                icon: const Icon(Icons.add_alarm),
                label: const Text('Incluir marcação'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final type = await showDialog<AbsenceType>(
                    context: context,
                    builder: (c) => SimpleDialog(
                      title: const Text('Lançar abono/ausência'),
                      children: [
                        for (final t in AbsenceType.values)
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(c, t),
                            child: Text(t.label),
                          ),
                      ],
                    ),
                  );
                  if (type == null || !context.mounted) return;
                  final reason = await promptText(
                    context,
                    type.label,
                    label: 'Motivo',
                    required: false,
                  );
                  if (reason == null) return;
                  await act(
                    () => api.post('/absences', {
                      'member_id': memberId,
                      'type': type.code,
                      'start_date': date.toString(),
                      'end_date': date.toString(),
                      'reason': reason,
                    }),
                    '${type.label} lançado',
                  );
                },
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Lançar abono / atestado / folga'),
              ),
            ] else if (isSelf)
              FilledButton.tonalIcon(
                onPressed: () async {
                  Navigator.pop(context);
                  await showRequestForm(
                    context,
                    initialDate: date,
                    initialType: dayPunches.isEmpty
                        ? RequestType.forgotPunch
                        : RequestType.adjustment,
                  );
                },
                icon: const Icon(Icons.edit_calendar_outlined),
                label: const Text('Solicitar ajuste deste dia'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(k, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
      Text(
        v,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ],
  );
}
