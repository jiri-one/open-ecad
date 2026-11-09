// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/middle_button_double_click.dart';

void main() {
  bool click(
    MiddleButtonDoubleClick recognizer,
    int time, {
    int buttons = kMiddleMouseButton,
    int device = 1,
  }) {
    recognizer.down(
      PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        device: device,
        buttons: buttons,
        position: const Offset(100, 100),
        timeStamp: Duration(milliseconds: time),
      ),
    );
    return recognizer.up(
      PointerUpEvent(
        kind: PointerDeviceKind.mouse,
        device: device,
        position: const Offset(100, 100),
        timeStamp: Duration(milliseconds: time + 30),
      ),
    );
  }

  test('two middle clicks fit once, with a fresh pair required afterward', () {
    final recognizer = MiddleButtonDoubleClick();
    expect(click(recognizer, 100), isFalse);
    expect(click(recognizer, 230), isTrue);
    expect(click(recognizer, 360), isFalse);
    expect(click(recognizer, 490), isTrue);
  });

  test('slow clicks, other devices and button chords do not form a pair', () {
    final recognizer = MiddleButtonDoubleClick();
    expect(click(recognizer, 100), isFalse);
    expect(click(recognizer, 700), isFalse);
    expect(click(recognizer, 830, device: 2), isFalse);
    expect(
      click(recognizer, 960, buttons: kMiddleMouseButton | kPrimaryMouseButton),
      isFalse,
    );
    expect(click(recognizer, 1090), isFalse);
    expect(click(recognizer, 1220), isTrue);
  });

  test('reset cancels a previous click and an in-progress press', () {
    final recognizer = MiddleButtonDoubleClick();
    click(recognizer, 100);
    recognizer.reset();
    expect(click(recognizer, 230), isFalse);
    recognizer.down(
      const PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
        timeStamp: Duration(milliseconds: 300),
      ),
    );
    recognizer.reset();
    expect(
      recognizer.up(
        const PointerUpEvent(timeStamp: Duration(milliseconds: 330)),
      ),
      isFalse,
    );
    expect(click(recognizer, 400), isFalse);
  });

  test(
    'moving away and back is a drag even if the release position matches',
    () {
      final recognizer = MiddleButtonDoubleClick();
      recognizer.down(
        const PointerDownEvent(
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
          position: Offset(100, 100),
          timeStamp: Duration(milliseconds: 100),
        ),
      );
      recognizer.move(
        const PointerMoveEvent(
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
          position: Offset(140, 100),
          timeStamp: Duration(milliseconds: 120),
        ),
      );
      expect(
        recognizer.up(
          const PointerUpEvent(
            kind: PointerDeviceKind.mouse,
            position: Offset(100, 100),
            timeStamp: Duration(milliseconds: 150),
          ),
        ),
        isFalse,
      );
      expect(click(recognizer, 230), isFalse);
    },
  );
}
