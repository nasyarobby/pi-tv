/// Parses YouTube links (and messy share text containing one) into a video
/// id and/or playlist id, plus an optional start time and playlist index.
library;

/// A YouTube video, a playlist, or a video inside a playlist.
///
/// A playlist is one item in the Pi TV queue: the TV opens [watchUrl] with
/// `list=` (and `index`) kept, and YouTube plays through the playlist.
class YouTubeLink {
  const YouTubeLink(this.videoId, {this.startSeconds, this.playlistId, this.playlistIndex})
      : assert(videoId != null || playlistId != null);

  /// A playlist without a specific video (`youtube.com/playlist?list=`).
  const YouTubeLink.playlist(String this.playlistId, {this.playlistIndex})
      : videoId = null,
        startSeconds = null;

  /// The 11 character YouTube video id (`null` for a bare playlist link).
  final String? videoId;

  /// Start offset in seconds, if the link carried a timestamp.
  final int? startSeconds;

  /// The `list=` playlist id, if any.
  final String? playlistId;

  /// The `index=` position inside the playlist (YouTube's 1-based value).
  final int? playlistIndex;

  bool get isPlaylist => playlistId != null;

  /// The URL the TV opens. `list` and `index` are kept; a playlist is never
  /// rewritten as a bare single-video `watch?v=` link (spec §5.4):
  /// * video + playlist: `watch?v=<id>&list=<list>[&index=<n>][&t=<s>s]`
  /// * playlist only: `playlist?list=<list>`
  /// * video only: `watch?v=<id>[&t=<s>s]`
  Uri get watchUrl {
    final v = videoId;
    if (v == null) {
      return Uri.https('www.youtube.com', '/playlist', {
        'list': playlistId!,
        if (playlistIndex != null) 'index': '$playlistIndex',
      });
    }
    return Uri.https('www.youtube.com', '/watch', {
      'v': v,
      if (playlistId != null) 'list': playlistId!,
      if (playlistId != null && playlistIndex != null) 'index': '$playlistIndex',
      if (startSeconds != null && startSeconds! > 0) 't': '${startSeconds}s',
    });
  }

  /// Playlist page URL (`playlist?list=`), or `null` for a single video.
  Uri? get playlistUrl => playlistId == null ? null : Uri.https('www.youtube.com', '/playlist', {'list': playlistId!});

  /// Default thumbnail served by YouTube's image CDN (`null` for a bare
  /// playlist link, which has no video id).
  String? get thumbnailUrl => videoId == null ? null : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

  /// Short human label: `youtu.be/<id>`, `Playlist <list>` or both.
  String get shortLabel {
    final parts = <String>[
      if (videoId != null) 'youtu.be/$videoId',
      if (playlistId != null) 'playlist $playlistId${playlistIndex != null ? ' #$playlistIndex' : ''}',
      if (startSeconds != null) 'from ${startSeconds}s',
    ];
    return parts.join(' · ');
  }

  /// Same link with a different start time.
  YouTubeLink withStart(int? seconds) => videoId == null
      ? this
      : YouTubeLink(videoId, startSeconds: seconds, playlistId: playlistId, playlistIndex: playlistIndex);

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final RegExp _listPattern = RegExp(r'^[A-Za-z0-9_-]{2,80}$');

  /// Hosts that are accepted as YouTube (exact match after lower-casing).
  static const Set<String> hosts = {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'www.youtu.be',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  };

  /// True when [id] has the shape of a YouTube video id.
  static bool isValidVideoId(String id) => _idPattern.hasMatch(id);

  /// True when [id] has the shape of a YouTube playlist id (`PL…`, `RD…`,
  /// `OLAK5uy_…`, `UU…`, …).
  static bool isValidPlaylistId(String id) => _listPattern.hasMatch(id);

  /// True when [host] is one of the accepted YouTube hosts.
  static bool isYouTubeHost(String host) => hosts.contains(host.toLowerCase());

  /// Extracts the first YouTube video or playlist link from [text].
  ///
  /// [text] may be a bare URL, a URL without a scheme, or share text such as
  /// `"Great song - YouTube https://youtu.be/abc?t=42"`. Returns `null` when
  /// no supported YouTube URL is found. Non-YouTube URLs are rejected.
  static YouTubeLink? parse(String text) {
    for (final candidate in _candidates(text)) {
      final link = parseUrl(candidate);
      if (link != null) return link;
    }
    return null;
  }

  /// Like [parse] but throws [FormatException] when nothing is found.
  static YouTubeLink parseOrThrow(String text) {
    final link = parse(text);
    if (link == null) {
      throw const FormatException('Not a supported YouTube video or playlist link');
    }
    return link;
  }

  /// Parses a single URL string (scheme optional).
  static YouTubeLink? parseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'https://$s';
    final Uri uri;
    try {
      uri = Uri.parse(s);
    } on FormatException {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final host = uri.host.toLowerCase();
    if (!isYouTubeHost(host)) return null;

    final segments = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    String? id;
    if (host.endsWith('youtu.be')) {
      if (segments.isNotEmpty) id = segments.first;
    } else if (segments.isNotEmpty && segments.first == 'watch') {
      id = uri.queryParameters['v'];
    } else if (segments.length >= 2 && const {'shorts', 'embed', 'live', 'v', 'e'}.contains(segments.first)) {
      id = segments[1];
    } else if (segments.isEmpty || segments.first == 'watch_videos') {
      id = uri.queryParameters['v'];
    }
    // `embed/videoseries?list=` is a playlist embed; "videoseries" happens
    // to have the shape of a video id.
    if (id == 'videoseries' || (id != null && !isValidVideoId(id))) id = null;

    // Playlist: `list=` on watch/share/embed URLs, or `/playlist?list=`.
    // (`embed/videoseries?list=` has no video id.)
    String? list = uri.queryParameters['list'];
    final playlistPage = segments.isNotEmpty && segments.first == 'playlist';
    final videoseries = segments.length >= 2 && segments.first == 'embed' && segments[1] == 'videoseries';
    if (list != null && !isValidPlaylistId(list)) list = null;
    if (id == null && !(playlistPage || videoseries || segments.isEmpty || segments.first == 'watch')) list = null;
    if (id == null && list == null) return null;

    final index = int.tryParse(uri.queryParameters['index'] ?? '');
    final playlistIndex = list != null && index != null && index > 0 ? index : null;
    if (id == null) return YouTubeLink.playlist(list!, playlistIndex: playlistIndex);
    return YouTubeLink(id, startSeconds: _startFrom(uri), playlistId: list, playlistIndex: playlistIndex);
  }

  static int? _startFrom(Uri uri) {
    final q = uri.queryParameters;
    for (final key in const ['t', 'start', 'time_continue']) {
      final v = q[key];
      if (v != null) {
        final secs = parseTimestamp(v);
        if (secs != null) return secs;
      }
    }
    // Fragment form: #t=1m30s
    final frag = uri.fragment;
    if (frag.isNotEmpty) {
      final m = RegExp(r'(?:^|&)(?:t|start)=([^&]+)').firstMatch(frag);
      if (m != null) return parseTimestamp(m.group(1)!);
    }
    return null;
  }

  /// Parses YouTube timestamp formats: `90`, `90s`, `1m30s`, `1h2m3s`,
  /// `01:30`, `1:02:03`. Returns `null` for anything else.
  static int? parseTimestamp(String value) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return null;
    final plain = RegExp(r'^(\d+)s?$').firstMatch(v);
    if (plain != null) return int.parse(plain.group(1)!);
    final hms = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$').firstMatch(v);
    if (hms != null && (hms.group(1) != null || hms.group(2) != null)) {
      final h = int.parse(hms.group(1) ?? '0');
      final m = int.parse(hms.group(2) ?? '0');
      final s = int.parse(hms.group(3) ?? '0');
      return h * 3600 + m * 60 + s;
    }
    final colon = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{2})$').firstMatch(v);
    if (colon != null) {
      final h = int.parse(colon.group(1) ?? '0');
      return h * 3600 + int.parse(colon.group(2)!) * 60 + int.parse(colon.group(3)!);
    }
    return null;
  }

  static final RegExp _token = RegExp(r'''[^\s<>"'`]+''');
  static const String _trailing = '.,;:!?)]}»”’…';

  static Iterable<String> _candidates(String text) sync* {
    for (final m in _token.allMatches(text)) {
      var t = m.group(0)!;
      // Share text sometimes wraps links in brackets or ends with punctuation.
      while (t.isNotEmpty && '([{«“‘'.contains(t[0])) {
        t = t.substring(1);
      }
      while (t.isNotEmpty && _trailing.contains(t[t.length - 1])) {
        t = t.substring(0, t.length - 1);
      }
      final lower = t.toLowerCase();
      if (lower.contains('youtu')) yield t;
    }
  }

  Map<String, Object?> toJson() => {
        if (videoId != null) 'videoId': videoId,
        if (startSeconds != null) 'startSeconds': startSeconds,
        if (playlistId != null) 'playlistId': playlistId,
        if (playlistIndex != null) 'playlistIndex': playlistIndex,
      };

  @override
  bool operator ==(Object other) =>
      other is YouTubeLink &&
      other.videoId == videoId &&
      other.startSeconds == startSeconds &&
      other.playlistId == playlistId &&
      other.playlistIndex == playlistIndex;

  @override
  int get hashCode => Object.hash(videoId, startSeconds, playlistId, playlistIndex);

  @override
  String toString() =>
      'YouTubeLink($videoId, start: $startSeconds${playlistId != null ? ', list: $playlistId, index: $playlistIndex' : ''})';
}
