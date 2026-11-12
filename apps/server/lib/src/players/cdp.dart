import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Chrome DevTools Protocol seam: HTTP discovery + a WebSocket session.
abstract class CdpEndpoint {
  /// `/json/version`, or null when nothing listens on the port.
  Future<Map<String, Object?>?> version();

  /// `/json/list`.
  Future<List<Map<String, Object?>>> targets();

  /// `/json/new?<url>` creates a new page target.
  Future<Map<String, Object?>?> newPage(String url);

  Future<CdpSession> connect(String webSocketDebuggerUrl);
}

abstract class CdpSession {
  Future<Map<String, Object?>> send(String method, [Map<String, Object?> params = const {}]);
  Stream<CdpEvent> get events;
  bool get isClosed;
  Future<void> get done;
  Future<void> close();
}

class CdpEvent {
  const CdpEvent(this.method, this.params);
  final String method;
  final Map<String, Object?> params;
}

class CdpException implements Exception {
  CdpException(this.message);
  final String message;
  @override
  String toString() => 'CdpException: $message';
}

/// Real endpoint on `127.0.0.1:<port>`.
class HttpCdpEndpoint implements CdpEndpoint {
  HttpCdpEndpoint(this.port, {this.host = '127.0.0.1'});
  final int port;
  final String host;

  Future<Object?> _get(String path, {String method = 'GET'}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.openUrl(method, Uri.parse('http://$host:$port$path'));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      return jsonDecode(body);
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } on HttpException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Map<String, Object?>?> version() async {
    final v = await _get('/json/version');
    return v is Map ? v.cast<String, Object?>() : null;
  }

  @override
  Future<List<Map<String, Object?>>> targets() async {
    final v = await _get('/json/list');
    if (v is! List) return const [];
    return [
      for (final t in v)
        if (t is Map) t.cast<String, Object?>()
    ];
  }

  @override
  Future<Map<String, Object?>?> newPage(String url) async {
    final v = await _get('/json/new?${Uri.encodeComponent(url)}', method: 'PUT');
    return v is Map ? v.cast<String, Object?>() : null;
  }

  @override
  Future<CdpSession> connect(String webSocketDebuggerUrl) async {
    final ws = await WebSocket.connect(webSocketDebuggerUrl).timeout(const Duration(seconds: 5));
    return WebSocketCdpSession(ws);
  }
}

class WebSocketCdpSession implements CdpSession {
  WebSocketCdpSession(this._ws) {
    _ws.listen(_onMessage, onDone: _onDone, onError: (Object _) => _onDone());
  }
  final WebSocket _ws;
  int _nextId = 1;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final _events = StreamController<CdpEvent>.broadcast();
  final _done = Completer<void>();

  void _onMessage(Object? data) {
    if (data is! String) return;
    final m = jsonDecode(data);
    if (m is! Map) return;
    final id = m['id'];
    if (id is int) {
      final c = _pending.remove(id);
      if (c == null) return;
      if (m['error'] != null) {
        c.completeError(CdpException(jsonEncode(m['error'])));
      } else {
        c.complete(((m['result'] as Map?) ?? const {}).cast<String, Object?>());
      }
    } else if (m['method'] is String) {
      _events.add(CdpEvent(m['method'] as String, ((m['params'] as Map?) ?? const {}).cast<String, Object?>()));
    }
  }

  void _onDone() {
    for (final c in _pending.values) {
      c.completeError(CdpException('connection closed'));
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
    _events.close();
  }

  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<void> get done => _done.future;
  @override
  Stream<CdpEvent> get events => _events.stream;

  @override
  Future<Map<String, Object?>> send(String method, [Map<String, Object?> params = const {}]) {
    if (isClosed) return Future.error(CdpException('connection closed'));
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(id);
      throw CdpException('timeout waiting for $method');
    });
  }

  @override
  Future<void> close() async {
    await _ws.close();
    _onDone();
  }
}
