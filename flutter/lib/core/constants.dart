// 定数の集約。worker/src/constants.js・route.js・app.js と同じ値を持つ。
// サーバー側の値を変えたら、ここも合わせる（test/core/constants_test.dart は値の固定だけを見る）。

/// 本番 Worker のオリジン。招待リンクもこのドメインで組み立てる（アプリを入れていない相手も開けるように）。
const String kProdBaseUrl = 'https://shibuya-machimachi.kaeru3160.workers.dev';

/// Flutter 版のカスタムスキーム。Capacitor 版（審査中）の `shibuyamachimachi://` と
/// 同じ端末で取り合わないよう、別の名前にしている（Flutter 版に置き換えるときに戻す）。
const String kAppScheme = 'shibuyamachimachi-flutter';

/// 渋谷駅（サーバーの SHIBUYA_STATION）。送信可否・エリア判定は必ずこれを使う。
const double kShibuyaStationLat = 35.658;
const double kShibuyaStationLng = 139.7016;

/// 渋谷エリアの半径(m)。これより外では位置を送らない。
const double kShibuyaRadiusM = 1500;

/// 3D表示の中心（ハチ公口付近）。地図の初期中心にだけ使う。送信判定には使わない。
const double kMapCenterLat = 35.659;
const double kMapCenterLng = 139.7005;

const int kMeetDistanceM = 20;
const int kLocationStaleMs = 120000;
const int kRoomTtlMs = 3 * 60 * 60 * 1000;
const int kMaxJudgeCalls = 10;
const int kBothPressedJudgeWindowMs = 60000;

/// WebSocket の1メッセージ上限（バイト）。超えるとサーバーは黙って捨てる。
const int kWsMaxMessageBytes = 2048;

/// サーバーは location を role ごとに 1000ms に1回まで受ける。遅延の揺れで捨てられないよう余白を取る。
const int kLocationMinIntervalMs = 1200;

/// 止まっていても位置が「古い(2分)」扱いにならないよう、最後の位置を送り直す間隔。
const int kLocationHeartbeatMs = 20000;

/// これより古い測位は送らない（送り直しも含む）。GPS が止まった（地下・許可の取り消し等）のに、
/// 最後の位置を新しい位置として送り続けないため。相手には最長で約 1 分＋2 分で「位置が古い」と出る。
const int kLocationResendMaxAgeMs = 60000;

/// 階の選択肢（B5→10F の順）。サーバーの FLOORS と同じ。
const List<String> kFloors = [
  'B5', 'B4', 'B3', 'B2', 'B1', //
  '1F', '2F', '3F', '4F', '5F', '6F', '7F', '8F', '9F', '10F',
];

/// ユーザーが階を変えてから、サーバーの古い階で上書きしない猶予。
const int kFloorOverrideMs = 5000;

/// 道のデータ・スポット一覧の版の印（route.js と同じ）。
const String kRouteGraphVersion = '52c88875bd';
const String kPlacesVersion = '2026-09-26a';

/// 同梱アセットのパス。
const String kAssetGraph = 'assets/route/graph.json';
const String kAssetPlaces = 'assets/route/places.json';
const String kAssetBuildings = 'assets/data/buildings_shibuya_1500m.geojson';
const String kAssetPois = 'assets/data/pois_shibuya_1500m.geojson';

/// roomId・secret などの形（32桁の16進・小文字）。
final RegExp kHex32 = RegExp(r'^[a-f0-9]{32}$');

/// 待ち合わせ場所のID（サーバーの SPOT_ID_PATTERN と同じ）。
final RegExp kSpotIdPattern = RegExp(r'^[a-z0-9-]{1,40}$');

/// ニックネームの最大長（UTF-16 単位。JS の .length と同じ数え方）。
const int kNicknameMaxLength = 20;
