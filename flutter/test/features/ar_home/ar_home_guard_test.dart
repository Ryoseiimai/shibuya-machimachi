// 約束の見張り（ソースを読む静的チェック）と、アイコン・起動画面の素材の形。
// - カメラ映像は画面に出すだけ: 画像ストリーム・撮影・録画・録音を呼ばない。enableAudio: false
// - この機能から通信しない・座標をログに出さない
// - iOS アイコンは透過なし・Contents.json どおりの大きさ
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const featureDir = 'lib/features/ar_home';
const brandingDir = 'assets/ar_home/branding';

Iterable<File> dartFiles() =>
    Directory(featureDir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

/// PNG の IHDR から (幅, 高さ, 色の種類) を読む。色の種類 2=RGB（透過なし）、6=RGBA。
(int, int, int) pngInfo(File f) {
  final b = f.readAsBytesSync();
  final d = ByteData.sublistView(b);
  expect(b.sublist(1, 4), 'PNG'.codeUnits, reason: f.path);
  return (d.getUint32(16), d.getUint32(20), b[25]);
}

void main() {
  test('カメラは表示だけ（画像ストリーム・撮影・録画・録音なし）', () {
    final src = File('$featureDir/ar_camera.dart').readAsStringSync();
    for (final banned in ['startImageStream', 'takePicture', 'startVideoRecording', 'prepareForVideoRecording']) {
      expect(src.contains('$banned('), isFalse, reason: banned);
    }
    expect(src, contains('enableAudio: false'));
    expect(RegExp(r'enableAudio:\s*true').hasMatch(src), isFalse);
  });

  test('この機能から通信しない・ログに出さない', () {
    for (final f in dartFiles()) {
      final src = f.readAsStringSync();
      for (final banned in [
        "package:http/",
        'WebSocket',
        'HttpClient',
        'print(',
        'debugPrint(',
        'sendFloor(',
        'sendLocation',
        'Clipboard',
      ]) {
        // debugPrint( は print( を含むので両方ここで見張る
        expect(src.contains(banned), isFalse, reason: '${f.path}: $banned');
      }
    }
  });

  test('iOS アイコン: Contents.json のファイルが全部あり、大きさが合い、透過なし', () {
    final dir = '$brandingDir/ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final contents = jsonDecode(File('$dir/Contents.json').readAsStringSync()) as Map<String, dynamic>;
    final images = (contents['images'] as List).cast<Map<String, dynamic>>();
    expect(images, isNotEmpty);
    for (final img in images) {
      final name = img['filename'] as String;
      final pt = double.parse((img['size'] as String).split('x').first);
      final scale = int.parse((img['scale'] as String).replaceAll('x', ''));
      final (w, h, colorType) = pngInfo(File('$dir/$name'));
      expect((w, h), ((pt * scale).round(), (pt * scale).round()), reason: name);
      expect(colorType, isNot(6), reason: '$name は透過なしにする（App Store の決まり）');
    }
  });

  test('Android アイコン・起動画面の素材がそろっている', () {
    const res = '$brandingDir/android/app/src/main/res';
    const dens = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
    dens.forEach((d, s) {
      expect(pngInfo(File('$res/mipmap-$d/ic_launcher.png')).$1, (48 * s).round(), reason: d);
      expect(pngInfo(File('$res/mipmap-$d/ic_launcher_foreground.png')).$1, (108 * s).round(), reason: d);
      expect(pngInfo(File('$res/mipmap-$d/ic_launcher_background.png')).$1, (108 * s).round(), reason: d);
      expect(pngInfo(File('$res/drawable-$d/splash_mark.png')).$1, (160 * s).round(), reason: d);
    });
    expect(File('$res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync(), contains('adaptive-icon'));
    expect(File('$res/values/colors.xml').readAsStringSync(), contains('#FFF7F0'));
    expect(File('$res/drawable/launch_background.xml').readAsStringSync(), contains('@drawable/splash_mark'));
  });

  test('iOS 起動画面: 地は #fff7f0、マークは 200pt', () {
    final sb = File('$brandingDir/ios/Runner/Base.lproj/LaunchScreen.storyboard').readAsStringSync();
    expect(sb, contains('green="0.96862745098039216" blue="0.94117647058823528"'));
    expect(sb, contains('<image name="LaunchImage" width="200" height="200"/>'));
    const li = '$brandingDir/ios/Runner/Assets.xcassets/LaunchImage.imageset';
    expect(pngInfo(File('$li/LaunchImage.png')).$1, 200);
    expect(pngInfo(File('$li/LaunchImage@2x.png')).$1, 400);
    expect(pngInfo(File('$li/LaunchImage@3x.png')).$1, 600);
  });
}
