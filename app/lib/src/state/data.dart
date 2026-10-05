import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pontomax_core/pontomax_core.dart';

import 'session.dart';

typedef J = Map<String, dynamic>;

/// Período de apuração.
typedef PeriodQuery = ({String? memberId, LocalDate from, LocalDate to});

final todayProvider = FutureProvider.autoDispose<J>((ref) async {
  return ref.watch(apiProvider).getMap('/punches/today');
});

final timesheetProvider = FutureProvider.autoDispose.family<J, PeriodQuery>((
  ref,
  q,
) async {
  return ref
      .watch(apiProvider)
      .getMap(
        '/timesheet',
        query: {
          'member_id': q.memberId,
          'from': q.from.toString(),
          'to': q.to.toString(),
        },
      );
});

final punchesProvider = FutureProvider.autoDispose
    .family<
      List<Punch>,
      ({String? memberId, LocalDate from, LocalDate to, bool outside})
    >((ref, q) async {
      final list = await ref
          .watch(apiProvider)
          .getList(
            '/punches',
            query: {
              'member_id': q.memberId,
              'from': q.from.toString(),
              'to': q.to.toString(),
              if (q.outside) 'outside': 'true',
            },
          );
      return [for (final p in list) Punch.fromJson(p)];
    });

final requestsProvider = FutureProvider.autoDispose
    .family<List<TimeRequest>, ({bool mine, String? status})>((ref, q) async {
      final list = await ref
          .watch(apiProvider)
          .getList(
            '/requests',
            query: {if (q.mine) 'mine': 'true', 'status': q.status},
          );
      return [for (final r in list) TimeRequest.fromJson(r)];
    });

final bankProvider = FutureProvider.autoDispose.family<J, String?>((
  ref,
  memberId,
) async {
  return ref.watch(apiProvider).getMap('/bank', query: {'member_id': memberId});
});

final notesProvider = FutureProvider.autoDispose<List<Note>>((ref) async {
  final list = await ref.watch(apiProvider).getList('/notes');
  return [for (final n in list) Note.fromJson(n)];
});

final notificationsProvider = FutureProvider.autoDispose<List<AppNotification>>(
  (ref) async {
    final list = await ref.watch(apiProvider).getList('/notifications');
    return [for (final n in list) AppNotification.fromJson(n)];
  },
);

final conversationsProvider = FutureProvider.autoDispose<List<Conversation>>((
  ref,
) async {
  final list = await ref.watch(apiProvider).getList('/chat/conversations');
  return [for (final c in list) Conversation.fromJson(c)];
});

final membersProvider = FutureProvider.autoDispose
    .family<List<Member>, ({String status, String? q})>((ref, f) async {
      final list = await ref
          .watch(apiProvider)
          .getList('/members', query: {'status': f.status, 'q': f.q});
      return [for (final m in list) Member.fromJson(m)];
    });

final memberProvider = FutureProvider.autoDispose.family<Member, String>((
  ref,
  id,
) async {
  return Member.fromJson(await ref.watch(apiProvider).getMap('/members/$id'));
});

final departmentsProvider = FutureProvider.autoDispose<List<NamedEntity>>((
  ref,
) async {
  final list = await ref.watch(apiProvider).getList('/departments');
  return [for (final d in list) NamedEntity.fromJson(d)];
});

final positionsProvider = FutureProvider.autoDispose<List<NamedEntity>>((
  ref,
) async {
  final list = await ref.watch(apiProvider).getList('/positions');
  return [for (final d in list) NamedEntity.fromJson(d)];
});

final schedulesProvider = FutureProvider.autoDispose<List<ScheduleEntity>>((
  ref,
) async {
  final list = await ref.watch(apiProvider).getList('/schedules');
  return [for (final s in list) ScheduleEntity.fromJson(s)];
});

final holidaysProvider = FutureProvider.autoDispose
    .family<List<HolidayEntity>, int>((ref, year) async {
      final list = await ref
          .watch(apiProvider)
          .getList('/holidays', query: {'year': year});
      return [for (final h in list) HolidayEntity.fromJson(h)];
    });

final geofencesProvider = FutureProvider.autoDispose<List<GeofenceEntity>>((
  ref,
) async {
  final list = await ref.watch(apiProvider).getList('/geofences');
  return [for (final g in list) GeofenceEntity.fromJson(g)];
});

final devicesProvider = FutureProvider.autoDispose<List<Device>>((ref) async {
  final list = await ref.watch(apiProvider).getList('/devices');
  return [for (final d in list) Device.fromJson(d)];
});

final dashboardProvider = FutureProvider.autoDispose.family<J, LocalDate?>((
  ref,
  date,
) async {
  return ref
      .watch(apiProvider)
      .getMap('/dashboard', query: {'date': date?.toString()});
});

final summaryProvider = FutureProvider.autoDispose
    .family<J, ({LocalDate from, LocalDate to})>((ref, q) async {
      return ref
          .watch(apiProvider)
          .getMap(
            '/reports/summary',
            query: {
              'from': q.from.toString(),
              'to': q.to.toString(),
              'bank': 'true',
            },
          );
    });

final auditProvider = FutureProvider.autoDispose
    .family<List<AuditLog>, String?>((ref, entity) async {
      final list = await ref
          .watch(apiProvider)
          .getList('/audit', query: {'entity': entity, 'limit': 200});
      return [for (final a in list) AuditLog.fromJson(a)];
    });

final absencesProvider = FutureProvider.autoDispose
    .family<List<AbsenceEntity>, String?>((ref, memberId) async {
      final list = await ref
          .watch(apiProvider)
          .getList('/absences', query: {'member_id': memberId});
      return [for (final a in list) AbsenceEntity.fromJson(a)];
    });

final signaturesProvider = FutureProvider.autoDispose<List<TimesheetSignature>>(
  (ref) async {
    final list = await ref.watch(apiProvider).getList('/timesheet/signatures');
    return [for (final s in list) TimesheetSignature.fromJson(s)];
  },
);
