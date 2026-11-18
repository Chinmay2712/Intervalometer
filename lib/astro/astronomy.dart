/// Low-precision sun and moon positions, accurate to a few arc-minutes for the
/// sun and well under a degree for the moon. That puts rise/set and twilight
/// times within about 1–3 minutes. Everything runs offline.
///
/// Sun: USNO approximate formulae. Moon: Meeus' lunar theory truncated to its
/// largest terms. Angles are radians unless the name says "Deg".
library;

import 'dart:math';

const double _rad = pi / 180;

double julianDay(DateTime t) => t.toUtc().millisecondsSinceEpoch / 86400000.0 + 2440587.5;

/// Days since J2000.0.
double _days(DateTime t) => julianDay(t) - 2451545.0;

/// Right ascension / declination (radians) and distance (km).
class Equatorial {
  const Equatorial(this.ra, this.dec, this.distanceKm, this.eclipticLon);
  final double ra;
  final double dec;
  final double distanceKm;

  /// Ecliptic longitude (radians). New/full moon are defined by it.
  final double eclipticLon;
}

Equatorial sunPosition(DateTime t) {
  final d = _days(t);
  final g = (357.529 + 0.98560028 * d) * _rad;
  final q = 280.459 + 0.98564736 * d;
  final l = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * _rad;
  final e = (23.439 - 0.00000036 * d) * _rad;
  final ra = atan2(cos(e) * sin(l), cos(l));
  final dec = asin(sin(e) * sin(l));
  final au = 1.00014 - 0.01671 * cos(g) - 0.00014 * cos(2 * g);
  return Equatorial(ra, dec, au * 149597870.7, l);
}

Equatorial moonPosition(DateTime t) {
  final d = _days(t);
  final l0 = (218.316 + 13.176396 * d) * _rad; // mean longitude
  final m = (134.963 + 13.064993 * d) * _rad; // mean anomaly
  final f = (93.272 + 13.229350 * d) * _rad; // mean distance from node
  final dd = (297.850 + 12.190749 * d) * _rad; // mean elongation from the sun
  final ms = (357.529 + 0.98560028 * d) * _rad; // sun's mean anomaly
  // Largest periodic terms (Meeus ch. 47): ~10' accuracy.
  final lon = l0 +
      _rad *
          (6.289 * sin(m) + // equation of centre
              1.274 * sin(2 * dd - m) + // evection
              0.658 * sin(2 * dd) + // variation
              0.214 * sin(2 * m) -
              0.186 * sin(ms) - // annual equation
              0.114 * sin(2 * f));
  final lat = _rad *
      (5.128 * sin(f) + 0.280 * sin(m + f) + 0.277 * sin(m - f) + 0.173 * sin(2 * dd - f));
  final dist = 385001 - 20905 * cos(m) - 3699 * cos(2 * dd - m) - 2956 * cos(2 * dd);
  const e = 23.4397 * _rad;
  final ra = atan2(sin(lon) * cos(e) - tan(lat) * sin(e), cos(lon));
  final dec = asin(sin(lat) * cos(e) + cos(lat) * sin(e) * sin(lon));
  return Equatorial(ra, dec, dist, lon);
}

double _localSidereal(DateTime t, double lonDeg) {
  final gmst = 280.46061837 + 360.98564736629 * _days(t);
  return ((gmst + lonDeg) % 360) * _rad;
}

/// Geometric altitude in degrees (no refraction).
double altitudeDeg(Equatorial p, DateTime t, double latDeg, double lonDeg) {
  final h = _localSidereal(t, lonDeg) - p.ra;
  final phi = latDeg * _rad;
  return asin(sin(phi) * sin(p.dec) + cos(phi) * cos(p.dec) * cos(h)) / _rad;
}

/// Azimuth in degrees, measured from north through east (0 = N, 90 = E).
double azimuthDeg(Equatorial p, DateTime t, double latDeg, double lonDeg) {
  final h = _localSidereal(t, lonDeg) - p.ra;
  final phi = latDeg * _rad;
  final az = atan2(sin(h), cos(h) * sin(phi) - tan(p.dec) * cos(phi)) / _rad + 180;
  return az % 360;
}

/// 16-point compass name for an azimuth, e.g. 157° → "SSE".
String compassPoint(double azimuthDeg) {
  const names = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
  return names[((azimuthDeg % 360) / 22.5).round() % 16];
}

/// Galactic centre (Sagittarius A*), the bright core of the Milky Way.
/// J2000 coordinates; precession since then (~0.4°) doesn't matter here.
const Equatorial galacticCentre = Equatorial(266.4168 * _rad, -29.0078 * _rad, 0, 0);

double sunAltitude(DateTime t, double lat, double lon) => altitudeDeg(sunPosition(t), t, lat, lon);
double moonAltitude(DateTime t, double lat, double lon) => altitudeDeg(moonPosition(t), t, lat, lon);
double coreAltitude(DateTime t, double lat, double lon) => altitudeDeg(galacticCentre, t, lat, lon);

/// Altitudes that define each event (centre of the disc, geometric).
abstract final class Horizon {
  /// Sunrise/sunset: refraction (34') + solar semi-diameter (16').
  static const sun = -0.833;
  static const civil = -6.0;
  static const nautical = -12.0;
  static const astronomical = -18.0;

  /// Moonrise/set: horizontal parallax (+57') minus refraction and semi-diameter.
  static const moon = 0.125;

  /// The Milky Way core needs to clear the horizon haze to photograph well.
  static const coreUseful = 10.0;
}

class MoonIllumination {
  const MoonIllumination(this.fraction, this.phase);

  /// Lit part of the disc, 0..1.
  final double fraction;

  /// 0 = new, 0.25 = first quarter, 0.5 = full, 0.75 = last quarter.
  final double phase;

  bool get waxing => phase < 0.5;
  double get ageDays => phase * 29.530588;

  String get name {
    if (phase < 0.02 || phase > 0.98) return 'New moon';
    if (phase < 0.23) return 'Waxing crescent';
    if (phase < 0.27) return 'First quarter';
    if (phase < 0.48) return 'Waxing gibbous';
    if (phase < 0.52) return 'Full moon';
    if (phase < 0.73) return 'Waning gibbous';
    if (phase < 0.77) return 'Last quarter';
    return 'Waning crescent';
  }
}

MoonIllumination moonIllumination(DateTime t) {
  final s = sunPosition(t);
  final m = moonPosition(t);
  final cosPhi = sin(s.dec) * sin(m.dec) + cos(s.dec) * cos(m.dec) * cos(s.ra - m.ra);
  final phi = acos(cosPhi.clamp(-1.0, 1.0)); // sun–moon elongation
  final inc = atan2(s.distanceKm * sin(phi), m.distanceKm - s.distanceKm * cos(phi));
  // Phase = moon's ecliptic longitude minus the sun's, as a fraction of a turn
  // (the astronomical definition of new / quarter / full).
  final phase = ((m.eclipticLon - s.eclipticLon) / (2 * pi)) % 1.0;
  return MoonIllumination((1 + cos(inc)) / 2, phase);
}

/// A moment where [f] crosses zero. [rising] = from negative to positive.
class Crossing {
  const Crossing(this.time, this.rising);
  final DateTime time;
  final bool rising;
}

/// Finds every zero crossing of [f] between [start] and [end] by sampling at
/// [step] and refining each bracket by bisection (to about a second).
List<Crossing> findCrossings(
  double Function(DateTime t) f,
  DateTime start,
  DateTime end, {
  Duration step = const Duration(minutes: 10),
}) {
  final out = <Crossing>[];
  var t0 = start;
  var v0 = f(t0);
  while (t0.isBefore(end)) {
    final t1 = t0.add(step);
    final v1 = f(t1);
    if ((v0 < 0) != (v1 < 0)) {
      var a = t0, b = t1, va = v0;
      for (var i = 0; i < 12; i++) {
        final mid = a.add(b.difference(a) ~/ 2);
        final vm = f(mid);
        if ((va < 0) == (vm < 0)) {
          a = mid;
          va = vm;
        } else {
          b = mid;
        }
      }
      out.add(Crossing(a.add(b.difference(a) ~/ 2), v0 < 0));
    }
    t0 = t1;
    v0 = v1;
  }
  return out;
}

/// Next time the moon reaches [targetPhase] (0 = new, 0.5 = full) after [from].
DateTime nextMoonPhase(double targetPhase, DateTime from) {
  double g(DateTime t) {
    var p = moonIllumination(t).phase - targetPhase;
    if (p > 0.5) p -= 1;
    if (p <= -0.5) p += 1;
    return p;
  }

  final crossings = findCrossings(g, from, from.add(const Duration(days: 31)),
      step: const Duration(hours: 6));
  // The wrap-around at ±0.5 shows up as a falling crossing; the real event rises.
  return crossings.firstWhere((c) => c.rising).time;
}
