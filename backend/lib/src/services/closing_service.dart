import 'package:pontomax_core/pontomax_core.dart';

import '../app.dart';
import '../db/database.dart';
import '../http/http_utils.dart';

/// Fechamento de período: após fechado, o tratamento do ponto (inclusões,
/// desconsiderações, abonos, aprovações e lançamentos no banco) fica
/// bloqueado até a reabertura por um administrador. Marcações originais
/// continuam sendo aceitas (exigência do REP-P).
class ClosingService {
  final App app;
  ClosingService(this.app);

  Future<List<Row>> overlapping(String companyId, LocalDate from, LocalDate to, {Db? db}) =>
      (db ?? app.db).query(
        '''
        SELECT pc.*, u.name AS closed_by_name FROM period_closings pc
        LEFT JOIN members m ON m.id = pc.closed_by LEFT JOIN users u ON u.id = m.user_id
        WHERE pc.company_id = @c AND pc.start_date <= @t AND pc.end_date >= @f
        ORDER BY pc.start_date''',
        {'c': companyId, 'f': from.toString(), 't': to.toString()},
      );

  /// Lança 409 se algum dia de `[from, to]` estiver em período fechado.
  Future<void> ensureOpen(String companyId, LocalDate from, [LocalDate? to, Db? db]) async {
    final rows = await overlapping(companyId, from, to ?? from, db: db);
    if (rows.isEmpty) return;
    final r = rows.first;
    final s = LocalDate.fromDateTime(r['start_date'] as DateTime).toBr();
    final e = LocalDate.fromDateTime(r['end_date'] as DateTime).toBr();
    throw ApiError(409, 'period_closed', 'O período de $s a $e está fechado. Reabra-o para fazer alterações.');
  }

  Map<String, Object?> toJson(Row r) => {
        'id': r['id'],
        'start_date': LocalDate.fromDateTime(r['start_date'] as DateTime).toString(),
        'end_date': LocalDate.fromDateTime(r['end_date'] as DateTime).toString(),
        'closed_by_name': r['closed_by_name'],
        'note': r['note'],
        'created_at': (r['created_at'] as DateTime).toIso8601String(),
      };
}
