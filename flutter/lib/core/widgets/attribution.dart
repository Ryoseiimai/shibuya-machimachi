// 出典の表記（必須）。3D・お店・道順を出す画面の下に置く。
import 'package:flutter/material.dart';

import '../theme.dart';

abstract final class Attributions {
  static const all = '建物: 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC BY 4.0）／地図: 地理院タイル／店舗・道順: © OpenStreetMap contributors (ODbL)';
  static const places = '場所・道順: © OpenStreetMap contributors (ODbL)';
  static const placeRoute = '場所・道順: © OpenStreetMap contributors (ODbL)／建物: 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC BY 4.0）／地図: 地理院タイル';
  static const hq = '建物: 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC BY 4.0）';
}

class AttributionText extends StatelessWidget {
  const AttributionText(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Text(text, style: AppText.attribution.copyWith(color: color)),
      );
}
