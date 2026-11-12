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
}
