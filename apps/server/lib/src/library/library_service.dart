import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../log.dart';
import 'metadata.dart';
import 'scanner.dart';

/// In-memory library built from scans, with folder listing and search.
class LibraryService {
  LibraryService(this.roots, {this.metadata, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final List<String> roots;
  final MetadataCache? metadata;
  final DateTime Function() _clock;
  final _log = Log('library');

  Map<String, ScannedFile> _files = {};
  final Map<String, MediaMetadata> _meta = {};
  DateTime? scannedAt;
  int lastSkipped = 0;
  Future<RescanResult>? _scan;
  Future<void>? _metaJob;
  final _changes = StreamController<void>.broadcast();

  /// Fires after every scan and whenever metadata fills in.
  Stream<void> get changes => _changes.stream;
  bool get scanning => _scan != null;
  int get total => _files.length;

  ScannedFile? byId(String id) => _files[id];

  /// Resolves a library id, or an absolute path inside a media dir.
  ScannedFile? resolve(String idOrPath) {
    final byIdHit = _files[idOrPath];
    if (byIdHit != null) return byIdHit;
    if (!p.isAbsolute(idOrPath)) return null;
    final norm = p.normalize(idOrPath);
    // Only files found by the scanner (inside MEDIA_DIRS) are playable.
    return _files[libraryIdFor(norm)];
  }

  /// Scans all roots (concurrent callers share one scan).
  Future<RescanResult> rescan() => _scan ??= _doScan().whenComplete(() => _scan = null);

  Future<RescanResult> _doScan() async {
    _changes.add(null);
    // Run the synchronous walk after yielding so callers see `scanning`.
    await Future<void>.delayed(Duration.zero);
    final report = LibraryScanner(roots).scan();
    for (final e in report.errors) {
      _log.warn(e);
    }
    _files = {for (final f in report.files) f.id: f};
    scannedAt = _clock();
    lastSkipped = report.skipped;
    final m = metadata;
    if (m != null) {
      for (final f in report.files) {
        final c = m.cached(f);
        if (c != null) _meta[f.id] = c;
      }
    }
    _log.info('scan: ${_files.length} videos, ${report.skipped} skipped');
    _changes.add(null);
    _startMetadata();
    return RescanResult(totalItems: _files.length, skipped: report.skipped, scannedAt: scannedAt!);
  }

  void _startMetadata() {
    final m = metadata;
    if (m == null || _metaJob != null) return;
    _metaJob = () async {
      var n = 0;
      while (true) {
        final todo = _files.values.where((f) => !_meta.containsKey(f.id)).toList();
        if (todo.isEmpty) break;
        for (final f in todo) {
          if (!_files.containsKey(f.id)) continue;
          _meta[f.id] = await m.probe(f);
          if (++n % 10 == 0) {
            m.save();
            _changes.add(null);
          }
        }
      }
      m.save();
      if (n > 0) _changes.add(null);
    }()
        .catchError((Object e) => _log.error('metadata job', e))
        .whenComplete(() => _metaJob = null);
  }

  /// Waits for the background metadata job (tests).
  Future<void> metadataIdle() async {
    while (_metaJob != null) {
      await _metaJob;
    }
  }

  LibraryEntry entry(ScannedFile f) {
    final m = _meta[f.id];
    return LibraryEntry(
      id: f.id,
      title: f.title,
      path: f.libraryPath,
      folder: f.folder,
      sizeBytes: f.size,
      durationSeconds: m?.duration,
      hasThumbnail: m?.hasThumbnail ?? false,
      width: m?.width,
      height: m?.height,
    );
  }

  /// Folder listing for [path] ('' = top), or a filename search for [query].
  LibraryListing listing({String path = '', String? query}) {
    final clean = path.split('/').where((s) => s.isNotEmpty && s != '.' && s != '..').join('/');
    final all = _files.values.toList()
      ..sort((a, b) => a.libraryPath.toLowerCase().compareTo(b.libraryPath.toLowerCase()));
    if (query != null && query.trim().isNotEmpty) {
      final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      final hits = all.where((f) {
        if (clean.isNotEmpty && !f.libraryPath.startsWith('$clean/')) return false;
        final name = p.basename(f.absolutePath).toLowerCase();
        return terms.every(name.contains);
      });
      return LibraryListing(
        path: clean,
        query: query,
        folders: const [],
        items: [for (final f in hits) entry(f)],
        scannedAt: scannedAt,
        scanning: scanning,
        totalItems: total,
      );
    }
    final folders = <String, int>{};
    final items = <LibraryEntry>[];
    final prefix = clean.isEmpty ? '' : '$clean/';
    for (final f in all) {
      final lp = f.libraryPath;
      if (!lp.startsWith(prefix)) continue;
      final rest = lp.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        items.add(entry(f));
      } else {
        final name = rest.substring(0, slash);
        folders.update(name, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    // Show configured roots even when empty.
    if (clean.isEmpty) {
      for (final label in rootLabels(roots).values) {
        folders.putIfAbsent(label, () => 0);
      }
    }
    final names = folders.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return LibraryListing(
      path: clean,
      folders: [for (final n in names) LibraryFolder(name: n, path: '$prefix$n', itemCount: folders[n]!)],
      items: items,
      scannedAt: scannedAt,
      scanning: scanning,
      totalItems: total,
    );
  }

  String? thumbnailFile(String id) {
    final m = metadata;
    if (m == null || !(_meta[id]?.hasThumbnail ?? false)) return null;
    return m.thumbPath(id);
  }

  Future<void> dispose() => _changes.close();
}
