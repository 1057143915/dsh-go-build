// 模式 as tabs: 工作 / 伙伴 / 酒馆 in one row at the foot of the screen, the way
// a chat app switches its pages. Each tab is built when first opened and then
// kept as it was left — the drawer's 模式 sheet and every 切换模式 key land here
// instead of pushing a page over the home (lib/ui/modes/mode_switch.dart).
//
// 工作 stays the home: it is the tab a launch opens by default, and back from
// either other tab returns to it rather than closing the app.
//
// The bar stands over the page on its own colour, and every page is told the
// bottom inset is one bar taller: the chat's composer, the tavern's last row and
// the drawer's foot all stop clear of it without knowing it is there. The page
// keeps the whole screen behind the bar, so its wallpaper is not squashed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../theme/theme.dart';
import 'mode_switch.dart' show appModeIcon, appModePage, appModeShortLabel;

/// The tab on screen. Not stored: a launch opens 模式 › 启动 ([appModeProvider])
/// through [ModeLaunch].
class ModeTabController extends Notifier<AppMode> {
  @override
  AppMode build() => AppMode.work;

  void show(AppMode mode) => state = mode;

  /// 工作, unless it is already the one on screen.
  void home() => state = AppMode.work;
}

final modeTabProvider = NotifierProvider<ModeTabController, AppMode>(ModeTabController.new);

/// 返回 on a page a 模式 owns: back to 工作 instead of popping (a tab is not a
/// page over the home). False everywhere else, so the caller pops as before.
bool leaveModeTab(BuildContext context) {
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    if (container.read(modeTabProvider) == AppMode.work) return false;
    container.read(modeTabProvider.notifier).home();
    return true;
  } catch (_) {
    // No scope above this page (a bare widget test): behave as before.
    return false;
  }
}

/// The three 模式 as pages kept side by side above a bar at the foot of the
/// screen. [work] is the home (the native shell, or its stand-in in tests).
class ModeTabs extends ConsumerStatefulWidget {
  const ModeTabs({super.key, required this.work});

  final Widget work;

  /// The bar's height, before the system's own bottom inset.
  static const barHeight = 56.0;

  @override
  ConsumerState<ModeTabs> createState() => _ModeTabsState();
}

class _ModeTabsState extends ConsumerState<ModeTabs> {
  /// Opened at least once. A tab never opened costs nothing: no page, no
  /// WebView, no timers.
  final _built = <AppMode>{AppMode.work};

  Widget _page(AppMode mode) => mode == AppMode.work ? widget.work : appModePage(mode);

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(modeTabProvider);
    _built.add(tab);
    // Opening a conversation from another tab (伙伴's 打开完整对话, a
    // notification, a plugin's tap) means the chat: land on 工作, where it is.
    ref.listen(currentSessionProvider, (previous, next) {
      if (next == null || previous == next) return;
      if (ref.read(modeTabProvider) != AppMode.work) ref.read(modeTabProvider.notifier).home();
    });
    final media = MediaQuery.of(context);
    // One bar's height more of bottom inset for the page: its SafeAreas and the
    // tab bar both count the system's own inset, so nothing pays for it twice.
    // With the keyboard up the bar is behind it, so the page reserves nothing
    // and the composer sits on the keyboard the way it did without tabs.
    final keyboard = media.viewInsets.bottom;
    final framed = media.copyWith(
      padding: media.padding.copyWith(
        bottom: media.padding.bottom + (keyboard > 0 ? 0 : ModeTabs.barHeight),
      ),
    );
    void pick(AppMode mode) {
      if (mode == tab) return;
      // The chat's box gives the keyboard back: the tab under it is not the one
      // being looked at.
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(modeTabProvider.notifier).show(mode);
    }

    return PopScope(
      // Back on a tab that is not 工作 goes home first; only 工作 closes the app.
      canPop: tab == AppMode.work,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && tab != AppMode.work) ref.read(modeTabProvider.notifier).home();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaQuery(
            data: framed,
            // Kept, not rebuilt: a conversation, a scroll position and her room
            // survive a look at another tab.
            child: IndexedStack(
              index: tab.index,
              // Every page is a whole screen: loose constraints would let one
              // size itself and the others follow the largest.
              sizing: StackFit.expand,
              children: [
                for (final mode in AppMode.values)
                  _built.contains(mode)
                      // Off screen: her stage pauses itself (TickerMode), and
                      // nothing off the tab animates.
                      ? TickerMode(enabled: mode == tab, child: _page(mode))
                      : const SizedBox.shrink(),
              ],
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: ModeTabBar(current: tab, onPick: pick)),
        ],
      ),
    );
  }
}

/// The foot of the screen: one key per 模式, the one on screen lit in the accent.
class ModeTabBar extends StatelessWidget {
  const ModeTabBar({super.key, required this.current, required this.onPick});

  final AppMode current;
  final ValueChanged<AppMode> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: ModeTabs.barHeight,
          child: Row(
            children: [
              for (final mode in AppMode.values)
                Expanded(
                  child: _ModeTabKey(
                    mode: mode,
                    label: appModeShortLabel(l10n, mode),
                    selected: mode == current,
                    onTap: () => onPick(mode),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeTabKey extends StatelessWidget {
  const _ModeTabKey({required this.mode, required this.label, required this.selected, required this.onTap});

  final AppMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final tint = selected ? scheme.primary : dsh.textTertiary;
    return Semantics(
      key: ValueKey('mode-tab-${mode.name}'),
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(appModeIcon(mode), size: 23, color: tint),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: tint,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
