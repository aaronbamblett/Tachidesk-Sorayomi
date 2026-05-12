// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Visible diagnostic overlay for the pinch-zoom investigation. Not a fix
// for #256 — a way for Aaron to OBSERVE on hardware whether pointer
// events reach `ZoomView` and whether its scale recognizer fires.
//
// Renders a small corner widget showing three live counters:
//   pd  — pointer-down events arriving at the ZoomView layer
//   ss  — ZoomView scale recognizer fires (onScaleChanged invocations)
//   pe  — outer DirectionalSwipeGestureHandler pan / drag-end fires
//
// Reading these on a real-device pinch tells us where the gesture is
// being consumed. Strip out after the cause is localized.

import 'package:flutter/material.dart';

class ReaderGestureDiagnostics {
  ReaderGestureDiagnostics._();
  static final instance = ReaderGestureDiagnostics._();

  final pointerDowns = ValueNotifier<int>(0);
  final scaleEvents = ValueNotifier<int>(0);
  final outerPanEnds = ValueNotifier<int>(0);
  final lastScale = ValueNotifier<double>(1.0);

  void bumpPointerDown() => pointerDowns.value++;
  void bumpScaleEvent(double scale) {
    scaleEvents.value++;
    lastScale.value = scale;
  }
  void bumpOuterPanEnd() => outerPanEnds.value++;

  void reset() {
    pointerDowns.value = 0;
    scaleEvents.value = 0;
    outerPanEnds.value = 0;
    lastScale.value = 1.0;
  }
}

class ReaderGestureDiagnosticsOverlay extends StatelessWidget {
  const ReaderGestureDiagnosticsOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final d = ReaderGestureDiagnostics.instance;
    return Positioned(
      top: 96,
      right: 6,
      child: Material(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: d.reset,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'DBG (tap=reset)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: d.pointerDowns,
                    builder: (_, v, __) => Text('pd: $v'),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: d.scaleEvents,
                    builder: (_, v, __) => Text('ss: $v'),
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: d.lastScale,
                    builder: (_, v, __) =>
                        Text('sc: ${v.toStringAsFixed(2)}'),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: d.outerPanEnds,
                    builder: (_, v, __) => Text('pe: $v'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
