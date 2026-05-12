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

/// Current scroll direction, used to gate pre-fetch decisions.
///
/// `up` and `down` refer to how the user is moving through the items
/// list, not screen direction: `down` is scrolling toward later items
/// (later pages, next chapter); `up` is scrolling toward earlier items
/// (earlier pages, previous chapter). `neutral` is idle / stationary.
enum ScrollDirection { up, down, neutral }

/// Whether pre-fetch is currently allowed, given the cooldown window.
///
/// After a pre-fetch fires, the items list grows and the
/// scroll-anchor `jumpTo` runs in a post-frame callback. Between those
/// two events the position listener can fire several times with
/// `mostVisibleIndex` still near the boundary, which without a cooldown
/// re-triggers the same pre-fetch and cascades. This gate enforces a
/// minimum interval between fires.
bool canPrefetch({
  required DateTime now,
  required DateTime? cooldownUntil,
}) {
  if (cooldownUntil == null) return true;
  return !now.isBefore(cooldownUntil);
}

/// Whether the reader should pre-fetch the NEXT chapter from the
/// current state.
///
/// Triggers only when:
/// - The user has scrolled close enough to the end of the loaded items
///   list (within `threshold` of `itemsLength`), AND
/// - The user is actively scrolling DOWN (toward later items).
///
/// The direction gate stops a user who is scrolling up near the end of
/// the loaded list (rare, but possible) from triggering a forward
/// pre-fetch they don't want.
bool shouldPrefetchForward({
  required int mostVisibleIndex,
  required int itemsLength,
  required int threshold,
  required ScrollDirection direction,
}) {
  if (itemsLength <= 0) return false;
  if (direction != ScrollDirection.down) return false;
  return mostVisibleIndex >= itemsLength - threshold;
}

/// Whether the reader should pre-fetch the PREVIOUS chapter from the
/// current state.
///
/// Triggers only when:
/// - The user is close to the start of the loaded items list (within
///   `threshold` of index 0), AND
/// - The user is actively scrolling UP (toward earlier items).
///
/// The direction gate is the load-bearing piece: opening a chapter at
/// page 0 puts the user at `mostVisibleIndex < threshold` immediately,
/// and any subsequent scroll (most often forward) used to trigger a
/// backward pre-fetch and prepend a wrong-direction chapter. The
/// direction gate ensures pre-fetch only fires when the user has
/// signalled real intent to read the previous chapter by scrolling up
/// near the boundary.
bool shouldPrefetchBackward({
  required int mostVisibleIndex,
  required int threshold,
  required ScrollDirection direction,
}) {
  if (direction != ScrollDirection.up) return false;
  return mostVisibleIndex < threshold;
}
