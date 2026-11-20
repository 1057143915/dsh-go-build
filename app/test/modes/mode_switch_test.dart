import 'package:dsh_app/state/app_mode_state.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/modes/mode_switch.dart';
import 'package:dsh_app/ui/modes/mode_tabs.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Widget _app(Widget home) => ProviderScope(
  overrides: [tavernProvider.overrideWith((ref) => PreviewTavern(tick: const Duration(milliseconds: 1)))],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  ),
);

void main() {
  testWidgets('a launch opens straight into the startup mode’s tab', (tester) async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'tavern'});
    await tester.pumpWidget(_app(const ModeLaunch(child: ModeTabs(work: Text('工作首页')))));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(ModeTabs)));
    expect(container.read(modeTabProvider), AppMode.tavern);
    expect(find.byType(TavernHomePage), findsOneWidget);

    // 工作's own key: back to the home tab, not a pop.
    await tester.tap(find.byKey(const ValueKey('mode-tab-work')));
    await tester.pumpAndSettle();
    expect(container.read(modeTabProvider), AppMode.work);
  });

  testWidgets('工作 as the startup mode shows the home tab and builds no other', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const ModeLaunch(child: ModeTabs(work: Text('工作首页')))));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(ModeTabs)));
    expect(container.read(modeTabProvider), AppMode.work);
    expect(find.byType(TavernHomePage), findsNothing);
    for (final mode in AppMode.values) {
      expect(find.byKey(ValueKey('mode-tab-${mode.name}')), findsOneWidget);
    }
  });

  testWidgets('the 模式 sheet opens a mode and keeps the startup choice', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppMode? opened;
    await tester.pumpWidget(
      _app(Scaffold(body: ModeSheet(current: AppMode.work, onOpen: (mode) => opened = mode))),
    );
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsWidgets);
    expect(find.text('伙伴小屋'), findsOneWidget);
    expect(find.text('酒馆'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('mode-row-tavern')));
    expect(opened, AppMode.tavern);

    // 启动时进入 › 酒馆.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('mode-startup')), matching: find.text('酒馆')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppModeController.key), 'tavern');
  });
}
