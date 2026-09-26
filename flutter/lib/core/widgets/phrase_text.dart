// 文節の途中で改行しない文字列。Flutter は日本語をどこでも折り返すので、
// 「、」「。」「)」「）」と、明示の区切り（/）の後ろで区切って Wrap に並べる。
import 'package:flutter/material.dart';

/// "位置情報は／この端末の中だけで使い、／サーバーには／送りません。" のように ／ で区切ってもよい。
List<String> splitPhrases(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  for (final ch in text.runes.map(String.fromCharCode)) {
    if (ch == '／') {
      if (buf.isNotEmpty) out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
    if (ch == '、' || ch == '。' || ch == ')' || ch == '）') {
      out.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

class PhraseText extends StatelessWidget {
  const PhraseText(this.text, {super.key, this.style, this.alignment = WrapAlignment.start});
  final String text;
  final TextStyle? style;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final phrases = splitPhrases(text);
    return Semantics(
      label: phrases.join(),
      excludeSemantics: true,
      child: Wrap(alignment: alignment, children: [for (final p in phrases) Text(p, style: style)]),
    );
  }
}
