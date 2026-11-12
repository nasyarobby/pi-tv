import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import '../widgets/thumb.dart';

/// Folder browser + filename search + Rescan (asks the Pi to scan again).
class LibraryView extends StatefulWidget {
  const LibraryView({super.key});
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
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
                          subtitle: Text(_query.isEmpty ? formatDuration(e.durationSeconds) : e.folder),
                          onTap: () => _choose(e),
                        ),
                      if (l.folders.isEmpty && l.items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(_query.isEmpty ? 'No videos here. Tap Rescan after adding files.' : 'No matches.',
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
    );
  }
}

/// "1 video" / "3 videos".
String videoCount(int n) => n == 1 ? '1 video' : '$n videos';
