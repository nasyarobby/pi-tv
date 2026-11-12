import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import '../theme.dart';
import '../widgets/thumb.dart';

/// Recently played. [wide] is the desktop table-like list with type,
/// time, and Play again / Add to queue actions.
class HistoryView extends StatelessWidget {
  const HistoryView({super.key, this.wide = false});
  final bool wide;

  String _when(DateTime t) {
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final h = app.history;
    if (h.isEmpty) return const Center(child: Text('Nothing played yet.'));
    if (wide) return _wide(context, h);
    return RefreshIndicator(
      onRefresh: app.refreshHistory,
      child: ListView.builder(
        itemCount: h.length,
        itemBuilder: (context, i) {
          final e = h[i];
          return ListTile(
            minVerticalPadding: 12,
            leading: MediaThumb(url: e.item.thumbnail, kind: e.item.kind, width: 80, height: 45),
            title: Text(e.item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${e.item.kind == MediaKind.youtube ? 'YouTube' : 'Local'} · ${_when(e.playedAt)}'),
            onTap: () => _replay(context, e.item),
            trailing: IconButton.filledTonal(
              key: ValueKey('replay-$i'),
              iconSize: 30,
              tooltip: 'Play again',
              onPressed: () => _replay(context, e.item),
              icon: const Icon(Icons.replay),
            ),
          );
        },
      ),
    );
  }

  Widget _wide(BuildContext context, List<HistoryEntry> h) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: PiTvColors.textMuted);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        child: Text('History', style: theme.textTheme.headlineSmall),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
        child: DefaultTextStyle.merge(
          style: theme.textTheme.labelMedium?.copyWith(color: PiTvColors.textMuted, letterSpacing: 0.8),
          child: const Row(children: [
            SizedBox(width: 128 + 16),
            Expanded(child: Text('TITLE')),
            SizedBox(width: 120, child: Text('TYPE')),
            SizedBox(width: 110, child: Text('PLAYED')),
            SizedBox(width: 112),
          ]),
        ),
      ),
      const Divider(),
      Expanded(
        child: RefreshIndicator(
          onRefresh: AppScope.read(context).refreshHistory,
          child: ListView.separated(
            itemCount: h.length,
            separatorBuilder: (_, __) => const Divider(indent: 24, endIndent: 24),
            itemBuilder: (context, i) {
              final e = h[i];
              final item = e.item;
              return InkWell(
                onTap: () => _replay(context, item),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  child: Row(children: [
                    MediaThumb(url: item.thumbnail, kind: item.kind, width: 128, height: 72),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(item.title,
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                        if (item.resolution != null || item.isPlaylist) ...[
                          const SizedBox(height: 4),
                          Row(children: [
                            if (item.resolution != null) ResolutionBadge(item.resolution),
                            if (item.isPlaylist) const InfoBadge('Playlist', accent: false, icon: Icons.playlist_play),
                          ]),
                        ],
                      ]),
                    ),
                    SizedBox(
                        width: 120,
                        child: Row(children: [
                          Icon(item.kind == MediaKind.youtube ? Icons.smart_display : Icons.movie,
                              size: 18, color: PiTvColors.textMuted),
                          const SizedBox(width: 6),
                          Text(item.kind == MediaKind.youtube ? 'YouTube' : 'Local', style: muted),
                        ])),
                    SizedBox(width: 110, child: Text(_when(e.playedAt), style: muted)),
                    IconButton.filled(
                      key: ValueKey('replay-$i'),
                      tooltip: 'Play again',
                      onPressed: () => _replay(context, item),
                      icon: const Icon(Icons.replay),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Add to queue',
                      onPressed: () => _replay(context, item, PlayMode.queue),
                      icon: const Icon(Icons.playlist_add),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }

  Future<void> _replay(BuildContext context, MediaItem item, [PlayMode mode = PlayMode.now]) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.replay(item, mode);
      messenger.showSnackBar(
          SnackBar(content: Text(mode == PlayMode.now ? 'Playing "${item.title}"' : 'Added to the queue')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(app.lastError ?? 'Could not replay')));
    }
  }
}
