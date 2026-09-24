// 意図的な簡略化: E2Eはローカルのwrangler dev(Miniflare)に対してのみ実行する。
// 実配備(wrp deploy)先のWorkerに対しては叩かない(決定論的・高速・第三者APIコストゼロにするため)。
// 本番同等の疎通確認は `curl` によるスモークテストで別途行う。
import { defineConfig } from "@playwright/test";

const PORT = 8788; // ローカル開発(npm run dev, 8787)と衝突しないポート
const BASE_URL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: "./tests",
  timeout: 30_000,
  fullyParallel: false,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL: BASE_URL,
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
