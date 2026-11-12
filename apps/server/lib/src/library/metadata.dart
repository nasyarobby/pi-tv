import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log.dart';
import '../process.dart';
import 'scanner.dart';

class MediaMetadata {
  const MediaMetadata({this.duration, this.hasThumbnail = false});
  final double? duration;
  final bool hasThumbnail;
}

/// Duration (ffprobe) and thumbnail (ffmpeg) with an on-disk cache keyed
/// by path + size + mtime.
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
    if (e is! Map || e['key'] != _key(f)) return null;
    return MediaMetadata(
      duration: (e['duration'] as num?)?.toDouble(),
      hasThumbnail: File(thumbPath(f.id)).existsSync(),
    );
  }

  Future<MediaMetadata> probe(ScannedFile f) async {
    final c = cached(f);
    if (c != null) return c;
    double? duration;
    try {
      final r = await _runner.run(
          ffprobe,
          [
            '-v',
            'error',
            '-show_entries',
            'format=duration',
            '-of',
            'json',
            f.absolutePath,
          ],
          timeout: const Duration(seconds: 30));
      if (r.ok) {
        final j = jsonDecode(r.stdout) as Map;
        duration = double.tryParse('${(j['format'] as Map?)?['duration']}');
      }
    } catch (e) {
      _log.debug('ffprobe ${f.absolutePath}: $e');
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
    _idx[f.id] = {'key': _key(f), 'duration': duration, 'path': f.absolutePath};
    return MediaMetadata(duration: duration, hasThumbnail: ok);
  }

  void save() {
    try {
      _indexFile.parent.createSync(recursive: true);
      _indexFile.writeAsStringSync(jsonEncode(_idx));
    } catch (e) {
      _log.warn('could not save metadata cache: $e');
    }
  }
}
