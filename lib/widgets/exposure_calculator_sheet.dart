import 'package:flutter/material.dart';
import 'package:valometer_camera/valometer_camera.dart';

import '../utils/astro_math.dart';
import '../utils/exposure.dart';

/// 500-rule / NPF-rule calculator. Pops with the chosen shutter time (s).
Future<double?> showExposureCalculator(BuildContext context, CameraCapabilities caps) {
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF12151C),
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _CalculatorSheet(caps: caps),
    ),
  );
}

class _CalculatorSheet extends StatefulWidget {
  const _CalculatorSheet({required this.caps});
  final CameraCapabilities caps;

  @override
  State<_CalculatorSheet> createState() => _CalculatorSheetState();
}

class _CalculatorSheetState extends State<_CalculatorSheet> {
  late LensOptics optics = LensOptics.fromCapabilities(widget.caps);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final t500 = rule500(optics.equivFocalMm);
    final tNpf = npfRule(
      fNumber: optics.fNumber,
      pixelPitchUm: optics.pixelPitchUm,
      focalMm: optics.focalMm,
    );
    final maxShutter = widget.caps.maxShutter;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Star-trail calculator', style: text.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Longest shutter time before stars stretch into lines.',
              style: text.bodySmall?.copyWith(color: Colors.white60),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _numField('35mm equiv. (mm)', optics.equivFocalMm,
                    (v) => optics = optics.copyWith(equivFocalMm: v)),
                const SizedBox(width: 12),
                _numField('f-number', optics.fNumber, (v) => optics = optics.copyWith(fNumber: v)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _numField('Real focal (mm)', optics.focalMm, (v) => optics = optics.copyWith(focalMm: v)),
                const SizedBox(width: 12),
                _numField('Pixel pitch (µm)', optics.pixelPitchUm,
                    (v) => optics = optics.copyWith(pixelPitchUm: v)),
              ],
            ),
            if (optics.estimated)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Some values are estimates (this phone doesn\'t report them). '
                  'Look up your camera specs and correct them for a better result.',
                  style: text.bodySmall?.copyWith(color: Colors.orangeAccent),
                ),
              ),
            const SizedBox(height: 20),
            _resultTile(
              title: '500 rule',
              subtitle: 'Quick and forgiving. Fine for phone screens and social media.',
              seconds: t500,
              maxShutter: maxShutter,
            ),
            const SizedBox(height: 10),
            _resultTile(
              title: 'NPF rule',
              subtitle: 'Strict. Gives pin-point stars at 100% zoom.',
              seconds: tNpf,
              maxShutter: maxShutter,
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField(String label, double value, ValueChanged<double> onChanged) {
    return Expanded(
      child: TextFormField(
        initialValue: _trim(value),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        onChanged: (s) {
          final v = double.tryParse(s.replaceAll(',', '.'));
          if (v != null && v > 0) setState(() => onChanged(v));
        },
      ),
    );
  }

  Widget _resultTile({
    required String title,
    required String subtitle,
    required double seconds,
    required double maxShutter,
  }) {
    final usable = seconds.clamp(widget.caps.minShutter, maxShutter);
    final capped = seconds > maxShutter;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$title · ${_secondsLabel(seconds)}', style: text.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: text.bodySmall?.copyWith(color: Colors.white60)),
                if (capped)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'This camera stops at ${formatShutter(maxShutter)}. Shoot '
                      '${framesToStack(seconds, maxShutter)}+ frames and stack them for the same light.',
                      style: text.bodySmall?.copyWith(color: const Color(0xFF7FB2FF)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, usable),
            child: Text('Use ${formatShutter(usable)}'),
          ),
        ],
      ),
    );
  }

  static String _secondsLabel(double s) => '${s.toStringAsFixed(s < 10 ? 1 : 0)} s';

  static String _trim(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
