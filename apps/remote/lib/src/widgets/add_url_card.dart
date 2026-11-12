import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';

/// Paste a YouTube video or playlist URL (or share text), then Play now /
/// Add to queue. A playlist is one queue item. [wide] puts the field and
/// both buttons on one row (desktop web layout).
class AddUrlCard extends StatefulWidget {
  const AddUrlCard({super.key, this.wide = false});
  final bool wide;
  @override
  State<AddUrlCard> createState() => _AddUrlCardState();
}

class _AddUrlCardState extends State<AddUrlCard> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) setState(() => _ctrl.text = d!.text!);
  }

  Future<void> _send(PlayMode mode) async {
    final text = _ctrl.text;
    if (YouTubeLink.parse(text) == null) {
      setState(() => _error = 'That is not a YouTube video or playlist link');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = AppScope.read(context);
    try {
      await app.playUrl(text, mode);
      _ctrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(mode == PlayMode.now ? 'Playing on the TV' : 'Added to the queue')));
      }
    } catch (_) {
      if (mounted) setState(() => _error = app.lastError ?? 'Could not send to the TV');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      key: const ValueKey('url-input'),
      controller: _ctrl,
      minLines: 1,
      maxLines: widget.wide ? 1 : 3,
      keyboardType: TextInputType.url,
      onSubmitted: widget.wide && !_busy ? (_) => _send(PlayMode.now) : null,
      decoration: InputDecoration(
        labelText: 'YouTube link, playlist or share text',
        border: const OutlineInputBorder(),
        errorText: _error,
        prefixIcon: widget.wide ? const Icon(Icons.link) : null,
        suffixIcon: IconButton(tooltip: 'Paste', onPressed: _paste, icon: const Icon(Icons.content_paste)),
      ),
    );
    final play = FilledButton.icon(
      key: const ValueKey('url-play'),
      onPressed: _busy ? null : () => _send(PlayMode.now),
      icon: const Icon(Icons.play_arrow),
      label: const Text('Play now'),
    );
    final queue = FilledButton.tonalIcon(
      key: const ValueKey('url-queue'),
      onPressed: _busy ? null : () => _send(PlayMode.queue),
      icon: const Icon(Icons.playlist_add),
      label: const Text('Add to queue'),
    );
    if (widget.wide) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: field),
            const SizedBox(width: 12),
            SizedBox(height: 56, width: 156, child: play),
            const SizedBox(width: 10),
            SizedBox(height: 56, width: 176, child: queue),
          ]),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('url-input'),
              controller: _ctrl,
              minLines: 1,
              maxLines: 3,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'YouTube link or share text',
                border: const OutlineInputBorder(),
                errorText: _error,
                suffixIcon: IconButton(tooltip: 'Paste', onPressed: _paste, icon: const Icon(Icons.content_paste)),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    key: const ValueKey('url-play'),
                    onPressed: _busy ? null : () => _send(PlayMode.now),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play now'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('url-queue'),
                    onPressed: _busy ? null : () => _send(PlayMode.queue),
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Add to queue'),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
