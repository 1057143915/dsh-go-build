// 壁纸池（lib/wallpaper/wallpaper_pool.dart + wallpaper_state 的 rotate）：文件夹列举与过滤、
// 随机避开上一张、设置的读写与回落、原样显示的取景与「不盖纱」、秒级间隔。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect, Size, Brightness;

import 'package:dsh_app/state/wallpaper_state.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/wallpaper_import.dart';
import 'package:dsh_app/wallpaper/wallpaper_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pool;

  setUp(() async {
    pool = await Directory.systemTemp.createTemp('wallpaper-pool');
  });

  tearDown(() async {
    if (pool.existsSync()) await pool.delete(recursive: true);
  });

  Future<void> put(String name, String bytes) async {
    final file = File('${pool.path}/$name');
    await file.create(recursive: true);
    await file.writeAsString(bytes);
  }

  test('列出文件夹里的图片：只认 PNG / JPEG / WebP，含子文件夹，顺序稳定', () async {
    await put('b.JPG', 'b');
    await put('a.png', 'a');
    await put('c.gif', 'c');
    await put('d.txt', 'd');
    await put('sub/e.webp', 'e');

    expect(await WallpaperPool.images(pool.path), [
      '${pool.path}/a.png',
      '${pool.path}/b.JPG',
      '${pool.path}/sub/e.webp',
    ]);
    expect(await WallpaperPool.images('${pool.path}/missing'), isEmpty);
    expect(await WallpaperPool.images(''), isEmpty);
  });

  test('不检查那条路的列举：不管后缀', () async {
    await put('a.png', 'a');
    await put('b.gif', 'b');
    await put('c.txt', 'c');

    expect(await WallpaperPool.allImages(pool.path), [
      '${pool.path}/a.png',
      '${pool.path}/b.gif',
      '${pool.path}/c.txt',
    ]);
  });

  test('随机挑一张避开上一张；只有一张时就是它', () {
    expect(WallpaperPool.pick(const [], '/a.png'), isNull);
    expect(WallpaperPool.pick(const ['/a.png'], '/a.png'), '/a.png');
    for (var i = 0; i < 20; i++) {
      expect(WallpaperPool.pick(const ['/a.png', '/b.png'], '/a.png'), '/b.png');
    }
  });

  test('原样显示：取景就是整图（不裁切），铺满交给渲染层', () {
    // 宽图、高图、同比例：windowIn 一律返回整图，渲染层再按 contain 缩小居中。
    for (final size in [(2000, 1000), (1000, 2000), (800, 400)]) {
      final w = CustomWallpaper(path: '/x.jpg', width: size.$1, height: size.$2, raw: true);
      expect(
        w.windowIn(Size(size.$1.toDouble(), size.$2.toDouble()), const Size(800, 800)),
        Rect.fromLTWH(0, 0, size.$1.toDouble(), size.$2.toDouble()),
      );
    }

    // 没开原样显示时还是覆盖（裁切）那套老行为。
    final cover = CustomWallpaper(path: '/d.jpg', width: 2000, height: 1000);
    expect(cover.windowIn(const Size(2000, 1000), const Size(800, 800)).width, 1600);
  });

  test('模糊与提亮压暗不再被原样显示强制归零', () {
    final w = CustomWallpaper(path: '/x.jpg', width: 100, height: 100, raw: true, blur: 0.5, lighten: 0.3, dim: 0.4);
    expect(w.blur, 0.5);
    expect(w.lighten, 0.3);
    expect(w.dim, 0.4);
    // withTone 仍然只改对应亮度那一档。
    expect(w.withTone(Brightness.dark, 0.9).dim, 0.9);
    expect(w.withTone(Brightness.light, 0.9).lighten, 0.9);
  });

  test('设置的读写与回落；间隔是秒、可手调到 10 秒', () {
    final pool = WallpaperPool(directory: '/pics', seconds: 10, raw: true, direct: true);
    final back = WallpaperPool.fromJson(jsonDecode(jsonEncode(pool.toJson())));
    expect(back.directory, '/pics');
    expect(back.seconds, 10);
    expect(back.triggers, isEmpty);
    expect(back.raw, isTrue);
    expect(back.direct, isTrue);

    // 新装默认：原样显示开着（清晰优先），定时关着。
    expect(const WallpaperPool().raw, isTrue);
    expect(const WallpaperPool().seconds, WallpaperPool.defaultSeconds);

    // 秒级范围：3 秒到 10 分钟。
    expect(back.withSeconds(1).seconds, WallpaperPool.minSeconds);
    expect(back.withSeconds(99999).seconds, WallpaperPool.maxSeconds);
    expect(back.withSeconds(10).seconds, 10);

    expect(back.toggled(WallpaperPoolTrigger.chat, true).has(WallpaperPoolTrigger.chat), isTrue);
    expect(back.toggled(WallpaperPoolTrigger.chat, true).toggled(WallpaperPoolTrigger.chat, false).triggers, isEmpty);

    // 越界或坏值回落默认。
    expect(WallpaperPool.fromJson({'seconds': 1}).seconds, WallpaperPool.defaultSeconds);
    expect(WallpaperPool.fromJson({'seconds': 'ten'}).seconds, WallpaperPool.defaultSeconds);
    final broken = WallpaperPool.fromJson({'directory': 7, 'triggers': 'chat', 'last': null});
    expect(broken.directory, '');
    expect(broken.triggers, isEmpty);
    expect(broken.last, '');
    expect(WallpaperPool.fromJson(null).directory, '');
  });

  group('从池里换一张', () {
    late Directory output;

    setUp(() async {
      output = await Directory.systemTemp.createTemp('wallpaper-copy');
      // 坏图排在前面（PNG 头、解不出来），好图是 720 × 1280 的 JPEG。
      await File(brokenFixture).copy('${pool.path}/01_broken.png');
      await File(brightFixture).copy('${pool.path}/02_bright.jpg');
    });

    tearDown(() async {
      if (output.existsSync()) await output.delete(recursive: true);
    });

    ProviderContainer container() {
      final container = ProviderContainer(
        overrides: [wallpaperImportProvider.overrideWithValue(WallpaperImport(directory: () async => output))],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('检查那条路：坏图跳过，换成能用的那一张；池里的原图不动', () async {
      SharedPreferences.setMockInitialValues({
        WallpaperPool.prefsKey: jsonEncode(WallpaperPool(directory: pool.path, raw: false).toJson()),
      });
      final provider = container();
      final notifier = provider.read(customWallpaperProvider.notifier);
      for (var i = 0; i < 5; i++) {
        expect(await notifier.rotate(force: true), isTrue);
        final wallpaper = provider.read(customWallpaperProvider).value!;
        expect(wallpaper.path, startsWith(output.path));
        expect(File(wallpaper.path).existsSync(), isTrue);
      }
      final stored = await WallpaperPool.load();
      expect(stored.last, '${pool.path}/02_bright.jpg');
      expect(File(stored.last).existsSync(), isTrue);
    });

    test('不检查那条路：原图直接当壁纸，不拷贝、不模糊不压暗、标记原样显示', () async {
      SharedPreferences.setMockInitialValues({
        WallpaperPool.prefsKey: jsonEncode(
          WallpaperPool(directory: pool.path, direct: true, raw: true).toJson(),
        ),
      });
      final provider = container();
      expect(await provider.read(customWallpaperProvider.notifier).rotate(force: true), isTrue);
      final wallpaper = provider.read(customWallpaperProvider).value!;
      expect(wallpaper.path, '${pool.path}/02_bright.jpg'); // 原图本身，没有被拷走
      expect(File(wallpaper.path).existsSync(), isTrue);
      expect(wallpaper.blur, 0);
      expect(wallpaper.lighten, 0);
      expect(wallpaper.dim, 0);
      expect(wallpaper.raw, isTrue);
    });

    test('切回旧聊天也会换：连着换两次都真换，不是只在新聊天里换', () async {
      SharedPreferences.setMockInitialValues({
        WallpaperPool.prefsKey: jsonEncode(WallpaperPool(directory: pool.path).toJson()),
      });
      final provider = container();
      final notifier = provider.read(customWallpaperProvider.notifier);
      // 第一次（force 绕过防抖，模拟真正的一次切屏）
      expect(await notifier.rotate(force: true), isTrue);
      final first = provider.read(customWallpaperProvider).value!.path;
      // 等过防抖窗口，再切一次（这就是「切回去过的聊天」）
      await Future<void>.delayed(CustomWallpaperController.rotateDebounce + const Duration(milliseconds: 50));
      expect(await notifier.rotate(), isTrue);
      final second = provider.read(customWallpaperProvider).value!.path;
      expect(second, isNot(first));
    });

    test('同一次切屏里重复触发只换一次（防抖，不是冷却）', () async {
      SharedPreferences.setMockInitialValues({
        WallpaperPool.prefsKey: jsonEncode(WallpaperPool(directory: pool.path).toJson()),
      });
      final provider = container();
      final notifier = provider.read(customWallpaperProvider.notifier);
      final results = await Future.wait([notifier.rotate(), notifier.rotate(), notifier.rotate()]);
      expect(results.where((r) => r).length, 1);
    });

    test('磨糊/压暗会跟着换下一张（不会跳回默认）', () async {
      SharedPreferences.setMockInitialValues({
        WallpaperPool.prefsKey: jsonEncode(
          WallpaperPool(directory: pool.path, direct: true, raw: true, blur: 0.66, lighten: 0.2, dim: 0.45).toJson(),
        ),
      });
      final provider = container();
      expect(await provider.read(customWallpaperProvider.notifier).rotate(force: true), isTrue);
      final w = provider.read(customWallpaperProvider).value!;
      expect(w.blur, 0.66);
      expect(w.lighten, 0.2);
      expect(w.dim, 0.45);
    });

    test('在设置页调磨糊/色调会写进池，下一张沿用', () async {
      SharedPreferences.setMockInitialValues({
        WallpaperPool.prefsKey: jsonEncode(WallpaperPool(directory: pool.path, direct: true).toJson()),
      });
      final provider = container();
      final notifier = provider.read(customWallpaperProvider.notifier);
      expect(await notifier.rotate(force: true), isTrue);

      await notifier.setBlur(0.8);
      await notifier.setTone(Brightness.dark, 0.3);
      final settings = await provider.read(wallpaperPoolProvider.future);
      expect(settings.blur, 0.8);
      expect(settings.dim, 0.3);

      // 换下一张，磨糊和压暗还在。
      await Future<void>.delayed(CustomWallpaperController.rotateDebounce + const Duration(milliseconds: 50));
      expect(await notifier.rotate(), isTrue);
      final next = provider.read(customWallpaperProvider).value!;
      expect(next.blur, 0.8);
      expect(next.dim, 0.3);
    });

    test('文件夹里没有能用的图：不换，也不报错', () async {
      await File('${pool.path}/02_bright.jpg').delete();
      SharedPreferences.setMockInitialValues({
        WallpaperPool.prefsKey: jsonEncode(WallpaperPool(directory: pool.path).toJson()),
      });
      final provider = container();
      expect(await provider.read(customWallpaperProvider.notifier).rotate(force: true), isFalse);
      expect(provider.read(customWallpaperProvider).value, isNull);
    });
  });
}
