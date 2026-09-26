// 道順案内(歩行ルート)のE2E: 場所モード(1人で定番スポットへ)・階の移動(地下→地上)・人モード(待ち合わせ相手へ)。
// ダミーGPS(渋谷駅付近の実在の地点)で、画面に矢印・次の案内文・残りの道のりが出ることを確かめ、証跡を撮る。
// 撮影先は既定で リポジトリ直下の 控え/route/(git管理外)。ROUTE_SHOT_DIR で変えられる。
import { test, expect } from "@playwright/test";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SHOT_DIR = process.env.ROUTE_SHOT_DIR || path.join(__dirname, "..", "..", "控え", "route");
fs.mkdirSync(SHOT_DIR, { recursive: true });

const MOBILE_VIEWPORT = { width: 390, height: 844 };
const HACHIKO = { latitude: 35.6590597, longitude: 139.7006279 }; // 忠犬ハチ公像(OSM)
const MOYAI = { latitude: 35.6572922, longitude: 139.6999685 }; // モヤイ像(OSM)
const ON_THE_WAY = { latitude: 35.65865, longitude: 139.70045 }; // ハチ公像とモヤイ像の間(駅西側)
const B3_POINT = { latitude: 35.658588, longitude: 139.702834 }; // 渋谷駅東側・地下3階の通路(OSM level=-3)

const ROUTE_TIMEOUT = 30_000;

function shot(page, name) {
  return page.screenshot({ path: path.join(SHOT_DIR, name) });
}

async function waitForGuidance(page, mount) {
  await expect(page.locator(`${mount} .route-remaining`)).toContainText("残り", { timeout: ROUTE_TIMEOUT });
}

test("場所モード: ハチ公像からモヤイ像へ、歩ける道に沿った矢印・案内文・残りの道のり・到着が出る", async ({ browser }) => {
  const context = await browser.newContext({ viewport: MOBILE_VIEWPORT, geolocation: HACHIKO, permissions: ["geolocation"] });
  const page = await context.newPage();

  // 作成画面(/new)の「場所へ行く」から場所モード(/go)へ
  await page.goto("/new");
  await page.click("#go-place-btn");
  await expect(page).toHaveURL(/\/go$/);
  await expect(page.locator("#screen-place-select")).toHaveClass(/visible/);
  await expect(page.locator("#place-list .place-item")).toHaveCount(13, { timeout: ROUTE_TIMEOUT });
  await context.setGeolocation(HACHIKO);
  await expect(page.locator('[data-place-id="moyai"] .place-dist')).toContainText("直線", { timeout: ROUTE_TIMEOUT });
  await shot(page, "01_place_select.png");

  await page.click('[data-place-id="moyai"]');
  await expect(page.locator("#screen-place-route")).toHaveClass(/visible/);
  await waitForGuidance(page, "#place-route-mount");
  await expect(page.locator("#place-route-mount .route-dest-name")).toHaveText("モヤイ像");
  await expect(page.locator("#place-route-mount .route-instruction")).toHaveText(/m先|へ/);
  const transform = await page.locator("#place-route-mount .route-arrow").evaluate((el) => el.style.transform);
  expect(transform).toMatch(/rotate\(/);
  await expect(page.locator('#place-route-mount .floor-chip[data-floor="1F"]')).toHaveClass(/is-active/);
  await page.waitForTimeout(2500); // 3D渋谷(道順の線)の描画を待つ
  await shot(page, "02_route_arrow.png");

  // 歩いて近づくと残りの道のりが減り、モヤイ像に着くと到着表示になる
  const before = await page.locator("#place-route-mount .route-remaining").textContent();
  await context.setGeolocation(ON_THE_WAY);
  await expect(page.locator("#place-route-mount .route-remaining")).not.toHaveText(before, { timeout: ROUTE_TIMEOUT });
  await context.setGeolocation(MOYAI);
  await expect(page.locator("#place-route-mount .route-instruction")).toHaveText("到着しました！", { timeout: ROUTE_TIMEOUT });

  await context.close();
});

test("場所モード: 渋谷駅の地下3階からハチ公像へ、階の移動(エスカレーター等で◯階へ)を案内し、1タップで階を直せる", async ({ browser }) => {
  const context = await browser.newContext({ viewport: MOBILE_VIEWPORT, geolocation: B3_POINT, permissions: ["geolocation"] });
  const page = await context.newPage();
  await page.goto("/go");
  await expect(page.locator("#place-list .place-item")).toHaveCount(13, { timeout: ROUTE_TIMEOUT });
  await context.setGeolocation(B3_POINT);
  await page.click('[data-place-id="hachiko"]');
  await waitForGuidance(page, "#place-route-mount");

  // 地下ではGPSが弱い前提: 今いる階をボタン1タップで地下3階に直す
  await page.click('#place-route-mount .floor-chip[data-floor="B3"]');
  await expect(page.locator('#place-route-mount .floor-chip[data-floor="B3"]')).toHaveClass(/is-active/);
  await expect(page.locator("#place-route-mount .route-instruction")).toHaveText(/(エスカレーター|階段|エレベーター)で(地下\d+|\d+)階へ/, { timeout: ROUTE_TIMEOUT });
  await expect(page.locator("#place-route-mount .route-card")).toHaveClass(/is-floor-change/);
  const confirm = page.locator("#place-route-mount .route-floor-confirm");
  await expect(confirm).toBeVisible();
  await expect(confirm).toHaveText(/階に着いた$/);
  await shot(page, "03_floor_change.png");

  // 「◯階に着いた」を押すと、その階が選ばれて次の案内に進む
  const firstInstruction = await page.locator("#place-route-mount .route-instruction").textContent();
  await confirm.click();
  await expect(page.locator('#place-route-mount .floor-chip[data-floor="B3"]')).not.toHaveClass(/is-active/);
  await expect(page.locator("#place-route-mount .route-instruction")).not.toHaveText(firstInstruction, { timeout: ROUTE_TIMEOUT });

  await context.close();
});

test("人モード: 待ち合わせ画面の「道順で案内」で、相手の近似位置まで歩ける道の案内が出る", async ({ browser }) => {
  const contextA = await browser.newContext({ viewport: MOBILE_VIEWPORT, geolocation: HACHIKO, permissions: ["geolocation"] });
  const contextB = await browser.newContext({ viewport: MOBILE_VIEWPORT, geolocation: MOYAI, permissions: ["geolocation"] });
  const pageA = await contextA.newPage();
  const pageB = await contextB.newPage();

  await pageA.goto("/new");
  await pageA.fill("#create-nickname", "ホストA");
  await pageA.click("#create-btn");
  await expect(pageA.locator("#screen-waiting-guest")).toHaveClass(/visible/, { timeout: 10_000 });
  const inviteUrl = await pageA.inputValue("#invite-url-input");
  await pageB.goto(inviteUrl);
  await expect(pageB.locator("#screen-preview")).toHaveClass(/visible/, { timeout: 10_000 });
  await pageB.fill("#preview-nickname", "ゲストB");
  await pageB.click("#preview-join-btn");
  await expect(pageA.locator("#screen-approve")).toHaveClass(/visible/, { timeout: 10_000 });
  await pageA.click("#approve-btn");
  await expect(pageA.locator("#screen-meet")).toHaveClass(/visible/, { timeout: 10_000 });
  await expect(pageB.locator("#screen-meet")).toHaveClass(/visible/, { timeout: 10_000 });
  await contextA.setGeolocation(HACHIKO);
  await contextB.setGeolocation(MOYAI);
  await expect(async () => {
    const text = await pageA.locator("#meet-distance").textContent();
    expect(Number(text)).toBeGreaterThan(100);
  }).toPass({ timeout: 15_000 });

  await pageA.click("#route-toggle-btn");
  await expect(pageA.locator("#route-toggle-btn")).toHaveText("まっすぐの矢印に戻す");
  await expect(pageA.locator("#arrow-wrap")).toBeHidden();
  await contextA.setGeolocation(HACHIKO);
  await waitForGuidance(pageA, "#meet-route-mount");
  await expect(pageA.locator("#meet-route-mount .route-dest-name")).toHaveText("ゲストB");
  await expect(pageA.locator("#meet-route-mount .route-instruction")).toHaveText(/m先|へ/);
  await pageA.evaluate(() => {
    const el = document.getElementById("distance-card");
    window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 8);
  });
  await pageA.waitForTimeout(1500);
  await shot(pageA, "04_person_route.png");

  // もう一度押すと、まっすぐの矢印に戻る
  await pageA.click("#route-toggle-btn");
  await expect(pageA.locator("#arrow-wrap")).toBeVisible();
  await expect(pageA.locator("#meet-route-mount")).toBeHidden();

  // 待ち合わせ場所: Aがスポットを決めると(サーバーに送るのはIDだけ)、Bにも届き、Bはそこへの道順を出せる
  await expect(pageA.locator('#meet-spot-select option[value="hachiko"]')).toHaveCount(1, { timeout: ROUTE_TIMEOUT });
  await pageA.selectOption("#meet-spot-select", "hachiko");
  await pageA.click("#meet-spot-set-btn");
  await expect(pageA.locator("#meet-spot-current")).toHaveText("待ち合わせ場所：ハチ公像(あなたが決めました)", { timeout: 10_000 });
  await expect(pageB.locator("#meet-spot-current")).toHaveText("待ち合わせ場所：ハチ公像(相手が決めました)", { timeout: 10_000 });
  await pageB.click("#meet-spot-go-btn");
  await contextB.setGeolocation(MOYAI);
  await waitForGuidance(pageB, "#meet-route-mount");
  await expect(pageB.locator("#meet-route-mount .route-dest-name")).toHaveText("ハチ公像");
  await pageB.evaluate(() => {
    const el = document.getElementById("meet-route-mount");
    window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 8);
  });
  await shot(pageB, "05_meet_spot_route.png");

  await contextA.close();
  await contextB.close();
});
