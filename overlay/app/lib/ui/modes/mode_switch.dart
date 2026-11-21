// Switching 模式 (lib/state/app_mode_state.dart): the 模式 sheet, its key in
// the drawer, and opening the startup mode on launch.
//
// 工作 is the home; 伙伴 and 酒馆 are two more tabs beside it at the foot of the
// screen (lib/ui/modes/mode_tabs.dart), kept built once opened. The sheet and
// the 切换模式 key therefore only choose a tab and close whatever page was over
// the home — no page is pushed for a mode any more.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../companion/companion_page.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../tavern/tavern_home_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'mode_tabs.dart';

/// The page of a mode other than 工作.
Widget appModePage(AppMode mode) => switch (mode) {
  AppMode.companion => const CompanionPage(),
  AppMode.tavern => const TavernHomePage(),
  AppMode.work => throw ArgumentError.value(mode, 'mode', '工作 is the home, not a page'),
};

/// Shows [mode]: any page or sheet over the home closes, then the tab at the
/// foot of the screen switches to it (lib/ui/modes/mode_tabs.dart). The three
/// modes stay built side by side, so this costs no page build and no WebView.
void openAppMode(BuildContext context, AppMode mode) {
  final container = ProviderScope.containerOf(context, listen: false);
  Navigator.of(context).popUntil((route) => route.isFirst);
  container.read(modeTabProvider.notifier).show(mode);
}

String appModeLabel(L10n l10n, AppMode mode) => switch (mode) {
  AppMode.work => l10n.modeWork,
  AppMode.companion => l10n.companionTitle,
  AppMode.tavern => l10n.tavernTitle,
};

IconData appModeIcon(AppMode mode) => switch (mode) {
  AppMode.work => AppIcons.chat,
  AppMode.companion => AppIcons.pet,
  AppMode.tavern => AppIcons.tavern,
};

/// 模式: the three modes, [current] marked, and which one a launch opens in.
Future<void> showModeSheet(BuildContext context, {required AppMode current}) => showAppSheet<void>(
  context,
  isScrollControlled: true,
  builder: (_) => ModeSheet(current: current, onOpen: (mode) => openAppMode(context, mode)),
);

class ModeSheet extends ConsumerWidget {
  const ModeSheet({super.key, required this.current, required this.onOpen});

  final AppMode current;
  final ValueChanged<AppMode> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final startup = ref.watch(appModeProvider.select((s) => s.startup));
    String subtitle(AppMode mode) => switch (mode) {
      AppMode.work => l10n.modeWorkSubtitle,
      AppMode.companion => l10n.companionEntrySubtitle,
      AppMode.tavern => l10n.modeTavernSubtitle,
    };
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.modeSheetTitle),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
            children: [
              for (final mode in AppMode.values)
                Semantics(
                  key: ValueKey('mode-row-${mode.name}'),
                  selected: mode == current,
                  inMutuallyExclusiveGroup: true,
                  child: SettingsTile(
                    icon: appModeIcon(mode),
                    tinted: false,
                    title: appModeLabel(l10n, mode),
                    subtitle: subtitle(mode),
                    onTap: () => mode == current ? Navigator.of(context).pop() : onOpen(mode),
                    trailing: mode == current
                        ? Icon(AppIcons.selected, size: 20, color: scheme.primary)
                        : const SizedBox(width: 20),
                  ),
                ),
            ],
          ),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
            children: [
              SettingsSegmentTile<AppMode>(
                key: const ValueKey('mode-startup'),
                title: l10n.modeStartup,
                tinted: false,
                segments: [for (final mode in AppMode.values) PillSegment(mode, appModeShortLabel(l10n, mode))],
                selected: startup,
                onChanged: (mode) => unawaited(ref.read(appModeProvider.notifier).setStartup(mode)),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// One word per mode, for the startup switch.
String appModeShortLabel(L10n l10n, AppMode mode) => switch (mode) {
  AppMode.work => l10n.modeWork,
  AppMode.companion => l10n.modeCompanionShort,
  AppMode.tavern => l10n.tavernTitle,
};

/// The drawer's key to 模式, beside 网页模式. The sheet it opens marks whichever
/// tab is on screen, and still holds 启动时进入.
class ModeKey extends ConsumerWidget {
  const ModeKey({super.key, this.current, this.size = 36, this.tier = GlassTier.pill});

  /// The tab to mark; null reads the one on screen.
  final AppMode? current;
  final double size;
  final GlassTier tier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppMode shown = current ?? ref.watch(modeTabProvider);
    return GlassIconButton(
      key: const ValueKey('mode-key'),
      icon: AppIcons.modes,
      tooltip: context.l10n.modeKeyTooltip,
      size: size,
      tier: tier,
      onPressed: () => unawaited(showModeSheet(context, current: shown)),
    );
  }
}

/// Opens the startup mode once per launch, before the home shows: until then
/// it draws the backdrop, so a launch into 酒馆 doesn't flash 工作 first.
class ModeLaunch extends ConsumerStatefulWidget {
  const ModeLaunch({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ModeLaunch> createState() => _ModeLaunchState();
}

/// Set once the startup mode has been opened this launch.
final modeLaunchedProvider = NotifierProvider<_Launched, bool>(_Launched.new);

class _Launched extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() => state = true;
}

class _ModeLaunchState extends ConsumerState<ModeLaunch> {
  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appModeProvider);
    final launched = ref.watch(modeLaunchedProvider);
    if (launched) return widget.child;
    if (!mode.loaded) return const AppBackdrop(child: SizedBox.expand());
    if (mode.startup == AppMode.work) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(modeLaunchedProvider.notifier).mark());
      return widget.child;
    }
    // 模式 › 启动: the tab is chosen before the first frame of the home, so a
    // launch into 酒馆 shows no frame of 工作 first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(modeLaunchedProvider)) return;
      ref.read(modeTabProvider.notifier).show(mode.startup);
      ref.read(modeLaunchedProvider.notifier).mark();
    });
    return const AppBackdrop(child: SizedBox.expand());
  }
}
