# Contributing / 貢献のしかた

## 日本語

まず [README](README.md) の「3分で動かす」を試してください。Googleアカウントも
Cloudflareアカウントも不要です。

### 開発モードの起動

```bash
git clone https://github.com/Ryoseiimai/shibuya-machimachi.git
cd shibuya-machimachi
npm run dev   # または make dev
```

- `wrangler dev` をローカルのみ(`--local`, Miniflare)で起動します。実際のCloudflareアカウントには繋ぎません。
- 同じURLをブラウザのタブ2つで開けば、1台のPCでA(ホスト)とB(ゲスト)の両方を再現できます。
- 止めるときは `Ctrl+C`。

GitHub Codespaces を使う場合は、README上部の「Open in GitHub Codespaces」バッジからブラウザだけで開発環境を起動できます(ローカルに何もインストール不要)。

### ブランチとPRの流れ

1. リポジトリをFork(または直接ブランチを作れる場合はブランチを作成)。
2. `git checkout -b feature/your-change` のように分かりやすい名前でブランチを切る。
3. 変更する。`cd worker && npm test`(状態機械・距離方角・フロア・Jev判定のユニットテスト)を実行してから commit する。
4. PRを作成する。PRテンプレートのチェック項目に沿って埋める。
5. CI(GitHub Actions)が緑になっていることを確認する。
6. レビューを待つ。小さな修正(誤字・翻訳・README改善など)であれば、GitHub上のファイル右上の鉛筆アイコンから直接編集提案(PR)を送ることもできます。

### 初めてのPRはAIに手伝わせてOK

Claude Code・GitHub Copilot・Codex などのAIコーディングエージェントを使って実装してもらって構いません。
このリポジトリには `AGENTS.md` と `CLAUDE.md` に、AIエージェント向けの構成・起動・テスト方法・守るべき線をまとめてあります。
AIに作業させた場合も、PRを出す前に必ず自分で `npm test` を実行し、PRテンプレートの「守るべき線」チェックリストを自分の目で確認してください。

### 守るべき線(必読)

[SECURITY.md](SECURITY.md) を参照してください。特に「両者が明示的に承認するまで位置の送受信を始めない」は必ず守ってください。

## English

First, try "3-minute quickstart" in the [README](README.md). No Google account and no Cloudflare account required.

### Start dev mode

```bash
git clone https://github.com/Ryoseiimai/shibuya-machimachi.git
cd shibuya-machimachi
npm run dev   # or: make dev
```

- Starts `wrangler dev` in local-only mode (`--local`, Miniflare). It never touches a real Cloudflare account.
- Open the same URL in two browser tabs to simulate both A (host) and B (guest) on one machine.
- Stop with `Ctrl+C`.

Prefer not to install anything locally? Use the "Open in GitHub Codespaces" badge at the top of the README to get a full dev environment in your browser.

### Branch & PR flow

1. Fork the repo (or create a branch directly if you have access).
2. Create a clearly named branch, e.g. `feature/your-change`.
3. Make your change. Run `cd worker && npm test` (state machine / distance-bearing / floor / Jev judgment unit tests) before committing.
4. Open a PR and fill out the PR template checklist.
5. Make sure CI (GitHub Actions) is green.
6. Wait for review. For small changes (typo fixes, translations, README improvements), you can also use GitHub's pencil ("Edit this file") button to propose a change directly as a PR.

### It's fine to use AI for your first PR

Feel free to use Claude Code, GitHub Copilot, Codex, or similar AI coding agents to help implement your change.
This repo includes `AGENTS.md` and `CLAUDE.md`, which describe the project layout, how to run/test it, and the lines an AI agent (or you) must not cross.
If an AI implemented the change, still run `npm test` yourself before opening the PR, and check the PR template's "lines not to cross" checklist with your own eyes.

### Lines not to cross (please read)

See [SECURITY.md](SECURITY.md). In particular: **never start sending/receiving location before both participants have explicitly approved.**
