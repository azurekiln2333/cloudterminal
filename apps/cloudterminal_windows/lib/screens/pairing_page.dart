import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/pairing_uri.dart';
import '../state/assistant_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

/// 配对页：显示二维码与短码，手机扫一次即可。
///
/// 二维码内容是 `cloudterminal://pair?relay=…&code=…`，等价于现有的配对横幅，
/// 只携带一次性码，**不含长期密钥**。刷新即作废旧码。
class PairingPage extends StatelessWidget {
  const PairingPage({super.key, required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final pair = controller.pairCode;
    final snapshot = controller.snapshot;
    return PageScaffold(
      title: '配对',
      subtitle: snapshot.relayUrl ?? '未配置中继地址',
      actions: <Widget>[
        IconButton(
          tooltip: '生成新的配对码',
          onPressed: controller.requestPairCode,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (!snapshot.relayOnline)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: _Notice(
                icon: Icons.cloud_off_rounded,
                text: '中继未连接。配对码需要中继在线才能生效；'
                    '请先确认连接设置（设置页）与网络。',
              ),
            ),
          SectionCard(
            title: '手机扫码连接',
            subtitle: '用 CloudTerminal 手机端扫描下面的二维码',
            child: pair == null
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    children: <Widget>[
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: QrImageView(
                            data: pair.uri,
                            size: 220,
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '短码（手机手动输入时使用）',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        PairUri.displayCode(pair.display),
                        style: AppTheme.mono(
                          30,
                          weight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _Countdown(expiresAt: pair.expiresAt),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          const _Notice(
            icon: Icons.lock_outline_rounded,
            text: '配对码 10 分钟内有效且只能用一次；刷新后旧码立即失效。'
                '二维码不含长期密钥，手机仍需通过中继认证换取凭据。',
          ),
        ],
      ),
    );
  }
}

class _Countdown extends StatefulWidget {
  const _Countdown({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.expiresAt.difference(DateTime.now());
    final expired = remaining.isNegative;
    final minutes = remaining.inMinutes.clamp(0, 99);
    final seconds = (remaining.inSeconds % 60).clamp(0, 59);
    return Text(
      expired
          ? '已过期，请点右上角刷新'
          : '剩余 ${minutes.toString().padLeft(2, '0')}:'
                '${seconds.toString().padLeft(2, '0')}',
      style: TextStyle(
        fontSize: 12.5,
        color: expired
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
