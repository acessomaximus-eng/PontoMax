import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class LocationResult {
  final double lat;
  final double lng;
  final double accuracy;
  const LocationResult(this.lat, this.lng, this.accuracy);
}

class LocationException implements Exception {
  final String message;
  const LocationException(this.message);
  @override
  String toString() => message;
}

/// Obtém a localização atual com tratamento de permissões.
class LocationService {
  static bool get supported =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.linux;

  static Future<LocationResult?> current({bool required = false}) async {
    if (!supported) {
      if (required) {
        throw const LocationException(
          'Localização indisponível nesta plataforma.',
        );
      }
      return null;
    }
    try {
      if (!kIsWeb && !await Geolocator.isLocationServiceEnabled()) {
        throw const LocationException('Ative o GPS/localização do aparelho.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const LocationException(
          'Permissão de localização negada. Autorize o acesso nas configurações para registrar o ponto.',
        );
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (pos.isMocked) {
        throw const LocationException(
          'Localização simulada detectada. Desative apps de GPS falso.',
        );
      }
      return LocationResult(pos.latitude, pos.longitude, pos.accuracy);
    } on LocationException {
      if (required) rethrow;
      return null;
    } catch (e) {
      debugPrint('Erro de localização: $e');
      if (required) {
        throw const LocationException(
          'Não foi possível obter sua localização. Tente novamente.',
        );
      }
      return null;
    }
  }
}
