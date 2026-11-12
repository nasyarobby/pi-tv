import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pi_tv_shared/pi_tv_shared.dart';

/// Title (and thumbnail) for the queue/history.
class YouTubeInfo {
  const YouTubeInfo({this.title, this.thumbnail});
  final String? title;
  final String? thumbnail;
}

/// Looks up a YouTube title for the queue/history (best effort).
abstract class YouTubeTitleLookup {
  Future<YouTubeInfo?> lookup(YouTubeLink link);
}

class NoTitleLookup implements YouTubeTitleLookup {
  @override
  Future<YouTubeInfo?> lookup(YouTubeLink link) async => null;
}

/// Uses YouTube's public oEmbed endpoint (no API key, no login). For a
/// playlist item the playlist's own title is used (oEmbed accepts
/// `playlist?list=` URLs), falling back to the video's.
class OEmbedTitleLookup implements YouTubeTitleLookup {
  OEmbedTitleLookup({http.Client? client, this.timeout = const Duration(seconds: 4)})
      : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;

  @override
  Future<YouTubeInfo?> lookup(YouTubeLink link) async {
    final urls = [
      if (link.playlistUrl != null) link.playlistUrl!,
      if (link.videoId != null) YouTubeLink(link.videoId).watchUrl,
    ];
    for (final url in urls) {
      final info = await _oembed(url);
      if (info != null) return info;
    }
    return null;
  }

  Future<YouTubeInfo?> _oembed(Uri url) async {
    try {
      final uri = Uri.https('www.youtube.com', '/oembed', {'url': url.toString(), 'format': 'json'});
      final r = await _client.get(uri).timeout(timeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      if (j is! Map) return null;
      final t = j['title'];
      final th = j['thumbnail_url'];
      if (t is! String || t.isEmpty) return null;
      return YouTubeInfo(title: t, thumbnail: th is String && th.isNotEmpty ? th : null);
    } catch (_) {
      return null;
    }
  }
}
