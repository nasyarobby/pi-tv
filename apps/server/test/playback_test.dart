import 'dart:io';

import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late FakePlayer yt;
  late FakePlayer local;
  late CountingInhibitor inhibitor;
  late CountingTv tv;
  late PlaybackController pc;
  var n = 0;

  MediaItem ytItem([String id = 'dQw4w9WgXcQ']) =>
      MediaItem(id: 'y${n++}', kind: MediaKind.youtube, title: 'YT $id', source: id);
  MediaItem localItem([String name = 'movie']) =>
      MediaItem(id: 'l${n++}', kind: MediaKind.local, title: name, source: name);

  setUp(() {
    Log.capture = true;
    yt = FakePlayer(MediaKind.youtube);
    local = FakePlayer(MediaKind.local);
    inhibitor = CountingInhibitor();
    tv = CountingTv();
    pc = PlaybackController(
      players: {MediaKind.youtube: yt, MediaKind.local: local},
      resolve: (i) => i.kind == MediaKind.youtube
          ? PlayTarget.youtube(YouTubeLink(i.source))
          : (i.source == 'gone' ? null : PlayTarget.file('/media/${i.source}.mkv')),
      inhibitor: inhibitor,
      tv: tv,
    );
  });

  tearDown(() => pc.dispose());

  test('play now starts the player, wakes the TV and inhibits blanking', () async {
    await pc.playNow(ytItem());
    expect(yt.loads, hasLength(1));
    expect(pc.state, PlaybackState.playing);
    expect(pc.windowOpen, isTrue);
    expect(inhibitor.active, isTrue);
    expect(tv.wakes, 1);
    expect(pc.history, hasLength(1));
  });

  test('mixed queue auto-advances YouTube -> local -> YouTube', () async {
    await pc.playNow(ytItem('aaaaaaaaaaa'));
    await pc.enqueue(localItem('film'));
    await pc.enqueue(ytItem('bbbbbbbbbbb'));
    expect(pc.queue.map((i) => i.kind), [MediaKind.local, MediaKind.youtube]);

    yt.finish();
    await pump(20);
    expect(pc.current!.kind, MediaKind.local);
    expect(local.loads.single.filePath, '/media/film.mkv');
    // Switching to local closed the YouTube window.
    expect(yt.closes, 1);
    expect(yt.isOpen, isFalse);

    local.finish();
    await pump(20);
    expect(pc.current!.source, 'bbbbbbbbbbb');
    expect(local.closes, 1, reason: 'switching back to YouTube quits mpv');
    expect(pc.queue, isEmpty);
    expect(pc.history.map((h) => h.item.kind).toList(), [MediaKind.youtube, MediaKind.local, MediaKind.youtube]);
  });

  test('end with an empty queue leaves the window open and loads nothing else', () async {
    await pc.playNow(ytItem());
    yt.finish();
    await pump(20);
    expect(pc.state, PlaybackState.ended);
    expect(pc.windowOpen, isTrue);
    expect(yt.closes, 0);
    expect(yt.loads, hasLength(1), reason: 'no related video is autoplayed');
    expect(inhibitor.active, isFalse, reason: 'inhibit released when ended');
    expect(pc.status.windowOpen, isTrue);
    expect(pc.status.state, PlaybackState.ended);
  });

  test('add to queue after the end starts it immediately', () async {
    await pc.playNow(ytItem());
    yt.finish();
    await pump(20);
    await pc.enqueue(localItem());
    expect(pc.current!.kind, MediaKind.local);
    expect(pc.state, PlaybackState.playing);
  });

  test('add to queue while idle starts playback', () async {
    await pc.enqueue(ytItem());
    expect(pc.state, PlaybackState.playing);
    expect(pc.queue, isEmpty);
  });

  test('Stop pauses, keeps the window open and releases the inhibit', () async {
    await pc.playNow(localItem());
    await pc.stop();
    expect(local.calls, contains('stop'));
    expect(local.closes, 0);
    expect(pc.windowOpen, isTrue);
    expect(pc.state, PlaybackState.stopped);
    expect(inhibitor.active, isFalse);
    await pc.play();
    expect(pc.state, PlaybackState.playing);
    expect(inhibitor.active, isTrue);
  });

  test('Close is the only user action that tears the window down', () async {
    await pc.playNow(ytItem());
    await pc.enqueue(localItem());
    // Every other user action keeps the window.
    await pc.pause();
    await pc.play();
    await pc.stop();
    await pc.seek(3);
    await pc.setVolume(30);
    await pc.setMuted(true);
    await pc.toggleSubtitles();
    pc.clearQueue();
    expect(yt.closes, 0);
    expect(pc.windowOpen, isTrue);

    await pc.close();
    expect(yt.closes, 1);
    expect(pc.windowOpen, isFalse);
    expect(pc.state, PlaybackState.idle);
    expect(inhibitor.active, isFalse);
  });

  test('Stop and Close never wake or switch the TV (CEC only on play)', () async {
    await pc.playNow(ytItem());
    final wakes = tv.wakes;
    await pc.stop();
    await pc.close();
    expect(tv.wakes, wakes);
  });

  test('switching local -> YouTube via play now closes mpv first', () async {
    await pc.playNow(localItem());
    await pc.playNow(ytItem());
    expect(local.calls.last, 'close');
    expect(yt.loads, hasLength(1));
    expect(local.isOpen, isFalse);
  });

  test('fullscreen toggle goes to the open YouTube player only, never to mpv', () async {
    await pc.toggleFullscreen(); // nothing open
    expect(yt.calls, isNot(contains('fullscreen')));
    await pc.playNow(ytItem());
    await pc.toggleFullscreen();
    expect(yt.calls.where((c) => c == 'fullscreen'), hasLength(1));
    await pc.playNow(localItem());
    await pc.toggleFullscreen();
    expect(local.calls, isNot(contains('fullscreen')));
    expect(yt.calls.where((c) => c == 'fullscreen'), hasLength(1));
  });

  test('same kind back-to-back reuses the window (no close)', () async {
    await pc.playNow(ytItem('aaaaaaaaaaa'));
    await pc.playNow(ytItem('bbbbbbbbbbb'));
    expect(yt.closes, 0);
    expect(yt.loads, hasLength(2));
  });

  test('next / previous', () async {
    await pc.playNow(ytItem('aaaaaaaaaaa'));
    await pc.enqueue(ytItem('bbbbbbbbbbb'));
    expect(await pc.next(), isTrue);
    expect(pc.current!.source, 'bbbbbbbbbbb');
    expect(await pc.next(), isFalse, reason: 'empty queue: next does nothing');
    await pc.previous();
    expect(pc.current!.source, 'aaaaaaaaaaa');
    expect(pc.queue.single.source, 'bbbbbbbbbbb', reason: 'current goes back to the front');
  });

  test('previous past 5 s restarts the current item', () async {
    await pc.playNow(ytItem('aaaaaaaaaaa'));
    await pc.playNow(ytItem('bbbbbbbbbbb'));
    yt.emit(yt.snapshot.copyWith(position: 30));
    await pc.previous();
    expect(pc.current!.source, 'bbbbbbbbbbb');
    expect(yt.calls, contains('seek:0.0'));
  });

  test('queue reorder / move / remove / clear', () async {
    await pc.playNow(ytItem());
    final a = localItem('a'), b = localItem('b'), c = localItem('c');
    for (final i in [a, b, c]) {
      await pc.enqueue(i);
    }
    pc.moveInQueue(c.id, 0);
    expect(pc.queue.map((i) => i.title), ['c', 'a', 'b']);
    pc.reorderQueue([b.id, c.id, a.id]);
    expect(pc.queue.map((i) => i.title), ['b', 'c', 'a']);
    expect(() => pc.reorderQueue([a.id]), throwsA(isA<PlaybackException>()));
    expect(pc.removeFromQueue(c.id), isTrue);
    expect(pc.removeFromQueue('nope'), isFalse);
    expect(pc.queue.map((i) => i.title), ['b', 'a']);
    pc.clearQueue();
    expect(pc.queue, isEmpty);
    expect(pc.status.queueLength, 0);
  });

  test('pause from the TV side updates state and releases inhibit', () async {
    await pc.playNow(ytItem());
    yt.emit(yt.snapshot.copyWith(paused: true));
    await pump();
    expect(pc.state, PlaybackState.paused);
    expect(inhibitor.active, isFalse);
    yt.emit(yt.snapshot.copyWith(paused: false));
    await pump();
    expect(pc.state, PlaybackState.playing);
    expect(inhibitor.active, isTrue);
  });

  test('window closed outside the server goes idle without relaunching', () async {
    await pc.playNow(ytItem());
    yt.crash();
    await pump();
    expect(pc.state, PlaybackState.idle);
    expect(pc.windowOpen, isFalse);
    expect(yt.loads, hasLength(1));
  });

  test('a removed local file is rejected', () async {
    await expectLater(pc.playNow(localItem('gone')), throwsA(isA<PlaybackException>()));
    expect(pc.state, PlaybackState.idle);
  });

  test('a failing player load surfaces an error and releases the inhibit', () async {
    yt.failNextLoad = StateError('no chromium');
    await expectLater(pc.playNow(ytItem()), throwsA(isA<PlaybackException>()));
    expect(inhibitor.active, isFalse);
  });

  test('history and queue persist through JsonStore', () async {
    final dir = await _tempDir();
    PlaybackController make() => PlaybackController(
          players: {MediaKind.youtube: FakePlayer(MediaKind.youtube), MediaKind.local: FakePlayer(MediaKind.local)},
          resolve: (i) => PlayTarget.youtube(YouTubeLink(i.source)),
          queueStore: JsonStore('$dir/q.json'),
          historyStore: JsonStore('$dir/h.json'),
        );
    final a = make();
    await a.playNow(ytItem());
    await a.enqueue(ytItem('bbbbbbbbbbb'));
    await a.dispose();
    final b = make();
    expect(b.history, hasLength(1));
    expect(b.queue.single.source, 'bbbbbbbbbbb');
    await b.dispose();
  });

  test('status stream reports the spec fields', () async {
    final seen = <NowPlaying>[];
    final sub = pc.statusChanges.listen(seen.add);
    await pc.playNow(localItem());
    await pump();
    final last = seen.last;
    expect(last.kind, MediaKind.local);
    expect(last.state, PlaybackState.playing);
    expect(last.windowOpen, isTrue);
    expect(last.durationSeconds, 10);
    await sub.cancel();
  });
}

Future<String> _tempDir() async => (await Directory.systemTemp.createTemp('pitv')).path;
