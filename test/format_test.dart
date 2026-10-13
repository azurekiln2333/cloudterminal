// Unit tests for the shared display formatters.

import 'package:cloudterminal/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ellipsizePath', () {
    test('leaves a short path unchanged', () {
      expect(
        ellipsizePath(r'D:\MyNewProjects\cloudterminal'),
        r'D:\MyNewProjects\cloudterminal',
      );
    });

    test('keeps the head and the trailing segment for a long Windows path', () {
      const path =
          r'D:\MyNewProjects\cloudterminal\.build\pi-herdr\live-probe-final';
      final result = ellipsizePath(path, max: 24);
      expect(result.length, lessThanOrEqualTo(24));
      expect(result, startsWith('D:'));
      expect(result, contains('…'));
      expect(result, endsWith(r'\live-probe-final'));
    });

    test('keeps the trailing segment for a long forward-slash path', () {
      const path = '/home/ohos/workspace/a/very/deep/project/folder';
      final result = ellipsizePath(path, max: 24);
      expect(result.length, lessThanOrEqualTo(24));
      expect(result, startsWith('/'));
      expect(result, contains('…'));
      expect(result, endsWith('/folder'));
    });

    test('handles mixed separators', () {
      const path = r'C:\work/projects/deep/nested/cloudterminal';
      final result = ellipsizePath(path, max: 22);
      expect(result.length, lessThanOrEqualTo(22));
      expect(result, startsWith('C:'));
      expect(result, endsWith('cloudterminal'));
    });

    test('keeps the tail of a single oversized segment', () {
      const name =
          'a-really-really-long-single-file-name-with-no-separators.md';
      final result = ellipsizePath(name, max: 16);
      expect(result.length, lessThanOrEqualTo(16));
      expect(result, startsWith('…'));
      expect(result, endsWith('.md'));
    });

    test('falls back to tail truncation when the tail alone is too long', () {
      const path = r'D:\MyNewProjects\cloudterminal';
      final result = ellipsizePath(path, max: 8);
      expect(result.length, lessThanOrEqualTo(8));
      expect(result, startsWith('…'));
    });
  });

  group('shortenPath / baseName', () {
    test('baseName handles both separators', () {
      expect(baseName(r'D:\a\b\cloudterminal'), 'cloudterminal');
      expect(baseName('/home/ohos/cloudterminal'), 'cloudterminal');
    });

    test('shortenPath truncates from the left', () {
      expect(shortenPath(r'D:\a\b\cloudterminal', max: 10), '…dterminal');
    });
  });
}
