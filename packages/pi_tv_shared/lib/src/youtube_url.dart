/// Parses YouTube links (and messy share text containing one) into a video
/// id plus an optional start time.
library;

/// A single YouTube video reference.
class YouTubeLink {
  const YouTubeLink(this.videoId, {this.startSeconds});

  /// The 11 character YouTube video id.
  final String videoId;

  /// Start offset in seconds, if the link carried a timestamp.
  final int? startSeconds;

  /// Canonical watch URL that the TV navigates to.
  Uri get watchUrl => Uri.https('www.youtube.com', '/watch', {
        'v': videoId,
        if (startSeconds != null && startSeconds! > 0) 't': '${startSeconds}s',
      });

  /// Default thumbnail served by YouTube's image CDN.
  String get thumbnailUrl => 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

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

  /// True when [host] is one of the accepted YouTube hosts.
  static bool isYouTubeHost(String host) => hosts.contains(host.toLowerCase());

  /// Extracts the first YouTube video link from [text].
  ///
  /// [text] may be a bare URL, a URL without a scheme, or share text such as
  /// `"Great song - YouTube https://youtu.be/abc?t=42"`. Returns `null` when
  /// no supported YouTube video URL is found. Non-YouTube URLs are rejected.
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
      throw const FormatException('Not a supported YouTube video link');
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
    if (id == null || !isValidVideoId(id)) return null;

    final start = _startFrom(uri);
    return YouTubeLink(id, startSeconds: start);
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

  Map<String, Object?> toJson() => {'videoId': videoId, if (startSeconds != null) 'startSeconds': startSeconds};

  @override
  bool operator ==(Object other) =>
      other is YouTubeLink && other.videoId == videoId && other.startSeconds == startSeconds;

  @override
  int get hashCode => Object.hash(videoId, startSeconds);

  @override
  String toString() => 'YouTubeLink($videoId, start: $startSeconds)';
}
