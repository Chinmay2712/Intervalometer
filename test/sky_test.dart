import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/astro/astronomy.dart';
import 'package:valometer/astro/night_report.dart';
import 'package:valometer/sky/weather_service.dart';

const london = (lat: 51.5074, lon: -0.1278);

Matcher within(DateTime expected, Duration tolerance) => predicate<DateTime?>(
      (t) => t != null && t.difference(expected).abs() <= tolerance,
      'within $tolerance of $expected',
    );

void main() {
  group('sun', () {
    test('London midsummer: sunset/sunrise and no full darkness', () {
      final r = NightReport.build(
        lat: london.lat,
        lon: london.lon,
        windowStart: DateTime.utc(2024, 6, 20, 12),
      );
      // timeanddate.com: sunset 21:21 BST, sunrise 04:43 BST.
      expect(r.sunset, within(DateTime.utc(2024, 6, 20, 20, 21), const Duration(minutes: 3)));
      expect(r.sunrise, within(DateTime.utc(2024, 6, 21, 3, 43), const Duration(minutes: 3)));
      expect(r.astroDusk, isNull);
      expect(r.darkRanges, isEmpty);
      expect(r.summary, startsWith('No full darkness'));
    });

    test('London midwinter: twilight stages in order', () {
      final r = NightReport.build(
        lat: london.lat,
        lon: london.lon,
        windowStart: DateTime.utc(2024, 12, 21, 12),
      );
      // Sunset 15:53 GMT, sunrise 08:06 GMT.
      expect(r.sunset, within(DateTime.utc(2024, 12, 21, 15, 53), const Duration(minutes: 3)));
      expect(r.sunrise, within(DateTime.utc(2024, 12, 22, 8, 6), const Duration(minutes: 3)));
      expect(r.civilDusk!.isAfter(r.sunset!), isTrue);
      expect(r.nauticalDusk!.isAfter(r.civilDusk!), isTrue);
      expect(r.astroDusk!.isAfter(r.nauticalDusk!), isTrue);
      expect(r.astroDawn!.isBefore(r.nauticalDawn!), isTrue);
      expect(r.darkDuration.inHours, greaterThan(10));
    });
  });

  group('moon', () {
    test('full and new moon dates (Jan 2024)', () {
      // Full moon 25 Jan 2024 17:54 UTC, new moon 11 Jan 2024 11:57 UTC.
      expect(nextMoonPhase(0.5, DateTime.utc(2024, 1, 20)),
          within(DateTime.utc(2024, 1, 25, 17, 54), const Duration(minutes: 20)));
      expect(nextMoonPhase(0, DateTime.utc(2024, 1, 1)),
          within(DateTime.utc(2024, 1, 11, 11, 57), const Duration(minutes: 20)));
    });

    test('illumination and phase names', () {
      final full = moonIllumination(DateTime.utc(2024, 1, 25, 18));
      expect(full.fraction, greaterThan(0.98));
      expect(full.name, 'Full moon');
      final newMoon = moonIllumination(DateTime.utc(2024, 1, 11, 12));
      expect(newMoon.fraction, lessThan(0.02));
      final firstQuarter = moonIllumination(DateTime.utc(2024, 1, 18, 3, 53));
      expect(firstQuarter.fraction, closeTo(0.5, 0.05));
      expect(firstQuarter.waxing, isTrue);
    });

    test('moon rises and sets during a midwinter London window', () {
      final r = NightReport.build(lat: london.lat, lon: london.lon, windowStart: DateTime.utc(2024, 12, 21, 12));
      expect(r.moonrise != null || r.moonset != null, isTrue);
    });
  });

  group('Milky Way core', () {
    test('compass points', () {
      expect(compassPoint(0), 'N');
      expect(compassPoint(157), 'SSE');
      expect(compassPoint(359), 'N');
    });

    test('Pune in June: core high in the south during darkness', () {
      // New moon 6 June 2024, so the moon is out of the way too.
      final r = NightReport.build(lat: 18.52, lon: 73.86, windowStart: DateTime.utc(2024, 6, 6, 6, 30));
      expect(r.core.visible, isNotEmpty);
      expect(r.core.best, isNotEmpty);
      // Max possible altitude = 90 − |18.52 + 29.01| ≈ 42.5°.
      expect(r.core.maxPossibleAltitude, closeTo(42.5, 0.1));
      expect(r.core.highestAltitude, closeTo(42.5, 1.0));
      expect(r.core.direction, anyOf('S', 'SSE', 'SSW'));
    });

    test('London in December: core is behind the sun', () {
      final r = NightReport.build(lat: london.lat, lon: london.lon, windowStart: DateTime.utc(2024, 12, 21, 12));
      expect(r.core.visible, isEmpty);
      expect(r.core.highestInDark, isNull);
    });

    test('far north: core never clears the horizon', () {
      final r = NightReport.build(lat: 70, lon: 20, windowStart: DateTime.utc(2024, 8, 1, 12));
      expect(r.core.maxPossibleAltitude, lessThan(0));
      expect(r.core.rise, isNull);
      expect(r.core.visible, isEmpty);
    });
  });

  group('forecast scoring', () {
    WeatherForecast clouds(int percent, DateTime from) => WeatherForecast(
          lat: london.lat,
          lon: london.lon,
          fetchedAt: from,
          hours: [
            for (var i = 0; i < 30; i++)
              HourlyWeather(time: from.add(Duration(hours: i)), cloud: percent, temperature: 5, dewPoint: 0),
          ],
        );

    test('clear, moonless winter night has a long best window', () {
      // 30 Dec 2024 is a new moon.
      final start = DateTime.utc(2024, 12, 30, 12);
      final r = NightReport.build(lat: london.lat, lon: london.lon, windowStart: start, forecast: clouds(0, start));
      expect(r.bestWindow!.duration.inHours, greaterThanOrEqualTo(10));
      expect(r.summary, startsWith('Best window'));
      expect(r.dewRisk, isFalse);
    });

    test('overcast night has no best window', () {
      final start = DateTime.utc(2024, 12, 30, 12);
      final r = NightReport.build(lat: london.lat, lon: london.lon, windowStart: start, forecast: clouds(100, start));
      expect(r.bestWindow, isNull);
      expect(r.summary, startsWith('Cloudy'));
    });

    test('parses Open-Meteo unixtime JSON', () {
      final f = WeatherForecast.parse({
        'latitude': 18.5,
        'longitude': 73.9,
        'hourly': {
          'time': [1730851200, 1730854800],
          'cloud_cover': [10, null],
          'temperature_2m': [12.5, 12.0],
          'dew_point_2m': [11.0, 11.0],
        },
      }, DateTime.utc(2024));
      expect(f.hours, hasLength(1));
      expect(f.hours.first.cloud, 10);
      expect(f.hours.first.dewRisk, isTrue);
      expect(f.at(DateTime.utc(2024, 11, 6, 0, 30))?.cloud, 10);
    });
  });
}
