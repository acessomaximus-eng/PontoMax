import 'dart:math' as math;

class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  bool get isValid => lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;

  /// Distância em metros (fórmula de Haversine).
  double distanceTo(GeoPoint other) {
    const r = 6371000.0;
    final dLat = _rad(other.lat - lat);
    final dLng = _rad(other.lng - lng);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat)) *
            math.cos(_rad(other.lat)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(a)));
  }

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  String toString() => '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
}

/// Perímetro circular permitido para marcação.
class Geofence {
  final String id;
  final String name;
  final GeoPoint center;
  final double radiusMeters;

  const Geofence({
    required this.id,
    required this.name,
    required this.center,
    required this.radiusMeters,
  });

  /// Considera a precisão do GPS: dentro se o círculo de incerteza tocar o
  /// perímetro, limitado a 100 m de folga para evitar fraudes com GPS ruim.
  bool contains(GeoPoint p, {double accuracy = 0}) {
    final slack = accuracy.clamp(0, 100);
    return center.distanceTo(p) <= radiusMeters + slack;
  }
}

class GeofenceMatch {
  final Geofence? geofence;
  final double? distance;
  final bool inside;
  const GeofenceMatch(this.geofence, this.distance, this.inside);
}

abstract final class Geo {
  /// Encontra o perímetro mais próximo e se o ponto está dentro de algum.
  static GeofenceMatch match(List<Geofence> fences, GeoPoint? p,
      {double accuracy = 0}) {
    if (p == null || fences.isEmpty) {
      return const GeofenceMatch(null, null, false);
    }
    Geofence? best;
    double? bestDist;
    for (final f in fences) {
      final d = f.center.distanceTo(p);
      if (f.contains(p, accuracy: accuracy)) {
        return GeofenceMatch(f, d, true);
      }
      if (bestDist == null || d < bestDist) {
        bestDist = d;
        best = f;
      }
    }
    return GeofenceMatch(best, bestDist, false);
  }
}
