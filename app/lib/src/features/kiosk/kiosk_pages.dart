import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_client.dart';
import '../../services/offline_queue.dart';
import '../../services/photo_service.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../auth/auth_pages.dart';
import '../common/qr_scanner_page.dart';

class KioskActivatePage extends ConsumerStatefulWidget {
  const KioskActivatePage({super.key});
  @override
  ConsumerState<KioskActivatePage> createState() => _KioskActivatePageState();
}

class _KioskActivatePageState extends ConsumerState<KioskActivatePage> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Ativar quiosque',
    subtitle:
        'Transforme este aparelho em um relógio de ponto coletivo. '
        'O gestor gera o código em Configurações › Quiosques.',
    children: [
      TextField(
        controller: _code,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(
          fontSize: 24,
          letterSpacing: 6,
          fontWeight: FontWeight.w800,
        ),
        textAlign: TextAlign.center,
        decoration: const InputDecoration(labelText: 'Código de ativação'),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                await runAction(
                  context,
                  () => ref
                      .read(sessionProvider.notifier)
                      .activateKiosk(
                        _code.text.trim(),
                        kIsWeb ? 'web' : defaultTargetPlatform.name,
                      ),
                );
                if (mounted) setState(() => _busy = false);
              },
        child: const Text('Ativar'),
      ),
      TextButton(
        onPressed: () => context.go('/login'),
        child: const Text('Voltar'),
      ),
    ],
  );
}

/// Tela do quiosque: relógio, QR dinâmico e teclado de PIN.
class KioskPage extends ConsumerStatefulWidget {
  const KioskPage({super.key});
  @override
  ConsumerState<KioskPage> createState() => _KioskPageState();
}

class _KioskPageState extends ConsumerState<KioskPage> {
  Timer? _clock;
  Timer? _qrTimer;
  Map<String, dynamic>? _info;
  String? _qr;
  String _identifier = '';
  String _pin = '';
  bool _askPin = false;
  bool _busy = false;
  Map<String, dynamic>? _success;
  String? _error;
  int _offset = -180;
  List<Map<String, dynamic>> _queue = [];
  bool _syncing = false;

  static const _queueKey = 'pontomax.kiosk_queue';

  ApiClient get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
    _load();
    _loadQueue();
  }

  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    if (raw == null || !mounted) return;
    setState(
      () => _queue = [
        for (final e in jsonDecode(raw) as List)
          (e as Map).cast<String, dynamic>(),
      ],
    );
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(_queue));
  }

  /// Envia marcações feitas sem conexão (idempotente por client_id).
  Future<void> _syncQueue() async {
    if (_syncing || _queue.isEmpty) return;
    _syncing = true;
    try {
      for (final item in [..._queue]) {
        final body = Map<String, dynamic>.of(item);
        final photo = body.remove('photo') as String?;
        try {
          if (photo != null) {
            final up = await _api.upload(
              base64Decode(photo),
              'image/jpeg',
              'kiosk.jpg',
              device: true,
            );
            body['photo_file_id'] = up['id'];
          }
          await _api.post('/kiosk/punch', {...body, 'offline': true}, true);
        } on ApiException catch (e) {
          if (e.isNetwork) break; // continua sem conexão
          // Erro definitivo (PIN inválido, colaborador inativo...): descarta.
        }
        _queue.removeWhere((q) => q['client_id'] == item['client_id']);
        await _saveQueue();
        if (mounted) setState(() {});
      }
    } finally {
      _syncing = false;
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    _qrTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sw = Stopwatch()..start();
      final info = await _api.get('/kiosk/me', device: true) as Map;
      sw.stop();
      ServerClock.sync(
        DateTime.parse(info['server_time'] as String),
        sw.elapsed,
      );
      setState(() {
        _info = info.cast();
        _offset =
            (info['company'] as Map)['utc_offset_minutes'] as int? ?? -180;
        _error = null;
      });
      await _refreshQr();
      _qrTimer?.cancel();
      _qrTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _refreshQr();
        _syncQueue();
      });
      unawaited(_syncQueue());
    } on ApiException catch (e) {
      if (e.status == 401) {
        await ref.read(sessionProvider.notifier).deactivateKiosk();
        return;
      }
      setState(() => _error = e.message);
      Future<void>.delayed(
        const Duration(seconds: 10),
        () => mounted ? _load() : null,
      );
    }
  }

  Future<void> _refreshQr() async {
    try {
      final r = await _api.get('/kiosk/qr', device: true) as Map;
      if (mounted) setState(() => _qr = r['token'] as String);
    } catch (_) {}
  }

  void _reset() => setState(() {
    _identifier = '';
    _pin = '';
    _askPin = false;
    _busy = false;
  });

  Future<void> _punch(Map<String, dynamic> identity) async {
    setState(() => _busy = true);
    final clientId = newClientId();
    final instant = ServerClock.nowUtc();
    Uint8List? photo;
    try {
      String? photoId;
      if ((_info?['company'] as Map?)?['require_photo'] == true) {
        photo = await PhotoService.selfie();
        if (photo == null) {
          throw const ApiException(
            422,
            'photo_required',
            'A foto é obrigatória.',
          );
        }
        final up = await _api.upload(
          photo,
          'image/jpeg',
          'kiosk.jpg',
          device: true,
        );
        photoId = up['id'] as String;
      }
      final r = await _api.post('/kiosk/punch', {
        ...identity,
        'client_id': clientId,
        'photo_file_id': ?photoId,
      }, true) as Map;
      setState(() {
        _success = r.cast();
        _reset();
      });
      Future<void>.delayed(
        const Duration(seconds: 6),
        () => mounted ? setState(() => _success = null) : null,
      );
    } on ApiException catch (e) {
      if (e.isNetwork) {
        // Sem internet: guarda com o horário sincronizado e envia depois.
        _queue.add({
          ...identity,
          'client_id': clientId,
          'punched_at': instant.toIso8601String(),
          'photo': ?(photo == null ? null : base64Encode(photo)),
        });
        await _saveQueue();
        if (!mounted) return;
        setState(() {
          _success = {
            'name': 'Registrado sem internet',
            'offline_time': TimeFmt.clock(TimeFmt.toWall(instant, _offset)),
          };
          _reset();
        });
        Future<void>.delayed(
          const Duration(seconds: 6),
          () => mounted ? setState(() => _success = null) : null,
        );
        return;
      }
      if (mounted) {
        showSnack(context, e.message, error: true);
        setState(() {
          _pin = '';
          _busy = false;
        });
      }
    }
  }

  void _key(String k) {
    setState(() {
      if (k == '⌫') {
        if (_askPin) {
          if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
        } else if (_identifier.isNotEmpty) {
          _identifier = _identifier.substring(0, _identifier.length - 1);
        }
      } else if (k == 'OK') {
        if (!_askPin && _identifier.isNotEmpty) {
          _askPin = true;
        } else if (_askPin && _pin.length >= 4) {
          _punch({'identifier': _identifier, 'pin': _pin, 'method': 'pin'});
        }
      } else {
        if (_askPin) {
          if (_pin.length < 6) _pin += k;
        } else if (_identifier.length < 14) {
          _identifier += k;
        }
      }
    });
  }

  Future<void> _badge() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScannerPage(
          title: 'Ler crachá',
          hint: 'Aproxime o QR Code do crachá ou do app',
        ),
      ),
    );
    if (code != null) await _punch({'badge_code': code});
  }

  Future<void> _exit() async {
    final ok = await confirm(
      context,
      'Sair do modo quiosque',
      'O aparelho deixará de funcionar como relógio de ponto e precisará de um novo código de ativação.',
      destructive: true,
      ok: 'Sair',
    );
    if (ok) await ref.read(sessionProvider.notifier).deactivateKiosk();
  }

  @override
  Widget build(BuildContext context) {
    final wall = ServerClock.wall(_offset);
    final company =
        (_info?['company'] as Map?)?['name'] as String? ?? 'PontoMax';
    final device = (_info?['device'] as Map?)?['name'] as String? ?? '';
    final wide = MediaQuery.sizeOf(context).width > 820;

    final clockPanel = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E3A8A), Color(0xFF0E7490)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onLongPress: _exit,
            child: Text(
              company,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            TimeFmt.clockSeconds(wall),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 72,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            capitalize(dateLong(LocalDate.fromDateTime(wall))),
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 28),
          if (_qr != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: QrImageView(data: _qr!, size: wide ? 220 : 160),
            ),
          const SizedBox(height: 12),
          const Text(
            'Escaneie com o app PontoMax para registrar pelo celular',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
          if (_queue.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Chip(
                avatar: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text('${_queue.length} marcação(ões) aguardando envio'),
              ),
            ),
          if (device.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              device,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.amberAccent),
              ),
            ),
        ],
      ),
    );

    final keypad = Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _askPin ? 'Digite seu PIN' : 'Digite sua matrícula ou CPF',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppColors.muted.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  _askPin ? '•' * _pin.length : _identifier,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GridView.count(
                shrinkWrap: true,
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.6,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final k in [
                    '1',
                    '2',
                    '3',
                    '4',
                    '5',
                    '6',
                    '7',
                    '8',
                    '9',
                    '⌫',
                    '0',
                    'OK',
                  ])
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        backgroundColor: k == 'OK' ? AppColors.accent : null,
                        foregroundColor: k == 'OK' ? Colors.white : null,
                        textStyle: const TextStyle(
                          fontFamily: 'NotoSans',
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      onPressed: _busy ? null : () => _key(k),
                      child: k == '⌫'
                          ? const Icon(
                              Icons.backspace_outlined,
                              semanticLabel: 'Apagar',
                            )
                          : Text(k),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (_askPin)
                TextButton(onPressed: _reset, child: const Text('Voltar')),
              OutlinedButton.icon(
                onPressed: _busy ? null : _badge,
                icon: const Icon(Icons.badge_outlined),
                label: const Text('Usar crachá / QR pessoal'),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      body: Stack(
        children: [
          wide
              ? Row(
                  children: [
                    Expanded(child: clockPanel),
                    Expanded(child: keypad),
                  ],
                )
              : ListView(
                  children: [
                    SizedBox(height: 520, child: clockPanel),
                    keypad,
                  ],
                ),
          if (_success != null)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _success = null),
                child: Container(
                  color: AppColors.accent.withValues(alpha: 0.96),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Colors.white,
                        size: 120,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${_success!['name']}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        _success!['punch'] == null
                            ? 'Marcação das ${_success!['offline_time']} guardada; será enviada quando a conexão voltar'
                            : 'Ponto registrado às ${TimeFmt.clock(Punch.fromJson(((_success!['punch']) as Map).cast()).wall)}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_success!['receipt'] != null)
                        Text(
                          'NSR ${(_success!['receipt'] as Map)['nsr']}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
