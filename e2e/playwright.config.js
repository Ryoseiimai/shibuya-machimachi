// 意図的な簡略化: E2Eはローカルのwrangler dev(Miniflare)に対してのみ実行する。
// 実配備(wrp deploy)先のWorkerに対しては叩かない(決定論的・高速・第三者APIコストゼロにするため)。
// 本番同等の疎通確認は `curl` によるスモークテストで別途行う。
import { defineConfig } from "@playwright/test";

const PORT = 8788; // ローカル開発(npm run dev, 8787)と衝突しないポート
const BASE_URL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: "./tests",
  // 60秒(元は30秒): 3D渋谷がMapLibre GL JS本体をjsdelivr CDNから取得するステップを含むため、
  // 初回・低速回線での余裕を持たせる(以後の`toPass`個別timeoutは変更していない)。
  timeout: 60_000,
  fullyParallel: false,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL: BASE_URL,
    // 3D渋谷(MapLibre GL/WebGL)とAR(getUserMedia)をヘッドレスChromiumで動かすためのフラグ。
    // --use-gl=swiftshader: GPUのないCI/サンドボックス環境でもソフトウェアレンダリングでWebGLを有効にする。
    // --use-fake-ui-for-media-stream / --use-fake-device-for-media-stream: カメラ許可ダイアログを
    // 出さずに合成のダミー映像デバイスを使う(実カメラ映像は一切扱わない)。
    launchOptions: {
      args: [
        "--use-gl=swiftshader",
        "--use-fake-ui-for-media-stream",
        "--use-fake-device-for-media-stream",
      ],
    },
  },
  webServer: {
    command: `npx wrangler dev --port ${PORT} --local`,
    cwd: "../worker",
    url: BASE_URL + "/",
    reuseExistingServer: false,
    timeout: 60_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
