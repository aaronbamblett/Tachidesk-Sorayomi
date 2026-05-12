// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/reader/controller/reader_chapter_logic.dart';

ChapterOrderInfo _ch(int id, double n) =>
    ChapterOrderInfo(id: id, chapterNumber: n);

void main() {
  group('findAdjacentChapterId', () {
    test('returns null on empty list', () {
      expect(findAdjacentChapterId(const [], 1, offset: 1), isNull);
    });

    test('returns null if relativeTo not in list', () {
      expect(
        findAdjacentChapterId([_ch(1, 1), _ch(2, 2)], 99, offset: 1),
        isNull,
      );
    });

    test('returns null at end of list (offset +1 on last chapter)', () {
      expect(
        findAdjacentChapterId([_ch(1, 1), _ch(2, 2)], 2, offset: 1),
        isNull,
      );
    });

    test('returns null at start of list (offset -1 on first chapter)', () {
      expect(
        findAdjacentChapterId([_ch(1, 1), _ch(2, 2)], 1, offset: -1),
        isNull,
      );
    });

    test('next chapter from an in-reading-order list', () {
      final chapters = [_ch(1, 1), _ch(2, 2), _ch(3, 3)];
      expect(findAdjacentChapterId(chapters, 2, offset: 1), 3);
    });

    test('previous chapter from an in-reading-order list', () {
      final chapters = [_ch(1, 1), _ch(2, 2), _ch(3, 3)];
      expect(findAdjacentChapterId(chapters, 2, offset: -1), 1);
    });

    test('next chapter is correct when input list is in descending order', () {
      // The server sometimes returns chapters newest-first.
      final chapters = [_ch(3, 3), _ch(2, 2), _ch(1, 1)];
      expect(findAdjacentChapterId(chapters, 2, offset: 1), 3);
    });

    test('previous chapter is correct when input list is in descending order',
        () {
      final chapters = [_ch(3, 3), _ch(2, 2), _ch(1, 1)];
      expect(findAdjacentChapterId(chapters, 2, offset: -1), 1);
    });

    test('next chapter respects chapter number, not insertion order', () {
      // Real-world case from a live query: chapters 1..53 were fetched
      // first (newest to oldest, so chapter 53 got the lowest id), then
      // chapters 112..120 were appended later (got the highest ids).
      // Database ids reflect insertion order, NOT reading order. The
      // user opens chapter 25 and "next" must be 26, not whatever
      // happens to be at index+1 in the raw list.
      final chapters = [
        // First batch: chapter numbers 53 down to 1.
        // chapter 53 → id 174, chapter 52 → id 175, ..., chapter 1 → id 226.
        // So chapter N has id (174 + (53 - N)).
        for (var n = 53; n >= 1; n--) _ch(174 + (53 - n), n.toDouble()),
        // Second batch: chapter numbers 112..120, ids 289..297.
        for (var n = 112; n <= 120; n++) _ch(289 + (n - 112), n.toDouble()),
      ];
      // Chapter 25 has id 174 + (53 - 25) = 202.
      // Chapter 26 has id 174 + (53 - 26) = 201.
      const chapter25Id = 202;
      const chapter26Id = 201;
      expect(
        findAdjacentChapterId(chapters, chapter25Id, offset: 1),
        chapter26Id,
      );
      final ch26 = chapters.firstWhere((c) => c.id == chapter26Id);
      expect(ch26.chapterNumber, 26.0);
    });

    test('previous chapter from a chapter at the boundary of the two batches',
        () {
      // Real-world case: chapter 53 is the last of the "old" batch,
      // and the "next" chapter after it in reading order is the first
      // of the "new" batch — chapter 112, NOT chapter 54 (which doesn't
      // exist) and NOT the chapter that happens to be at index+1 in
      // the raw list.
      final chapters = [
        for (var n = 53; n >= 1; n--) _ch(174 + (53 - n), n.toDouble()),
        for (var n = 112; n <= 120; n++) _ch(289 + (n - 112), n.toDouble()),
      ];
      // Chapter 53 has id = 174
      expect(findAdjacentChapterId(chapters, 174, offset: 1), 289);
      // And id 289 is chapter 112
      final ch112 = chapters.firstWhere((c) => c.id == 289);
      expect(ch112.chapterNumber, 112.0);
    });

    test('handles decimal chapter numbers (e.g. 1.5 between 1 and 2)', () {
      final chapters = [
        _ch(10, 1.0),
        _ch(11, 2.0),
        _ch(12, 1.5),
      ];
      // Next after chapter 1 should be chapter 1.5
      expect(findAdjacentChapterId(chapters, 10, offset: 1), 12);
      // Next after chapter 1.5 should be chapter 2
      expect(findAdjacentChapterId(chapters, 12, offset: 1), 11);
    });
  });

  group('orderChapterIdsForReading', () {
    test('returns ids in chapter-number ascending order regardless of input',
        () {
      final chapters = [_ch(3, 3), _ch(1, 1), _ch(2, 2)];
      expect(orderChapterIdsForReading(chapters), [1, 2, 3]);
    });

    test('handles the descending-then-appended real-world ordering', () {
      final chapters = [
        for (var n = 53; n >= 1; n--) _ch(174 + (53 - n), n.toDouble()),
        for (var n = 112; n <= 120; n++) _ch(289 + (n - 112), n.toDouble()),
      ];
      final ordered = orderChapterIdsForReading(chapters);
      // First five should be chapter 1, 2, 3, 4, 5
      expect(ordered.take(5).toList(), [226, 225, 224, 223, 222]);
      // Last five should be chapter 116, 117, 118, 119, 120
      expect(ordered.skip(ordered.length - 5).toList(),
          [293, 294, 295, 296, 297]);
    });
  });
}
