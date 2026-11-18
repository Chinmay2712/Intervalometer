import 'dart:async';

import 'package:flutter/foundation.dart';

enum SequencePhase { idle, countdown, exposing, waiting, done, stopped, failed }

class IntervalSettings {
  const IntervalSettings({
    this.startDelaySeconds = 5,
    this.intervalSeconds = 10,
    this.shots = 30,
  });

  /// Wait before the first shot (lets the phone stop shaking after you tap).
  final int startDelaySeconds;

  /// Time from the start of one shot to the start of the next.
  final double intervalSeconds;

  /// Number of photos; 0 = keep shooting until stopped.
  final int shots;

  IntervalSettings copyWith({int? startDelaySeconds, double? intervalSeconds, int? shots}) =>
      IntervalSettings(
        startDelaySeconds: startDelaySeconds ?? this.startDelaySeconds,
        intervalSeconds: intervalSeconds ?? this.intervalSeconds,
        shots: shots ?? this.shots,
      );

  /// Estimated wall-clock length of the whole sequence (null when unlimited).
  Duration? estimatedTotal(double shutterSeconds) {
    if (shots == 0) return null;
    final perShot = intervalSeconds > shutterSeconds ? intervalSeconds : shutterSeconds;
    final secs = startDelaySeconds + (shots - 1) * perShot + shutterSeconds;
    return Duration(milliseconds: (secs * 1000).round());
  }
}

/// Runs a timed sequence of shots. [shoot] must complete when the photo is saved.
class Intervalometer extends ChangeNotifier {
  Intervalometer({required this.shoot, this.tick = const Duration(milliseconds: 200)});

  final Future<void> Function() shoot;
  final Duration tick;

  SequencePhase phase = SequencePhase.idle;
  int shotsTaken = 0;
  int failures = 0;
  int? totalShots;

  /// Time left in the current countdown/wait.
  Duration remaining = Duration.zero;
  String? lastError;

  int _run = 0;

  bool get isRunning =>
      phase == SequencePhase.countdown ||
      phase == SequencePhase.exposing ||
      phase == SequencePhase.waiting;

  Future<void> start(IntervalSettings settings) async {
    if (isRunning) return;
    final run = ++_run;
    shotsTaken = 0;
    failures = 0;
    lastError = null;
    totalShots = settings.shots == 0 ? null : settings.shots;

    _setPhase(SequencePhase.countdown);
    final firstShot = DateTime.now().add(Duration(seconds: settings.startDelaySeconds));
    if (!await _waitUntil(firstShot, run)) return;

    var consecutiveFailures = 0;
    while (true) {
      final shotStart = DateTime.now();
      _setPhase(SequencePhase.exposing);
      try {
        await shoot();
        if (run != _run) return;
        shotsTaken++;
        consecutiveFailures = 0;
      } catch (e) {
        if (run != _run) return;
        failures++;
        consecutiveFailures++;
        lastError = e.toString();
        if (consecutiveFailures >= 3) {
          _setPhase(SequencePhase.failed);
          return;
        }
      }

      if (totalShots != null && shotsTaken >= totalShots!) {
        _setPhase(SequencePhase.done);
        return;
      }

      _setPhase(SequencePhase.waiting);
      final next = shotStart.add(Duration(milliseconds: (settings.intervalSeconds * 1000).round()));
      if (!await _waitUntil(next, run)) return;
    }
  }

  void stop() {
    if (!isRunning) return;
    _run++;
    remaining = Duration.zero;
    _setPhase(SequencePhase.stopped);
  }

  void _setPhase(SequencePhase p) {
    phase = p;
    notifyListeners();
  }

  Future<bool> _waitUntil(DateTime target, int run) async {
    while (true) {
      if (run != _run) return false;
      final left = target.difference(DateTime.now());
      if (left <= Duration.zero) {
        remaining = Duration.zero;
        return true;
      }
      remaining = left;
      notifyListeners();
      await Future<void>.delayed(left < tick ? left : tick);
    }
  }

  @override
  void dispose() {
    _run++;
    super.dispose();
  }
}
