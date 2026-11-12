import 'package:flutter/material.dart';

import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import '../theme.dart';
import '../widgets/thumb.dart';

/// Up next. [wide] is the desktop layout (larger artwork, numbered rows);
/// [dense] is the narrow side panel next to the desktop player.
class QueueView extends StatelessWidget {
  const QueueView({super.key, this.wide = false, this.dense = false});
  final bool wide;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final q = app.queue;
    return Column(
      children: [
        Padding(
          padding: wide ? const EdgeInsets.fromLTRB(24, 20, 16, 8) : const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            Expanded(
                child: Text('Up next (${q.length})',
                    style: wide ? Theme.of(context).textTheme.headlineSmall : Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(
              key: const ValueKey('queue-clear'),
              onPressed: q.isEmpty ? null : () => app.clearQueue().catchError((Object _) {}),
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear'),
            ),
          ]),
        ),
        Expanded(
          child: q.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                        key: ValueKey('queue-empty-hint'),
                        'The queue is empty. Use "Add to queue" on a link or a library file.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: PiTvColors.textMuted)),
                  ),
                )
              : ReorderableListView.builder(
                  itemCount: q.length,
                  buildDefaultDragHandles: false,
                  onReorderItem: (from, to) => app.moveQueueItem(q[from].id, to).catchError((Object _) {}),
                  itemBuilder: (context, i) {
                    final item = q[i];
                    return Dismissible(
                      key: ValueKey('queue-${item.id}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Theme.of(context).colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Icon(Icons.delete),
                      ),
                      onDismissed: (_) => app.removeQueueItem(item.id).catchError((Object _) {}),
                      child: ListTile(
                        minVerticalPadding: wide ? 14 : 12,
                        contentPadding: wide ? const EdgeInsets.symmetric(horizontal: 24) : null,
                        leading: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (wide)
                            SizedBox(
                                width: 32,
                                child: Text('${i + 1}',
                                    style: const TextStyle(color: PiTvColors.textMuted, fontWeight: FontWeight.w600))),
                          MediaThumb(
                              url: item.thumbnail,
                              kind: item.kind,
                              width: wide ? 128 : (dense ? 64 : 80),
                              height: wide ? 72 : (dense ? 36 : 45)),
                        ]),
                        title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Row(children: [
                          if (item.resolution != null) ...[ResolutionBadge(item.resolution), const SizedBox(width: 6)],
                          if (item.isPlaylist) ...[
                            const InfoBadge('Playlist', accent: false, icon: Icons.playlist_play),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                              child: Text(
                                  wide
                                      ? '${item.kind == MediaKind.youtube ? 'YouTube' : 'Local file'}'
                                          '${item.durationSeconds != null ? ' · ${formatDuration(item.durationSeconds)}' : ''}'
                                      : item.kind.name,
                                  overflow: TextOverflow.ellipsis)),
                        ]),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: 'Remove',
                            onPressed: () => app.removeQueueItem(item.id).catchError((Object _) {}),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.drag_handle)),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
