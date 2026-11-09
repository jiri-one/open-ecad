// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/app/typography.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/interface_preferences.dart';
import 'package:open_ecad/services/drawing_cursor_settings.dart';
import 'package:open_ecad/services/desktop_window.dart';
import 'package:open_ecad/widgets/components.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_fixtures.dart';

Future<EditorController> mount(WidgetTester tester, {double scale = 1}) async {
  SharedPreferences.setMockInitialValues({
    InterfacePreferences.storageKey: scale,
  });
  tester.view.physicalSize = const Size(1024, 768);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final app = EditorController(initialProject: testDemoProject());
  addTearDown(app.dispose);
  await tester.pumpWidget(OpenEcadApp(controller: app));
  await tester.pumpAndSettle();
  return app;
}

void expectUnclipped(WidgetTester tester, Finder text) {
  final paragraphs = find.descendant(of: text, matching: find.byType(RichText));
  for (final element in paragraphs.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.size.height + .5,
      greaterThanOrEqualTo(
        paragraph.getMaxIntrinsicHeight(paragraph.size.width),
      ),
      reason: paragraph.text.toPlainText(),
    );
  }
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Nastavení programu'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Písmo rozhraní…'));
  await tester.pumpAndSettle();
}

void setSlider(WidgetTester tester, double scale) {
  tester
      .widget<Slider>(find.byKey(const ValueKey('interface-text-scale')))
      .onChanged!(scale);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('text magnification preserves the platform scaling strategy', () {
    const scaler = InterfaceTextScaler(
      system: TextScaler.linear(1.5),
      fontSize: 18,
      magnification: 1.25,
    );
    expect(scaler.scale(14), 33.75);
    expect(scaler.scale(12), closeTo(28.92857, .00001));
    expect(scaler.scale(0), 0);
  });

  test(
    'GTK DPI scaling fills platform gaps without applying the same scale twice',
    () {
      for (final (platform, gtk, expected) in [
        (1.0, 1.5, 24.0),
        (1.5, 1.5, 24.0),
        (2.0, 1.5, 32.0),
        (1.0, 2.0, 32.0),
        (1.0, .75, 12.0),
        (.8, 1.0, 12.8),
      ]) {
        final scaler = InterfaceTextScaler(
          system: TextScaler.linear(platform),
          fontSize: 16,
          gtkFontScale: gtk,
          magnification: 1.5,
        );
        expect(scaler.scale(14), closeTo(expected * 1.5, .00001));
      }
    },
  );

  test('preferences survive restart and preview does not persist', () async {
    SharedPreferences.setMockInitialValues({'other': 'preserved'});
    final preferences = InterfacePreferences();
    addTearDown(preferences.dispose);
    await preferences.load();
    await preferences.save(1.5);
    preferences.preview(2);
    expect(preferences.effectiveScale, 2);
    final restored = InterfacePreferences();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.scale, 1.5);
    preferences.preview(null);
    expect(preferences.effectiveScale, 1.5);
    expect(
      (await SharedPreferences.getInstance()).getString('other'),
      'preserved',
    );
    await expectLater(preferences.save(double.nan), throwsArgumentError);
  });

  test('a late load cannot overwrite a saved font size', () async {
    SharedPreferences.setMockInitialValues({
      InterfacePreferences.storageKey: 1.1,
    });
    final store = Completer<SharedPreferences>();
    final preferences = InterfacePreferences(
      loadPreferences: () => store.future,
    );
    addTearDown(preferences.dispose);
    final loading = preferences.load();
    final saving = preferences.save(1.75);
    store.complete(await SharedPreferences.getInstance());
    await Future.wait([loading, saving]);
    expect(preferences.scale, 1.75);
  });

  testWidgets(
    'font size previews, cancels, saves and resets across documents',
    (tester) async {
      final app = await mount(tester);
      final canvas = find.byType(SchematicCanvas);
      final originalProject = app.project;
      app.viewport.zoomIn();
      await tester.pumpAndSettle();
      final originalZoom = app.viewport.zoom;
      final preferences =
          InterfacePreferencesScope.maybeOf(tester.element(canvas))!;
      await openSettings(tester);
      setSlider(tester, 1.5);
      await tester.pumpAndSettle();
      expect(MediaQuery.textScalerOf(tester.element(canvas)).scale(14), 21);
      expectUnclipped(tester, find.text('Přívod čerpadla · svorka X1:12'));
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(preferences.effectiveScale, 1);
      await openSettings(tester);
      setSlider(tester, 1.5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(preferences.scale, 1.5);
      expect(app.project, same(originalProject));
      expect(app.viewport.zoom, originalZoom);
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      workspace.create();
      await tester.pumpAndSettle();
      expect(MediaQuery.textScalerOf(tester.element(canvas)).scale(14), 21);
      final restored = InterfacePreferences();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.scale, 1.5);
      await openSettings(tester);
      await tester.tap(find.text('Podle systému'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(preferences.scale, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large system text keeps panels usable and chrome compact', (
    tester,
  ) async {
    final app = await mount(tester);
    for (final size in [const Size(960, 640), const Size(1440, 900)]) {
      tester.view.physicalSize = size;
      for (final scale in [1.0, 1.5, 2.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        for (final appearance in EcadAppearance.values) {
          await app.setAppearance(appearance);
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(SchematicCanvas));
          expect(MediaQuery.textScalerOf(context).scale(14), 14 * scale);
          final bar = tester.getSize(
            find.byKey(const ValueKey('workspace-command-bar')),
          );
          expect(bar.height, lessThanOrEqualTo(48));
          expect(
            tester.getSize(find.byType(EcadIconButton).first),
            const Size(30, 30),
          );
          expectUnclipped(
            tester,
            find.descendant(
              of: find.byKey(const ValueKey('workspace-command-bar')),
              matching: find.byType(Text),
            ),
          );
          expectUnclipped(
            tester,
            find.descendant(
              of: find.byKey(const ValueKey('workspace-status-bar')),
              matching: find.byType(Text),
            ),
          );
          for (final tab in ['Listy', 'Značky', 'Přístroje', 'Artikly']) {
            final target = find.widgetWithText(Tab, tab);
            await tester.ensureVisible(target);
            await tester.tap(target);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$size, $scale, $appearance, $tab',
            );
          }
          await tester.tap(find.byTooltip('Zobrazit vlastnosti'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Zobrazit asistenta'));
          await tester.pumpAndSettle();
        }
      }
    }
  });

  testWidgets('panel and dialog headings stay close to the chosen body size', (
    tester,
  ) async {
    final app = await mount(tester);
    tester.view.physicalSize = const Size(1440, 900);
    void expectProportions() {
      final context = tester.element(find.byType(SchematicCanvas));
      final theme = Theme.of(context).textTheme;
      final scaler = MediaQuery.textScalerOf(context);
      final bodySize = scaler.scale(theme.bodyMedium!.fontSize!);
      for (final style in [
        theme.displayLarge,
        theme.displayMedium,
        theme.displaySmall,
        theme.headlineLarge,
        theme.headlineMedium,
        theme.headlineSmall,
        theme.titleLarge,
        theme.titleMedium,
        theme.titleSmall,
      ]) {
        expect(
          scaler.scale(style!.fontSize!),
          lessThanOrEqualTo(bodySize * 1.2),
        );
      }
      for (final element in find.byType(RichText).evaluate()) {
        if (element.findAncestorWidgetOfExactType<Icon>() != null) continue;
        final paragraph = element.renderObject! as RenderParagraph;
        final size = paragraph.text.style?.fontSize;
        if (size == null) continue;
        expect(
          paragraph.textScaler.scale(size),
          lessThanOrEqualTo(bodySize * 1.2),
          reason: paragraph.text.toPlainText(),
        );
      }
      expect(tester.takeException(), isNull);
    }

    for (final scale in [1.0, 24 / 14, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      app.select({});
      app.setPanel(SidePanel.assistant);
      await tester.pumpAndSettle();
      expect(find.text('Od záměru k výkresu.'), findsOneWidget);
      expect(find.text('Otevřené projekty'), findsOneWidget);
      expectProportions();
      app.setPanel(SidePanel.properties);
      await tester.pumpAndSettle();
      expectProportions();
      app.select({app.sheet.devices.first.id});
      await tester.pumpAndSettle();
      expectProportions();
      await openSettings(tester);
      expectProportions();
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'dropdown labels keep their line height and open items can wrap',
    (tester) async {
      await mount(tester, scale: 2);
      await tester.tap(find.byTooltip('Nastavení programu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kreslicí kurzor…'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey(DrawingCursorColor.automatic));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expectUnclipped(tester, find.text('Automatická podle pozadí'));
      await tester.tap(field);
      await tester.pumpAndSettle();
      expectUnclipped(tester, find.text('Automatická podle pozadí').last);
      await tester.tap(find.text('Černá').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'GTK font and maximum magnification work together in a small window',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('open_ecad/system_typography');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => {'fontFamily': 'Liberation Sans', 'fontSize': 24.0},
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      const windowChannel = MethodChannel('window_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async => switch (call.method) {
          'isMaximized' || 'isFullScreen' || 'isMinimized' => false,
          _ => null,
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      await DesktopWindow.initialize();
      await mount(tester, scale: 2);
      tester.view.physicalSize = const Size(960, 640);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(SchematicCanvas));
      expect(
        Theme.of(context).textTheme.bodyMedium!.fontFamily,
        'Liberation Sans',
      );
      expect(MediaQuery.textScalerOf(context).scale(14), 48);
      expect(tester.takeException(), isNull);
      await openSettings(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      for (final tab in ['Značky', 'Přístroje', 'Artikly', 'Listy']) {
        final target = find.widgetWithText(Tab, tab);
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
      await tester.tap(find.byTooltip('Zobrazit vlastnosti'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
