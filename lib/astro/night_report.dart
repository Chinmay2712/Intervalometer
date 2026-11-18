import 'dart:math';

import '../sky/weather_service.dart';
import 'astronomy.dart';

class TimeRange {
  const TimeRange(this.start, this.end);
  final DateTime start;
  final DateTime end;
  Duration get duration => end.difference(start);
}

typedef _Sample = ({DateTime t, double sun, double moon, double core});

enum SkyQuality { excellent, good, fair, poor }

/// When and where the Milky Way's bright core (galactic centre) can be shot.
class MilkyWayCore {
  const MilkyWayCore({
    required this.rise,
    required this.set,
    required this.visible,
    required this.best,
    required this.highestInDark,
    required this.highestAltitude,
    required this.highestAzimuth,
    required this.maxPossibleAltitude,
  });

  /// Core crosses the horizon (may be null if it stays up or down all window).
  final DateTime? rise;
  final DateTime? set;

  /// Full darkness with the core at least [Horizon.coreUseful]° up.
  final List<TimeRange> visible;

  /// [visible] and the moon below the horizon: the ideal time.
  final List<TimeRange> best;

  /// Highest point of the core during full darkness (null if never dark+up).
  final DateTime? highestInDark;
  final double? highestAltitude;
  final double? highestAzimuth;

  /// Highest the core can ever get at this latitude.
  final double maxPossibleAltitude;

  Duration get visibleDuration => visible.fold(Duration.zero, (a, r) => a + r.duration);
  Duration get bestDuration => best.fold(Duration.zero, (a, r) => a + r.duration);

  /// Direction of the core at the start of its first best (or visible) window.
  String? get direction => highestAzimuth == null ? null : compassPoint(highestAzimuth!);
}

/// Shooting conditions for one forecast hour.
class NightHour {
  const NightHour({
    required this.time,
    required this.sunAltitude,
    required this.moonAltitude,
    required this.moonFraction,
    required this.weather,
  });

  final DateTime time; // UTC, start of the hour
  final double sunAltitude;
  final double moonAltitude;
  final double moonFraction;
  final HourlyWeather? weather;

  /// 1 in full astronomical darkness, falling to 0 at sunset.
  double get darkness {
    if (sunAltitude <= Horizon.astronomical) return 1;
    if (sunAltitude >= Horizon.civil) return 0;
    return (Horizon.civil - sunAltitude) / (Horizon.civil - Horizon.astronomical) * 0.6;
  }

  /// How much moonlight washes out the sky, 0..1.
  double get moonGlare {
    if (moonAltitude <= 0) return 0;
    return moonFraction * min(1.0, moonAltitude / 20 + 0.3);
  }

  /// 0..1: darkness × clear sky × moon penalty. Null without weather.
  double? get score {
    final w = weather;
    if (w == null) return null;
    return darkness * (1 - w.cloud / 100) * (1 - 0.7 * moonGlare);
  }

  SkyQuality? get quality {
    final s = score;
    if (s == null) return null;
    if (s >= 0.75) return SkyQuality.excellent;
    if (s >= 0.5) return SkyQuality.good;
    if (s >= 0.25) return SkyQuality.fair;
    return SkyQuality.poor;
  }
}

/// Everything about one night at one place: twilight, moon and (when
/// available) the hourly cloud forecast.
class NightReport {
  NightReport._({
    required this.windowStart,
    required this.windowEnd,
    required this.lat,
    required this.lon,
    required this.sunset,
    required this.sunrise,
    required this.civilDusk,
    required this.civilDawn,
    required this.nauticalDusk,
    required this.nauticalDawn,
    required this.astroDusk,
    required this.astroDawn,
    required this.moonrise,
    required this.moonset,
    required this.moon,
    required this.nextNewMoon,
    required this.nextFullMoon,
    required this.darkRanges,
    required this.moonFreeDarkRanges,
    required this.hours,
    required this.core,
  });

  /// Noon to noon, so the whole night sits inside one report.
  final DateTime windowStart;
  final DateTime windowEnd;
  final double lat;
  final double lon;

  final DateTime? sunset;
  final DateTime? sunrise;
  final DateTime? civilDusk;
  final DateTime? civilDawn;
  final DateTime? nauticalDusk;
  final DateTime? nauticalDawn;

  /// Start/end of full darkness. Null when the sun never gets 18° below the
  /// horizon (summer at high latitudes).
  final DateTime? astroDusk;
  final DateTime? astroDawn;

  final DateTime? moonrise;
  final DateTime? moonset;

  /// Moon at the middle of the night.
  final MoonIllumination moon;
  final DateTime nextNewMoon;
  final DateTime nextFullMoon;

  /// Periods of full astronomical darkness.
  final List<TimeRange> darkRanges;

  /// Full darkness with the moon below the horizon: the best astro time.
  final List<TimeRange> moonFreeDarkRanges;

  /// Milky Way core visibility for this night.
  final MilkyWayCore core;

  /// Hourly conditions from sunset to sunrise ([NightHour.weather] is null
  /// without a forecast).
  final List<NightHour> hours;

  Duration get darkDuration => darkRanges.fold(Duration.zero, (a, r) => a + r.duration);
  Duration get moonFreeDarkDuration => moonFreeDarkRanges.fold(Duration.zero, (a, r) => a + r.duration);

  bool get hasForecast => hours.any((h) => h.weather != null);
  bool get dewRisk => hours.any((h) => h.darkness > 0.5 && (h.weather?.dewRisk ?? false));

  /// Longest run of hours rated good or better.
  TimeRange? get bestWindow {
    TimeRange? best;
    DateTime? runStart;
    DateTime? runEnd;
    for (final h in hours) {
      final ok = (h.score ?? 0) >= 0.5;
      if (ok) {
        runStart ??= h.time;
        runEnd = h.time.add(const Duration(hours: 1));
      }
      if ((!ok || h == hours.last) && runStart != null) {
        final r = TimeRange(runStart, runEnd!);
        if (best == null || r.duration > best.duration) best = r;
        runStart = null;
      }
    }
    return best;
  }

  /// One-line verdict for the night.
  String get summary {
    if (darkRanges.isEmpty) return 'No full darkness tonight: the sun stays above −18°.';
    if (!hasForecast) {
      return moonFreeDarkRanges.isEmpty
          ? 'Moon is up through the dark hours (${(moon.fraction * 100).round()}% lit).'
          : 'Moon-free darkness: ${_hm(moonFreeDarkDuration)}. No cloud forecast.';
    }
    final w = bestWindow;
    if (w == null) {
      final avgCloud = hours.where((h) => h.darkness > 0.5 && h.weather != null).map((h) => h.weather!.cloud);
      final mean = avgCloud.isEmpty ? 0 : avgCloud.reduce((a, b) => a + b) / avgCloud.length;
      return mean > 60 ? 'Cloudy night: poor for astrophotography.' : 'Bright moon or cloud: fair at best.';
    }
    return 'Best window: ${_hm(w.duration)} of good sky.';
  }

  static String _hm(Duration d) => '${d.inHours}h ${d.inMinutes.remainder(60).toString().padLeft(2, '0')}m';

  /// [windowStart] should be local noon of the evening's date (converted to
  /// UTC is fine). The report covers the following 24 hours.
  static NightReport build({
    required double lat,
    required double lon,
    required DateTime windowStart,
    WeatherForecast? forecast,
  }) {
    final start = windowStart.toUtc();
    final end = start.add(const Duration(hours: 24));

    ({DateTime? down, DateTime? up}) sunEvents(double h0) {
      final c = findCrossings((t) => sunAltitude(t, lat, lon) - h0, start, end);
      final down = c.where((x) => !x.rising).firstOrNull?.time;
      final up = c.where((x) => x.rising && (down == null || x.time.isAfter(down))).firstOrNull?.time;
      return (down: down, up: up);
    }

    final sun = sunEvents(Horizon.sun);
    final civil = sunEvents(Horizon.civil);
    final nautical = sunEvents(Horizon.nautical);
    final astro = sunEvents(Horizon.astronomical);

    final moonCross = findCrossings((t) => moonAltitude(t, lat, lon) - Horizon.moon, start, end);
    final moonrise = moonCross.where((c) => c.rising).firstOrNull?.time;
    final moonset = moonCross.where((c) => !c.rising).firstOrNull?.time;

    // 5-minute grid of sun, moon and Milky Way core altitudes.
    const step = Duration(minutes: 5);
    final samples = <_Sample>[
      for (var t = start; !t.isAfter(end); t = t.add(step))
        (t: t, sun: sunAltitude(t, lat, lon), moon: moonAltitude(t, lat, lon), core: coreAltitude(t, lat, lon)),
    ];
    List<TimeRange> ranges(bool Function(_Sample s) test) {
      final out = <TimeRange>[];
      DateTime? from;
      for (var i = 0; i < samples.length; i++) {
        final on = test(samples[i]);
        if (on) from ??= samples[i].t;
        if ((!on || i == samples.length - 1) && from != null) {
          out.add(TimeRange(from, samples[i].t));
          from = null;
        }
      }
      return out;
    }

    bool isDark(_Sample s) => s.sun <= Horizon.astronomical;
    bool moonDown(_Sample s) => s.moon <= Horizon.moon;
    bool coreUp(_Sample s) => s.core >= Horizon.coreUseful;

    final dark = ranges(isDark);
    final moonFree = ranges((s) => isDark(s) && moonDown(s));

    // Milky Way core.
    final coreCross = findCrossings((t) => coreAltitude(t, lat, lon), start, end);
    final darkCore = samples.where((s) => isDark(s) && coreUp(s)).toList();
    final peak = darkCore.isEmpty ? null : darkCore.reduce((a, b) => a.core >= b.core ? a : b);
    final core = MilkyWayCore(
      rise: coreCross.where((c) => c.rising).firstOrNull?.time,
      set: coreCross.where((c) => !c.rising).firstOrNull?.time,
      visible: ranges((s) => isDark(s) && coreUp(s)),
      best: ranges((s) => isDark(s) && coreUp(s) && moonDown(s)),
      highestInDark: peak?.t,
      highestAltitude: peak?.core,
      highestAzimuth: peak == null ? null : azimuthDeg(galacticCentre, peak.t, lat, lon),
      maxPossibleAltitude: 90 - (lat - (-29.0078)).abs(),
    );

    final middle = astro.down != null && astro.up != null
        ? astro.down!.add(astro.up!.difference(astro.down!) ~/ 2)
        : start.add(const Duration(hours: 12));

    // Hourly rows from the hour before sunset to the hour after sunrise.
    final hours = <NightHour>[];
    final from = (sun.down ?? start.add(const Duration(hours: 6))).subtract(const Duration(hours: 1));
    final to = (sun.up ?? end.subtract(const Duration(hours: 6))).add(const Duration(hours: 1));
    var h = DateTime.utc(from.year, from.month, from.day, from.hour);
    while (h.isBefore(to)) {
      final mid = h.add(const Duration(minutes: 30));
      hours.add(NightHour(
        time: h,
        sunAltitude: sunAltitude(mid, lat, lon),
        moonAltitude: moonAltitude(mid, lat, lon),
        moonFraction: moonIllumination(mid).fraction,
        weather: forecast?.at(h),
      ));
      h = h.add(const Duration(hours: 1));
    }

    return NightReport._(
      windowStart: start,
      windowEnd: end,
      lat: lat,
      lon: lon,
      sunset: sun.down,
      sunrise: sun.up,
      civilDusk: civil.down,
      civilDawn: civil.up,
      nauticalDusk: nautical.down,
      nauticalDawn: nautical.up,
      astroDusk: astro.down,
      astroDawn: astro.up,
      moonrise: moonrise,
      moonset: moonset,
      moon: moonIllumination(middle),
      nextNewMoon: nextMoonPhase(0, start),
      nextFullMoon: nextMoonPhase(0.5, start),
      darkRanges: dark,
      moonFreeDarkRanges: moonFree,
      hours: hours,
      core: core,
    );
  }
}
