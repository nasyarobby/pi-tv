/// HTTP + WebSocket client for the Pi TV server, used by both remotes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'ws_connect_stub.dart'
    if (dart.library.io) 'ws_connect_io.dart'
    if (dart.library.js_interop) 'ws_connect_web.dart';

/// Name of the HTTP-only session cookie set by `POST /api/login`.
const String sessionCookieName = 'pitv_session';

class PiTvApiException implements Exception {
  PiTvApiException(this.statusCode, this.message, {this.retryAfterSeconds});
  final int statusCode;
  final String message;
  final int? retryAfterSeconds;

  bool get isUnauthorized => statusCode == 401;
  bool get isLockedOut => statusCode == 429;

  @override
  String toString() => 'PiTvApiException($statusCode, $message)';
}

class LoginResult {
  const LoginResult(this.token, this.expiresAt);
  final String token;
  final DateTime? expiresAt;
}

/// Thin typed wrapper over the server API.
///
/// On Android set [token] after login; it is sent as `Authorization: Bearer`.
/// On the web leave [token] null: the browser sends the HTTP-only cookie.
class PiTvClient {
  PiTvClient(this.baseUri, {this.token, http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final Uri baseUri;
  String? token;
  final http.Client _http;

  Map<String, String> get authHeaders => token == null ? const {} : {'Authorization': 'Bearer $token'};

  Uri _u(String path, [Map<String, String>? query]) {
    final base = baseUri.path.endsWith('/') ? baseUri.path.substring(0, baseUri.path.length - 1) : baseUri.path;
    return baseUri.replace(path: '$base$path', queryParameters: query == null || query.isEmpty ? null : query);
  }

  /// Absolute URL for a server-relative or absolute thumbnail.
  String? resolveThumbnail(String? thumb) {
    if (thumb == null || thumb.isEmpty) return null;
    if (thumb.startsWith('http://') || thumb.startsWith('https://')) return thumb;
    return _u(thumb).toString();
  }

  Future<Object?> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, _u(path, query));
    req.headers.addAll(authHeaders);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _http.send(req));
    Object? decoded;
    if (res.body.isNotEmpty) {
      try {
        decoded = jsonDecode(res.body);
      } on FormatException {
        decoded = null;
      }
    }
    if (res.statusCode >= 400) {
      final msg = decoded is Map && decoded['error'] is String ? decoded['error'] as String : 'HTTP ${res.statusCode}';
      throw PiTvApiException(res.statusCode, msg, retryAfterSeconds: int.tryParse(res.headers['retry-after'] ?? ''));
    }
    return decoded;
  }

  Map<String, Object?> _map(Object? o) => o is Map ? o.cast<String, Object?>() : <String, Object?>{};

  Future<bool> health() async {
    final j = _map(await _send('GET', '/api/health'));
    return j['ok'] == true;
  }

  /// Logs in with the six digit PIN. Stores and returns the session token.
  Future<LoginResult> login(String pin) async {
    final j = _map(await _send('POST', '/api/login', body: {'pin': pin}));
    token = j['token'] as String?;
    return LoginResult(token ?? '', DateTime.tryParse(j['expiresAt'] as String? ?? ''));
  }

  Future<void> logout() async {
    await _send('POST', '/api/logout');
    token = null;
  }

  Future<NowPlaying> status() async => NowPlaying.fromJson(_map(await _send('GET', '/api/status')));

  Future<NowPlaying> play(PlayRequest request) async =>
      NowPlaying.fromJson(_map(_map(await _send('POST', '/api/play', body: request.toJson()))['status']));

  Future<NowPlaying> control(ControlAction action, [Object? value]) async {
    final j =
        _map(await _send('POST', '/api/control', body: {'action': action.name, if (value != null) 'value': value}));
    return NowPlaying.fromJson(_map(j['status']));
  }

  Future<List<MediaItem>> queue() async => _items(await _send('GET', '/api/queue'));

  /// Moves the item with [id] to [index].
  Future<List<MediaItem>> moveQueueItem(String id, int index) async =>
      _items(await _send('PUT', '/api/queue', body: {'id': id, 'index': index}));

  /// Replaces the queue order with [ids] (must be a permutation).
  Future<List<MediaItem>> reorderQueue(List<String> ids) async =>
      _items(await _send('PUT', '/api/queue', body: {'order': ids}));

  Future<List<MediaItem>> removeQueueItem(String id) async =>
      _items(await _send('DELETE', '/api/queue/${Uri.encodeComponent(id)}'));

  Future<List<MediaItem>> clearQueue() async => _items(await _send('DELETE', '/api/queue'));

  List<MediaItem> _items(Object? o) =>
      [for (final i in (_map(o)['items'] as List? ?? const [])) MediaItem.fromJson((i as Map).cast<String, Object?>())];

  Future<LibraryListing> library({String path = '', String? query}) async =>
      LibraryListing.fromJson(_map(await _send('GET', '/api/library', query: {
        if (path.isNotEmpty) 'path': path,
        if (query != null && query.isNotEmpty) 'q': query,
      })));

  /// Asks the server to scan the configured media directories again.
  Future<RescanResult> rescan() async => RescanResult.fromJson(_map(await _send('POST', '/api/library/rescan')));

  Future<List<HistoryEntry>> history() async => [
        for (final i in (_map(await _send('GET', '/api/history'))['items'] as List? ?? const []))
          HistoryEntry.fromJson((i as Map).cast<String, Object?>())
      ];

  Future<SetupInfo> setupInfo() async => SetupInfo.fromJson(_map(await _send('GET', '/api/setup-info')));

  /// WebSocket URL for live status.
  Uri get wsUri => _u('/ws').replace(scheme: baseUri.scheme == 'https' ? 'wss' : 'ws');

  /// Opens the live status socket. On IO platforms the token is sent as an
  /// `Authorization` header; on the web the browser sends the session cookie.
  WebSocketChannel openSocket() => connectWebSocket(wsUri, authHeaders);

  /// Decoded stream of server events from an open socket.
  static Stream<ServerEvent> events(WebSocketChannel channel) => channel.stream
      .map((m) {
        if (m is! String) return null;
        final d = jsonDecode(m);
        return d is Map ? ServerEvent.fromJson(d.cast<String, Object?>()) : null;
      })
      .where((e) => e != null)
      .cast<ServerEvent>();

  /// Sends a control message over an open socket.
  static void sendControl(WebSocketChannel channel, ControlAction action, [Object? value]) =>
      channel.sink.add(jsonEncode({'type': 'control', 'action': action.name, if (value != null) 'value': value}));

  void close() => _http.close();
}
