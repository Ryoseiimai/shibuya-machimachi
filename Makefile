.PHONY: dev test e2e

# Googleアカウント・Cloudflareアカウントなしで動く開発モード
dev:
	bash scripts/dev.sh

# worker のユニットテスト(node:test)
test:
	cd worker && npm test

# Playwright end-to-end テスト(2ブラウザコンテキストでA/Bの承認フローを通しで確認)
e2e:
	cd e2e && npm test
