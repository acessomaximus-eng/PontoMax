import 'dart:io';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Salva o arquivo e o abre com o aplicativo padrão do sistema.
Future<String?> saveAndOpen(
  Uint8List bytes,
  String filename,
  String mimeType,
) async {
  final dot = filename.lastIndexOf('.');
  final name = dot > 0 ? filename.substring(0, dot) : filename;
  final ext = dot > 0 ? filename.substring(dot + 1) : '';
  String path;
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    path = file.path;
  } else {
    path = await FileSaver.instance.saveFile(
      name: name,
      bytes: bytes,
      fileExtension: ext,
      mimeType: MimeType.custom,
      customMimeType: mimeType,
    );
  }
  try {
    await OpenFilex.open(path, type: mimeType);
  } catch (e) {
    debugPrint('Não foi possível abrir $path: $e');
  }
  return path;
}
