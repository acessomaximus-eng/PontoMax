import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../app.dart';
import '../auth/crypto_utils.dart';
import '../db/database.dart';
import '../http/http_utils.dart';

/// Armazenamento de arquivos (fotos de marcação, atestados, anexos).
///
/// Implementação em disco local; URLs são assinadas (HMAC + expiração) para
/// funcionarem em `<img>` sem cabeçalho de autenticação.
class StorageService {
  final App app;
  StorageService(this.app);

  static const maxBytes = 10 * 1024 * 1024;
  static const allowedTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'application/pdf',
  };

  Future<Row> save({
    Db? db,
    required List<int> bytes,
    required String contentType,
    required String filename,
    String? companyId,
    String? userId,
  }) async {
    if (bytes.isEmpty) throw const ApiError.badRequest('Arquivo vazio');
    if (bytes.length > maxBytes) throw const ApiError.badRequest('Arquivo maior que 10 MB');
    final type = contentType.split(';').first.trim().toLowerCase();
    if (!allowedTypes.contains(type)) {
      throw ApiError.badRequest('Tipo de arquivo não permitido: $type');
    }
    final now = app.now();
    final rel = p.join('${now.year}', now.month.toString().padLeft(2, '0'), '${randomToken(18)}${_ext(type)}');
    final file = File(p.join(app.config.storageDir, rel));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    final row = await (db ?? app.db).one(
      'INSERT INTO files (company_id, uploaded_by, filename, content_type, size, sha256, path) '
      'VALUES (@c, @u, @f, @t, @s, @h, @p) RETURNING *',
      {
        'c': companyId,
        'u': userId,
        'f': filename,
        't': type,
        's': bytes.length,
        'h': sha256.convert(bytes).toString(),
        'p': rel,
      },
    );
    return row!;
  }

  Future<(Row, List<int>)> read(String id) async {
    final row = await app.db.one('SELECT * FROM files WHERE id = @id', {'id': requireUuid(id)});
    if (row == null) throw const ApiError.notFound('Arquivo não encontrado');
    final file = File(p.join(app.config.storageDir, row['path'] as String));
    if (!await file.exists()) throw const ApiError.notFound('Arquivo não encontrado');
    return (row, await file.readAsBytes());
  }

  /// URL assinada válida por [ttl].
  String? signedUrl(String? fileId, {Duration ttl = const Duration(hours: 12)}) {
    if (fileId == null) return null;
    final exp = app.now().add(ttl).millisecondsSinceEpoch ~/ 1000;
    final sig = hmacHex(app.config.jwtSecret, 'file:$fileId:$exp').substring(0, 32);
    return '/api/v1/files/$fileId?exp=$exp&sig=$sig';
  }

  bool verifySignature(String fileId, String? exp, String? sig) {
    if (exp == null || sig == null) return false;
    final e = int.tryParse(exp);
    if (e == null || e < app.now().millisecondsSinceEpoch ~/ 1000) return false;
    final expected = hmacHex(app.config.jwtSecret, 'file:$fileId:$e').substring(0, 32);
    return constantTimeEquals(expected, sig);
  }

  static String _ext(String type) => switch (type) {
        'image/jpeg' => '.jpg',
        'image/png' => '.png',
        'image/webp' => '.webp',
        'image/heic' => '.heic',
        'application/pdf' => '.pdf',
        _ => '',
      };
}
