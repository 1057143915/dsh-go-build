// 酒馆随机背景的「什么时候换」：进入这一局、切到另一局、定时。
//
// 只在前台走表：切到后台就停，回前台重新计时 —— 换背景只在看得见的时候有意义，也省电。
// 没有后台任务，不申请权限。
//
// 表跟着酒馆对话页走（lib/ui/tavern/tavern_chat_page.dart 打开时 watch、关掉时 leave）：
// 酒馆首页或工作界面在的时候不该为了这件事在后台换图。
//
// 池子的设置是异步读回来的，所以「进入这一局」那一档要等设置到齐再判一次：watch()
// 先把这一局记下来，sync() 拿到池子后补上那一次。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../tavern/tavern_background_pool.dart';
import '../tavern/tavern_background_rotation.dart';
import '../wallpaper/wallpaper_pool.dart';

class TavernBackgroundRotationOwner {
  TavernBackgroundRotationOwner(this._ref);

  final Ref _ref;

  Timer? _timer;
  int? _forSeconds;
  String? _chatId;
  bool _foreground = true;
  bool _loaded = false;

  /// 这一局是否已经按「进入时换」换过：换局重置。
  bool _entered = false;

  TavernBackgroundPool _pool = const TavernBackgroundPool();

  /// 池设置到了（启动读到、设置页改了）：补上「进入这一局」那一次，再按需起表。
  void sync(TavernBackgroundPool? pool) {
    _pool = pool ?? const TavernBackgroundPool();
    _loaded = pool != null;
    final chatId = _chatId;
    if (_loaded && chatId != null && !_entered) {
      _entered = true;
      if (_pool.has(WallpaperPoolTrigger.launch)) unawaited(_rotate(chatId));
    }
    _apply();
  }

  /// 现在打开的是哪一局：换局按「切换这一局」那一档换一张。
  void watch(String chatId) {
    if (_chatId == chatId) return;
    final first = _chatId == null;
    _chatId = chatId;
    _entered = false;
    if (first) {
      // 第一次进来交给 sync()：池子还没读回来时判断会漏掉「进入时换」。
      if (_loaded) sync(_pool);
      return;
    }
    if (_pool.has(WallpaperPoolTrigger.chat)) unawaited(_rotate(chatId));
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _apply();
  }

  void _apply() {
    final chatId = _chatId;
    final wanted = _foreground && chatId != null && _pool.has(WallpaperPoolTrigger.interval);
    if (!wanted) {
      _timer?.cancel();
      _timer = null;
      _forSeconds = null;
      return;
    }
    if (_timer != null && _forSeconds == _pool.seconds) return;
    _timer?.cancel();
    _forSeconds = _pool.seconds;
    _timer = Timer.periodic(Duration(seconds: _pool.seconds), (_) => unawaited(_rotate(chatId)));
  }

  Future<void> _rotate(String chatId) => _ref.read(tavernBackgroundRotatorProvider).rotate(chatId);

  /// 这一页走了：表停，等下一次打开。
  void leave() {
    _chatId = null;
    _entered = false;
    _apply();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

final tavernBackgroundRotationProvider = Provider<TavernBackgroundRotationOwner>((ref) {
  final owner = TavernBackgroundRotationOwner(ref);
  ref.onDispose(owner.dispose);
  return owner;
});
