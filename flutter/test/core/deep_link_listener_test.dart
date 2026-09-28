// DeepLinkListener: 同じリンクは短い間（起動時の二重配達）だけ無視し、あとでもう一度タップされたら開く。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/deep_link.dart';

void main() {
  late StreamController<Uri> links;
  late List<String> went;
  var now = 0;
  late DeepLinkListener l;

  setUp(() {
    links = StreamController<Uri>();
    went = [];
    now = 0;
    l = DeepLinkListener(links: links.stream, go: went.add, nowMs: () => now)..start();
  });
  tearDown(() {
    l.dispose();
    links.close();
  });

  final invite = Uri.parse('https://shibuya-machimachi.kaeru3160.workers.dev/r/${'a' * 32}?invite=${'c' * 32}');

  test('2秒以内の同じリンクは1回だけ開く', () async {
    links.add(invite);
    now += 500;
    links.add(invite);
    await Future<void>.delayed(Duration.zero);
    expect(went, ['/r/${'a' * 32}?invite=${'c' * 32}']);
  });

  test('ホームに戻ってから同じリンクをもう一度タップしたら開く', () async {
    links.add(Uri.parse('shibuyamachimachi-flutter://demo'));
    await Future<void>.delayed(Duration.zero);
    now += 30000;
    links.add(Uri.parse('shibuyamachimachi-flutter://demo'));
    await Future<void>.delayed(Duration.zero);
    expect(went, ['/new?demo=1', '/new?demo=1']);
  });

  test('違うリンクはすぐ開き、知らないリンクは無視する', () async {
    links.add(invite);
    links.add(Uri.parse('shibuyamachimachi-flutter://go'));
    links.add(Uri.parse('https://example.com/r/x'));
    await Future<void>.delayed(Duration.zero);
    expect(went, ['/r/${'a' * 32}?invite=${'c' * 32}', '/go']);
  });
}
