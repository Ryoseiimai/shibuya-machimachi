// 高画質3D: 同梱物（Web 版の写しが元とずれていないか・省メモリ設定）・行き先の制限・JS との橋・画面の動き。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/map3d/map3d_screen.dart';
import 'package:shibuya_machimachi/features/map3d/src/hq_web.dart';

const _hqDir = 'assets/hq';
const _worker = '../worker/public';

String _read(String p) => File(p).readAsStringSync();

/// テスト用の偽 WebView。Dart→JS の呼び出しを記録し、JS→Dart の知らせを流せる。
class FakeHost implements HqWebHost {
  final calls = <(String, Map<String, Object?>)>[];
  @override
  Future<void> call(String method, Map<String, Object?> args) async => calls.add((method, args));
}

class FakeRoom extends RoomController {
  FakeRoom(this.initial);
  final RoomState? initial;
  @override
  RoomViewState build() => RoomViewState(server: initial);
  void setServer(RoomState s) => state = RoomViewState(server: s);
}

RoomState _state(String phase, {String? selfFloor, String? otherFloor}) => RoomState.fromJson({
      'phase': phase,
      'role': 'host',
      'self': {'nickname': 'りょう', 'approved': true, 'floor': selfFloor},
      'other': {'nickname': 'すず"<b>', 'approved': true, 'floor': otherFloor},
      'distance_m': 120,
      'bearing_deg': 45,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('同梱物（assets/hq）', () {
    test('配る一覧のファイルが全部あり、pubspec の assets/hq/ 直下に平置きされている', () {
      for (final name in kHqAssetFiles.keys) {
        expect(File('$_hqDir/$name').existsSync(), isTrue, reason: name);
      }
      final onDisk = Directory(_hqDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.js') || n.endsWith('.html') || n.endsWith('.wasm'));
      expect(onDisk.toSet(), kHqAssetFiles.keys.toSet(), reason: '一覧に無い JS/HTML/wasm を置かない');
      expect(Directory(_hqDir).listSync().whereType<Directory>(), isEmpty, reason: 'サブフォルダは pubspec に登録が要る');
    });

    test('three.js・3d-tiles-renderer の写しは、import の書き換え以外は Web 版と同じ', () {
      final pairs = <String, String>{
        'three.module.js': 'vendor/three/three.module.js',
        'GLTFLoader.js': 'vendor/three/examples/jsm/loaders/GLTFLoader.js',
        'DRACOLoader.js': 'vendor/three/examples/jsm/loaders/DRACOLoader.js',
        'BufferGeometryUtils.js': 'vendor/three/examples/jsm/utils/BufferGeometryUtils.js',
        'draco_wasm_wrapper.js': 'vendor/three/examples/jsm/libs/draco/gltf/draco_wasm_wrapper.js',
        'index.three.js': 'vendor/3d-tiles-renderer/index.three.js',
        'renderer-CUfHAmYW.js': 'vendor/3d-tiles-renderer/renderer-CUfHAmYW.js',
        'renderer-_7gAivIK.js': 'vendor/3d-tiles-renderer/renderer-_7gAivIK.js',
        'GLTFCesiumRTCExtension.js': 'vendor/3d-tiles-renderer/GLTFCesiumRTCExtension.js',
      };
      String norm(String s) => s
          .replaceAll("'../../../three.module.js'", "'./three.module.js'")
          .replaceAll("'../utils/BufferGeometryUtils.js'", "'./BufferGeometryUtils.js'")
          .replaceAll('"../three/three.module.js"', '"./three.module.js"')
          .replaceAll('"../three/examples/jsm/loaders/GLTFLoader.js"', '"./GLTFLoader.js"')
          .replaceAll('"../three/examples/jsm/utils/BufferGeometryUtils.js"', '"./BufferGeometryUtils.js"');
      for (final e in pairs.entries) {
        expect(_read('$_hqDir/${e.key}'), norm(_read('$_worker/${e.value}')), reason: e.key);
      }
      expect(File('$_hqDir/draco_decoder.wasm').readAsBytesSync(),
          File('$_worker/vendor/three/examples/jsm/libs/draco/gltf/draco_decoder.wasm').readAsBytesSync());
      // 平置きの中で親フォルダを見に行く import が残っていない
      for (final name in kHqAssetFiles.keys.where((n) => n.endsWith('.js'))) {
        expect(RegExp(r'''from\s*["']\.\./''').hasMatch(_read('$_hqDir/$name')), isFalse, reason: name);
      }
    });

    test('shibuya3d-hq.js は省メモリ設定（Web 版の TOUCH_LIMITS そのまま）を必ず使う', () {
      final app = _read('$_hqDir/shibuya3d-hq.js');
      final web = _read('$_worker/assets/js/shibuya3d-hq.mjs');
      String block(String s) {
        final start = s.indexOf('const TOUCH_LIMITS = Object.freeze({');
        return s.substring(start, s.indexOf('});', start) + 3);
      }

      expect(block(app), block(web));
      for (final v in [
        'areaRadiusM: 500',
        'leafTextureMaxPx: 1024',
        'parentTextureMaxPx: 512',
        'cacheMaxBytes: 220 * MB',
        'cacheMinBytes: 150 * MB',
        'downloadJobs: 4',
        'parseJobs: 2',
        'dracoWorkers: 2',
      ]) {
        expect(block(app), contains(v));
      }
      expect(app, contains('const LIMITS = TOUCH_LIMITS;'));
      expect(app, isNot(contains('const DESKTOP_LIMITS')));
      expect(app, isNot(contains('const IS_COARSE_POINTER')));
      // 見た目・データの元は同じ
      String line(String s, String key) => s.split('\n').firstWhere((l) => l.startsWith(key));
      for (final key in ['const TILESET_URL', 'const GROUND_ELLIPSOIDAL_HEIGHT_M', 'const INTRO_DISTANCE_M', 'const ME_COLOR', 'const PARTNER_COLOR']) {
        expect(line(app, key), line(web, key));
      }
      // 閉じたときの後片付けは元のまま残っている
      for (final s in ['tiles.dispose()', 'dracoLoader.dispose()', 'renderer.dispose()', 'renderer.forceContextLoss()']) {
        expect(app, contains(s));
      }
    });

    test('外への通信は PLATEAU の配信元だけ（CSP）・橋は座標を Flutter へ返さない', () {
      final html = _read('$_hqDir/index.html');
      final csp = RegExp(r'Content-Security-Policy" content="([^"]+)"').firstMatch(html)!.group(1)!;
      final hosts = RegExp(r'https://[a-z0-9.-]+').allMatches(csp).map((m) => m.group(0)).toSet();
      expect(hosts, {'https://$kPlateauHost'});
      expect(csp, contains("object-src 'none'"));
      expect(csp, contains("form-action 'none'"));
      expect(html, isNot(contains('<script>')), reason: 'インラインのスクリプトは置かない');
      final bridge = _read('$_hqDir/hq-bridge.js');
      final posts = RegExp(r'post\(\{([^}]*)\}\)').allMatches(bridge).map((m) => m.group(1)!).toList();
      expect(posts, isNotEmpty);
      for (final p in posts) {
        expect(p, isNot(contains('lat')));
        expect(p, isNot(contains('lng')));
        expect(p, isNot(contains('name')));
      }
      expect(bridge, isNot(contains('fetch(')));
      expect(bridge, contains('"$kHqHandlerName"'));
    });

    test('rootBundle から読める（pubspec 登録済み）', () async {
      for (final name in kHqAssetFiles.keys) {
        final data = await rootBundle.load('$kHqAssetDir/$name');
        expect(data.lengthInBytes, greaterThan(0), reason: name);
      }
    });
  });

  group('WebView の決まり', () {
    test('カスタムスキームで配るのは一覧のファイルだけ', () {
      expect(hqAssetNameFor(Uri.parse('machimachi-hq://app/index.html')), 'index.html');
      expect(hqAssetNameFor(Uri.parse('machimachi-hq://app/draco_decoder.wasm')), 'draco_decoder.wasm');
      expect(hqAssetNameFor(Uri.parse('machimachi-hq://app/../pubspec.yaml')), isNull);
      expect(hqAssetNameFor(Uri.parse('machimachi-hq://app/assets/hq/index.html')), isNull);
      expect(hqAssetNameFor(Uri.parse('machimachi-hq://evil/index.html')), isNull);
      expect(hqAssetNameFor(Uri.parse('https://app/index.html')), isNull);
      expect(hqAssetNameFor(Uri.parse('machimachi-hq://app/secret.json')), isNull);
    });

    test('画面の移動は自分の index.html だけ（iOS / Android）', () {
      for (final pf in [TargetPlatform.iOS, TargetPlatform.android]) {
        expect(isAllowedHqNavigation(hqEntryUri(platform: pf), platform: pf), isTrue);
        expect(isAllowedHqNavigation(Uri.parse('https://example.com/'), platform: pf), isFalse);
        expect(isAllowedHqNavigation(Uri.parse('https://$kPlateauHost/x/tileset.json'), platform: pf), isFalse);
        expect(isAllowedHqNavigation(null, platform: pf), isFalse);
      }
      expect(hqEntryUri(platform: TargetPlatform.iOS).toString(), 'machimachi-hq://app/index.html');
      expect(hqEntryUri(platform: TargetPlatform.android).toString(),
          'https://appassets.androidplatform.net/assets/flutter_assets/assets/hq/index.html');
    });

    test('JS からの知らせは4種類だけ読む', () {
      expect(HqMessage.parse({'type': 'ready'}), isA<HqReady>());
      expect(HqMessage.parse({'type': 'loaded'}), isA<HqLoaded>());
      expect((HqMessage.parse({'type': 'progress', 'pct': 42.4}) as HqProgress).pct, 42);
      expect((HqMessage.parse({'type': 'progress', 'pct': 180}) as HqProgress).pct, 100);
      expect(HqMessage.parse({'type': 'progress', 'pct': 'x'}), isNull);
      expect((HqMessage.parse({'type': 'error', 'code': 'tileset'}) as HqError).code, 'tileset');
      expect(HqMessage.parse({'type': 'evil'}), isNull);
      expect(HqMessage.parse('ready'), isNull);
    });

    test('Dart→JS は引数を別に渡す（名前を文字列に埋め込まない）', () {
      expect(hqJsFunctionBody('setPartner'), 'const h = window.machimachiHQ; if (h) h.setPartner(lat, lng, floor, name);');
      expect(hqJsFunctionBody('destroy'), 'const h = window.machimachiHQ; if (h) h.destroy();');
      expect(() => hqJsFunctionBody('eval'), throwsArgumentError);
    });

    test('エラーの文言', () {
      expect(hqErrorText('tileset'), contains('通信を確かめて'));
      expect(hqErrorText('crashed'), contains('メモリが足りない'));
      expect(hqErrorText('context_lost'), contains('メモリが足りない'));
      expect(hqErrorText('mount'), contains('使えません'));
    });
  });

  group('HqViewerScreen', () {
    late FakeHost host;
    late void Function(HqMessage) send;
    late void Function(String) fail;

    setUp(() {
      host = FakeHost();
      debugHqWebViewBuilder = ({required onCreated, required onMessage, required onFailed}) {
        onCreated(host);
        send = onMessage;
        fail = onFailed;
        return const ColoredBox(color: Colors.black, child: SizedBox.expand());
      };
    });
    tearDown(() => debugHqWebViewBuilder = null);

    Future<FakeRoom> pumpHq(WidgetTester tester, {RoomState? room}) async {
      final fake = FakeRoom(room);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          roomControllerProvider.overrideWith(() => fake),
          positionProvider.overrideWith((ref) => Stream.value(const PositionFix(lat: 35.659, lng: 139.7005, timestampMs: 0))),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HqViewerScreen())),
                  child: const Text('開く'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('読み込み表示 → 進捗 → 読み終わりで消える・出典と閉じるがある', (tester) async {
      await pumpHq(tester, room: _state('active', selfFloor: '3F', otherFloor: 'B1'));
      expect(find.text('高画質モデルを読み込み中…'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      expect(find.byTooltip('閉じる'), findsOneWidget);
      expect(find.text(Attributions.hq), findsOneWidget);

      send(const HqProgress(37));
      await tester.pump();
      expect(find.text('37%'), findsOneWidget);

      send(const HqLoaded());
      await tester.pump();
      expect(find.text('高画質モデルを読み込み中…'), findsNothing);
    });

    testWidgets('ready で自分と相手（推定・階・名前）を JS に渡す。同じ値は二度送らない', (tester) async {
      await pumpHq(tester, room: _state('active', selfFloor: '3F', otherFloor: 'B1'));
      expect(host.calls, isEmpty, reason: 'ready 前は送らない');
      send(const HqReady());
      await tester.pumpAndSettle();
      final me = host.calls.firstWhere((c) => c.$1 == 'setMe').$2;
      expect(me['floor'], 3);
      expect(me['lat'], 35.659);
      final p = host.calls.firstWhere((c) => c.$1 == 'setPartner').$2;
      expect(p['floor'], -1);
      expect(p['name'], 'すず"<b>');
      final expected = destinationPoint(35.659, 139.7005, 45, 120);
      expect(p['lat'], closeTo(expected.lat, 1e-12));
      final n = host.calls.length;
      await tester.pump();
      await tester.pump();
      expect(host.calls.length, n);
    });

    testWidgets('閉じるで destroy → 前の画面へ戻る', (tester) async {
      await pumpHq(tester, room: _state('active'));
      send(const HqReady());
      await tester.pump();
      await tester.tap(find.byTooltip('閉じる'));
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c.$1 == 'destroy').length, 1);
      expect(find.byType(HqViewerScreen), findsNothing);
      expect(find.text('開く'), findsOneWidget);
    });

    testWidgets('待ち合わせが終わったら（active でなくなったら）自分で閉じる', (tester) async {
      final room = await pumpHq(tester, room: _state('active'));
      send(const HqReady());
      await tester.pump();
      room.setServer(_state('stopped'));
      await tester.pumpAndSettle();
      expect(find.byType(HqViewerScreen), findsNothing);
      expect(host.calls.where((c) => c.$1 == 'destroy').length, 1);
    });

    testWidgets('中身が落ちたら WebView を外して文言を出す', (tester) async {
      await pumpHq(tester, room: _state('active'));
      fail('crashed');
      await tester.pump();
      expect(find.textContaining('メモリが足りない', findRichText: true), findsWidgets);
      expect(find.text('高画質モデルを読み込み中…'), findsNothing);
      expect(find.byType(ColoredBox).evaluate().where((e) => (e.widget as ColoredBox).color == Colors.black), isEmpty);
    });

    testWidgets('通信が無く tileset が取れないときの文言', (tester) async {
      await pumpHq(tester, room: _state('active'));
      send(const HqError('tileset'));
      await tester.pump();
      expect(find.textContaining('通信を確かめて', findRichText: true), findsWidgets);
    });
  });
}
