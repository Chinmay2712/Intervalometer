import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// One forecast hour from Open-Meteo (free, no API key, CC BY 4.0).
class HourlyWeather {
  const HourlyWeather({
    required this.time,
    required this.cloud,
    this.cloudLow,
    this.cloudMid,
    this.cloudHigh,
    this.temperature,
    this.dewPoint,
    this.humidity,
    this.windKmh,
    this.visibilityM,
  });

  final DateTime time; // UTC
  final int cloud; // total cloud cover %
  final int? cloudLow;
  final int? cloudMid;
  final int? cloudHigh;
  final double? temperature; // °C
  final double? dewPoint; // °C
  final int? humidity; // %
  final double? windKmh;
  final double? visibilityM;

  /// Lens fogging is likely when air temperature is close to the dew point.
  bool get dewRisk =>
      temperature != null && dewPoint != null && temperature! - dewPoint! < 2.5;
}

class WeatherForecast {
  const WeatherForecast({
    required this.hours,
    required this.fetchedAt,
    required this.lat,
    required this.lon,
    this.stale = false,
  });

  final List<HourlyWeather> hours;
  final DateTime fetchedAt;
  final double lat;
  final double lon;

  /// True when this is a cached copy because the network request failed.
  final bool stale;

  HourlyWeather? at(DateTime t) {
    for (final h in hours) {
      final diff = t.difference(h.time).inMinutes;
      if (diff >= 0 && diff < 60) return h;
    }
    return null;
  }

  static WeatherForecast parse(Map<String, dynamic> json, DateTime fetchedAt, {bool stale = false}) {
    final hourly = json['hourly'] as Map<String, dynamic>;
    final times = (hourly['time'] as List).cast<num>();
    List<num?> col(String k) => ((hourly[k] as List?) ?? List.filled(times.length, null)).cast<num?>();
    final total = col('cloud_cover');
    final low = col('cloud_cover_low');
    final mid = col('cloud_cover_mid');
    final high = col('cloud_cover_high');
    final temp = col('temperature_2m');
    final dew = col('dew_point_2m');
    final rh = col('relative_humidity_2m');
    final wind = col('wind_speed_10m');
    final vis = col('visibility');
    return WeatherForecast(
      lat: (json['latitude'] as num).toDouble(),
      lon: (json['longitude'] as num).toDouble(),
      fetchedAt: fetchedAt,
      stale: stale,
      hours: [
        for (var i = 0; i < times.length; i++)
          if (total[i] != null)
            HourlyWeather(
              time: DateTime.fromMillisecondsSinceEpoch(times[i].toInt() * 1000, isUtc: true),
              cloud: total[i]!.round(),
              cloudLow: low[i]?.round(),
              cloudMid: mid[i]?.round(),
              cloudHigh: high[i]?.round(),
              temperature: temp[i]?.toDouble(),
              dewPoint: dew[i]?.toDouble(),
              humidity: rh[i]?.round(),
              windKmh: wind[i]?.toDouble(),
              visibilityM: vis[i]?.toDouble(),
            ),
      ],
    );
  }
}

/// Fetches and caches the hourly forecast. Coordinates are rounded to
/// 2 decimals (about 1 km) before they leave the phone.
class WeatherService {
  WeatherService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static const _cacheKey = 'sky.forecast';
  static const _maxAge = Duration(hours: 1);

  static double _round(double v) => (v * 100).round() / 100;

  Future<WeatherForecast> fetch(double lat, double lon, {bool force = false}) async {
    final rLat = _round(lat), rLon = _round(lon);
    final prefs = await SharedPreferences.getInstance();
    final cached = _readCache(prefs, rLat, rLon);
    if (!force && cached != null && DateTime.now().difference(cached.fetchedAt) < _maxAge) {
      return cached;
    }

    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$rLat',
      'longitude': '$rLon',
      'hourly': 'cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,'
          'temperature_2m,dew_point_2m,relative_humidity_2m,wind_speed_10m,visibility',
      'forecast_days': '4',
      'timeformat': 'unixtime',
      'timezone': 'GMT',
    });
    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final now = DateTime.now();
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final forecast = WeatherForecast.parse(json, now);
      await prefs.setString(_cacheKey, jsonEncode({
        'lat': rLat,
        'lon': rLon,
        'fetchedAt': now.millisecondsSinceEpoch,
        'data': json,
      }));
      return forecast;
    } catch (_) {
      if (cached != null) {
        return WeatherForecast(
          hours: cached.hours,
          fetchedAt: cached.fetchedAt,
          lat: cached.lat,
          lon: cached.lon,
          stale: true,
        );
      }
      rethrow;
    }
  }

  WeatherForecast? _readCache(SharedPreferences prefs, double lat, double lon) {
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['lat'] != lat || m['lon'] != lon) return null;
      return WeatherForecast.parse(
        m['data'] as Map<String, dynamic>,
        DateTime.fromMillisecondsSinceEpoch(m['fetchedAt'] as int),
      );
    } catch (_) {
      return null;
    }
  }
}
