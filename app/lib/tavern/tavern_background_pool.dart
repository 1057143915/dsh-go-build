// 酒馆的随机背景：一个文件夹里的多张图，按你的时机随机挑一张给「这一局」。
// 和 App 自己的壁纸池（lib/wallpaper/wallpaper_pool.dart）分开存，一条 JSON 在
// `tavern.background_pool`：酒馆换背景不该动首页那张，反过来也一样。
//
// 三个时机沿用壁纸池那三个名字（启动 / 切换这一局 / 定时），间隔也是 3 秒到 10 分钟。
// 观感（模糊 / 提亮 / 压暗）和「全图还是裁剪」也一起存在池里：换下一张时沿用同一套，
// 不会每换一张就跳回默认。
//
// 挑中的图：
//  - 检查（默认）：走导入那条路，拷进 `<support>/tavern/backgrounds`，15 MB 以内、PNG/JPEG/WebP；
//  - 不检查（direct）：原图路径直接用，不拷贝、不按大小和格式拦，只读文件头拿宽高。

import 'dart:convert';
import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../wallpaper/wallpaper_pool.dart';

/// 酒馆的背景池：文件夹、时机、间隔、上一张、取图与画法、观感。
class TavernBackgroundPool {
  const TavernBackgroundPool({
    this.directory = '',
    this.triggers = const <WallpaperPoolTrigger>{},
    this.seconds = WallpaperPool.defaultSeconds,
    this.last = '',
    this.raw = true,
    this.direct = false,
    this.blur,
    this.lighten,
    this.dim,
  });

  static const prefsKey = 'tavern.background_pool';

  final String directory;
  final Set<WallpaperPoolTrigger> triggers;

  /// 定时换的间隔（秒）。
  final int seconds;

  /// 上一张的原图路径：随机时避开它，连着两次同一张很出戏。
  final String last;

  /// 全图：整图等比放进屏幕、居中、不裁切。关掉就是裁剪铺满（cover）。
  final bool raw;

  /// 不检查：原图直接当背景，不拷贝、不按大小和格式拦。
  final bool direct;

  /// 观感。null = 跟着图画自己的（等于没调过）。
  final double? blur;
  final double? lighten;
  final double? dim;

  bool get hasDirectory => directory.isNotEmpty;

  bool has(WallpaperPoolTrigger trigger) => triggers.contains(trigger);

  TavernBackgroundPool copyWith({
    String? directory,
    Set<WallpaperPoolTrigger>? triggers,
    int? seconds,
    String? last,
    bool? raw,
    bool? direct,
    double? blur,
    double? lighten,
    double? dim,
  }) =>
      TavernBackgroundPool(
        directory: directory ?? this.directory,
        triggers: triggers ?? this.triggers,
        seconds: seconds ?? this.seconds,
        last: last ?? this.last,
        raw: raw ?? this.raw,
        direct: direct ?? this.direct,
        blur: blur ?? this.blur,
        lighten: lighten ?? this.lighten,
        dim: dim ?? this.dim,
      );

  TavernBackgroundPool toggled(WallpaperPoolTrigger trigger, bool on) {
    final next = {...triggers};
    if (on) {
      next.add(trigger);
    } else {
      next.remove(trigger);
    }
    return copyWith(triggers: next);
  }

  TavernBackgroundPool withSeconds(int value) => copyWith(seconds: value.clamp(_minSeconds, _maxSeconds));

  /// 一次性把三个观感记下来（换图时钉住用）。
  TavernBackgroundPool withLook({double? blur, double? lighten, double? dim}) =>
      copyWith(blur: blur, lighten: lighten, dim: dim);

  /// [brightness] 那一档的色调；没调过返回 null。
  double? toneFor(Brightness brightness) => brightness == Brightness.dark ? dim : lighten;

  static int get _minSeconds => WallpaperPool.minSeconds;
  static int get _maxSeconds => WallpaperPool.maxSeconds;

  Map<String, Object?> toJson() => {
    'directory': directory,
    'triggers': [for (final trigger in triggers) trigger.name],
    'seconds': seconds,
    'last': last,
    'raw': raw,
    'direct': direct,
    'blur': ?blur,
    'lighten': ?lighten,
    'dim': ?dim,
  };

  static TavernBackgroundPool fromJson(Object? raw) {
    if (raw is! Map) return const TavernBackgroundPool();
    final directory = raw['directory'];
    final triggers = raw['triggers'];
    final seconds = raw['seconds'];
    final last = raw['last'];
    return TavernBackgroundPool(
      directory: directory is String ? directory : '',
      triggers: triggers is List
          ? {
              for (final name in triggers)
                ...WallpaperPoolTrigger.values.where((trigger) => trigger.name == name),
            }
          : const <WallpaperPoolTrigger>{},
      seconds: seconds is int && seconds >= _minSeconds && seconds <= _maxSeconds
          ? seconds
          : WallpaperPool.defaultSeconds,
      last: last is String ? last : '',
      raw: raw['raw'] != false,
      direct: raw['direct'] == true,
      blur: _unit(raw['blur']),
      lighten: _unit(raw['lighten']),
      dim: _unit(raw['dim']),
    );
  }

  static double? _unit(Object? value) {
    if (value is! num || !value.isFinite) return null;
    return value.toDouble().clamp(0.0, 1.0);
  }

  static Future<TavernBackgroundPool> load([SharedPreferences? prefs]) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final stored = store.getString(prefsKey);
      if (stored == null) return const TavernBackgroundPool();
      return fromJson(jsonDecode(stored));
    } catch (_) {
      return const TavernBackgroundPool();
    }
  }

  static Future<void> save(TavernBackgroundPool pool) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(pool.toJson()));
  }
}

/// 池子的读写：设置页和换图都从这里改。
final tavernBackgroundPoolProvider = AsyncNotifierProvider<TavernBackgroundPoolController, TavernBackgroundPool>(
  TavernBackgroundPoolController.new,
);

class TavernBackgroundPoolController extends AsyncNotifier<TavernBackgroundPool> {
  @override
  Future<TavernBackgroundPool> build() => TavernBackgroundPool.load();

  Future<void> _update(TavernBackgroundPool Function(TavernBackgroundPool) change) async {
    final current = state.value ?? const TavernBackgroundPool();
    final next = change(current);
    state = AsyncData(next);
    await TavernBackgroundPool.save(next);
  }

  Future<void> setDirectory(String directory) =>
      _update((pool) => pool.copyWith(directory: directory, last: ''));

  Future<void> toggle(WallpaperPoolTrigger trigger, bool on) => _update((pool) => pool.toggled(trigger, on));

  Future<void> setSeconds(int value) => _update((pool) => pool.withSeconds(value));

  Future<void> setBlur(double value) => _update((pool) => pool.copyWith(blur: value.clamp(0.0, 1.0)));

  Future<void> setTone(Brightness brightness, double value) => _update(
    (pool) => brightness == Brightness.dark
        ? pool.copyWith(dim: value.clamp(0.0, 1.0))
        : pool.copyWith(lighten: value.clamp(0.0, 1.0)),
  );

  /// 全图（true）还是裁剪铺满（false）。
  Future<void> setRaw(bool raw) => _update((pool) => pool.copyWith(raw: raw));

  /// 一次把观感定下来（换图时把这一套钉进池，之后换图 / 换局都沿用）。
  Future<void> withLook({double? blur, double? lighten, double? dim}) =>
      _update((pool) => pool.withLook(blur: blur, lighten: lighten, dim: dim));

  Future<void> setDirect(bool direct) => _update((pool) => pool.copyWith(direct: direct));

  /// 记住刚挑中的那张，随机时避开它。
  Future<void> take(String path) => _update((pool) => pool.copyWith(last: path));
}
