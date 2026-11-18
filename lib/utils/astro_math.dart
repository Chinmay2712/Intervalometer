/// Star-trailing exposure rules and lens optics helpers.
library;

import 'dart:math';

import 'package:valometer_camera/valometer_camera.dart';

/// 35 mm-equivalent focal length from the horizontal field of view
/// (a full-frame sensor is 36 mm wide).
double equivFocalFromFov(double fovDegrees) => 18 / tan(fovDegrees * pi / 360);

/// Classic 500 rule: longest exposure (s) before stars visibly trail.
/// Generous on high-resolution sensors; treat it as an upper bound.
double rule500(double equivFocalMm) => 500 / equivFocalMm;

/// Simplified NPF rule (Frédéric Michaud, Société Astronomique de France):
/// t = (35·N + 30·p) / f, with N = f-number, p = pixel pitch in µm,
/// f = real focal length in mm. Gives pin-point stars at 100 % zoom.
double npfRule({
  required double fNumber,
  required double pixelPitchUm,
  required double focalMm,
}) =>
    (35 * fNumber + 30 * pixelPitchUm) / focalMm;

/// The optical numbers the calculators need. Values the phone doesn't report
/// are estimated and flagged so the user can correct them.
class LensOptics {
  const LensOptics({
    required this.equivFocalMm,
    required this.focalMm,
    required this.fNumber,
    required this.pixelPitchUm,
    required this.estimated,
  });

  final double equivFocalMm;
  final double focalMm;
  final double fNumber;
  final double pixelPitchUm;

  /// True when at least one value is a guess (typical on iPhone, which does
  /// not expose the physical sensor size).
  final bool estimated;

  LensOptics copyWith({double? equivFocalMm, double? focalMm, double? fNumber, double? pixelPitchUm}) =>
      LensOptics(
        equivFocalMm: equivFocalMm ?? this.equivFocalMm,
        focalMm: focalMm ?? this.focalMm,
        fNumber: fNumber ?? this.fNumber,
        pixelPitchUm: pixelPitchUm ?? this.pixelPitchUm,
        estimated: estimated,
      );

  factory LensOptics.fromCapabilities(CameraCapabilities caps) {
    var estimated = false;

    double equiv;
    if (caps.fieldOfView != null && caps.fieldOfView! > 0) {
      equiv = equivFocalFromFov(caps.fieldOfView!);
    } else if (caps.focalLength != null && caps.sensorWidthMm != null) {
      equiv = caps.focalLength! * 36 / caps.sensorWidthMm!;
    } else {
      equiv = 26;
      estimated = true;
    }

    double focal;
    if (caps.focalLength != null && caps.focalLength! > 0) {
      focal = caps.focalLength!;
    } else {
      focal = equiv / typicalPhoneCropFactor(equiv);
      estimated = true;
    }

    final pitch = caps.pixelPitchUm ?? 2.44; // 48 MP sensor binned to 12 MP
    if (caps.pixelPitchUm == null) estimated = true;

    final fNumber = caps.aperture ?? 1.8;
    if (caps.aperture == null) estimated = true;

    return LensOptics(
      equivFocalMm: equiv,
      focalMm: focal,
      fNumber: fNumber,
      pixelPitchUm: pitch,
      estimated: estimated,
    );
  }
}

/// Rough crop factor of phone cameras by lens type (ultra-wide sensors are
/// small, main sensors are large, telephoto sensors are small).
double typicalPhoneCropFactor(double equivFocalMm) {
  if (equivFocalMm < 18) return 6.0;
  if (equivFocalMm < 40) return 3.5;
  return 7.0;
}

/// How many frames to stack to reach [targetSeconds] of total exposure.
int framesToStack(double targetSeconds, double perFrameSeconds) =>
    max(1, (targetSeconds / perFrameSeconds).ceil());
