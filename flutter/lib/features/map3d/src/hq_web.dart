// 高画質3D の WebView まわり（同梱物の配り方・行き先の制限・JS からの知らせの読み取り）。
// 同梱物は assets/hq/ に平置き。iOS はカスタムスキーム machimachi-hq://app/…、Android は
// WebViewAssetLoader の https://appassets.androidplatform.net/assets/flutter_assets/assets/hq/… で配る
// （file:// は使わない。どちらも同一オリジンになるので ES モジュール・fetch・Worker が動く）。
// localhost サーバーは使わない（ポートの取り合いを避ける）。
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

const String kHqScheme = 'machimachi-hq';
const String kHqHost = 'app';
const String kHqAssetDir = 'assets/hq';
const String kAndroidAssetDomain = 'appassets.androidplatform.net';
const String kAndroidAssetPrefix = '/assets/flutter_assets/$kHqAssetDir/';

/// PLATEAU の配信元。WebView から外へ出てよいのはここへの GET だけ（index.html の CSP でも絞っている）。
const String kPlateauHost = 'assets.cms.plateau.reearth.io';

/// JS → Dart の知らせの窓口の名前（hq-bridge.js と同じ）。
const String kHqHandlerName = 'machimachiHq';

/// 配ってよい同梱物（名前 → Content-Type）。ここに無いものは返さない。
const Map<String, String> kHqAssetFiles = {
  'index.html': 'text/html',
  'hq-bridge.js': 'text/javascript',
  'shibuya3d-hq.js': 'text/javascript',
  'three.module.js': 'text/javascript',
  'GLTFLoader.js': 'text/javascript',
  'DRACOLoader.js': 'text/javascript',
  'BufferGeometryUtils.js': 'text/javascript',
  'draco_wasm_wrapper.js': 'text/javascript',
  'draco_decoder.wasm': 'application/wasm',
  'index.three.js': 'text/javascript',
  'renderer-CUfHAmYW.js': 'text/javascript',
  'renderer-_7gAivIK.js': 'text/javascript',
  'GLTFCesiumRTCExtension.js': 'text/javascript',
};

bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

/// 最初に開く URL。
Uri hqEntryUri({TargetPlatform? platform}) => (platform ?? defaultTargetPlatform) == TargetPlatform.android
    ? Uri.parse('https://$kAndroidAssetDomain${kAndroidAssetPrefix}index.html')
    : Uri.parse('$kHqScheme://$kHqHost/index.html');

/// カスタムスキームの URL → 同梱物のファイル名（配れないものは null）。
String? hqAssetNameFor(Uri url) {
  if (url.scheme != kHqScheme || url.host != kHqHost) return null;
  final segs = url.pathSegments;
  if (segs.length != 1) return null;
  final name = segs.single;
  return kHqAssetFiles.containsKey(name) ? name : null;
}

/// 画面の移動（ナビゲーション）として許すのは、自分の index.html だけ。外のページへは行かせない。
bool isAllowedHqNavigation(Uri? url, {TargetPlatform? platform}) {
  if (url == null) return false;
  if (url.scheme == 'about' && url.path == 'blank') return true;
  final entry = hqEntryUri(platform: platform);
  return url.scheme == entry.scheme && url.host == entry.host && url.path == entry.path;
}

/// JS からの知らせ（座標・名前は来ない）。
sealed class HqMessage {
  const HqMessage();

  /// callHandler の引数から読む。知らない形は null（無視する）。
  static HqMessage? parse(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'ready':
        return const HqReady();
      case 'loaded':
        return const HqLoaded();
      case 'progress':
        final pct = raw['pct'];
        if (pct is! num || !pct.isFinite) return null;
        return HqProgress(pct.round().clamp(0, 100));
      case 'error':
        final code = raw['code'];
        return HqError(code is String ? code : 'unknown');
    }
    return null;
  }
}

class HqReady extends HqMessage {
  const HqReady();
}

class HqLoaded extends HqMessage {
  const HqLoaded();
}

class HqProgress extends HqMessage {
  const HqProgress(this.pct);
  final int pct;
}

class HqError extends HqMessage {
  const HqError(this.code);
  final String code;
}

/// エラーの種類 → 画面の文言（PhraseText で出すので ／ は文節の切れ目。画面には出ない）。
String hqErrorText(String code) => switch (code) {
      'tileset' => '高画質モデルを／読み込めませんでした。通信を確かめて、開き直してください。',
      'context_lost' || 'crashed' => 'メモリが足りないため、高画質表示を／続けられませんでした。閉じてから、もう一度／お試しください。',
      'mount' => 'この端末では、高画質表示を／使えません。',
      _ => '高画質表示で／エラーが起きました。閉じてから、もう一度／お試しください。',
    };

/// Dart → JS の呼び出し口。
abstract interface class HqWebHost {
  /// window.machimachiHQ の関数を呼ぶ（引数は JSON で渡すので、名前に記号があっても壊れない）。
  Future<void> call(String method, Map<String, Object?> args);
}

typedef HqWebViewBuilder = Widget Function({
  required ValueChanged<HqWebHost> onCreated,
  required ValueChanged<HqMessage> onMessage,
  required ValueChanged<String> onFailed,
});

/// テスト用の差し替え口（null なら本物の InAppWebView）。
@visibleForTesting
HqWebViewBuilder? debugHqWebViewBuilder;

HqWebViewBuilder get hqWebViewBuilder => debugHqWebViewBuilder ?? buildHqInAppWebView;

/// 呼べる関数（hq-bridge.js の window.machimachiHQ）と、渡す引数の名前。
const Map<String, List<String>> kHqJsMethods = {
  'setMe': ['lat', 'lng', 'floor'],
  'setPartner': ['lat', 'lng', 'floor', 'name'],
  'destroy': [],
};

/// callAsyncJavaScript に渡す関数本体（引数は arguments で別に渡す）。
String hqJsFunctionBody(String method) {
  final params = kHqJsMethods[method];
  if (params == null) throw ArgumentError.value(method, 'method');
  return 'const h = window.machimachiHQ; if (h) h.$method(${params.join(', ')});';
}

class _InAppHost implements HqWebHost {
  _InAppHost(this._c);
  final InAppWebViewController _c;

  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    await _c.callAsyncJavaScript(functionBody: hqJsFunctionBody(method), arguments: args);
  }
}

Widget buildHqInAppWebView({
  required ValueChanged<HqWebHost> onCreated,
  required ValueChanged<HqMessage> onMessage,
  required ValueChanged<String> onFailed,
}) {
  return InAppWebView(
    initialUrlRequest: URLRequest(url: WebUri.uri(hqEntryUri())),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      resourceCustomSchemes: _isAndroid ? const [] : const [kHqScheme],
      webViewAssetLoader: _isAndroid
          ? WebViewAssetLoader(domain: kAndroidAssetDomain, pathHandlers: [AssetsPathHandler(path: '/assets/')])
          : null,
      useShouldOverrideUrlLoading: true,
      supportZoom: false,
      builtInZoomControls: false,
      disableContextMenu: true,
      disableLongPressContextMenuOnLinks: true,
      allowsLinkPreview: false,
      allowsBackForwardNavigationGestures: false,
      supportMultipleWindows: false,
      javaScriptCanOpenWindowsAutomatically: false,
      allowFileAccess: false,
      allowContentAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      thirdPartyCookiesEnabled: false,
      geolocationEnabled: false,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      disableVerticalScroll: true,
      disableHorizontalScroll: true,
      transparentBackground: false,
      underPageBackgroundColor: const Color(0xFF0B1114),
      isInspectable: kDebugMode,
    ),
    // 地図の操作は全部 WebView に渡す（全画面なので取り合う相手はいない）。
    gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
      Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
    },
    onWebViewCreated: (c) {
      c.addJavaScriptHandler(
        handlerName: kHqHandlerName,
        callback: (args) {
          final m = HqMessage.parse(args.isEmpty ? null : args.first);
          if (m != null) onMessage(m);
          return null;
        },
      );
      onCreated(_InAppHost(c));
    },
    onLoadResourceWithCustomScheme: (c, request) async {
      final name = hqAssetNameFor(request.url);
      if (name == null) return null;
      final data = await rootBundle.load('$kHqAssetDir/$name');
      return CustomSchemeResponse(
        data: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        contentType: kHqAssetFiles[name]!,
        contentEncoding: 'utf-8',
      );
    },
    shouldOverrideUrlLoading: (c, action) async =>
        isAllowedHqNavigation(action.request.url) ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL,
    onCreateWindow: (c, action) async => false,
    // WebView の中身がメモリ超過などで落ちたとき（iOS / Android）。WebView は画面側で外す。
    onWebContentProcessDidTerminate: (c) => onFailed('crashed'),
    onRenderProcessGone: (c, detail) => onFailed('crashed'),
    onReceivedError: (c, request, error) {
      if (request.isForMainFrame ?? false) onFailed('mount');
    },
    // コンソールの中身は読まない・出さない（URL 等がログに残らないように）。
  );
}
