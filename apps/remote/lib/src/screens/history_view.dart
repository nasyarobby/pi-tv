import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import '../widgets/thumb.dart';

class HistoryView extends StatelessWidget {
  const HistoryView({super.key});

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

  Future<void> _replay(BuildContext context, MediaItem item) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.replay(item);
      messenger.showSnackBar(SnackBar(content: Text('Playing "${item.title}"')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(app.lastError ?? 'Could not replay')));
    }
  }
}
