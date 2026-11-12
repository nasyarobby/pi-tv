import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:test/test.dart';

void main() {
  test('login stores token and sends Authorization afterwards', () async {
    final seen = <http.Request>[];
    final mock = MockClient((req) async {
      seen.add(req);
      if (req.url.path == '/api/login') {
        expect(jsonDecode(req.body), {'pin': '012345'});
        return http.Response(jsonEncode({'token': 'tok'}), 200);
      }
      return http.Response(jsonEncode(const NowPlaying(queueLength: 2).toJson()), 200);
    });
    final c = PiTvClient(Uri.parse('http://pi:8787'), httpClient: mock);
    await c.login('012345');
    expect(c.token, 'tok');
    final s = await c.status();
    expect(s.queueLength, 2);
    expect(seen.last.headers['Authorization'], 'Bearer tok');
    expect(seen.first.headers.containsKey('Authorization'), isFalse);
  });

  test('errors carry status code and retry-after', () async {
    final mock =
        MockClient((req) async => http.Response(jsonEncode({'error': 'locked'}), 429, headers: {'retry-after': '300'}));
    final c = PiTvClient(Uri.parse('http://pi:8787'), httpClient: mock);
    final e = await c.login('000000').then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<PiTvApiException>());
    final ex = e as PiTvApiException;
    expect(ex.isLockedOut, isTrue);
    expect(ex.retryAfterSeconds, 300);
    expect(ex.message, 'locked');
  });

  test('rescan posts to /api/library/rescan', () async {
    late http.Request r;
    final mock = MockClient((req) async {
      r = req;
      return http.Response(jsonEncode({'total': 5, 'skipped': 1, 'scannedAt': '2026-01-01T00:00:00Z'}), 200);
    });
    final res = await PiTvClient(Uri.parse('http://pi:8787'), token: 't', httpClient: mock).rescan();
    expect(r.method, 'POST');
    expect(r.url.path, '/api/library/rescan');
    expect(res.totalItems, 5);
  });

  test('library query parameters and thumbnail resolution', () async {
    late Uri u;
    final mock = MockClient((req) async {
      u = req.url;
      return http.Response(jsonEncode({'path': '', 'folders': [], 'items': []}), 200);
    });
    final c = PiTvClient(Uri.parse('http://pi:8787'), httpClient: mock);
    await c.library(path: 'Movies/Kids', query: 'cat');
    expect(u.queryParameters, {'path': 'Movies/Kids', 'q': 'cat'});
    expect(c.resolveThumbnail('/api/thumb/x'), 'http://pi:8787/api/thumb/x');
    expect(c.resolveThumbnail('https://i.ytimg.com/a.jpg'), 'https://i.ytimg.com/a.jpg');
    expect(c.wsUri.toString(), 'ws://pi:8787/ws');
  });
}
