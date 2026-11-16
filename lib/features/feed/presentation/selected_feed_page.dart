import 'dart:async';

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
/// Mirrors the desktop client's layout: one fixed video layer that follows the
/// centred page, with the pager itself carrying only covers and text. The
/// player engine is never rebuilt while swiping — a new item is opened on the
/// same session, which is the equivalent of the client's `reload()`.
class SelectedFeedPage extends ConsumerStatefulWidget {
  const SelectedFeedPage({super.key});

  @override
  ConsumerState<SelectedFeedPage> createState() => _SelectedFeedPageState();
}

class _SelectedFeedPageState extends ConsumerState<SelectedFeedPage> {
  final _controller = PageController();
  int _index = 0;

  /// Bumped on every activation so a slow open cannot revive a left page.
  int _activation = 0;

  /// Set before awaiting the open: without it every rebuild during a slow CDN
  /// start begins another open and cancels the first one.
  String? _openingId;
  String? _playingId;
  int _playingIndex = 0;
  PlaybackSession? _session;
  bool _paused = false;

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

  Future<void> _open(int index, VideoSummary item, VideoDetail detail) async {
    final id = item.id.value;
    if (_playingId == id || _openingId == id) return;
    final session = _resolveSession();
    if (session == null) return;
    _openingId = id;
    final activation = ++_activation;
    try {
      await session.open(
        detail,
        detail.parts.isEmpty ? null : detail.parts.first,
        desiredPlaying: true,
      );
      if (!mounted || activation != _activation) return;
      setState(() {
        _playingId = id;
        _playingIndex = index;
        _openingId = null;
        _paused = false;
      });
    } on Object {
      if (!mounted || activation != _activation) return;
      setState(() {
        _playingId = null;
        _openingId = null;
      });
    }
  }

  Future<void> _togglePlayback() async {
    final session = _session;
    if (session == null) return;
    final next = !_paused;
    setState(() => _paused = next);
    if (next) {
      await session.pause();
    } else {
      await session.play();
    }
  }

  void _onPageChanged(int index, int itemCount) {
    setState(() => _index = index);
    if (index >= itemCount - 2) {
      ref.read(selectedFeedControllerProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(selectedFeedControllerProvider);
    final items = state.items;
    if (items.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _SelectedFeedStatus(state: state),
            _backButton(),
          ],
        ),
      );
    }
    final centered = items[_index.clamp(0, items.length - 1)];
    final detail = ref.watch(videoDetailProvider(centered.id)).value;
    if (detail != null &&
        _playingId != centered.id.value &&
        _openingId != centered.id.value) {
      final index = _index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _open(index, centered, detail);
      });
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                key: const ValueKey('selected-feed-pager'),
                controller: _controller,
                scrollDirection: Axis.vertical,
                itemCount: items.length,
                onPageChanged: (index) => _onPageChanged(index, items.length),
                itemBuilder: (context, index) => _SelectedCover(
                  item: items[index],
                  index: index,
                  active: index == _index,
                ),
              ),
              _buildVideoLayer(height),
              if (_playingId != null)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _togglePlayback,
                    child: _paused
                        ? const Center(
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 76,
                              color: Colors.white70,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              _backButton(),
            ],
          );
        },
      ),
    );
  }

  /// One surface for the whole flow. Swiping moves it with the page it belongs
  /// to instead of building a player per page, which is what keeps a single
  /// native texture alive on Windows.
  Widget _buildVideoLayer(double height) {
    final engine = _session?.engine;
    if (engine == null || _playingId == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final page = _controller.hasClients
            ? (_controller.page ?? _playingIndex.toDouble())
            : _playingIndex.toDouble();
        final offset = (_playingIndex - page) * height;
        return Transform.translate(offset: Offset(0, offset), child: child);
      },
      child: VideoCompositionScope.of(context).compose(
        context,
        layers: [
          VideoSurface(key: const ValueKey('selected-surface'), engine: engine),
        ],
      ),
    );
  }

  Widget _backButton() => Positioned(
    top: 12,
    left: 12,
    child: SafeArea(
      child: Material(
        color: Colors.black45,
        shape: const CircleBorder(),
        child: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
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
  );
}

/// Cover and text only; the video is drawn by the single layer above.
class _SelectedCover extends StatelessWidget {
  const _SelectedCover({
    required this.item,
    required this.index,
    required this.active,
  });

  final VideoSummary item;
  final int index;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cover = item.coverUrl.isEmpty ? null : item.coverUrl;
    return Stack(
      key: ValueKey('selected-feed-item-$index'),
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (cover != null)
          Image.network(
            cover,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.62, 1],
              ),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 30,
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
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
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
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _formatCount(int count) {
  if (count < 10000) return '$count';
  final value = count / 10000;
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}万';
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
