import 'dart:io';

import 'package:pontomax_backend/src/config.dart';
import 'package:test/test.dart';

void main() {
  test('sem JWT_SECRET gera um segredo aleatório e persistente', () async {
    final dir = await Directory.systemTemp.createTemp('pmx_cfg');
    addTearDown(() => dir.delete(recursive: true));
    final env = {'STORAGE_DIR': dir.path, 'PONTOMAX_ENV': 'production'};
    final a = Config.fromEnv(env);
    expect(a.jwtSecret.length, 64);
    expect(Config.fromEnv(env).jwtSecret, a.jwtSecret); // sobrevive a reinícios
    expect(Config.fromEnv({...env, 'JWT_SECRET': 'definido-pelo-usuario'}).jwtSecret, 'definido-pelo-usuario');
  });
}
