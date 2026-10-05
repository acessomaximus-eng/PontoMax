import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../api/api_client.dart';
import '../../config.dart';
import '../../services/location_service.dart';
import '../../services/offline_queue.dart';
import '../../services/photo_service.dart';
import '../../services/reminders.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../common/receipt_sheet.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Timer? _ticker;
  bool _busy = false;
  bool _remindersScheduled = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Tenta enviar marcações off-line pendentes.
    Future.microtask(() => ref.read(offlineQueueProvider.notifier).sync());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _scheduleReminders(Map<String, dynamic> today, Me me) async {
    if (_remindersScheduled || !Reminders.supported) return;
    _remindersScheduled = true;
    if (!(me.company?.settings.reminders ?? true)) return;
    final schedule = ScheduleDefinition.fromJson(
      (today['schedule'] as Map).cast(),
    );
    await Reminders.scheduleFrom(schedule, me.offset, ServerClock.nowUtc());
  }

  Future<void> _punch({String? qrToken}) async {
    final me = ref.read(meProvider);
    final settings = me.company?.settings ?? const CompanySettings();
    final mustLocate =
        settings.requireGeofence &&
        !(me.member?.allowAnywhere ?? false) &&
        qrToken == null;
    setState(() => _busy = true);
    try {
      // 1. Localização.
      LocationResult? loc;
      try {
        loc = await LocationService.current(required: mustLocate);
      } on LocationException catch (e) {
        if (mounted) showSnack(context, e.message, error: true);
        return;
      }
      // 2. Selfie.
      Uint8List? photo;
      if (settings.requirePhoto) {
        photo = await PhotoService.selfie();
        if (photo == null) {
          if (mounted) {
            showSnack(
              context,
              'A foto é obrigatória para registrar o ponto.',
              error: true,
            );
          }
          return;
        }
      }
      if (!mounted) return;
      // 3. Confirmação.
      final ok = await _confirmSheet(loc, photo);
      if (ok != true || !mounted) return;
      final instant = ServerClock.nowUtc();
      final api = ref.read(apiProvider);
      final body = <String, dynamic>{
        'source': AppConfig.punchSource,
        'method': qrToken != null ? 'qr' : 'app',
        'lat': loc?.lat,
        'lng': loc?.lng,
        'accuracy': loc?.accuracy,
        'qr_token': qrToken,
        'client_id': newClientId(),
      };
      try {
        if (photo != null) {
          final up = await api.upload(photo, 'image/jpeg', 'selfie.jpg');
          body['photo_file_id'] = up['id'];
        }
        final res = await api.post('/punches', body) as Map;
        ref.invalidate(todayProvider);
        unawaited(ref.read(sessionProvider.notifier).refreshMe());
        if (mounted) {
          await showReceiptSheet(
            context,
            (res['receipt'] as Map).cast(),
            punchId: (res['punch'] as Map)['id'] as String,
          );
        }
      } on ApiException catch (e) {
        if (e.isNetwork && settings.allowOffline) {
          await ref
              .read(offlineQueueProvider.notifier)
              .add(
                PendingPunch(
                  body['client_id'] as String,
                  instant,
                  Map.of(body)..remove('client_id'),
                  photoBase64: photo == null ? null : base64Encode(photo),
                ),
              );
          if (mounted) {
            showSnack(
              context,
              'Sem internet: marcação das ${TimeFmt.clockSeconds(TimeFmt.toWall(instant, me.offset))} salva e será enviada automaticamente.',
            );
          }
        } else {
          if (mounted) showSnack(context, e.message, error: true);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmSheet(LocationResult? loc, Uint8List? photo) {
    final me = ref.read(meProvider);
    return showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Confirmar registro de ponto',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (photo != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        photo,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 16),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        StreamBuilder(
                          stream: Stream.periodic(const Duration(seconds: 1)),
                          builder: (_, _) => Text(
                            TimeFmt.clockSeconds(ServerClock.wall(me.offset)),
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        Text(
                          capitalize(
                            dateLong(
                              LocalDate.fromDateTime(
                                ServerClock.wall(me.offset),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  loc == null ? Icons.location_off_outlined : Icons.location_on,
                  color: loc == null ? AppColors.muted : AppColors.accent,
                ),
                title: Text(
                  loc == null
                      ? 'Localização não informada'
                      : 'Localização capturada',
                ),
                subtitle: loc == null
                    ? null
                    : Text(
                        '${loc.lat.toStringAsFixed(5)}, ${loc.lng.toStringAsFixed(5)} (±${loc.accuracy.round()} m)',
                      ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  minimumSize: const Size.fromHeight(54),
                ),
                onPressed: () => Navigator.pop(c, true),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Confirmar registro'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _scanQr() async {
    final token = await context.push<String>('/escanear');
    if (token != null && mounted) await _punch(qrToken: token);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final today = ref.watch(todayProvider);
    final pending = ref.watch(offlineQueueProvider);
    final wall = ServerClock.wall(me.offset);
    final t = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Olá, ${me.user.name.split(' ').first}!'),
        actions: [
          IconButton(
            tooltip: 'Notificações',
            onPressed: () => context.go('/notificacoes'),
            icon: Badge(
              isLabelVisible: me.unreadNotifications > 0,
              label: Text('${me.unreadNotifications}'),
              child: const Icon(Icons.notifications_none),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(todayProvider);
          await ref.read(offlineQueueProvider.notifier).sync();
          await ref.read(sessionProvider.notifier).refreshMe();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Constrained(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 28,
                        horizontal: 16,
                      ),
                      child: Column(
                        children: [
                          Text(
                            capitalize(dateLong(LocalDate.fromDateTime(wall))),
                            style: t.textTheme.titleSmall?.copyWith(
                              color: AppColors.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            TimeFmt.clockSeconds(wall),
                            style: t.textTheme.displayMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            ServerClock.synced
                                ? 'Horário oficial sincronizado com o servidor'
                                : 'Sincronizando horário...',
                            style: t.textTheme.labelSmall?.copyWith(
                              color: AppColors.muted,
                            ),
                          ),
                          const SizedBox(height: 24),
                          today.when(
                            skipLoadingOnRefresh: true,
                            data: (d) {
                              unawaited(_scheduleReminders(d, me));
                              return _PunchButton(
                                label:
                                    d['next_label'] as String? ?? 'Registrar',
                                working: d['working'] == true,
                                busy: _busy,
                                onPressed: () => _punch(),
                              );
                            },
                            loading: () => const _PunchButton(
                              label: 'Registrar',
                              working: false,
                              busy: true,
                              onPressed: null,
                            ),
                            error: (e, _) => _PunchButton(
                              label: 'Registrar',
                              working: false,
                              busy: _busy,
                              onPressed: () => _punch(),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextButton.icon(
                            onPressed: _busy ? null : _scanQr,
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text(
                              'Registrar lendo o QR Code do quiosque',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (pending.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Card(
                      color: AppColors.warning.withValues(alpha: 0.1),
                      child: ListTile(
                        leading: const Icon(
                          Icons.cloud_upload_outlined,
                          color: AppColors.warning,
                        ),
                        title: Text('${pending.length} marcação(ões) off-line'),
                        subtitle: Text(
                          pending
                              .map(
                                (p) => TimeFmt.clock(
                                  TimeFmt.toWall(p.punchedAt, me.offset),
                                ),
                              )
                              .join(', '),
                        ),
                        trailing: TextButton(
                          onPressed: () =>
                              ref.read(offlineQueueProvider.notifier).sync(),
                          child: const Text('Enviar'),
                        ),
                      ),
                    ),
                  ],
                  AsyncView(
                    value: today,
                    onRetry: () => ref.invalidate(todayProvider),
                    builder: (d) => _TodaySummary(data: d, offset: me.offset),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PunchButton extends StatelessWidget {
  final String label;
  final bool working;
  final bool busy;
  final VoidCallback? onPressed;
  const _PunchButton({
    required this.label,
    required this.working,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = working
        ? const [Color(0xFFF97316), Color(0xFFEA580C)]
        : const [Color(0xFF10B981), Color(0xFF059669)];
    return Semantics(
      button: true,
      label: 'Registrar ponto: $label',
      child: GestureDetector(
        onTap: busy ? null : onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 190,
          height: 190,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: colors.first.withValues(alpha: 0.35),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: busy ? null : onPressed,
              child: Center(
                child: busy
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.fingerprint,
                            color: Colors.white,
                            size: 64,
                          ),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TodaySummary extends StatelessWidget {
  final Map<String, dynamic> data;
  final int offset;
  const _TodaySummary({required this.data, required this.offset});

  @override
  Widget build(BuildContext context) {
    final day = (data['day'] as Map).cast<String, dynamic>();
    final punches = [
      for (final p in data['punches'] as List)
        Punch.fromJson((p as Map).cast()),
    ];
    final valid = punches.where((p) => !p.disregarded).toList();
    var worked = day['worked'] as int? ?? 0;
    // Jornada em curso: soma o tempo desde a última entrada.
    if (data['working'] == true && valid.isNotEmpty) {
      worked += ServerClock.wall(offset).difference(valid.last.wall).inMinutes;
    }
    final expected = day['expected'] as int? ?? 0;
    final next = data['next_expected'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatCard(
                label: 'Trabalhado',
                value: hm(worked),
                icon: Icons.timer_outlined,
                color: AppColors.brand,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatCard(
                label: 'Prevista hoje',
                value: expected == 0 ? 'Folga' : hm(expected),
                icon: Icons.event_available_outlined,
                color: AppColors.info,
                hint: next == null ? null : 'Próxima: $next',
              ),
            ),
          ],
        ),
        const SectionTitle('Marcações de hoje'),
        if (punches.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Nenhuma marcação ainda. Toque no botão para registrar sua entrada.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < punches.length; i++)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          (i.isEven ? AppColors.accent : AppColors.warning)
                              .withValues(alpha: 0.15),
                      child: Icon(
                        i.isEven ? Icons.login : Icons.logout,
                        color: i.isEven ? AppColors.accent : AppColors.warning,
                      ),
                    ),
                    title: Text(
                      TimeFmt.clock(punches[i].wall),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        decoration: punches[i].disregarded
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    subtitle: Text(
                      [
                        i.isEven ? 'Entrada' : 'Saída',
                        punches[i].method.label,
                        if (punches[i].geofenceName != null)
                          punches[i].geofenceName!,
                        if (punches[i].offline) 'off-line',
                        if (punches[i].origin != PunchOrigin.original)
                          punches[i].origin.label,
                      ].join(' • '),
                    ),
                    trailing: punches[i].nsr == null
                        ? null
                        : IconButton(
                            tooltip: 'Comprovante',
                            icon: const Icon(Icons.receipt_long_outlined),
                            onPressed: () =>
                                showReceiptById(context, punches[i].id),
                          ),
                  ),
              ],
            ),
          ),
        if ((day['issues'] as List).isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final i in day['issues'] as List)
                StatusChip(
                  (i as Map)['label'] as String,
                  color: AppColors.warning,
                  icon: Icons.info_outline,
                ),
            ],
          ),
        ],
      ],
    );
  }
}
