import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_all/webview_all.dart';

import '../../../core/presentation/app_input_host.dart';
import '../../../domain/video.dart';
import '../application/selected_feed_controller.dart';

/// Full-screen vertical "精选" flow.
///
/// Video playback is delegated to the real Bilibili video page inside a WebView:
/// the page is loaded as usual and then reduced to its player with one injected
/// style sheet, which keeps the official player, danmaku and account behaviour
/// instead of reimplementing them on top of libmpv.
class SelectedFeedPage extends ConsumerStatefulWidget {
  const SelectedFeedPage({super.key});

  @override
  ConsumerState<SelectedFeedPage> createState() => _SelectedFeedPageState();
}

class _SelectedFeedPageState extends ConsumerState<SelectedFeedPage> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
              onPageChanged: (index) => _onPageChanged(index, items.length),
              itemBuilder: (context, index) => _SelectedFeedCard(
                item: items[index],
                index: index,
                active: index == _index,
                // Neighbouring players stay mounted so a swipe lands on a page
                // that is already loading instead of a cold WebView.
                attached: (index - _index).abs() <= 1,
              ),
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
    required this.attached,
  });

  final VideoSummary item;
  final int index;
  final bool active;
  final bool attached;

  @override
  Widget build(BuildContext context) {
    final cover = item.coverUrl.isEmpty ? null : item.coverUrl;
    return Stack(
      key: ValueKey('selected-feed-item-$index'),
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        // The cover stays underneath so a loading WebView never shows a hole.
        if (cover != null)
          Image.network(
            cover,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          ),
        if (attached)
          _SelectedWebPlayer(
            key: ValueKey('selected-player-${item.id.value}'),
            bvid: item.id.value,
            active: active,
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
          child: IgnorePointer(
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
        ),
      ],
    );
  }
}

/// Loads the real video page and shrinks it to its player.
class _SelectedWebPlayer extends StatefulWidget {
  const _SelectedWebPlayer({
    super.key,
    required this.bvid,
    required this.active,
  });

  final String bvid;
  final bool active;

  @override
  State<_SelectedWebPlayer> createState() => _SelectedWebPlayerState();
}

class _SelectedWebPlayerState extends State<_SelectedWebPlayer> {
  WebViewSession? _session;
  WebViewController? _controller;
  WebViewWidget? _view;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final session = await WebViewSession.create(
        onPermissionRequest: (request) => request.deny(),
      );
      if (_disposed || session == null) {
        await session?.close();
        return;
      }
      _session = session;
      final controller = session.controller;
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      // The page is opened by the app, so its media must start without a tap.
      await controller.setMediaPlaybackRequiresUserGesture(false);
      await controller.setBackgroundColor(Colors.black);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            unawaited(_decorate());
          },
        ),
      );
      await controller.loadRequest(
        Uri.parse('https://www.bilibili.com/video/${widget.bvid}/'),
      );
      if (_disposed) return;
      if (mounted) setState(() {});
    } on Object {
      if (mounted) setState(() {});
    }
  }

  /// Injects the stylesheet that turns the video page into a bare player.
  Future<void> _decorate() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.runJavaScript(_kShrinkToPlayer);
    await _syncPlayback();
  }

  Future<void> _syncPlayback() async {
    final controller = _controller;
    if (controller == null) return;
    // The page autoplays on load; neighbours must not keep decoding audio once
    // the user has moved on, so playback is re-asserted on every activation.
    await controller.runJavaScript(widget.active ? _kPlay : _kPause);
  }

  @override
  void didUpdateWidget(_SelectedWebPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) unawaited(_syncPlayback());
  }

  @override
  void dispose() {
    _disposed = true;
    final session = _session;
    _session = null;
    _controller = null;
    unawaited(session?.close() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return NativeInputRegion(
      child: _view ??= WebViewWidget(controller: controller),
    );
  }
}

const _kShrinkToPlayer = '''
(function () {
  var id = 'bs-selected-style';
  if (document.getElementById(id)) return;
  var style = document.createElement('style');
  style.id = id;
  style.textContent = [
    'html,body{overflow:hidden!important;background:#000!important}',
    'body *{visibility:hidden!important}',
    '#bilibili-player,#bilibili-player *{visibility:visible!important}',
    '#bilibili-player{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;margin:0!important;z-index:2147483646!important}',
    '#bilibili-player .bpx-player-container,#bilibili-player .bpx-player-primary-area{width:100%!important;height:100%!important}',
    '#bilibili-player .bpx-player-container{box-shadow:none!important}',
    '#bilibili-player .bpx-player-video-area{height:100%!important}',
    '.bpx-player-ending-panel,.bpx-player-ending-wrap,.bpx-player-toast-auto{display:none!important}'
  ].join('');
  document.head.appendChild(style);
})();
''';

const _kPlay =
    "(function(){var v=document.querySelector('#bilibili-player video,video');"
    'if(!v)return;var p=v.play();if(p&&p.catch)p.catch(function(){});})();';

const _kPause =
    "(function(){var v=document.querySelector('#bilibili-player video,video');"
    'if(!v)return;v.pause();})();';

String _formatCount(int count) {
  if (count < 10000) return '$count';
  final value = count / 10000;
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)}万';
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
