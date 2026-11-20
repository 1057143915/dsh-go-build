// 壁纸自动更换的驱动：定时表、前台判定、切换聊天框。换图本身在
// CustomWallpaperController.rotate()（lib/state/wallpaper_state.dart），这里只管「什么时候」。
//
// 表只在前台走：切到后台就停，回前台重新计时 —— 换背景只在看得见的时候有意义，也省电。
// 没有后台任务，不申请任何权限。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wallpaper/wallpaper_pool.dart';
import 'wallpaper_state.dart';

/// 由 [DshApp] 持有：设置变了调 [sync]，前后台切换调 [setForeground]，当前会话变了调
/// [onSessionChanged]。
class WallpaperRotationOwner {
  WallpaperRotationOwner(this._ref);

  final Ref _ref;

  Timer? _timer;

  /// 表对的是哪个间隔（秒）；间隔变了才重建。
  int? _forSeconds;

  WallpaperPool _pool = const WallpaperPool();
  bool _foreground = true;

  /// 池的设置变了（启动时读到、设置页改了）：按需起表或停表。
  void sync(WallpaperPool? pool) {
    _pool = pool ?? const WallpaperPool();
    _apply();
  }

  /// 前后台切换。
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _apply();
  }

  /// 切换了聊天框。开着这一档才换。
  void onSessionChanged() {
    if (!_pool.has(WallpaperPoolTrigger.chat)) return;
    unawaited(_rotate());
  }

  void _apply() {
    final wanted = _foreground && _pool.has(WallpaperPoolTrigger.interval);
    if (!wanted) {
      _timer?.cancel();
      _timer = null;
      _forSeconds = null;
      return;
    }
    if (_timer != null && _forSeconds == _pool.seconds) return;
    _timer?.cancel();
    _forSeconds = _pool.seconds;
    _timer = Timer.periodic(Duration(seconds: _pool.seconds), (_) => unawaited(_rotate()));
  }

  /// 换一张；池没设好、文件夹空、图都读不出来时什么也不做（rotate 自己判断）。
  Future<void> _rotate() => _ref.read(customWallpaperProvider.notifier).rotate();

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

final wallpaperRotationProvider = Provider<WallpaperRotationOwner>((ref) {
  final owner = WallpaperRotationOwner(ref);
  ref.onDispose(owner.dispose);
  return owner;
});
