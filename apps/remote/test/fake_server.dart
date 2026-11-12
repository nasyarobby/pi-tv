import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pi_tv_remote/src/app_controller.dart';
import 'package:pi_tv_remote/src/platform/settings_store.dart';
import 'package:pi_tv_remote/src/platform/share_source.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// In-memory Pi TV server behind a MockClient.
class FakePiServer {
  String pin = '012345';
  final List<http.Request> requests = [];
  final Set<String> tokens = {};
  List<Map<String, Object?>> files = [
    {
      'id': 'f1',
      'title': 'Film One',
      'path': 'Movies/Film One.mkv',
      'folder': 'Movies',
      'size': 1,
      'hasThumbnail': false
    },
  ];
  List<Map<String, Object?>> pendingFiles = [];
  NowPlaying status = const NowPlaying();
  final List<Map<String, Object?>> queue = [];

  bool _authed(http.Request r) {
    final a = r.headers['Authorization'];
    return a != null && tokens.contains(a.substring(7));
  }

  http.Response _j(Object o, [int code = 200]) => http.Response(jsonEncode(o), code);

  late final http.Client client = MockClient((r) async {
    requests.add(r);
    final path = r.url.path;
    if (path == '/api/health') return _j({'ok': true});
    if (path == '/api/login') {
      final p = (jsonDecode(r.body) as Map)['pin'];
      if (p == pin) {
        tokens.add('tok$pin');
        return _j({'token': 'tok$pin'});
      }
      return _j({'error': 'Wrong PIN'}, 401);
    }
    if (!_authed(r)) return _j({'error': 'PIN login required'}, 401);
    switch ((r.method, path)) {
      case ('GET', '/api/status'):
        return _j(status.toJson());
      case ('GET', '/api/queue'):
        return _j({'items': queue});
      case ('GET', '/api/history'):
        return _j({'items': []});
      case ('GET', '/api/setup-info'):
        return _j({
          'url': 'http://192.168.1.20:8787',
          'candidates': ['http://192.168.1.20:8787']
        });
      case ('GET', '/api/library'):
        final q = r.url.queryParameters['q'];
        final items = q == null
            ? files
            : files.where((f) => (f['title'] as String).toLowerCase().contains(q.toLowerCase())).toList();
        return _j({'path': '', 'folders': [], 'items': items, 'total': files.length});
      case ('POST', '/api/library/rescan'):
        files = [...files, ...pendingFiles];
        pendingFiles = [];
        return _j({'total': files.length, 'skipped': 0, 'scannedAt': '2026-11-12T00:00:00Z'});
      case ('POST', '/api/play'):
        final body = (jsonDecode(r.body) as Map).cast<String, Object?>();
        final req = PlayRequest.fromJson(body);
        final link = req.url == null ? null : YouTubeLink.parse(req.url!);
        if (req.url != null && link == null) return _j({'error': 'Not a YouTube video link'}, 400);
        final item = MediaItem(
          id: 'i${requests.length}',
          kind: link != null ? MediaKind.youtube : MediaKind.local,
          title: link != null ? 'YouTube ${link.videoId}' : 'Film One',
          source: link?.videoId ?? req.localPath!,
        );
        if (req.mode == PlayMode.queue) {
          queue.add(item.toJson());
        } else {
          status = NowPlaying(item: item, state: PlaybackState.playing, windowOpen: true, durationSeconds: 100);
        }
        return _j({'item': item.toJson(), 'status': status.copyWith(queueLength: queue.length).toJson()});
      case ('POST', '/api/control'):
        final a = (jsonDecode(r.body) as Map)['action'];
        if (a == 'stop') status = status.copyWith(state: PlaybackState.stopped);
        if (a == 'close') status = const NowPlaying();
        return _j({'ok': true, 'status': status.toJson()});
    }
    return _j({'error': 'nope'}, 404);
  });

  int count(String method, String path) => requests.where((r) => r.method == method && r.url.path == path).length;
}

class FakeSocket with StreamChannelMixin<dynamic> implements WebSocketChannel {
  final _ctrl = StreamChannelController<dynamic>();
  @override
  Stream<dynamic> get stream => _ctrl.foreign.stream;
  @override
  WebSocketSink get sink => _Sink(_ctrl.foreign.sink);
  @override
  Future<void> get ready => Future.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

class _Sink extends DelegatingStreamSink<dynamic> implements WebSocketSink {
  _Sink(super.sink);
  @override
  Future<void> close([int? closeCode, String? closeReason]) => super.close();
}

class FakeShareSource implements ShareSource {
  FakeShareSource([this.initial]);
  final String? initial;
  final ctrl = StreamController<String>.broadcast();
  @override
  Future<String?> initialShare() async => initial;
  @override
  Stream<String> get shares => ctrl.stream;
}

AppController makeController(FakePiServer server, {bool web = true, SettingsStore? store, ShareSource? shares}) =>
    AppController(
      store: store ?? MemorySettingsStore(),
      isWeb: web,
      webOrigin: Uri.parse('http://192.168.1.20:8787'),
      shareSource: shares,
      clientFactory: (b, t) => PiTvClient(b, token: t, httpClient: server.client),
      socketOpener: (_) => FakeSocket(),
    );
