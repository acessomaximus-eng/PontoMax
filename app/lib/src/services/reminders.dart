import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Lembretes de marcação de ponto (notificações locais agendadas a partir
/// da escala do colaborador).
class Reminders {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static const _kEnabled = 'pontomax.reminders.enabled';
  static const _kMinutes = 'pontomax.reminders.minutes';

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static Future<void> init() async {
    if (!supported || _initialized) return;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
        ),
      );
      _initialized = true;
    } catch (e) {
      debugPrint('Lembretes indisponíveis: $e');
    }
  }

  static Future<bool> enabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? true;
  }

  static Future<int> minutesBefore() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kMinutes) ?? 5;
  }

  static Future<void> configure({
    required bool enabled,
    required int minutesBefore,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    await prefs.setInt(_kMinutes, minutesBefore);
    if (!enabled) await cancelAll();
  }

  static Future<bool> requestPermission() async {
    if (!supported) return false;
    await init();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    return await ios?.requestPermissions(alert: true, sound: true) ?? false;
  }

  static Future<void> cancelAll() async {
    if (!supported || !_initialized) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  /// Agenda os lembretes dos próximos 7 dias com base na escala.
  static Future<int> scheduleFrom(
    ScheduleDefinition schedule,
    int offsetMinutes,
    DateTime nowUtc,
  ) async {
    if (!supported) return 0;
    await init();
    if (!_initialized || !await enabled()) return 0;
    await cancelAll();
    final before = await minutesBefore();
    final today = LocalDate.fromDateTime(TimeFmt.toWall(nowUtc, offsetMinutes));
    var id = 1000;
    var count = 0;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'punch_reminders',
        'Lembretes de ponto',
        channelDescription: 'Avisos para registrar entrada, intervalo e saída',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );
    for (var i = 0; i < 7; i++) {
      final day = today.addDays(i);
      final t = schedule.templateFor(day);
      if (!t.hasFixedTimes) continue;
      for (var k = 0; k < t.intervals.length; k++) {
        final iv = t.intervals[k];
        final last = k == t.intervals.length - 1;
        for (final (minute, label) in [
          (iv.start, k == 0 ? 'entrada' : 'retorno do intervalo'),
          (iv.end, last ? 'saída' : 'saída para o intervalo'),
        ]) {
          final wall = day.toDateTime().add(Duration(minutes: minute - before));
          final utc = TimeFmt.fromWall(wall, offsetMinutes);
          if (!utc.isAfter(nowUtc)) continue;
          try {
            await _plugin.zonedSchedule(
              id: id++,
              scheduledDate: tz.TZDateTime.from(utc, tz.UTC),
              notificationDetails: details,
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              title: 'Hora de registrar o ponto',
              body: 'Não esqueça da $label às ${TimeFmt.hm(minute)}.',
            );
            count++;
          } catch (e) {
            debugPrint('Falha ao agendar lembrete: $e');
            return count;
          }
        }
      }
    }
    return count;
  }

  static Future<void> showNow(String title, String body) async {
    if (!supported) return;
    await init();
    if (!_initialized) return;
    try {
      await _plugin.show(
        id: 1,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'general',
            'Geral',
            importance: Importance.defaultImportance,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}
