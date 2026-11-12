import 'dart:convert';

import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:test/test.dart';

void main() {
  test('NowPlaying round-trips and exposes the spec fields', () {
    const np = NowPlaying(
      item: MediaItem(id: 'q1', kind: MediaKind.local, title: 'Movie', source: 'abc', thumbnail: '/api/thumb/abc'),
      state: PlaybackState.ended,
      positionSeconds: 12.5,
      durationSeconds: 100,
      volume: 70,
      queueLength: 3,
      windowOpen: true,
    );
    final j = jsonDecode(jsonEncode(np.toJson())) as Map<String, Object?>;
    for (final k in [
      'kind',
      'title',
      'thumbnail',
      'position',
      'duration',
      'state',
      'volume',
      'queueLength',
      'windowOpen'
    ]) {
      expect(j.containsKey(k), isTrue, reason: k);
    }
    expect(j['kind'], 'local');
    expect(j['state'], 'ended');
    final back = NowPlaying.fromJson(j);
    expect(back.item!.title, 'Movie');
    expect(back.state, PlaybackState.ended);
    expect(back.windowOpen, isTrue);
    expect(back.queueLength, 3);
  });

  test('LibraryListing round-trip', () {
    final l = LibraryListing(
      path: 'Movies',
      folders: const [LibraryFolder(name: 'Kids', path: 'Movies/Kids', itemCount: 2)],
      items: const [LibraryEntry(id: 'x', title: 'A', path: 'Movies/A.mkv', folder: 'Movies', sizeBytes: 10)],
      scannedAt: DateTime.utc(2026),
      totalItems: 3,
    );
    final back = LibraryListing.fromJson(jsonDecode(jsonEncode(l.toJson())) as Map<String, Object?>);
    expect(back.folders.single.itemCount, 2);
    expect(back.items.single.path, 'Movies/A.mkv');
    expect(back.totalItems, 3);
  });

  test('ServerEvent parsing', () {
    expect(ServerEvent.fromJson({'type': 'status', 'status': const NowPlaying().toJson()}), isA<StatusEvent>());
    expect(ServerEvent.fromJson({'type': 'library', 'total': 4}), isA<LibraryChangedEvent>());
    expect(ServerEvent.fromJson({'type': 'nope'}), isNull);
  });

  test('PlayRequest', () {
    final r = PlayRequest.fromJson({'url': 'x', 'mode': 'queue'});
    expect(r.mode, PlayMode.queue);
    expect(PlayRequest.fromJson({'url': 'x'}).mode, PlayMode.now);
  });

  group('resolution labels', () {
    test('standard names', () {
      expect(resolutionLabel(3840, 2160), '4K');
      expect(resolutionLabel(4096, 2160), '4K');
      expect(resolutionLabel(2560, 1440), '1440p');
      expect(resolutionLabel(1920, 1080), '1080p');
      expect(resolutionLabel(1080, 1920), '1080p');
      expect(resolutionLabel(1280, 720), '720p');
      expect(resolutionLabel(854, 480), '480p');
      expect(resolutionLabel(640, 480), '480p');
    });
    test('unmatched sizes show the exact width×height; unknown is null', () {
      expect(resolutionLabel(1920, 800), '1920×800');
      expect(resolutionLabel(720, 576), '720×576');
      expect(resolutionLabel(null, 1080), isNull);
      expect(resolutionLabel(0, 0), isNull);
    });
    test('library entry, media item and now playing carry width/height + label', () {
      const e =
          LibraryEntry(id: 'a', title: 'A', path: 'm/A.mkv', folder: 'm', sizeBytes: 1, width: 3840, height: 2160);
      final e2 = LibraryEntry.fromJson(e.toJson());
      expect(e.toJson()['resolution'], '4K');
      expect([e2.width, e2.height, e2.resolution], [3840, 2160, '4K']);
      const item = MediaItem(id: '1', kind: MediaKind.local, title: 'A', source: 'a', width: 1280, height: 720);
      expect(MediaItem.fromJson(item.toJson()).resolution, '720p');
      const np = NowPlaying(item: item, width: 1280, height: 720);
      final j = np.toJson();
      expect([j['width'], j['height'], j['resolution']], [1280, 720, '720p']);
      expect(NowPlaying.fromJson(j).resolution, '720p');
      const yt = NowPlaying(item: MediaItem(id: '2', kind: MediaKind.youtube, title: 'Y', source: 'dQw4w9WgXcQ'));
      expect(yt.toJson().containsKey('resolution'), isFalse);
    });
  });

  test('a YouTube playlist item keeps its list and index through JSON', () {
    const item = MediaItem(
        id: '1', kind: MediaKind.youtube, title: 'P', source: 'dQw4w9WgXcQ', playlistId: 'PLx1', playlistIndex: 4);
    final back = MediaItem.fromJson(item.toJson());
    expect(back.isPlaylist, isTrue);
    expect(back.youtubeLink!.watchUrl.toString(), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx1&index=4');
    const only = MediaItem(id: '2', kind: MediaKind.youtube, title: 'P', source: '', playlistId: 'PLx1');
    expect(only.youtubeLink!.watchUrl.toString(), 'https://www.youtube.com/playlist?list=PLx1');
    const np = NowPlaying(item: item, playlistPosition: 2, playlistLength: 9, canNext: true);
    final n = NowPlaying.fromJson(np.toJson());
    expect([n.playlistPosition, n.playlistLength, n.canNext], [2, 9, true]);
  });
}
