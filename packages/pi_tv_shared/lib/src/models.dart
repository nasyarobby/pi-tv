/// JSON models exchanged between the Pi TV server and the remotes.
library;

enum MediaKind { youtube, local }

/// High level state of the TV player.
///
/// `stopped` means the user pressed Stop: playback is paused and the window
/// stays open. `ended` means the last item finished and nothing is queued.
enum PlaybackState { idle, loading, playing, paused, stopped, ended }

/// Controls accepted by `POST /api/control` and the WebSocket.
enum ControlAction {
  play,
  pause,
  toggle,
  stop,
  close,
  seek,
  seekRelative,
  volume,
  mute,
  next,
  prev,
  subtitles,
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

MediaKind mediaKindFromName(Object? name) => _enumByName(MediaKind.values, name, MediaKind.youtube);
PlaybackState playbackStateFromName(Object? name) => _enumByName(PlaybackState.values, name, PlaybackState.idle);
ControlAction? controlActionFromName(Object? name) {
  for (final v in ControlAction.values) {
    if (v.name == name) return v;
  }
  return null;
}

double? _toDouble(Object? v) => v is num ? v.toDouble() : null;
int? _toInt(Object? v) => v is num ? v.toInt() : null;

/// One playable item (queue entry, now playing item, history entry).
class MediaItem {
  const MediaItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.source,
    this.thumbnail,
    this.startSeconds,
    this.durationSeconds,
  });

  /// Unique id of this queue/history entry.
  final String id;
  final MediaKind kind;
  final String title;

  /// YouTube video id, or the library id of a local file.
  final String source;

  /// Absolute URL (YouTube) or server-relative path (`/api/thumb/...`).
  final String? thumbnail;
  final int? startSeconds;
  final double? durationSeconds;

  MediaItem copyWith({String? id, String? title, double? durationSeconds, String? thumbnail, int? startSeconds}) =>
      MediaItem(
        id: id ?? this.id,
        kind: kind,
        title: title ?? this.title,
        source: source,
        thumbnail: thumbnail ?? this.thumbnail,
        startSeconds: startSeconds ?? this.startSeconds,
        durationSeconds: durationSeconds ?? this.durationSeconds,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'source': source,
        if (thumbnail != null) 'thumbnail': thumbnail,
        if (startSeconds != null) 'startSeconds': startSeconds,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
      };

  factory MediaItem.fromJson(Map<String, Object?> j) => MediaItem(
        id: j['id'] as String,
        kind: mediaKindFromName(j['kind']),
        title: (j['title'] as String?) ?? '',
        source: (j['source'] as String?) ?? '',
        thumbnail: j['thumbnail'] as String?,
        startSeconds: _toInt(j['startSeconds']),
        durationSeconds: _toDouble(j['durationSeconds']),
      );
}

/// Live status pushed over the WebSocket and returned by `/api/status`.
class NowPlaying {
  const NowPlaying({
    this.item,
    this.state = PlaybackState.idle,
    this.positionSeconds = 0,
    this.durationSeconds,
    this.volume = 100,
    this.muted = false,
    this.queueLength = 0,
    this.windowOpen = false,
    this.subtitles,
    this.canPrevious = false,
  });

  final MediaItem? item;
  final PlaybackState state;
  final double positionSeconds;
  final double? durationSeconds;

  /// 0–100.
  final double volume;
  final bool muted;
  final int queueLength;

  /// Whether our Chromium window or mpv is still open on the TV.
  final bool windowOpen;

  /// Subtitle visibility for local files (`null` when not applicable).
  final bool? subtitles;
  final bool canPrevious;

  MediaKind? get kind => item?.kind;
  bool get isPlaying => state == PlaybackState.playing;

  NowPlaying copyWith({
    MediaItem? item,
    bool clearItem = false,
    PlaybackState? state,
    double? positionSeconds,
    double? durationSeconds,
    bool clearDuration = false,
    double? volume,
    bool? muted,
    int? queueLength,
    bool? windowOpen,
    bool? subtitles,
    bool clearSubtitles = false,
    bool? canPrevious,
  }) =>
      NowPlaying(
        item: clearItem ? null : (item ?? this.item),
        state: state ?? this.state,
        positionSeconds: positionSeconds ?? this.positionSeconds,
        durationSeconds: clearDuration ? null : (durationSeconds ?? this.durationSeconds),
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
        queueLength: queueLength ?? this.queueLength,
        windowOpen: windowOpen ?? this.windowOpen,
        subtitles: clearSubtitles ? null : (subtitles ?? this.subtitles),
        canPrevious: canPrevious ?? this.canPrevious,
      );

  Map<String, Object?> toJson() => {
        'kind': item?.kind.name,
        'title': item?.title,
        'thumbnail': item?.thumbnail,
        'item': item?.toJson(),
        'state': state.name,
        'position': positionSeconds,
        'duration': durationSeconds,
        'volume': volume,
        'muted': muted,
        'queueLength': queueLength,
        'windowOpen': windowOpen,
        'subtitles': subtitles,
        'canPrevious': canPrevious,
      };

  factory NowPlaying.fromJson(Map<String, Object?> j) => NowPlaying(
        item: j['item'] is Map ? MediaItem.fromJson((j['item'] as Map).cast<String, Object?>()) : null,
        state: playbackStateFromName(j['state']),
        positionSeconds: _toDouble(j['position']) ?? 0,
        durationSeconds: _toDouble(j['duration']),
        volume: _toDouble(j['volume']) ?? 100,
        muted: j['muted'] == true,
        queueLength: _toInt(j['queueLength']) ?? 0,
        windowOpen: j['windowOpen'] == true,
        subtitles: j['subtitles'] as bool?,
        canPrevious: j['canPrevious'] == true,
      );
}

class HistoryEntry {
  const HistoryEntry({required this.item, required this.playedAt});
  final MediaItem item;
  final DateTime playedAt;

  Map<String, Object?> toJson() => {'item': item.toJson(), 'playedAt': playedAt.toUtc().toIso8601String()};

  factory HistoryEntry.fromJson(Map<String, Object?> j) => HistoryEntry(
        item: MediaItem.fromJson((j['item'] as Map).cast<String, Object?>()),
        playedAt: DateTime.tryParse(j['playedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// A video file found by the library scanner.
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.title,
    required this.path,
    required this.folder,
    required this.sizeBytes,
    this.durationSeconds,
    this.hasThumbnail = false,
  });

  /// Stable id derived from the absolute path.
  final String id;
  final String title;

  /// Display path relative to the library (`<root>/sub/file.mkv`).
  final String path;

  /// Folder of [path] (`<root>/sub`).
  final String folder;
  final int sizeBytes;
  final double? durationSeconds;
  final bool hasThumbnail;

  String get thumbnailPath => '/api/thumb/$id';

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'folder': folder,
        'size': sizeBytes,
        if (durationSeconds != null) 'duration': durationSeconds,
        'hasThumbnail': hasThumbnail,
      };

  factory LibraryEntry.fromJson(Map<String, Object?> j) => LibraryEntry(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        folder: (j['folder'] as String?) ?? '',
        sizeBytes: _toInt(j['size']) ?? 0,
        durationSeconds: _toDouble(j['duration']),
        hasThumbnail: j['hasThumbnail'] == true,
      );
}

class LibraryFolder {
  const LibraryFolder({required this.name, required this.path, required this.itemCount});
  final String name;
  final String path;

  /// Number of videos anywhere below this folder.
  final int itemCount;

  Map<String, Object?> toJson() => {'name': name, 'path': path, 'count': itemCount};
  factory LibraryFolder.fromJson(Map<String, Object?> j) => LibraryFolder(
        name: (j['name'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        itemCount: _toInt(j['count']) ?? 0,
      );
}

/// Response of `GET /api/library`.
class LibraryListing {
  const LibraryListing({
    required this.path,
    required this.folders,
    required this.items,
    this.query,
    this.scannedAt,
    this.scanning = false,
    this.totalItems = 0,
  });

  /// Folder being listed (`''` for the top level).
  final String path;
  final String? query;
  final List<LibraryFolder> folders;
  final List<LibraryEntry> items;
  final DateTime? scannedAt;
  final bool scanning;
  final int totalItems;

  Map<String, Object?> toJson() => {
        'path': path,
        if (query != null) 'q': query,
        'folders': [for (final f in folders) f.toJson()],
        'items': [for (final i in items) i.toJson()],
        'scannedAt': scannedAt?.toUtc().toIso8601String(),
        'scanning': scanning,
        'total': totalItems,
      };

  factory LibraryListing.fromJson(Map<String, Object?> j) => LibraryListing(
        path: (j['path'] as String?) ?? '',
        query: j['q'] as String?,
        folders: [
          for (final f in (j['folders'] as List? ?? const []))
            LibraryFolder.fromJson((f as Map).cast<String, Object?>())
        ],
        items: [
          for (final i in (j['items'] as List? ?? const [])) LibraryEntry.fromJson((i as Map).cast<String, Object?>())
        ],
        scannedAt: DateTime.tryParse(j['scannedAt'] as String? ?? ''),
        scanning: j['scanning'] == true,
        totalItems: _toInt(j['total']) ?? 0,
      );
}

/// Result of `POST /api/library/rescan`.
class RescanResult {
  const RescanResult({required this.totalItems, required this.skipped, required this.scannedAt});
  final int totalItems;
  final int skipped;
  final DateTime scannedAt;

  Map<String, Object?> toJson() =>
      {'total': totalItems, 'skipped': skipped, 'scannedAt': scannedAt.toUtc().toIso8601String()};
  factory RescanResult.fromJson(Map<String, Object?> j) => RescanResult(
        totalItems: _toInt(j['total']) ?? 0,
        skipped: _toInt(j['skipped']) ?? 0,
        scannedAt: DateTime.tryParse(j['scannedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Body of `POST /api/play`.
class PlayRequest {
  const PlayRequest({this.url, this.localPath, this.startSeconds, this.mode = PlayMode.now});
  final String? url;

  /// Library id (preferred) or an absolute path inside a media directory.
  final String? localPath;
  final int? startSeconds;
  final PlayMode mode;

  Map<String, Object?> toJson() => {
        if (url != null) 'url': url,
        if (localPath != null) 'localPath': localPath,
        if (startSeconds != null) 'startSeconds': startSeconds,
        'mode': mode.name,
      };

  factory PlayRequest.fromJson(Map<String, Object?> j) => PlayRequest(
        url: j['url'] as String?,
        localPath: j['localPath'] as String?,
        startSeconds: _toInt(j['startSeconds']),
        mode: j['mode'] == 'queue' ? PlayMode.queue : PlayMode.now,
      );
}

enum PlayMode { now, queue }

class SetupInfo {
  const SetupInfo({required this.url, this.candidates = const []});

  /// Preferred origin for the QR code, e.g. `http://192.168.1.20:8787`.
  final String url;
  final List<String> candidates;

  Map<String, Object?> toJson() => {'url': url, 'candidates': candidates};
  factory SetupInfo.fromJson(Map<String, Object?> j) => SetupInfo(
        url: (j['url'] as String?) ?? '',
        candidates: [for (final c in (j['candidates'] as List? ?? const [])) c as String],
      );
}

/// Messages pushed by the server over `/ws`.
sealed class ServerEvent {
  const ServerEvent();

  static ServerEvent? fromJson(Map<String, Object?> j) {
    switch (j['type']) {
      case 'status':
        return StatusEvent(NowPlaying.fromJson((j['status'] as Map).cast<String, Object?>()));
      case 'queue':
        return QueueEvent([
          for (final i in (j['items'] as List? ?? const [])) MediaItem.fromJson((i as Map).cast<String, Object?>())
        ]);
      case 'history':
        return const HistoryChangedEvent();
      case 'library':
        return LibraryChangedEvent(totalItems: _toInt(j['total']) ?? 0, scanning: j['scanning'] == true);
      case 'error':
        return ErrorEvent((j['message'] as String?) ?? 'error');
    }
    return null;
  }
}

class StatusEvent extends ServerEvent {
  const StatusEvent(this.status);
  final NowPlaying status;
}

class QueueEvent extends ServerEvent {
  const QueueEvent(this.items);
  final List<MediaItem> items;
}

class HistoryChangedEvent extends ServerEvent {
  const HistoryChangedEvent();
}

class LibraryChangedEvent extends ServerEvent {
  const LibraryChangedEvent({required this.totalItems, required this.scanning});
  final int totalItems;
  final bool scanning;
}

class ErrorEvent extends ServerEvent {
  const ErrorEvent(this.message);
  final String message;
}
