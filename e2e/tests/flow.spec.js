// 承認フローの通し確認: 作成 → 招待リンク → Bが承認して参加 → Aが承認 → 両画面に距離と矢印が出る。
// 2つの独立したブラウザコンテキスト(A/Bそれぞれ別デバイス相当)で、ダミーGPS(渋谷駅付近の2点)を使う。
import { test, expect } from "@playwright/test";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCREENSHOT_DIR = path.join(__dirname, "..", "..", "控え");
fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

// 渋谷駅ちょうどと、そこから約4.4m真北の2点(どちらも渋谷エリア内・20m以内)。
// 「真北」にしているのは、AのAR視点で相手(B)が視野角(60度)の正面に来るようにするため
// (AR部品は端末の向きセンサーの初期値heading=0=北向きを前提に人影を描画する。詳細はテスト内の
// AR検証コメント参照)。
const POINT_A = { latitude: 35.658, longitude: 139.7016 };
const POINT_B = { latitude: 35.65804, longitude: 139.7016 };

const MOBILE_VIEWPORT = { width: 390, height: 844 };

function shot(page, name) {
  return page.screenshot({ path: path.join(SCREENSHOT_DIR, name) });
}

test("host creates, guest joins via invite link, both approve, distance+arrow appear on both screens", async ({ browser }) => {
  const contextA = await browser.newContext({
    viewport: MOBILE_VIEWPORT,
    geolocation: POINT_A,
    // cameraはAR画面(pageAで検証)がgetUserMediaを呼ぶために必要。実際の映像はplaywright.config.jsの
    // --use-fake-device-for-media-stream による合成のダミー映像で、実カメラは使わない。
    permissions: ["geolocation", "camera"],
  });
  const contextB = await browser.newContext({
    viewport: MOBILE_VIEWPORT,
    geolocation: POINT_B,
    permissions: ["geolocation"],
  });
  const pageA = await contextA.newPage();
  const pageB = await contextB.newPage();

  // 01: ホスト(A)が作成画面でニックネームを入力
  await pageA.goto("/");
  await expect(pageA.locator("#screen-create")).toHaveClass(/visible/);
  await pageA.fill("#create-nickname", "ホストA");
  await shot(pageA, "01_create.png");
  await pageA.click("#create-btn");

  // 02: 招待リンク画面(まだ誰も参加していない)
  await expect(pageA.locator("#screen-waiting-guest")).toHaveClass(/visible/, { timeout: 10_000 });
  const inviteUrl = await pageA.inputValue("#invite-url-input");
  expect(inviteUrl).toContain("/r/");
  expect(inviteUrl).toContain("invite=");
  await shot(pageA, "02_invite.png");

  // 03: ゲスト(B)が招待リンクを開き、Aのニックネームを見てから自分のニックネームを入力
  await pageB.goto(inviteUrl);
  await expect(pageB.locator("#screen-preview")).toHaveClass(/visible/, { timeout: 10_000 });
  await expect(pageB.locator("#preview-host-name")).toHaveText("ホストA");
  await pageB.fill("#preview-nickname", "ゲストB");
  await shot(pageB, "03_guest_preview.png");

  // 04: 「承認して参加」した直後 = Bの同意は済んだが、まだAが承認していない段階。
  //     このスクショは「未承認の段階では相手の位置(距離・矢印)が一切出ない」ことの証拠。
  await pageB.click("#preview-join-btn");
  await expect(pageB.locator("#screen-waiting-approval-guest")).toHaveClass(/visible/, { timeout: 10_000 });
  await expect(pageB.locator("#waiting-host-name")).toHaveText("ホストA");
  await expect(pageB.locator("#screen-meet")).not.toHaveClass(/visible/);
  await expect(pageB.locator("#screen-meet")).toBeHidden();
  await shot(pageB, "04_guest_waiting_approval_no_location.png");

  // 05: ホスト側も、Bが参加した通知(承認ボタン)は見えるが、この時点でまだ距離は出ない。
  await expect(pageA.locator("#screen-approve")).toHaveClass(/visible/, { timeout: 10_000 });
  await expect(pageA.locator("#approve-guest-name")).toHaveText("ゲストB");
  await expect(pageA.locator("#screen-meet")).not.toHaveClass(/visible/);
  await shot(pageA, "05_host_approve_prompt_no_location.png");

  // Aが「この人と位置を共有する」を押す = 両者承認が揃い、はじめて位置の送受信が始まる。
  await pageA.click("#approve-btn");

  // 06 / 07: 両画面がactiveになり、距離と方角の矢印(回転角)が表示される。
  await expect(pageA.locator("#screen-meet")).toHaveClass(/visible/, { timeout: 10_000 });
  await expect(pageB.locator("#screen-meet")).toHaveClass(/visible/, { timeout: 10_000 });

  // クライアントはwatchPositionだけで位置を送る設計(AGENTS.md参照)。実機のGPSは静止中でも
  // 数秒おきに再報告されるが、Playwrightの固定ダミー座標は放っておくと再配信されないため、
  // テスト側でcontext.setGeolocation()を呼び直して「次のGPSティック」を明示的に発生させる。
  await contextA.setGeolocation(POINT_A);
  await contextB.setGeolocation(POINT_B);

  await expect(async () => {
    const text = await pageA.locator("#meet-distance").textContent();
    expect(text).not.toBe("--");
    expect(Number(text)).toBeLessThan(50);
  }).toPass({ timeout: 15_000 });

  await expect(async () => {
    const text = await pageB.locator("#meet-distance").textContent();
    expect(text).not.toBe("--");
    expect(Number(text)).toBeLessThan(50);
  }).toPass({ timeout: 15_000 });

  const arrowTransformA = await pageA.locator("#arrow").evaluate((el) => el.style.transform);
  const arrowTransformB = await pageB.locator("#arrow").evaluate((el) => el.style.transform);
  expect(arrowTransformA).toContain("rotate(");
  expect(arrowTransformB).toContain("rotate(");

  await shot(pageA, "06_active_host_distance_and_arrow.png");
  await shot(pageB, "07_active_guest_distance_and_arrow.png");

  // 08: 近くのお店 — 相手(B)の推定位置(サーバーのdistance_m/bearing_degから復元、生座標そのものではない)
  // から見て近い順3件が表示される。
  await expect(async () => {
    const count = await pageA.locator("#shops-list li").count();
    expect(count).toBe(3);
  }).toPass({ timeout: 20_000 });

  // 09: 3D渋谷 — 自分・相手それぞれのピン(MapLibreのDOM Marker要素)が1本ずつ、計2本立つ。
  await expect(async () => {
    const pinCount = await pageA.locator("#map3d .maplibregl-marker").count();
    expect(pinCount).toBe(2);
  }).toPass({ timeout: 20_000 });

  // #slot-shopsと#slot-3dは隣接するカードなので、前者の上端をビューポート上端ぎりぎりまで
  // スクロールすると、高さ844pxのビューポート内に両方(お店3件+3Dピン2本)が収まる。
  await pageA.evaluate(() => {
    const el = document.getElementById("slot-shops");
    window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 8);
  });
  await shot(pageA, "10_active_with_3d_shops.png");

  // 10: AR — 「ARで探す」ボタンで全画面ARビューを開くと、相手がいる方向に人影(シルエット)が出る。
  // POINT_BはPOINT_Aの真北にあり、ARの向きセンサーはヘッドレス環境では初期値heading=0(北向き)の
  // ままなので、相手の方位(≒0度)は視野角60度の正面に収まり、矢印ではなく人影が表示される側になる
  // (ar.js の render(): |normalizeAngleDiff(heading, bearing)| <= 30 で人影、それ以外は矢印)。
  await expect(pageA.locator("#ar-open-btn")).toBeEnabled({ timeout: 20_000 });
  await pageA.click("#ar-open-btn");
  await expect(pageA.locator("#ar-fullscreen")).toBeVisible();
  await expect(pageA.locator(".mm-ar-person")).toBeVisible({ timeout: 10_000 });
  await shot(pageA, "11_ar_view.png");
  await pageA.click("#ar-close-btn");
  await expect(pageA.locator("#ar-fullscreen")).toBeHidden();

  await contextA.close();
  await contextB.close();
});
