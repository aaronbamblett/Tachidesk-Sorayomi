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
import '../../../../data/manga_book/manga_book_repository.dart';
import '../../../../domain/chapter/chapter_model.dart';
import '../../../../domain/chapter_batch/chapter_batch_model.dart';
import '../../../../domain/manga/manga_model.dart';
import '../../../manga_details/controller/manga_details_controller.dart';
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

  /// Pre-fetch the next / previous chapter when the user's most-visible
  /// item is within this many positions of the start or end of the loaded
  /// items list.
  static const int preFetchPagesThreshold = 5;
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

    // The full list of chapters for this manga, in reading order.
    final mangaChapterList = ref
        .watch(mangaChapterListProvider(mangaId: manga.id))
        .valueOrNull;

    // The set of chapter IDs whose pages we have currently loaded into
    // the reader. ORDERED by reading order. Grows as the user approaches
    // either end. Never shrinks during a session — old chapters stay
    // around so backward scrolling still works without re-fetching.
    final loadedChapterIds = useState<List<int>>([initialChapterId]);

    // The chapter the user is currently looking at — derived from the
    // most-visible item. Drives the wrapper / slider state. Never drives
    // the items list shape.
    final activeChapterId = useState<int>(initialChapterId);
    final currentPageInChapter = useState<int>(0);

    // Anchor: which (chapter, page) the user is most-visibly looking at.
    // Used to keep their viewport stable when the items list grows at
    // the start (the previous chapter just loaded in).
    final anchorChapterId = useState<int>(initialChapterId);
    final anchorPageIndex = useState<int>(0);

    // Mark-as-read dedupe across the reader session.
    final markedAsRead = useRef<Set<int>>(<int>{});

    // Debounced save of mid-chapter progress for the active chapter,
    // mirroring the old reader_screen.onPageChanged behaviour: write
    // `lastPageRead` for the active chapter when the user pauses on a
    // page for ~2 seconds, never regressing existing progress.
    final progressSaveDebounce = useRef<Timer?>(null);

    Future<void> markChapterAsRead(int chapterId) async {
      if (markedAsRead.value.contains(chapterId)) return;
      markedAsRead.value = {...markedAsRead.value, chapterId};
      final result = await AsyncValue.guard(
        () => ref.read(mangaBookRepositoryProvider).putChapter(
              chapterId: chapterId,
              patch: ChapterChange(
                lastPageRead: 0,
                isRead: true,
              ),
            ),
      );
      if (result.hasError) {
        // The mutation failed — let it be retried next time the user
        // crosses or reaches the last page of this chapter by clearing
        // it from the dedupe set.
        final next = {...markedAsRead.value}..remove(chapterId);
        markedAsRead.value = next;
        return;
      }
      // Refresh local caches so the manga details / chapter list / history
      // immediately reflect the new read state.
      ref.invalidate(chapterProvider(chapterId: chapterId));
      ref.invalidate(mangaChapterListProvider(mangaId: manga.id));
    }

    // Build the items list locally from the set of loaded chapters. The
    // widget watches each loaded chapter's provider individually; Riverpod
    // de-duplicates and caches, and pre-fetching is just "add a chapter
    // ID to the loaded list — its pages stream in shortly after".
    final items = <ReaderItem>[];
    final loadedChapters = <int, ChapterDto>{};
    for (final id in loadedChapterIds.value) {
      final chapter =
          ref.watch(chapterProvider(chapterId: id)).valueOrNull;
      if (chapter != null) loadedChapters[id] = chapter;
    }
    for (var i = 0; i < loadedChapterIds.value.length; i++) {
      final id = loadedChapterIds.value[i];
      final chapter = loadedChapters[id];
      final pages =
          ref.watch(chapterPagesProvider(chapterId: id)).valueOrNull;
      if (chapter == null || pages == null) continue;
      for (var p = 0; p < pages.pages.length; p++) {
        items.add(ReaderItemPage(
          chapter: chapter,
          pageIndex: p,
          pageCount: pages.pages.length,
          url: pages.pages[p],
        ));
      }
      // Separator between this and the next loaded chapter, if there
      // is one.
      if (i < loadedChapterIds.value.length - 1) {
        final nextId = loadedChapterIds.value[i + 1];
        final nextChapter = loadedChapters[nextId];
        if (nextChapter != null) {
          items.add(ReaderItemSeparator(
            endingChapter: chapter,
            startingChapter: nextChapter,
          ));
        }
      }
    }

    final activeChapter = loadedChapters[activeChapterId.value];
    final activeChapterPages = ref
        .watch(chapterPagesProvider(chapterId: activeChapterId.value))
        .valueOrNull;

    // Scroll-anchor preservation: when items list grows at the start
    // (previous chapter pages just loaded in), the user's anchor item
    // moves to a higher global index. Detect by tracking whether items
    // changed length and the anchor's new index differs from the current
    // most-visible-index; if so, jump to the anchor's new index so the
    // user's viewport stays put visually.
    final previousItemsLength = useRef<int>(0);
    final anchorGlobalIndex = items.indexWhere(
      (item) =>
          item is ReaderItemPage &&
          item.chapter.id == anchorChapterId.value &&
          item.pageIndex == anchorPageIndex.value,
    );
    useEffect(() {
      if (previousItemsLength.value != 0 &&
          items.length != previousItemsLength.value &&
          anchorGlobalIndex >= 0) {
        final positions = positionsListener.itemPositions.value;
        if (positions.isNotEmpty) {
          final mostVisible = _mostVisibleIndex(positions.toList());
          if (mostVisible != null && mostVisible != anchorGlobalIndex) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (scrollController.isAttached) {
                scrollController.jumpTo(index: anchorGlobalIndex);
              }
            });
          }
        }
      }
      previousItemsLength.value = items.length;
      return null;
    });

    // Position listener: drives active chapter, current page,
    // mark-as-read, and pre-fetch in both directions. Reads each tick
    // and operates on the latest items snapshot via closure capture.
    useEffect(() {
      void listener() {
        final positions = positionsListener.itemPositions.value.toList();
        if (positions.isEmpty || items.isEmpty) return;

        final mostVisibleIndex = _mostVisibleIndex(positions);
        if (mostVisibleIndex == null) return;
        if (mostVisibleIndex < 0 || mostVisibleIndex >= items.length) return;

        final item = items[mostVisibleIndex];

        // Update anchor (used by the scroll-preservation effect above).
        anchorChapterId.value = item.owningChapter.id;
        anchorPageIndex.value =
            item is ReaderItemPage ? item.pageIndex : 0;

        // Update active chapter / current page.
        if (item is ReaderItemPage) {
          if (currentPageInChapter.value != item.pageIndex &&
              item.chapter.id == activeChapterId.value) {
            currentPageInChapter.value = item.pageIndex;
          }
          if (item.isLastPageOfChapter &&
              item.chapter.id == activeChapterId.value) {
            markChapterAsRead(item.chapter.id);
          }
        }

        final cursorChapterId = item.owningChapter.id;
        if (cursorChapterId != activeChapterId.value) {
          final outgoing = activeChapterId.value;
          activeChapterId.value = cursorChapterId;
          currentPageInChapter.value =
              item is ReaderItemPage ? item.pageIndex : 0;
          // The chapter the user left should be marked read.
          markChapterAsRead(outgoing);
        }

        // Forward pre-fetch: if we're within N items of the end of
        // the loaded list AND there's a chapter after the last loaded
        // one in the manga's chapter list, append it.
        if (mostVisibleIndex >=
            items.length - _ScrollConfig.preFetchPagesThreshold) {
          final lastLoadedId = loadedChapterIds.value.last;
          final next = _findAdjacentChapter(
            mangaChapterList,
            lastLoadedId,
            offset: 1,
          );
          if (next != null &&
              !loadedChapterIds.value.contains(next.id)) {
            loadedChapterIds.value = [...loadedChapterIds.value, next.id];
          }
        }

        // Backward pre-fetch: if we're within N items of the start of
        // the loaded list AND there's a chapter before the first loaded
        // one in the manga's chapter list, prepend it. The
        // scroll-anchor effect will compensate the scroll position
        // once those pages stream in.
        if (mostVisibleIndex < _ScrollConfig.preFetchPagesThreshold) {
          final firstLoadedId = loadedChapterIds.value.first;
          final prev = _findAdjacentChapter(
            mangaChapterList,
            firstLoadedId,
            offset: -1,
          );
          if (prev != null &&
              !loadedChapterIds.value.contains(prev.id)) {
            loadedChapterIds.value = [prev.id, ...loadedChapterIds.value];
          }
        }
      }

      positionsListener.itemPositions.addListener(listener);
      return () =>
          positionsListener.itemPositions.removeListener(listener);
    });

    // Schedule a debounced save of `lastPageRead` for the active chapter
    // whenever the local page index moves. Mirrors the prior screen-level
    // behaviour but with the multi-chapter context the reader now owns.
    useEffect(() {
      progressSaveDebounce.value?.cancel();
      final chapterId = activeChapterId.value;
      final pageIndex = currentPageInChapter.value;
      final chapterSnapshot = loadedChapters[chapterId];

      progressSaveDebounce.value =
          Timer(const Duration(seconds: 2), () async {
        if (chapterSnapshot == null) return;
        if (chapterSnapshot.isRead.ifNull()) return;
        if (markedAsRead.value.contains(chapterId)) return;
        // Don't regress saved progress.
        final saved =
            chapterSnapshot.lastPageRead.getValueOnNullOrNegative();
        if (pageIndex <= saved) return;
        await AsyncValue.guard(
          () => ref.read(mangaBookRepositoryProvider).putChapter(
                chapterId: chapterId,
                patch: ChapterChange(lastPageRead: pageIndex),
              ),
        );
      });
      return null;
    }, [currentPageInChapter.value, activeChapterId.value]);

    useEffect(() {
      return () => progressSaveDebounce.value?.cancel();
    }, const []);

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
        // Slider moved within the active chapter — translate to global
        // items index and jump.
        final start = items.indexWhere(
          (item) =>
              item is ReaderItemPage &&
              item.chapter.id == activeChapterId.value &&
              item.pageIndex == 0,
        );
        if (start < 0) return;
        currentPageInChapter.value = pageWithinChapter;
        if (scrollController.isAttached) {
          scrollController.jumpTo(index: start + pageWithinChapter);
        }
      },
      onPrevious: () =>
          _stepBy(scrollController, positionsListener, isNext: false),
      onNext: () =>
          _stepBy(scrollController, positionsListener, isNext: true),
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

  /// Returns the chapter `offset` positions away from the chapter with
  /// id `relativeTo` in the manga's reading-order chapter list. Returns
  /// null if it would fall off either end.
  static ChapterDto? _findAdjacentChapter(
    List<ChapterDto>? chapters,
    int relativeTo, {
    required int offset,
  }) {
    if (chapters == null) return null;
    final i = chapters.indexWhere((c) => c.id == relativeTo);
    if (i == -1) return null;
    final target = i + offset;
    if (target < 0 || target >= chapters.length) return null;
    return chapters[target];
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

  /// Tap-zone / hardware-button stepping. Moves by one item in the
  /// scrollable, which spans chapters in this multi-chapter list.
  static void _stepBy(
    ItemScrollController scrollController,
    ItemPositionsListener positionsListener, {
    required bool isNext,
  }) {
    final positions = positionsListener.itemPositions.value.toList();
    if (positions.isEmpty) return;
    final mostVisible = _mostVisibleIndex(positions);
    if (mostVisible == null) return;
    final target = isNext ? mostVisible + 1 : (mostVisible - 1).clamp(0, 1 << 30);
    if (scrollController.isAttached) {
      scrollController.jumpTo(index: target, alignment: 0);
    }
  }
}
