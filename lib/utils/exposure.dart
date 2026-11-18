/// Standard photographic stops and formatting helpers.
library;

const List<double> kShutterStops = [
  1 / 8000, 1 / 4000, 1 / 2000, 1 / 1000, 1 / 500, 1 / 250, 1 / 125,
  1 / 60, 1 / 30, 1 / 15, 1 / 8, 1 / 4, 1 / 2,
  1, 2, 4, 6, 8, 10, 13, 15, 20, 25, 30,
];

const List<double> kIsoStops = [
  25, 32, 50, 64, 100, 125, 200, 250, 400, 500, 800, 1000,
  1600, 2000, 3200, 4000, 6400, 8000, 12800, 25600,
];

/// The stops that fit inside [min]..[max], always including both ends so the
/// full hardware range is reachable.
List<double> stopsWithin(List<double> stops, double min, double max) {
  final result = stops.where((s) => s >= min * 1.001 && s <= max * 0.999).toList();
  result.insert(0, min);
  result.add(max);
  return result;
}

/// Index of the stop closest to [value].
int nearestIndex(List<double> stops, double value) {
  var best = 0;
  for (var i = 1; i < stops.length; i++) {
    if ((stops[i] - value).abs() < (stops[best] - value).abs()) best = i;
  }
  return best;
}

/// 1/250, 1/4, 1", 2.5", 30"
String formatShutter(double seconds) {
  if (seconds >= 0.95) {
    final rounded = seconds.roundToDouble();
    return (seconds - rounded).abs() < 0.05
        ? '${rounded.toInt()}"'
        : '${seconds.toStringAsFixed(1)}"';
  }
  return '1/${(1 / seconds).round()}';
}

String formatIso(double iso) => iso.round().toString();

/// 1:02:03 or 4:05
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
