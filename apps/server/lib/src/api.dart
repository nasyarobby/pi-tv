import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth.dart';
import 'library/library_service.dart';
import 'log.dart';
import 'playback.dart';
import 'youtube_meta.dart';

const String serverVersion = '0.1.0';

Response _json(Object? body, {int status = 200, Map<String, String>? headers}) => Response(status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...?headers});

Response _error(int status, String message, {Map<String, String>? headers}) =>
    _json({'error': message}, status: status, headers: headers);

class _BadRequest implements Exception {
  _BadRequest(this.message);
  final String message;
}

/// Origin URLs for the QR code / setup page.
typedef SetupInfoProvider = Future<SetupInfo> Function(Request request);

/// HTTP + WebSocket API (spec §11) and the static web remote.
class PiTvApi {
  PiTvApi({
    required this.auth,
    required this.playback,
    required this.library,
    YouTubeTitleLookup? titles,
    this.webDir,
    SetupInfoProvider? setupInfo,
    this.secureCookie = false,
  })  : titles = titles ?? NoTitleLookup(),
        _setupInfo = setupInfo ?? defaultSetupInfo(8787);

  final AuthService auth;
  final PlaybackController playback;
  final LibraryService library;
  final YouTubeTitleLookup titles;
  final String? webDir;
  final SetupInfoProvider _setupInfo;
  final bool secureCookie;
  final _log = Log('api');
  final Set<WebSocketChannel> _sockets = {};

  static const publicApiPaths = {'api/login', 'api/health'};

  int get socketCount => _sockets.length;

  static String remoteAddress(Request r) {
    final info = r.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    final test = r.context['pitv.remote'];
    return test is String ? test : 'unknown';
  }

  static String? tokenFrom(Request r) {
    final auth = r.headers['authorization'];
    if (auth != null && auth.toLowerCase().startsWith('bearer ')) return auth.substring(7).trim();
    final cookie = r.headers['cookie'];
    if (cookie != null) {
      for (final part in cookie.split(';')) {
        final kv = part.trim();
        if (kv.startsWith('$sessionCookieName=')) return kv.substring(sessionCookieName.length + 1);
      }
    }
    return null;
  }

  /// Everything under `/api` and `/ws` needs a session, except login and
  /// health. The static web remote (which contains the login page) is public.
  Middleware get authMiddleware => (inner) => (request) {
        final path = request.url.path;
        final protected = path == 'ws' || path.startsWith('ws/') || path == 'api' || path.startsWith('api/');
        if (!protected || publicApiPaths.contains(path)) return inner(request);
        if (!auth.sessions.validate(tokenFrom(request))) {
          return _error(401, 'PIN login required');
        }
        return inner(request);
      };

  Handler get handler {
    final router = Router()
      ..get('/api/health', (Request r) => _json({'ok': true, 'version': serverVersion}))
      ..post('/api/login', _login)
      ..post('/api/logout', _logout)
      ..get('/api/status', (Request r) => _json(playback.status.toJson()))
      ..post('/api/play', _play)
      ..post('/api/control', _control)
      ..get('/api/queue', (Request r) => _queueJson())
      ..put('/api/queue', _reorder)
      ..delete('/api/queue', (Request r) {
        playback.clearQueue();
        return _queueJson();
      })
      ..delete('/api/queue/<id>', (Request r, String id) {
        if (!playback.removeFromQueue(id)) return _error(404, 'not in queue');
        return _queueJson();
      })
      ..get('/api/library', (Request r) {
        final q = r.url.queryParameters;
        return _json(library.listing(path: q['path'] ?? '', query: q['q']).toJson());
      })
      ..post('/api/library/rescan', (Request r) async {
        final res = await library.rescan();
        return _json(res.toJson());
      })
      ..get('/api/thumb/<id>', _thumb)
      ..get(
          '/api/history',
          (Request r) => _json({
                'items': [for (final h in playback.history) h.toJson()]
              }))
      ..get('/api/setup-info', (Request r) async => _json((await _setupInfo(r)).toJson()))
      ..get('/ws', webSocketHandler(_onSocket))
      ..all('/api/<rest|.*>', (Request r) => _error(404, 'no such API route'));

    final static = _staticHandler();
    final cascade = Cascade().add(router.call).add(static).handler;
    return const Pipeline().addMiddleware(_errors).addMiddleware(authMiddleware).addHandler(cascade);
  }

  Middleware get _errors => (inner) => (request) async {
        try {
          return await inner(request);
        } on _BadRequest catch (e) {
          return _error(400, e.message);
        } on PlaybackException catch (e) {
          return _error(409, e.message);
        } on HijackException {
          rethrow;
        } catch (e, st) {
          _log.error('${request.method} /${request.url.path}', e, st);
          return _error(500, 'internal error: $e');
        }
      };

  Handler _staticHandler() {
    final dir = webDir;
    if (dir == null || !Directory(dir).existsSync()) {
      return (Request r) => Response.ok(
          '<!doctype html><title>Pi TV</title><h1>Pi TV server</h1>'
          '<p>The web remote is not installed. Set WEB_DIR to the Flutter web build.</p>',
          headers: {'content-type': 'text/html'});
    }
    final files = createStaticHandler(dir, defaultDocument: 'index.html');
    final index = File(p.join(dir, 'index.html'));
    return (Request r) async {
      final res = await files(r);
      if (res.statusCode != 404) return res;
      // SPA routes (/setup, /queue, ...) fall back to index.html.
      if (p.extension(r.url.path).isEmpty && index.existsSync()) {
        return Response.ok(index.openRead(), headers: {'content-type': 'text/html', 'cache-control': 'no-cache'});
      }
      return res;
    };
  }

  Future<Map<String, Object?>> _body(Request r) async {
    final s = await r.readAsString();
    if (s.trim().isEmpty) return {};
    try {
      final d = jsonDecode(s);
      if (d is Map) return d.cast<String, Object?>();
    } on FormatException {
      // fallthrough
    }
    throw _BadRequest('body must be a JSON object');
  }

  Future<Response> _login(Request r) async {
    final body = await _body(r);
    final pin = body['pin'];
    final outcome = auth.login(pin is String ? pin : null, remoteAddress(r));
    switch (outcome) {
      case LoginOk(:final token, :final expiresAt):
        final maxAge = expiresAt.difference(DateTime.now()).inSeconds;
        return _json({
          'token': token,
          'expiresAt': expiresAt.toUtc().toIso8601String()
        }, headers: {
          'set-cookie': '$sessionCookieName=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=$maxAge'
              '${secureCookie ? '; Secure' : ''}',
        });
      case LoginRejected(:final attemptsLeft):
        return _json({'error': 'Wrong PIN', 'attemptsLeft': attemptsLeft}, status: 401);
      case LoginLockedOut(:final retryAfter):
        return _error(429, 'Too many wrong PINs. Try again in ${(retryAfter.inSeconds / 60).ceil()} min.',
            headers: {'retry-after': '${retryAfter.inSeconds}'});
    }
  }

  Response _logout(Request r) {
    final t = tokenFrom(r);
    if (t != null) auth.sessions.revoke(t);
    return _json({'ok': true},
        headers: {'set-cookie': '$sessionCookieName=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0'});
  }

  /// Builds a queue item from a play request.
  Future<MediaItem> itemFor(PlayRequest req) async {
    if (req.url != null && req.url!.trim().isNotEmpty) {
      final parsed = YouTubeLink.parse(req.url!);
      if (parsed == null) throw _BadRequest('Not a YouTube video link');
      final link = req.startSeconds != null ? YouTubeLink(parsed.videoId, startSeconds: req.startSeconds) : parsed;
      final title = await titles.title(link) ?? 'YouTube ${link.videoId}';
      return MediaItem(
        id: playback.newItemId(),
        kind: MediaKind.youtube,
        title: title,
        source: link.videoId,
        thumbnail: link.thumbnailUrl,
        startSeconds: link.startSeconds,
      );
    }
    if (req.localPath != null && req.localPath!.isNotEmpty) {
      final f = library.resolve(req.localPath!);
      if (f == null) throw _BadRequest('File is not in the media library');
      final e = library.entry(f);
      return MediaItem(
        id: playback.newItemId(),
        kind: MediaKind.local,
        title: e.title,
        source: f.id,
        thumbnail: e.thumbnailPath,
        startSeconds: req.startSeconds,
        durationSeconds: e.durationSeconds,
      );
    }
    throw _BadRequest('Send a url or a localPath');
  }

  Future<Response> _play(Request r) async {
    final req = PlayRequest.fromJson(await _body(r));
    final item = await itemFor(req);
    if (req.mode == PlayMode.queue) {
      await playback.enqueue(item);
    } else {
      await playback.playNow(item);
    }
    return _json({'item': item.toJson(), 'status': playback.status.toJson()});
  }

  Future<void> runControl(ControlAction action, Object? value) async {
    double numeric(Object? v) {
      if (v is num) return v.toDouble();
      throw _BadRequest('${action.name} needs a numeric value');
    }

    switch (action) {
      case ControlAction.play:
        await playback.play();
      case ControlAction.pause:
        await playback.pause();
      case ControlAction.toggle:
        await playback.toggle();
      case ControlAction.stop:
        await playback.stop();
      case ControlAction.close:
        await playback.close();
      case ControlAction.seek:
        await playback.seek(numeric(value));
      case ControlAction.seekRelative:
        await playback.seekRelative(numeric(value));
      case ControlAction.volume:
        await playback.setVolume(numeric(value));
      case ControlAction.mute:
        if (value is bool) {
          await playback.setMuted(value);
        } else {
          await playback.toggleMute();
        }
      case ControlAction.next:
        await playback.next();
      case ControlAction.prev:
        await playback.previous();
      case ControlAction.subtitles:
        await playback.toggleSubtitles();
    }
  }

  Future<Response> _control(Request r) async {
    final body = await _body(r);
    final action = controlActionFromName(body['action']);
    if (action == null) throw _BadRequest('unknown action ${body['action']}');
    await runControl(action, body['value']);
    return _json({'ok': true, 'status': playback.status.toJson()});
  }

  Response _queueJson() => _json({
        'items': [for (final i in playback.queue) i.toJson()]
      });

  Future<Response> _reorder(Request r) async {
    final body = await _body(r);
    final order = body['order'];
    if (order is List) {
      playback.reorderQueue([for (final o in order) '$o']);
    } else if (body['id'] is String && body['index'] is int) {
      playback.moveInQueue(body['id'] as String, body['index'] as int);
    } else {
      throw _BadRequest('send {order: [ids]} or {id, index}');
    }
    return _queueJson();
  }

  Response _thumb(Request r, String id) {
    final f = library.thumbnailFile(id);
    if (f == null || !File(f).existsSync()) return Response.notFound('no thumbnail');
    return Response.ok(File(f).openRead(),
        headers: {'content-type': 'image/jpeg', 'cache-control': 'private, max-age=86400'});
  }

  void _onSocket(WebSocketChannel ch, String? protocol) {
    _sockets.add(ch);
    void send(Object o) {
      try {
        ch.sink.add(jsonEncode(o));
      } catch (_) {}
    }

    send({'type': 'status', 'status': playback.status.toJson()});
    send({
      'type': 'queue',
      'items': [for (final i in playback.queue) i.toJson()]
    });
    final subs = <StreamSubscription<Object?>>[
      playback.statusChanges.listen((s) => send({'type': 'status', 'status': s.toJson()})),
      playback.queueChanges.listen((q) => send({
            'type': 'queue',
            'items': [for (final i in q) i.toJson()]
          })),
      playback.historyChanges.listen((_) => send({'type': 'history'})),
      library.changes.listen((_) => send({'type': 'library', 'total': library.total, 'scanning': library.scanning})),
    ];
    ch.stream.listen((m) async {
      if (m is! String) return;
      try {
        final d = jsonDecode(m);
        if (d is! Map) return;
        if (d['type'] == 'control') {
          final a = controlActionFromName(d['action']);
          if (a == null) throw _BadRequest('unknown action ${d['action']}');
          await runControl(a, d['value']);
        } else if (d['type'] == 'ping') {
          send({'type': 'pong'});
        }
      } on _BadRequest catch (e) {
        send({'type': 'error', 'message': e.message});
      } catch (e) {
        send({'type': 'error', 'message': '$e'});
      }
    }, onDone: () {
      _sockets.remove(ch);
      for (final s in subs) {
        s.cancel();
      }
    });
  }
}

/// Picks the URL shown in the QR code: PUBLIC_URL, else the Host the
/// request used (when it is not localhost), else the first LAN IPv4.
SetupInfoProvider defaultSetupInfo(int port, {String? publicUrl}) => (Request r) async {
      final candidates = <String>[];
      try {
        for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
          for (final a in ni.addresses) {
            if (!a.isLoopback) candidates.add('http://${a.address}:$port');
          }
        }
      } catch (_) {}
      if (publicUrl != null) return SetupInfo(url: publicUrl, candidates: candidates);
      final host = r.headers['host'];
      if (host != null && !host.startsWith('localhost') && !host.startsWith('127.')) {
        return SetupInfo(url: 'http://$host', candidates: candidates);
      }
      return SetupInfo(
          url: candidates.isNotEmpty ? candidates.first : 'http://localhost:$port', candidates: candidates);
    };
