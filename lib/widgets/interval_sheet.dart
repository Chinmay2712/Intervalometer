import 'package:flutter/material.dart';

import '../ui/tokens.dart';

import '../intervalometer.dart';
import '../utils/exposure.dart';

/// Bottom sheet for editing the interval sequence. Returns the new settings.
Future<IntervalSettings?> showIntervalSheet(
  BuildContext context, {
  required IntervalSettings initial,
  required double shutterSeconds,
}) {
  return showModalBottomSheet<IntervalSettings>(
    context: context,
    showDragHandle: true,
    // Grows to fit its content (the default caps it at about half the screen).
    isScrollControlled: true,
    builder: (_) => _IntervalSheet(initial: initial, shutterSeconds: shutterSeconds),
  );
}

class _IntervalSheet extends StatefulWidget {
  const _IntervalSheet({required this.initial, required this.shutterSeconds});
  final IntervalSettings initial;
  final double shutterSeconds;

  @override
  State<_IntervalSheet> createState() => _IntervalSheetState();
}

class _IntervalSheetState extends State<_IntervalSheet> {
  late IntervalSettings s = widget.initial;

  static const _intervals = <double>[1, 2, 3, 5, 8, 10, 15, 20, 30, 35, 45, 60, 90, 120, 300, 600];
  static const _delays = <int>[0, 2, 3, 5, 10, 30, 60, 300, 600, 1800, 3600];
  static const _counts = <int>[0, 5, 10, 20, 30, 50, 100, 150, 200, 300, 500, 999];

  @override
  Widget build(BuildContext context) {
    final total = s.estimatedTotal(widget.shutterSeconds);
    final tooShort = s.intervalSeconds < widget.shutterSeconds + 1;
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Intervalometer', style: text.titleLarge),
            const SizedBox(height: 16),
            _PickerRow(
              label: 'Start delay',
              hint: "Wait before the first shot, so tapping the phone doesn't shake it.",
              valueText: s.startDelaySeconds == 0
                  ? 'None'
                  : formatDuration(Duration(seconds: s.startDelaySeconds)),
              onMinus: () => setState(() => s = s.copyWith(
                  startDelaySeconds: _step(_delays, s.startDelaySeconds, -1))),
              onPlus: () => setState(() => s = s.copyWith(
                  startDelaySeconds: _step(_delays, s.startDelaySeconds, 1))),
            ),
            _PickerRow(
              label: 'Interval',
              hint: 'Time from the start of one shot to the start of the next.',
              valueText: formatShutter(s.intervalSeconds),
              onMinus: () => setState(() => s = s.copyWith(
                  intervalSeconds: _step(_intervals, s.intervalSeconds, -1))),
              onPlus: () => setState(() => s = s.copyWith(
                  intervalSeconds: _step(_intervals, s.intervalSeconds, 1))),
            ),
            _PickerRow(
              label: 'Shots',
              hint: 'How many photos to take in total (∞ = until you stop it).',
              valueText: s.shots == 0 ? '∞' : '${s.shots}',
              onMinus: () => setState(() => s = s.copyWith(shots: _step(_counts, s.shots, -1))),
              onPlus: () => setState(() => s = s.copyWith(shots: _step(_counts, s.shots, 1))),
            ),
            const SizedBox(height: 8),
            Text(
              total == null
                  ? 'Runs until you stop it.'
                  : 'Total time ≈ ${formatDuration(total)}',
              style: text.bodyMedium,
            ),
            if (tooShort)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Interval is shorter than the exposure (${formatShutter(widget.shutterSeconds)}) '
                  '+ save time, so shots will run back-to-back.',
                  style: text.bodySmall?.copyWith(color: V.amber),
                ),
              ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, s),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Moves to the previous/next value in [options] relative to [current].
  static T _step<T extends num>(List<T> options, T current, int dir) => dir > 0
      ? options.firstWhere((o) => o > current, orElse: () => options.last)
      : options.lastWhere((o) => o < current, orElse: () => options.first);
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.hint,
    required this.valueText,
    required this.onMinus,
    required this.onPlus,
  });
  final String label;
  final String hint;
  final String valueText;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(hint, style: const TextStyle(fontSize: 12, height: 1.3, color: V.textDim)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(onPressed: onMinus, icon: const Icon(Icons.remove)),
          SizedBox(
            width: 84,
            child: Text(
              valueText,
              textAlign: TextAlign.center,
              style: V.readout(20),
            ),
          ),
          IconButton.filledTonal(onPressed: onPlus, icon: const Icon(Icons.add)),
        ],
      ),
    );
  }
}
