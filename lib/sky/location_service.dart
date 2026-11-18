import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SkyLocation {
  const SkyLocation({required this.lat, required this.lon, required this.fromGps});
  final double lat;
  final double lon;
  final bool fromGps;

  String get label {
    final ns = lat >= 0 ? 'N' : 'S';
    final ew = lon >= 0 ? 'E' : 'W';
    return '${lat.abs().toStringAsFixed(2)}° $ns, ${lon.abs().toStringAsFixed(2)}° $ew';
  }
}

class LocationFailure implements Exception {
  LocationFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Approximate (≈1 km) location, remembered for offline use in the field.
class LocationService {
  static const _latKey = 'sky.lat', _lonKey = 'sky.lon', _gpsKey = 'sky.gps';

  Future<SkyLocation?> saved() async {
    final p = await SharedPreferences.getInstance();
    final lat = p.getDouble(_latKey), lon = p.getDouble(_lonKey);
    if (lat == null || lon == null) return null;
    return SkyLocation(lat: lat, lon: lon, fromGps: p.getBool(_gpsKey) ?? false);
  }

  Future<void> save(SkyLocation l) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_latKey, l.lat);
    await p.setDouble(_lonKey, l.lon);
    await p.setBool(_gpsKey, l.fromGps);
  }

  Future<SkyLocation> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationFailure('Location is turned off. Turn it on, or enter coordinates by hand.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw LocationFailure('Location permission denied. Enter coordinates by hand instead.');
    }
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 20),
        ),
      );
    } catch (_) {
      pos = await Geolocator.getLastKnownPosition();
    }
    if (pos == null) throw LocationFailure('Could not get a location fix. Try again outdoors.');
    final loc = SkyLocation(lat: pos.latitude, lon: pos.longitude, fromGps: true);
    await save(loc);
    return loc;
  }
}
