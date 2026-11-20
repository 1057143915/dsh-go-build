// 酒馆随机背景：池子的读写、避开上一张、观感沿用，以及三个时机的判断都在池子和
// 换图器里（lib/tavern/tavern_background_pool.dart、lib/tavern/tavern_background_rotation.dart）。

import 'dart:io';
import 'dart:ui' show Brightness;

import 'package:dsh_app/tavern/tavern_background_pool.dart';
import 'package:dsh_app/wallpaper/wallpaper_pool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a fresh pool has no folder and no triggers', () async {
    final pool = await TavernBackgroundPool.load();
    expect(pool.hasDirectory, isFalse);
    expect(pool.triggers, isEmpty);
    expect(pool.seconds, WallpaperPool.defaultSeconds);
    expect(pool.raw, isTrue, reason: '默认整图不裁切');
    expect(pool.toneFor(Brightness.light), isNull);
  });

  test('the pool survives a round trip; unknown triggers are dropped', () async {
    const pool = TavernBackgroundPool(
      directory: '/pics',
      triggers: {WallpaperPoolTrigger.launch, WallpaperPoolTrigger.interval},
      seconds: 7,
      last: '/pics/a.jpg',
      raw: false,
      direct: true,
      blur: 0.4,
      lighten: 0.25,
      dim: 0.6,
    );
    await TavernBackgroundPool.save(pool);
    final back = await TavernBackgroundPool.load();
    expect(back.directory, '/pics');
    expect(back.triggers, {WallpaperPoolTrigger.launch, WallpaperPoolTrigger.interval});
    expect(back.seconds, 7);
    expect(back.last, '/pics/a.jpg');
    expect(back.raw, isFalse);
    expect(back.direct, isTrue);
    expect(back.blur, 0.4);
    expect(back.toneFor(Brightness.dark), 0.6);
    expect(back.toneFor(Brightness.light), 0.25);

    expect(TavernBackgroundPool.fromJson({'triggers': ['nope', 'chat']}).triggers, {WallpaperPoolTrigger.chat});
    expect(TavernBackgroundPool.fromJson({'seconds': 1}).seconds, WallpaperPool.defaultSeconds);
    expect(TavernBackgroundPool.fromJson('nope').hasDirectory, isFalse);
  });

  test('it is its own key: the app wallpaper pool is untouched', () async {
    final prefs = await SharedPreferences.getInstance();
    await TavernBackgroundPool.save(const TavernBackgroundPool(directory: '/tavern-pics'));
    expect(prefs.getString(WallpaperPool.prefsKey), isNull);
    expect(prefs.getString(TavernBackgroundPool.prefsKey), contains('/tavern-pics'));
  });

  test('seconds stay inside 3 s – 10 min and the trigger set follows the switch', () {
    const pool = TavernBackgroundPool();
    expect(pool.withSeconds(1).seconds, WallpaperPool.minSeconds);
    expect(pool.withSeconds(99999).seconds, WallpaperPool.maxSeconds);
    final on = pool.toggled(WallpaperPoolTrigger.chat, true);
    expect(on.has(WallpaperPoolTrigger.chat), isTrue);
    expect(on.toggled(WallpaperPoolTrigger.chat, false).has(WallpaperPoolTrigger.chat), isFalse);
  });

  test('picking a picture avoids the one on screen, and copes with a folder of one', () {
    final images = ['/p/a.jpg', '/p/b.jpg', '/p/c.jpg'];
    for (var i = 0; i < 30; i++) {
      expect(WallpaperPool.pick(images, '/p/b.jpg'), isNot('/p/b.jpg'));
    }
    expect(WallpaperPool.pick(['/p/only.jpg'], '/p/only.jpg'), '/p/only.jpg');
    expect(WallpaperPool.pick(const [], null), isNull);
  });

  test('the folder scan keeps to pictures when it is asked to', () async {
    final dir = await Directory.systemTemp.createTemp('tavern-bg');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/a.jpg').writeAsBytes([0]);
    await File('${dir.path}/b.txt').writeAsString('x');
    await Directory('${dir.path}/sub').create();
    await File('${dir.path}/sub/c.png').writeAsBytes([0]);
    final pictures = await WallpaperPool.images(dir.path);
    expect(pictures.length, 2);
    expect(pictures.every((path) => path.endsWith('.jpg') || path.endsWith('.png')), isTrue);
    final all = await WallpaperPool.allImages(dir.path);
    expect(all.length, 3);
  });
}
