// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';
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
import '../../controller/reader_chapter_logic.dart';
import '../../controller/reader_controller.dart';
import '../../controller/reader_item.dart';
import '../chapter_separator.dart';
import '../reader_wrapper.dart';

class _Config {
  const _Config._();
  static const int preFetchThreshold = 3;

  /// Dwell time before committing an active-chapter change (see continuous
  /// reader for the same guard against single-frame transient flips).
  static const Duration activeChapterDwellTime = Duration(milliseconds: 500);

  /// Cooldown between successive pre-fetch fires; prevents the rebuild +
  /// scroll-anchor jumpTo race from re-triggering pre-fetch repeatedly.
  /// Same idea as continuous reader.
  static const Duration prefetchCooldown = Duration(milliseconds: 800);
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

    // Debounced save of mid-chapter progress for the active chapter.
    final progressSaveDebounce = useRef<Timer?>(null);

    // Dwell-time debounce on active-chapter changes (see _Config).
    final activeChapterDwellTimer = useRef<Timer?>(null);

    // Current scroll direction, updated from ScrollNotification below.
    // Starts at `neutral` so neither pre-fetch fires on initial render.
    // (Named with a `Ref` suffix to avoid shadowing the widget's
    // `scrollDirection: Axis` constructor parameter.)
    final scrollDirectionRef =
        useRef<ScrollDirection>(ScrollDirection.neutral);

    // Cooldown timestamp; pre-fetch is rate-limited to avoid re-firing
    // during the rebuild + scroll-anchor jumpTo gap.
    final prefetchCooldownUntil = useRef<DateTime?>(null);

    Future<void> markChapterAsRead(int chapterId) async {
      if (markedAsRead.value.contains(chapterId)) return;
      markedAsRead.value = {...markedAsRead.value, chapterId};
      final result = await AsyncValue.guard(
        () => ref.read(mangaBookRepositoryProvider).putChapter(
              chapterId: chapterId,
              patch: ChapterChange(lastPageRead: 0, isRead: true),
            ),
      );
      if (result.hasError) {
        final next = {...markedAsRead.value}..remove(chapterId);
        markedAsRead.value = next;
        return;
      }
      ref.invalidate(chapterProvider(chapterId: chapterId));
      ref.invalidate(mangaChapterListProvider(mangaId: manga.id));
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
          // Dwell-time guard: don't flip active until the cursor has
          // stayed in the new chapter for activeChapterDwellTime. A
          // momentary cross during fast PageView animation should not
          // trigger mark-as-read.
          activeChapterDwellTimer.value?.cancel();
          activeChapterDwellTimer.value =
              Timer(_Config.activeChapterDwellTime, () {
            if (!pageController.hasClients) return;
            final livePage = pageController.page?.round();
            if (livePage == null ||
                livePage < 0 ||
                livePage >= items.length) {
              return;
            }
            final liveItem = items[livePage];
            if (liveItem.owningChapter.id != cursorChapterId) return;
            if (cursorChapterId == activeChapterId.value) return;

            final outgoing = activeChapterId.value;
            activeChapterId.value = cursorChapterId;
            currentPageInChapter.value =
                liveItem is ReaderItemPage ? liveItem.pageIndex : 0;
            markChapterAsRead(outgoing);
          });
        } else {
          activeChapterDwellTimer.value?.cancel();
        }

        final orderInfo = mangaChapterList == null
            ? const <ChapterOrderInfo>[]
            : [
                for (final c in mangaChapterList)
                  ChapterOrderInfo(
                    id: c.id,
                    chapterNumber: c.chapterNumber,
                  ),
              ];

        // Pre-fetch decisions gated on scroll direction; see continuous
        // reader for the full rationale (the page-zero-then-scroll-forward
        // cascade that was eating chapters). Cooldown gates re-fire
        // during the rebuild + scroll-anchor jumpTo gap.
        final canFire = canPrefetch(
          now: DateTime.now(),
          cooldownUntil: prefetchCooldownUntil.value,
        );

        if (canFire &&
            shouldPrefetchForward(
              mostVisibleIndex: pageIndex,
              itemsLength: items.length,
              threshold: _Config.preFetchThreshold,
              direction: scrollDirectionRef.value,
            )) {
          final lastLoadedId = loadedChapterIds.value.last;
          final nextId = findAdjacentChapterId(
            orderInfo,
            lastLoadedId,
            offset: 1,
          );
          if (nextId != null &&
              !loadedChapterIds.value.contains(nextId)) {
            loadedChapterIds.value = [...loadedChapterIds.value, nextId];
            prefetchCooldownUntil.value =
                DateTime.now().add(_Config.prefetchCooldown);
          }
        }

        if (canFire &&
            shouldPrefetchBackward(
              mostVisibleIndex: pageIndex,
              threshold: _Config.preFetchThreshold,
              direction: scrollDirectionRef.value,
            )) {
          final firstLoadedId = loadedChapterIds.value.first;
          final prevId = findAdjacentChapterId(
            orderInfo,
            firstLoadedId,
            offset: -1,
          );
          if (prevId != null &&
              !loadedChapterIds.value.contains(prevId)) {
            loadedChapterIds.value = [prevId, ...loadedChapterIds.value];
            prefetchCooldownUntil.value =
                DateTime.now().add(_Config.prefetchCooldown);
          }
        }
      }

      pageController.addListener(listener);
      return () => pageController.removeListener(listener);
    });

    // Debounced save of in-progress reading position for the active
    // chapter. Mirrors the prior reader_screen.onPageChanged behaviour.
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
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification) {
            final delta = notification.scrollDelta ?? 0;
            if (delta > 0) {
              scrollDirectionRef.value = ScrollDirection.down;
            } else if (delta < 0) {
              scrollDirectionRef.value = ScrollDirection.up;
            }
          } else if (notification is ScrollEndNotification) {
            scrollDirectionRef.value = ScrollDirection.neutral;
          }
          return false;
        },
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
      ),
    );
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
