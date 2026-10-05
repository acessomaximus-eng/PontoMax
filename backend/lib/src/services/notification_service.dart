import '../app.dart';
import '../db/database.dart';

/// Notificações in-app (e gancho para push/e-mail).
class NotificationService {
  final App app;
  NotificationService(this.app);

  Future<void> notify(
    String memberId, {
    Db? db,
    required String title,
    String body = '',
    String type = 'info',
    Map<String, Object?> data = const {},
  }) async {
    await (db ?? app.db).execute(
      'INSERT INTO notifications (member_id, title, body, type, data) VALUES (@m, @t, @b, @ty, @d)',
      {'m': memberId, 't': title, 'b': body, 'ty': type, 'd': data},
    );
    app.events.publish('member:$memberId', 'notification');
  }

  /// Notifica todos os gestores ativos da empresa.
  Future<void> notifyManagers(
    String companyId, {
    Db? db,
    required String title,
    String body = '',
    String type = 'info',
    Map<String, Object?> data = const {},
    String? exceptMemberId,
  }) async {
    final managers = await (db ?? app.db).query(
      "SELECT id FROM members WHERE company_id = @c AND active AND role <> 'employee'",
      {'c': companyId},
    );
    for (final m in managers) {
      if (m['id'] == exceptMemberId) continue;
      await notify(m['id'] as String, db: db, title: title, body: body, type: type, data: data);
    }
  }
}
