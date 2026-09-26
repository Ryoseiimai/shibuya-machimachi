// 【ar_home 担当】ホーム（`/`・アプリの入口と「このアプリについて」）と AR（`/ar`・カメラ越しに相手の方向）。
// 公開インターフェース（クラス名・コンストラクタ）は固定。仕様は flutter/SPEC.md §6.4、正本は ar.js / lp.js。
//
// 他の機能から使ってよいもの（この1ファイルだけを import する）:
//   - HomeScreen() / ArScreen()
//   - arGuideProvider・ArGuide: AR に「道順の次の曲がり角」を指させる（置かなければ相手を指す）
//     例) ref.read(arGuideProvider.notifier).set(ArGuide(route: coords, destinationName: 'ハチ公像', destinationLevel: 0));
//         道順を消した・部屋を出たら ref.read(arGuideProvider.notifier).clear();
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core.dart';
import 'ar_camera.dart';
import 'ar_guide.dart';
import 'ar_view.dart';
import 'home_view.dart';

export 'ar_guide.dart' show ArGuide, ArGuideNotifier, arGuideProvider;

/// `/`: アプリの入口。LP の要点（できること・安心の設計・出典）と、作る/場所へ行く/デモの入口。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const HomeView();
}

/// `/ar`: AR（全画面・黒地）。相手の推定位置（partnerEstimateProvider）・自分の位置・向き（headingProvider）・
/// 傾き（tiltProvider）・相手の名前と階（roomControllerProvider）をプロバイダから読む。
/// active でなくなったら自分で閉じる。カメラ映像は画面に出すだけ（送信・保存・画像ストリーム・録音なし）。
class ArScreen extends ConsumerStatefulWidget {
  const ArScreen({super.key});

  @override
  ConsumerState<ArScreen> createState() => _ArScreenState();
}

class _ArScreenState extends ConsumerState<ArScreen> with WidgetsBindingObserver {
  late final ArCamera _camera = ref.read(arCameraFactoryProvider)();
  ArCameraStatus _cameraStatus = ArCameraStatus.starting;
  bool _startInFlight = false;
  bool _headingTimedOut = false;
  Timer? _headingTimer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 許可の確認はこの画面を開いたタップ（meet の「ARで探す」）の直後に行う。
    unawaited(_startCamera());
    _headingTimer = Timer(kArHeadingWaitTimeout, () {
      if (mounted) setState(() => _headingTimedOut = true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _headingTimer?.cancel();
    unawaited(_camera.stop());
    super.dispose();
  }

  Future<void> _startCamera() async {
    if (_startInFlight) return;
    _startInFlight = true;
    final ArCameraStatus s;
    try {
      s = await _camera.start();
    } finally {
      _startInFlight = false;
    }
    if (!mounted) {
      unawaited(_camera.stop());
      return;
    }
    // starting が返るのは初期化中に止められたとき（次の resumed で開き直す）。
    if (s != ArCameraStatus.starting) setState(() => _cameraStatus = s);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive || AppLifecycleState.hidden || AppLifecycleState.paused:
        // 許可ダイアログでも inactive になるので、開いている途中は止めない。
        if (!_startInFlight && _cameraStatus == ArCameraStatus.ready) {
          unawaited(_camera.stop());
          setState(() => _cameraStatus = ArCameraStatus.starting);
        }
      case AppLifecycleState.resumed:
        // 設定で許可してから戻ってきた場合もここで開き直す。
        if (_cameraStatus == ArCameraStatus.starting || _cameraStatus == ArCameraStatus.denied) {
          unawaited(_startCamera());
        }
      case AppLifecycleState.detached:
        break;
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      GoRouter.maybeOf(context)?.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 待ち合わせが止まった・期限が切れたら（active でなくなったら）自分で閉じる。
    ref.listen(roomControllerProvider.select((v) => v.isActive), (prev, next) {
      if (prev == true && !next) _close();
    });

    final Widget cameraLayer = switch (_cameraStatus) {
      ArCameraStatus.ready => _camera.buildPreview(),
      ArCameraStatus.starting => const ColoredBox(color: Colors.black),
      ArCameraStatus.denied || ArCameraStatus.unavailable => const ColoredBox(
        key: ValueKey('ar-no-camera'),
        color: kArNoCameraBg,
        // 人影（画面の高さ×0.56 付近）と重ならないよう上寄せ。
        child: Align(
          alignment: Alignment(0, -0.6),
          child: Text('カメラ映像はありません', style: TextStyle(color: Color(0xFFDDDDDD), fontSize: 12)),
        ),
      ),
    };

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: ExcludeSemantics(child: cameraLayer)),
          Positioned.fill(
            child: SafeArea(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ArOverlayLayer(cameraStatus: _cameraStatus, headingTimedOut: _headingTimedOut),
                  ),
                  const Positioned(left: 12, top: 12, right: 64, child: _ArTopCaption()),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton.filled(
                        key: const ValueKey('ar-close'),
                        tooltip: '閉じる',
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0x99000000),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _close,
                        icon: const Icon(Icons.close, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 左上: 何を指しているか＋「映像は送信も保存もしません」。
class _ArTopCaption extends ConsumerWidget {
  const _ArTopCaption();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guide = ref.watch(arGuideProvider);
    final nick = ref.watch(roomControllerProvider.select((v) => v.server?.other?.nickname));
    final what = guide != null
        ? '道順: ${guide.destinationName}まで'
        : '相手: ${(nick == null || nick.isEmpty) ? '相手' : nick}';
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              what,
              key: const ValueKey('ar-caption'),
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const PhraseText('カメラ映像は／送信も保存も／しません', style: TextStyle(color: Color(0xFFE0E0E0), fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
