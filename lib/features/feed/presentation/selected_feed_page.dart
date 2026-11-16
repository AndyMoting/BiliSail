import 'package:bili_player/bili_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/video.dart';
import '../../playback/application/playback_session.dart';
import '../../video/application/video_controller.dart';
import '../application/selected_feed_controller.dart';

/// Full-screen vertical "精选" flow.
///
/// Mirrors the desktop client: one video per screen, ten per request, and the
/// next page is requested while the user is still on the second to last item so
/// the swipe never lands on a loading card. The visible tab owns one playback
/// session, so only the centered item is opened; neighbours stay on their cover
/// and take over the same session once they reach the center.
class SelectedFeedPage extends ConsumerStatefulWidget {
  const SelectedFeedPage({super.key});

  @override
  ConsumerState<SelectedFeedPage> createState() => _SelectedFeedPageState();
}

class _SelectedFeedPageState extends ConsumerState<SelectedFeedPage> {
  final _controller = PageController();
  int _index = 0;

  /// Guards against a slow detail request reviving a page the user left.
  int _activation = 0;
  bool _activating = false;

  /// The item currently loading or playing behind the centered page.
  String? _playingId;
  PlaybackSession? _session;

  @override
  void dispose() {
    _activation++;
    _controller.dispose();
    super.dispose();
  }

  PlaybackSession? _resolveSession() {
    if (_session != null) return _session;
    if (!ref.exists(playbackSessionProvider)) return null;
    return _session = ref.read(playbackSessionProvider);
  }

  /// Opens the already resolved detail on the tab's single session.
  Future<void> _open(VideoSummary item, VideoDetail detail) async {
    if (_playingId == item.id.value) return;
    final session = _resolveSession();
    if (session == null || _activating) return;
    _activating = true;
    final activation = ++_activation;
    try {
      await session.open(
        detail,
        detail.parts.isEmpty ? null : detail.parts.first,
        desiredPlaying: true,
      );
      if (!mounted || activation != _activation) return;
      setState(() => _playingId = item.id.value);
    } on Object {
      if (!mounted || activation != _activation) return;
      setState(() => _playingId = null);
    } finally {
      _activating = false;
    }
  }

  void _onPageChanged(int index, int itemCount, List<VideoSummary> items) {
    setState(() => _index = index);
    // The centered page takes the session over; the previous one immediately
    // falls back to its cover, matching the desktop handoff.
    if (index >= itemCount - 2) {
      ref.read(selectedFeedControllerProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(selectedFeedControllerProvider);
    final items = state.items;
    if (items.isNotEmpty) {
      final centered = items[_index.clamp(0, items.length - 1)];
      // Watching keeps the auto-dispose detail alive while this page is
      // centered; opening from a post-frame callback avoids mutating playback
      // during build.
      final detail = ref.watch(videoDetailProvider(centered.id)).value;
      if (detail != null && _playingId != centered.id.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _open(centered, detail);
        });
      }
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (items.isEmpty)
            _SelectedFeedStatus(state: state)
          else
            PageView.builder(
              key: const ValueKey('selected-feed-pager'),
              controller: _controller,
              scrollDirection: Axis.vertical,
              itemCount: items.length,
              onPageChanged: (index) =>
                  _onPageChanged(index, items.length, items),
              itemBuilder: (context, index) {
                final item = items[index];
                final playing = index == _index && _playingId == item.id.value;
                return _SelectedFeedCard(
                  item: item,
                  index: index,
                  active: index == _index,
                  engine: playing ? _session?.engine : null,
                  onOpen: () => context.go('/video/${item.id.value}'),
                );
              },
            ),
          Positioned(
            top: 12,
            left: 12,
            child: SafeArea(
              child: _RoundIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: '返回',
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/');
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectedFeedCard extends StatelessWidget {
  const _SelectedFeedCard({
    required this.item,
    required this.index,
    required this.active,
    required this.onOpen,
    this.engine,
  });

  final VideoSummary item;
  final int index;
  final bool active;

  /// Present only for the centered item whose media is already open.
  final PlayerEngine? engine;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cover = item.coverUrl.isEmpty ? null : item.coverUrl;
    final playing = engine;
    return GestureDetector(
      key: ValueKey('selected-feed-item-$index'),
      onTap: onOpen,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black),
          if (cover != null)
            Image.network(
              cover,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          if (playing != null)
            VideoSurface(key: ValueKey('selected-surface-$index'), engine: playing),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.55, 1],
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 36,
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '@${item.author}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (item.playCount case final count?) ...[
                        const SizedBox(width: 12),
                        const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white70,
                          size: 16,
                        ),
                        Text(
                          _formatCount(count),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      if (active) ...[
                        const SizedBox(width: 12),
                        const _LiveDot(),
                      ],
                    ],
                  ),
                  if (item.recommendationReason case final reason?
                      when reason.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        reason,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatCount(int count) {
  if (count < 10000) return '$count';
  final value = count / 10000;
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}万';
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: const BoxDecoration(
      color: Color(0xFFFB7299),
      shape: BoxShape.circle,
    ),
  );
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black45,
    shape: const CircleBorder(),
    child: IconButton(
      icon: Icon(icon, color: Colors.white),
      tooltip: tooltip,
      onPressed: onPressed,
    ),
  );
}

class _SelectedFeedStatus extends ConsumerWidget {
  const _SelectedFeedStatus({required this.state});

  final SelectedFeedState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    final failure = state.failure;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.sentiment_dissatisfied_rounded,
              color: Colors.white38,
              size: 44,
            ),
            const SizedBox(height: 16),
            Text(
              failure == null ? '暂时没有推荐' : '精选加载失败',
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            if (failure != null) ...[
              const SizedBox(height: 8),
              Text(
                '$failure',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () =>
                  ref.read(selectedFeedControllerProvider.notifier).refresh(),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
