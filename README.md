# Valometer

Manual camera + intervalometer for astrophotography, built in Flutter with
native camera code for full control:

| | iOS | Android |
|---|---|---|
| Camera API | AVFoundation (Swift) | Camera2 (Kotlin) |
| ISO / shutter | ✅ (shutter up to ~1 s, hardware limit) | ✅ (often up to 10–30 s) |
| White balance (Kelvin) | ✅ exact | ✅ exact on Android 16+, nearest preset before that |
| Manual focus / ∞ | ✅ | ✅ (if the lens supports it) |
| Aperture | read-only (shown in the top bar) | read-only |
| RAW (DNG) | ✅ Bayer RAW | ✅ if the phone supports RAW |
| Photo format (JPEG, HEIC, PNG, TIFF, RAW, optionally + RAW) | ✅ JPEG/HEIC by the camera; PNG/TIFF lossless from the uncompressed photo | ✅ JPEG by the camera; HEIC/PNG/TIFF converted from a quality-100 JPEG |
| Photos saved to | Photos app + app's Documents/Valometer | Pictures/Valometer + app folder |

## Studio (camera screen, top bar icon)

Layout: a night-sky backdrop with the three tools in a floating switcher at
the bottom and the main action in the top bar (**Process** → **Stop** →
**Export**, plus a ⋮ menu for Reset / Details / Start over). The current tool's
options sit in a capsule floating over the canvas on the left: tap an icon and
the capsule itself grows to show those settings, then shrinks back once you
pick something (or tap outside / the icon again). While editing, the open
capsule drops to the bottom and the photo shrinks above it so changes stay
visible. The canvas shows the chosen photos (tap play to preview the
sequence), the result building up live while it processes, and then the
editor.

Nothing goes to the gallery while processing: the result opens in the editor
as a draft. Edit it (or not), then tap **Export** to save the image and/or
video to the gallery and the app's `Studio` folder; each export adds a new
copy. Leaving or starting over before exporting asks before discarding the
draft. Editor:
- Photo: Looks (one-tap astro presets), Light (exposure, contrast, highlights,
  shadows, black point), Color (saturation, warmth, tint), Curve, Astro tools
  (remove light pollution, noise reduction, star reduction, sharpen, clarity),
  Crop & rotate (aspect presets, rotate, flip, straighten). Hold to compare.
- Video: Trim, Speed & loop (12–60 fps, ping-pong), Looks / Light / Color /
  Curve on every frame, Deflicker.

Choose photos from a **Valometer sequence** (interval shots are grouped
automatically) or **the gallery** (multi-select, sorted by time taken), then:

- **Stack:** aligns the stars (rotation + shift) and averages the frames to
  cut noise. Options:
  - *Remove planes and satellites*: kappa-sigma outlier rejection (2 passes).
  - *Keep foreground sharp*: paint the ground; the sky is aligned and the
    ground stays still, with a soft blended edge.
  - Up to 255 photos per stack.
- **Star trails:** lighten blend of the sequence, plus an optional
  **growing-trails video**.
- **Timelapse:** H.264 MP4 at 24/30/60 fps, Full HD or 4K.

Exports go to the gallery (Pictures/Movies › Valometer on Android, Photos on
iPhone) and to the app's `Studio` folder. Processing runs on the
phone in a background isolate at the photos' **full resolution** (a 48 MP
sequence gives a 48 MP stack or trail; needs roughly 1 GB of free memory at
48 MP), or ~3 MP with *Fast processing*. JPEG/HEIC input only; RAW/DNG stacking isn't supported yet.

### Deleted photos

Each saved photo/video remembers its gallery item. When the app opens, comes
back to the foreground or lists sequences in Studio, it checks the gallery
and deletes the app's own copies of photos you deleted there (all of a shot's
formats must be gone). On iPhone this needs full Photos access; photos saved
before this feature are only checked on Android (by file name).

## Sky conditions (moon icon with stars, top bar)

- Twilight times (sunset, civil/nautical/astronomical dusk and dawn, sunrise)
  and a darkness timeline, calculated **offline** from your location.
- Moon phase, % lit, moonrise/moonset, next new and full moon.
- "Dark and moon down" windows.
- Milky Way core: best and visible windows (dark, ≥ 10° up, moon down),
  highest altitude and compass direction, core rise/set.
- Hourly cloud forecast (total + low/mid/high), temperature, dew point and a
  dew warning, from [Open-Meteo](https://open-meteo.com) (free, no key).
- Per-hour shooting quality and the night's best window.

Location is approximate (~1 km) and remembered for use in the field. You can
also type in coordinates. Coordinates are rounded to 2 decimals before being
sent to Open-Meteo. Accuracy: sunrise/sunset within ~3 min, moon phases
within ~20 min (checked against published 2024 times in `test/sky_test.dart`).

## ⚠️ Keep `!` out of the project path

Gradle fails on paths containing `!` ("Could not determine wrapper version").
The project now lives in `C:\Users\chinm\Desktop\One_For_All\VIbe Code\valometer`,
which is fine. Don't rename any parent folder to include `!` again.

## Open in Android Studio

1. File › Open › select the `valometer` folder (the one with `pubspec.yaml`).
2. Make sure the Flutter and Dart plugins are installed (Settings › Plugins).
3. Run `flutter pub get` (Android Studio prompts you).
4. Plug in an Android phone with USB debugging on and press Run ▶.

## Accounts (Supabase + Google / Apple): ON HOLD

> Login is hidden for now and the app opens straight to the camera. The code
> and the Supabase project are kept. To turn it back on, set
> `Env.accountsEnabled = true` in `lib/config/env.dart`.

Sign-in is optional: without settings, or with "Continue without an account",
the app runs fully offline. To turn it on:

1. **Supabase project.** Copy *Project URL* and the *publishable key*
   (`sb_publishable_…`) from Project Settings › API Keys into `env.json`.
2. **Database + delete-account function** (Supabase CLI):
   ```
   supabase link --project-ref <your-ref>
   supabase db push
   supabase functions deploy delete-account
   ```
3. **Google** (Google Cloud Console › APIs & Services › Credentials):
   - Create an OAuth client of type **Web application**. Put its ID in
     `GOOGLE_WEB_CLIENT_ID`. Put the same ID and its secret in Supabase ›
     Authentication › Providers › Google.
   - Create an **Android** client: package `com.valometer.valometer` plus the
     SHA-1 from `cd android && ./gradlew signingReport`.
   - Create an **iOS** client: bundle ID `com.valometer.valometer`. Put its ID
     in `GOOGLE_IOS_CLIENT_ID` and its *reversed* ID in `ios/Runner/Info.plist`
     (replace `REPLACE_WITH_IOS_CLIENT_ID`).
4. **Apple** (needs the paid Apple Developer Program):
   - In Xcode, go to Runner › Signing & Capabilities and add **Sign in with
     Apple** (it uses `ios/Runner/Runner.entitlements`).
   - In Supabase › Authentication › Providers › Apple, add the bundle ID
     `com.valometer.valometer`. For Apple sign-in on Android, also add a
     Services ID + key and the redirect URL `com.valometer.valometer://login-callback`.
5. Supabase › Authentication › URL Configuration: add
   `com.valometer.valometer://login-callback` to the redirect URLs.

`env.json` is git-ignored. `env.example.json` shows the keys. In Android
Studio, pick the **Valometer** run configuration (it passes
`--dart-define-from-file=env.json`). From a terminal:
`flutter run --dart-define-from-file=env.json`.

## Running on your iPhone

iOS apps can only be built on a **Mac with Xcode** (Apple's rule; Windows
can't do it). Options:

- Borrow or use a Mac: `open ios/Runner.xcworkspace`, set your Apple ID team in
  *Signing & Capabilities*, then `flutter run` with the iPhone connected.
- A cloud Mac CI (Codemagic, GitHub Actions macOS runners) to build and
  upload to TestFlight.

Minimum iOS: 17. Minimum Android: 10 (API 29).

## Project layout

```
lib/
  main.dart                  app entry, portrait lock, night-vision filter
  theme.dart                 dark theme + red night-vision mode
  intervalometer.dart        timed shooting sequence (tested)
  utils/exposure.dart        shutter/ISO stops & formatting
  screens/camera_screen.dart viewfinder + all controls
  widgets/interval_sheet.dart interval settings sheet
packages/valometer_camera/   local plugin with the native camera code
  lib/valometer_camera.dart                    Dart API
  ios/.../ValometerCameraPlugin.swift          AVFoundation
  android/.../ValometerCameraPlugin.kt         Flutter bridge + permissions
  android/.../CameraController.kt              Camera2 manual capture
```

## Tips for night shooting

- Use a tripod and a start delay of 3–5 s so the tap doesn't shake the shot.
- Pick RAW (or "Also save RAW") with the format button and stack the frames later (Sequator, Siril, DeepSkyStacker).
- On iPhone, shoot many ~1 s frames and stack them, because single exposures are capped by iOS.
- Switch on the red night-vision mode (moon icon) to keep your eyes dark-adapted.

## Roadmap (agreed, not built yet)

Presets synced to your account ·
battery/storage estimate.
