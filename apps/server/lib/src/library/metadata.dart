import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log.dart';
import '../process.dart';
import 'scanner.dart';

class MediaMetadata {
  const MediaMetadata({this.duration, this.hasThumbnail = false, this.width, this.height});
  final double? duration;
  final bool hasThumbnail;

  /// Size of the first video stream (display size: rotation applied).
  final int? width;
  final int? height;
}

/// Bump when the cached fields change so older entries are re-probed
/// (v2 added width/height; the thumbnail is kept).
const int metadataCacheVersion = 2;

/// Duration + video size (ffprobe) and thumbnail (ffmpeg) with an on-disk
/// cache keyed by path + size + mtime.
class MetadataCache {
  MetadataCache(this._runner, this.cacheDir, {this.ffprobe = 'ffprobe', this.ffmpeg = 'ffmpeg'});
  final ProcessRunner _runner;
  final String cacheDir;
  final String ffprobe;
  final String ffmpeg;
  final _log = Log('metadata');
  Map<String, Object?>? _index;

  File get _indexFile => File(p.join(cacheDir, 'metadata.json'));
  String thumbPath(String id) => p.join(cacheDir, 'thumbs', '$id.jpg');

  Map<String, Object?> get _idx {
    if (_index != null) return _index!;
    try {
      final d = jsonDecode(_indexFile.readAsStringSync());
      _index = d is Map ? d.cast<String, Object?>() : {};
    } catch (_) {
      _index = {};
    }
    return _index!;
  }

  String _key(ScannedFile f) => '${f.size}:${f.modified.millisecondsSinceEpoch}';

  MediaMetadata? cached(ScannedFile f) {
    final e = _idx[f.id];
    if (e is! Map || e['key'] != _key(f) || e['v'] != metadataCacheVersion) return null;
    return MediaMetadata(
      duration: (e['duration'] as num?)?.toDouble(),
      hasThumbnail: File(thumbPath(f.id)).existsSync(),
      width: (e['width'] as num?)?.toInt(),
      height: (e['height'] as num?)?.toInt(),
    );
  }

  Future<MediaMetadata> probe(ScannedFile f) async {
    final c = cached(f);
    if (c != null) return c;
    final old = _idx[f.id];
    // An entry from an older cache version for the same file: only ffprobe
    // again, keep the thumbnail.
    final thumbOk = old is Map && old['key'] == _key(f) && File(thumbPath(f.id)).existsSync();
    double? duration;
    int? width, height;
    try {
      final r = await _runner.run(
          ffprobe,
          [
            '-v',
            'error',
            '-select_streams',
            'v:0',
            '-show_entries',
            'format=duration:stream=width,height:stream_side_data=rotation:stream_tags=rotate',
            '-of',
            'json',
            f.absolutePath,
          ],
          timeout: const Duration(seconds: 30));
      if (r.ok) {
        final j = jsonDecode(r.stdout) as Map;
        duration = double.tryParse('${(j['format'] as Map?)?['duration']}');
        (width, height) = videoSizeFromProbe(j);
      }
    } catch (e) {
      _log.debug('ffprobe ${f.absolutePath}: $e');
    }
    if (thumbOk) {
      _idx[f.id] = _entry(f, duration, width, height);
      return MediaMetadata(duration: duration, hasThumbnail: true, width: width, height: height);
    }
    final thumb = thumbPath(f.id);
    Directory(p.dirname(thumb)).createSync(recursive: true);
    final at = duration != null && duration > 20 ? (duration * 0.1).clamp(5, 120).toStringAsFixed(1) : '1';
    var ok = false;
    try {
      final r = await _runner.run(
          ffmpeg,
          [
            '-nostdin',
            '-y',
            '-v',
            'error',
            '-ss',
            at,
            '-i',
            f.absolutePath,
            '-frames:v',
            '1',
            '-vf',
            'scale=480:-2',
            '-q:v',
            '4',
            thumb,
          ],
          timeout: const Duration(seconds: 60));
      ok = r.ok && File(thumb).existsSync();
      if (!ok && at != '0') {
        final r2 = await _runner.run(ffmpeg,
            ['-nostdin', '-y', '-v', 'error', '-i', f.absolutePath, '-frames:v', '1', '-vf', 'scale=480:-2', thumb],
            timeout: const Duration(seconds: 60));
        ok = r2.ok && File(thumb).existsSync();
      }
    } catch (e) {
      _log.debug('ffmpeg ${f.absolutePath}: $e');
    }
    _idx[f.id] = _entry(f, duration, width, height);
    return MediaMetadata(duration: duration, hasThumbnail: ok, width: width, height: height);
  }

  Map<String, Object?> _entry(ScannedFile f, double? duration, int? width, int? height) => {
        'v': metadataCacheVersion,
        'key': _key(f),
        'duration': duration,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        'path': f.absolutePath,
      };

  void save() {
    try {
      _indexFile.parent.createSync(recursive: true);
      _indexFile.writeAsStringSync(jsonEncode(_idx));
    } catch (e) {
      _log.warn('could not save metadata cache: $e');
    }
  }
}

/// Width and height of the first video stream in ffprobe JSON output,
/// swapped for a 90°/270° rotation so a portrait phone video reads as
/// portrait. `(null, null)` when there is no video stream.
(int?, int?) videoSizeFromProbe(Map<dynamic, dynamic> probe) {
  final streams = probe['streams'];
  if (streams is! List || streams.isEmpty || streams.first is! Map) return (null, null);
  final s = streams.first as Map;
  final w = (s['width'] as num?)?.toInt();
  final h = (s['height'] as num?)?.toInt();
  if (w == null || h == null || w <= 0 || h <= 0) return (null, null);
  num? rotation;
  final side = s['side_data_list'];
  if (side is List) {
    for (final d in side) {
      if (d is Map && d['rotation'] is num) rotation = d['rotation'] as num;
    }
  }
  final tags = s['tags'];
  if (rotation == null && tags is Map) rotation = num.tryParse('${tags['rotate']}');
  final quarter = rotation != null && (rotation.round().abs() % 180) == 90;
  return quarter ? (h, w) : (w, h);
}
