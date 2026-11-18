import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../ui/tokens.dart';

/// The painted foreground: 0 = sky, 255 = ground, at [width]×[height].
class ForegroundMask {
  const ForegroundMask(this.data, this.width, this.height);
  final Uint8List data;
  final int width;
  final int height;

  double get coverage => data.where((v) => v > 0).length / data.length;
}

class _Stroke {
  _Stroke(this.erase, this.radius);
  final bool erase;
  final double radius; // fraction of image width
  final points = <Offset>[]; // normalised 0..1 image coordinates
}

/// Paint over the ground/trees/buildings so the stacker keeps them still while
/// aligning the sky.
class MaskPainterScreen extends StatefulWidget {
  const MaskPainterScreen({super.key, required this.imagePath, this.initial});
  final String imagePath;
  final ForegroundMask? initial;

  @override
  State<MaskPainterScreen> createState() => _MaskPainterScreenState();
}

class _MaskPainterScreenState extends State<MaskPainterScreen> {
  static const _maskLongSide = 320;

  final _strokes = <_Stroke>[];
  bool _erase = false;
  double _brush = 0.06;
  Size? _imageSize; // oriented pixel size
  ui.Image? _initialOverlay;

  @override
  void initState() {
    super.initState();
    _loadSize();
  }

  Future<void> _loadSize() async {
    final codec = await ui.instantiateImageCodec(await File(widget.imagePath).readAsBytes(), targetWidth: 64);
    final frame = await codec.getNextFrame();
    final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    codec.dispose();

    ui.Image? overlay;
    final init = widget.initial;
    if (init != null) {
      // Show the previous mask as a starting point.
      final rgba = Uint8List(init.width * init.height * 4);
      for (var i = 0; i < init.data.length; i++) {
        rgba[i * 4] = 185;
        rgba[i * 4 + 1] = 140;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = (init.data[i] * 0.45).round();
      }
      final c = await ui.ImmutableBuffer.fromUint8List(rgba);
      final d = ui.ImageDescriptor.raw(c, width: init.width, height: init.height, pixelFormat: ui.PixelFormat.rgba8888);
      overlay = (await (await d.instantiateCodec()).getNextFrame()).image;
    }
    if (mounted) {
      setState(() {
        _imageSize = size;
        _initialOverlay = overlay;
      });
    }
  }

  ForegroundMask _rasterise() {
    final s = _imageSize!;
    final mw = s.width >= s.height ? _maskLongSide : (_maskLongSide * s.width / s.height).round();
    final mh = s.width >= s.height ? (_maskLongSide * s.height / s.width).round() : _maskLongSide;
    final data = Uint8List(mw * mh);
    final init = widget.initial;
    if (init != null && _initialOverlay != null) {
      for (var y = 0; y < mh; y++) {
        for (var x = 0; x < mw; x++) {
          data[y * mw + x] = init.data[(y * init.height ~/ mh) * init.width + (x * init.width ~/ mw)];
        }
      }
    }
    for (final st in _strokes) {
      final r = st.radius * mw;
      final pts = <Offset>[];
      // Interpolate so fast swipes leave no gaps.
      for (var i = 0; i < st.points.length; i++) {
        final p = Offset(st.points[i].dx * mw, st.points[i].dy * mh);
        if (i > 0) {
          final prev = Offset(st.points[i - 1].dx * mw, st.points[i - 1].dy * mh);
          final steps = max(1, ((p - prev).distance / max(1.0, r / 2)).ceil());
          for (var k = 1; k < steps; k++) {
            pts.add(Offset.lerp(prev, p, k / steps)!);
          }
        }
        pts.add(p);
      }
      for (final p in pts) {
        for (var y = max(0, (p.dy - r).floor()); y <= min(mh - 1, (p.dy + r).ceil()); y++) {
          for (var x = max(0, (p.dx - r).floor()); x <= min(mw - 1, (p.dx + r).ceil()); x++) {
            if ((x - p.dx) * (x - p.dx) + (y - p.dy) * (y - p.dy) <= r * r) {
              data[y * mw + x] = st.erase ? 0 : 255;
            }
          }
        }
      }
    }
    return ForegroundMask(data, mw, mh);
  }

  /// Quick start: everything below a horizontal line is foreground.
  void _fillBelow(double fraction) {
    final st = _Stroke(false, 0.02);
    for (var y = fraction; y <= 1.0; y += 0.01) {
      for (var x = 0.0; x <= 1.0; x += 0.01) {
        st.points.add(Offset(x, y));
      }
    }
    setState(() => _strokes.add(st));
  }

  @override
  Widget build(BuildContext context) {
    final size = _imageSize;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paint the foreground'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
            icon: const Icon(Icons.undo),
          ),
          TextButton(
            onPressed: size == null ? null : () => Navigator.pop(context, _rasterise()),
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Paint over the ground, trees and buildings. Leave the sky unpainted. '
              'The sky is aligned to the stars, the painted part stays still.',
              style: TextStyle(color: V.textDim, fontSize: 13),
            ),
          ),
          Expanded(
            child: size == null
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: AspectRatio(
                      aspectRatio: size.width / size.height,
                      child: LayoutBuilder(builder: (context, c) {
                        Offset norm(Offset local) =>
                            Offset((local.dx / c.maxWidth).clamp(0, 1), (local.dy / c.maxHeight).clamp(0, 1));
                        return GestureDetector(
                          onPanStart: (d) => setState(() => _strokes.add(_Stroke(_erase, _brush)..points.add(norm(d.localPosition)))),
                          onPanUpdate: (d) => setState(() => _strokes.last.points.add(norm(d.localPosition))),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.file(File(widget.imagePath), fit: BoxFit.fill, cacheWidth: 1200),
                              CustomPaint(painter: _MaskOverlay(_strokes, _initialOverlay)),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Paint'), icon: Icon(Icons.brush)),
                          ButtonSegment(value: true, label: Text('Erase'), icon: Icon(Icons.auto_fix_normal)),
                        ],
                        selected: {_erase},
                        onSelectionChanged: (s) => setState(() => _erase = s.first),
                      ),
                      const Spacer(),
                      PopupMenuButton<double>(
                        tooltip: 'Fill below a line',
                        onSelected: _fillBelow,
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 0.5, child: Text('Fill bottom half')),
                          PopupMenuItem(value: 0.67, child: Text('Fill bottom third')),
                          PopupMenuItem(value: 0.8, child: Text('Fill bottom fifth')),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Row(children: [Icon(Icons.vertical_align_bottom), Text(' Fill')]),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('Brush'),
                      Expanded(
                        child: Slider(value: _brush, min: 0.01, max: 0.15, onChanged: (v) => setState(() => _brush = v)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MaskOverlay extends CustomPainter {
  _MaskOverlay(this.strokes, this.initial);
  final List<_Stroke> strokes;
  final ui.Image? initial;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    final init = initial;
    if (init != null) {
      canvas.drawImageRect(
        init,
        Rect.fromLTWH(0, 0, init.width.toDouble(), init.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    for (final s in strokes) {
      final paint = Paint()
        ..color = const Color(0x73B98CFF)
        ..strokeWidth = s.radius * size.width * 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..blendMode = s.erase ? BlendMode.clear : BlendMode.src;
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final p = Offset(s.points[i].dx * size.width, s.points[i].dy * size.height);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
          path.lineTo(p.dx + 0.01, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MaskOverlay old) => true;
}
