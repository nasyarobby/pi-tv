import 'dart:async';

import 'package:pi_tv_shared/pi_tv_shared.dart';

/// Point-in-time state reported by a player.
class PlayerSnapshot {
  const PlayerSnapshot({
    this.open = false,
    this.position = 0,
    this.duration,
    this.paused = true,
    this.ended = false,
    this.volume = 100,
    this.muted = false,
    this.title,
    this.subtitles,
  });

  /// Whether the player window (Chromium / mpv) is up.
  final bool open;
  final double position;
  final double? duration;
  final bool paused;
  final bool ended;
  final double volume;
  final bool muted;
  final String? title;
  final bool? subtitles;

  PlayerSnapshot copyWith({
    bool? open,
    double? position,
    double? duration,
    bool? paused,
    bool? ended,
    double? volume,
    bool? muted,
    String? title,
    bool? subtitles,
  }) =>
      PlayerSnapshot(
        open: open ?? this.open,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        paused: paused ?? this.paused,
        ended: ended ?? this.ended,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
        title: title ?? this.title,
        subtitles: subtitles ?? this.subtitles,
      );

  @override
  String toString() =>
      'PlayerSnapshot(open: $open, pos: $position/$duration, paused: $paused, ended: $ended, vol: $volume)';
}

/// What a player is asked to load.
class PlayTarget {
  const PlayTarget.youtube(YouTubeLink this.link)
      : filePath = null,
        startSeconds = null;
  const PlayTarget.file(String this.filePath, {this.startSeconds}) : link = null;
  final YouTubeLink? link;
  final String? filePath;
  final int? startSeconds;
}

/// A TV player (Chromium for YouTube, mpv for local files).
abstract class Player {
  MediaKind get kind;

  /// Whether the player's window is currently open.
  bool get isOpen;

  PlayerSnapshot get snapshot;

  /// Emits whenever the snapshot changes (position ticks included).
  Stream<PlayerSnapshot> get snapshots;

  /// Opens the window if needed (reusing it if already open) and starts
  /// playing [target] fullscreen.
  Future<void> load(PlayTarget target);

  Future<void> play();
  Future<void> pause();

  /// Stop = pause and keep the window open.
  Future<void> stop();
  Future<void> seek(double seconds);
  Future<void> setVolume(double volume);
  Future<void> setMuted(bool muted);

  /// Toggles subtitles; returns the new visibility when known.
  Future<bool?> toggleSubtitles();

  /// Exits fullscreen and tears the window down. Only called for an explicit
  /// Close from a remote, or when switching to the other player.
  Future<void> close();

  /// Releases resources without closing the window (server shutdown).
  Future<void> dispose();
}
