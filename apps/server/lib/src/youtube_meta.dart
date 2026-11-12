import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pi_tv_shared/pi_tv_shared.dart';

/// Looks up a YouTube title for the queue/history (best effort).
abstract class YouTubeTitleLookup {
  Future<String?> title(YouTubeLink link);
}

class NoTitleLookup implements YouTubeTitleLookup {
  @override
  Future<String?> title(YouTubeLink link) async => null;
}

/// Uses YouTube's public oEmbed endpoint (no API key, no login).
class OEmbedTitleLookup implements YouTubeTitleLookup {
  OEmbedTitleLookup({http.Client? client, this.timeout = const Duration(seconds: 4)})
      : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;

  @override
  Future<String?> title(YouTubeLink link) async {
    try {
      final uri = Uri.https('www.youtube.com', '/oembed', {
        'url': YouTubeLink(link.videoId).watchUrl.toString(),
        'format': 'json',
      });
      final r = await _client.get(uri).timeout(timeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      final t = j is Map ? j['title'] : null;
      return t is String && t.isNotEmpty ? t : null;
    } catch (_) {
      return null;
    }
  }
}
