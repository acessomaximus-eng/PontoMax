import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

class SchedulesPage extends ConsumerWidget {
  const SchedulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(schedulesProvider);
    final me = ref.watch(meProvider);
    final defaultId = me.company?.defaultScheduleId;
    return Scaffold(
      appBar: AppBar(title: const Text('Escalas e jornadas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/escalas/nova'),
        icon: const Icon(Icons.add),
        label: const Text('Nova escala'),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(schedulesProvider),
        builder: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            for (final s in list)
              Constrained(
                maxWidth: 900,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ScheduleCard(entity: s, isDefault: s.id == defaultId),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleCard extends ConsumerWidget {
  final ScheduleEntity entity;
  final bool isDefault;
  const _ScheduleCard({required this.entity, required this.isDefault});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final def = ScheduleDefinition.fromJson(entity.definition.cast());
    final labels = def.type == ScheduleType.weekly
        ? TimeFmt.weekdayShort
        : [for (var i = 0; i < def.days.length; i++) 'Dia ${i + 1}'];
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/escalas/${entity.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      entity.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (isDefault)
                    const StatusChip('Padrão', color: AppColors.brand),
                  const SizedBox(width: 6),
                  StatusChip(
                    '${entity.membersCount} colaborador(es)',
                    color: AppColors.muted,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${def.type.label} • ${def.regime.label} • ${hm(def.weeklyMinutes)} semanais • tolerância ${def.tolerancePerMark}/${def.toleranceDaily} min',
                style: const TextStyle(color: AppColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < def.days.length && i < 14; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            (def.days[i].workDay
                                    ? AppColors.brand
                                    : AppColors.muted)
                                .withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${labels[i]}: ${def.days[i].describe()}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayDraft {
  bool work;
  List<(int, int)> intervals;
  int? flexible;
  _DayDraft(this.work, this.intervals, this.flexible);

  factory _DayDraft.from(DayTemplate t) => _DayDraft(t.workDay, [
    for (final i in t.intervals) (i.start, i.end),
  ], t.flexibleMinutes);

  DayTemplate toTemplate() => DayTemplate(
    workDay: work,
    intervals: work && flexible == null
        ? [for (final (s, e) in intervals) WorkInterval(s, e)]
        : const [],
    flexibleMinutes: work ? flexible : null,
  );
}

/// Editor de escala (semanal ou cíclica) com regras de cálculo.
class ScheduleEditorPage extends ConsumerStatefulWidget {
  final String? scheduleId;
  const ScheduleEditorPage({super.key, this.scheduleId});

  @override
  ConsumerState<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends ConsumerState<ScheduleEditorPage> {
  final _name = TextEditingController();
  ScheduleDefinition _base = ScheduleDefinition.standard44();
  List<_DayDraft> _days = [];
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.scheduleId != null) {
      ref.read(apiProvider).getMap('/schedules/${widget.scheduleId}').then((j) {
        final e = ScheduleEntity.fromJson(j);
        if (!mounted) return;
        setState(() {
          _name.text = e.name;
          _apply(ScheduleDefinition.fromJson(e.definition.cast()));
          _loaded = true;
        });
      });
    } else {
      _name.text = 'Nova escala';
      _apply(ScheduleDefinition.standard44());
      _loaded = true;
    }
  }

  void _apply(ScheduleDefinition d) {
    _base = d;
    _days = [for (final t in d.days) _DayDraft.from(t)];
  }

  ScheduleDefinition get _current =>
      _base.copyWith(days: [for (final d in _days) d.toTemplate()]);

  void _preset(String key) {
    final today = LocalDate.fromDateTime(DateTime.now());
    setState(() {
      switch (key) {
        case '44h':
          _apply(
            ScheduleDefinition.standard44().copyWith(regime: _base.regime),
          );
        case '40h':
          final d = DayTemplate.work([
            WorkInterval.hm('08:00', '12:00'),
            WorkInterval.hm('13:00', '17:00'),
          ]);
          _apply(
            _base.copyWith(
              type: ScheduleType.weekly,
              days: [d, d, d, d, d, DayTemplate.off, DayTemplate.off],
            ),
          );
        case '6x1':
          final d = DayTemplate.work([
            WorkInterval.hm('08:00', '12:00'),
            WorkInterval.hm('13:00', '15:20'),
          ]);
          _apply(
            _base.copyWith(
              type: ScheduleType.weekly,
              days: [d, d, d, d, d, d, DayTemplate.off],
            ),
          );
        case '12x36d':
          _apply(
            ScheduleDefinition.twelveByThirtySix(
              anchor: today,
              regime: _base.regime,
            ),
          );
        case '12x36n':
          _apply(
            ScheduleDefinition.twelveByThirtySix(
              anchor: today,
              start: '19:00',
              end: '07:00',
              regime: _base.regime,
            ),
          );
        case 'flex':
          final d = DayTemplate.flexible(480);
          _apply(
            _base.copyWith(
              type: ScheduleType.weekly,
              days: [d, d, d, d, d, DayTemplate.off, DayTemplate.off],
            ),
          );
      }
    });
  }

  Future<void> _editInterval(_DayDraft day, int index) async {
    final existing = index < day.intervals.length
        ? day.intervals[index]
        : (8 * 60, 12 * 60);
    final start = await showTimePicker(
      context: context,
      helpText: 'Início do período',
      initialTime: TimeOfDay(
        hour: (existing.$1 ~/ 60) % 24,
        minute: existing.$1 % 60,
      ),
    );
    if (start == null || !mounted) return;
    final end = await showTimePicker(
      context: context,
      helpText: 'Fim do período',
      initialTime: TimeOfDay(
        hour: (existing.$2 ~/ 60) % 24,
        minute: existing.$2 % 60,
      ),
    );
    if (end == null) return;
    final s = start.hour * 60 + start.minute;
    var e = end.hour * 60 + end.minute;
    if (e <= s) e += 1440;
    setState(() {
      if (index < day.intervals.length) {
        day.intervals[index] = (s, e);
      } else {
        day.intervals.add((s, e));
      }
      day.intervals.sort((a, b) => a.$1.compareTo(b.$1));
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final body = {'name': _name.text.trim(), 'definition': _current.toJson()};
    final api = ref.read(apiProvider);
    final r = await runAction(
      context,
      () => widget.scheduleId == null
          ? api.post('/schedules', body)
          : api.put('/schedules/${widget.scheduleId}', body),
      success: 'Escala salva',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) {
      ref.invalidate(schedulesProvider);
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final s = _base;
    final weekly = s.type == ScheduleType.weekly;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.scheduleId == null ? 'Nova escala' : 'Editar escala',
        ),
        actions: [
          if (widget.scheduleId != null)
            IconButton(
              tooltip: 'Excluir',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirm(
                  context,
                  'Excluir escala',
                  'Deseja excluir esta escala?',
                  destructive: true,
                )) {
                  return;
                }
                if (!context.mounted) return;
                final r = await runAction(
                  context,
                  () => ref
                      .read(apiProvider)
                      .delete('/schedules/${widget.scheduleId}'),
                );
                if (r != null || context.mounted) {
                  ref.invalidate(schedulesProvider);
                  if (context.mounted && r != null) context.pop();
                }
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Salvar'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Constrained(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Nome da escala',
                  ),
                ),
                const SectionTitle('Modelos prontos'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (k, l) in const [
                      ('44h', 'Comercial 44h'),
                      ('40h', 'Comercial 40h'),
                      ('6x1', '6x1'),
                      ('12x36d', '12x36 diurno'),
                      ('12x36n', '12x36 noturno'),
                      ('flex', 'Flexível 8h/dia'),
                    ])
                      ActionChip(label: Text(l), onPressed: () => _preset(k)),
                  ],
                ),
                const SectionTitle('Tipo e regime'),
                SegmentedButton<ScheduleType>(
                  segments: [
                    for (final t in ScheduleType.values)
                      ButtonSegment(value: t, label: Text(t.label)),
                  ],
                  selected: {s.type},
                  onSelectionChanged: (v) => setState(() {
                    final type = v.first;
                    if (type == ScheduleType.weekly && _days.length != 7) {
                      _days = [
                        for (var i = 0; i < 7; i++)
                          i < _days.length
                              ? _days[i]
                              : _DayDraft(false, [], null),
                      ];
                    }
                    _base = _base.copyWith(
                      type: type,
                      cycleAnchor:
                          _base.cycleAnchor ??
                          LocalDate.fromDateTime(DateTime.now()),
                    );
                  }),
                ),
                if (!weekly) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final d = await showDatePicker(
                              context: context,
                              initialDate:
                                  (s.cycleAnchor?.toDateTime() ??
                                          DateTime.now())
                                      .toLocal(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2035),
                            );
                            if (d != null) {
                              setState(
                                () => _base = _base.copyWith(
                                  cycleAnchor: LocalDate(
                                    d.year,
                                    d.month,
                                    d.day,
                                  ),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.event),
                          label: Text(
                            'Início do ciclo (Dia 1): ${s.cycleAnchor?.toBr() ?? '-'}',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text('Dias no ciclo:'),
                      IconButton(
                        onPressed: _days.length > 1
                            ? () => setState(() => _days.removeLast())
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text(
                        '${_days.length}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      IconButton(
                        onPressed: _days.length < 28
                            ? () => setState(
                                () => _days.add(_DayDraft(false, [], null)),
                              )
                            : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<CompensationRegime>(
                  initialValue: s.regime,
                  decoration: const InputDecoration(
                    labelText: 'Regime de compensação',
                  ),
                  items: [
                    for (final r in CompensationRegime.values)
                      DropdownMenuItem(value: r, child: Text(r.label)),
                  ],
                  onChanged: (v) =>
                      setState(() => _base = _base.copyWith(regime: v)),
                ),
                const SectionTitle('Dias e horários'),
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < _days.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _dayRow(
                          i,
                          weekly ? TimeFmt.weekdayNames[i] : 'Dia ${i + 1}',
                        ),
                      ],
                    ],
                  ),
                ),
                const SectionTitle('Regras de cálculo'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _number(
                                'Tolerância por marcação (min)',
                                s.tolerancePerMark,
                                (v) =>
                                    _base = _base.copyWith(tolerancePerMark: v),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _number(
                                'Tolerância diária (min)',
                                s.toleranceDaily,
                                (v) =>
                                    _base = _base.copyWith(toleranceDaily: v),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _number(
                                'Hora extra dia útil (%)',
                                s.overtimeRateWeekday,
                                (v) => _base = _base.copyWith(
                                  overtimeRateWeekday: v,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _number(
                                'Hora extra folga/feriado (%)',
                                s.overtimeRateRestDay,
                                (v) => _base = _base.copyWith(
                                  overtimeRateRestDay: v,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _number(
                                'Interjornada mínima (min)',
                                s.minInterjourney,
                                (v) =>
                                    _base = _base.copyWith(minInterjourney: v),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _number(
                                'Limite diário no banco — híbrido (min)',
                                s.hybridDailyBankLimit,
                                (v) => _base = _base.copyWith(
                                  hybridDailyBankLimit: v,
                                ),
                              ),
                            ),
                          ],
                        ),
                        SwitchListTile(
                          value: s.preAssignedBreak,
                          onChanged: (v) => setState(
                            () => _base = _base.copyWith(preAssignedBreak: v),
                          ),
                          title: const Text('Intervalo pré-assinalado'),
                          subtitle: const Text(
                            'O colaborador marca só entrada e saída; o intervalo é preenchido automaticamente',
                          ),
                        ),
                        SwitchListTile(
                          value: s.nightReduced,
                          onChanged: (v) => setState(
                            () => _base = _base.copyWith(nightReduced: v),
                          ),
                          title: const Text('Hora noturna reduzida (52m30s)'),
                        ),
                        SwitchListTile(
                          value: s.extendNightShift,
                          onChanged: (v) => setState(
                            () => _base = _base.copyWith(extendNightShift: v),
                          ),
                          title: const Text(
                            'Prorrogação da jornada noturna (Súmula 60 TST)',
                          ),
                        ),
                        SwitchListTile(
                          value: s.deductAbsencesFromBank,
                          onChanged: (v) => setState(
                            () => _base = _base.copyWith(
                              deductAbsencesFromBank: v,
                            ),
                          ),
                          title: const Text(
                            'Abater faltas e atrasos do banco de horas',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _number(String label, int value, void Function(int) set) =>
      TextFormField(
        initialValue: '$value',
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null) set(n);
        },
      );

  Widget _dayRow(int i, String label) {
    final d = _days[i];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Switch(
            value: d.work,
            onChanged: (v) => setState(() {
              d.work = v;
              if (v && d.intervals.isEmpty && d.flexible == null) {
                d.intervals = [(480, 720), (780, 1020)];
              }
            }),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: !d.work
                ? const Text(
                    'Folga / DSR',
                    style: TextStyle(color: AppColors.muted),
                  )
                : Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (d.flexible != null)
                        InputChip(
                          label: Text('Flexível ${hm(d.flexible!)}'),
                          onPressed: () async {
                            final v = await promptText(
                              context,
                              'Carga diária (HH:MM)',
                              initial: hm(d.flexible!),
                            );
                            if (v != null) {
                              setState(() => d.flexible = TimeFmt.parseHm(v));
                            }
                          },
                          onDeleted: () => setState(() => d.flexible = null),
                        )
                      else ...[
                        for (var k = 0; k < d.intervals.length; k++)
                          InputChip(
                            label: Text(
                              '${TimeFmt.hm(d.intervals[k].$1)}–${TimeFmt.hm(d.intervals[k].$2)}',
                            ),
                            onPressed: () => _editInterval(d, k),
                            onDeleted: () =>
                                setState(() => d.intervals.removeAt(k)),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.add, size: 16),
                          label: const Text('Período'),
                          onPressed: () => _editInterval(d, d.intervals.length),
                        ),
                        TextButton(
                          onPressed: () => setState(() => d.flexible = 480),
                          child: const Text('Flexível'),
                        ),
                      ],
                    ],
                  ),
          ),
          if (i > 0)
            IconButton(
              tooltip: 'Copiar do dia anterior',
              icon: const Icon(Icons.content_copy, size: 18),
              onPressed: () => setState(() {
                final p = _days[i - 1];
                _days[i] = _DayDraft(p.work, [...p.intervals], p.flexible);
              }),
            ),
        ],
      ),
    );
  }
}
