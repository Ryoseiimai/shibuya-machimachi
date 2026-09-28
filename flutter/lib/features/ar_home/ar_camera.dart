// AR の背面カメラ。映像は画面に出すだけで、送信・保存・画像ストリーム・撮影・録画・録音は一切しない
// （startImageStream / takePicture / startVideoRecording を呼ばない。enableAudio: false）。
// テストではプラグインに触れないよう、arCameraFactoryProvider を差し替える。
import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

enum ArCameraStatus {
  /// 許可の確認・初期化中。
  starting,

  /// 映像が出ている。
  ready,

  /// 許可されなかった（設定から許可してもらう）。
  denied,

  /// カメラが無い・初期化できない。
  unavailable,
}

/// AR のカメラの差し替え口。
abstract interface class ArCamera {
  /// 許可を確かめて背面カメラを開く。何度呼んでもよい（開いていれば ready を返す）。
  Future<ArCameraStatus> start();

  /// 映像（画面いっぱいに切り抜いて表示）。ready の間だけ呼ぶ。
  Widget buildPreview();

  /// 閉じる（アプリが裏に回ったとき・画面を閉じたとき）。
  Future<void> stop();
}

/// camera パッケージを使う本物。
class PluginArCamera implements ArCamera {
  CameraController? _controller;

  /// start と stop が入れ違ったとき、古い初期化の結果を捨てるための番号。
  int _generation = 0;

  @override
  Future<ArCameraStatus> start() async {
    if (_controller?.value.isInitialized ?? false) return ArCameraStatus.ready;
    final gen = ++_generation;

    // カメラの無い端末（シミュレータ・一部の iPad など）では許可を求めない（先に一覧を見る。一覧だけなら許可は要らない）。
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (_) {
      return ArCameraStatus.unavailable;
    }
    if (cameras.isEmpty) return ArCameraStatus.unavailable;

    final permission = await Permission.camera.request();
    if (!permission.isGranted && !permission.isLimited) return ArCameraStatus.denied;
    final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);

    final controller = CameraController(back, ResolutionPreset.high, enableAudio: false);
    try {
      await controller.initialize();
    } on CameraException catch (e) {
      await controller.dispose();
      // iOS: CameraAccessDenied / CameraAccessDeniedWithoutPrompt / CameraAccessRestricted
      return e.code.startsWith('CameraAccess') ? ArCameraStatus.denied : ArCameraStatus.unavailable;
    } catch (_) {
      await controller.dispose();
      return ArCameraStatus.unavailable;
    }
    if (gen != _generation) {
      // 初期化中に stop された（画面を閉じた・裏に回った）。
      await controller.dispose();
      return ArCameraStatus.starting;
    }
    _controller = controller;
    return ArCameraStatus.ready;
  }

  @override
  Widget buildPreview() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.expand();
    final ps = c.value.previewSize;
    if (ps == null) return CameraPreview(c);
    // previewSize は横長（センサーの向き）。縦画面固定なので縦横を入れ替え、画面いっぱいに切り抜く。
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(width: ps.height, height: ps.width, child: CameraPreview(c)),
      ),
    );
  }

  @override
  Future<void> stop() async {
    _generation++;
    final c = _controller;
    _controller = null;
    if (c != null) await c.dispose();
  }
}

/// AR 画面ごとに新しいカメラを作る。テストではフェイクに差し替える。
final arCameraFactoryProvider = Provider<ArCamera Function()>((ref) => PluginArCamera.new);

/// 「設定を開く」。テストでは差し替える。
final arOpenSettingsProvider = Provider<Future<bool> Function()>((ref) => openAppSettings);
