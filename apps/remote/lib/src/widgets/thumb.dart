import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';

/// Thumbnail for a queue/library/history item (auth header on Android).
class MediaThumb extends StatelessWidget {
  const MediaThumb({super.key, this.url, this.kind, this.width = 96, this.height = 54});
  final String? url;
  final MediaKind? kind;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final resolved = app.resolveThumbnail(url);
    final fallback = Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(kind == MediaKind.local ? Icons.movie_outlined : Icons.smart_display_outlined),
    );
    if (resolved == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        resolved,
        width: width,
        height: height,
        fit: BoxFit.cover,
        // i.ytimg.com sends no CORS headers; fall back to an <img> element on web.
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        headers: app.imageHeaders.isEmpty ? null : app.imageHeaders,
        errorBuilder: (context, error, stack) => fallback,
      ),
    );
  }
}

String formatDuration(double? seconds) {
  if (seconds == null || seconds.isNaN || seconds < 0) return '--:--';
  final s = seconds.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}
