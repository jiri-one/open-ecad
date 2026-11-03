// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

abstract interface class CanvasHoverInfo {
  EcadProject get project;
  String get sheetId;
  Object get targetIdentity;
  String get label;
  String get detail;
  String get tooltip;
  String get semanticsLabel;
}
