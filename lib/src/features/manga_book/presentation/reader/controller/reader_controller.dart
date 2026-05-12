// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../data/manga_book/manga_book_repository.dart';
import '../../../domain/chapter/chapter_model.dart';
import '../../../domain/chapter_page/chapter_page_model.dart';
import '../../manga_details/controller/manga_details_controller.dart';
import 'reader_item.dart';

part 'reader_controller.g.dart';

@riverpod
FutureOr<ChapterDto?> chapter(
  Ref ref, {
  required int chapterId,
}) =>
    ref.watch(mangaBookRepositoryProvider).getChapter(chapterId: chapterId);

@riverpod
Future<ChapterPagesDto?> chapterPages(Ref ref, {required int chapterId}) => ref
    .watch(mangaBookRepositoryProvider)
    .getChapterPages(chapterId: chapterId);

/// Composes pages from the previous, current, and next chapters of a manga
/// into one ordered `List<ReaderItem>`, with chapter separators at the
/// seams. The continuous and single-page readers consume this list directly
/// so chapter-to-chapter transitions are inline rather than route-driven.
///
/// Pre-fetching is automatic: the provider watches `chapterPagesProvider`
/// for both neighbors. When the user scrolls past a boundary, the calling
/// widget bumps `activeChapterId` to the new chapter; this provider
/// re-derives with a fresh trio.
///
/// Behavior on partial loads:
/// - If the current chapter's pages haven't loaded yet, the list is empty.
/// - Neighbor pages that are still loading are simply omitted; the list
///   grows when they arrive.
@riverpod
List<ReaderItem> readerItems(
  Ref ref, {
  required int mangaId,
  required int activeChapterId,
}) {
  final chapters = ref
      .watch(mangaChapterListProvider(mangaId: mangaId))
      .valueOrNull;
  if (chapters == null || chapters.isEmpty) return const [];

  final activeIndex =
      chapters.indexWhere((c) => c.id == activeChapterId);
  if (activeIndex == -1) return const [];

  final prev = activeIndex > 0 ? chapters[activeIndex - 1] : null;
  final current = chapters[activeIndex];
  final next =
      activeIndex < chapters.length - 1 ? chapters[activeIndex + 1] : null;

  final currentPages =
      ref.watch(chapterPagesProvider(chapterId: current.id)).valueOrNull;
  final prevPages = prev != null
      ? ref.watch(chapterPagesProvider(chapterId: prev.id)).valueOrNull
      : null;
  final nextPages = next != null
      ? ref.watch(chapterPagesProvider(chapterId: next.id)).valueOrNull
      : null;

  if (currentPages == null) return const [];

  final items = <ReaderItem>[];

  if (prev != null && prevPages != null) {
    for (var i = 0; i < prevPages.pages.length; i++) {
      items.add(ReaderItemPage(
        chapter: prev,
        pageIndex: i,
        pageCount: prevPages.pages.length,
        url: prevPages.pages[i],
      ));
    }
    items.add(ReaderItemSeparator(
      endingChapter: prev,
      startingChapter: current,
    ));
  }

  for (var i = 0; i < currentPages.pages.length; i++) {
    items.add(ReaderItemPage(
      chapter: current,
      pageIndex: i,
      pageCount: currentPages.pages.length,
      url: currentPages.pages[i],
    ));
  }

  if (next != null) {
    items.add(ReaderItemSeparator(
      endingChapter: current,
      startingChapter: next,
    ));
    if (nextPages != null) {
      for (var i = 0; i < nextPages.pages.length; i++) {
        items.add(ReaderItemPage(
          chapter: next,
          pageIndex: i,
          pageCount: nextPages.pages.length,
          url: nextPages.pages[i],
        ));
      }
    }
  } else {
    items.add(ReaderItemSeparator(
      endingChapter: current,
      startingChapter: null,
    ));
  }

  return items;
}

/// The index in `readerItems` at which the current chapter's first page sits.
/// Used by the reader widget to anchor scroll position across chapter
/// transitions (so the user's viewport doesn't jump when the previous
/// chapter's pages load in or out).
@riverpod
int readerItemsCurrentChapterStart(
  Ref ref, {
  required int mangaId,
  required int activeChapterId,
}) {
  final items = ref.watch(readerItemsProvider(
    mangaId: mangaId,
    activeChapterId: activeChapterId,
  ));
  return items.indexWhere(
    (item) =>
        item is ReaderItemPage &&
        item.chapter.id == activeChapterId &&
        item.pageIndex == 0,
  );
}
