import 'package:flutter/material.dart';
import 'package:valometer_camera/valometer_camera.dart';

/// The user's choice of output: one main format, optionally plus a DNG.
class FormatChoice {
  const FormatChoice(this.format, {this.alsoRaw = false});

  final PhotoFormat format;

  /// Also save the DNG next to [format] (ignored for [PhotoFormat.dng]).
  final bool alsoRaw;

  bool get savesRaw => format == PhotoFormat.dng || alsoRaw;

  /// Short label for the camera screen button, e.g. "JPEG", "TIFF+RAW".
  String get label => format == PhotoFormat.dng ? 'RAW' : (alsoRaw ? '${format.label}+RAW' : format.label);

  /// Falls back to what [caps] can actually produce.
  FormatChoice fitTo(CameraCapabilities caps) {
    final f = caps.formats.containsKey(format) ? format : PhotoFormat.jpeg;
    return FormatChoice(f, alsoRaw: alsoRaw && caps.supportsRaw && f != PhotoFormat.dng);
  }
}

String _describe(PhotoFormat f, FormatSupport? s) {
  final what = switch (f) {
    PhotoFormat.jpeg => 'Smallest files, opens everywhere',
    PhotoFormat.heic => 'About half the size of JPEG, same quality',
    PhotoFormat.png => 'Lossless, large files',
    PhotoFormat.tiff => 'Lossless, uncompressed, for editing',
    PhotoFormat.dng => 'Sensor data only, best for editing and stacking in desktop apps',
  };
  final how = switch (s) {
    null => 'Not available on this camera',
    FormatSupport.native => 'Shot directly by the camera',
    FormatSupport.lossless => 'Made from the uncompressed photo',
    FormatSupport.converted => 'Converted from the camera\'s JPEG',
  };
  return '$what\n$how';
}

/// Bottom sheet to pick the photo format. Returns null if dismissed.
Future<FormatChoice?> showFormatSheet(
  BuildContext context, {
  required FormatChoice initial,
  required CameraCapabilities caps,
}) {
  return showModalBottomSheet<FormatChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _FormatSheet(initial: initial, caps: caps),
  );
}

class _FormatSheet extends StatefulWidget {
  const _FormatSheet({required this.initial, required this.caps});
  final FormatChoice initial;
  final CameraCapabilities caps;

  @override
  State<_FormatSheet> createState() => _FormatSheetState();
}

class _FormatSheetState extends State<_FormatSheet> {
  late PhotoFormat _format = widget.initial.format;
  late bool _alsoRaw = widget.initial.alsoRaw;

  @override
  Widget build(BuildContext context) {
    final caps = widget.caps;
    final converted = caps.formats[_format] == FormatSupport.converted ||
        (_alsoRaw && caps.formats[_format] == FormatSupport.lossless);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Photo format', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            RadioGroup<PhotoFormat>(
              groupValue: _format,
              onChanged: (f) => setState(() => _format = f!),
              child: Column(
                children: [
                  for (final f in PhotoFormat.values)
                    RadioListTile<PhotoFormat>(
                      value: f,
                      enabled: caps.formats.containsKey(f),
                      contentPadding: EdgeInsets.zero,
                      title: Text(f == PhotoFormat.dng ? 'RAW only (DNG)' : f.label),
                      subtitle: Text(_describe(f, caps.formats[f])),
                      isThreeLine: true,
                    ),
                ],
              ),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also save RAW (DNG)'),
              subtitle: Text(caps.supportsRaw ? 'Keeps the sensor data next to the photo' : 'This camera can\'t shoot RAW'),
              value: _format == PhotoFormat.dng || (_alsoRaw && caps.supportsRaw),
              onChanged: caps.supportsRaw && _format != PhotoFormat.dng ? (v) => setState(() => _alsoRaw = v) : null,
            ),
            if (converted)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Converting takes a second or two after each shot. In Interval mode, leave a little gap between shots.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(FormatChoice(_format, alsoRaw: _alsoRaw)),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
