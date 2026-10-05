import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// Captura de selfie (marcação) e anexos (atestados).
class PhotoService {
  static final _picker = ImagePicker();

  static bool get hasCamera =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static Future<Uint8List?> selfie() async {
    final file = await _picker.pickImage(
      source: hasCamera ? ImageSource.camera : ImageSource.gallery,
      preferredCameraDevice: CameraDevice.front,
      maxWidth: 720,
      maxHeight: 720,
      imageQuality: 70,
    );
    return file?.readAsBytes();
  }

  static Future<(Uint8List, String, String)?> attachment({
    bool camera = false,
  }) async {
    final file = await _picker.pickImage(
      source: camera && hasCamera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 80,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final name = file.name.isEmpty ? 'anexo.jpg' : file.name;
    final lower = name.toLowerCase();
    final type = lower.endsWith('.png')
        ? 'image/png'
        : lower.endsWith('.webp')
        ? 'image/webp'
        : 'image/jpeg';
    return (bytes, type, name);
  }
}
