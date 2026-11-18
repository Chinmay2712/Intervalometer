import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

/// Disposes [image] after the next two frames, so a widget that is still
/// painting it (or fading out) never draws a disposed image.
void disposeImageLater(ui.Image? image) {
  if (image == null) return;
  final binding = SchedulerBinding.instance;
  binding.addPostFrameCallback((_) {
    binding.addPostFrameCallback((_) => image.dispose());
    binding.scheduleFrame();
  });
  binding.scheduleFrame();
}
