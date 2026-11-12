import 'dart:io';

import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late FakeRunner runner;
  late FakeCdpEndpoint cdp;
  late ChromiumPlayer player;
  late Directory tmp;
  const wayland = DisplayEnvironment(DisplayKind.wayland, waylandDisplay: 'wayland-0', runtimeDir: '/run/user/1000');

  setUp(() {
    Log.capture = true;
    tmp = Directory.systemTemp.createTempSync('pitv-chromium');
    runner = FakeRunner(available: {'chromium'});
    cdp = FakeCdpEndpoint();
    runner.onStart = (c, p) {
      cdp.up = true;
      cdp.onBrowserClose = () => p.exit(0);
    };
    player = ChromiumPlayer(
      runner: runner,
      display: () => wayland,
      userDataDir: '${tmp.path}/chromium-profile',
      cdpPort: 9333,
      endpoint: cdp,
      pollInterval: const Duration(hours: 1),
      settleDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await player.dispose();
    tmp.deleteSync(recursive: true);
  });

  const link = YouTubeLink('dQw4w9WgXcQ', startSeconds: 90);

  test('launches system Chromium fullscreen with a dedicated profile, never kiosk', () async {
    await player.load(const PlayTarget.youtube(link));
    expect(runner.starts, hasLength(1));
    final c = runner.starts.single;
    expect(c.exe, '/usr/bin/chromium');
    expect(c.args, contains('--start-fullscreen'));
    expect(c.args, contains('--remote-debugging-port=9333'));
    expect(c.args, contains('--user-data-dir=${tmp.path}/chromium-profile'));
    expect(c.args, contains('--ozone-platform=wayland'));
    expect(c.args.any((a) => a.contains('kiosk')), isFalse);
    expect(c.args.last, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s');
    expect(player.isOpen, isTrue);
  });

  test('X11 fallback uses the x11 ozone platform', () {
    final args = player.launchArgs(const DisplayEnvironment(DisplayKind.x11, x11Display: ':0'), 'u');
    expect(args, contains('--ozone-platform=x11'));
    expect(args, isNot(contains('--ozone-platform=wayland')));
  });

  test('navigates, starts playback and sends "f" for player fullscreen', () async {
    await player.load(const PlayTarget.youtube(link));
    expect(cdp.log, contains('Page.navigate'));
    expect(cdp.log, contains('Page.addScriptToEvaluateOnNewDocument'));
    expect(cdp.keys, contains('f'));
    expect(cdp.page.fullscreen, isTrue);
    expect(cdp.page.paused, isFalse);
    expect(player.snapshot.paused, isFalse);
  });

  test('clicks Play when autoplay is blocked', () async {
    cdp.page.autoplayBlocked = true;
    await player.load(const PlayTarget.youtube(YouTubeLink('dQw4w9WgXcQ')));
    expect(cdp.log, contains('eval:playbutton'));
    expect(cdp.page.paused, isFalse);
  });

  test('reuses an already running Chromium instead of launching another', () async {
    await player.load(const PlayTarget.youtube(link));
    await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa')));
    expect(runner.starts, hasLength(1));

    // A fresh server process finds the existing window on the CDP port.
    final again = ChromiumPlayer(
      runner: runner,
      display: () => wayland,
      userDataDir: '${tmp.path}/chromium-profile',
      endpoint: cdp,
      pollInterval: const Duration(hours: 1),
      settleDelay: Duration.zero,
    );
    await again.load(const PlayTarget.youtube(YouTubeLink('bbbbbbbbbbb')));
    expect(runner.starts, hasLength(1));
    expect(cdp.page.vid, 'bbbbbbbbbbb');
    await again.dispose();
  });

  test('reports ended and stays on the video', () async {
    await player.load(const PlayTarget.youtube(link));
    cdp.page
      ..ended = true
      ..paused = true
      ..t = 100;
    final ended = player.snapshots.firstWhere((s) => s.ended);
    // trigger a poll through a control call
    await player.seek(100);
    cdp.page.ended = true;
    await player.pause();
    expect((await ended).ended, isTrue);
    expect(player.isOpen, isTrue);
    expect(cdp.browserClosed, isFalse);
    expect(cdp.page.vid, 'dQw4w9WgXcQ');
  });

  test('if YouTube autoplays a related video it is sent back to the ended video', () async {
    await player.load(const PlayTarget.youtube(link));
    // YouTube navigates by itself to a related video.
    cdp.page.url = 'https://www.youtube.com/watch?v=RELATED0000';
    await player.pause(); // runs a poll
    expect(cdp.page.vid, 'dQw4w9WgXcQ');
    expect(cdp.page.paused, isTrue);
    expect(player.snapshot.ended, isTrue);
    expect(player.isOpen, isTrue);
  });

  test('Stop pauses and keeps the window', () async {
    await player.load(const PlayTarget.youtube(link));
    await player.stop();
    expect(cdp.page.paused, isTrue);
    expect(cdp.browserClosed, isFalse);
    expect(runner.processes.single.exited, isFalse);
    expect(player.isOpen, isTrue);
  });

  test('controls map to the YouTube player', () async {
    await player.load(const PlayTarget.youtube(link));
    await player.seek(42);
    expect(cdp.page.t, 42);
    await player.setVolume(35);
    expect(cdp.page.volume, 35);
    await player.toggleSubtitles();
    expect(cdp.keys, contains('c'));
  });

  test('Close exits fullscreen and closes our Chromium', () async {
    await player.load(const PlayTarget.youtube(link));
    await player.close();
    expect(cdp.log, contains('eval:exitfs'));
    expect(cdp.browserClosed, isTrue);
    expect(runner.processes.single.exited, isTrue);
    expect(player.isOpen, isFalse);
  });

  test('a Chromium that exits on its own marks the window closed', () async {
    await player.load(const PlayTarget.youtube(link));
    final closed = player.snapshots.firstWhere((s) => !s.open);
    cdp.up = false;
    runner.processes.single.exit(0);
    expect((await closed).open, isFalse);
  });
}
