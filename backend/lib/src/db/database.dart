import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart';

import 'migrations.dart';

final _log = Logger('db');

typedef Row = Map<String, dynamic>;

/// Executor comum a pool e transação.
abstract class Db {
  Future<List<Row>> query(String sql, [Map<String, Object?> params = const {}]);

  Future<Row?> one(String sql, [Map<String, Object?> params = const {}]) async {
    final rows = await query(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> execute(String sql, [Map<String, Object?> params = const {}]);
}

class _SessionDb extends Db {
  final Session session;
  _SessionDb(this.session);

  @override
  Future<List<Row>> query(String sql, [Map<String, Object?> params = const {}]) async {
    final result = await session.execute(Sql.named(sql), parameters: params);
    return [for (final r in result) r.toColumnMap()];
  }

  @override
  Future<int> execute(String sql, [Map<String, Object?> params = const {}]) async {
    final result = await session.execute(Sql.named(sql), parameters: params);
    return result.affectedRows;
  }
}

/// Acesso ao PostgreSQL com pool de conexões.
class Database extends Db {
  final Pool _pool;

  Database._(this._pool);

  factory Database.connect(String url, {int maxConnections = 10}) {
    final uri = Uri.parse(url);
    final userInfo = uri.userInfo.split(':');
    final ssl = uri.queryParameters['sslmode'];
    // `?host=/cloudsql/PROJETO:REGIAO:INSTANCIA` → socket Unix (Cloud SQL).
    final socketDir = uri.queryParameters['host'];
    final unix = socketDir != null && socketDir.startsWith('/');
    final port = uri.hasPort ? uri.port : 5432;
    final endpoint = Endpoint(
      host: unix ? '$socketDir/.s.PGSQL.$port' : (uri.host.isEmpty ? 'localhost' : uri.host),
      port: port,
      database: uri.pathSegments.isEmpty ? 'pontomax' : uri.pathSegments.first,
      username: userInfo.isNotEmpty ? Uri.decodeComponent(userInfo[0]) : null,
      password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : null,
      isUnixSocket: unix,
    );
    final pool = Pool.withEndpoints(
      [endpoint],
      settings: PoolSettings(
        maxConnectionCount: maxConnections,
        sslMode: switch (ssl) {
          'require' => SslMode.require,
          'verify-full' => SslMode.verifyFull,
          _ => SslMode.disable,
        },
      ),
    );
    return Database._(pool);
  }

  @override
  Future<List<Row>> query(String sql, [Map<String, Object?> params = const {}]) async {
    final result = await _pool.execute(Sql.named(sql), parameters: params);
    return [for (final r in result) r.toColumnMap()];
  }

  @override
  Future<int> execute(String sql, [Map<String, Object?> params = const {}]) async {
    final result = await _pool.execute(Sql.named(sql), parameters: params);
    return result.affectedRows;
  }

  /// Executa [fn] em uma transação (rollback automático em exceção).
  Future<T> tx<T>(Future<T> Function(Db tx) fn) =>
      _pool.runTx((session) => fn(_SessionDb(session)));

  Future<void> migrate() async {
    await _pool.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version integer PRIMARY KEY,
        name text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )''');
    final applied = {
      for (final r in await query('SELECT version FROM schema_migrations')) r['version'] as int,
    };
    for (final (version, name, sql) in migrations) {
      if (applied.contains(version)) continue;
      _log.info('Aplicando migração $version — $name');
      await _pool.runTx((s) async {
        await s.execute(sql, queryMode: QueryMode.simple);
        await s.execute(
          Sql.named('INSERT INTO schema_migrations (version, name) VALUES (@v, @n)'),
          parameters: {'v': version, 'n': name},
        );
      });
    }
  }

  /// Apaga todos os dados (somente testes).
  Future<void> resetForTests() async {
    await _pool.execute('DROP SCHEMA public CASCADE', queryMode: QueryMode.simple);
    await _pool.execute('CREATE SCHEMA public', queryMode: QueryMode.simple);
    await migrate();
  }

  Future<void> close() => _pool.close();
}
