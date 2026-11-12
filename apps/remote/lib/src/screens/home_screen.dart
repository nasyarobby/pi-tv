import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import '../theme.dart';
import '../widgets/add_url_card.dart';
import 'history_view.dart';
import 'library_view.dart';
import 'now_playing_view.dart';
import 'queue_view.dart';

const homeTabs = ['/', '/queue', '/library', '/history'];

/// The web remote switches to the desktop layout at this viewport width
/// (logical pixels). Narrower web viewports, and the Android app at any
/// size, keep the stacked phone layout.
const double desktopBreakpoint = 1000;

/// Above this width the desktop side nav shows labels next to the icons.
const double desktopWideBreakpoint = 1320;

/// Width of the desktop side panel (queue next to the player, or the
/// player next to queue / library / history).
const double desktopSidePanel = 380;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tab = widget.initialTab;
  bool _shareOpen = false;

  /// Keeps the library's folder and search when the layout switches.
  final _libraryKey = GlobalKey();

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
            Text(link == null ? 'Not a YouTube video or playlist link' : 'Send to the TV?',
                style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(link == null ? text : link.shortLabel, maxLines: 3, overflow: TextOverflow.ellipsis),
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
    return LayoutBuilder(builder: (context, box) {
      final desktop = app.isWeb && box.maxWidth >= desktopBreakpoint;
      return desktop ? _desktop(context, box.maxWidth) : _compact(context);
    });
  }

  Widget _menu(BuildContext context) {
    final app = AppScope.of(context);
    return PopupMenuButton<String>(
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
    );
  }

  Widget _queueIcon(BuildContext context) {
    final app = AppScope.of(context);
    return Badge(
        isLabelVisible: app.queue.isNotEmpty, label: Text('${app.queue.length}'), child: const Icon(Icons.queue_music));
  }

  /// Phone layout (Android, narrow web): one tab at a time, bottom nav.
  Widget _compact(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      key: const ValueKey('layout-compact'),
      appBar: AppBar(
        title: const Text('Pi TV'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(app.connected ? Icons.wifi : Icons.wifi_off,
                semanticLabel: app.connected ? 'Connected' : 'Disconnected'),
          ),
          _menu(context),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: _tab, children: [
          const NowPlayingView(),
          const QueueView(),
          LibraryView(key: _libraryKey, active: _tab == 2),
          const HistoryView(),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Now playing'),
          NavigationDestination(icon: _queueIcon(context), label: 'Queue'),
          const NavigationDestination(icon: Icon(Icons.video_library_outlined), label: 'Library'),
          const NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }

  /// Desktop web layout: side nav, and every section shares the width with
  /// a side panel: Now playing shows the player wide with the queue beside
  /// it; Queue, Library and History keep a compact player beside them so
  /// playback stays in reach while browsing.
  Widget _desktop(BuildContext context, double width) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final extended = width >= desktopWideBreakpoint;
    // All sections stay mounted (like the phone tab stack) so the library
    // folder, search and scroll survive switching sections.
    final main = IndexedStack(index: _tab, children: [
      ListView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
        children: [
          Text('Now playing', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 16),
          const AddUrlCard(wide: true),
          const SizedBox(height: 20),
          const NowPlayingCard(wide: true),
        ],
      ),
      const QueueView(wide: true),
      LibraryView(key: _libraryKey, active: _tab == 2, grid: true),
      const HistoryView(wide: true),
    ]);
    final side = _tab == 0
        ? const Card(
            key: ValueKey('desktop-side-queue'),
            margin: EdgeInsets.fromLTRB(0, 24, 24, 24),
            clipBehavior: Clip.antiAlias,
            child: QueueView(dense: true))
        : _sidePlayer();
    return Scaffold(
      key: const ValueKey('layout-desktop'),
      body: SafeArea(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NavigationRail(
            key: const ValueKey('desktop-nav'),
            extended: extended,
            minExtendedWidth: 220,
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 20),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: PiTvColors.accentContainer, borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.live_tv, color: PiTvColors.accent),
                ),
                if (extended) ...[
                  const SizedBox(width: 12),
                  Text('Pi TV', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ]),
            ),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Tooltip(
                      message: app.connected ? 'Connected to the Pi' : 'Reconnecting…',
                      child: Icon(app.connected ? Icons.wifi : Icons.wifi_off,
                          color: app.connected ? PiTvColors.accent : theme.colorScheme.error,
                          semanticLabel: app.connected ? 'Connected' : 'Disconnected'),
                    ),
                    const SizedBox(height: 8),
                    _menu(context),
                  ]),
                ),
              ),
            ),
            destinations: [
              const NavigationRailDestination(
                  icon: Icon(Icons.play_circle_outline),
                  selectedIcon: Icon(Icons.play_circle),
                  label: Text('Now playing')),
              NavigationRailDestination(icon: _queueIcon(context), label: const Text('Queue')),
              const NavigationRailDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library),
                  label: Text('Library')),
              const NavigationRailDestination(icon: Icon(Icons.history), label: Text('History')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Center(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1400), child: main),
            ),
          ),
          SizedBox(width: desktopSidePanel, child: side),
        ]),
      ),
    );
  }

  Widget _sidePlayer() => ListView(
        key: const ValueKey('desktop-side-player'),
        padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
        children: const [NowPlayingCard()],
      );
}
