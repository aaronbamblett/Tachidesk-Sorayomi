// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Pure helpers for the multi-chapter reader. Decoupled from `ChapterDto`
// (which is graphql_codegen-generated and painful to construct in tests)
// so this logic can be unit-tested without a widget harness.

/// Minimal info about a chapter needed for reading-order math: the id and
/// the chapter number used to sort.
class ChapterOrderInfo {
  const ChapterOrderInfo({
    required this.id,
    required this.chapterNumber,
  });

  final int id;
  final double chapterNumber;

  @override
  bool operator ==(Object other) =>
      other is ChapterOrderInfo &&
      other.id == id &&
      other.chapterNumber == chapterNumber;

  @override
  int get hashCode => Object.hash(id, chapterNumber);

  @override
  String toString() =>
      'ChapterOrderInfo(id: $id, chapterNumber: $chapterNumber)';
}

/// Returns the id of the chapter `offset` positions away from the chapter
/// whose id is `relativeTo`, in chapter-number-ascending reading order.
/// Returns null if that target would fall off either end of the list, or
/// if `relativeTo` is not in `chapters`.
///
/// The raw chapter list returned by Suwayomi reflects server insertion
/// order, NOT reading order. A live query against the production server
/// produced an order like `[53, 52, 51, ..., 1, 112, 113, ..., 120]` — the
/// later chapters were inserted later (higher database ids) but go in a
/// different position in the reading sequence. Sorting on `chapterNumber`
/// is the only correct way to walk adjacency.
int? findAdjacentChapterId(
  List<ChapterOrderInfo> chapters,
  int relativeTo, {
  required int offset,
}) {
  if (chapters.isEmpty) return null;
  final sorted = [...chapters]
    ..sort((a, b) => a.chapterNumber.compareTo(b.chapterNumber));
  final i = sorted.indexWhere((c) => c.id == relativeTo);
  if (i == -1) return null;
  final target = i + offset;
  if (target < 0 || target >= sorted.length) return null;
  return sorted[target].id;
}

/// Returns the chapter ids in reading order. The result is always
/// sorted ascending by chapter number regardless of input order.
List<int> orderChapterIdsForReading(List<ChapterOrderInfo> chapters) {
  final sorted = [...chapters]
    ..sort((a, b) => a.chapterNumber.compareTo(b.chapterNumber));
  return [for (final c in sorted) c.id];
}
