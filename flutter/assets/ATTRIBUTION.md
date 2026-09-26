# 同梱データの出典

このフォルダのデータは、リポジトリの `worker/public/` にある同じファイルの写しです（2026-09-27、origin/main 426e411 時点）。
更新するときは元ファイルから写し直し、`lib/core/constants.dart` の版の印（`kRouteGraphVersion` / `kPlacesVersion`）と合わせてください（`test/core/assets_test.dart` が検査します）。

| ファイル | 元 | 出典・ライセンス |
|---|---|---|
| `data/buildings_shibuya_1500m.geojson` | `worker/public/assets/data/` | 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC BY 4.0） https://www.mlit.go.jp/plateau/ |
| `data/pois_shibuya_1500m.geojson` | `worker/public/assets/data/` | © OpenStreetMap contributors (ODbL) https://www.openstreetmap.org/copyright |
| `route/graph.json` | `worker/public/route/` | © OpenStreetMap contributors (ODbL)。OSM から `scripts/build_route_graph.mjs` で作った派生データベース |
| `route/places.json` | `worker/public/route/` | © OpenStreetMap contributors (ODbL) |

地図タイル（実行時に取得）: 地理院タイル（国土地理院） https://maps.gsi.go.jp/development/ichiran.html

アプリ内の表記（`lib/core/widgets/attribution.dart`）:
「建物: 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC BY 4.0）／地図: 地理院タイル／店舗・道順: © OpenStreetMap contributors (ODbL)」
