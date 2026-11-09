// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/gestures.dart';

class MiddleButtonDoubleClick {
  PointerDownEvent? _down;
  PointerUpEvent? _previous;

  void reset() {
    _down = null;
    _previous = null;
  }

  void down(PointerDownEvent event) {
    if (_down != null ||
        event.kind != PointerDeviceKind.mouse ||
        event.buttons != kMiddleMouseButton) {
      reset();
      return;
    }
    _down = event;
  }

  void move(PointerMoveEvent event) {
    if (_down?.pointer == event.pointer &&
        (event.buttons != kMiddleMouseButton ||
            (event.position - _down!.position).distance >
                kDoubleTapTouchSlop)) {
      reset();
    }
  }

  bool up(PointerUpEvent event) {
    final down = _down;
    _down = null;
    if (down == null ||
        down.pointer != event.pointer ||
        event.timeStamp < down.timeStamp ||
        event.timeStamp - down.timeStamp > kDoubleTapTimeout ||
        (event.position - down.position).distance > kDoubleTapTouchSlop) {
      _previous = null;
      return false;
    }
    final previous = _previous;
    if (previous != null &&
        previous.device == down.device &&
        down.timeStamp >= previous.timeStamp &&
        down.timeStamp - previous.timeStamp <= kDoubleTapTimeout &&
        (down.position - previous.position).distance <= kDoubleTapSlop) {
      _previous = null;
      return true;
    }
    _previous = event;
    return false;
  }
}
