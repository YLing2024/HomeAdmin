import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'theme.dart';

/// Hermes 控制台地址：**构建期注入**，源码内只允许 `example.com` 占位。
///
/// ```bash
/// flutter build apk --release --dart-define=HERMES_URL=https://<真实域名>
/// ```
///
/// 与 Web 端 `VITE_HERMES_DASHBOARD_URL` 的做法一致：真实域名只写在本地，绝不入库。
const String kHermesUrl = String.fromEnvironment(
  'HERMES_URL',
  defaultValue: 'https://hermes.example.com',
);

/// 与终端页一致的深色底，消除加载瞬间白闪。
const Color _kHermesBg = Color(0xFF13110F);

/// 主文档加载超时；超时未完成即视为失败（可注入以便测试）。
const Duration kHermesLoadTimeout = Duration(seconds: 20);

/// WebView 向页面回传的加载 / 导航事件。
class HermesWebViewEvents {
  const HermesWebViewEvents({
    required this.onStarted,
    required this.onFinished,
    required this.onProgress,
    required this.onError,
  });

  final VoidCallback onStarted;
  final VoidCallback onFinished;
  final void Function(int progress) onProgress;

  /// 主文档加载失败（断网 / 超时 / 5xx / DNS 等），[description] 为原始描述。
  final void Function(String description) onError;
}

/// 页面依赖的最小 WebView 抽象。
///
/// 真实实现包一层 `webview_flutter`（见 [createHermesWebView]）；测试注入替身即可在
/// 无平台视图的情况下驱动加载 / 失败 / 重建，无需新增依赖。
abstract class HermesWebViewAdapter {
  Widget build();

  void dispose();
}

typedef HermesWebViewFactory = HermesWebViewAdapter Function(
  String url,
  HermesWebViewEvents events,
);

/// 默认实现：`webview_flutter`（与终端页同款，仅加载 + 进度 + 错误回调）。
///
/// 铁律：**不做任何 cookie 注入 / SSO 打通 / 自动登录**——Hermes 自带登录，
/// 用户在 WebView 里登一次，之后由 WebView 自己带 cookie。
HermesWebViewAdapter createHermesWebView(
  String url,
  HermesWebViewEvents events,
) {
  final controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(_kHermesBg)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) => events.onStarted(),
        onPageFinished: (_) => events.onFinished(),
        onProgress: events.onProgress,
        onWebResourceError: (err) {
          // 只把主文档错误当作失败；忽略图片 / 脚本等子资源错误，避免误报。
          if (err.isForMainFrame ?? true) events.onError(err.description);
        },
      ),
    )
    ..loadRequest(Uri.parse(url));
  return _FlutterWebViewAdapter(controller);
}

class _FlutterWebViewAdapter implements HermesWebViewAdapter {
  _FlutterWebViewAdapter(this._controller);

  final WebViewController _controller;

  @override
  Widget build() => WebViewWidget(controller: _controller);

  @override
  void dispose() {
    // WebViewController 无公开 dispose；平台视图随 widget 移除回收。
  }
}

/// Hermes 控制台页：全屏 WebView（对齐 Web 端 `Hermes.jsx`，但用原生 WebView 而非 iframe）。
///
/// - 顶部 AppBar：「刷新」（[_reload]，自增 nonce 重建 WebView，照抄终端页做法）
///   与「用浏览器打开」（`url_launcher` 外部打开）。
/// - 加载态：顶部细进度条；失败态：「重试」+「用浏览器打开」，绝不白屏。
/// - 双登录：不注入 cookie、不做 SSO，保留 Hermes 自己的登录。
/// - 常驻：由宿主放进 `IndexedStack`，切走不销毁；[active] 仅在**首次**可见时创建 WebView，
///   之后切走再切回不重建，避免登录态反复丢失（对齐终端页常驻思路）。
class HermesPage extends StatefulWidget {
  const HermesPage({
    super.key,
    this.active = true,
    this.url = kHermesUrl,
    this.onOpenExternal,
    this.webViewFactory = createHermesWebView,
    this.loadTimeout = kHermesLoadTimeout,
  });

  /// 是否处于可见 Tab：仅首次可见时创建 WebView，此后常驻保留。
  final bool active;

  /// 目标地址，默认取构建期注入的 [kHermesUrl]。
  final String url;

  /// 外部打开；缺省用 `url_launcher`（测试可注入）。
  final Future<bool> Function(String url)? onOpenExternal;

  /// WebView 工厂（测试注入替身）。
  final HermesWebViewFactory webViewFactory;

  /// 主文档加载超时；传 [Duration.zero] 关闭。
  final Duration loadTimeout;

  @override
  State<HermesPage> createState() => _HermesPageState();
}

class _HermesPageState extends State<HermesPage> {
  HermesWebViewAdapter? _adapter;
  Timer? _timeout;

  /// 刷新自增，令 WebView 子树连同实例整体重建（对齐终端页 `_nonce`）。
  int _nonce = 0;

  bool _loading = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 懒创建：不可见时不加载 Hermes，避免 App 启动即请求。
    if (widget.active) _buildAdapter();
  }

  @override
  void didUpdateWidget(covariant HermesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 首次切到本页才创建；此后 _adapter 非空，切走再切回不重建（保留登录态）。
    if (widget.active && _adapter == null && _error == null) {
      _buildAdapter();
    }
  }

  @override
  void dispose() {
    _cancelTimeout();
    _adapter?.dispose();
    super.dispose();
  }

  /// 创建 WebView 实例。调用方保证随后会有 build（initState / didUpdateWidget / setState）。
  void _buildAdapter() {
    _cancelTimeout();
    _loading = true;
    _progress = 0;
    _error = null;
    _adapter = widget.webViewFactory(
      widget.url,
      HermesWebViewEvents(
        onStarted: _onStarted,
        onFinished: _onFinished,
        onProgress: _onProgress,
        onError: _onError,
      ),
    );
    _startTimeout();
  }

  void _startTimeout() {
    _cancelTimeout();
    if (widget.loadTimeout <= Duration.zero) return;
    _timeout = Timer(widget.loadTimeout, () {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载超时，请检查网络后重试';
      });
    });
  }

  void _cancelTimeout() {
    _timeout?.cancel();
    _timeout = null;
  }

  void _onStarted() {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
  }

  void _onProgress(int progress) {
    if (!mounted) return;
    setState(() {
      _progress = progress.clamp(0, 100) / 100.0;
      if (progress >= 100) _loading = false;
    });
  }

  void _onFinished() {
    if (!mounted) return;
    _cancelTimeout();
    setState(() {
      _loading = false;
      _progress = 1;
    });
  }

  void _onError(String description) {
    if (!mounted) return;
    _cancelTimeout();
    setState(() {
      _loading = false;
      _error = description.isEmpty ? '加载失败' : description;
    });
  }

  /// 刷新 / 重试：丢弃旧实例并自增 nonce，重建 WebView（照抄终端页「重连」）。
  void _reload() {
    _cancelTimeout();
    _adapter?.dispose();
    _adapter = null;
    setState(() {
      _nonce++;
      _loading = true;
      _progress = 0;
      _error = null;
    });
  }

  Future<void> _openExternal() async {
    final open = widget.onOpenExternal ?? _launchExternal;
    final ok = await open(widget.url);
    if (mounted && !ok) showAppToast(context, '无法打开链接', ok: false);
  }

  static Future<bool> _launchExternal(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // 懒创建在 build 中进行（不 setState）；此时 _adapter 为 null 且页面刚可见。
    if (widget.active && _adapter == null) _buildAdapter();

    return Scaffold(
      backgroundColor: _kHermesBg,
      appBar: AppBar(
        title: const Text('Hermes'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
          IconButton(
            tooltip: '用浏览器打开',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openExternal,
          ),
        ],
      ),
      body: _adapter == null
          ? const SizedBox.shrink()
          : Stack(
              children: [
                Positioned.fill(
                  // nonce 变化 → key 变化 → WebView 子树整体重建
                  child: KeyedSubtree(
                    key: ValueKey<String>('hermes-webview-$_nonce'),
                    child: _adapter!.build(),
                  ),
                ),
                if (_error != null) Positioned.fill(child: _failure(c)),
                if (_error == null && _loading)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(
                      value: _progress > 0 && _progress < 1 ? _progress : null,
                      minHeight: 2,
                      backgroundColor: Colors.transparent,
                      color: c.accent,
                    ),
                  ),
              ],
            ),
    );
  }

  /// 失败态：一行说明 + 「重试」+「用浏览器打开」，杜绝白屏。
  Widget _failure(AppColors c) {
    return ColoredBox(
      color: _kHermesBg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, color: c.muted, size: 32),
              const SizedBox(height: 12),
              Text(
                'Hermes 加载失败',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: _reload,
                    child: const Text('重试'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _openExternal,
                    child: const Text('用浏览器打开'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
