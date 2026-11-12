import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../app_scope.dart';
import '../theme.dart';
import '../widgets/add_url_card.dart';
import '../widgets/thumb.dart';

/// Phone / narrow layout of the Now playing tab: link card + player card.
class NowPlayingView extends StatelessWidget {
  const NowPlayingView({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: const [AddUrlCard(), SizedBox(height: 16), NowPlayingCard()],
      );
}

/// The player card: artwork, title, state, scrubber, transport, volume,
/// Stop and Close. [wide] lays it out side by side for the desktop web
/// layout; the default is the stacked phone card.
class NowPlayingCard extends StatefulWidget {
  const NowPlayingCard({super.key, this.wide = false});
  final bool wide;
  @override
  State<NowPlayingCard> createState() => _NowPlayingCardState();
}

class _NowPlayingCardState extends State<NowPlayingCard> {
  double? _dragPos;
  double? _dragVol;

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppScope.read(context).lastError ?? '$e')));
    }
  }

  Future<void> _confirmClose() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Close the player on the TV?'),
        content: const Text('This exits fullscreen and closes the YouTube window or mpv. The TV stays on.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('confirm-close'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Close')),
        ],
      ),
    );
    if (ok == true) await _run(() => AppScope.read(context).control(ControlAction.close));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.status;
    final item = s.item;
    final theme = Theme.of(context);
    final wide = widget.wide;
    final dur = s.durationSeconds ?? 0;
    final pos = (_dragPos ?? s.positionSeconds).clamp(0, dur > 0 ? dur : 0).toDouble();
    final stateLabel = switch (s.state) {
      PlaybackState.idle => 'Nothing playing',
      PlaybackState.loading => 'Loading…',
      PlaybackState.playing => 'Playing',
      PlaybackState.paused => 'Paused',
      PlaybackState.stopped => 'Stopped (window open)',
      PlaybackState.ended => 'Ended (window open)',
    };
    Widget big(IconData icon, String tip, VoidCallback? onTap, {Key? key, bool primary = false}) => Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 6 : 4),
          child: SizedBox(
            width: primary ? 76 : 56,
            height: primary ? 76 : 56,
            child: primary
                ? FilledButton(
                    key: key,
                    onPressed: onTap,
                    style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                    child: Icon(icon, size: 44, semanticLabel: tip))
                : IconButton.filledTonal(
                    key: key,
                    style: secondaryRoundStyle(),
                    onPressed: onTap,
                    tooltip: tip,
                    iconSize: 32,
                    icon: Icon(icon, semanticLabel: tip)),
          ),
        );
    final has = item != null && s.windowOpen;
    final playlist = item?.isPlaylist == true;

    final art = AspectRatio(
      aspectRatio: 16 / 9,
      child: item == null
          ? Container(
              decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.tv_off, size: 64, color: PiTvColors.textMuted))
          : LayoutBuilder(
              builder: (c, box) =>
                  MediaThumb(url: item.thumbnail, kind: item.kind, width: box.maxWidth, height: box.maxHeight)),
    );
    final title = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (item != null)
        Padding(
          padding: const EdgeInsets.only(right: 8, top: 2),
          child: Icon(
              item.kind == MediaKind.youtube ? (playlist ? Icons.playlist_play : Icons.smart_display) : Icons.movie),
        ),
      Expanded(
        child: Text(item?.title ?? 'Nothing playing',
            key: const ValueKey('np-title'),
            style: wide ? theme.textTheme.headlineSmall : theme.textTheme.titleLarge,
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ),
    ]);
    final meta = Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (s.resolution != null) ResolutionBadge(s.resolution),
      if (playlist)
        InfoBadge(
          s.playlistPosition != null && s.playlistLength != null
              ? 'Playlist ${s.playlistPosition}/${s.playlistLength}'
              : 'Playlist',
          key: const ValueKey('np-playlist'),
          icon: Icons.playlist_play,
          accent: false,
        ),
      Text(
          '$stateLabel · queue ${s.queueLength}${s.windowOpen ? '' : ' · TV window closed'}'
          '${app.connected ? '' : ' · reconnecting…'}',
          key: const ValueKey('np-state'),
          style: theme.textTheme.bodyMedium?.copyWith(color: PiTvColors.textMuted)),
    ]);
    final scrubber = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Slider(
        key: const ValueKey('np-scrubber'),
        value: pos,
        max: dur > 0 ? dur : 1,
        onChanged: has && dur > 0 ? (v) => setState(() => _dragPos = v) : null,
        onChangeEnd: (v) async {
          await _run(() => app.control(ControlAction.seek, v));
          if (mounted) setState(() => _dragPos = null);
        },
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 0),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(formatDuration(pos)),
          Text(formatDuration(s.durationSeconds)),
        ]),
      ),
    ]);
    final transport = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          big(Icons.skip_previous, playlist ? 'Previous (in playlist)' : 'Previous',
              has ? () => _run(() => app.control(ControlAction.prev)) : null),
          big(Icons.replay_10, 'Back 10 s',
              has ? () => _run(() => app.control(ControlAction.seekRelative, -10)) : null),
          big(s.isPlaying ? Icons.pause : Icons.play_arrow, s.isPlaying ? 'Pause' : 'Play',
              item != null ? () => _run(() => app.control(ControlAction.toggle)) : null,
              key: const ValueKey('np-toggle'), primary: true),
          big(Icons.forward_10, 'Forward 10 s',
              has ? () => _run(() => app.control(ControlAction.seekRelative, 10)) : null),
          big(Icons.skip_next, playlist ? 'Next (in playlist)' : 'Next',
              (s.queueLength > 0 || (has && s.canNext)) ? () => _run(() => app.control(ControlAction.next)) : null,
              key: const ValueKey('np-next')),
        ],
      ),
    );
    final volume = Row(children: [
      IconButton(
        iconSize: 30,
        tooltip: s.muted ? 'Unmute' : 'Mute',
        onPressed: has ? () => _run(() => app.control(ControlAction.mute, !s.muted)) : null,
        icon: Icon(s.muted ? Icons.volume_off : Icons.volume_up),
      ),
      Expanded(
        child: Slider(
          key: const ValueKey('np-volume'),
          value: (_dragVol ?? s.volume).clamp(0, 100).toDouble(),
          max: 100,
          divisions: 20,
          label: '${(_dragVol ?? s.volume).round()}',
          onChanged: has ? (v) => setState(() => _dragVol = v) : null,
          onChangeEnd: (v) async {
            await _run(() => app.control(ControlAction.volume, v));
            if (mounted) setState(() => _dragVol = null);
          },
        ),
      ),
      if (item?.kind == MediaKind.youtube)
        IconButton(
          key: const ValueKey('np-fullscreen'),
          iconSize: 30,
          tooltip: 'Fullscreen on the TV (toggle)',
          onPressed: has ? () => _run(() => app.control(ControlAction.fullscreen)) : null,
          icon: const Icon(Icons.fullscreen),
        ),
      if (item?.kind == MediaKind.local)
        IconButton(
          iconSize: 30,
          tooltip: 'Subtitles',
          onPressed: has ? () => _run(() => app.control(ControlAction.subtitles)) : null,
          icon: Icon(s.subtitles == false ? Icons.subtitles_off_outlined : Icons.subtitles),
        ),
    ]);
    final stopClose = Row(children: [
      Expanded(
        child: SizedBox(
          height: 56,
          child: OutlinedButton.icon(
            key: const ValueKey('np-stop'),
            onPressed: has ? () => _run(() => app.control(ControlAction.stop)) : null,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: SizedBox(
          height: 56,
          child: FilledButton.tonalIcon(
            key: const ValueKey('np-close'),
            onPressed: s.windowOpen ? _confirmClose : null,
            icon: const Icon(Icons.close_fullscreen),
            label: const Text('Close'),
          ),
        ),
      ),
    ]);

    if (!wide) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              art,
              const SizedBox(height: 12),
              title,
              const SizedBox(height: 4),
              meta,
              scrubber,
              const SizedBox(height: 8),
              transport,
              const SizedBox(height: 12),
              volume,
              const SizedBox(height: 8),
              stopClose,
            ],
          ),
        ),
      );
    }
    // Desktop: artwork left, title + volume + Stop/Close right; scrubber and
    // transport across the full width below.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 11, child: ClipRRect(borderRadius: BorderRadius.circular(12), child: art)),
            const SizedBox(width: 28),
            Expanded(
              flex: 9,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(item == null ? 'TV' : (item.kind == MediaKind.youtube ? 'YOUTUBE' : 'LOCAL FILE'),
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: PiTvColors.accent, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                title,
                const SizedBox(height: 10),
                meta,
                const SizedBox(height: 24),
                volume,
                const SizedBox(height: 16),
                stopClose,
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          scrubber,
          const SizedBox(height: 8),
          transport,
        ]),
      ),
    );
  }
}
