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

/// Middle-ellipsis path that keeps the head (drive/root) and the tail.
///
/// The trailing segment is usually the project or file name, so tail-only
/// truncation (`shortenPath`) loses the most informative part on a phone. This
/// keeps both ends: `D:\…\cloudterminal`. Both `\` and `/` are treated as
/// separators because the path belongs to the paired PC, which is usually
/// Windows while the phone may be ohos/Android.
String ellipsizePath(String path, {int max = 42}) {
  if (max <= 1 || path.length <= max) return path;
  final parts = path.split(RegExp(r'[\\/]'));
  if (parts.length <= 2) {
    // A single oversized segment (e.g. a long file name): keep the tail.
    return '…${path.substring(path.length - max + 1)}';
  }
  final separator = path.contains('\\') ? '\\' : '/';
  final head = parts.first;
  final tail = parts.last;
  // 2 chars for the ellipsis and the separator after the head; the rest is the
  // budget for whatever middle segments still fit.
  final budget = max - head.length - tail.length - 2;
  if (budget <= 0) return '…${path.substring(path.length - max + 1)}';
  final middle = _middleSegments(parts, budget);
  if (middle.isEmpty) return '$head$separator…$separator$tail';
  return '$head$separator…$separator${middle.join(separator)}$separator$tail';
}

/// Picks the segments adjacent to the head and tail that fit in [budget] chars.
List<String> _middleSegments(List<String> parts, int budget) {
  final middle = parts.sublist(1, parts.length - 1);
  if (middle.isEmpty) return const <String>[];
  // Grow outward from the tail: the segment before the project name is the
  // next most useful context.
  final kept = <String>[];
  var used = 0;
  for (var i = middle.length - 1; i >= 0; i--) {
    final cost = middle[i].length + 1; // +1 for the separator.
    if (used + cost > budget) break;
    kept.insert(0, middle[i]);
    used += cost;
  }
  return kept;
}
