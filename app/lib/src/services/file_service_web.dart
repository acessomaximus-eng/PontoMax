import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';

/// Na web, dispara o download pelo navegador.
Future<String?> saveAndOpen(
  Uint8List bytes,
  String filename,
  String mimeType,
) async {
  final dot = filename.lastIndexOf('.');
  final name = dot > 0 ? filename.substring(0, dot) : filename;
  final ext = dot > 0 ? filename.substring(dot + 1) : '';
  return FileSaver.instance.saveFile(
    name: name,
    bytes: bytes,
    fileExtension: ext,
    mimeType: MimeType.custom,
    customMimeType: mimeType,
  );
}
