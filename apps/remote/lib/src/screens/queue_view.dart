import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../widgets/thumb.dart';

class QueueView extends StatelessWidget {
  const QueueView({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final q = app.queue;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            Expanded(child: Text('Up next (${q.length})', style: Theme.of(context).textTheme.titleMedium)),
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
              ? const Center(child: Text('The queue is empty. Use "Add to queue" on a link or a library file.'))
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
                        minVerticalPadding: 12,
                        leading: MediaThumb(url: item.thumbnail, kind: item.kind, width: 80, height: 45),
                        title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(item.kind.name),
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
