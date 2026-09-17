# admin_app

云铃管理后台 App

## 构建

私有基础设施地址在编译期注入，仓库内只有占位域。构建时必须带两个 `--dart-define`，否则 App 会连到占位地址、无法访问后端：

```bash
flutter build apk --release \
  --dart-define=API_BASE=<admin 域名，含 https://> \
  --dart-define=AUTH_BASE=<认证中心域名，含 https://>
```

产物位于 `build/app/outputs/flutter-apk/app-release.apk`。本地调试同理，在 `flutter run` 后追加相同的 `--dart-define` 参数。

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
