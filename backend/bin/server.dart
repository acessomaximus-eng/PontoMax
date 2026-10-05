import 'dart:io';

import 'package:logging/logging.dart';
import 'package:pontomax_backend/server.dart';
import 'package:pontomax_backend/src/seed.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main(List<String> args) async {
  // Usado pelo HEALTHCHECK do Docker.
  if (args.contains('--healthcheck')) {
    final port = Platform.environment['PORT'] ?? '8080';
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/v1/health'));
      final res = await req.close();
      exit(res.statusCode == 200 ? 0 : 1);
    } catch (_) {
      exit(1);
    }
  }

  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    stdout.writeln('${r.time.toIso8601String()} ${r.level.name} [${r.loggerName}] ${r.message}'
        '${r.error != null ? ' — ${r.error}' : ''}${r.stackTrace != null ? '\n${r.stackTrace}' : ''}');
  });

  final config = Config.fromEnv();
  final db = Database.connect(config.databaseUrl);
  await db.migrate();
  final app = App(config, db);
  if (config.seedDemo || args.contains('--seed')) {
    await seedDemo(app);
  }

  final server = await io.serve(buildHandler(app), InternetAddress.anyIPv4, config.port);
  server.autoCompress = true;
  Logger('server').info('PontoMax API ouvindo em http://${server.address.host}:${server.port}');

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close(force: true);
    await db.close();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await server.close(force: true);
      await db.close();
      exit(0);
    });
  }
}
