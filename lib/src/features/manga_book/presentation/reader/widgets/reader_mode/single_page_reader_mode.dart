// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../../constants/app_constants.dart';
import '../../../../../../utils/extensions/cache_manager_extensions.dart';
import '../../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../../utils/misc/app_utils.dart';
import '../../../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../../../../widgets/server_image.dart';
import '../../../../../settings/presentation/reader/widgets/reader_scroll_animation_tile/reader_scroll_animation_tile.dart';
import '../../../../data/manga_book/manga_book_repository.dart';
import '../../../../domain/chapter/chapter_model.dart';
import '../../../../domain/chapter_batch/chapter_batch_model.dart';
import '../../../../domain/manga/manga_model.dart';
import '../../../manga_details/controller/manga_details_controller.dart';
import '../../controller/reader_controller.dart';
import '../../controller/reader_item.dart';
import '../chapter_separator.dart';
import '../reader_wrapper.dart';

class _Config {
  const _Config._();
  static const int preFetchThreshold = 3;
}

class SinglePageReaderMode extends HookConsumerWidget {
  const SinglePageReaderMode({
    super.key,
    required this.manga,
    required this.initialChapterId,
    this.reverse = false,
    this.scrollDirection = Axis.horizontal,
    this.showReaderLayoutAnimation = false,
  });

  final MangaDto manga;
  final int initialChapterId;
  final bool reverse;
  final Axis scrollDirection;
  final bool showReaderLayoutAnimation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cacheManager = useMemoized(() => DefaultCacheManager());

    final mangaChapterList = ref
        .watch(mangaChapterListProvider(mangaId: manga.id))
        .valueOrNull;

    // Loaded chapter set — grows in either direction as the user
    // approaches a boundary. Same shape as the continuous reader.
    final loadedChapterIds = useState<List<int>>([initialChapterId]);

    // Active chapter / page state — derived from PageController.page,
    // never drives the items list shape.
    final activeChapterId = useState<int>(initialChapterId);
    final currentPageInChapter = useState<int>(0);

    final anchorChapterId = useState<int>(initialChapterId);
    final anchorPageIndex = useState<int>(0);

    final markedAsRead = useRef<Set<int>>(<int>{});

    Future<void> markChapterAsRead(int chapterId) async {
      if (markedAsRead.value.contains(chapterId)) return;
      markedAsRead.value = {...markedAsRead.value, chapterId};
      await AsyncValue.guard(
        () => ref.read(mangaBookRepositoryProvider).putChapter(
              chapterId: chapterId,
              patch: ChapterChange(lastPageRead: 0, isRead: true),
            ),
      );
    }

    // Build items list locally from loaded chapters.
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

    // Initial page index in the items list for the route's chapter +
    // lastPageRead.
    final initialIndex = _initialPageIndex(items, initialChapterId);

    // PageController bound to that initial index. Re-memo if items size
    // crosses zero (e.g. initial load) so the controller picks up the
    // correct initial page.
    final pageController = useMemoized(
      () => PageController(initialPage: initialIndex.clamp(0, 1 << 30)),
      [items.isEmpty],
    );

    // Anchor preservation: when items list grows at the start (previous
    // chapter just loaded), the anchor's global index jumps. Compensate
    // with jumpToPage. Same idea as the continuous reader.
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
        if (pageController.hasClients) {
          final currentPage = pageController.page?.round();
          if (currentPage != null && currentPage != anchorGlobalIndex) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (pageController.hasClients) {
                pageController.jumpToPage(anchorGlobalIndex);
              }
            });
          }
        }
      }
      previousItemsLength.value = items.length;
      return null;
    });

    // Page-controller listener: derive active chapter + current page,
    // mark-as-read on chapter completion, pre-fetch in both directions.
    useEffect(() {
      void listener() {
        if (!pageController.hasClients) return;
        final pageDouble = pageController.page;
        if (pageDouble == null) return;
        final pageIndex = pageDouble.round();
        if (pageIndex < 0 || pageIndex >= items.length) return;

        final item = items[pageIndex];

        anchorChapterId.value = item.owningChapter.id;
        anchorPageIndex.value =
            item is ReaderItemPage ? item.pageIndex : 0;

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
          markChapterAsRead(outgoing);
        }

        if (pageIndex >= items.length - _Config.preFetchThreshold) {
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

        if (pageIndex < _Config.preFetchThreshold) {
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

      pageController.addListener(listener);
      return () => pageController.removeListener(listener);
    });

    // Eager prefetch of adjacent pages WITHIN the active chapter (the
    // existing single-page behaviour). Cross-chapter prefetch is handled
    // by the boundary-driven loadedChapterIds growth above.
    useEffect(() {
      final pageList = activeChapterPages?.pages;
      if (pageList == null || pageList.isEmpty) return null;
      final p = currentPageInChapter.value;
      if (p > 0 && p - 1 < pageList.length) {
        cacheManager.getServerFile(ref, pageList[p - 1]);
      }
      if (p < pageList.length - 1) {
        cacheManager.getServerFile(ref, pageList[p + 1]);
      }
      if (p < pageList.length - 2) {
        cacheManager.getServerFile(ref, pageList[p + 2]);
      }
      return null;
    }, [currentPageInChapter.value, activeChapterPages?.pages.length]);

    final isAnimationEnabled =
        ref.read(readerScrollAnimationProvider).ifNull(true);

    if (activeChapter == null || activeChapterPages == null) {
      return const Center(child: CenterSorayomiShimmerIndicator());
    }

    return ReaderWrapper(
      scrollDirection: scrollDirection,
      chapter: activeChapter,
      manga: manga,
      chapterPages: activeChapterPages,
      currentIndex: currentPageInChapter.value,
      onChanged: (pageWithinChapter) {
        final start = items.indexWhere(
          (item) =>
              item is ReaderItemPage &&
              item.chapter.id == activeChapterId.value &&
              item.pageIndex == 0,
        );
        if (start < 0) return;
        if (pageController.hasClients) {
          pageController.jumpToPage(start + pageWithinChapter);
        }
      },
      showReaderLayoutAnimation: showReaderLayoutAnimation,
      onPrevious: () => pageController.previousPage(
        duration: isAnimationEnabled ? kDuration : kInstantDuration,
        curve: kCurve,
      ),
      onNext: () => pageController.nextPage(
        duration: isAnimationEnabled ? kDuration : kInstantDuration,
        curve: kCurve,
      ),
      pageController: pageController,
      child: PageView.builder(
        scrollDirection: scrollDirection,
        reverse: reverse,
        controller: pageController,
        allowImplicitScrolling: true,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        itemBuilder: (BuildContext context, int index) {
          if (items.isEmpty || index >= items.length) {
            return const Center(child: CenterSorayomiShimmerIndicator());
          }
          final item = items[index];
          switch (item) {
            case ReaderItemPage():
              final image = ServerImage(
                showReloadButton: true,
                fit: BoxFit.contain,
                size: Size.fromHeight(context.height),
                appendApiToUrl: false,
                imageUrl: item.url,
                progressIndicatorBuilder:
                    (context, url, downloadProgress) =>
                        CenterSorayomiShimmerIndicator(
                  value: downloadProgress.progress,
                ),
              );
              return AppUtils.wrapOn(
                !kIsWeb && (Platform.isAndroid || Platform.isIOS)
                    ? (child) =>
                        InteractiveViewer(maxScale: 5, child: child)
                    : null,
                image,
              );
            case ReaderItemSeparator():
              return Center(
                child: ChapterSeparator(
                  manga: manga,
                  chapter: item.endingChapter,
                  isPreviousChapterSeparator: false,
                ),
              );
          }
        },
        itemCount: items.isEmpty ? 1 : items.length,
      ),
    );
  }

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

  static int _initialPageIndex(
    List<ReaderItem> items,
    int initialChapterId,
  ) {
    if (items.isEmpty) return 0;
    final firstPageOfInitial = items.indexWhere(
      (item) =>
          item is ReaderItemPage &&
          item.chapter.id == initialChapterId &&
          item.pageIndex == 0,
    );
    if (firstPageOfInitial < 0) return 0;
    // The active chapter object is loaded later; for the initial render
    // we assume the route is opening at lastPageRead by reading it from
    // the first page item's chapter property.
    final firstItem = items[firstPageOfInitial];
    if (firstItem is ReaderItemPage) {
      final isRead = firstItem.chapter.isRead.ifNull();
      final lastPageRead =
          firstItem.chapter.lastPageRead.getValueOnNullOrNegative();
      return firstPageOfInitial + (isRead ? 0 : lastPageRead);
    }
    return firstPageOfInitial;
  }
}
