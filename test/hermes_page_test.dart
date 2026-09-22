import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/hermes_page.dart';
import 'package:home_admin/home_page.dart';

/// 替身 WebView：不接触平台视图，只记录 URL / 事件 / 释放。
class _FakeAdapter implements HermesWebViewAdapter {
  _FakeAdapter(this.url, this.events);

  final String url;
  final HermesWebViewEvents events;
  bool disposed = false;

  @override
  Widget build() => const SizedBox(key: Key('fake-hermes-webview'));

  @override
  void dispose() => disposed = true;
}

class _FakeFactory {
  final List<_FakeAdapter> created = [];

  HermesWebViewAdapter call(String url, HermesWebViewEvents events) {
    final adapter = _FakeAdapter(url, events);
    created.add(adapter);
    return adapter;
  }
}

HermesWebViewFactory _asFactory(_FakeFactory fake) =>
    (url, events) => fake(url, events);

Widget _host(Widget child) => MaterialApp(home: child);

void main() {
  group('抽屉导航', () {
    testWidgets('末项为 Hermes，其余八项顺序不变，点击选中下标 8', (tester) async {
      final labels = homeNavItems.map((e) => e.label).toList();
      expect(labels, ['系统', '版本', '博客', '管理', '终端', '文件', '通知', '调试', 'Hermes']);

      int? selected;
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: HomeDrawer(
              current: 0,
              onSelect: (i) => selected = i,
              onClose: () {},
            ),
          ),
        ),
      );

      for (final label in labels) {
        expect(find.text(label), findsOneWidget);
      }
      // Hermes 追加在最后：位置低于「调试」。
      expect(
        tester.getTopLeft(find.text('Hermes')).dy,
        greaterThan(tester.getTopLeft(find.text('调试')).dy),
      );

      await tester.tap(find.text('Hermes'));
      await tester.pumpAndSettle();
      expect(selected, 8);
    });
  });

  group('HermesPage URL 注入', () {
    testWidgets('默认取构建期注入 kHermesUrl，源码仅 example.com 占位', (tester) async {
      final fake = _FakeFactory();
      await tester.pumpWidget(
        _host(
          HermesPage(
            webViewFactory: _asFactory(fake),
            loadTimeout: Duration.zero,
          ),
        ),
      );

      expect(kHermesUrl, 'https://hermes.example.com');
      expect(fake.created.single.url, kHermesUrl);
    });

    testWidgets('显式 url 覆盖注入值并传给 WebView', (tester) async {
      final fake = _FakeFactory();
      await tester.pumpWidget(
        _host(
          HermesPage(
            url: 'https://injected.example.com',
            webViewFactory: _asFactory(fake),
            loadTimeout: Duration.zero,
          ),
        ),
      );

      expect(fake.created.single.url, 'https://injected.example.com');
    });
  });

  group('HermesPage 加载与失败态', () {
    testWidgets('失败态显示说明 + 重试 + 用浏览器打开，重试重建 WebView', (tester) async {
      final fake = _FakeFactory();
      var opened = 0;
      await tester.pumpWidget(
        _host(
          HermesPage(
            webViewFactory: _asFactory(fake),
            loadTimeout: Duration.zero,
            onOpenExternal: (_) async {
              opened += 1;
              return true;
            },
          ),
        ),
      );
      expect(find.byKey(const Key('fake-hermes-webview')), findsOneWidget);

      fake.created.single.events.onError('net::ERR_INTERNET_DISCONNECTED');
      await tester.pump();

      expect(find.text('Hermes 加载失败'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '用浏览器打开'), findsOneWidget);
      expect(find.textContaining('ERR_INTERNET_DISCONNECTED'), findsOneWidget);

      // 失败态下「用浏览器打开」可用。
      await tester.tap(find.widgetWithText(OutlinedButton, '用浏览器打开'));
      await tester.pump();
      expect(opened, 1);

      // 重试：旧实例释放、新实例创建，恢复为 WebView（不白屏）。
      final first = fake.created.single;
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pump();
      expect(fake.created.length, 2);
      expect(first.disposed, isTrue);
      expect(find.byKey(const Key('fake-hermes-webview')), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('加载完成后隐藏进度、保留 WebView', (tester) async {
      final fake = _FakeFactory();
      await tester.pumpWidget(
        _host(
          HermesPage(
            webViewFactory: _asFactory(fake),
            loadTimeout: Duration.zero,
          ),
        ),
      );

      fake.created.single.events.onProgress(50);
      await tester.pump();
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.5, 0.001));

      fake.created.single.events.onFinished();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byKey(const Key('fake-hermes-webview')), findsOneWidget);
    });
  });

  group('HermesPage 刷新与常驻', () {
    testWidgets('点「刷新」重建 WebView（旧实例释放）', (tester) async {
      final fake = _FakeFactory();
      await tester.pumpWidget(
        _host(
          HermesPage(
            webViewFactory: _asFactory(fake),
            loadTimeout: Duration.zero,
          ),
        ),
      );
      expect(fake.created.length, 1);
      final first = fake.created.single;

      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();

      expect(fake.created.length, 2);
      expect(first.disposed, isTrue);
      expect(find.byKey(const Key('fake-hermes-webview')), findsOneWidget);
    });

    testWidgets('AppBar「用浏览器打开」调用注入回调', (tester) async {
      final fake = _FakeFactory();
      final opened = <String>[];
      await tester.pumpWidget(
        _host(
          HermesPage(
            url: 'https://injected.example.com',
            webViewFactory: _asFactory(fake),
            loadTimeout: Duration.zero,
            onOpenExternal: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      );

      await tester.tap(find.byTooltip('用浏览器打开'));
      await tester.pump();
      expect(opened, ['https://injected.example.com']);
    });

    testWidgets('不可见时不创建 WebView（懒加载）', (tester) async {
      final fake = _FakeFactory();
      await tester.pumpWidget(
        _host(
          HermesPage(
            active: false,
            webViewFactory: _asFactory(fake),
            loadTimeout: Duration.zero,
          ),
        ),
      );
      expect(fake.created, isEmpty);
    });

    testWidgets('切走再切回不重建 WebView（保留 Hermes 登录态）', (tester) async {
      final fake = _FakeFactory();
      Widget page(bool active) => _host(
            HermesPage(
              active: active,
              webViewFactory: _asFactory(fake),
              loadTimeout: Duration.zero,
            ),
          );

      await tester.pumpWidget(page(true));
      expect(fake.created.length, 1);

      await tester.pumpWidget(page(false));
      expect(fake.created.length, 1);
      expect(fake.created.single.disposed, isFalse);

      await tester.pumpWidget(page(true));
      expect(fake.created.length, 1);
    });
  });
}
