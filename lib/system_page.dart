import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';

class SystemPage extends StatefulWidget {
  const SystemPage({super.key, this.active = true});

  /// 是否处于可见 Tab：SSE 仅在激活时建连，切走立即断开（对齐 Web System.jsx）
  final bool active;

  @override
  State<SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends State<SystemPage> {
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _processes = [];
  List<Map<String, dynamic>> _services = [];
  double? _totalCpu; // 全部进程 CPU 合计（SSE services.total_cpu）
  String? _error;
  DateTime? _updated; // 最近一次快照时间（对齐 Web「更新于」）
  String _procSort = 'mem';

  SystemStreamHandle? _stream;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    if (widget.active) _connect();
  }

  @override
  void didUpdateWidget(covariant SystemPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _connect(); // 切回系统 Tab：重新建连
    } else if (!widget.active && oldWidget.active) {
      _disconnect(); // 切走：立即断开，零残留
    }
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  void _disconnect() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _stream?.cancel();
    _stream = null;
  }

  void _connect() {
    _disconnect();
    _stream = Api.systemStream(
      onSnapshot: _onSnapshot,
      onError: (err) {
        if (!mounted) return;
        setState(() => _error = '连接已断开，正在重连…');
      },
      onDone: _scheduleReconnect,
    );
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    // 连接断开（或流结束）且 Tab 仍激活：5s 后自动重试
    if (!widget.active) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && widget.active) _connect();
    });
  }

  void _onSnapshot(Map<String, dynamic> snapshot) {
    if (!mounted) return;
    final system = snapshot['system'];
    final hist = snapshot['history'];
    final servicesRaw = snapshot['services'];
    final services = servicesRaw is Map ? servicesRaw : <String, dynamic>{};
    setState(() {
      _data = (system is Map) ? Map<String, dynamic>.from(system) : null;
      _history = (hist is List)
          ? hist.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
          : [];
      final s = services['services'];
      final p = services['processes'];
      _services = (s is List)
          ? s.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
          : [];
      _processes = (p is List)
          ? p.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
          : [];
      _totalCpu = services['total_cpu'] is num
          ? (services['total_cpu'] as num).toDouble()
          : null;
      _updated = DateTime.now();
      _error = null;
    });
  }

  /* ============ 格式化 ============ */

  String _fmtBytes(num? b) {
    if (b == null) return '—';
    final v = b.toDouble();
    if (v >= 1024 * 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(1)} TB';
    }
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (v >= 1024 * 1024) {
      return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (v >= 1024) return '${(v / 1024).toStringAsFixed(1)} KB';
    return '${v.toStringAsFixed(1)} B';
  }

  String _fmtMB(num? mb) {
    if (mb == null) return '—';
    final v = mb.toDouble();
    return v == v.roundToDouble() ? '${v.toInt()} MB' : '${v.toStringAsFixed(1)} MB';
  }

  String _fmtRate(num? r) {
    if (r == null) return '—';
    return '${_fmtBytes(r)}/s';
  }

  String _fmtUptime(num? sec) {
    if (sec == null) return '刚刚';
    final s = sec.toInt();
    final d = s ~/ 86400;
    final h = (s % 86400) ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final parts = <String>[
      if (d > 0) '$d 天',
      if (h > 0) '$h 小时',
      if (m > 0) '$m 分钟',
    ];
    return parts.isEmpty ? '刚刚' : parts.join(' ');
  }

  String _fmtLoad(dynamic load) {
    if (load is List) {
      return load
          .whereType<num>()
          .map((x) => x.toStringAsFixed(2))
          .join(' / ');
    }
    if (load is String) return load;
    return '—';
  }

  double _pct(dynamic v) => v is num ? v.toDouble() : 0.0;
  num _num(dynamic v) => v is num ? v : 0;

  String _fmtClock(DateTime t) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}';
  }

  /// 手动刷新：重连 SSE 立即拉取最新快照
  Future<void> _reconnect() async {
    _connect();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = _data;
    return RefreshIndicator(
      onRefresh: () async => _reconnect(),
      color: c.accent,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              const Spacer(),
              Text(
                '系统监控',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.center,
            child: Text(
              _updated == null
                  ? '更新于 --'
                  : '更新于 ${_fmtClock(_updated!)}',
              style: TextStyle(color: c.muted, fontSize: 11),
            ),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: c.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: c.danger, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          if (data == null)
            const Padding(
              padding: EdgeInsets.only(top: 140),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            _metricGrid(data, c),
            const SizedBox(height: 12),
            _diskCard(data['disk'], c),
            if (_processes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _processBlock(c),
            ],
            const SizedBox(height: 12),
            _trendBlock(c),
          ],
        ],
      ),
    );
  }

  /* ============ 指标卡片 ============ */

  Widget _metricGrid(Map<String, dynamic> data, AppColors c) {
    final cpu = data['cpu'] is Map ? data['cpu'] as Map : const {};
    final mem = data['memory'] is Map ? data['memory'] as Map : const {};
    final net = data['network'] is Map ? data['network'] as Map : const {};
    final io = data['disk_io'] is Map ? data['disk_io'] as Map : const {};
    final procs = data['processes'] is Map ? data['processes'] as Map : const {};
    final cpuUsage = _pct(cpu['usage_percent']);
    final memPercent = _pct(mem['percent']);

    final cpuCard = PanelCard(
      title: 'CPU',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${cpuUsage.toStringAsFixed(1)}%',
            style: TextStyle(
              color: c.fg,
              fontSize: 38,
              fontWeight: FontWeight.w200,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          MetricBar(percent: cpuUsage),
          const SizedBox(height: 10),
          _kv(c, '型号', (cpu['model'] ?? '-').toString()),
          _kv(c, '核心数', (cpu['cores'] ?? '-').toString()),
          _kv(
            c,
            '进程',
            '${_num(procs['running'])} / ${_num(procs['total'])}',
          ),
          _kv(c, '负载 (1/5/15m)', _fmtLoad(cpu['loadavg'])),
        ],
      ),
    );

    final memCard = PanelCard(
      title: '内存',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${memPercent.toStringAsFixed(1)}%',
            style: TextStyle(
              color: c.fg,
              fontSize: 38,
              fontWeight: FontWeight.w200,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          MetricBar(percent: memPercent),
          const SizedBox(height: 10),
          _kv(c, '已用', _fmtBytes(_num(mem['used']))),
          _kv(c, '剩余', _fmtBytes(_num(mem['free']))),
          _kv(c, '总计', _fmtBytes(_num(mem['total']))),
        ],
      ),
    );

    final sysCard = PanelCard(
      title: '系统',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(c, '主机名', (data['hostname'] ?? '-').toString()),
          _kv(c, '操作系统', (data['os'] ?? '-').toString()),
          _kv(c, '运行时长', _fmtUptime(data['uptime'] is num ? data['uptime'] as num : null)),
        ],
      ),
    );

    final netCard = PanelCard(
      title: '网络',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(c, '↓ 下载', _fmtRate(net['rx_rate'] is num ? net['rx_rate'] as num : null), amber: true),
          _kv(c, '↑ 上传', _fmtRate(net['tx_rate'] is num ? net['tx_rate'] as num : null)),
          _kv(c, '累计下载', _fmtBytes(_num(net['rx_bytes']))),
          _kv(c, '累计上传', _fmtBytes(_num(net['tx_bytes']))),
        ],
      ),
    );

    final ioCard = PanelCard(
      title: '磁盘 I/O',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _rateStat(c, '读', _fmtRate(io['read_rate'] is num ? io['read_rate'] as num : null), amber: true),
              ),
              _vDivider(c),
              Expanded(
                child: _rateStat(c, '写', _fmtRate(io['write_rate'] is num ? io['write_rate'] as num : null)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _rateStat(c, '累计读', _fmtBytes(_num(io['read_bytes'])))),
              _vDivider(c),
              Expanded(child: _rateStat(c, '累计写', _fmtBytes(_num(io['write_bytes'])))),
            ],
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return Column(
            children: [
              cpuCard,
              const SizedBox(height: 12),
              memCard,
              const SizedBox(height: 12),
              sysCard,
              const SizedBox(height: 12),
              netCard,
              const SizedBox(height: 12),
              ioCard,
            ],
          );
        }
        return Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cpuCard),
                const SizedBox(width: 12),
                Expanded(child: memCard),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: sysCard),
                const SizedBox(width: 12),
                Expanded(child: netCard),
              ],
            ),
            const SizedBox(height: 12),
            ioCard,
          ],
        );
      },
    );
  }

  Widget _diskCard(dynamic diskRaw, AppColors c) {
    final disk = diskRaw is Map ? diskRaw : null;
    if (disk == null) return const SizedBox.shrink();
    final percent = _pct(disk['percent']);
    return PanelCard(
      title: '磁盘',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '已用 ${_fmtBytes(_num(disk['used']))}',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${percent.toStringAsFixed(0)}% · 共 ${_fmtBytes(_num(disk['total']))}',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          MetricBar(percent: percent),
          const SizedBox(height: 10),
          _kv(c, '剩余 / 总', '${_fmtBytes(_num(disk['free']))} / ${_fmtBytes(_num(disk['total']))}'),
        ],
      ),
    );
  }

  /* ============ 进程排行 ============ */

  Widget _processBlock(AppColors c) {
    final sorted = List<Map<String, dynamic>>.from(_processes);
    if (_procSort == 'name') {
      sorted.sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
    } else if (_procSort == 'cpu') {
      sorted.sort((a, b) => (_num(b['cpu'])).compareTo(_num(a['cpu'])));
    } else {
      sorted.sort((a, b) => (_num(b['mem_mb'])).compareTo(_num(a['mem_mb'])));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const BlockTitle('进程排行'),
            const Spacer(),
            _sortBtn(c, '名称', 'name'),
            const SizedBox(width: 4),
            _sortBtn(c, '内存', 'mem'),
            const SizedBox(width: 4),
            _sortBtn(c, 'CPU', 'cpu'),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: c.surface2,
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(child: _headLabel(c, '进程')),
                    SizedBox(width: 56, child: _headLabel(c, 'PID', right: true)),
                    SizedBox(width: 64, child: _headLabel(c, '内存', right: true)),
                    SizedBox(width: 60, child: _headLabel(c, 'CPU', right: true)),
                  ],
                ),
              ),
              for (final p in sorted)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      StatusDot(up: _serviceUp(p['pid'])),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (p['name'] ?? '-').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.fg, fontSize: 12.5),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '${p['pid']}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 12,
                            fontFamily: 'monospace',
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text(
                          _fmtMB(_num(p['mem_mb'])),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: c.fg,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 60,
                        child: Text(
                          '${_num(p['cpu']).toDouble().toStringAsFixed(1)}%',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // 合计行（对齐 Web：合计（全部进程） + CPU 列）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
                ),
                child: Row(
                  children: [
                    StatusDot(up: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '合计（全部进程）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.fg,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(width: 56, child: Text('', style: TextStyle(color: c.muted, fontSize: 12))),
                    SizedBox(width: 64, child: Text('', style: TextStyle(color: c.fg, fontSize: 12))),
                    SizedBox(
                      width: 60,
                      child: Text(
                        _totalCpu == null ? '—' : '${_totalCpu!.toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: c.fg,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _serviceUp(dynamic pid) {
    for (final s in _services) {
      if ('${s['pid']}' == '$pid') {
        return s['status'] != 'down';
      }
    }
    return true;
  }

  Widget _sortBtn(AppColors c, String label, String key) {
    final active = _procSort == key;
    return InkWell(
      onTap: () => setState(() => _procSort = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? c.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? c.accent : c.muted,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /* ============ 趋势图 ============ */

  Widget _trendBlock(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BlockTitle('趋势'),
        const SizedBox(height: 8),
        TrendChart(
          title: 'CPU / 内存（%）',
          history: _history,
          series: const [
            TrendSeries('cpu', 'CPU', accent: true),
            TrendSeries('mem_percent', '内存', accent: false),
          ],
          yMax: 100,
          yLabel: '%',
          fmtValue: (v) => '${v.toStringAsFixed(1)}%',
        ),
        const SizedBox(height: 12),
        TrendChart(
          title: '网速（/s）',
          history: _history,
          series: const [
            TrendSeries('net_rx_rate', '↓ 下载', accent: true),
            TrendSeries('net_tx_rate', '↑ 上传', accent: false),
          ],
          fmtValue: (v) => _fmtRate(v),
        ),
        const SizedBox(height: 12),
        TrendChart(
          title: '磁盘 I/O（/s）',
          history: _history,
          series: const [
            TrendSeries('disk_io_read', '读', accent: true),
            TrendSeries('disk_io_write', '写', accent: false),
          ],
          fmtValue: (v) => _fmtRate(v),
        ),
      ],
    );
  }

  /* ============ 通用小组件 ============ */

  Widget _kv(AppColors c, String label, String value, {bool amber = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: amber ? c.accent : c.fg,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rateStat(AppColors c, String label, String value, {bool amber = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: c.muted, fontSize: 11)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: TextStyle(
              color: amber ? c.accent : c.fg,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _headLabel(AppColors c, String text, {bool right = false}) => Text(
    text,
    textAlign: right ? TextAlign.right : TextAlign.left,
    style: TextStyle(
      color: c.muted,
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    ),
  );

  Widget _vDivider(AppColors c) => Container(
    width: 1,
    height: 34,
    margin: const EdgeInsets.symmetric(horizontal: 10),
    color: c.border,
  );
}

/* ============ 趋势图（纯 CustomPainter，无图表库，对齐 Web 手写 SVG） ============ */

class TrendSeries {
  final String key;
  final String label;
  final bool accent;
  const TrendSeries(this.key, this.label, {required this.accent});
}

class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.title,
    required this.history,
    required this.series,
    this.yMax,
    this.yLabel = '',
    required this.fmtValue,
  });

  final String title;
  final List<Map<String, dynamic>> history;
  final List<TrendSeries> series;
  final double? yMax;
  final String yLabel;
  final String Function(num) fmtValue;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  static const int _window = 30;
  int _offset = 0;

  bool get _following {
    final len = widget.history.length;
    if (len <= _window) return true;
    return _offset + _window >= len;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final history = widget.history;
    final len = history.length;

    // 数据增长且处于跟随态：窗口自动右移
    if (_following && len > _window) {
      _offset = len - _window;
    }

    final start = len <= _window ? 0 : _offset.clamp(0, len - _window);
    final end = math.min(len, start + _window);
    final slice = history.sublist(start, end);

    return PanelCard(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final s in widget.series)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: s.accent ? c.accent : c.muted,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        s.label,
                        style: TextStyle(color: c.muted, fontSize: 11),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _latest(s.key),
                        style: TextStyle(color: c.fg, fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (len < 2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text(
                  '数据采集中…（约 3 秒后显示趋势）',
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 160,
              child: ClipRect(
                child: GestureDetector(
                  onHorizontalDragEnd: (_) {},
                  onHorizontalDragUpdate: (d) {
                    if (len <= _window) return;
                    final next = _offset - (d.primaryDelta! / 6).round();
                    setState(() => _offset = next.clamp(0, len - _window));
                  },
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _TrendPainter(
                      points: slice,
                      series: widget.series,
                      yMax: widget.yMax,
                      yLabel: widget.yLabel,
                      fmtValue: widget.fmtValue,
                      c: c,
                    ),
                  ),
                ),
              ),
            ),
            if (!_following && len > _window)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InkWell(
                    onTap: () => setState(() => _offset = len - _window),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.accentBorder),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '回最新',
                        style: TextStyle(color: c.accent, fontSize: 11),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _latest(String key) {
    final h = widget.history;
    if (h.isEmpty) return '';
    final v = h.last[key];
    return v is num ? widget.fmtValue(v) : '';
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.series,
    required this.yMax,
    required this.yLabel,
    required this.fmtValue,
    required this.c,
  });

  final List<Map<String, dynamic>> points;
  final List<TrendSeries> series;
  final double? yMax;
  final String yLabel;
  final String Function(num) fmtValue;
  final AppColors c;

  static const double _l = 52, _r = 12, _t = 12, _b = 24;

  double _niceMax(double v) {
    if (v <= 0) return 1;
    final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    final f = v / exp;
    double nf;
    if (f <= 1) {
      nf = 1;
    } else if (f <= 2) {
      nf = 2;
    } else if (f <= 5) {
      nf = 5;
    } else {
      nf = 10;
    }
    return nf * exp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final plotW = w - _l - _r;
    final plotH = h - _t - _b;
    if (plotW <= 0 || plotH <= 0 || points.isEmpty) return;

    final gridPaint = Paint()
      ..color = c.border.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final textStyle = TextStyle(color: c.muted, fontSize: 9, fontFeatures: const [FontFeature.tabularFigures()]);
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    double maxV;
    bool percentChart;
    if (yMax != null) {
      maxV = yMax!;
      percentChart = true;
    } else {
      var m = 0.0;
      for (final p in points) {
        for (final s in series) {
          final v = p[s.key];
          if (v is num) m = math.max(m, v.toDouble());
        }
      }
      maxV = _niceMax(m);
      percentChart = false;
    }

    final nTicks = percentChart ? 4 : 5;
    for (var i = 0; i < nTicks; i++) {
      final ratio = i / (nTicks - 1);
      final y = _t + plotH * (1 - ratio);
      canvas.drawLine(Offset(_l, y), Offset(_l + plotW, y), gridPaint);
      final val = maxV * ratio;
      final label = percentChart
          ? '${val.round()}$yLabel'
          : fmtValue(val.toDouble());
      textPainter.text = TextSpan(text: label, style: textStyle);
      textPainter.layout();
      textPainter.paint(canvas, Offset(_l - textPainter.width - 6, y - textPainter.height / 2));
    }

    // X 轴时间标签：首/1/3/2/3/尾
    final xIdx = <int>{0, (points.length - 1) ~/ 3, (2 * (points.length - 1)) ~/ 3, points.length - 1};
    for (final i in xIdx) {
      final ts = points[i]['ts'];
      final x = _l + plotW * (i / (points.length - 1));
      textPainter.text = TextSpan(text: _fmtTime(ts), style: textStyle);
      textPainter.layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, _t + plotH + 4));
    }

    for (final s in series) {
      final linePaint = Paint()
        ..color = s.accent ? c.accent : c.muted
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      var first = true;
      for (var i = 0; i < points.length; i++) {
        final v = points[i][s.key];
        if (v is! num) continue;
        final x = _l + plotW * (i / (points.length - 1));
        final y = _t + plotH * (1 - (v.toDouble().clamp(0, maxV) / maxV));
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      if (!first) canvas.drawPath(path, linePaint);
    }
  }

  String _fmtTime(dynamic ts) {
    final t = ts is num ? ts.toInt() : 0;
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.points != points || old.c != c || old.yMax != yMax;
}
