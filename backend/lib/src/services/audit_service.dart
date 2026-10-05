import '../app.dart';
import '../db/database.dart';

/// Trilha de auditoria de todas as alterações relevantes.
class AuditService {
  final App app;
  AuditService(this.app);

  Future<void> log({
    Db? db,
    required String? companyId,
    required String? userId,
    required String action,
    required String entity,
    String? entityId,
    Map<String, Object?> data = const {},
    String? ip,
  }) async {
    await (db ?? app.db).execute(
      'INSERT INTO audit_logs (company_id, user_id, action, entity, entity_id, data, ip) '
      'VALUES (@c, @u, @a, @e, @eid, @d, @ip)',
      {
        'c': companyId,
        'u': userId,
        'a': action,
        'e': entity,
        'eid': entityId,
        'd': _clean(data),
        'ip': ip,
      },
    );
  }

  static Map<String, Object?> _clean(Map<String, Object?> data) => {
        for (final e in data.entries)
          if (!const {'password', 'password_hash', 'pin', 'pin_hash', 'token'}.contains(e.key))
            e.key: e.value is DateTime ? (e.value as DateTime).toIso8601String() : e.value,
      };
}
