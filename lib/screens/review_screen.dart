import 'dart:io';

import 'package:flutter/material.dart';

import '../utils/histogram.dart';
import '../widgets/histogram_view.dart';

/// Full-screen view of the last photo. Pinch-zoom up to 12× to check that
/// stars are sharp dots (focus) and not short lines (trailing).
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.path, this.histogram, this.savedAs = const []});

  final String path;
  final Histogram? histogram;

  /// Formats saved to the gallery for this shot, e.g. ["TIFF", "DNG"].
  final List<String> savedAs;

  @override
  Widget build(BuildContext context) {
    final h = histogram;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.jpg$'), ''), style: const TextStyle(fontSize: 14)),
        actions: [
          if (savedAs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Text(savedAs.join(' + '), style: const TextStyle(color: Colors.white60))),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              maxScale: 12,
              child: Center(child: Image.file(File(path), fit: BoxFit.contain)),
            ),
          ),
          if (h != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 80, child: HistogramView(histogram: h)),
                  const SizedBox(height: 8),
                  Text(h.astroAdvice),
                  Text(
                    'Clipped: ${(h.clippedShadows * 100).toStringAsFixed(1)}% black · '
                    '${(h.clippedHighlights * 100).toStringAsFixed(1)}% white',
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('Pinch to zoom. Stars should be round dots.',
                style: TextStyle(fontSize: 12, color: Colors.white38)),
          ),
        ],
      ),
    );
  }
}
