// 随机背景的换图动作：从池子的文件夹里挑一张，装进「这一局」。
// 驱动（什么时候换）在 lib/state/tavern_background_rotation.dart；这里只管怎么换。
//
// 挑图沿用壁纸池那套（lib/wallpaper/wallpaper_pool.dart：后台 isolate 列目录、30 秒缓存、
// 避开上一张、最多试 5 张），所以几千张图还能照样切局不卡。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wallpaper/custom_wallpaper.dart';
import '../wallpaper/wallpaper_import.dart';
import '../wallpaper/wallpaper_pool.dart';
import 'tavern_background_pool.dart';
import 'tavern_backgrounds.dart';

/// 酒馆自己的导入器：拷进 `<support>/tavern/backgrounds`，和单张换图同一处。
final tavernBackgroundRotatorProvider = Provider<TavernBackgroundRotator>(TavernBackgroundRotator.new);

class TavernBackgroundRotator {
  TavernBackgroundRotator(this._ref);

  final Ref _ref;

  /// 一轮换图只跑一个：定时和切局撞在一起时不排队建两张图。
  bool _busy = false;

  /// 同一动作 400 毫秒内的重复触发合并成一次（不是冷却：你来回切局该换还是立刻换）。
  static const debounce = Duration(milliseconds: 400);
  DateTime? _last;

  /// 换一张。false: 没换（没设文件夹、文件夹里没有能用的图、正在换）。
  Future<bool> rotate(String chatId, {bool force = false}) async {
    final pool = _ref.read(tavernBackgroundPoolProvider).value ?? const TavernBackgroundPool();
    if (!pool.hasDirectory || _busy) return false;
    final now = DateTime.now();
    final since = _last == null ? null : now.difference(_last!);
    if (!force && since != null && since < debounce) return false;
    _busy = true;
    try {
      // 让切局那一下先落定，再解码新图：解码一张 1000 万像素的图那一帧必掉。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      var remaining = pool.direct
          ? await WallpaperPool.allImages(pool.directory)
          : await WallpaperPool.images(pool.directory);
      final current = _ref.read(tavernChatBackgroundProvider(chatId));
      final previous = current?.path;
      for (var attempt = 0; attempt < WallpaperPool.maxAttempts && remaining.isNotEmpty; attempt++) {
        final next = WallpaperPool.pick(remaining, previous);
        if (next == null) break;
        remaining = remaining.where((path) => path != next).toList();
        final picture = pool.direct ? await _direct(next) : await _imported(next, current);
        if (picture == null) continue; // 认不出来 / 读不出来：换下一张再试
        // 观感沿用池里那套：新图不是你调回默认，而是和上一张一样。
        await _ref.read(tavernChatBackgroundProvider(chatId).notifier).use(
          picture.copyWith(
            raw: pool.raw,
            blur: pool.blur ?? picture.blur,
            lighten: pool.lighten ?? picture.lighten,
            dim: pool.dim ?? picture.dim,
          ),
        );
        await _ref.read(tavernBackgroundPoolProvider.notifier).take(next);
        // 上一张如果是酒馆自己的副本（检查那条路拷进来的），换掉就删，别攒着占空间；
        // 用户自己的原图（不检查那条路）不动。
        if (current != null && current.path != picture.path) await _dropIfOwned(current.path);
        _last = now;
        return true;
      }
      return false;
    } finally {
      _busy = false;
    }
  }

  /// 只删酒馆自己目录里的副本。
  Future<void> _dropIfOwned(String path) async {
    try {
      final own = await tavernBackgroundDirectory();
      if (path.startsWith(own.path)) await WallpaperImport.removeFile(path);
    } catch (_) {}
  }

  /// 检查那条路：拷进酒馆自己的目录，认类型、留观感。
  Future<CustomWallpaper?> _imported(String path, CustomWallpaper? previous) async {
    try {
      final (picture, _) = await _ref
          .read(tavernBackgroundImportProvider)
          .keep(File(path).openRead(), previous: previous);
      return picture;
    } catch (_) {
      return null;
    }
  }

  /// 不检查那条路：原图直接用，只读文件头拿宽高。
  Future<CustomWallpaper?> _direct(String path) async {
    final size = await WallpaperImport.dimensions(path);
    if (size == null) return null;
    return CustomWallpaper(path: path, width: size.$1, height: size.$2);
  }
}
