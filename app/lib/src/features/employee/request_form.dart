import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../services/photo_service.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

/// Formulário de solicitação (esquecimento, ajuste, atestado, abono, folga, férias).
Future<bool?> showRequestForm(
  BuildContext context, {
  LocalDate? initialDate,
  RequestType? initialType,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: _RequestForm(initialDate: initialDate, initialType: initialType),
    ),
  );
}

class _RequestForm extends ConsumerStatefulWidget {
  final LocalDate? initialDate;
  final RequestType? initialType;
  const _RequestForm({this.initialDate, this.initialType});

  @override
  ConsumerState<_RequestForm> createState() => _RequestFormState();
}

class _RequestFormState extends ConsumerState<_RequestForm> {
  late RequestType _type = widget.initialType ?? RequestType.forgotPunch;
  late LocalDate _date;
  LocalDate? _end;
  final _times = <TimeOfDay>[];
  final _reason = TextEditingController();
  final _hours = TextEditingController();
  (List<int>, String, String)? _attachment;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final me = ref.read(meProvider);
    _date =
        widget.initialDate ??
        LocalDate.fromDateTime(ServerClock.wall(me.offset));
  }

  bool get _needsTimes => _type.createsPunches;
  bool get _allowsRange =>
      _type == RequestType.vacation ||
      _type == RequestType.medicalCertificate ||
      _type == RequestType.bankDayOff;
  bool get _allowsPartial =>
      _type == RequestType.allowance || _type == RequestType.medicalCertificate;

  Future<void> _pickDate({bool end = false}) async {
    final d = await showDatePicker(
      context: context,
      initialDate: (end ? _end ?? _date : _date).toDateTime().toLocal(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      locale: const Locale('pt', 'BR'),
    );
    if (d == null) return;
    setState(() {
      final ld = LocalDate(d.year, d.month, d.day);
      if (end) {
        _end = ld;
      } else {
        _date = ld;
      }
    });
  }

  Future<void> _addTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
    );
    if (t != null) {
      setState(
        () => _times
          ..add(t)
          ..sort(
            (a, b) =>
                (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute),
          ),
      );
    }
  }

  Future<void> _submit() async {
    if (_needsTimes && _times.isEmpty) {
      showSnack(context, 'Adicione ao menos um horário', error: true);
      return;
    }
    if (_reason.text.trim().isEmpty) {
      showSnack(context, 'Descreva a justificativa', error: true);
      return;
    }
    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    final ok = await runAction(context, () async {
      String? attachmentId;
      if (_attachment != null) {
        final up = await api.upload(
          Uint8List.fromList(_attachment!.$1),
          _attachment!.$2,
          _attachment!.$3,
        );
        attachmentId = up['id'] as String;
      }
      int? minutes;
      if (_allowsPartial && _hours.text.trim().isNotEmpty) {
        minutes = TimeFmt.parseHm(
          _hours.text.contains(':') ? _hours.text : '${_hours.text}:00',
        );
      }
      await api.post('/requests', {
        'type': _type.code,
        'date': _date.toString(),
        if (_allowsRange && _end != null) 'end_date': _end.toString(),
        'times': [
          for (final t in _times)
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
        ],
        'minutes': ?minutes,
        'reason': _reason.text.trim(),
        'attachment_file_id': ?attachmentId,
      });
      return true;
    }, success: 'Solicitação enviada ao gestor');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      ref.invalidate(requestsProvider);
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Nova solicitação',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in RequestType.values)
                  ChoiceChip(
                    avatar: Icon(requestTypeIcon(t), size: 18),
                    label: Text(t.label),
                    selected: _type == t,
                    onSelected: (_) => setState(() {
                      _type = t;
                      _end = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(),
                    icon: const Icon(Icons.event),
                    label: Text(
                      _allowsRange ? 'De ${_date.toBr()}' : _date.toBr(),
                    ),
                  ),
                ),
                if (_allowsRange) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickDate(end: true),
                      icon: const Icon(Icons.event_available),
                      label: Text(
                        _end == null ? 'Até (opcional)' : 'Até ${_end!.toBr()}',
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (_needsTimes) ...[
              const SizedBox(height: 16),
              const Text(
                'Horários a incluir',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _times)
                    InputChip(
                      label: Text(t.format(context)),
                      onDeleted: () => setState(() => _times.remove(t)),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Adicionar horário'),
                    onPressed: _addTime,
                  ),
                ],
              ),
            ],
            if (_allowsPartial) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _hours,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(
                  labelText: 'Horas por dia (opcional)',
                  helperText:
                      'Ex.: 02:30 para abono parcial. Em branco = dia inteiro.',
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _reason,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Justificativa'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final a = await PhotoService.attachment(camera: true);
                    if (a != null) setState(() => _attachment = a);
                  },
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Fotografar'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final a = await PhotoService.attachment();
                    if (a != null) setState(() => _attachment = a);
                  },
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Anexar'),
                ),
              ],
            ),
            if (_attachment != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.image_outlined,
                  color: AppColors.accent,
                ),
                title: Text(_attachment!.$3),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _attachment = null),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Text('Enviar solicitação'),
            ),
          ],
        ),
      ),
    );
  }
}
