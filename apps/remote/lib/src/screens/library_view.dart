import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import '../theme.dart';
import '../widgets/thumb.dart';

/// Folder browser + filename search + Rescan (asks the Pi to scan again).
///
/// Back (Android system Back, browser back on the web) inside a subfolder
/// goes up one folder; only at the library root does Back fall through to
/// the existing leave/exit behavior. [active] is whether the Library tab is
/// the one showing (the view stays mounted in the tab stack). [grid] shows
/// the wide card grid used by the desktop web layout.
class LibraryView extends StatefulWidget {
  const LibraryView({super.key, this.active = true, this.grid = false});
  final bool active;
  final bool grid;
  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  String _path = '';
  String _query = '';
  LibraryListing? _listing;
  bool _loading = false;
  int _seenVersion = -1;
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = AppScope.of(context).libraryVersion;
    if (v != _seenVersion) {
      _seenVersion = v;
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final l = await AppScope.read(context).library(path: _path, query: _query.isEmpty ? null : _query);
      if (mounted) setState(() => _listing = l);
    } catch (_) {
      // error shown via lastError
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(String path) {
    setState(() => _path = path);
    _load();
  }

  /// One folder up (`Movies/Kids` -> `Movies` -> root).
  void _up() {
    final i = _path.lastIndexOf('/');
    _open(i < 0 ? '' : _path.substring(0, i));
  }

  Future<void> _rescan() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await app.rescan();
      await _load();
      if (r != null) {
        messenger.showSnackBar(SnackBar(
            content: Text(
                'Library rescanned: ${videoCount(r.totalItems)}${r.skipped > 0 ? ', ${r.skipped} unreadable' : ''}')));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(app.lastError ?? 'Rescan failed')));
    }
  }

  Future<void> _choose(LibraryEntry e) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final mode = await showModalBottomSheet<PlayMode>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(e.title, style: Theme.of(c).textTheme.titleMedium), subtitle: Text(e.path)),
          ListTile(
              key: const ValueKey('lib-play-now'),
              leading: const Icon(Icons.play_arrow),
              title: const Text('Play now'),
              onTap: () => Navigator.pop(c, PlayMode.now)),
          ListTile(
              key: const ValueKey('lib-add-queue'),
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to queue'),
              onTap: () => Navigator.pop(c, PlayMode.queue)),
        ]),
      ),
    );
    if (mode == null) return;
    try {
      await app.playLocal(e.id, mode);
      messenger
          .showSnackBar(SnackBar(content: Text(mode == PlayMode.now ? 'Playing on the TV' : 'Added to the queue')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(app.lastError ?? 'Could not play')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final l = _listing;
    final crumbs = _path.isEmpty ? <String>[] : _path.split('/');
    final scanning = app.libraryScanning || (l?.scanning ?? false);
    final pad = widget.grid ? 24.0 : 12.0;
    return PopScope(
      // In a subfolder Back goes up one folder instead of leaving the app.
      canPop: !widget.active || _path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.active && _path.isNotEmpty) _up();
      },
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(pad, widget.grid ? 20 : 12, pad, 0),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('lib-search'),
                  controller: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search by filename',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                              _load();
                            }),
                  ),
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 300), () {
                      setState(() => _query = v.trim());
                      _load();
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('lib-rescan'),
                  onPressed: scanning ? null : _rescan,
                  icon: scanning
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                  label: const Text('Rescan'),
                ),
              ),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pad - 4, vertical: widget.grid ? 6 : 0),
            child: Row(children: [
              if (_path.isNotEmpty)
                IconButton(
                    key: const ValueKey('lib-up'),
                    tooltip: 'Up one folder',
                    onPressed: _up,
                    icon: const Icon(Icons.arrow_upward)),
              TextButton.icon(
                  onPressed: () => _open(''), icon: const Icon(Icons.home_outlined), label: const Text('Library')),
              for (var i = 0; i < crumbs.length; i++) ...[
                const Icon(Icons.chevron_right, size: 18),
                TextButton(onPressed: () => _open(crumbs.sublist(0, i + 1).join('/')), child: Text(crumbs[i])),
              ],
            ]),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: l == null
                ? const SizedBox()
                : widget.grid
                    ? _grid(context, l)
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          children: [
                            if (_query.isEmpty)
                              for (final f in l.folders)
                                ListTile(
                                  minVerticalPadding: 14,
                                  leading: const Icon(Icons.folder, size: 36),
                                  title: Text(f.name),
                                  subtitle: Text(videoCount(f.itemCount)),
                                  onTap: () => _open(f.path),
                                ),
                            for (final e in l.items)
                              ListTile(
                                key: ValueKey('lib-item-${e.id}'),
                                minVerticalPadding: 12,
                                leading: MediaThumb(
                                    url: e.hasThumbnail ? e.thumbnailPath : null,
                                    kind: MediaKind.local,
                                    width: 80,
                                    height: 45),
                                title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                                subtitle: Row(children: [
                                  if (e.resolution != null) ...[
                                    ResolutionBadge(e.resolution),
                                    const SizedBox(width: 8)
                                  ],
                                  Flexible(
                                      child: Text(_query.isEmpty ? formatDuration(e.durationSeconds) : e.folder,
                                          overflow: TextOverflow.ellipsis)),
                                ]),
                                onTap: () => _choose(e),
                              ),
                            if (l.folders.isEmpty && l.items.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Text(
                                    _query.isEmpty ? 'No videos here. Tap Rescan after adding files.' : 'No matches.',
                                    textAlign: TextAlign.center),
                              ),
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text('${videoCount(l.totalItems)} in the library', textAlign: TextAlign.center),
                            ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _quick(LibraryEntry e, PlayMode mode) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.playLocal(e.id, mode);
      messenger
          .showSnackBar(SnackBar(content: Text(mode == PlayMode.now ? 'Playing on the TV' : 'Added to the queue')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(app.lastError ?? 'Could not play')));
    }
  }

  /// Desktop: folders as tiles, videos as 16:9 cards with duration and
  /// resolution on the artwork and Play / Queue buttons.
  Widget _grid(BuildContext context, LibraryListing l) {
    final theme = Theme.of(context);
    final folders = _query.isEmpty ? l.folders : const <LibraryFolder>[];
    return CustomScrollView(slivers: [
      if (folders.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300, mainAxisExtent: 76, crossAxisSpacing: 12, mainAxisSpacing: 12),
            itemCount: folders.length,
            itemBuilder: (c, i) {
              final f = folders[i];
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _open(f.path),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      const Icon(Icons.folder, size: 34, color: PiTvColors.accent),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(f.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                              Text(videoCount(f.itemCount),
                                  style: theme.textTheme.bodySmall?.copyWith(color: PiTvColors.textMuted)),
                            ]),
                      ),
                      const Icon(Icons.chevron_right, color: PiTvColors.textMuted),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 320, childAspectRatio: 1.12, crossAxisSpacing: 16, mainAxisSpacing: 16),
          itemCount: l.items.length,
          itemBuilder: (c, i) {
            final e = l.items[i];
            return Card(
              key: ValueKey('lib-item-${e.id}'),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _choose(e),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(fit: StackFit.expand, children: [
                      LayoutBuilder(
                          builder: (c, box) => MediaThumb(
                              url: e.hasThumbnail ? e.thumbnailPath : null,
                              kind: MediaKind.local,
                              width: box.maxWidth,
                              height: box.maxHeight)),
                      if (e.resolution != null) Positioned(left: 8, top: 8, child: ResolutionBadge(e.resolution)),
                      if (e.durationSeconds != null)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(6)),
                            child: Text(formatDuration(e.durationSeconds),
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                        ),
                    ]),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(e.title,
                                maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                            const SizedBox(height: 2),
                            Text(_query.isEmpty ? _formatSize(e.sizeBytes) : e.folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(color: PiTvColors.textMuted)),
                          ]),
                        ),
                        IconButton(
                            tooltip: 'Play now',
                            color: PiTvColors.accent,
                            onPressed: () => _quick(e, PlayMode.now),
                            icon: const Icon(Icons.play_circle_fill)),
                        IconButton(
                            tooltip: 'Add to queue',
                            onPressed: () => _quick(e, PlayMode.queue),
                            icon: const Icon(Icons.playlist_add)),
                      ]),
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              l.folders.isEmpty && l.items.isEmpty
                  ? (_query.isEmpty ? 'No videos here. Click Rescan after adding files.' : 'No matches.')
                  : '${videoCount(l.totalItems)} in the library',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: PiTvColors.textMuted)),
        ),
      ),
    ]);
  }
}

/// "1 video" / "3 videos".
String videoCount(int n) => n == 1 ? '1 video' : '$n videos';

String _formatSize(int bytes) {
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(0)} MB';
  return '${(bytes / 1e3).toStringAsFixed(0)} KB';
}
