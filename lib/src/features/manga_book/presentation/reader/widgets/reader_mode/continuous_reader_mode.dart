// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../../utils/misc/app_utils.dart';
import '../../../../../../widgets/server_image.dart';
import '../../../../../settings/presentation/reader/widgets/reader_pinch_to_zoom/reader_pinch_to_zoom.dart';
import '../../../../../settings/presentation/reader/widgets/reader_scroll_animation_tile/reader_scroll_animation_tile.dart';
import '../../../../data/manga_book/manga_book_repository.dart';
import '../../../../domain/chapter/chapter_model.dart';
import '../../../../domain/chapter_batch/chapter_batch_model.dart';
import '../../../../domain/manga/manga_model.dart';
import '../../controller/reader_controller.dart';
import '../../controller/reader_item.dart';
import '../chapter_separator.dart';
import '../reader_wrapper.dart';

/// Scroll-behaviour tuning for the continuous / webtoon reader.
class _ScrollConfig {
  const _ScrollConfig._();

  /// Visibility threshold (fraction of viewport) below which an item is
  /// ignored when deciding which page is "currently being read".
  static const double minVisibleAreaThreshold = 0.4;

  /// Delay before allowing programmatic navigation again after the user
  /// finishes scrolling — prevents the slider from yanking the viewport
  /// mid-scroll.
  static const Duration programmaticNavigationDelay =
      Duration(milliseconds: 800);

  /// Debounce on chapter-change detection to avoid thrashing across a
  /// boundary on fast scrolls.
  static const Duration activeChapterDebounce = Duration(milliseconds: 250);
}

class ContinuousReaderMode extends HookConsumerWidget {
  const ContinuousReaderMode({
    super.key,
    required this.manga,
    required this.initialChapterId,
    this.showSeparator = false,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.showReaderLayoutAnimation = false,
  });

  final MangaDto manga;
  final int initialChapterId;
  final bool showSeparator;
  final Axis scrollDirection;
  final bool reverse;
  final bool showReaderLayoutAnimation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ItemScrollController scrollController =
        useMemoized(() => ItemScrollController());
    final ItemPositionsListener positionsListener =
        useMemoized(() => ItemPositionsListener.create());

    // The chapter the user is currently reading. Starts at the route's
    // initial chapter, updates as the user scrolls across boundaries.
    final activeChapterId = useState<int>(initialChapterId);

    // Items composed from prev + current + next chapters. Grows as
    // neighbours' pages load; shrinks at the seams when activeChapterId
    // advances.
    final items = ref.watch(readerItemsProvider(
      mangaId: manga.id,
      activeChapterId: activeChapterId.value,
    ));

    final activeChapter = ref
        .watch(chapterProvider(chapterId: activeChapterId.value))
        .valueOrNull;
    final activeChapterPages = ref
        .watch(chapterPagesProvider(chapterId: activeChapterId.value))
        .valueOrNull;

    // Local page index within the active chapter — drives the reader's
    // progress bar / slider. Initialised from the active chapter's
    // last-read page on first build.
    final currentPageInChapter = useState<int>(
      activeChapter?.isRead.ifNull() ?? false
          ? 0
          : (activeChapter?.lastPageRead).getValueOnNullOrNegative(),
    );

    final lastReportedChapterId = useState<int>(activeChapterId.value);

    final ObjectRef<Timer?> positionUpdateTimer = useRef<Timer?>(null);
    final ObjectRef<Timer?> activeChapterDebounce = useRef<Timer?>(null);
    final isUserScrolling = useState<bool>(false);
    final isNavigatingFromSlider = useState<bool>(false);

    // Track which chapter IDs have already had mark-as-read fired in this
    // reader session so we don't spam the GraphQL mutation on every scroll
    // tick once we've passed a boundary.
    final markedAsRead = useRef<Set<int>>(<int>{});

    useEffect(() {
      return () {
        positionUpdateTimer.value?.cancel();
        activeChapterDebounce.value?.cancel();
        positionUpdateTimer.value = null;
        activeChapterDebounce.value = null;
      };
    }, const []);

    // Mark-as-read pipeline: fires once per chapter when the user scrolls
    // its last page out of the viewport going forwards. Uses the existing
    // mangaBookRepository.putChapter mutation to mirror the previous
    // reader_screen behaviour.
    Future<void> markChapterAsRead(int chapterId) async {
      if (markedAsRead.value.contains(chapterId)) return;
      markedAsRead.value = {...markedAsRead.value, chapterId};
      await AsyncValue.guard(
        () => ref.read(mangaBookRepositoryProvider).putChapter(
              chapterId: chapterId,
              patch: ChapterChange(
                lastPageRead: 0,
                isRead: true,
              ),
            ),
      );
    }

    // Position listener — recomputes "which item is most visible", then
    // derives (activeChapter, localPageIndex). When the active chapter
    // changes, bumps the state notifier and schedules read-marking on the
    // chapter just left behind.
    useEffect(() {
      void listener() {
        if (isNavigatingFromSlider.value) return;

        final positions = positionsListener.itemPositions.value.toList();
        if (positions.isEmpty || items.isEmpty) return;

        final mostVisibleIndex = _mostVisibleIndex(positions);
        if (mostVisibleIndex == null) return;
        if (mostVisibleIndex < 0 || mostVisibleIndex >= items.length) return;

        final item = items[mostVisibleIndex];
        final chapterAtCursor = item.owningChapter;

        // Update local page index within whatever chapter we're in.
        if (item is ReaderItemPage) {
          if (currentPageInChapter.value != item.pageIndex &&
              chapterAtCursor.id == activeChapterId.value) {
            currentPageInChapter.value = item.pageIndex;
          }
        }

        // Schedule a debounced active-chapter switch so quick crossings
        // don't thrash.
        if (chapterAtCursor.id != activeChapterId.value) {
          activeChapterDebounce.value?.cancel();
          activeChapterDebounce.value =
              Timer(_ScrollConfig.activeChapterDebounce, () {
            final outgoing = activeChapterId.value;
            activeChapterId.value = chapterAtCursor.id;
            currentPageInChapter.value =
                item is ReaderItemPage ? item.pageIndex : 0;
            // When the user crosses forward into a later chapter, the
            // chapter they left should be considered read.
            markChapterAsRead(outgoing);
          });
        }

        isUserScrolling.value = true;
        positionUpdateTimer.value?.cancel();
        positionUpdateTimer.value =
            Timer(_ScrollConfig.programmaticNavigationDelay, () {
          isUserScrolling.value = false;
          isNavigatingFromSlider.value = false;
        });
      }

      positionsListener.itemPositions.addListener(listener);
      return () {
        positionsListener.itemPositions.removeListener(listener);
      };
    }, [items, activeChapterId.value]);

    // Notify the reader_wrapper / slider that the local page changed.
    // Mirrors the old onPageChanged signal but stays internal — the slider
    // only ever sees pages of the active chapter.
    useEffect(() {
      lastReportedChapterId.value = activeChapterId.value;
      return null;
    }, [activeChapterId.value]);

    final bool isAnimationEnabled =
        ref.read(readerScrollAnimationProvider).ifNull(true);
    final bool isPinchToZoomEnabled =
        ref.read(pinchToZoomProvider).ifNull(true);

    if (activeChapter == null || activeChapterPages == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ReaderWrapper(
      scrollDirection: scrollDirection,
      chapterPages: activeChapterPages,
      chapter: activeChapter,
      manga: manga,
      showReaderLayoutAnimation: showReaderLayoutAnimation,
      currentIndex: currentPageInChapter.value,
      onChanged: (pageWithinChapter) {
        // Slider moved to `pageWithinChapter` within the active chapter.
        // Translate that into a global items index and jump to it.
        final activeStart = items.indexWhere(
          (item) =>
              item is ReaderItemPage &&
              item.chapter.id == activeChapterId.value &&
              item.pageIndex == 0,
        );
        if (activeStart < 0) return;

        isNavigatingFromSlider.value = true;
        currentPageInChapter.value = pageWithinChapter;
        scrollController.jumpTo(index: activeStart + pageWithinChapter);
        Timer(const Duration(milliseconds: 300), () {
          isNavigatingFromSlider.value = false;
        });
      },
      // The reader_wrapper's prev/next arrows in continuous mode page
      // within the current chapter rather than across — preserving the
      // existing UX. Cross-chapter movement is the user's own scroll.
      onPrevious: () => _stepWithinChapter(
        scrollController,
        positionsListener,
        isUserScrolling,
        isAnimationEnabled,
        isNext: false,
      ),
      onNext: () => _stepWithinChapter(
        scrollController,
        positionsListener,
        isUserScrolling,
        isAnimationEnabled,
        isNext: true,
      ),
      child: AppUtils.wrapOn(
        !kIsWeb &&
                (Platform.isAndroid || Platform.isIOS) &&
                isPinchToZoomEnabled
            ? (Widget child) => InteractiveViewer(maxScale: 5, child: child)
            : null,
        ScrollablePositionedList.builder(
          itemScrollController: scrollController,
          itemPositionsListener: positionsListener,
          initialScrollIndex: _initialScrollIndex(items, activeChapter),
          scrollDirection: scrollDirection,
          reverse: reverse,
          itemCount: items.length,
          minCacheExtent: scrollDirection == Axis.vertical
              ? context.height * 2
              : context.width * 2,
          itemBuilder: (context, index) {
            final item = items[index];
            switch (item) {
              case ReaderItemPage():
                return _buildPage(context, item);
              case ReaderItemSeparator():
                return _buildSeparator(context, item);
            }
          },
        ),
      ),
    );
  }

  static int _initialScrollIndex(
    List<ReaderItem> items,
    ChapterDto activeChapter,
  ) {
    if (items.isEmpty) return 0;
    final lastPageRead =
        activeChapter.lastPageRead.getValueOnNullOrNegative();
    final isRead = activeChapter.isRead.ifNull();
    final firstPageOfActive = items.indexWhere(
      (item) =>
          item is ReaderItemPage &&
          item.chapter.id == activeChapter.id &&
          item.pageIndex == 0,
    );
    if (firstPageOfActive < 0) return 0;
    return firstPageOfActive + (isRead ? 0 : lastPageRead);
  }

  Widget _buildPage(BuildContext context, ReaderItemPage item) {
    return ServerImage(
      showReloadButton: true,
      fit: scrollDirection == Axis.vertical
          ? BoxFit.fitWidth
          : BoxFit.fitHeight,
      appendApiToUrl: false,
      imageUrl: item.url,
      progressIndicatorBuilder: (_, __, downloadProgress) => Center(
        child: CircularProgressIndicator(value: downloadProgress.progress),
      ),
      wrapper: (Widget child) => SizedBox(
        height:
            scrollDirection == Axis.vertical ? context.height * .7 : null,
        width:
            scrollDirection != Axis.vertical ? context.width * .7 : null,
        child: child,
      ),
    );
  }

  Widget _buildSeparator(BuildContext context, ReaderItemSeparator item) {
    return SizedBox(
      width: scrollDirection != Axis.vertical ? context.width * .5 : null,
      child: ChapterSeparator(
        manga: manga,
        chapter: item.endingChapter,
        // The existing ChapterSeparator widget uses this flag to decide
        // whether to show "Previous chapter" vs "Next chapter" affordances.
        // At an inline seam we're always pointing forward.
        isPreviousChapterSeparator: false,
      ),
    );
  }

  static int? _mostVisibleIndex(List<ItemPosition> positions) {
    ItemPosition? best;
    double bestArea = 0;
    for (final p in positions) {
      final area = _visibleArea(p);
      if (area > bestArea && area > _ScrollConfig.minVisibleAreaThreshold) {
        bestArea = area;
        best = p;
      }
    }
    return best?.index;
  }

  static double _visibleArea(ItemPosition p) {
    final leading = p.itemLeadingEdge.clamp(0.0, 1.0);
    final trailing = p.itemTrailingEdge.clamp(0.0, 1.0);
    return (trailing - leading).clamp(0.0, 1.0);
  }

  /// Tap-zone / hardware-button stepping. Moves by one item within the
  /// scrollable, which in this multi-chapter list happens to cross chapter
  /// boundaries naturally without extra logic.
  static void _stepWithinChapter(
    ItemScrollController scrollController,
    ItemPositionsListener positionsListener,
    ValueNotifier<bool> isUserScrolling,
    bool isAnimationEnabled, {
    required bool isNext,
  }) {
    if (isUserScrolling.value) return;

    final positions = positionsListener.itemPositions.value.toList();
    if (positions.isEmpty) return;

    ItemPosition? current;
    for (final p in positions) {
      if (_visibleArea(p) > _ScrollConfig.minVisibleAreaThreshold) {
        current = p;
        break;
      }
    }
    if (current == null) return;

    final int target;
    if (isNext) {
      target = current.itemTrailingEdge > 0.8
          ? current.index + 1
          : current.index;
    } else {
      target = current.itemLeadingEdge < 0.2
          ? (current.index - 1).clamp(0, 1 << 30)
          : current.index;
    }

    if (isAnimationEnabled) {
      scrollController.scrollTo(
        index: target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0,
      );
    } else {
      scrollController.jumpTo(index: target, alignment: 0);
    }
  }
}
