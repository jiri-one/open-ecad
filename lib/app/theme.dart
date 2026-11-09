import 'package:flutter/material.dart';

import '../editor/schematic_canvas.dart';

enum EcadAppearance { paper, ink, studio }

extension AppearanceLabel on EcadAppearance {
  String get label => switch (this) {
    EcadAppearance.paper => 'Kontrastní bílý',
    EcadAppearance.ink => 'Kontrastní černý',
    EcadAppearance.studio => 'Barevný',
  };
}

@immutable
class EcadColors extends ThemeExtension<EcadColors> {
  const EcadColors({
    required this.background,
    required this.panel,
    required this.foreground,
    required this.muted,
    required this.border,
    required this.subtle,
    required this.accent,
    required this.onAccent,
    required this.canvas,
    required this.highContrast,
    required this.dark,
  });

  factory EcadColors.forAppearance(EcadAppearance appearance) =>
      switch (appearance) {
        EcadAppearance.paper => const EcadColors(
          background: Colors.white,
          panel: Colors.white,
          foreground: Colors.black,
          muted: Colors.black,
          border: Colors.black,
          subtle: Colors.white,
          accent: Colors.black,
          onAccent: Colors.white,
          canvas: Colors.white,
          highContrast: true,
          dark: false,
        ),
        EcadAppearance.ink => const EcadColors(
          background: Colors.black,
          panel: Colors.black,
          foreground: Colors.white,
          muted: Colors.white,
          border: Colors.white,
          subtle: Colors.black,
          accent: Colors.white,
          onAccent: Colors.black,
          canvas: Colors.black,
          highContrast: true,
          dark: true,
        ),
        EcadAppearance.studio => const EcadColors(
          background: Color(0xFFF5F6F8),
          panel: Colors.white,
          foreground: Color(0xFF20292F),
          muted: Color(0xFF58636D),
          border: Color(0xFFD5DCE2),
          subtle: Color(0xFFF0F3F5),
          accent: Color(0xFF165C4C),
          onAccent: Colors.white,
          canvas: Color(0xFFE6EBEE),
          highContrast: false,
          dark: false,
        ),
      };

  static EcadColors of(BuildContext context) =>
      Theme.of(context).extension<EcadColors>()!;
  final Color background,
      panel,
      foreground,
      muted,
      border,
      subtle,
      accent,
      onAccent,
      canvas;
  final bool highContrast, dark;

  CanvasPalette get canvasPalette => CanvasPalette(
    background: canvas,
    paper: dark ? Colors.black : Colors.white,
    ink: foreground,
    muted: muted,
    grid: highContrast ? foreground : const Color(0xFFBCC6CD),
    selection: accent,
    wire: highContrast ? foreground : const Color(0xFF365C6B),
    sheetBorder: highContrast ? foreground : const Color(0xFF99A6AF),
    highContrast: highContrast,
  );

  @override
  EcadColors copyWith({
    Color? background,
    Color? panel,
    Color? foreground,
    Color? muted,
    Color? border,
    Color? subtle,
    Color? accent,
    Color? onAccent,
    Color? canvas,
    bool? highContrast,
    bool? dark,
  }) => EcadColors(
    background: background ?? this.background,
    panel: panel ?? this.panel,
    foreground: foreground ?? this.foreground,
    muted: muted ?? this.muted,
    border: border ?? this.border,
    subtle: subtle ?? this.subtle,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    canvas: canvas ?? this.canvas,
    highContrast: highContrast ?? this.highContrast,
    dark: dark ?? this.dark,
  );

  @override
  EcadColors lerp(covariant EcadColors? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

ThemeData buildEcadTheme(EcadAppearance appearance, {String? fontFamily}) {
  final c = EcadColors.forAppearance(appearance);
  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: c.dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    surface: c.panel,
    onSurface: c.foreground,
    onSurfaceVariant: c.muted,
    outline: c.border,
    outlineVariant: c.border,
    error: c.highContrast ? c.foreground : const Color(0xFF9F302E),
    onError: c.panel,
    surfaceContainerHighest: c.subtle,
  );
  final body = TextStyle(fontSize: 14, color: c.foreground, height: 1.35);
  final title = body.copyWith(fontWeight: FontWeight.w600);
  final heading = title.copyWith(fontSize: 16, height: 1.25);
  return ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    fontFamilyFallback: const ['NotoSans'],
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    dividerColor: c.border,
    disabledColor: c.muted,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: c.subtle,
    visualDensity: VisualDensity.compact,
    extensions: <ThemeExtension<dynamic>>[c],
    textTheme: TextTheme(
      displayLarge: heading,
      displayMedium: heading,
      displaySmall: heading,
      headlineLarge: heading,
      headlineMedium: heading,
      headlineSmall: heading,
      titleLarge: heading,
      titleMedium: title,
      titleSmall: title,
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: body.copyWith(fontSize: 12, color: c.muted),
      labelSmall: TextStyle(fontSize: 12, color: c.foreground),
      labelMedium: TextStyle(fontSize: 13, color: c.foreground),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: c.foreground,
      ),
    ),
    iconTheme: IconThemeData(color: c.foreground, size: 18),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      textStyle: TextStyle(
        color: c.onAccent,
        fontSize: 13,
        fontFamily: fontFamily,
      ),
      decoration: BoxDecoration(
        color: c.accent,
        borderRadius: BorderRadius.circular(4),
      ),
      waitDuration: const Duration(milliseconds: 600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.panel,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: TextStyle(
        fontSize: 14,
        color: c.muted,
        fontFamily: fontFamily,
      ),
      labelStyle: TextStyle(
        fontSize: 14,
        color: c.muted,
        fontFamily: fontFamily,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: c.accent, width: 2),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: c.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.subtle,
        disabledForegroundColor: c.muted,
        minimumSize: const Size(0, 36),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        textStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamily: fontFamily,
        ),
        animationDuration: Duration.zero,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.foreground,
        side: BorderSide(color: c.border),
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        textStyle: TextStyle(fontSize: 14, fontFamily: fontFamily),
        animationDuration: Duration.zero,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.foreground,
        textStyle: TextStyle(fontSize: 14, fontFamily: fontFamily),
        animationDuration: Duration.zero,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.border),
      ),
      titleTextStyle: heading.copyWith(fontFamily: fontFamily),
    ),
  );
}
