// 设置 › 主题 › 壁纸: the user's own wallpaper (lib/wallpaper/custom_wallpaper.dart), whether it's
// the one in use, and the picture baked for the screen it's on.

import 'dart:io';

import 'dart:ui' as ui;
import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../performance/performance_state.dart';
import '../wallpaper/custom_wallpaper.dart';
import '../wallpaper/wallpaper_import.dart';
import '../wallpaper/wallpaper_pool.dart';
import '../wallpaper/wallpaper_render.dart';

export '../wallpaper/wallpaper_import.dart' show LaunchImportProblem;

final wallpaperImportProvider = Provider<WallpaperImport>((ref) => WallpaperImport());

/// Bakes for the backdrop and the settings' small phones; keeps the last decoded picture.
final wallpaperRendererProvider = Provider<WallpaperRenderer>((ref) {
  final renderer = WallpaperRenderer();
  ref.onDispose(renderer.release);
  return renderer;
});

/// The stored wallpaper (null: none chosen yet, or its file is gone).
final customWallpaperProvider = AsyncNotifierProvider<CustomWallpaperController, CustomWallpaper?>(
  CustomWallpaperController.new,
);

class CustomWallpaperController extends AsyncNotifier<CustomWallpaper?> {
  @override
  Future<CustomWallpaper?> build() => CustomWallpaper.load();

  /// The system picker; the pick becomes the wallpaper in use. Null when it did, else why not
  /// ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> choose() async {
    final previous = await _current;
    final (wallpaper, problem) = await ref.read(wallpaperImportProvider).pick(previous: previous);
    if (wallpaper == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(wallpaper);
    // Only now: until the new one is saved, the old file is the one the next launch reads.
    if (previous != null && previous.path != wallpaper.path) await WallpaperImport.removeFile(previous.path);
    return null;
  }

  /// The stored wallpaper, once it's read.
  Future<CustomWallpaper?> get _current async {
    if (state.hasValue) return state.value;
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  /// The custom one in use (true) or the default backdrop (false); the picture stays either way.
  Future<void> use(bool custom) async {
    final current = await _current;
    if (current == null || current.on == custom) return;
    await _store(current.copyWith(on: custom));
  }

  /// Where the screen sits in the picture.
  Future<void> frame({required double zoom, required double alignX, required double alignY}) async {
    final current = await _current;
    if (current == null) return;
    await _store(
      current.copyWith(
        zoom: zoom.clamp(1.0, CustomWallpaper.maxZoom),
        alignX: alignX.clamp(-1.0, 1.0),
        alignY: alignY.clamp(-1.0, 1.0),
      ),
    );
  }

  Future<void> setBlur(double blur) async {
    final value = blur.clamp(0.0, 1.0);
    // 记进池：下一张换上来还是这个模糊，不会跳回默认。
    await ref.read(wallpaperPoolProvider.notifier).setBlur(value);
    final current = await _current;
    if (current == null || current.blur == value) return;
    await _store(current.copyWith(blur: value));
  }

  /// 提亮 (light mode) or 压暗 (dark mode).
  Future<void> setTone(Brightness brightness, double tone) async {
    final value = tone.clamp(0.0, 1.0);
    // 记进池：换下一张时这一档仍是这个值。
    await ref.read(wallpaperPoolProvider.notifier).setTone(brightness, value);
    final current = await _current;
    if (current == null || current.toneFor(brightness) == value) return;
    await _store(current.withTone(brightness, value));
  }

  bool _rotatedAtLaunch = false;
  bool _rotating = false;

  /// 刚换过的时间：400 毫秒内的重复触发合并成一次。只挡「同一动作重复触发」（比如一次切屏
  /// 里会话 provider 连发两次），不是冷却 —— 你来回切聊天该换还是立刻换。
  static const rotateDebounce = Duration(milliseconds: 400);
  DateTime? _lastRotate;

  /// 每次启动: 池开着这一档就换一张。App 起来后调一次，重复调用只算一次。
  Future<void> rotateOnLaunch() async {
    if (_rotatedAtLaunch) return;
    _rotatedAtLaunch = true;
    if ((await ref.read(wallpaperPoolProvider.future)).has(WallpaperPoolTrigger.launch)) await rotate();
  }

  /// 从壁纸池随机换一张。false: 没换（没选文件夹、文件夹里没有能用的图、正在换另一张）。
  /// 没有冷却：每次切聊天框都要真换 —— 旧聊天也换，不是只在新聊天里换。
  Future<bool> rotate({bool force = false}) async {
    final pool = await ref.read(wallpaperPoolProvider.future);
    if (pool.directory.isEmpty || _rotating) return false;
    final now = DateTime.now();
    final since = _lastRotate == null ? null : now.difference(_lastRotate!);
    if (!force && since != null && since < rotateDebounce) return false;
    _rotating = true;
    try {
      // 让切屏动画先走完再解码新图：以前是切换瞬间就同步烘焙一张 1000 万像素的图，
      // 那一帧必掉。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!ref.mounted) return false;
      var remaining = pool.direct
          ? await WallpaperPool.allImages(pool.directory)
          : await WallpaperPool.images(pool.directory);
      final previous = await _current;
      for (var attempt = 0; attempt < WallpaperPool.maxAttempts && remaining.isNotEmpty; attempt++) {
        final next = WallpaperPool.pick(remaining, previous?.path);
        if (next == null) break;
        remaining = remaining.where((path) => path != next).toList();
        final (wallpaper, _) = pool.direct ? await _adoptDirect(next) : await _adopt(next, previous);
        if (wallpaper == null) continue; // 认不出来 / 读不出来: 换下一张再试
        // 观感沿用池里那套（模糊 / 提亮 / 压暗）：新图不是回到默认，而是和你上一张一样。
        final blur = pool.blur ?? wallpaper.blur;
        final lighten = pool.lighten ?? wallpaper.lighten;
        final dim = pool.dim ?? wallpaper.dim;
        await _store(
          wallpaper.copyWith(raw: pool.raw, blur: blur, lighten: lighten, dim: dim),
        );
        await ref.read(wallpaperPoolProvider.notifier).take(next);
        _lastRotate = now;
        return true;
      }
      return false;
    } finally {
      _rotating = false;
    }
  }

  /// 池里的一张图走原有的导入（拷贝、认类型、取边缘色、保留观感）。
  Future<(CustomWallpaper?, LaunchImportProblem?)> _adopt(String path, CustomWallpaper? previous) async {
    try {
      return await ref.read(wallpaperImportProvider).keep(File(path).openRead(), previous: previous);
    } catch (_) {
      return (null, LaunchImportProblem.unreadable);
    }
  }

  /// 不检查那条路：原图直接当壁纸，不拷贝、不按大小和格式拦。
  Future<(CustomWallpaper?, LaunchImportProblem?)> _adoptDirect(String path) async {
    final size = await WallpaperImport.dimensions(path);
    if (size == null) return (null, LaunchImportProblem.unreadable);
    return (CustomWallpaper(path: path, width: size.$1, height: size.$2), null);
  }

  Future<void> _store(CustomWallpaper wallpaper) async {
    state = AsyncData(wallpaper);
    await CustomWallpaper.save(wallpaper);
  }
}

/// 壁纸池的设置（lib/wallpaper/wallpaper_pool.dart）: 文件夹、自动更换的时机与间隔。
final wallpaperPoolProvider = AsyncNotifierProvider<WallpaperPoolController, WallpaperPool>(
  WallpaperPoolController.new,
);

class WallpaperPoolController extends AsyncNotifier<WallpaperPool> {
  @override
  Future<WallpaperPool> build() => WallpaperPool.load();

  Future<void> setDirectory(String directory) => _update((pool) => pool.copyWith(directory: directory, last: ''));

  Future<void> toggle(WallpaperPoolTrigger trigger, bool on) => _update((pool) => pool.toggled(trigger, on));

  Future<void> setSeconds(int value) => _update((pool) => pool.withSeconds(value));

  Future<void> setBlur(double value) => _update((pool) => pool.copyWith(blur: value.clamp(0.0, 1.0)));

  Future<void> setTone(Brightness brightness, double value) => _update(
    (pool) => brightness == Brightness.dark
        ? pool.copyWith(dim: value.clamp(0.0, 1.0))
        : pool.copyWith(lighten: value.clamp(0.0, 1.0)),
  );

  Future<void> setRaw(bool raw) => _update((pool) => pool.copyWith(raw: raw));

  Future<void> setDirect(bool direct) => _update((pool) => pool.copyWith(direct: direct));

  Future<void> take(String path) => _update((pool) => pool.copyWith(last: path));

  Future<void> _update(WallpaperPool Function(WallpaperPool) change) async {
    final next = change(await future);
    state = AsyncData(next);
    await WallpaperPool.save(next);
  }
}

/// The wallpaper baked for [WallpaperFrame]; null: the default backdrop (none chosen, switched
/// off, or the picture can't be read — the page never breaks over it).
final wallpaperImageProvider = FutureProvider.autoDispose.family<ui.Image?, WallpaperFrame>((ref, frame) async {
  final CustomWallpaper? wallpaper;
  try {
    wallpaper = await ref.watch(customWallpaperProvider.future);
  } catch (_) {
    return null;
  }
  if (wallpaper == null || !wallpaper.on) return null;
  final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
  final image = await ref.read(wallpaperRendererProvider).bake(wallpaper, frame.copyWith(lightweight: lightweight));
  if (!ref.mounted) {
    image?.dispose();
    return null;
  }
  if (image != null) ref.onDispose(image.dispose);
  return image;
});

/// Bakes a page's own picture ([sceneImageProvider]); apart from [wallpaperRendererProvider], so
/// the app's wallpaper stays decoded meanwhile.
final _sceneRendererProvider = Provider.autoDispose<WallpaperRenderer>((ref) {
  final renderer = WallpaperRenderer();
  ref.onDispose(renderer.release);
  return renderer;
});

/// A page's own picture (a tavern chat's background, `WallpaperBackdrop.scene`) baked for its
/// frame the way the wallpaper is; null when it can't be read.
final sceneImageProvider = FutureProvider.autoDispose.family<ui.Image?, (CustomWallpaper, WallpaperFrame)>((
  ref,
  key,
) async {
  final (picture, frame) = key;
  final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
  final image = await ref.watch(_sceneRendererProvider).bake(picture, frame.copyWith(lightweight: lightweight));
  if (!ref.mounted) {
    image?.dispose();
    return null;
  }
  if (image != null) ref.onDispose(image.dispose);
  return image;
});
