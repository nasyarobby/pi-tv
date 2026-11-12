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
      fullscreenTimeout: const Duration(milliseconds: 200),
      fullscreenRetryDelay: const Duration(milliseconds: 5),
      fullscreenReapplyInterval: Duration.zero,
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

  group('YouTube player fullscreen', () {
    test('waits for the player to be ready, then sends "f" and verifies it covers the screen', () async {
      cdp.page.notReadyReads = 12;
      await player.load(const PlayTarget.youtube(link));
      expect(cdp.page.notReadyReads, 0);
      expect(cdp.page.fKeys, 1);
      expect(cdp.page.fullscreen, isTrue);
      expect(cdp.page.requestFullscreenCalls, 0);
      final focus = cdp.log.lastIndexOf('eval:focus');
      expect(focus, greaterThan(cdp.log.indexOf('eval:play')));
      expect(focus, lessThan(cdp.log.lastIndexOf('Input.dispatchKeyEvent')));
    });

    test('falls back to requestFullscreen when "f" does not take', () async {
      cdp.page.ignoreFKey = true;
      await player.load(const PlayTarget.youtube(link));
      expect(cdp.page.fKeys, 1);
      expect(cdp.page.requestFullscreenCalls, 1);
      expect(cdp.page.fullscreen, isTrue);
    });

    test('retries until the fullscreen element really covers the screen', () async {
      cdp.page.fullscreenCoversScreen = false;
      final load = player.load(const PlayTarget.youtube(link));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      cdp.page.fullscreenCoversScreen = true;
      await load;
      expect(cdp.page.fullscreen, isTrue);
      expect(cdp.page.state()['full'], isTrue);
      // It kept trying, and exited the partial fullscreen before each new
      // "f" so the toggle never turned the real one off.
      expect(cdp.page.fKeys, greaterThan(1));
      expect(cdp.log, contains('eval:exitfs'));
    });

    test('a failed attempt does not break playback, and the poll loop retries', () async {
      cdp.page
        ..ignoreFKey = true
        ..rejectRequestFullscreen = true;
      await player.load(const PlayTarget.youtube(link));
      expect(cdp.page.fullscreen, isFalse);
      expect(player.isOpen, isTrue);
      expect(cdp.page.paused, isFalse);
      cdp.page.rejectRequestFullscreen = false;
      await player.setVolume(50); // runs a poll
      await player.pendingFullscreen;
      expect(cdp.page.fullscreen, isTrue);
    });

    test('is re-applied when the next queue item starts', () async {
      await player.load(const PlayTarget.youtube(link));
      expect(cdp.page.fullscreen, isTrue);
      await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa')));
      expect(cdp.page.vid, 'aaaaaaaaaaa');
      expect(cdp.page.fKeys, 2);
      expect(cdp.page.fullscreen, isTrue);
    });

    test('the poll loop puts the player back when it falls out of fullscreen', () async {
      await player.load(const PlayTarget.youtube(link));
      cdp.page.fullscreen = false;
      await player.seek(10);
      await player.pendingFullscreen;
      expect(cdp.page.fullscreen, isTrue);
      expect(cdp.page.t, 10);
    });

    test('Stop stays paused, fullscreen and open', () async {
      await player.load(const PlayTarget.youtube(link));
      await player.stop();
      await player.pendingFullscreen;
      expect(cdp.page.paused, isTrue);
      expect(cdp.page.fullscreen, isTrue);
      expect(cdp.browserClosed, isFalse);
      expect(player.isOpen, isTrue);
    });

    test('after YouTube autoplays a related video, the ended video is fullscreen again and paused', () async {
      await player.load(const PlayTarget.youtube(link));
      cdp.page.url = 'https://www.youtube.com/watch?v=RELATED0000';
      await player.pause(); // poll: returns to the ended video (navigation drops fullscreen)
      expect(cdp.page.vid, 'dQw4w9WgXcQ');
      await player.pause(); // next poll re-applies fullscreen
      await player.pendingFullscreen;
      expect(cdp.page.fullscreen, isTrue);
      expect(cdp.page.paused, isTrue);
      expect(cdp.page.vid, 'dQw4w9WgXcQ');
      expect(player.snapshot.ended, isTrue);
    });

    test('Close stops re-applying fullscreen', () async {
      await player.load(const PlayTarget.youtube(link));
      final keys = cdp.page.fKeys;
      await player.close();
      cdp.page.fullscreen = false;
      await player.seek(5);
      expect(player.pendingFullscreen, isNull);
      expect(cdp.page.fKeys, keys);
      expect(player.isOpen, isFalse);
    });
  });

  group('persistent Chromium profile', () {
    test('lives under the data dir', () {
      expect(chromiumProfileDir('/home/pi/.pi-tv'), '/home/pi/.pi-tv/chromium-profile');
    });

    test('Close then play reuses the same user-data-dir and keeps its contents', () async {
      final profile = '${tmp.path}/chromium-profile';
      await player.load(const PlayTarget.youtube(link));
      final cookies = File('$profile/Default/Cookies')
        ..createSync(recursive: true)
        ..writeAsStringSync('session');
      await player.close();
      expect(cookies.existsSync(), isTrue);

      await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa')));
      expect(runner.starts, hasLength(2));
      for (final s in runner.starts) {
        expect(s.args, contains('--user-data-dir=$profile'));
        expect(s.args.where((a) => a.startsWith('--user-data-dir=')), hasLength(1));
        expect(s.args.any((a) => a.contains('incognito') || a.contains('guest')), isFalse);
      }
      expect(cookies.readAsStringSync(), 'session');
    });

    test('a server restart after Chromium exited uses the same profile and does not wipe it', () async {
      final profile = '${tmp.path}/chromium-profile';
      await player.load(const PlayTarget.youtube(link));
      final marker = File('$profile/Default/Cookies')
        ..createSync(recursive: true)
        ..writeAsStringSync('session');
      await player.stop();
      // Chromium exits on its own (crash, reboot of the session, ...).
      cdp.up = false;
      runner.processes.single.exit(0);
      await player.dispose();

      player = ChromiumPlayer(
        runner: runner,
        display: () => wayland,
        userDataDir: profile,
        endpoint: cdp,
        pollInterval: const Duration(hours: 1),
        settleDelay: Duration.zero,
        fullscreenTimeout: const Duration(milliseconds: 200),
        fullscreenRetryDelay: const Duration(milliseconds: 5),
      );
      await player.load(const PlayTarget.youtube(link));
      expect(runner.starts, hasLength(2));
      expect(runner.starts.last.args, contains('--user-data-dir=$profile'));
      expect(marker.readAsStringSync(), 'session');
    });
  });
}
