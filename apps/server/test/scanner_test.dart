import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Directory root;

  void touch(String rel, [String content = 'x']) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() {
    Log.capture = true;
    root = Directory.systemTemp.createTempSync('pitv-media');
  });

  tearDown(() {
    // Restore permissions so cleanup works.
    Process.runSync('chmod', ['-R', 'u+rwx', root.path]);
    root.deleteSync(recursive: true);
  });

  test('picks up every supported extension, case-insensitively', () {
    for (final e in ['mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'wmv', 'mpeg', 'mpg', 'MKV', 'Mp4']) {
      touch('v_$e.$e');
    }
    for (final e in ['srt', 'txt', 'jpg', 'nfo', 'mp3', 'iso']) {
      touch('other.$e');
    }
    final r = LibraryScanner([root.path]).scan();
    expect(r.files.map((f) => p.extension(f.absolutePath).substring(1).toLowerCase()).toSet(),
        {'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'wmv', 'mpeg', 'mpg'});
    expect(r.files, hasLength(11));
  });

  test('recurses into nested folders', () {
    touch('Movies/A.mkv');
    touch('Movies/Kids/2024/B.mp4');
    touch('Shows/S01/E01.mkv');
    final r = LibraryScanner([root.path]).scan();
    final label = p.basename(root.path);
    expect(r.files.map((f) => f.libraryPath).toSet(), {
      '$label/Movies/A.mkv',
      '$label/Movies/Kids/2024/B.mp4',
      '$label/Shows/S01/E01.mkv',
    });
    expect(r.files.firstWhere((f) => f.title == 'B').folder, '$label/Movies/Kids/2024');
  });

  test('ignores hidden files and junk folders', () {
    touch('good.mkv');
    touch('.hidden.mkv');
    touch('._good.mkv');
    touch('.hiddendir/x.mkv');
    touch('@eaDir/good.mkv/SYNOVIDEO.mp4');
    touch('.Trash/old.mkv');
    touch('.Trash-1000/files/old.mkv');
    touch('#recycle/r.mkv');
    touch('lost+found/l.mkv');
    final r = LibraryScanner([root.path]).scan();
    expect(r.files.map((f) => f.relativePath), ['good.mkv']);
  });

  test('skips unreadable files and folders but lists the rest', () {
    if (Platform.environment['USER'] == 'root') return; // root can read anything
    touch('ok.mkv');
    touch('locked.mkv');
    touch('Private/secret.mkv');
    touch('Public/open.mp4');
    Process.runSync('chmod', ['000', p.join(root.path, 'locked.mkv')]);
    Process.runSync('chmod', ['000', p.join(root.path, 'Private')]);
    final r = LibraryScanner([root.path]).scan();
    expect(r.files.map((f) => f.relativePath).toSet(), {'ok.mkv', 'Public/open.mp4'});
    expect(r.skipped, 2);
  });

  test('missing media dir is reported, others still scanned', () {
    touch('a.mkv');
    final r = LibraryScanner(['/nonexistent/pitv', root.path]).scan();
    expect(r.files, hasLength(1));
    expect(r.errors.single, contains('/nonexistent/pitv'));
  });

  test('symlink loops do not hang the scan', () {
    touch('d/a.mkv');
    Link(p.join(root.path, 'd', 'loop')).createSync(p.join(root.path, 'd'));
    final r = LibraryScanner([root.path]).scan();
    expect(r.files.where((f) => f.title == 'a'), hasLength(1));
  });

  test('root labels are de-duplicated', () {
    expect(rootLabels(['/mnt/a/Movies', '/mnt/b/Movies', '/srv/TV']).values.toList(), ['Movies', 'Movies (2)', 'TV']);
  });

  group('LibraryService', () {
    test('folder listing follows the layout and search matches filenames', () async {
      touch('Movies/Big Buck Bunny.mkv');
      touch('Movies/Kids/Cartoon One.mp4');
      touch('Movies/Kids/Cartoon Two.mp4');
      final lib = LibraryService([root.path]);
      await lib.rescan();
      final label = p.basename(root.path);
      final top = lib.listing();
      expect(top.folders.single.name, label);
      expect(top.folders.single.itemCount, 3);
      final movies = lib.listing(path: '$label/Movies');
      expect(movies.folders.single.name, 'Kids');
      expect(movies.items.single.title, 'Big Buck Bunny');
      final s = lib.listing(query: 'cartoon');
      expect(s.items.map((i) => i.title), ['Cartoon One', 'Cartoon Two']);
      expect(lib.listing(query: 'cartoon two').items.single.title, 'Cartoon Two');
      expect(lib.listing(path: '../../etc').items, isEmpty);
    });

    test('rescan picks up new and removed files', () async {
      touch('a.mkv');
      final lib = LibraryService([root.path]);
      expect((await lib.rescan()).totalItems, 1);
      touch('b.mp4');
      File(p.join(root.path, 'a.mkv')).deleteSync();
      final r = await lib.rescan();
      expect(r.totalItems, 1);
      expect(lib.listing(query: 'b').items.single.title, 'b');
      expect(lib.listing(query: 'a').items, isEmpty);
    });

    test('resolve only accepts scanned files', () async {
      touch('a.mkv');
      final lib = LibraryService([root.path]);
      await lib.rescan();
      final f = lib.listing(query: 'a').items.single;
      expect(lib.resolve(f.id), isNotNull);
      expect(lib.resolve(p.join(root.path, 'a.mkv')), isNotNull);
      expect(lib.resolve('/etc/passwd'), isNull);
      expect(lib.resolve(p.join(root.path, '..', 'x.mkv')), isNull);
    });

    test('metadata from ffprobe/ffmpeg is cached on disk', () async {
      touch('a.mkv');
      final cache = Directory.systemTemp.createTempSync('pitv-cache');
      final runner = FakeRunner();
      runner.onRun = (c) {
        if (c.exe == 'ffprobe') return const CommandResult(0, '{"format":{"duration":"125.5"}}', '');
        if (c.exe == 'ffmpeg') File(c.args.last).writeAsStringSync('jpg');
        return const CommandResult(0, '', '');
      };
      final lib = LibraryService([root.path], metadata: MetadataCache(runner, cache.path));
      await lib.rescan();
      await lib.metadataIdle();
      final e = lib.listing(query: 'a').items.single;
      expect(e.durationSeconds, 125.5);
      expect(e.hasThumbnail, isTrue);
      expect(lib.thumbnailFile(e.id), isNotNull);
      final probes = runner.runs.length;

      // A new service (server restart) uses the cache instead of probing.
      final lib2 = LibraryService([root.path], metadata: MetadataCache(runner, cache.path));
      await lib2.rescan();
      await lib2.metadataIdle();
      expect(runner.runs.length, probes);
      expect(lib2.listing(query: 'a').items.single.durationSeconds, 125.5);
      cache.deleteSync(recursive: true);
    });
    test('video width/height are probed, cached and labelled (4K, 1080p, 720p, unmatched)', () async {
      final sizes = {'uhd.mkv': (3840, 2160), 'fhd.mp4': (1920, 1080), 'hd.mkv': (1280, 720), 'scope.mkv': (1920, 800)};
      sizes.keys.forEach(touch);
      final cache = Directory.systemTemp.createTempSync('pitv-cache');
      addTearDown(() => cache.deleteSync(recursive: true));
      final runner = FakeRunner();
      runner.onRun = (c) {
        if (c.exe == 'ffprobe') {
          expect(c.args, containsAllInOrder(['-select_streams', 'v:0']));
          final (w, h) = sizes[p.basename(c.args.last)]!;
          return CommandResult(0, '{"streams":[{"width":$w,"height":$h}],"format":{"duration":"60"}}', '');
        }
        if (c.exe == 'ffmpeg') File(c.args.last).writeAsStringSync('jpg');
        return const CommandResult(0, '', '');
      };
      final lib = LibraryService([root.path], metadata: MetadataCache(runner, cache.path));
      await lib.rescan();
      await lib.metadataIdle();
      Map<String, String?> labels(LibraryService l) =>
          {for (final e in l.listing(query: '.').items) e.title: e.resolution};
      final want = {'fhd': '1080p', 'hd': '720p', 'scope': '1920×800', 'uhd': '4K'};
      expect(labels(lib), want);
      final json = lib.listing(query: 'uhd').toJson();
      final item = ((json['items'] as List).single as Map);
      expect([item['width'], item['height'], item['resolution']], [3840, 2160, '4K']);

      // Restart: served from the on-disk cache without probing again.
      final probes = runner.runs.length;
      final lib2 = LibraryService([root.path], metadata: MetadataCache(runner, cache.path));
      await lib2.rescan();
      await lib2.metadataIdle();
      expect(runner.runs.length, probes);
      expect(labels(lib2), want);
    });

    test('an older cache entry without a size is re-probed with ffprobe only (thumbnail kept)', () async {
      touch('old.mkv');
      final cache = Directory.systemTemp.createTempSync('pitv-cache');
      addTearDown(() => cache.deleteSync(recursive: true));
      final runner = FakeRunner();
      runner.onRun = (c) {
        if (c.exe == 'ffprobe') return const CommandResult(0, '{"format":{"duration":"10"}}', '');
        if (c.exe == 'ffmpeg') File(c.args.last).writeAsStringSync('jpg');
        return const CommandResult(0, '', '');
      };
      final lib = LibraryService([root.path], metadata: MetadataCache(runner, cache.path));
      await lib.rescan();
      await lib.metadataIdle();
      // Rewrite the cache as a v1 entry (no "v", no width/height).
      final f = File(p.join(cache.path, 'metadata.json'));
      final idx = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
      for (final e in idx.values) {
        (e as Map).remove('v');
      }
      f.writeAsStringSync(jsonEncode(idx));
      runner.runs.clear();
      runner.onRun = (c) {
        if (c.exe == 'ffprobe') {
          return const CommandResult(0, '{"streams":[{"width":1280,"height":720}],"format":{"duration":"10"}}', '');
        }
        return const CommandResult(0, '', '');
      };
      final lib2 = LibraryService([root.path], metadata: MetadataCache(runner, cache.path));
      await lib2.rescan();
      await lib2.metadataIdle();
      expect(runner.runs.map((r) => r.exe), ['ffprobe']);
      final e = lib2.listing(query: 'old').items.single;
      expect([e.resolution, e.hasThumbnail], ['720p', isTrue]);
    });
  });

  test('videoSizeFromProbe applies rotation and tolerates missing streams', () {
    expect(
        videoSizeFromProbe({
          'streams': [
            {
              'width': 1920,
              'height': 1080,
              'side_data_list': [
                {'rotation': -90}
              ]
            }
          ]
        }),
        (1080, 1920));
    expect(
        videoSizeFromProbe({
          'streams': [
            {
              'width': 1280,
              'height': 720,
              'tags': {'rotate': '180'}
            }
          ]
        }),
        (1280, 720));
    expect(videoSizeFromProbe({'streams': []}), (null, null));
    expect(videoSizeFromProbe({}), (null, null));
  });
}
