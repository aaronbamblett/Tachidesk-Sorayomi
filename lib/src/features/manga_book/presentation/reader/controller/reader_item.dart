// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import '../../../domain/chapter/chapter_model.dart';

/// One renderable item in the multi-chapter reader.
///
/// The reader composes a single `List<ReaderItem>` by concatenating the
/// loaded pages of the previous, current, and next chapters with separator
/// items between them. The continuous and single-page reader widgets both
/// consume this same list.
sealed class ReaderItem {
  const ReaderItem();

  /// The chapter this item is bound to. For pages, the chapter that owns the
  /// page. For separators, the chapter the user is about to leave (the
  /// chapter ending at this seam) — the reader treats the separator as the
  /// last item of the ending chapter for read-position math.
  ChapterDto get owningChapter;

  /// True when this item is the last page of its chapter (used by the
  /// continuous reader's mark-as-read trigger).
  bool get isLastPageOfChapter;
}

/// A single page of a chapter.
final class ReaderItemPage extends ReaderItem {
  const ReaderItemPage({
    required this.chapter,
    required this.pageIndex,
    required this.pageCount,
    required this.url,
  });

  final ChapterDto chapter;
  final int pageIndex;
  final int pageCount;
  final String url;

  @override
  ChapterDto get owningChapter => chapter;

  @override
  bool get isLastPageOfChapter => pageIndex == pageCount - 1;
}

/// The seam between two chapters. Rendered as a transition widget (chapter
/// title, "next: X" affordance, etc.) inline between page lists.
final class ReaderItemSeparator extends ReaderItem {
  const ReaderItemSeparator({
    required this.endingChapter,
    required this.startingChapter,
  });

  /// The chapter whose pages have just ended.
  final ChapterDto endingChapter;

  /// The chapter the user is about to enter. May be null when the separator
  /// sits at the start (no previous chapter loaded) or end (no next chapter
  /// exists at all).
  final ChapterDto? startingChapter;

  @override
  ChapterDto get owningChapter => endingChapter;

  @override
  bool get isLastPageOfChapter => false;
}
