import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/fakes.dart';

const pin = '012345';

class Harness {
  Harness._(this.server, this.api, this.yt, this.local, this.media, this.web, this.clock);
  final HttpServer server;
  final PiTvApi api;
  final FakePlayer yt;
  final FakePlayer local;
  final Directory media;
  final Directory web;
  final TestClock clock;

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
  Uri u(String path) => base.resolve(path);

  static Future<Harness> start({Handler Function(Handler h)? wrap}) async {
    Log.capture = true;
    final media = Directory.systemTemp.createTempSync('pitv-api-media');
    File(p.join(media.path, 'Movies', 'Film One.mkv'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('x');
    final web = Directory.systemTemp.createTempSync('pitv-web');
    File(p.join(web.path, 'index.html')).writeAsStringSync('<html>remote</html>');
    File(p.join(web.path, 'main.dart.js')).writeAsStringSync('//js');
    final clock = TestClock();
    final yt = FakePlayer(MediaKind.youtube);
    final local = FakePlayer(MediaKind.local);
    final library = LibraryService([media.path]);
    await library.rescan();
    final playback = PlaybackController(
      players: {MediaKind.youtube: yt, MediaKind.local: local},
      resolve: (i) => i.kind == MediaKind.youtube
          ? PlayTarget.youtube(YouTubeLink(i.source))
          : PlayTarget.file(library.byId(i.source)!.absolutePath),
    );
    final api = PiTvApi(
      auth: AuthService(
        pin: pin,
        sessions: SessionStore(),
        limiter: PinAttemptLimiter(clock: () => clock.now),
      ),
      playback: playback,
      library: library,
      webDir: web.path,
      setupInfo: (r) async => const SetupInfo(url: 'http://192.168.1.20:8787'),
    );
    final server = await shelf_io.serve(api.handler, '127.0.0.1', 0);
    return Harness._(server, api, yt, local, media, web, clock);
  }

  Future<void> close() async {
    await server.close(force: true);
    media.deleteSync(recursive: true);
    web.deleteSync(recursive: true);
  }

  Future<http.Response> login(String candidate) =>
      http.post(u('/api/login'), body: jsonEncode({'pin': candidate}), headers: {'content-type': 'application/json'});

  Future<String> token() async => (jsonDecode((await login(pin)).body) as Map)['token'] as String;
}

class TestClock {
  DateTime now = DateTime(2026, 1, 1);
}

void main() {
  late Harness h;
  setUp(() async => h = await Harness.start());
  tearDown(() => h.close());

  group('PIN login', () {
    test('correct 6 digit PIN (leading zero) returns a token and an HTTP-only cookie', () async {
      final r = await h.login(pin);
      expect(r.statusCode, 200);
      final body = jsonDecode(r.body) as Map;
      expect(body['token'], isA<String>());
      final cookie = r.headers['set-cookie']!;
      expect(cookie, startsWith('$sessionCookieName='));
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('SameSite=Strict'));
      expect(cookie, isNot(contains(pin)));
    });

    test('wrong PIN is rejected', () async {
      final r = await h.login('123456');
      expect(r.statusCode, 401);
      expect((jsonDecode(r.body) as Map)['attemptsLeft'], 4);
    });

    test('non 6-digit values are rejected, including the PIN without its leading zero', () async {
      for (final bad in ['12345', '0123456', 'abcdef', '', ' 012345']) {
        final r = await h.login(bad);
        expect(r.statusCode, 401, reason: bad);
        h.api.auth.limiter.recordSuccess('127.0.0.1'); // keep the address unlocked
      }
      final r = await http.post(h.u('/api/login'), body: jsonEncode({'pin': 12345}));
      expect(r.statusCode, 401, reason: 'numbers are not accepted, only a 6 character string');
    });

    test('5 failures lock the address for 5 minutes, even for the right PIN', () async {
      for (var i = 0; i < 4; i++) {
        expect((await h.login('999999')).statusCode, 401);
      }
      final fifth = await h.login('999999');
      expect(fifth.statusCode, 429);
      expect(int.parse(fifth.headers['retry-after']!), 300);
      expect((await h.login(pin)).statusCode, 429);
      h.clock.now = h.clock.now.add(const Duration(minutes: 4, seconds: 59));
      expect((await h.login(pin)).statusCode, 429);
      h.clock.now = h.clock.now.add(const Duration(seconds: 2));
      expect((await h.login(pin)).statusCode, 200);
    });

    test('logout revokes the token', () async {
      final t = await h.token();
      final hdr = {'authorization': 'Bearer $t'};
      expect((await http.get(h.u('/api/status'), headers: hdr)).statusCode, 200);
      await http.post(h.u('/api/logout'), headers: hdr);
      expect((await http.get(h.u('/api/status'), headers: hdr)).statusCode, 401);
    });
  });

  group('authentication required', () {
    final protected = <(String, String)>[
      ('GET', '/api/status'),
      ('POST', '/api/play'),
      ('POST', '/api/control'),
      ('GET', '/api/queue'),
      ('PUT', '/api/queue'),
      ('DELETE', '/api/queue'),
      ('DELETE', '/api/queue/x'),
      ('GET', '/api/library'),
      ('POST', '/api/library/rescan'),
      ('GET', '/api/history'),
      ('GET', '/api/setup-info'),
      ('GET', '/api/thumb/abc'),
      ('GET', '/api/unknown'),
      ('GET', '/ws'),
    ];
    for (final (method, path) in protected) {
      test('$method $path without a session -> 401', () async {
        final r = await http.Response.fromStream(await http.Client().send(http.Request(method, h.u(path))));
        expect(r.statusCode, 401);
      });
    }

    test('a bad token or cookie is rejected', () async {
      expect((await http.get(h.u('/api/status'), headers: {'authorization': 'Bearer nope'})).statusCode, 401);
      expect((await http.get(h.u('/api/status'), headers: {'cookie': '$sessionCookieName=nope'})).statusCode, 401);
    });

    test('PIN in a query string is not accepted', () async {
      expect((await http.get(h.u('/api/status?pin=$pin'))).statusCode, 401);
    });

    test('health check, login page and static files are public', () async {
      expect((await http.get(h.u('/api/health'))).statusCode, 200);
      final index = await http.get(h.u('/'));
      expect(index.statusCode, 200);
      expect(index.body, contains('remote'));
      expect((await http.get(h.u('/main.dart.js'))).statusCode, 200);
      // SPA routes fall back to index.html
      expect((await http.get(h.u('/setup'))).body, contains('remote'));
    });

    test('cookie (web) and bearer token (Android) both work', () async {
      final r = await h.login(pin);
      final cookie = r.headers['set-cookie']!.split(';').first;
      expect((await http.get(h.u('/api/status'), headers: {'cookie': cookie})).statusCode, 200);
      final t = (jsonDecode(r.body) as Map)['token'];
      expect((await http.get(h.u('/api/status'), headers: {'authorization': 'Bearer $t'})).statusCode, 200);
    });
  });

  group('API with a session', () {
    late PiTvClient client;
    setUp(() async {
      client = PiTvClient(h.base);
      await client.login(pin);
    });

    test('play a YouTube share text now, then queue a local file', () async {
      final s = await client.play(const PlayRequest(url: 'Great video https://youtu.be/dQw4w9WgXcQ?t=1m30s'));
      expect(s.kind, MediaKind.youtube);
      expect(s.item!.startSeconds, 90);
      expect(h.yt.loads.single.link!.videoId, 'dQw4w9WgXcQ');
      final film = (await client.library(query: 'film')).items.single;
      final s2 = await client.play(PlayRequest(localPath: film.id, mode: PlayMode.queue));
      expect(s2.queueLength, 1);
      expect((await client.queue()).single.title, 'Film One');
    });

    test('non-YouTube URLs are rejected with 400', () async {
      final e = await client
          .play(const PlayRequest(url: 'https://vimeo.com/1'))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e as PiTvApiException).statusCode, 400);
    });

    test('local paths outside the library are rejected', () async {
      final e = await client
          .play(const PlayRequest(localPath: '/etc/passwd'))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e as PiTvApiException).statusCode, 400);
    });

    test('stop keeps the window, close tears it down', () async {
      await client.play(const PlayRequest(url: 'https://youtu.be/dQw4w9WgXcQ'));
      var s = await client.control(ControlAction.stop);
      expect(s.state, PlaybackState.stopped);
      expect(s.windowOpen, isTrue);
      s = await client.control(ControlAction.close);
      expect(s.windowOpen, isFalse);
      expect(h.yt.closes, 1);
    });

    test('fullscreen control toggles the YouTube player and keeps it open', () async {
      await client.play(const PlayRequest(url: 'https://youtu.be/dQw4w9WgXcQ'));
      final s = await client.control(ControlAction.fullscreen);
      expect(s.windowOpen, isTrue);
      expect(h.yt.calls.where((c) => c == 'fullscreen'), hasLength(1));
      final r =
          await http.post(h.u('/api/control'), headers: client.authHeaders, body: jsonEncode({'action': 'fullscreen'}));
      expect(r.statusCode, 200);
      expect(h.yt.calls.where((c) => c == 'fullscreen'), hasLength(2));
    });

    test('controls validate their values', () async {
      await client.play(const PlayRequest(url: 'https://youtu.be/dQw4w9WgXcQ'));
      expect((await client.control(ControlAction.volume, 40)).volume, 40);
      final e = await client.control(ControlAction.seek, 'x').then<Object?>((_) => null, onError: (Object e) => e);
      expect((e as PiTvApiException).statusCode, 400);
      final r =
          await http.post(h.u('/api/control'), headers: client.authHeaders, body: jsonEncode({'action': 'explode'}));
      expect(r.statusCode, 400);
    });

    test('queue reorder, remove and clear over HTTP', () async {
      await client.play(const PlayRequest(url: 'https://youtu.be/aaaaaaaaaaa'));
      for (final id in ['bbbbbbbbbbb', 'ccccccccccc', 'ddddddddddd']) {
        await client.play(PlayRequest(url: 'https://youtu.be/$id', mode: PlayMode.queue));
      }
      var q = await client.queue();
      q = await client.moveQueueItem(q.last.id, 0);
      expect(q.first.source, 'ddddddddddd');
      q = await client.reorderQueue(q.reversed.map((i) => i.id).toList());
      expect(q.first.source, 'ccccccccccc');
      q = await client.removeQueueItem(q.first.id);
      expect(q, hasLength(2));
      expect(await client.clearQueue(), isEmpty);
    });

    test('history lists played items', () async {
      await client.play(const PlayRequest(url: 'https://youtu.be/aaaaaaaaaaa'));
      final hist = await client.history();
      expect(hist.single.item.source, 'aaaaaaaaaaa');
    });

    test('setup-info gives only the URL, never the PIN', () async {
      final r = await http.get(h.u('/api/setup-info'), headers: client.authHeaders);
      expect(r.body, isNot(contains(pin)));
      expect((await client.setupInfo()).url, 'http://192.168.1.20:8787');
    });

    test('remote-triggered rescan refreshes the library listing', () async {
      expect((await client.library(query: 'new')).items, isEmpty);
      File(p.join(h.media.path, 'Movies', 'New Arrival.mp4')).writeAsStringSync('x');
      // Not visible until a rescan.
      expect((await client.library(query: 'new')).items, isEmpty);
      final res = await client.rescan();
      expect(res.totalItems, 2);
      final after = await client.library(query: 'new');
      expect(after.items.single.title, 'New Arrival');
      final folder = await client.library(path: '${p.basename(h.media.path)}/Movies');
      expect(folder.items.map((i) => i.title), containsAll(['Film One', 'New Arrival']));
    });
  });

  group('WebSocket', () {
    test('rejected without a session', () async {
      final ch = IOWebSocketChannel.connect(h.u('/ws').replace(scheme: 'ws'));
      await expectLater(ch.ready, throwsA(anything));
    });

    test('pushes status, accepts controls and library events (bearer token)', () async {
      final t = await h.token();
      final ch = IOWebSocketChannel.connect(h.u('/ws').replace(scheme: 'ws'), headers: {'authorization': 'Bearer $t'});
      final events = PiTvClient.events(ch).asBroadcastStream();
      final first = await events.first.timeout(const Duration(seconds: 5));
      expect(first, isA<StatusEvent>());

      final client = PiTvClient(h.base, token: t);
      final playing = events.firstWhere((e) => e is StatusEvent && e.status.state == PlaybackState.playing);
      await client.play(const PlayRequest(url: 'https://youtu.be/dQw4w9WgXcQ'));
      expect(((await playing.timeout(const Duration(seconds: 5))) as StatusEvent).status.kind, MediaKind.youtube);

      final stopped = events.firstWhere((e) => e is StatusEvent && e.status.state == PlaybackState.stopped);
      PiTvClient.sendControl(ch, ControlAction.stop);
      final st = (await stopped.timeout(const Duration(seconds: 5))) as StatusEvent;
      expect(st.status.windowOpen, isTrue);

      final lib = events.firstWhere((e) => e is LibraryChangedEvent);
      await client.rescan();
      expect(await lib.timeout(const Duration(seconds: 5)), isA<LibraryChangedEvent>());
      await ch.sink.close();
    });

    test('accepts the session cookie (web)', () async {
      final r = await h.login(pin);
      final cookie = r.headers['set-cookie']!.split(';').first;
      final ch = IOWebSocketChannel.connect(h.u('/ws').replace(scheme: 'ws'), headers: {'cookie': cookie});
      expect(await PiTvClient.events(ch).first.timeout(const Duration(seconds: 5)), isA<StatusEvent>());
      await ch.sink.close();
    });
  });
}
