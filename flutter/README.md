# 渋谷マチマチ（Flutter 版）

Web 版（`worker/`）と同じサーバーにつなぐ iOS/Android ネイティブ版。設計・分担・インターフェースは [SPEC.md](SPEC.md)。

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --simulator --debug
```

Bundle ID `jp.co.ryoseiworld.shibuyamachimachi.flutter`（Capacitor 版 `app/` とは別アプリ）。
