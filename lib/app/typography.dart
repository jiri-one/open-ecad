// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/interface_preferences.dart';

class InterfacePreferencesScope
    extends InheritedNotifier<InterfacePreferences> {
  const InterfacePreferencesScope({
    super.key,
    required InterfacePreferences preferences,
    required super.child,
  }) : super(notifier: preferences);

  static InterfacePreferences? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<InterfacePreferencesScope>()
          ?.notifier;
}

@immutable
class InterfaceTextScaler extends TextScaler {
  const InterfaceTextScaler({
    required this.system,
    this.fontSize = 14,
    this.magnification = 1,
    this.gtkFontScale,
  });

  final TextScaler system;
  final double fontSize, magnification;
  final double? gtkFontScale;

  @override
  double scale(double fontSize) {
    final size = fontSize * this.fontSize / 14;
    final platformSize = system.scale(size);
    final gtkScale = gtkFontScale;
    if (gtkScale == null || gtkScale == 1) return platformSize * magnification;
    if (system == TextScaler.noScaling) return size * gtkScale * magnification;
    // GTK's DPI can already include the platform accessibility scale.
    return math.max(platformSize, size * gtkScale) * magnification;
  }

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is InterfaceTextScaler &&
      other.system == system &&
      other.fontSize == fontSize &&
      other.magnification == magnification &&
      other.gtkFontScale == gtkFontScale;

  @override
  int get hashCode =>
      Object.hash(system, fontSize, magnification, gtkFontScale);
}

double interfaceLineHeight(BuildContext context, {double fontSize = 14}) {
  final painter = TextPainter(
    text: TextSpan(
      text: 'Ágj',
      style: Theme.of(
        context,
      ).textTheme.bodyMedium!.copyWith(fontSize: fontSize),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

double interfaceRowHeight(
  BuildContext context, {
  double minimum = 40,
  double fontSize = 14,
  double padding = 8,
}) => math.max(
  minimum,
  interfaceLineHeight(context, fontSize: fontSize) + padding,
);
