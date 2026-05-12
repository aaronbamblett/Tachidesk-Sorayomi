// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../constants/enum.dart';
import '../../../../utils/extensions/custom_extensions.dart';
import '../../../settings/presentation/reader/widgets/reader_ignore_safe_area_tile/reader_ignore_safe_area_tile.dart';
import '../../../settings/presentation/reader/widgets/reader_mode_tile/reader_mode_tile.dart';
import '../../domain/manga/manga_model.dart';
import '../manga_details/controller/manga_details_controller.dart';
import 'controller/reader_controller.dart';
import 'widgets/reader_mode/continuous_reader_mode.dart';
import 'widgets/reader_mode/single_page_reader_mode.dart';

class ReaderScreen extends HookConsumerWidget {
  const ReaderScreen({
    super.key,
    required this.mangaId,
    required this.chapterId,
    this.showReaderLayoutAnimation = false,
  });
  final int mangaId;
  final int chapterId;
  final bool showReaderLayoutAnimation;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mangaProvider = mangaWithIdProvider(mangaId: mangaId);
    final chapterProviderWithIndex = chapterProvider(chapterId: chapterId);
    final chapterPages = ref.watch(chapterPagesProvider(chapterId: chapterId));
    final manga = ref.watch(mangaProvider);
    final chapter = ref.watch(chapterProviderWithIndex);
    final defaultReaderMode = ref.watch(readerModeKeyProvider);
    final ignoreSafeArea = ref.watch(readerIgnoreSafeAreaProvider).ifNull();

    // Mark-as-read, onPageChanged debounce, and last-page tracking are
    // owned by the reader-mode widgets themselves now — they have the
    // multi-chapter context this screen-level wrapper lacks.

    useEffect(() {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      return () => SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.manual,
            overlays: SystemUiOverlay.values,
          );
    }, []);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          ref.invalidate(chapterProviderWithIndex);
          ref.invalidate(mangaChapterListProvider(mangaId: mangaId));
        }
      },
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SafeArea(
          top: !ignoreSafeArea,
          bottom: !ignoreSafeArea,
          left: !ignoreSafeArea,
          right: !ignoreSafeArea,
          child: manga.showUiWhenData(
            context,
            (data) {
              if (data == null) return const SizedBox.shrink();
              return chapter.showUiWhenData(
                context,
                (chapterData) {
                  if (chapterData == null) return const SizedBox.shrink();
                  return chapterPages.showUiWhenData(
                    context,
                    (chapterPagesData) {
                      if (chapterPagesData == null) {
                        return const SizedBox.shrink();
                      }
                      return switch (
                          data.metaData.readerMode ?? defaultReaderMode) {
                        ReaderMode.singleVertical => SinglePageReaderMode(
                            initialChapterId: chapterId,
                            manga: data,
                            scrollDirection: Axis.vertical,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,),
                        ReaderMode.singleHorizontalRTL => SinglePageReaderMode(
                            initialChapterId: chapterId,
                            manga: data,
                            reverse: true,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,),
                        ReaderMode.continuousHorizontalLTR =>
                          ContinuousReaderMode(
                            initialChapterId: chapterId,
                            manga: data,
                            scrollDirection: Axis.horizontal,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,),
                        ReaderMode.continuousHorizontalRTL =>
                          ContinuousReaderMode(
                            initialChapterId: chapterId,
                            manga: data,
                            scrollDirection: Axis.horizontal,
                            reverse: true,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,),
                        ReaderMode.singleHorizontalLTR => SinglePageReaderMode(
                            initialChapterId: chapterId,
                            manga: data,),
                        ReaderMode.continuousVertical => ContinuousReaderMode(
                            initialChapterId: chapterId,
                            manga: data,
                            showSeparator: true,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,),
                        ReaderMode.webtoon => ContinuousReaderMode(
                            initialChapterId: chapterId,
                            manga: data,
                            showReaderLayoutAnimation:
                                showReaderLayoutAnimation,),
                        ReaderMode.defaultReader || null => switch (
                              defaultReaderMode ?? ReaderMode.webtoon) {
                            ReaderMode.singleHorizontalLTR =>
                              SinglePageReaderMode(
                                initialChapterId: chapterId,
                                manga: data,),
                            ReaderMode.singleHorizontalRTL =>
                              SinglePageReaderMode(
                                initialChapterId: chapterId,
                                manga: data,
                                reverse: true,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,),
                            ReaderMode.singleVertical => SinglePageReaderMode(
                                initialChapterId: chapterId,
                                manga: data,
                                scrollDirection: Axis.vertical,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,),
                            ReaderMode.continuousHorizontalLTR =>
                              ContinuousReaderMode(
                                initialChapterId: chapterId,
                                manga: data,
                                scrollDirection: Axis.horizontal,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,),
                            ReaderMode.continuousHorizontalRTL =>
                              ContinuousReaderMode(
                                initialChapterId: chapterId,
                                manga: data,
                                scrollDirection: Axis.horizontal,
                                reverse: true,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,),
                            ReaderMode.continuousVertical =>
                              ContinuousReaderMode(
                                initialChapterId: chapterId,
                                manga: data,
                                showSeparator: true,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,),
                            ReaderMode.webtoon || _ => ContinuousReaderMode(
                                initialChapterId: chapterId,
                                manga: data,
                                showReaderLayoutAnimation:
                                    showReaderLayoutAnimation,),
                          }
                      };
                    },
                  );
                },
                refresh: () => ref.refresh(chapterProviderWithIndex.future),
                addScaffoldWrapper: true,
              );
            },
            addScaffoldWrapper: true,
            refresh: () => ref.refresh(mangaProvider.future),
          ),
        ),
      ),
    );
  }
}
