import 'dart:async';

import 'package:pi_tv_shared/pi_tv_shared.dart';

import 'cec.dart';
import 'inhibit.dart';
import 'log.dart';
import 'players/player.dart';
import 'store.dart';

/// Resolves a [MediaItem] into what a player should load.
typedef TargetResolver = PlayTarget? Function(MediaItem item);

class PlaybackException implements Exception {
  PlaybackException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Queue, now playing and history; decides which player is active.
///
/// Rules (spec §3, §5, §7, §15):
/// * one item plays at a time; switching kinds closes the player being left;
/// * when an item ends the next queued item starts; when the queue is empty
///   the window stays open on the ended item (no related autoplay);
/// * Stop pauses and keeps the window; only [close] tears windows down.
class PlaybackController {
  PlaybackController({
    required Map<MediaKind, Player> players,
    required this.resolve,
    ScreenInhibitor? inhibitor,
    TvControl? tv,
    JsonStore? queueStore,
    JsonStore? historyStore,
    this.historyLimit = 100,
    DateTime Function()? clock,
  })  : _players = players,
        _inhibitor = inhibitor ?? NoopInhibitor(),
        _tv = tv ?? NoopTvControl(),
        _queueStore = queueStore ?? JsonStore(null),
        _historyStore = historyStore ?? JsonStore(null),
        _clock = clock ?? DateTime.now {
    for (final pl in players.values) {
      _subs.add(pl.snapshots.listen((s) => _onSnapshot(pl, s)));
    }
    _restore();
  }

  final Map<MediaKind, Player> _players;
  final TargetResolver resolve;
  final ScreenInhibitor _inhibitor;
  final TvControl _tv;
  final JsonStore _queueStore;
  final JsonStore _historyStore;
  final int historyLimit;
  final DateTime Function() _clock;
  final _log = Log('playback');
  final List<StreamSubscription<PlayerSnapshot>> _subs = [];

  final List<MediaItem> _queue = [];
  final List<HistoryEntry> _history = [];

  /// Items played before the current one (for Previous).
  final List<MediaItem> _previous = [];
  MediaItem? _current;
  Player? _active;
  PlaybackState _state = PlaybackState.idle;
  int _idCounter = 0;
  bool _advancing = false;
  Future<void> _ops = Future.value();

  final _status = StreamController<NowPlaying>.broadcast();
  final _queueChanges = StreamController<List<MediaItem>>.broadcast();
  final _historyChanges = StreamController<void>.broadcast();

  Stream<NowPlaying> get statusChanges => _status.stream;
  Stream<List<MediaItem>> get queueChanges => _queueChanges.stream;
  Stream<void> get historyChanges => _historyChanges.stream;

  List<MediaItem> get queue => List.unmodifiable(_queue);
  List<HistoryEntry> get history => List.unmodifiable(_history);
  MediaItem? get current => _current;
  PlaybackState get state => _state;
  Player? get activePlayer => _active;

  bool get windowOpen => _players.values.any((p) => p.isOpen);

  String newItemId() => '${_clock().microsecondsSinceEpoch.toRadixString(36)}-${(_idCounter++).toRadixString(36)}';

  NowPlaying get status {
    final s = _active?.snapshot;
    return NowPlaying(
      item: _current,
      state: _state,
      positionSeconds: s?.position ?? 0,
      durationSeconds: s?.duration ?? _current?.durationSeconds,
      volume: s?.volume ?? 100,
      muted: s?.muted ?? false,
      queueLength: _queue.length,
      windowOpen: windowOpen,
      subtitles: _current?.kind == MediaKind.local ? s?.subtitles : null,
      canPrevious: _previous.isNotEmpty,
    );
  }

  /// Serialises state-changing operations.
  Future<T> _serial<T>(Future<T> Function() op) {
    final c = Completer<T>();
    _ops = _ops.then((_) async {
      try {
        c.complete(await op());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  void _restore() {
    final q = _queueStore.read();
    if (q is List) {
      for (final i in q) {
        if (i is Map) _queue.add(MediaItem.fromJson(i.cast<String, Object?>()));
      }
    }
    final h = _historyStore.read();
    if (h is List) {
      for (final i in h) {
        if (i is Map) _history.add(HistoryEntry.fromJson(i.cast<String, Object?>()));
      }
    }
  }

  void _queueChanged() {
    _queueStore.write([for (final i in _queue) i.toJson()]);
    if (!_queueChanges.isClosed) _queueChanges.add(queue);
    _publish();
  }

  void _publish() {
    if (!_status.isClosed) _status.add(status);
  }

  Future<void> _setState(PlaybackState s) async {
    _state = s;
    if (s == PlaybackState.playing || s == PlaybackState.loading) {
      await _guard(_inhibitor.acquire, 'inhibit');
    } else {
      await _guard(_inhibitor.release, 'release inhibit');
    }
    _publish();
  }

  Future<void> _guard(Future<void> Function() f, String what) async {
    try {
      await f();
    } catch (e) {
      _log.warn('$what failed: $e');
    }
  }

  void _onSnapshot(Player p, PlayerSnapshot s) {
    if (!identical(p, _active)) {
      _publish();
      return;
    }
    if (!s.open) {
      // Window closed outside our control (crash or user closed it on the Pi).
      if (_state != PlaybackState.idle) {
        _log.info('${p.kind.name} window went away');
        _active = null;
        unawaited(_setState(PlaybackState.idle));
      }
      return;
    }
    final cur = _current;
    if (cur != null &&
        s.title != null &&
        cur.kind == MediaKind.youtube &&
        cur.title != s.title &&
        cur.title.startsWith('YouTube ')) {
      _current = cur.copyWith(title: s.title);
    }
    if (_state == PlaybackState.loading) {
      _publish();
      return;
    }
    if (s.ended && (_state == PlaybackState.playing || _state == PlaybackState.paused)) {
      unawaited(_onEnded());
      return;
    }
    if (_state == PlaybackState.playing && s.paused && !s.ended) {
      unawaited(_setState(PlaybackState.paused));
      return;
    }
    if ((_state == PlaybackState.paused || _state == PlaybackState.stopped || _state == PlaybackState.ended) &&
        !s.paused &&
        !s.ended) {
      unawaited(_setState(PlaybackState.playing));
      return;
    }
    _publish();
  }

  Future<void> _onEnded() async {
    if (_advancing) return;
    _advancing = true;
    try {
      await _serial(() async {
        if (_queue.isNotEmpty) {
          _log.info('item ended; playing next in queue');
          final next = _queue.removeAt(0);
          _queueChanged();
          await _start(next);
        } else {
          _log.info('item ended; queue empty, leaving the window open');
          await _setState(PlaybackState.ended);
        }
      });
    } finally {
      _advancing = false;
    }
  }

  void _addHistory(MediaItem item) {
    _history.insert(0, HistoryEntry(item: item, playedAt: _clock()));
    if (_history.length > historyLimit) _history.removeRange(historyLimit, _history.length);
    _historyStore.write([for (final h in _history) h.toJson()]);
    if (!_historyChanges.isClosed) _historyChanges.add(null);
  }

  /// Starts [item] now. Must run inside [_serial].
  Future<void> _start(MediaItem item, {bool recordPrevious = true}) async {
    final target = resolve(item);
    if (target == null) throw PlaybackException('Cannot play "${item.title}": file is no longer in the library');
    final player = _players[item.kind];
    if (player == null) throw PlaybackException('No player for ${item.kind.name}');
    // Switching YouTube <-> local closes the player being left.
    for (final other in _players.values) {
      if (!identical(other, player) && other.isOpen) {
        _log.info('switching to ${item.kind.name}: closing ${other.kind.name} player');
        await other.close();
      }
    }
    final prev = _current;
    if (recordPrevious && prev != null) _previous.add(prev);
    _current = item;
    _active = player;
    await _setState(PlaybackState.loading);
    unawaited(_tv.wakeAndSelect().catchError((Object e) => _log.warn('CEC failed: $e')));
    try {
      await player.load(target);
    } catch (e) {
      _log.error('could not start ${item.title}', e);
      await _setState(player.isOpen ? PlaybackState.stopped : PlaybackState.idle);
      throw PlaybackException('Could not start playback: $e');
    }
    _addHistory(item);
    await _setState(PlaybackState.playing);
  }

  /// Play now (replaces the current item; the queue is kept).
  Future<void> playNow(MediaItem item) => _serial(() => _start(item));

  /// Adds to the end of the queue. Starts it right away if nothing is
  /// loaded or the last item has ended.
  Future<void> enqueue(MediaItem item) => _serial(() async {
        if (_state == PlaybackState.idle || _state == PlaybackState.ended) {
          await _start(item);
        } else {
          _queue.add(item);
          _queueChanged();
        }
      });

  Future<bool> next() => _serial(() async {
        if (_queue.isEmpty) return false;
        final n = _queue.removeAt(0);
        _queueChanged();
        await _start(n);
        return true;
      });

  /// Previous: restart the current item if it is past 5 s, otherwise go
  /// back to the item played before it (the current one returns to the
  /// front of the queue).
  Future<void> previous() => _serial(() async {
        final pos = _active?.snapshot.position ?? 0;
        if (_previous.isEmpty || pos > 5) {
          if (_active != null && _current != null) {
            await _active!.seek(0);
            if (_state != PlaybackState.playing) {
              await _active!.play();
              await _setState(PlaybackState.playing);
            }
          }
          return;
        }
        final back = _previous.removeLast();
        final cur = _current;
        if (cur != null) {
          _queue.insert(0, cur);
          _queueChanged();
        }
        await _start(back, recordPrevious: false);
      });

  Future<void> play() => _serial(() async {
        final p = _active;
        if (p == null || !p.isOpen) {
          final cur = _current;
          if (cur != null) await _start(cur, recordPrevious: false);
          return;
        }
        await p.play();
        await _setState(PlaybackState.playing);
      });

  Future<void> pause() => _serial(() async {
        final p = _active;
        if (p == null) return;
        await p.pause();
        if (_state == PlaybackState.playing || _state == PlaybackState.loading) {
          await _setState(PlaybackState.paused);
        }
      });

  Future<void> toggle() => _state == PlaybackState.playing ? pause() : play();

  /// Stop: pause, keep the window open, release the screen inhibit.
  Future<void> stop() => _serial(() async {
        final p = _active;
        if (p == null) return;
        await p.stop();
        if (_state != PlaybackState.ended) await _setState(PlaybackState.stopped);
      });

  /// Close: the only user action that tears the TV window down.
  Future<void> close() => _serial(() async {
        for (final p in _players.values) {
          if (p.isOpen) {
            _log.info('closing ${p.kind.name} player (Close from remote)');
            await p.close();
          }
        }
        _active = null;
        _current = null;
        await _setState(PlaybackState.idle);
      });

  Future<void> seek(double seconds) => _serial(() async {
        await _active?.seek(seconds);
        if (_state == PlaybackState.ended) await _setState(PlaybackState.paused);
      });

  Future<void> seekRelative(double delta) =>
      seek(((_active?.snapshot.position ?? 0) + delta).clamp(0, double.infinity).toDouble());

  Future<void> setVolume(double v) => _serial(() async => _active?.setVolume(v.clamp(0, 100).toDouble()));
  Future<void> setMuted(bool m) => _serial(() async => _active?.setMuted(m));
  Future<void> toggleMute() => setMuted(!(_active?.snapshot.muted ?? false));
  Future<bool?> toggleSubtitles() => _serial(() async => _active?.toggleSubtitles());

  /// Manual fullscreen toggle: only for an open YouTube (Chromium) player;
  /// a no-op for local files (mpv) or when nothing is open.
  Future<void> toggleFullscreen() => _serial(() async {
        final a = _active;
        if (a == null || a.kind != MediaKind.youtube || !a.isOpen) return;
        await a.toggleFullscreen();
      });

  // ---- queue editing ----

  void moveInQueue(String id, int index) {
    final from = _queue.indexWhere((i) => i.id == id);
    if (from < 0) throw PlaybackException('No queue item $id');
    final item = _queue.removeAt(from);
    _queue.insert(index.clamp(0, _queue.length), item);
    _queueChanged();
  }

  void reorderQueue(List<String> ids) {
    final byId = {for (final i in _queue) i.id: i};
    if (ids.length != byId.length || !ids.every(byId.containsKey) || ids.toSet().length != ids.length) {
      throw PlaybackException('order must list every queue item id exactly once');
    }
    _queue
      ..clear()
      ..addAll(ids.map((id) => byId[id]!));
    _queueChanged();
  }

  bool removeFromQueue(String id) {
    final before = _queue.length;
    _queue.removeWhere((i) => i.id == id);
    if (_queue.length == before) return false;
    _queueChanged();
    return true;
  }

  void clearQueue() {
    _queue.clear();
    _queueChanged();
  }

  /// Server shutdown: release the inhibit, leave windows as they are.
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _guard(_inhibitor.release, 'release inhibit');
    await _status.close();
    await _queueChanges.close();
    await _historyChanges.close();
  }
}
