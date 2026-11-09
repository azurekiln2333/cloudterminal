import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/pairing_uri.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/section_label.dart';

/// First-run screen: connect this phone to the agent running on a PC.
///
/// Three ways in, in the order most people want them:
/// 1. 扫描二维码 / 粘贴配对链接 ([_PairMethod.qr])
/// 2. 输入短码 ([_PairMethod.code])
/// 3. 手工填写服务器地址与设备密钥 ([_PairMethod.manual])
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.controller, this.initialRelay});

  final RemoteController controller;
  final String? initialRelay;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

enum _PairMethod { qr, code, manual }

class _PairScreenState extends State<PairScreen> {
  late final TextEditingController _relay =
      TextEditingController(text: widget.initialRelay ?? '');
  final TextEditingController _code = TextEditingController();
  final TextEditingController _agentId = TextEditingController();
  final TextEditingController _secret = TextEditingController();
  final TextEditingController _qr = TextEditingController();
  final FocusNode _codeFocus = FocusNode();
  _PairMethod _method = _PairMethod.code;

  /// Whether the "手工输入" section (server address + credentials) is open.
  bool _manualOpen = true;
  bool _busy = false;
  bool _obscureSecret = true;
  String? _error;

  /// Host of the relay inside the last pasted link, shown as a receipt so the
  /// user can see the paste was understood before pressing 连接.
  String? _pastedHost;

  @override
  void dispose() {
    _relay.dispose();
    _code.dispose();
    _agentId.dispose();
    _secret.dispose();
    _qr.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Entry points
  // ---------------------------------------------------------------------

  void _startQr() {
    setState(() {
      _method = _PairMethod.qr;
      _manualOpen = false;
      _error = null;
    });
  }

  /// Fills the link field from the clipboard.
  ///
  /// This app has no camera scanner, so "paste what the PC shows" is the real
  /// flow — and it used to require knowing that a long press offers Paste. The
  /// button validates the payload immediately, so a wrong copy is reported next
  /// to the button that read it instead of after a connect attempt.
  Future<void> _pasteLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _error = '剪贴板是空的，先在电脑上复制配对链接');
      return;
    }
    final parsed = PairingUri.tryParse(text);
    setState(() {
      _qr.text = text;
      _error = parsed == null
          ? '剪贴板里的内容不是 CloudTerminal 配对链接（应以 '
                '${PairingUri.scheme}://${PairingUri.host} 开头）'
          : null;
      _pastedHost = parsed?.relay.host;
    });
  }

  void _startCode() {
    setState(() {
      _method = _PairMethod.code;
      _manualOpen = true;
      _error = null;
    });
    _codeFocus.requestFocus();
  }

  Future<void> _submit() async {
    if (_method == _PairMethod.qr) return _submitQr();
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

  Future<void> _submitQr() async {
    FocusScope.of(context).unfocus();
    final payload = _qr.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.controller.pairWithQr(payload);
      if (!result.needsRelayConfirm) return;
      if (!mounted) return;
      final confirmed = await _confirmRelayChange(result);
      if (confirmed && mounted) {
        await widget.controller.pairWithQr(payload, confirmed: true);
      }
    } on RemoteException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The QR names a relay other than the one this phone remembers.
  Future<bool> _confirmRelayChange(QrPairResult result) async {
    final previous = result.previousRelayHost;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.swap_horiz_rounded),
        title: const Text('将连接新服务器'),
        content: Text(
          '这个二维码指向 ${result.relayHost}'
          '${previous == null ? '' : '，与上次使用的 $previous 不同'}。'
          '确认后本机将改为连接新的服务器。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('连接新服务器'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  // ---------------------------------------------------------------------

  bool get _canSubmit {
    if (_busy) return false;
    switch (_method) {
      case _PairMethod.qr:
        return _qr.text.trim().isNotEmpty;
      case _PairMethod.code:
        if (_relay.text.trim().isEmpty) return false;
        return _code.text.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').length == 8;
      case _PairMethod.manual:
        return _relay.text.trim().isNotEmpty &&
            _agentId.text.trim().isNotEmpty &&
            _secret.text.trim().isNotEmpty;
    }
  }

  String get _submitLabel {
    if (_busy) return '正在连接…';
    return _method == _PairMethod.qr ? '解析并连接' : '连接';
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
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(
                        Icons.phonelink_rounded,
                        size: 28,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '连接你的电脑',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '在电脑上复制它显示的配对链接粘贴过来，或直接输入配对码。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _EntryButton(
                          icon: Icons.content_paste_rounded,
                          label: '粘贴配对链接',
                          selected: _method == _PairMethod.qr,
                          onPressed: _busy ? null : _startQr,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _EntryButton(
                          icon: Icons.pin_outlined,
                          label: '输入短码',
                          selected: _method == _PairMethod.code,
                          onPressed: _busy ? null : _startCode,
                        ),
                      ),
                    ],
                  ),
                  if (_method != _PairMethod.qr) ...<Widget>[
                    const SizedBox(height: 14),
                    _ModeToggle(
                      options: const <({_PairMethod value, String label, IconData icon})>[
                        (
                          value: _PairMethod.code,
                          label: '配对码',
                          icon: Icons.pin_outlined,
                        ),
                        (
                          value: _PairMethod.manual,
                          label: '手动填写',
                          icon: Icons.key_rounded,
                        ),
                      ],
                      selected: _method,
                      onChanged: (value) => setState(() {
                        _method = value;
                        _manualOpen = true;
                        _error = null;
                      }),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (_method == _PairMethod.qr) ...<Widget>[
                    const SectionLabel('配对链接'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _qr,
                      autocorrect: false,
                      minLines: 2,
                      maxLines: 4,
                      style: AppTheme.mono(13),
                      onChanged: (_) => setState(() => _pastedHost = null),
                      decoration: InputDecoration(
                        hintText:
                            'cloudterminal://pair?relay=wss%3A%2F%2F…&code=XXXXXXXX&v=1',
                        hintStyle: AppTheme.mono(12),
                        prefixIcon: const Icon(Icons.link_rounded),
                        suffixIcon: _qr.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () => setState(() {
                                  _qr.clear();
                                  _pastedHost = null;
                                }),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pasteLink,
                          icon: const Icon(Icons.content_paste_rounded, size: 18),
                          label: const Text('从剪贴板粘贴'),
                        ),
                        const SizedBox(width: 12),
                        if (_pastedHost != null)
                          Expanded(
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 16,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    '已识别 $_pastedHost',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '没有扫描功能：长按电脑上的二维码图片复制链接，'
                      '或直接粘贴 agent 打印的配对链接。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _SectionHeader(
                    title: '手工输入',
                    subtitle: _manualOpen
                        ? (_method == _PairMethod.manual
                            ? '服务器地址 + 设备 ID + 密钥'
                            : '服务器地址 + 配对码')
                        : '${_relay.text.trim().isEmpty ? '服务器地址' : _relay.text.trim()} · 点击展开',
                    expanded: _manualOpen,
                    onTap: _busy
                        ? null
                        : () => setState(() => _manualOpen = !_manualOpen),
                  ),
                  if (_manualOpen) ...<Widget>[
                    const SizedBox(height: 12),
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
                    if (_method == _PairMethod.manual) ...<Widget>[
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
                            onPressed: () => setState(
                                () => _obscureSecret = !_obscureSecret),
                          ),
                        ),
                      ),
                    ] else ...<Widget>[
                      const SectionLabel('配对码'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _code,
                        focusNode: _codeFocus,
                        autocorrect: false,
                        textCapitalization: TextCapitalization.characters,
                        textAlign: TextAlign.center,
                        maxLength: 9,
                        inputFormatters: <TextInputFormatter>[
                          _PairCodeFormatter(),
                        ],
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
                    ],
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
                    label: Text(_submitLabel),
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

/// One of the two prominent entry points at the top of the screen.
class _EntryButton extends StatelessWidget {
  const _EntryButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      backgroundColor:
          selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      foregroundColor:
          selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    );
    return FilledButton.tonalIcon(
      style: style,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Tappable header that folds away the legacy server-address form.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(Icons.tune_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two-option toggle used to pick how the manual form authenticates.
///
/// A plain button pair rather than [SegmentedButton]: the segmented control
/// splits its width unevenly enough that tapping a label is unreliable on
/// small (phone-sized) layouts.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<({_PairMethod value, String label, IconData icon})> options;
  final _PairMethod selected;
  final ValueChanged<_PairMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          for (final option in options)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _ModeToggleButton(
                  icon: option.icon,
                  label: option.label,
                  selected: option.value == selected,
                  onPressed: () => onChanged(option.value),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeToggleButton extends StatelessWidget {
  const _ModeToggleButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        backgroundColor: selected ? scheme.primaryContainer : null,
        foregroundColor: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          const SizedBox(height: 6),
          Text(
            '配对链接格式：${PairingUri.scheme}://${PairingUri.host}'
            '?relay=<服务器地址>&code=<配对码>&v=${PairingUri.currentVersion}',
            style: muted.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
