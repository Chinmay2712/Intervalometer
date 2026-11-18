import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:valometer_camera/valometer_camera.dart';

/// Keeps Valometer's own copies in step with the phone's gallery.
///
/// Every capture and Studio result is saved twice: once to the gallery and
/// once inside the app (the working copies the Studio reads). When the user
/// deletes the photo from the gallery, [sync] deletes the app's copies too,
/// so they stop using storage.
///
/// Files are grouped by name stem (VAL_20261110_220102_123 → .jpg, .dng,
/// .tif…). A group is removed only when every gallery item it was saved as
/// is gone; anything that can't be checked is kept.
class GallerySync {
  GallerySync._();

  static const _indexName = 'gallery_index.json';

  /// Index reads/writes and syncs run one at a time.
  static Future<void> _queue = Future.value();
  static Future<T> _serial<T>(Future<T> Function() task) {
    final next = _queue.then((_) => task());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  // ------------------------------------------------------------- record

  /// Remembers the gallery items for one capture.
  static Future<void> recordCapture(CaptureResult shot) async {
    final any = shot.jpegPath ?? shot.photoPath ?? shot.rawPath;
    if (any == null) return;
    await _record(stemOf(any), shot.galleryIds.values.toList());
  }

  /// Saves [path] to the gallery and remembers it.
  static Future<String?> saveAndRecord(String path, {String mime = 'image/jpeg'}) async {
    final id = await ValometerCamera.instance.saveToGallery(path, mime: mime);
    await _record(stemOf(path), [?id]);
    return id;
  }

  static Future<void> _record(String stem, List<String> ids) => _serial(() async {
        final index = await _load();
        final list = index.putIfAbsent(stem, () => <String>[]);
        for (final id in ids) {
          if (!list.contains(id)) list.add(id);
        }
        await _save(index);
      });

  // --------------------------------------------------------------- sync

  /// Deletes app copies whose gallery items were all deleted. Safe to call
  /// often. Returns the number of files deleted.
  static Future<int> sync() => _serial(() async {
        try {
          return await _sync();
        } catch (_) {
          return 0; // never let housekeeping break the app
        }
      });

  static Future<int> _sync() async {
    final dirs = await _dirs();
    final index = await _load();
    var deleted = 0;

    // 1. Groups with recorded gallery ids.
    final stems = [for (final e in index.entries) if (e.value.isNotEmpty) e.key];
    final ids = [for (final s in stems) ...index[s]!];
    if (ids.isNotEmpty) {
      final found = await ValometerCamera.instance.galleryExists(ids);
      var k = 0;
      for (final s in stems) {
        final n = index[s]!.length;
        final states = found.sublist(k, k + n);
        k += n;
        if (states.every((v) => v == false)) {
          deleted += _deleteGroup(dirs, s);
          index.remove(s);
        }
      }
    }

    // 2. Older files saved before ids were recorded (Android: by file name).
    if (Platform.isAndroid) {
      final legacy = <String, List<String>>{};
      for (final dir in dirs) {
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          final name = f.uri.pathSegments.last;
          if (!name.startsWith('VAL_') || name.endsWith('.json')) continue;
          final stem = stemOf(name);
          if (index.containsKey(stem)) continue;
          legacy.putIfAbsent(stem, () => []).add(name);
        }
      }
      if (legacy.isNotEmpty) {
        final names = [for (final l in legacy.values) ...l];
        final found = await ValometerCamera.instance.galleryExists(names, byName: true);
        var k = 0;
        for (final e in legacy.entries) {
          final states = found.sublist(k, k + e.value.length);
          k += e.value.length;
          if (states.every((v) => v == false)) {
            deleted += _deleteGroup(dirs, e.key);
          } else {
            index[e.key] = const []; // still there: never look it up by name again
          }
        }
      }
    }

    await _save(index);
    return deleted;
  }

  static int _deleteGroup(List<Directory> dirs, String stem) {
    var n = 0;
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name.startsWith('$stem.')) {
          try {
            f.deleteSync();
            n++;
          } catch (_) {}
        }
      }
    }
    return n;
  }

  // ------------------------------------------------------------ storage

  /// File name without folder and extension.
  static String stemOf(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  static Future<List<Directory>> _dirs() async {
    final docs = await getApplicationDocumentsDirectory();
    return [
      Directory(await ValometerCamera.instance.framesDirectory()),
      Directory('${docs.path}/Studio'),
    ];
  }

  static Future<File> _indexFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$_indexName');

  static Future<Map<String, List<String>>> _load() async {
    try {
      final f = await _indexFile();
      if (!f.existsSync()) return {};
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return {for (final e in raw.entries) e.key: [for (final v in e.value as List) '$v']};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<String, List<String>> index) async {
    final f = await _indexFile();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(index));
    await tmp.rename(f.path);
  }
}
