/// Small display helpers shared by the screens.
library;

String formatCost(double usd) {
  if (usd <= 0) return r'$0';
  if (usd < 0.01) return '<\$0.01';
  return '\$${usd.toStringAsFixed(2)}';
}

String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} 秒';
  if (d.inMinutes < 60) {
    final s = d.inSeconds % 60;
    return s == 0 ? '${d.inMinutes} 分' : '${d.inMinutes} 分 $s 秒';
  }
  return '${d.inHours} 小时 ${d.inMinutes % 60} 分';
}

String formatRelative(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inSeconds < 45) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${time.month}月${time.day}日';
}

/// Last path segment for either separator style (the PC may be Windows).
String baseName(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final i = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  final name = i < 0 ? trimmed : trimmed.substring(i + 1);
  return name.isEmpty ? path : name;
}

/// Shorten long paths from the left: `…\projects\app\src`.
String shortenPath(String path, {int max = 42}) {
  if (path.length <= max) return path;
  return '…${path.substring(path.length - max + 1)}';
}
