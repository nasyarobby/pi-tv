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
    {bool web = true, MemorySettingsStore? store, FakeShareSource? shares, String route = '/'}) async {
  t.view.physicalSize = const Size(1080, 2400);
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
    expect(find.text('That is not a YouTube video link'), findsOneWidget);
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
}
