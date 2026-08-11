import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'login_page.dart';
import 'theme.dart';

class SystemPage extends StatefulWidget {
  const SystemPage({super.key});

  @override
  State<SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends State<SystemPage> {
  Map<String, dynamic>? _data;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final data = await Api.system();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = e.toString());
    }
  }

  String _fmtBytes(num? b) {
    if (b == null) return '—';
    final v = b.toDouble();
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (v >= 1024 * 1024) {
      return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (v >= 1024) return '${(v / 1024).toStringAsFixed(1)} KB';
    return '${v.toStringAsFixed(0)} B';
  }

  String _fmtRate(num? r) {
    if (r == null) return '—';
    final v = r.toDouble();
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB/s';
    }
    if (v >= 1024 * 1024) {
      return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (v >= 1024) return '${(v / 1024).toStringAsFixed(1)} KB/s';
    return '${v.toStringAsFixed(0)} B/s';
  }

  String _fmtUptime(num? sec) {
    if (sec == null) return '-';
    final s = sec.toInt();
    final d = s ~/ 86400;
    final h = (s % 86400) ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (d > 0) return '$d 天 $h 小时 $m 分';
    if (h > 0) return '$h 小时 $m 分';
    return '$m 分钟';
  }

  double _pct(dynamic v) =>
      v is num ? v.toDouble() : 0.0;

  num _num(dynamic v) => v is num ? v : 0;

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return RefreshIndicator(
      onRefresh: _refresh,
      color: kAmber,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1A1A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF5C2A2A)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 16,
                    color: Color(0xFFEF9A9A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFEF9A9A),
                        fontSize: 13,
                      ),
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
            _headerCard(data),
            const SizedBox(height: 12),
            _cpuCard(data['cpu']),
            const SizedBox(height: 12),
            _memoryCard(data['memory']),
            const SizedBox(height: 12),
            _diskCard(data['disk']),
            const SizedBox(height: 12),
            _networkCard(data['network']),
            const SizedBox(height: 12),
            _diskIoCard(data['disk_io']),
          ],
        ],
      ),
    );
  }

  Widget _headerCard(Map<String, dynamic> data) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.dns, color: kAmber, size: 18),
              const SizedBox(width: 8),
              const Text(
                '服务器',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const Icon(Icons.storage_rounded, size: 14, color: kMuted),
              const SizedBox(width: 4),
              Text(
                _fmtUptime(
                  data['uptime'] is num ? data['uptime'] as num : null,
                ),
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _kv('主机名', (data['hostname'] ?? '-').toString()),
          const SizedBox(height: 8),
          _kv('系统', (data['os'] ?? '-').toString()),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(color: kMuted, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _card({required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  Widget _metricHeader({
    required IconData icon,
    required String title,
    required double percent,
    String? percentSuffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kAmber.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: kAmber, size: 18),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '${percent.toStringAsFixed(1)}${percentSuffix ?? '%'}',
              style: const TextStyle(
                color: kAmber,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        GradientBar(value: percent / 100, height: 10, borderRadius: 5),
      ],
    );
  }

  Widget _cpuCard(dynamic cpuRaw) {
    final cpu = cpuRaw is Map ? cpuRaw : const <String, dynamic>{};
    final usage = _pct(cpu['usage_percent']);
    final model = (cpu['model'] ?? '-').toString();
    final cores = (cpu['cores'] ?? '-').toString();
    final load = cpu['loadavg'] is List ? cpu['loadavg'] as List : const [];
    final loadStr = load
        .whereType<num>()
        .map((x) => x.toStringAsFixed(2))
        .join(' / ');
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metricHeader(icon: Icons.memory, title: 'CPU', percent: usage),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _miniStat(
                  '型号',
                  model,
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 8),
              _miniStat('核心数', cores),
            ],
          ),
          if (loadStr.isNotEmpty) ...[
            const SizedBox(height: 10),
            _miniStat('负载 1 / 5 / 15', loadStr),
          ],
        ],
      ),
    );
  }

  Widget _memoryCard(dynamic memRaw) {
    final mem = memRaw is Map ? memRaw : const <String, dynamic>{};
    final total = _num(mem['total']);
    final used = _num(mem['used']);
    final free = _num(mem['free']);
    final percent = _pct(mem['percent']);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metricHeader(
            icon: Icons.speed_rounded,
            title: '内存',
            percent: percent,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _numStat('已用', _fmtBytes(used), amber: true)),
              _vDivider(),
              Expanded(child: _numStat('可用', _fmtBytes(free))),
              _vDivider(),
              Expanded(child: _numStat('总计', _fmtBytes(total))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diskCard(dynamic diskRaw) {
    final disk = diskRaw is Map ? diskRaw : const <String, dynamic>{};
    final total = _num(disk['total']);
    final used = _num(disk['used']);
    final free = _num(disk['free']);
    final percent = _pct(disk['percent']);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metricHeader(
            icon: Icons.storage_rounded,
            title: '磁盘',
            percent: percent,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _numStat('已用', _fmtBytes(used), amber: true)),
              _vDivider(),
              Expanded(child: _numStat('剩余', _fmtBytes(free))),
              _vDivider(),
              Expanded(child: _numStat('总计', _fmtBytes(total))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _networkCard(dynamic netRaw) {
    final net = netRaw is Map ? netRaw : const <String, dynamic>{};
    final rxRate = net['rx_rate'];
    final txRate = net['tx_rate'];
    final rxBytes = net['rx_bytes'];
    final txBytes = net['tx_bytes'];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kAmber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.network_check, color: kAmber, size: 18),
              ),
              const SizedBox(width: 10),
              const Text(
                '网络',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _rateStat('↓ 下载', _fmtRate(rxRate), amber: true)),
              _vDivider(),
              Expanded(child: _rateStat('↑ 上传', _fmtRate(txRate))),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _numStat('累计下载', _fmtBytes(rxBytes))),
              _vDivider(),
              Expanded(child: _numStat('累计上传', _fmtBytes(txBytes))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diskIoCard(dynamic ioRaw) {
    final io = ioRaw is Map ? ioRaw : const <String, dynamic>{};
    final readRate = io['read_rate'];
    final writeRate = io['write_rate'];
    final readBytes = io['read_bytes'];
    final writeBytes = io['write_bytes'];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kAmber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.sd_storage, color: kAmber, size: 18),
              ),
              const SizedBox(width: 10),
              const Text(
                '磁盘 I/O',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _rateStat('↓ 读取', _fmtRate(readRate), amber: true)),
              _vDivider(),
              Expanded(child: _rateStat('↑ 写入', _fmtRate(writeRate))),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _numStat('累计读取', _fmtBytes(readBytes))),
              _vDivider(),
              Expanded(child: _numStat('累计写入', _fmtBytes(writeBytes))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rateStat(String label, String value, {bool amber = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: kMuted, fontSize: 11),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: TextStyle(
              color: amber ? kAmber : Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _numStat(String label, String value, {bool amber = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: kMuted, fontSize: 11),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: TextStyle(
              color: amber ? kAmber : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _miniStat(String label, String value, {int maxLines = 2}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: kMuted, fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
        ),
      ],
    );
  }

  Widget _vDivider() {
    return Container(
      width: 1,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: kBorder,
    );
  }
}
