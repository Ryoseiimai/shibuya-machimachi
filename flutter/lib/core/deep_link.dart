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

/// app_links を聞いてルーターへ流す。同じ URL を二重に開かない（Capacitor 版の sm:lastOpenedUrl と同じ役目）。
class DeepLinkListener {
  DeepLinkListener(this.router, {AppLinks? appLinks}) : _links = appLinks ?? AppLinks();
  final GoRouter router;
  final AppLinks _links;
  StreamSubscription<Uri>? _sub;
  String? _last;

  void start() {
    _sub = _links.uriLinkStream.listen((uri) {
      final loc = deepLinkToLocation(uri);
      if (loc == null || loc == _last) return;
      _last = loc;
      router.go(loc);
    }, onError: (Object _) {});
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
  late final DeepLinkListener _l = DeepLinkListener(widget.router)..start();

  @override
  void dispose() {
    _l.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
