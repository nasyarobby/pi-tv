import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import 'history_view.dart';
import 'library_view.dart';
import 'now_playing_view.dart';
import 'queue_view.dart';

const homeTabs = ['/', '/queue', '/library', '/history'];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tab = widget.initialTab;
  bool _shareOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final share = AppScope.of(context).pendingShare;
    if (share != null && !_shareOpen) {
      _shareOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _confirmShare(share));
    }
  }

  /// Share target confirmation: Play now / Add to queue.
  Future<void> _confirmShare(String text) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final link = YouTubeLink.parse(text);
    final mode = await showModalBottomSheet<PlayMode>(
      context: context,
      isDismissible: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(link == null ? 'Not a YouTube video link' : 'Send to the TV?',
                style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
                link == null
                    ? text
                    : 'youtu.be/${link.videoId}${link.startSeconds != null ? ' from ${link.startSeconds}s' : ''}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),
            if (link != null) ...[
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  key: const ValueKey('share-play-now'),
                  onPressed: () => Navigator.pop(c, PlayMode.now),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play now'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 56,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('share-add-queue'),
                  onPressed: () => Navigator.pop(c, PlayMode.queue),
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Add to queue'),
                ),
              ),
            ],
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          ]),
        ),
      ),
    );
    app.clearShare();
    _shareOpen = false;
    if (mode == null) return;
    try {
      await app.playUrl(text, mode);
      messenger
          .showSnackBar(SnackBar(content: Text(mode == PlayMode.now ? 'Playing on the TV' : 'Added to the queue')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(app.lastError ?? 'Could not send to the TV')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pi TV'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(app.connected ? Icons.wifi : Icons.wifi_off,
                semanticLabel: app.connected ? 'Connected' : 'Disconnected'),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'setup') Navigator.of(context).pushNamed('/setup');
              if (v == 'logout') app.logout();
              if (v == 'server') app.changeServer();
            },
            itemBuilder: (c) => [
              const PopupMenuItem(value: 'setup', child: Text('Set up Android app (QR)')),
              if (!app.isWeb) const PopupMenuItem(value: 'server', child: Text('Change Pi address')),
              const PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: _tab, children: const [NowPlayingView(), QueueView(), LibraryView(), HistoryView()]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Now playing'),
          NavigationDestination(
              icon: Badge(
                  isLabelVisible: app.queue.isNotEmpty,
                  label: Text('${app.queue.length}'),
                  child: const Icon(Icons.queue_music)),
              label: 'Queue'),
          const NavigationDestination(icon: Icon(Icons.video_library_outlined), label: 'Library'),
          const NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}
