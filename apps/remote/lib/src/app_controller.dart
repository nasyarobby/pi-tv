import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'platform/settings_store.dart';
import 'platform/share_source.dart';

enum AppPhase { starting, needsServer, needsLogin, ready }

typedef ClientFactory = PiTvClient Function(Uri base, String? token);
typedef SocketOpener = WebSocketChannel Function(PiTvClient client);

/// Normalises what the user typed or scanned into a server origin:
/// `192.168.1.20` -> `http://192.168.1.20:8787`.
Uri? normaliseServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || (u.scheme != 'http' && u.scheme != 'https')) return null;
  return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : 8787);
}

/// App state shared by every screen (one instance per app).
class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.isWeb,
    Uri? webOrigin,
    ShareSource? shareSource,
    ClientFactory? clientFactory,
    SocketOpener? socketOpener,
  })  : _webOrigin = webOrigin,
        _shares = shareSource ?? NoShareSource(),
        _clientFactory = clientFactory ?? ((b, t) => PiTvClient(b, token: t)),
        _openSocket = socketOpener ?? ((c) => c.openSocket());

  final SettingsStore store;
  final bool isWeb;
  final Uri? _webOrigin;
  final ShareSource _shares;
  final ClientFactory _clientFactory;
  final SocketOpener _openSocket;

  AppPhase phase = AppPhase.starting;
  PiTvClient? client;
  Uri? serverUrl;
  NowPlaying status = const NowPlaying();
  List<MediaItem> queue = const [];
  List<HistoryEntry> history = const [];
  bool connected = false;
  String? lastError;

  /// Share text waiting for setup/login or for the user's confirmation.
  String? pendingShare;

  /// Bumped whenever the server says the library changed.
  int libraryVersion = 0;
  bool libraryScanning = false;

  WebSocketChannel? _socket;
  StreamSubscription<ServerEvent>? _socketSub;
  StreamSubscription<String>? _shareSub;
  Timer? _reconnect;
  bool _disposed = false;

  Future<void> init() async {
    _shareSub = _shares.shares.listen(receiveShare);
    final initial = await _shares.initialShare();
    if (initial != null) pendingShare = initial;

    if (isWeb) {
      serverUrl = _webOrigin;
    } else {
      final saved = await store.read(kServerUrl);
      serverUrl = saved == null ? null : Uri.tryParse(saved);
    }
    if (serverUrl == null) {
      _setPhase(AppPhase.needsServer);
      return;
    }
    final token = isWeb ? null : await store.read(kToken);
    client = _clientFactory(serverUrl!, token);
    if (!isWeb && token == null) {
      _setPhase(AppPhase.needsLogin);
      return;
    }
    // Web: the HTTP-only cookie may already hold a session.
    try {
      status = await client!.status();
      await _enterReady();
    } on PiTvApiException catch (e) {
      if (e.isUnauthorized) {
        await store.write(kToken, null);
        client!.token = null;
      } else {
        lastError = e.message;
      }
      _setPhase(AppPhase.needsLogin);
    } catch (e) {
      lastError = 'Cannot reach the Pi at $serverUrl';
      _setPhase(AppPhase.needsLogin);
    }
  }

  void _setPhase(AppPhase p) {
    phase = p;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Android first run: saves the Pi address after a health check.
  Future<String?> setServer(String input) async {
    final u = normaliseServerUrl(input);
    if (u == null) return 'Enter the Pi address, e.g. 192.168.1.20:8787';
    final c = _clientFactory(u, null);
    try {
      final ok = await c.health().timeout(const Duration(seconds: 6));
      if (!ok) return 'That address did not answer like a Pi TV server';
    } catch (_) {
      return 'Cannot reach $u. Check the address and that the phone is on the home Wi-Fi.';
    }
    serverUrl = u;
    client = c;
    await store.write(kServerUrl, u.toString());
    await store.write(kToken, null);
    _setPhase(AppPhase.needsLogin);
    return null;
  }

  /// Back to the address screen (Android).
  Future<void> changeServer() async {
    _closeSocket();
    await store.write(kToken, null);
    _setPhase(AppPhase.needsServer);
  }

  /// Returns an error message, or null on success.
  Future<String?> login(String pin) async {
    if (!isValidPin(pin)) return 'The PIN has 6 digits';
    final c = client;
    if (c == null) return 'No server';
    try {
      final r = await c.login(pin);
      if (!isWeb) await store.write(kToken, r.token);
      lastError = null;
      await _enterReady();
      return null;
    } on PiTvApiException catch (e) {
      if (e.isLockedOut) return e.message;
      if (e.isUnauthorized) return 'Wrong PIN';
      return e.message;
    } catch (_) {
      return 'Cannot reach the Pi';
    }
  }

  Future<void> logout() async {
    try {
      await client?.logout();
    } catch (_) {}
    await store.write(kToken, null);
    _closeSocket();
    _setPhase(AppPhase.needsLogin);
  }

  Future<void> _enterReady() async {
    _setPhase(AppPhase.ready);
    _connectSocket();
    await Future.wait([refreshQueue(), refreshHistory()].map((f) => f.catchError((Object _) {})));
  }

  void _connectSocket() {
    _closeSocket();
    final c = client;
    if (c == null) return;
    try {
      final ch = _openSocket(c);
      _socket = ch;
      _socketSub =
          PiTvClient.events(ch).listen(_onEvent, onDone: _onSocketDone, onError: (Object _) => _onSocketDone());
      ch.ready.then((_) {
        connected = true;
        _notify();
      }, onError: (Object _) => _onSocketDone());
    } catch (_) {
      _onSocketDone();
    }
  }

  void _onSocketDone() {
    if (connected) {
      connected = false;
      _notify();
    }
    if (_disposed || phase != AppPhase.ready) return;
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), () async {
      // A 401 here means the session expired.
      try {
        await client?.status();
        _connectSocket();
      } on PiTvApiException catch (e) {
        if (e.isUnauthorized) {
          await store.write(kToken, null);
          _setPhase(AppPhase.needsLogin);
        } else {
          _onSocketDone();
        }
      } catch (_) {
        _onSocketDone();
      }
    });
  }

  void _closeSocket() {
    _reconnect?.cancel();
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.sink.close();
    _socket = null;
    connected = false;
  }

  void _onEvent(ServerEvent e) {
    switch (e) {
      case StatusEvent(:final status):
        this.status = status;
      case QueueEvent(:final items):
        queue = items;
      case HistoryChangedEvent():
        unawaited(refreshHistory());
      case LibraryChangedEvent(:final scanning):
        libraryScanning = scanning;
        libraryVersion++;
      case ErrorEvent(:final message):
        lastError = message;
    }
    _notify();
  }

  Future<T?> _guard<T>(Future<T> Function(PiTvClient c) f) async {
    final c = client;
    if (c == null) return null;
    try {
      final r = await f(c);
      lastError = null;
      return r;
    } on PiTvApiException catch (e) {
      if (e.isUnauthorized) {
        await store.write(kToken, null);
        _closeSocket();
        _setPhase(AppPhase.needsLogin);
        return null;
      }
      lastError = e.message;
      _notify();
      rethrow;
    }
  }

  Future<void> refreshQueue() async {
    final q = await _guard((c) => c.queue());
    if (q != null) {
      queue = q;
      _notify();
    }
  }

  Future<void> refreshHistory() async {
    final h = await _guard((c) => c.history());
    if (h != null) {
      history = h;
      _notify();
    }
  }

  Future<void> playUrl(String text, PlayMode mode) async {
    final s = await _guard((c) => c.play(PlayRequest(url: text, mode: mode)));
    if (s != null) {
      status = s;
      _notify();
    }
    await refreshQueue();
  }

  Future<void> playLocal(String libraryId, PlayMode mode) async {
    final s = await _guard((c) => c.play(PlayRequest(localPath: libraryId, mode: mode)));
    if (s != null) {
      status = s;
      _notify();
    }
    await refreshQueue();
  }

  /// One-tap replay of a history entry.
  Future<void> replay(MediaItem item, [PlayMode mode = PlayMode.now]) => item.kind == MediaKind.youtube
      ? playUrl(YouTubeLink(item.source, startSeconds: item.startSeconds).watchUrl.toString(), mode)
      : playLocal(item.source, mode);

  Future<void> control(ControlAction action, [Object? value]) async {
    final s = await _guard((c) => c.control(action, value));
    if (s != null) {
      status = s;
      _notify();
    }
  }

  Future<void> moveQueueItem(String id, int index) async {
    final q = await _guard((c) => c.moveQueueItem(id, index));
    if (q != null) {
      queue = q;
      _notify();
    }
  }

  Future<void> removeQueueItem(String id) async {
    final q = await _guard((c) => c.removeQueueItem(id));
    if (q != null) {
      queue = q;
      _notify();
    }
  }

  Future<void> clearQueue() async {
    final q = await _guard((c) => c.clearQueue());
    if (q != null) {
      queue = q;
      _notify();
    }
  }

  Future<LibraryListing?> library({String path = '', String? query}) =>
      _guard((c) => c.library(path: path, query: query));

  /// Rescan from the remote (no shell on the Pi needed).
  Future<RescanResult?> rescan() async {
    libraryScanning = true;
    _notify();
    try {
      final r = await _guard((c) => c.rescan());
      libraryVersion++;
      return r;
    } finally {
      libraryScanning = false;
      _notify();
    }
  }

  Future<SetupInfo?> setupInfo() => _guard((c) => c.setupInfo());

  /// Called for Android shares; held until setup + login are done.
  void receiveShare(String text) {
    pendingShare = text;
    _notify();
  }

  void clearShare() {
    pendingShare = null;
    _notify();
  }

  String? resolveThumbnail(String? thumb) => client?.resolveThumbnail(thumb);
  Map<String, String> get imageHeaders => client?.authHeaders ?? const {};

  @override
  void dispose() {
    _disposed = true;
    _closeSocket();
    _shareSub?.cancel();
    super.dispose();
  }
}
