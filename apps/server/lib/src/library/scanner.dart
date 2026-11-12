import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Video extensions the scanner picks up (lower-case, no dot).
const Set<String> videoExtensions = {'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'wmv', 'mpeg', 'mpg'};

/// Folder / file names that are never listed.
const Set<String> denyList = {
  '@eaDir',
  '#recycle',
  '#snapshot',
  '.Trash',
  '\$RECYCLE.BIN',
  'System Volume Information',
  'lost+found',
  '.AppleDouble',
  '__MACOSX',
};

bool isDenied(String name) =>
    name.startsWith('.') || denyList.contains(name) || name.startsWith('.Trash-') || name.startsWith('._');

/// A video file found on disk.
class ScannedFile {
  ScannedFile({
    required this.id,
    required this.absolutePath,
    required this.root,
    required this.rootLabel,
    required this.relativePath,
    required this.size,
    required this.modified,
  });
  final String id;
  final String absolutePath;
  final String root;
  final String rootLabel;

  /// Path relative to [root], with `/` separators.
  final String relativePath;
  final int size;
  final DateTime modified;

  /// `<rootLabel>/<relativePath>`.
  String get libraryPath => relativePath.isEmpty ? rootLabel : '$rootLabel/$relativePath';
  String get folder => p.posix.dirname(libraryPath);
  String get title => p.basenameWithoutExtension(absolutePath);
}

class ScanReport {
  ScanReport(this.files, this.skipped, this.errors);
  final List<ScannedFile> files;

  /// Files or folders that could not be read.
  final int skipped;
  final List<String> errors;
}

String libraryIdFor(String absolutePath) => sha1.convert(utf8.encode(absolutePath)).toString().substring(0, 16);

/// Human labels for the configured roots (basename, de-duplicated).
Map<String, String> rootLabels(List<String> roots) {
  final out = <String, String>{};
  final used = <String, int>{};
  for (final r in roots) {
    var base = p.basename(p.normalize(r));
    if (base.isEmpty || base == '/') base = 'media';
    final n = used.update(base, (v) => v + 1, ifAbsent: () => 1);
    out[r] = n == 1 ? base : '$base ($n)';
  }
  return out;
}

/// Recursive scanner over the configured media directories.
class LibraryScanner {
  LibraryScanner(this.roots);
  final List<String> roots;

  ScanReport scan() {
    final files = <ScannedFile>[];
    final errors = <String>[];
    var skipped = 0;
    final labels = rootLabels(roots);
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) {
        errors.add('missing media dir: $root');
        continue;
      }
      final visited = <String>{};
      void walk(Directory d) {
        String real;
        try {
          real = d.resolveSymbolicLinksSync();
        } on FileSystemException {
          skipped++;
          return;
        }
        if (!visited.add(real)) return; // symlink loop
        List<FileSystemEntity> entries;
        try {
          entries = d.listSync(followLinks: false);
        } on FileSystemException catch (e) {
          skipped++;
          errors.add('cannot list ${d.path}: ${e.osError?.message ?? e.message}');
          return;
        }
        entries.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
        for (final e in entries) {
          final name = p.basename(e.path);
          if (isDenied(name)) continue;
          var type = FileSystemEntity.typeSync(e.path, followLinks: false);
          if (type == FileSystemEntityType.link) type = FileSystemEntity.typeSync(e.path);
          if (type == FileSystemEntityType.directory) {
            walk(Directory(e.path));
          } else if (type == FileSystemEntityType.file) {
            final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
            if (!videoExtensions.contains(ext)) continue;
            final f = File(e.path);
            try {
              // Verify the file is actually readable, not just listed.
              f.openSync().closeSync();
              final st = f.statSync();
              files.add(ScannedFile(
                id: libraryIdFor(f.absolute.path),
                absolutePath: f.absolute.path,
                root: root,
                rootLabel: labels[root]!,
                relativePath: p.split(p.relative(f.path, from: root)).join('/'),
                size: st.size,
                modified: st.modified,
              ));
            } on FileSystemException {
              skipped++;
            }
          }
        }
      }

      walk(dir);
    }
    return ScanReport(files, skipped, errors);
  }
}
