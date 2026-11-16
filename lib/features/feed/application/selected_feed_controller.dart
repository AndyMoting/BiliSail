import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/app_failure.dart';
import '../../../domain/page_result.dart';
import '../../../domain/request_cancellation.dart';
import '../../../domain/video.dart';
import '../domain/feed_repository.dart';
import 'feed_controller.dart';

/// One page of the desktop "精选" flow plus its own loading state.
final class SelectedFeedState {
  const SelectedFeedState({
    this.items = const <VideoSummary>[],
    this.loading = false,
    this.hasMore = true,
    this.failure,
  });

  final List<VideoSummary> items;
  final bool loading;
  final bool hasMore;

  /// Kept as the raw error so the page can decide between a retry card and a
  /// silent tail failure while the already loaded pages stay playable.
  final Object? failure;

  SelectedFeedState copyWith({
    List<VideoSummary>? items,
    bool? loading,
    bool? hasMore,
    Object? failure,
    bool clearFailure = false,
  }) => SelectedFeedState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    hasMore: hasMore ?? this.hasMore,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

final selectedFeedControllerProvider =
    NotifierProvider<SelectedFeedController, SelectedFeedState>(
      SelectedFeedController.new,
    );

/// Drives the vertical selected page.
///
/// The server hands out ten items per request, so the controller never asks for
/// a larger window; it only keeps the retry index of the current page and lets
/// the page prefetch while the user is still watching the last loaded video.
class SelectedFeedController extends Notifier<SelectedFeedState> {
  int _page = 0;
  RequestCancellation? _cancellation;
  bool _busy = false;

  @override
  SelectedFeedState build() {
    ref.onDispose(() {
      _cancellation?.cancel();
      _cancellation = null;
    });
    Future<void>.microtask(refresh);
    return const SelectedFeedState(loading: true);
  }

  SelectedFeedRepository? get _repository {
    final repository = ref.read(feedRepositoryProvider);
    if (repository is SelectedFeedRepository) return repository;
    return null;
  }

  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    _cancellation?.cancel();
    final cancellation = RequestCancellation();
    _cancellation = cancellation;
    state = state.copyWith(loading: true, clearFailure: true);
    try {
      final repository = _repository;
      if (repository == null) {
        throw const AppFailure(AppFailureKind.protocol, '精选流服务暂不可用');
      }
      final PageResult<VideoSummary> result = await repository.loadSelectedFeed(
        page: 1,
        cancellation: cancellation,
      );
      if (cancellation.isCancelled) return;
      _page = 1;
      state = SelectedFeedState(items: result.items, hasMore: result.hasMore);
    } on Object catch (error) {
      if (cancellation.isCancelled) return;
      state = state.copyWith(loading: false, failure: error);
    } finally {
      _busy = false;
    }
  }

  /// Loads the next ten videos. A failed page keeps its index so the caller can
  /// retry the same page instead of skipping it.
  Future<void> loadMore() async {
    if (_busy || !state.hasMore) return;
    _busy = true;
    final cancellation = RequestCancellation();
    _cancellation = cancellation;
    state = state.copyWith(loading: true, clearFailure: true);
    try {
      final repository = _repository;
      if (repository == null) {
        throw const AppFailure(AppFailureKind.protocol, '精选流服务暂不可用');
      }
      final PageResult<VideoSummary> result = await repository.loadSelectedFeed(
        page: _page + 1,
        cancellation: cancellation,
      );
      if (cancellation.isCancelled) return;
      // A repeated recommendation must not create a second page entry; the
      // vertical pager keys pages by position, so duplicates would loop.
      final seen = {for (final item in state.items) item.id.value};
      _page += 1;
      state = SelectedFeedState(
        items: [
          ...state.items,
          ...result.items.where((item) => seen.add(item.id.value)),
        ],
        hasMore: result.hasMore,
      );
    } on Object catch (error) {
      if (cancellation.isCancelled) return;
      state = state.copyWith(loading: false, failure: error);
    } finally {
      _busy = false;
    }
  }
}
