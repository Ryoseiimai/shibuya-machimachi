// ディープリンク → アプリ内の場所（go_router の location）。
// 受け付ける形:
//   https://<本番host>/r/<id>?invite=<token>   → /r/<id>?invite=<token>
//   shibuyamachimachi-flutter://r/<id>?invite= → 同上
//   .../demo                                   → /new?demo=1
//   .../new・/                                  → /new
//   .../go                                     → /go
// それ以外は null（無視）。Flutter 標準のディープリンクは切って（Info.plist / AndroidManifest）、ここだけで扱う。
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'constants.dart';

String? deepLinkToLocation(Uri uri, {String prodHost = 'shibuya-machimachi.kaeru3160.workers.dev'}) {
  List<String> segs;
  if (uri.scheme == kAppScheme) {
    // shibuyamachimachi-flutter://r/<id> は host が "r"、path が "/<id>" になる。
    segs = [if (uri.host.isNotEmpty) uri.host, ...uri.pathSegments];
  } else if ((uri.scheme == 'https') && uri.host == prodHost) {
    segs = uri.pathSegments;
  } else {
    return null;
  }
  segs = segs.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return '/new';
  switch (segs.first) {
    case 'r':
      if (segs.length < 2) return null;
      final id = segs[1];
      if (id == 'demo') return '/new?demo=1';
      if (!kHex32.hasMatch(id)) return null;
      final invite = uri.queryParameters['invite'];
      if (invite != null && invite.isNotEmpty) {
        return Uri(path: '/r/$id', queryParameters: {'invite': invite}).toString();
      }
      return '/r/$id';
    case 'demo':
      return '/new?demo=1';
    case 'new':
      return '/new';
    case 'go':
      return '/go';
    default:
      return null;
  }
}

/// 同じリンクを二重に開かない間隔。起動時のリンクが2回届く（初回リンクと stream の両方）のを吸収するだけで、
/// それより後にもう一度タップされた同じリンク（ホームに戻ってから同じ招待・デモを開き直す等）は開く。
const Duration kDeepLinkDedupWindow = Duration(seconds: 2);

/// リンクの流れを聞いてルーターへ流す。同じ URL が短い間に続けて届いたときだけ無視する
/// （Capacitor 版の sm:lastOpenedUrl と同じ役目）。
class DeepLinkListener {
  DeepLinkListener({required this.links, required this.go, int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// app_links の uriLinkStream（テストでは差し替え）。
  final Stream<Uri> links;

  /// router.go。
  final void Function(String location) go;
  final int Function() _nowMs;
  StreamSubscription<Uri>? _sub;
  String? _last;
  int _lastAtMs = 0;

  void start() {
    _sub = links.listen(_onUri, onError: (Object _) {});
  }

  void _onUri(Uri uri) {
    final loc = deepLinkToLocation(uri);
    if (loc == null) return;
    final now = _nowMs();
    if (loc == _last && now - _lastAtMs < kDeepLinkDedupWindow.inMilliseconds) return;
    _last = loc;
    _lastAtMs = now;
    go(loc);
  }

  void dispose() => _sub?.cancel();
}

/// ウィジェットの寿命に合わせて DeepLinkListener を動かす。
class DeepLinkScope extends StatefulWidget {
  const DeepLinkScope({super.key, required this.router, required this.child});
  final GoRouter router;
  final Widget child;

  @override
  State<DeepLinkScope> createState() => _DeepLinkScopeState();
}

class _DeepLinkScopeState extends State<DeepLinkScope> {
  late final DeepLinkListener _l = DeepLinkListener(links: AppLinks().uriLinkStream, go: widget.router.go)..start();

  @override
  void dispose() {
    _l.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
