import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_tv_remote/src/app.dart';
import 'package:pi_tv_remote/src/app_controller.dart';
import 'package:pi_tv_remote/src/platform/settings_store.dart';
import 'package:pi_tv_remote/src/widgets/pin_pad.dart';

import 'fake_server.dart';

Future<void> enterPin(WidgetTester t, String pin) async {
  for (final d in pin.split('')) {
    await t.tap(find.byKey(ValueKey('pin-key-$d')));
    await t.pump();
  }
  await t.pumpAndSettle();
}

Future<AppController> boot(WidgetTester t, FakePiServer s,
    {bool web = true,
    MemorySettingsStore? store,
    FakeShareSource? shares,
    String route = '/',
    Size size = const Size(432, 960)}) async {
  t.view.physicalSize = size * 2.5;
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
  final c = makeController(s, web: web, store: store, shares: shares);
  await c.init();
  await t.pumpWidget(PiTvApp(controller: c, initialRoute: route));
  await t.pumpAndSettle();
  return c;
}

void main() {
  test('normaliseServerUrl', () {
    expect(normaliseServerUrl('192.168.1.20').toString(), 'http://192.168.1.20:8787');
    expect(normaliseServerUrl('http://pi.local:9000/').toString(), 'http://pi.local:9000');
    expect(normaliseServerUrl(' '), isNull);
    expect(normaliseServerUrl('ftp://x'), isNull);
  });

  testWidgets('numeric PIN pad keeps leading zeros and completes at 6 digits', (t) async {
    String? got;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: PinPad(onCompleted: (p) => got = p)))));
    await enterPin(t, '01234');
    expect(got, isNull);
    await t.tap(find.byKey(const ValueKey('pin-key-back')));
    await t.pump();
    await enterPin(t, '45');
    expect(got, '012345');
  });

  testWidgets('web: login with the PIN, wrong PIN shows an error', (t) async {
    final s = FakePiServer();
    await boot(t, s);
    expect(find.text('Enter the 6-digit PIN'), findsOneWidget);
    await enterPin(t, '123456');
    expect(find.text('Wrong PIN'), findsOneWidget);
    await enterPin(t, '012345');
    expect(find.text('Now playing'), findsWidgets);
    expect(s.requests.where((r) => r.url.queryParameters.containsKey('pin')), isEmpty);
  });

  testWidgets('paste URL: rejects non-YouTube, plays share text', (t) async {
    final s = FakePiServer();
    await boot(t, s);
    await enterPin(t, '012345');
    await t.enterText(find.byKey(const ValueKey('url-input')), 'https://vimeo.com/1');
    await t.tap(find.byKey(const ValueKey('url-play')));
    await t.pumpAndSettle();
    expect(find.text('That is not a YouTube video or playlist link'), findsOneWidget);
    expect(s.count('POST', '/api/play'), 0);

    await t.enterText(find.byKey(const ValueKey('url-input')), 'Watch https://youtu.be/dQw4w9WgXcQ?t=42 now');
    await t.tap(find.byKey(const ValueKey('url-play')));
    await t.pumpAndSettle();
    expect(s.count('POST', '/api/play'), 1);
    expect(find.text('YouTube dQw4w9WgXcQ'), findsOneWidget);
  });

  testWidgets('Stop keeps the window; Close asks first then closes', (t) async {
    final s = FakePiServer();
    await boot(t, s);
    await enterPin(t, '012345');
    await t.enterText(find.byKey(const ValueKey('url-input')), 'https://youtu.be/dQw4w9WgXcQ');
    await t.tap(find.byKey(const ValueKey('url-play')));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 6)); // let the snackbar go away
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('np-stop')));
    await t.tap(find.byKey(const ValueKey('np-stop')));
    await t.pumpAndSettle();
    expect(find.textContaining('Stopped (window open)'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('np-close')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('confirm-close')));
    await t.pumpAndSettle();
    expect(find.textContaining('Nothing playing'), findsWidgets);
  });

  testWidgets('Fullscreen button sends the fullscreen control for YouTube only', (t) async {
    final s = FakePiServer();
    await boot(t, s);
    await enterPin(t, '012345');
    await t.enterText(find.byKey(const ValueKey('url-input')), 'https://youtu.be/dQw4w9WgXcQ');
    await t.tap(find.byKey(const ValueKey('url-play')));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 6));
    await t.pumpAndSettle();
    final fs = find.byKey(const ValueKey('np-fullscreen'));
    expect(fs, findsOneWidget);
    await t.ensureVisible(fs);
    await t.tap(fs);
    await t.pumpAndSettle();
    final controls = s.requests.where((r) => r.url.path == '/api/control').toList();
    expect(controls, hasLength(1));
    expect(controls.single.body, contains('"action":"fullscreen"'));

    // A local file (mpv): no fullscreen button.
    await t.tap(find.text('Library'));
    await t.pumpAndSettle();
    await t.tap(find.text('Film One'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('lib-play-now')));
    await t.pumpAndSettle();
    await t.tap(find.text('Now playing').first);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('np-fullscreen')), findsNothing);
  });

  testWidgets('Rescan button asks the server to rescan and refreshes the listing', (t) async {
    final s = FakePiServer();
    s.pendingFiles = [
      {'id': 'f2', 'title': 'New Arrival', 'path': 'Movies/New Arrival.mp4', 'folder': 'Movies', 'size': 1},
    ];
    await boot(t, s);
    await enterPin(t, '012345');
    await t.tap(find.text('Library'));
    await t.pumpAndSettle();
    expect(find.text('Film One'), findsOneWidget);
    expect(find.text('New Arrival'), findsNothing);
    await t.tap(find.byKey(const ValueKey('lib-rescan')));
    await t.pumpAndSettle();
    expect(s.count('POST', '/api/library/rescan'), 1);
    expect(find.text('New Arrival'), findsOneWidget);
    expect(find.textContaining('Library rescanned: 2 videos'), findsOneWidget);
  });

  testWidgets('library item -> Add to queue', (t) async {
    final s = FakePiServer();
    await boot(t, s);
    await enterPin(t, '012345');
    await t.tap(find.text('Library'));
    await t.pumpAndSettle();
    await t.tap(find.text('Film One'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('lib-add-queue')));
    await t.pumpAndSettle();
    final play = s.requests.lastWhere((r) => r.url.path == '/api/play');
    expect(play.body, contains('"localPath":"f1"'));
    expect(play.body, contains('"mode":"queue"'));
  });

  testWidgets('Android first run: address, then PIN; token stored', (t) async {
    final s = FakePiServer();
    final store = MemorySettingsStore();
    final c = await boot(t, s, web: false, store: store);
    expect(find.text('Connect to your Pi'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('server-address')), '192.168.1.20');
    await t.tap(find.byKey(const ValueKey('server-connect')));
    await t.pumpAndSettle();
    expect(store.values[kServerUrl], 'http://192.168.1.20:8787');
    await enterPin(t, '012345');
    expect(store.values[kToken], 'tok012345');
    expect(store.values.values.contains('012345'), isFalse, reason: 'the token is stored, not the PIN');
    expect(c.phase, AppPhase.ready);
    // Every request after login carries the Authorization header.
    final after = s.requests.where((r) => r.url.path != '/api/login' && r.url.path != '/api/health');
    expect(after.every((r) => r.headers['Authorization'] == 'Bearer tok012345'), isTrue);
  });

  testWidgets('Android share before setup: setup, login, then confirm and send', (t) async {
    final s = FakePiServer();
    final shares = FakeShareSource('Cool clip - YouTube https://youtube.com/shorts/dQw4w9WgXcQ?si=abc');
    await boot(t, s, web: false, shares: shares);
    expect(find.textContaining('shared link will be sent'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('server-address')), '192.168.1.20:8787');
    await t.tap(find.byKey(const ValueKey('server-connect')));
    await t.pumpAndSettle();
    await enterPin(t, '012345');
    expect(find.text('Send to the TV?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('share-add-queue')));
    await t.pumpAndSettle();
    final play = s.requests.lastWhere((r) => r.url.path == '/api/play');
    expect(play.body, contains('shorts/dQw4w9WgXcQ'));
    expect(play.body, contains('"mode":"queue"'));
  });

  testWidgets('share while running shows Play now / Add to queue', (t) async {
    final s = FakePiServer();
    final shares = FakeShareSource();
    final store = MemorySettingsStore({kServerUrl: 'http://192.168.1.20:8787', kToken: 'tok012345'});
    s.tokens.add('tok012345');
    await boot(t, s, web: false, shares: shares, store: store);
    shares.ctrl.add('https://music.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s');
    await t.pumpAndSettle();
    expect(find.textContaining('from 90s'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('share-play-now')));
    await t.pumpAndSettle();
    expect(s.count('POST', '/api/play'), 1);
  });

  testWidgets('/setup shows the server URL and a QR code, never the PIN', (t) async {
    final s = FakePiServer();
    await boot(t, s, route: '/setup');
    await enterPin(t, '012345');
    expect(find.byKey(const ValueKey('setup-qr')), findsOneWidget);
    expect(find.text('http://192.168.1.20:8787'), findsWidgets);
    expect(find.textContaining('012345'), findsNothing);
  });
  group('desktop web layout', () {
    testWidgets('wide web viewport: side nav + player and queue side by side; resizing switches layouts', (t) async {
      final s = FakePiServer();
      await boot(t, s, size: const Size(1440, 900));
      await enterPin(t, '012345');
      expect(find.byKey(const ValueKey('layout-desktop')), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('desktop-side-queue')), findsOneWidget);
      expect(find.byKey(const ValueKey('np-toggle')), findsOneWidget);
      // The player card uses the width: artwork and controls side by side.
      final title = t.getRect(find.byKey(const ValueKey('np-title')));
      final toggle = t.getRect(find.byKey(const ValueKey('np-toggle')));
      expect(title.left, greaterThan(600));
      expect(toggle.width, 76);

      // Library on desktop: grid with the player beside it.
      await t.tap(find.text('Library'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('lib-item-f1')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-side-player')), findsOneWidget);

      // Narrow the browser: the phone layout, same tab.
      t.view.physicalSize = const Size(420, 900) * 2.5;
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('layout-compact')), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('Film One'), findsOneWidget, reason: 'still on the Library tab');

      t.view.physicalSize = const Size(1200, 800) * 2.5;
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('layout-desktop')), findsOneWidget);
    });

    testWidgets('just under the breakpoint stays compact; Android stays compact at any width', (t) async {
      final s = FakePiServer();
      await boot(t, s, size: const Size(999, 900));
      await enterPin(t, '012345');
      expect(find.byKey(const ValueKey('layout-compact')), findsOneWidget);
    });

    testWidgets('Android tablet width keeps the stacked layout', (t) async {
      final s = FakePiServer();
      final store = MemorySettingsStore();
      await boot(t, s, web: false, store: store, size: const Size(1280, 800));
      await t.enterText(find.byKey(const ValueKey('server-address')), '192.168.1.20');
      await t.tap(find.byKey(const ValueKey('server-connect')));
      await t.pumpAndSettle();
      await enterPin(t, '012345');
      expect(find.byKey(const ValueKey('layout-compact')), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });
  });

  group('library Back goes up one folder', () {
    FakePiServer nested() => FakePiServer()
      ..folders = true
      ..files = [
        {'id': 'k1', 'title': 'Cartoon', 'path': 'Movies/Kids/Cartoon.mkv', 'folder': 'Movies/Kids', 'size': 1},
        {'id': 'm1', 'title': 'Drama', 'path': 'Movies/Drama.mkv', 'folder': 'Movies', 'size': 1},
      ];

    for (final web in [true, false]) {
      testWidgets('${web ? 'browser' : 'Android system'} Back: Kids -> Movies -> root -> leaves', (t) async {
        final s = nested();
        await boot(t, s, web: web);
        if (!web) {
          await t.enterText(find.byKey(const ValueKey('server-address')), '192.168.1.20');
          await t.tap(find.byKey(const ValueKey('server-connect')));
          await t.pumpAndSettle();
        }
        await enterPin(t, '012345');
        await t.tap(find.text('Library'));
        await t.pumpAndSettle();
        await t.tap(find.text('Movies'));
        await t.pumpAndSettle();
        await t.tap(find.text('Kids'));
        await t.pumpAndSettle();
        expect(find.text('Cartoon'), findsOneWidget);

        // Back (system / browser) is delivered as a route pop.
        expect(await t.binding.handlePopRoute(), isTrue);
        await t.pumpAndSettle();
        expect(find.text('Drama'), findsOneWidget, reason: 'up to Movies');
        expect(find.text('Cartoon'), findsNothing);
        expect(find.text('Kids'), findsOneWidget);

        expect(await t.binding.handlePopRoute(), isTrue);
        await t.pumpAndSettle();
        expect(find.text('Movies'), findsOneWidget, reason: 'up to the library root');
        expect(find.text('Drama'), findsNothing);

        // At the root Back is not consumed: the existing leave/exit behavior.
        expect(await t.binding.handlePopRoute(), isFalse);
      });
    }

    testWidgets('Back on another tab is not swallowed by the library', (t) async {
      final s = nested();
      await boot(t, s);
      await enterPin(t, '012345');
      await t.tap(find.text('Library'));
      await t.pumpAndSettle();
      await t.tap(find.text('Movies'));
      await t.pumpAndSettle();
      await t.tap(find.text('History'));
      await t.pumpAndSettle();
      expect(await t.binding.handlePopRoute(), isFalse);
    });
  });

  testWidgets('resolution labels in the library list and on now playing', (t) async {
    final s = FakePiServer()
      ..files = [
        {'id': 'u', 'title': 'Ultra', 'path': 'Ultra.mkv', 'folder': '', 'size': 1, 'width': 3840, 'height': 2160},
        {'id': 'h', 'title': 'Hd', 'path': 'Hd.mkv', 'folder': '', 'size': 1, 'width': 1280, 'height': 720},
        {'id': 'w', 'title': 'Scope', 'path': 'Scope.mkv', 'folder': '', 'size': 1, 'width': 1920, 'height': 800},
        {'id': 'n', 'title': 'Unknown', 'path': 'Unknown.mkv', 'folder': '', 'size': 1},
      ];
    await boot(t, s);
    await enterPin(t, '012345');
    await t.tap(find.text('Library'));
    await t.pumpAndSettle();
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1920×800'), findsOneWidget);
    await t.tap(find.text('Ultra'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('lib-play-now')));
    await t.pumpAndSettle();
    await t.tap(find.text('Now playing').first);
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byType(Card), matching: find.byKey(const ValueKey('res-4K'))), findsWidgets);
  });

  testWidgets('a playlist URL is sent with list= kept and shows as one playlist item', (t) async {
    final s = FakePiServer();
    await boot(t, s);
    await enterPin(t, '012345');
    await t.enterText(
        find.byKey(const ValueKey('url-input')), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc123&index=2');
    await t.tap(find.byKey(const ValueKey('url-play')));
    await t.pumpAndSettle();
    final play = s.requests.lastWhere((r) => r.url.path == '/api/play');
    expect(play.body, contains('list=PLabc123'));
    expect(find.text('Playlist 1/5'), findsOneWidget);
    // Next is available inside the playlist even with an empty queue.
    await t.pump(const Duration(seconds: 6));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('np-next')));
    await t.tap(find.byKey(const ValueKey('np-next')));
    await t.pumpAndSettle();
    expect(s.requests.where((r) => r.url.path == '/api/control').single.body, contains('"action":"next"'));
  });
}
