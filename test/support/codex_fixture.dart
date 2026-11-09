import 'dart:async';

import 'fake_relay.dart';

/// Isolated wire data only: never connects to a desktop daemon.
class CodexFixture {
  CodexFixture({
    this.available = true,
    this.canControl = false,
    this.canInput = false,
    this.canResume = false,
  }) {
    socket = healthyAgent(
      codex: <String, dynamic>{
        'available': available,
        'canControl': canControl,
        if (!available) 'reason': '请先启动 Codex Desktop',
      },
      capabilities: <String>[
        'terminal',
        if (available) 'codex_history',
        if (canControl) 'codex_control',
      ],
      sessions: <Map<String, dynamic>>[
        sessionJson('terminal-1', kind: 'terminal', title: '本机终端'),
      ],
    );
    final base = socket.onSend!;
    socket.onSend = (s, frame) {
      final data = frame['data'];
      if (data is! Map<String, dynamic> ||
          !(data['type'] as String).startsWith('codex_')) {
        base(s, frame);
        return;
      }
      scheduleMicrotask(() {
        final body = _reply(data);
        s.msg(<String, dynamic>{...body, 'id': data['id']});
      });
    };
  }
  final bool available;
  final bool canControl;
  bool canInput;
  bool canResume;
  late final FakeSocket socket;
  String? activeTurnId;
  String? readError;
  List<Map<String, dynamic>> pending = <Map<String, dynamic>>[];

  Map<String, dynamic> thread([String id = 'thread-1']) => <String, dynamic>{
    'id': id,
    'title': id == 'thread-1' ? '修复桌面任务' : '另一个历史会话',
    'projectId': 'project-1',
    'cwd': r'C:\isolated-fixture',
    'updatedAt': 1000,
    'status': activeTurnId == null ? 'idle' : 'active',
    'canAcceptDirectInput': canInput,
    'canResume': canResume,
    'activeTurnId': ?activeTurnId,
  };

  Map<String, dynamic> _reply(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'codex_projects':
        return <String, dynamic>{
          'kind': 'codex_projects',
          'projects': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'project-1',
              'title': '项目一',
              'roots': <String>[r'C:\isolated-fixture'],
            },
            if (data['cursor'] != null)
              <String, dynamic>{
                'id': 'project-2',
                'title': '项目二',
                'roots': <String>[],
              },
          ],
          if (data['cursor'] == null) 'nextCursor': 'projects-2',
        };
      case 'codex_threads':
        return <String, dynamic>{
          'kind': 'codex_threads',
          'threads': <Map<String, dynamic>>[
            thread(),
            if (data['cursor'] != null) thread('thread-2'),
          ],
          if (data['cursor'] == null) 'nextCursor': 'threads-2',
        };
      case 'codex_read':
        if (readError != null) {
          return <String, dynamic>{'kind': 'error', 'message': readError};
        }
        final earlier = data['cursor'] != null;
        return <String, dynamic>{
          'kind': 'codex_thread',
          'thread': thread(data['threadId'] as String),
          'turns': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': earlier ? 'turn-1' : 'turn-2',
              'status': 'completed',
              'items': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': earlier ? 'item-1' : 'item-2',
                  'kind': 'assistant',
                  'text': earlier ? '更早的回答' : '最近的回答',
                },
              ],
            },
          ],
          if (!earlier) 'nextCursor': 'earlier-turns',
          'pendingRequests': pending,
        };
      case 'codex_resume':
        canResume = false;
        canInput = true;
        return <String, dynamic>{'kind': 'ack'};
      case 'codex_send':
        activeTurnId = 'running-turn';
        return <String, dynamic>{'kind': 'ack'};
      case 'codex_interrupt':
        activeTurnId = null;
        return <String, dynamic>{'kind': 'ack'};
      case 'codex_respond':
        pending = <Map<String, dynamic>>[];
        return <String, dynamic>{'kind': 'ack'};
      default:
        return <String, dynamic>{'kind': 'error', 'message': '未知测试请求'};
    }
  }
}
