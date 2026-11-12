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
      outputSize: (_) async => const OutputSize(1920, 1080),
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
    expect(c.args, contains('--window-position=0,0'));
    expect(c.args, contains('--window-size=1920,1080'));
    expect(c.args.any((a) => a.startsWith('--force-device-scale-factor')), isFalse);
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

  test('navigates and starts playback, without sending "f" or requesting fullscreen', () async {
    await player.load(const PlayTarget.youtube(link));
    expect(cdp.log, contains('Page.navigate'));
    expect(cdp.log, contains('Page.addScriptToEvaluateOnNewDocument'));
    expect(cdp.keys, isNot(contains('f')));
    expect(cdp.page.fKeys, 0);
    expect(cdp.page.fullscreen, isFalse);
    expect(cdp.log, isNot(contains('eval:fullscreen')));
    expect(cdp.page.paused, isFalse);
    expect(player.snapshot.paused, isFalse);
  });

  test('the window size follows the detected output, not a hard-coded 1920x1080', () async {
    player = ChromiumPlayer(
      runner: runner,
      display: () => wayland,
      userDataDir: '${tmp.path}/chromium-profile',
      endpoint: cdp,
      pollInterval: const Duration(hours: 1),
      settleDelay: Duration.zero,
      outputSize: (_) async => const OutputSize(3840, 2160),
    );
    cdp.windowBounds.addAll({'width': 3840, 'height': 2160});
    await player.load(const PlayTarget.youtube(link));
    expect(runner.starts.single.args, contains('--window-size=3840,2160'));
    expect(player.outputSize, const OutputSize(3840, 2160));
  });

  test('unknown output size: no window-size flag, still --start-fullscreen', () {
    final args = player.launchArgs(wayland, 'u');
    expect(args, contains('--start-fullscreen'));
    expect(args.any((a) => a.startsWith('--window-size')), isFalse);
  });

  test('a window smaller than the output is resized to the output, then made fullscreen', () async {
    cdp.windowBounds.addAll({'width': 1440, 'height': 1080, 'windowState': 'normal'});
    await player.load(const PlayTarget.youtube(link));
    expect(cdp.setBounds, [
      {'left': 0, 'top': 0, 'width': 1920, 'height': 1080},
      {'windowState': 'fullscreen'},
    ]);
  });

  test('a fullscreen window at the output size is left alone', () async {
    await player.load(const PlayTarget.youtube(link));
    await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa')));
    expect(cdp.setBounds, isEmpty);
  });

  test('the guard script makes the YouTube player full-bleed on watch pages', () {
    expect(youtubeGuardScript, contains('pitv-fullbleed'));
    expect(youtubeGuardScript, isNot(contains('PITV_FULL_BLEED_CSS')));
    expect(youtubeGuardScript, contains(r'#movie_player { position: fixed !important;'));
    expect(youtubeFullBleedCss, contains('width: 100vw !important; height: 100vh !important;'));
    // Hides the page chrome that made the player a partial box (sidebar,
    // masthead), and never forces fullscreen itself.
    expect(youtubeFullBleedCss, contains('#secondary'));
    expect(youtubeFullBleedCss, contains('#masthead-container'));
    expect(youtubeGuardScript, isNot(contains('requestFullscreen')));
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

  group('YouTube fullscreen is manual only', () {
    test('no "f" on load, on the next queue item, or from the poll loop', () async {
      await player.load(const PlayTarget.youtube(link));
      await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa')));
      for (var i = 0; i < 5; i++) {
        await player.seek(i.toDouble()); // each control runs a poll
      }
      cdp.page.url = 'https://www.youtube.com/watch?v=RELATED0000';
      await player.pause(); // poll returns to the ended video
      await player.pause();
      expect(cdp.page.fKeys, 0);
      expect(cdp.page.fullscreen, isFalse);
      expect(cdp.log, isNot(contains('eval:fullscreen')));
    });

    test('toggleFullscreen sends exactly one "f" to the focused player each time', () async {
      await player.load(const PlayTarget.youtube(link));
      await player.toggleFullscreen();
      expect(cdp.page.fKeys, 1);
      expect(cdp.page.fullscreen, isTrue);
      final focus = cdp.log.lastIndexOf('eval:focus');
      expect(focus, greaterThan(-1));
      expect(focus, lessThan(cdp.log.lastIndexOf('Input.dispatchKeyEvent')));
      // The poll loop leaves it alone.
      await player.seek(3);
      expect(cdp.page.fKeys, 1);
      await player.toggleFullscreen();
      expect(cdp.page.fKeys, 2);
      expect(cdp.page.fullscreen, isFalse);
      await player.seek(4);
      expect(cdp.page.fKeys, 2);
      expect(cdp.page.fullscreen, isFalse);
    });

    test('toggleFullscreen without a window does nothing', () async {
      await player.toggleFullscreen();
      expect(cdp.keys, isEmpty);
      expect(runner.starts, isEmpty);
    });

    test('Stop leaves the window open and does not touch fullscreen', () async {
      await player.load(const PlayTarget.youtube(link));
      await player.toggleFullscreen();
      await player.stop();
      expect(cdp.page.paused, isTrue);
      expect(cdp.page.fullscreen, isTrue);
      expect(cdp.page.fKeys, 1);
      expect(cdp.browserClosed, isFalse);
      expect(player.isOpen, isTrue);
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
        outputSize: (_) async => const OutputSize(1920, 1080),
      );
      await player.load(const PlayTarget.youtube(link));
      expect(runner.starts, hasLength(2));
      expect(runner.starts.last.args, contains('--user-data-dir=$profile'));
      expect(marker.readAsStringSync(), 'session');
    });
  });
  group('YouTube playlists', () {
    const list = 'PLtest123';
    void setupPlaylist() {
      cdp.page
        ..playlistId = list
        ..playlist = ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc'];
    }

    test('watch?v= + list opens with list and index kept, not a bare watch?v= URL', () async {
      setupPlaylist();
      await player.load(const PlayTarget.youtube(YouTubeLink('bbbbbbbbbbb', playlistId: list, playlistIndex: 2)));
      expect(runner.starts.single.args.last, 'https://www.youtube.com/watch?v=bbbbbbbbbbb&list=$list&index=2');
      expect(cdp.page.list, list);
      expect(player.snapshot.playlistIndex, 1);
      expect(player.snapshot.playlistLength, 3);
    });

    test('a bare playlist?list= link opens the playlist and starts its first video', () async {
      setupPlaylist();
      await player.load(const PlayTarget.youtube(YouTubeLink.playlist(list)));
      expect(runner.starts.single.args.last, 'https://www.youtube.com/playlist?list=$list');
      expect(cdp.log, contains('eval:playall'));
      expect(cdp.page.vid, 'aaaaaaaaaaa');
      expect(cdp.page.list, list);
      expect(player.snapshot.paused, isFalse);
    });

    test('YouTube advancing inside the playlist is accepted, not sent back', () async {
      setupPlaylist();
      await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa', playlistId: list)));
      cdp.page.advancePlaylist();
      await player.pause(); // poll
      expect(cdp.page.vid, 'bbbbbbbbbbb');
      expect(player.snapshot.ended, isFalse);
      expect(player.snapshot.playlistIndex, 1);
    });

    test('a playlist video that ends mid-playlist is not the end of the item', () async {
      setupPlaylist();
      await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa', playlistId: list)));
      cdp.page.ended = true;
      await player.pause();
      expect(player.snapshot.ended, isFalse, reason: 'YouTube autoplays the next playlist video');
    });

    test('the last playlist video ending is the end; related autoplay after it is blocked', () async {
      setupPlaylist();
      await player.load(const PlayTarget.youtube(YouTubeLink('ccccccccccc', playlistId: list, playlistIndex: 3)));
      cdp.page.ended = true;
      await player.pause();
      expect(player.snapshot.ended, isTrue);
      // YouTube then autoplays a related video (no list): sent back.
      cdp.page.url = 'https://www.youtube.com/watch?v=RELATED0000';
      await player.pause();
      expect(cdp.page.vid, 'ccccccccccc');
      expect(cdp.page.list, list);
      expect(player.snapshot.ended, isTrue);
    });

    test('a related video outside the playlist mid-playlist is still blocked', () async {
      setupPlaylist();
      await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa', playlistId: list)));
      cdp.page.url = 'https://www.youtube.com/watch?v=RELATED0000';
      await player.pause();
      expect(cdp.page.vid, 'aaaaaaaaaaa');
    });

    test('next/previous skip inside the playlist, false at the edges and for single videos', () async {
      setupPlaylist();
      await player.load(const PlayTarget.youtube(YouTubeLink('aaaaaaaaaaa', playlistId: list)));
      expect(await player.skipInItem(forward: false), isFalse);
      expect(await player.skipInItem(forward: true), isTrue);
      expect(cdp.page.vid, 'bbbbbbbbbbb');
      expect(await player.skipInItem(forward: true), isTrue);
      expect(cdp.page.vid, 'ccccccccccc');
      expect(await player.skipInItem(forward: true), isFalse, reason: 'last video: our queue moves');
      expect(await player.skipInItem(forward: false), isTrue);
      expect(cdp.page.vid, 'bbbbbbbbbbb');

      await player.load(const PlayTarget.youtube(link));
      expect(await player.skipInItem(forward: true), isFalse);
    });

    test('the guard only blocks autonav outside an unfinished playlist', () {
      expect(youtubeGuardScript, contains('inOpenPlaylist'));
      expect(youtubeGuardScript, contains('if (!inOpenPlaylist()) cancelAutonav();'));
    });
  });

  test('closeIfRunning closes a Chromium left on the CDP port by a previous server run', () async {
    cdp.up = true; // not launched or attached by this instance
    expect(player.isOpen, isFalse);
    await player.closeIfRunning();
    expect(cdp.browserClosed, isTrue);
  });

  test('closeIfRunning is a no-op when no Chromium is running', () async {
    await player.closeIfRunning();
    expect(cdp.browserClosed, isFalse);
    expect(cdp.log, isEmpty);
  });
}
