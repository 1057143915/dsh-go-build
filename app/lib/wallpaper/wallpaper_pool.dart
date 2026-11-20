// 壁纸池：一个文件夹里的多张图片，随机挑一张当壁纸（lib/state/wallpaper_state.dart 的
// CustomWallpaperController.rotate）。设置和 CustomWallpaper 一样存 shared_preferences 的一条
// JSON；图片留在用户自己的文件夹里。
//
// 两条取图方式：
//  - 检查（默认）：把挑中的那一张交给 WallpaperImport.keep()，走原有的导入（拷贝、15 MB 上限、
//    PNG / JPEG / WebP、取边缘色、保留观感）。
//  - 不检查（direct）：原图直接当壁纸，不拷贝、不按大小和格式拦，取景用原样模式。
//
// 原样显示（raw）管的是画法：整图等比放进屏幕、居中、不裁切，不盖系统自动算的白纱。
// 模糊和提亮 / 压暗存在池里（blur / lighten / dim），换下一张照样沿用。

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Brightness;

import 'package:flutter/foundation.dart' show compute;
import 'package:shared_preferences/shared_preferences.dart';

/// 什么时候自动换一张；可以同时开着几个。
enum WallpaperPoolTrigger {
  /// 每次启动 App。
  launch,

  /// 切换聊天框（当前会话变了）。
  chat,

  /// 到时间。
  interval,
}

/// 壁纸文件夹、自动更换的时机与间隔、上一张（随机时避开它）、以及两条取图/画法开关。
class WallpaperPool {
  const WallpaperPool({
    this.directory = '',
    this.triggers = const <WallpaperPoolTrigger>{},
    this.seconds = defaultSeconds,
    this.last = '',
    this.raw = true,
    this.direct = false,
    this.blur,
    this.lighten,
    this.dim,
  });

  static const prefsKey = 'wallpaper_pool';

  /// 定时换的间隔（秒），3 秒到 10 分钟，拖动滑块自己调。
  static const minSeconds = 3;
  static const maxSeconds = 600;
  static const defaultSeconds = 30;

  /// 一次最多认这么多张：几万张图的文件夹不整个读进来。
  static const maxImages = 2000;

  /// 挑中的图读不出来（太大、坏了）时，最多再试几张。
  static const maxAttempts = 5;

  /// 认的后缀，走检查那条路时用（和导入一致：PNG、JPEG、WebP）。
  static const extensions = {'.png', '.jpg', '.jpeg', '.webp'};

  final String directory;
  final Set<WallpaperPoolTrigger> triggers;

  /// 定时换的间隔（秒）。
  final int seconds;

  /// 上一次挑中的原图路径。
  final String last;

  /// 原样显示：整图居中、不裁切，模糊和提亮 / 压暗归零。
  final bool raw;

  /// 不检查：原图直接当壁纸，不拷贝、不按大小和格式拦（认不出的格式解码不出来才跳过）。
  final bool direct;

  /// 观感：模糊、浅色提亮、深色压暗。null 表示还没调过（用 App 默认值）。
  /// 存在池里，所以换下一张时沿用同一套 —— 不会每换一张就回到默认。
  final double? blur;
  final double? lighten;
  final double? dim;

  bool has(WallpaperPoolTrigger trigger) => triggers.contains(trigger);

  WallpaperPool copyWith({
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
      WallpaperPool(
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

  /// [trigger] 开着或关掉。
  WallpaperPool toggled(WallpaperPoolTrigger trigger, bool on) {
    final next = {...triggers};
    if (on) {
      next.add(trigger);
    } else {
      next.remove(trigger);
    }
    return copyWith(triggers: next);
  }

  /// 间隔改成 [value] 秒（夹在 3 秒到 10 分钟之间）。
  WallpaperPool withSeconds(int value) => copyWith(seconds: value.clamp(minSeconds, maxSeconds));

  /// 记住这一套观感（换图时沿用）。
  WallpaperPool withLook({double? blur, double? lighten, double? dim}) =>
      copyWith(blur: blur, lighten: lighten, dim: dim);

  /// [brightness] 那一档的色调；没调过返回 null。
  double? toneFor(Brightness brightness) => brightness == Brightness.dark ? dim : lighten;

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

  static WallpaperPool fromJson(Object? raw) {
    if (raw is! Map) return const WallpaperPool();
    final directory = raw['directory'];
    final triggers = raw['triggers'];
    final seconds = raw['seconds'];
    final last = raw['last'];
    return WallpaperPool(
      directory: directory is String ? directory : '',
      triggers: triggers is List
          ? {
              for (final name in triggers)
                ...WallpaperPoolTrigger.values.where((trigger) => trigger.name == name),
            }
          : const <WallpaperPoolTrigger>{},
      seconds: seconds is int && seconds >= minSeconds && seconds <= maxSeconds ? seconds : defaultSeconds,
      last: last is String ? last : '',
      raw: raw['raw'] != false,
      direct: raw['direct'] == true,
      blur: _unit(raw['blur']),
      lighten: _unit(raw['lighten']),
      dim: _unit(raw['dim']),
    );
  }

  /// 0–1 的浮点，坏值当没设置。
  static double? _unit(Object? value) {
    if (value is! num || !value.isFinite) return null;
    return value.toDouble().clamp(0.0, 1.0);
  }

  /// 存着的那份；没有、坏了就当没设置过。
  static Future<WallpaperPool> load([SharedPreferences? prefs]) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final stored = store.getString(prefsKey);
      if (stored == null) return const WallpaperPool();
      return fromJson(jsonDecode(stored));
    } catch (_) {
      return const WallpaperPool();
    }
  }

  static Future<void> save(WallpaperPool pool) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(pool.toJson()));
  }

  /// 列目录的结果缓存：同一文件夹 30 秒内不重复遍历。切换聊天框时每次都走一遍文件系统
  /// 会让界面掉帧（几千张图就是几千次 stat），缓存 + 后台 isolate 之后切屏不卡。
  static final Map<String, (DateTime, List<String>)> _cache = {};
  static const _cacheTtl = Duration(seconds: 30);

  /// 缓存最多留这么多条（每个文件夹一条），免得换过很多目录后一直堆着。
  static const _cacheLimit = 8;

  static List<String>? _cached(String key) {
    final hit = _cache[key];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.$1) > _cacheTtl) {
      _cache.remove(key);
      return null;
    }
    return hit.$2;
  }

  static void _remember(String key, List<String> images) {
    if (_cache.length >= _cacheLimit) {
      // 先清过期的，还满就丢最早那条。
      _cache.removeWhere((_, hit) => DateTime.now().difference(hit.$1) > _cacheTtl);
      if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    }
    _cache[key] = (DateTime.now(), images);
  }

  /// [directory] 里（含子文件夹）能当壁纸的图片。排序让每次列举的顺序一样 —— 顺序不定的话
  /// 「随机」会退化成「跟着文件系统的返回顺序走」。不检查那条路用的是 [allImages]。
  static Future<List<String>> images(String directory, {int limit = maxImages}) async {
    if (directory.isEmpty) return const [];
    final key = 'img|$directory|$limit';
    final cached = _cached(key);
    if (cached != null) return cached;
    // 文件遍历放到后台 isolate：不占 UI 线程，切换聊天框时不会掉帧。
    final found = await _scan((directory, limit, true));
    _remember(key, found);
    return found;
  }

  /// 不检查那条路用的列举：不管后缀，只要是文件就收（认不出的格式在解码时会被跳过）。
  static Future<List<String>> allImages(String directory, {int limit = maxImages}) async {
    if (directory.isEmpty) return const [];
    final key = 'all|$directory|$limit';
    final cached = _cached(key);
    if (cached != null) return cached;
    final found = await _scan((directory, limit, false));
    _remember(key, found);
    return found;
  }

  /// 实际的遍历（在后台 isolate 里跑）。[onlyPictures] 为真时只收 PNG / JPEG / WebP。
  static Future<List<String>> _scan((String, int, bool) job) async {
    final (directory, limit, onlyPictures) = job;
    try {
      if (!Directory(directory).existsSync()) return const [];
      return await compute(_scanSync, job);
    } catch (_) {
      return const [];
    }
  }

  /// [compute] 的入口：必须顶格、只接一个参数，才能被送进后台 isolate。
  static List<String> _scanSync((String, int, bool) job) {
    final (directory, limit, onlyPictures) = job;
    final found = <String>[];
    try {
      for (final entity in Directory(directory).listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (onlyPictures && !extensions.contains(extensionOf(entity.path))) continue;
        found.add(entity.path);
        if (found.length >= limit) break;
      }
    } catch (_) {
      return const [];
    }
    found.sort();
    return found;
  }

  /// [path] 的小写后缀（含点）；没有后缀时空串。
  static String extensionOf(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot).toLowerCase();
  }

  /// 随机挑一张，避开 [current]（连着两次同一张很出戏）；只有一张时就用那一张。
  static String? pick(List<String> images, String? current, {Random? random}) {
    if (images.isEmpty) return null;
    final choices = images.length > 1 && current != null ? images.where((path) => path != current).toList() : images;
    final from = choices.isEmpty ? images : choices;
    return from[(random ?? Random()).nextInt(from.length)];
  }
}
