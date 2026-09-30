import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/section_label.dart';

/// First-run screen: connect this phone to the agent running on a PC.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.controller, this.initialRelay});

  final RemoteController controller;
  final String? initialRelay;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

enum _PairMethod { code, manual }

class _PairScreenState extends State<PairScreen> {
  late final TextEditingController _relay =
      TextEditingController(text: widget.initialRelay ?? '');
  final TextEditingController _code = TextEditingController();
  final TextEditingController _agentId = TextEditingController();
  final TextEditingController _secret = TextEditingController();
  _PairMethod _method = _PairMethod.code;
  bool _busy = false;
  bool _obscureSecret = true;
  String? _error;

  @override
  void dispose() {
    _relay.dispose();
    _code.dispose();
    _agentId.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_method == _PairMethod.code) {
        await widget.controller.pairWithCode(_relay.text, _code.text);
      } else {
        await widget.controller
            .pairManually(_relay.text, _agentId.text, _secret.text);
      }
    } on RemoteException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _canSubmit {
    if (_busy || _relay.text.trim().isEmpty) return false;
    if (_method == _PairMethod.code) {
      return _code.text.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').length == 8;
    }
    return _agentId.text.trim().isNotEmpty && _secret.text.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Icon(
                        Icons.phonelink_rounded,
                        size: 36,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '连接你的电脑',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '在电脑上启动 CloudTerminal agent，它会显示服务器地址和一次性配对码。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  SegmentedButton<_PairMethod>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<_PairMethod>>[
                      ButtonSegment<_PairMethod>(
                        value: _PairMethod.code,
                        label: Text('配对码'),
                        icon: Icon(Icons.pin_outlined, size: 18),
                      ),
                      ButtonSegment<_PairMethod>(
                        value: _PairMethod.manual,
                        label: Text('手动填写'),
                        icon: Icon(Icons.key_rounded, size: 18),
                      ),
                    ],
                    selected: <_PairMethod>{_method},
                    onSelectionChanged: (s) => setState(() {
                      _method = s.first;
                      _error = null;
                    }),
                  ),
                  const SizedBox(height: 20),
                  const SectionLabel('服务器地址'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _relay,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'relay.example.com 或 192.168.1.5:8787',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_method == _PairMethod.code) ...<Widget>[
                    const SectionLabel('配对码'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _code,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.characters,
                      textAlign: TextAlign.center,
                      maxLength: 9,
                      inputFormatters: <TextInputFormatter>[_PairCodeFormatter()],
                      style: AppTheme.mono(24, fontWeight: FontWeight.w600)
                          .copyWith(letterSpacing: 4),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) {
                        if (_canSubmit) _submit();
                      },
                      decoration: const InputDecoration(
                        hintText: 'XXXX-XXXX',
                        counterText: '',
                      ),
                    ),
                  ] else ...<Widget>[
                    const SectionLabel('设备 ID'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _agentId,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      style: AppTheme.mono(14),
                      decoration: const InputDecoration(
                        hintText: 'a_xxxxxxxxxxxxxxxx',
                        prefixIcon: Icon(Icons.computer_rounded),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SectionLabel('密钥'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _secret,
                      autocorrect: false,
                      obscureText: _obscureSecret,
                      onChanged: (_) => setState(() {}),
                      style: AppTheme.mono(14),
                      decoration: InputDecoration(
                        hintText: 'agent.json 里的 secret',
                        prefixIcon: const Icon(Icons.key_rounded),
                        suffixIcon: IconButton(
                          tooltip: _obscureSecret ? '显示' : '隐藏',
                          icon: Icon(_obscureSecret
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () =>
                              setState(() => _obscureSecret = !_obscureSecret),
                        ),
                      ),
                    ),
                  ],
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    child: _error == null
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: _ErrorBanner(message: _error!),
                          ),
                  ),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: _canSubmit ? _submit : null,
                    icon: _busy
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.link_rounded),
                    label: Text(_busy ? '正在连接…' : '连接'),
                  ),
                  const SizedBox(height: 28),
                  const _HowTo(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Upper-cases and inserts the dash: "abcd2345" → "ABCD-2345".
class _PairCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text
        .toUpperCase()
        .replaceAll(RegExp(r'[^0-9A-Z]'), '');
    final clipped = raw.length > 8 ? raw.substring(0, 8) : raw;
    final text = clipped.length > 4
        ? '${clipped.substring(0, 4)}-${clipped.substring(4)}'
        : clipped;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _HowTo extends StatelessWidget {
  const _HowTo();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: scheme.onSurfaceVariant,
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.terminal_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                '在电脑上运行',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              'cd server\nnpm run agent -- --relay wss://你的服务器/ws',
              style: AppTheme.mono(12, color: scheme.onSurface),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '同一局域网内可以不用服务器：加 --local-relay，然后填写 agent 显示的局域网地址。'
            '配对码 10 分钟内有效且只能用一次，在电脑终端按回车可以换一个新的。',
            style: muted,
          ),
        ],
      ),
    );
  }
}
