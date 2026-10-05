import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../state/session.dart';

/// Marcação pendente de envio (registrada sem conexão).
class PendingPunch {
  final String clientId;
  final DateTime punchedAt;
  final Map<String, dynamic> data;
  final String? photoBase64;
  final String? lastError;

  const PendingPunch(
    this.clientId,
    this.punchedAt,
    this.data, {
    this.photoBase64,
    this.lastError,
  });

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'punched_at': punchedAt.toIso8601String(),
    'data': data,
    'photo': photoBase64,
    'error': lastError,
  };

  factory PendingPunch.fromJson(Map<String, dynamic> j) => PendingPunch(
    j['client_id'] as String,
    DateTime.parse(j['punched_at'] as String),
    (j['data'] as Map).cast(),
    photoBase64: j['photo'] as String?,
    lastError: j['error'] as String?,
  );

  PendingPunch withError(String e) => PendingPunch(
    clientId,
    punchedAt,
    data,
    photoBase64: photoBase64,
    lastError: e,
  );
}

String newClientId() {
  final r = Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final offlineQueueProvider = NotifierProvider<OfflineQueue, List<PendingPunch>>(
  OfflineQueue.new,
);

/// Fila de marcações off-line, persistida localmente e sincronizada com
/// `POST /punches/sync` (idempotente por `client_id`).
class OfflineQueue extends Notifier<List<PendingPunch>> {
  static const _key = 'pontomax.offline_queue';
  bool _syncing = false;

  @override
  List<PendingPunch> build() {
    Future.microtask(_load);
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      state = [
        for (final e in jsonDecode(raw) as List)
          PendingPunch.fromJson((e as Map).cast()),
      ];
    } catch (_) {
      await prefs.remove(_key);
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final p in state) p.toJson()]),
    );
  }

  Future<void> add(PendingPunch p) async {
    state = [...state, p];
    await _save();
  }

  /// Envia as pendências. Retorna quantas foram sincronizadas.
  Future<int> sync() async {
    if (_syncing || state.isEmpty) return 0;
    _syncing = true;
    final api = ref.read(apiProvider);
    var synced = 0;
    try {
      final items = <Map<String, dynamic>>[];
      for (final p in state) {
        String? photoId;
        if (p.photoBase64 != null) {
          final up = await api.upload(
            base64Decode(p.photoBase64!),
            'image/jpeg',
            'selfie.jpg',
          );
          photoId = up['id'] as String;
        }
        items.add({
          ...p.data,
          'client_id': p.clientId,
          'punched_at': p.punchedAt.toIso8601String(),
          'offline': true,
          'photo_file_id': ?photoId,
        });
      }
      final res = await api.post('/punches/sync', {'punches': items}) as Map;
      final results = [
        for (final r in res['results'] as List)
          (r as Map).cast<String, dynamic>(),
      ];
      final remaining = <PendingPunch>[];
      for (final p in state) {
        final r = results.firstWhere(
          (x) => x['client_id'] == p.clientId,
          orElse: () => const {},
        );
        if (r['ok'] == true) {
          synced++;
        } else if (const {
          'invalid_offline_time',
          'conflict',
          'inactive_member',
          'dismissed',
        }.contains(r['code'])) {
          // Erros definitivos: descarta para não travar a fila.
          synced++;
        } else {
          remaining.add(
            p.withError(r['error']?.toString() ?? 'Falha ao sincronizar'),
          );
        }
      }
      state = remaining;
      await _save();
    } on ApiException catch (e) {
      debugPrint('Sincronização adiada: ${e.message}');
    } finally {
      _syncing = false;
    }
    return synced;
  }

  Future<void> discard(String clientId) async {
    state = [
      for (final p in state)
        if (p.clientId != clientId) p,
    ];
    await _save();
  }
}
