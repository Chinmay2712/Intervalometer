import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the time between shutter presses is measured.
enum RemoteTiming {
  /// Wait for the photo (exposure + saving), then a gap. Shots never overlap.
  gapAfterShot,

  /// A press every N seconds from start to start (even spacing for timelapses).
  fixedInterval,
}

/// What the remote should do. All times in whole seconds.
@immutable
class RemotePlan {
  const RemotePlan({
    this.startDelay = 5,
    this.timing = RemoteTiming.gapAfterShot,
    this.exposure = 30,
    this.saveTime = 10,
    this.gap = 3,
    this.interval = 45,
    this.shots = 10,
  });

  /// Before the first shot only.
  final int startDelay;
  final RemoteTiming timing;

  /// How long the iPhone exposes (e.g. Night mode at 30 s).
  final int exposure;

  /// How long the iPhone needs to process and save afterwards.
  final int saveTime;

  /// Pause after a photo is saved ([RemoteTiming.gapAfterShot]).
  final int gap;

  /// Start-to-start time ([RemoteTiming.fixedInterval]).
  final int interval;

  /// Number of photos; 0 = until stopped.
  final int shots;

  /// Time the iPhone is busy with one photo.
  int get busy => exposure + saveTime;

  /// Seconds from one press to the next.
  int get period => timing == RemoteTiming.fixedInterval ? interval : busy + gap;

  /// The next press would arrive while the iPhone is still busy. On iPhone
  /// that press acts as "Stop" and cuts the running exposure short.
  bool get overlaps => timing == RemoteTiming.fixedInterval && interval < busy;

  /// Whole run, from Start until the last photo is saved. Null = open-ended.
  Duration? get total =>
      shots == 0 ? null : Duration(seconds: startDelay + (shots - 1) * period + busy);

  RemotePlan copyWith({
    int? startDelay,
    RemoteTiming? timing,
    int? exposure,
    int? saveTime,
    int? gap,
    int? interval,
    int? shots,
  }) =>
      RemotePlan(
        startDelay: startDelay ?? this.startDelay,
        timing: timing ?? this.timing,
        exposure: exposure ?? this.exposure,
        saveTime: saveTime ?? this.saveTime,
        gap: gap ?? this.gap,
        interval: interval ?? this.interval,
        shots: shots ?? this.shots,
      );

  Map<String, Object> toJson() => {
        'startDelay': startDelay,
        'timing': timing.name,
        'exposure': exposure,
        'saveTime': saveTime,
        'gap': gap,
        'interval': interval,
        'shots': shots,
      };

  factory RemotePlan.fromJson(Map<String, dynamic> j) {
    const d = RemotePlan();
    int v(String k, int fallback) => (j[k] as num?)?.toInt() ?? fallback;
    return RemotePlan(
      startDelay: v('startDelay', d.startDelay),
      timing: RemoteTiming.values.firstWhere((t) => t.name == j['timing'], orElse: () => d.timing),
      exposure: v('exposure', d.exposure),
      saveTime: v('saveTime', d.saveTime),
      gap: v('gap', d.gap),
      interval: v('interval', d.interval),
      shots: v('shots', d.shots),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemotePlan && mapEquals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);

  static const _prefsKey = 'remote_plan';

  static Future<RemotePlan> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (raw != null) return RemotePlan.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt or missing: defaults.
    }
    return const RemotePlan();
  }

  Future<void> save() async =>
      (await SharedPreferences.getInstance()).setString(_prefsKey, jsonEncode(toJson()));
}

/// Ready-made settings. Exposure must match what the iPhone is set to.
const List<(String, RemotePlan)> kRemotePresets = [
  ('Night mode 30 s', RemotePlan(startDelay: 5, exposure: 30, saveTime: 10, gap: 2, shots: 10)),
  ('Star trails', RemotePlan(startDelay: 5, exposure: 30, saveTime: 10, gap: 0, shots: 120)),
  ('Timelapse', RemotePlan(startDelay: 3, timing: RemoteTiming.fixedInterval, exposure: 1, saveTime: 2, interval: 5, shots: 300)),
  ('Self-timer', RemotePlan(startDelay: 10, exposure: 3, saveTime: 3, gap: 0, shots: 1)),
];

enum RemotePhase { idle, countdown, running, paused, done }

/// Runs a [RemotePlan]: presses the shutter at the right moments.
class RemoteSession extends ChangeNotifier {
  RemoteSession({required this.press, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final Future<bool> Function() press;
  final DateTime Function() _now;

  RemotePlan? _plan;
  RemotePhase _phase = RemotePhase.idle;
  int _taken = 0;
  DateTime? _nextAt;
  DateTime? _lastPressAt;
  DateTime? _startedAt;
  Timer? _timer;

  RemotePlan? get plan => _plan;
  RemotePhase get phase => _phase;
  int get taken => _taken;
  DateTime? get nextAt => _nextAt;
  DateTime? get lastPressAt => _lastPressAt;
  DateTime? get startedAt => _startedAt;
  bool get active => _phase == RemotePhase.countdown || _phase == RemotePhase.running || _phase == RemotePhase.paused;

  void start(RemotePlan plan) {
    _plan = plan;
    _taken = 0;
    _lastPressAt = null;
    _startedAt = _now();
    _phase = RemotePhase.countdown;
    _nextAt = _now().add(Duration(seconds: plan.startDelay));
    _schedule();
  }

  /// After a lost connection: try the missed shot now.
  void resume() {
    if (_phase != RemotePhase.paused) return;
    _phase = _taken == 0 ? RemotePhase.countdown : RemotePhase.running;
    _nextAt = _now();
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _phase = _phase == RemotePhase.done ? RemotePhase.done : RemotePhase.idle;
    _nextAt = null;
    notifyListeners();
  }

  void reset() {
    stop();
    _phase = RemotePhase.idle;
    notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    final wait = _nextAt!.difference(_now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _fire);
    notifyListeners();
  }

  Future<void> _fire() async {
    final plan = _plan!;
    final firedAt = _now();
    final ok = await press();
    if (_phase == RemotePhase.idle) return; // stopped while pressing
    if (!ok) {
      _phase = RemotePhase.paused;
      _nextAt = null;
      notifyListeners();
      return;
    }
    _taken++;
    _lastPressAt = firedAt;
    if (plan.shots > 0 && _taken >= plan.shots) {
      _phase = RemotePhase.done;
      _nextAt = null;
      notifyListeners();
      return;
    }
    _phase = RemotePhase.running;
    _nextAt = firedAt.add(Duration(seconds: plan.period));
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
