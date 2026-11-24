import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../remote/remote_plan.dart';
import '../remote/remote_trigger.dart';
import '../ui/tokens.dart';

/// Android only: this phone becomes a Bluetooth shutter remote for an
/// iPhone (it sends Volume Up, like a selfie-stick remote) and fires it on a
/// schedule, so the iPhone Camera app can shoot Night-mode sequences.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final _trigger = RemoteTrigger();
  late final _session = RemoteSession(press: _trigger.press);
  Timer? _ticker;

  RemotePlan _plan = const RemotePlan();
  bool _starting = true;
  String? _problem; // why the remote isn't running
  String? _problemCode;
  String? _phoneName;
  List<PairedDevice> _paired = const [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((_) {});
    RemotePlan.load().then((p) {
      if (mounted) setState(() => _plan = p);
    });
    _session.addListener(_onSession);
    _trigger.link.addListener(_onLink);
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_session.active && mounted) setState(() {});
    });
    _startRemote();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _session.removeListener(_onSession);
    _session.dispose();
    _trigger.link.removeListener(_onLink);
    _trigger.dispose();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  void _onLink() {
    if (!mounted) return;
    setState(() {});
    // Lost the iPhone mid-run: the session pauses on the next press. Tell now.
    if (!_trigger.link.value.connected && _session.active) {
      HapticFeedback.heavyImpact();
    }
  }

  RemotePhase? _lastPhase;
  void _onSession() {
    if (!mounted) return;
    final phase = _session.phase;
    if (phase != _lastPhase) {
      if (phase == RemotePhase.done) {
        HapticFeedback.vibrate();
        _toast('Done: ${_session.taken} photo${_session.taken == 1 ? '' : 's'} taken.');
      } else if (phase == RemotePhase.paused) {
        HapticFeedback.vibrate();
      }
      _lastPhase = phase;
    }
    setState(() {});
  }

  Future<void> _startRemote() async {
    setState(() {
      _starting = true;
      _problem = null;
      _problemCode = null;
    });
    try {
      _phoneName = await _trigger.start();
      await _loadPaired();
    } on PlatformException catch (e) {
      _problem = e.message ?? e.code;
      _problemCode = e.code;
    } on MissingPluginException {
      _problem = 'The iPhone remote works on Android only.';
      _problemCode = 'unsupported';
    }
    if (mounted) setState(() => _starting = false);
  }

  Future<void> _loadPaired() async {
    try {
      final list = await _trigger.pairedDevices();
      if (mounted) setState(() => _paired = list);
    } on PlatformException {
      // Not fatal: pairing from the iPhone still works.
    }
  }

  void _setPlan(RemotePlan p) {
    setState(() => _plan = p);
    unawaited(p.save());
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _testShot() async {
    final ok = await _trigger.press();
    if (mounted) _toast(ok ? 'Shutter pressed.' : 'Not connected to the iPhone.');
  }

  Future<void> _pairNew() async {
    try {
      final name = await _trigger.makeDiscoverable();
      if (name != null) _phoneName = name;
    } on PlatformException catch (e) {
      _toast(e.message ?? e.code);
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pair with the iPhone', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              _step('1', 'On the iPhone open Settings › Bluetooth.'),
              _step('2', 'Tap "${_phoneName ?? 'this phone'}" under Other Devices (this phone stays visible for 2 minutes).'),
              _step('3', 'Accept the pairing on both phones. It then shows as connected here.'),
              _step('4', 'Next time the phones reconnect by themselves when this screen is open.'),
            ],
          ),
        ),
      ),
    );
    unawaited(_loadPaired());
  }

  Widget _step(String n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: V.raised, shape: BoxShape.circle),
              child: Text(n, style: V.readout(13, color: V.ion)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );

  Future<void> _connect(PairedDevice d) async {
    try {
      final ok = await _trigger.connect(d.address);
      if (!ok && mounted) _toast('Couldn\'t reach ${d.name}. Is its Bluetooth on?');
    } on PlatformException catch (e) {
      _toast(e.message ?? e.code);
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_session.active) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop the sequence?'),
        content: const Text('Leaving this screen stops the remote.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep running')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Stop')),
        ],
      ),
    );
    return leave == true;
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final locked = _session.active;
    return PopScope(
      canPop: !_session.active,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          _session.reset();
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('iPhone remote')),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    _connectionCard(),
                    const SizedBox(height: 20),
                    _sectionLabel('Presets'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (name, preset) in kRemotePresets)
                          ChoiceChip(
                            label: Text(name),
                            selected: _plan == preset,
                            onSelected: locked ? null : (_) => _setPlan(preset),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _sectionLabel('Timing'),
                    SegmentedButton<RemoteTiming>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: RemoteTiming.gapAfterShot, label: Text('Gap after photo')),
                        ButtonSegment(value: RemoteTiming.fixedInterval, label: Text('Fixed interval')),
                      ],
                      selected: {_plan.timing},
                      onSelectionChanged: locked ? null : (s) => _setPlan(_plan.copyWith(timing: s.first)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _plan.timing == RemoteTiming.gapAfterShot
                          ? 'Waits for each photo to finish exposing and saving, then the gap.'
                          : 'Presses every interval, start to start. Even spacing for timelapses.',
                      style: const TextStyle(color: V.textDim, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    _NumberRow(
                      label: 'Start delay',
                      hint: 'Before the first photo only',
                      value: _plan.startDelay,
                      values: _kSeconds,
                      enabled: !locked,
                      onChanged: (v) => _setPlan(_plan.copyWith(startDelay: v)),
                    ),
                    _NumberRow(
                      label: 'Exposure on iPhone',
                      hint: 'Match the Night mode time you set',
                      value: _plan.exposure,
                      values: _kExposure,
                      enabled: !locked,
                      onChanged: (v) => _setPlan(_plan.copyWith(exposure: v)),
                    ),
                    _NumberRow(
                      label: 'Saving time',
                      hint: 'iPhone processing after the exposure',
                      value: _plan.saveTime,
                      values: _kSeconds,
                      enabled: !locked,
                      onChanged: (v) => _setPlan(_plan.copyWith(saveTime: v)),
                    ),
                    if (_plan.timing == RemoteTiming.gapAfterShot)
                      _NumberRow(
                        label: 'Gap between photos',
                        hint: 'After each photo is saved',
                        value: _plan.gap,
                        values: _kSeconds,
                        enabled: !locked,
                        onChanged: (v) => _setPlan(_plan.copyWith(gap: v)),
                      )
                    else
                      _NumberRow(
                        label: 'Interval',
                        hint: 'From one press to the next',
                        value: _plan.interval,
                        values: _kSeconds.where((s) => s > 0).toList(),
                        enabled: !locked,
                        onChanged: (v) => _setPlan(_plan.copyWith(interval: v)),
                      ),
                    _NumberRow(
                      label: 'Photos',
                      hint: 'How many shots',
                      value: _plan.shots,
                      values: _kShots,
                      enabled: !locked,
                      format: (v) => v == 0 ? '∞' : '$v',
                      onChanged: (v) => _setPlan(_plan.copyWith(shots: v)),
                    ),
                    if (_plan.overlaps) ...[
                      const SizedBox(height: 8),
                      _warning('The interval is shorter than exposure + saving '
                          '(${_plan.busy} s). The next press would stop the running photo early.'),
                    ],
                    const SizedBox(height: 12),
                    _summary(),
                  ],
                ),
              ),
              _runPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: V.textFaint, fontSize: 12, letterSpacing: 1.6, fontWeight: FontWeight.w700)),
      );

  Widget _warning(String text) => HudPanel(
        color: V.raised,
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: V.amber, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(color: V.amber))),
          ],
        ),
      );

  Widget _summary() {
    final total = _plan.total;
    final end = total == null ? null : DateTime.now().add(total);
    return Text(
      [
        'One photo every ${formatSeconds(_plan.period)}',
        if (total != null) 'total ≈ ${formatSeconds(total.inSeconds)}',
        if (end != null) 'done ≈ ${_clock(end)}',
        if (total == null) 'runs until you press Stop',
      ].join(' · '),
      style: V.readout(14, color: V.textDim, weight: FontWeight.w400),
    );
  }

  Widget _connectionCard() {
    final link = _trigger.link.value;
    final Color dot;
    final String title;
    String? subtitle;
    if (_starting) {
      dot = V.textFaint;
      title = 'Starting Bluetooth remote…';
    } else if (_problem != null) {
      dot = V.signal;
      title = _problemCode == 'bluetooth_off' ? 'Bluetooth is off' : 'Remote unavailable';
      subtitle = _problem;
    } else if (link.connected) {
      dot = V.aurora;
      title = 'Connected to ${link.name ?? 'iPhone'}';
      subtitle = 'Open the iPhone Camera app, set Night mode, and frame the shot.';
    } else if (link.state == LinkState.connecting) {
      dot = V.amber;
      title = 'Connecting to ${link.name ?? 'iPhone'}…';
    } else {
      dot = V.amber;
      title = 'Not connected';
      subtitle = 'Pair once from the iPhone\'s Bluetooth settings, or pick it below.';
    }

    return HudPanel(
      padding: const EdgeInsets.all(14),
      radius: V.rMedium,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: V.textDim)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_problemCode == 'bluetooth_off')
                FilledButton.icon(
                  onPressed: () async {
                    await _trigger.enableBluetooth();
                    await Future<void>.delayed(const Duration(seconds: 2));
                    if (mounted) await _startRemote();
                  },
                  icon: const Icon(Icons.bluetooth),
                  label: const Text('Turn on Bluetooth'),
                )
              else if (_problem != null && _problemCode != 'unsupported' && _problemCode != 'no_bluetooth')
                FilledButton(onPressed: _startRemote, child: const Text('Try again')),
              if (_problem == null && !_starting && link.connected) ...[
                FilledButton.icon(
                  onPressed: _session.active ? null : _testShot,
                  icon: const Icon(Icons.camera_outlined),
                  label: const Text('Test shot'),
                ),
                OutlinedButton(
                  onPressed: _session.active ? null : _trigger.disconnect,
                  child: const Text('Disconnect'),
                ),
              ],
              if (_problem == null && !_starting && !link.connected) ...[
                FilledButton.icon(
                  onPressed: _pairNew,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Pair new iPhone'),
                ),
                for (final d in _paired)
                  OutlinedButton.icon(
                    onPressed: link.state == LinkState.connecting ? null : () => _connect(d),
                    icon: const Icon(Icons.phone_iphone, size: 18),
                    label: Text(d.name),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _runPanel() {
    final phase = _session.phase;
    final connected = _trigger.link.value.connected;
    final plan = _session.plan ?? _plan;

    Widget body;
    if (phase == RemotePhase.idle) {
      body = SizedBox(
        width: double.infinity,
        height: 56,
        child: FilledButton.icon(
          onPressed: connected && !_plan.overlaps ? () => _session.start(_plan) : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(connected ? 'Start' : 'Connect the iPhone to start'),
        ),
      );
    } else if (phase == RemotePhase.done) {
      body = Row(
        children: [
          const Icon(Icons.check_circle, color: V.aurora),
          const SizedBox(width: 10),
          Expanded(child: Text('Done · ${_session.taken} photo${_session.taken == 1 ? '' : 's'}')),
          FilledButton(onPressed: _session.reset, child: const Text('OK')),
        ],
      );
    } else {
      final now = DateTime.now();
      final next = _session.nextAt;
      final left = next == null ? 0 : (next.difference(now).inMilliseconds / 1000).ceil().clamp(0, 1 << 30);
      final sinceShot = _session.lastPressAt == null ? null : now.difference(_session.lastPressAt!).inSeconds;
      final String status;
      if (phase == RemotePhase.paused) {
        status = 'Paused: the iPhone isn\'t connected';
      } else if (phase == RemotePhase.countdown) {
        status = 'First photo in';
      } else if (sinceShot != null && sinceShot < plan.exposure) {
        status = 'Exposing · next press in';
      } else if (sinceShot != null && sinceShot < plan.busy) {
        status = 'Saving · next press in';
      } else {
        status = 'Next press in';
      }
      final count = plan.shots == 0 ? '${_session.taken}' : '${_session.taken} / ${plan.shots}';
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(status, style: TextStyle(color: phase == RemotePhase.paused ? V.signal : V.textDim)),
                    if (phase != RemotePhase.paused)
                      Text(formatSeconds(left), style: V.readout(40, color: V.ion)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Photos', style: TextStyle(color: V.textDim)),
                  Text(count, style: V.readout(28)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: plan.shots == 0 ? null : _session.taken / plan.shots,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (phase == RemotePhase.paused) ...[
                Expanded(
                  child: FilledButton(
                    onPressed: connected ? _session.resume : null,
                    child: Text(connected ? 'Resume' : 'Waiting for iPhone…'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: V.signal, minimumSize: const Size.fromHeight(48)),
                  onPressed: _session.reset,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Stop'),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: V.surface,
        border: Border(top: BorderSide(color: V.line)),
      ),
      child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: body),
    );
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

const _kSeconds = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 45, 60, 90, 120, 180, 300, 600, 900, 1800, 3600];
const _kExposure = [1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 25, 30];
const _kShots = [0, 1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 120, 150, 200, 250, 300, 400, 500, 750, 1000];

/// "45 s", "2 m 05 s", "1 h 12 m".
String formatSeconds(int s) {
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60} m ${(s % 60).toString().padLeft(2, '0')} s';
  return '${s ~/ 3600} h ${((s % 3600) ~/ 60).toString().padLeft(2, '0')} m';
}

/// −  value  +  row. Steps through [values]; tapping the number lets you
/// type any value.
class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.hint,
    required this.value,
    required this.values,
    required this.onChanged,
    this.enabled = true,
    this.format,
  });

  final String label;
  final String hint;
  final int value;
  final List<int> values;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final String Function(int)? format;

  String _show(int v) => format?.call(v) ?? formatSeconds(v);

  int? _step(int dir) {
    if (dir > 0) {
      for (final v in values) {
        if (v > value) return v;
      }
    } else {
      for (final v in values.reversed) {
        if (v < value) return v;
      }
    }
    return null;
  }

  Future<void> _type(BuildContext context) async {
    final ctrl = TextEditingController(text: '$value');
    final v = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(suffixText: format == null ? 'seconds' : null, helperText: hint),
          onSubmitted: (t) => Navigator.pop(context, int.tryParse(t)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(ctrl.text)), child: const Text('Set')),
        ],
      ),
    );
    if (v != null) onChanged(v.clamp(values.first, 86400));
  }

  @override
  Widget build(BuildContext context) {
    final down = enabled ? _step(-1) : null;
    final up = enabled ? _step(1) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                Text(hint, style: const TextStyle(color: V.textFaint, fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Less $label',
            onPressed: down == null ? null : () => onChanged(down),
            icon: const Icon(Icons.remove),
          ),
          Semantics(
            button: true,
            label: '$label ${_show(value)}. Tap to type.',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(V.rSmall),
              onTap: enabled ? () => _type(context) : null,
              child: Container(
                constraints: const BoxConstraints(minWidth: 84, minHeight: 44),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(_show(value), style: V.readout(18, color: enabled ? V.text : V.textFaint)),
              ),
            ),
          ),
          IconButton(
            tooltip: 'More $label',
            onPressed: up == null ? null : () => onChanged(up),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
