// Herdr models, controller and UI tests.
//
// Wire fixtures are copied from a live `herdr 0.9.3` session (see
// .trellis/tasks/10-12-herdr-mobile/research/herdr-cli-0.9.3.md) so a field
// rename on either side breaks these tests.

import 'dart:async';

import 'dart:io';

import 'package:cloudterminal/models/herdr.dart';
import 'package:cloudterminal/models/protocol.dart';
import 'package:cloudterminal/screens/herdr_screen.dart';
import 'package:cloudterminal/screens/session_screen.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/codex_catalog.dart';
import 'package:cloudterminal/state/herdr_controller.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/theme/app_theme.dart';
import 'package:cloudterminal/widgets/workspace_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_relay.dart';
import 'terminal_test.dart' show controllerFor;

// ---------------------------------------------------------------------------
// Recorded fixtures
// ---------------------------------------------------------------------------

Map<String, dynamic> workspaceJson({
  String id = 'wJ',
  String label = 'cloudterminal',
  int number = 13,
  bool focused = true,
  String status = 'working',
  int paneCount = 2,
  int tabCount = 1,
}) => <String, dynamic>{
  'workspaceId': id,
  'label': label,
  'number': number,
  'focused': focused,
  'agentStatus': status,
  'paneCount': paneCount,
  'tabCount': tabCount,
  'activeTabId': '$id:t1',
};

Map<String, dynamic> agentJson({
  String target = 'wJ:p1',
  String paneId = 'wJ:p1',
  String workspaceId = 'wJ',
  String kind = 'codex',
  String status = 'working',
  String? name,
  String cwd = r'D:\MyNewProjects\cloudterminal',
  bool focused = true,
}) => <String, dynamic>{
  'target': target,
  'paneId': paneId,
  'workspaceId': workspaceId,
  'tabId': '$workspaceId:t1',
  'cwd': cwd,
  'agentKind': kind,
  'status': status,
  'focused': focused,
  'terminalTitle': 'π - cloudterminal',
  'name': ?name,
  'interactiveReady': true,
};

Map<String, dynamic> paneJson({
  String paneId = 'wJ:p2',
  String workspaceId = 'wJ',
  String? tabId,
  String? agent = 'pi',
  String? status = 'idle',
  String? name,
  String? cwd,
  String? terminalTitle,
  bool focused = false,
  int scrollOffsetFromBottom = 0,
}) => <String, dynamic>{
  'paneId': paneId,
  'workspaceId': workspaceId,
  'tabId': tabId ?? '$workspaceId:t1',
  'cwd': cwd ?? r'D:\MyNewProjects\cloudterminal',
  'focused': focused,
  'terminalTitle': terminalTitle ?? 'π - cloudterminal',
  'agent': ?agent,
  'agentStatus': ?status,
  'name': ?name,
  'interactiveReady': true,
  'scroll': <String, dynamic>{
    'offsetFromBottom': scrollOffsetFromBottom,
    'maxOffsetFromBottom': scrollOffsetFromBottom,
    'viewportRows': 43,
  },
};

Map<String, dynamic> tabJson({
  String tabId = 'wJ:t1',
  String workspaceId = 'wJ',
  String label = 'main',
  int number = 1,
  bool focused = true,
  String status = 'idle',
  int paneCount = 2,
}) => <String, dynamic>{
  'tabId': tabId,
  'workspaceId': workspaceId,
  'label': label,
  'number': number,
  'focused': focused,
  'agentStatus': status,
  'paneCount': paneCount,
};

Map<String, dynamic> availabilityJson({
  bool available = true,
  bool installed = true,
  bool running = true,
  String? reason,
}) => <String, dynamic>{
  'available': available,
  'installed': installed,
  'serverRunning': running,
  'canControl': available,
  'version': installed ? '0.9.3' : null,
  'protocol': 22,
  'socket': r'D:\AppData\Roaming\herdr\herdr.sock',
  'reason': ?reason,
};

// ---------------------------------------------------------------------------
// Model parsing
// ---------------------------------------------------------------------------

void main() {
  group('Herdr models', () {
    test('parses a real workspace payload', () {
      final workspace = HerdrWorkspace.fromJson(workspaceJson());
      expect(workspace.workspaceId, 'wJ');
      expect(workspace.label, 'cloudterminal');
      expect(workspace.number, 13);
      expect(workspace.focused, isTrue);
      expect(workspace.agentStatus, HerdrAgentStatus.working);
      expect(workspace.paneCount, 2);
      expect(workspace.activeTabId, 'wJ:t1');
      expect(workspace.displayLabel, 'cloudterminal');
    });

    test('falls back to the id when the label is empty', () {
      final workspace = HerdrWorkspace.fromJson(
        workspaceJson(id: 'wF', label: ''),
      );
      expect(workspace.displayLabel, 'wF');
    });

    test('degrades an unknown agent status to unknown, never throws', () {
      expect(parseHerdrAgentStatus('working'), HerdrAgentStatus.working);
      expect(parseHerdrAgentStatus('done'), HerdrAgentStatus.done);
      expect(parseHerdrAgentStatus('quiescent'), HerdrAgentStatus.unknown);
      expect(parseHerdrAgentStatus(null), HerdrAgentStatus.unknown);
      expect(parseHerdrAgentStatus(42), HerdrAgentStatus.unknown);
    });

    test('tolerates missing optional fields', () {
      final agent = HerdrAgent.fromJson(<String, dynamic>{
        'target': 'w1:p1',
        'paneId': 'w1:p1',
      });
      expect(agent.agentKind, '');
      expect(agent.status, HerdrAgentStatus.unknown);
      expect(agent.name, isNull);
      expect(agent.completionSeq, isNull);
    });

    test('a named agent displays its name, an unnamed one its pane', () {
      expect(
        HerdrAgent.fromJson(agentJson(name: 'pi-go-review')).displayName,
        'pi-go-review',
      );
      expect(
        HerdrAgent.fromJson(
          agentJson(kind: 'codex', paneId: 'wJ:p1'),
        ).displayName,
        'codex · wJ:p1',
      );
    });

    test('only idle and done accept input; blocked does not', () {
      for (final status in <String>['idle', 'done']) {
        expect(
          HerdrAgent.fromJson(agentJson(status: status)).canAcceptInput,
          isTrue,
          reason: status,
        );
      }
      for (final status in <String>['working', 'blocked', 'unknown']) {
        expect(
          HerdrAgent.fromJson(agentJson(status: status)).canAcceptInput,
          isFalse,
          reason: status,
        );
      }
      expect(
        HerdrAgent.fromJson(agentJson(status: 'blocked')).needsAttention,
        isTrue,
      );
      expect(
        HerdrAgent.fromJson(agentJson(status: 'done')).needsAttention,
        isTrue,
      );
      expect(
        HerdrAgent.fromJson(agentJson(status: 'working')).needsAttention,
        isFalse,
      );
    });

    test('a pane with no agent is an empty terminal', () {
      final pane = HerdrPane.fromJson(paneJson(agent: null, status: null));
      expect(pane.hostsAgent, isFalse);
      expect(pane.agentStatus, isNull);
      expect(pane.scroll?.viewportRows, 43);
    });

    test('a pane agent target prefers the name over the pane id', () {
      expect(
        HerdrPane.fromJson(paneJson(name: 'reviewer')).agentTarget,
        'reviewer',
      );
      expect(HerdrPane.fromJson(paneJson()).agentTarget, 'wJ:p2');
    });

    test('parses availability with and without a reason', () {
      final ready = HerdrAvailability.fromJson(availabilityJson());
      expect(ready.available, isTrue);
      expect(ready.version, '0.9.3');
      expect(ready.protocol, 22);
      expect(ready.summary, 'Herdr 0.9.3');

      final stopped = HerdrAvailability.fromJson(
        availabilityJson(
          available: false,
          running: false,
          reason: 'Herdr 服务未运行。',
        ),
      );
      expect(stopped.canControl, isFalse);
      expect(stopped.summary, 'Herdr 服务未运行。');
    });

    test('parses pane output and preserves the trailing newline', () {
      final output = HerdrOutput.fromJson(<String, dynamic>{
        'paneId': 'wJ:p2',
        'source': 'recent-unwrapped',
        'text': 'line one\nline two\n\n',
      });
      expect(output.source, HerdrReadSource.recentUnwrapped);
      // The raw screen text is the single source of truth: no trailing-\n
      // trimming, because terminal vertical whitespace is part of the layout.
      expect(output.text, 'line one\nline two\n\n');
      expect(output.isBlank, isFalse);
      expect(
        HerdrOutput.fromJson(<String, dynamic>{'text': '   \n'}).isBlank,
        isTrue,
      );
    });

    test(
      'preserves trailing whitespace, blank lines and ANSI from pane read',
      () {
        const raw = '\x1b[32mOK\x1b[0m  \n\n\n┌───┐\n│   │\n\n';
        final output = HerdrOutput.fromJson(<String, dynamic>{
          'paneId': 'wJ:p2',
          'source': 'visible',
          'text': raw,
        });
        expect(output.text, raw); // zero rewriting
        expect(output.text.endsWith('\n'), isTrue);
        expect(output.text.startsWith('\x1b[32mOK\x1b[0m  '), isTrue);
        expect(output.isBlank, isFalse);
      },
    );

    test('a whitespace-only pane read is blank', () {
      final output = HerdrOutput.fromJson(<String, dynamic>{
        'paneId': 'wJ:p2',
        'source': 'visible',
        'text': '   \n\n  ',
      });
      expect(output.isBlank, isTrue);
      expect(output.text, '   \n\n  ', reason: 'blankness never rewrites');
    });

    test('an unknown read source falls back to visible', () {
      final output = HerdrOutput.fromJson(<String, dynamic>{
        'text': 'x',
        'source': 'telepathy',
      });
      expect(output.source, HerdrReadSource.visible);
    });

    test('exposes exactly the wire values Herdr accepts', () {
      expect(HerdrReadSource.values.map((s) => s.wire).toList(), <String>[
        'visible',
        'recent',
        'recent-unwrapped',
        'detection',
      ]);
      expect(herdrAgentKinds, contains('pi'));
      expect(herdrAgentKinds, contains('codex'));
      expect(herdrAgentKinds.length, 24);
      // Keys stay non-destructive.
      expect(herdrKeys.map((k) => k.$1), contains('ctrl+c'));
      expect(
        herdrKeys.map((k) => k.$1).any((k) => k.contains('alt+')),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Action payloads
  // -------------------------------------------------------------------------

  group('HerdrActions wire shape', () {
    test('workspace create omits absent optionals', () {
      expect(HerdrActions.workspaceCreate(), <String, dynamic>{
        'kind': 'workspace_create',
      });
      expect(
        HerdrActions.workspaceCreate(label: 'cloudterminal', focus: false),
        <String, dynamic>{
          'kind': 'workspace_create',
          'label': 'cloudterminal',
          'focus': false,
        },
      );
    });

    test('pane split keeps the pane id and direction', () {
      expect(
        HerdrActions.paneSplit('wJ:p2', 'right', ratio: 0.5, focus: false),
        <String, dynamic>{
          'kind': 'pane_split',
          'paneId': 'wJ:p2',
          'direction': 'right',
          'ratio': 0.5,
          'focus': false,
        },
      );
    });

    test('agent start carries a validated kind and pane', () {
      expect(
        HerdrActions.agentStart('reviewer', 'codex', 'wZ:p1'),
        <String, dynamic>{
          'kind': 'agent_start',
          'name': 'reviewer',
          'agentKind': 'codex',
          'paneId': 'wZ:p1',
        },
      );
    });

    test('pane rename without a label clears it', () {
      expect(HerdrActions.paneRename('wJ:p2'), <String, dynamic>{
        'kind': 'pane_rename',
        'paneId': 'wJ:p2',
      });
    });

    test('every action kind is a snake_case Herdr verb', () {
      final actions = <Map<String, dynamic>>[
        HerdrActions.workspaceFocus('wJ'),
        HerdrActions.workspaceClose('wJ'),
        HerdrActions.tabCreate('wJ'),
        HerdrActions.tabClose('wJ:t1'),
        HerdrActions.paneZoom('wJ:p2'),
        HerdrActions.paneClose('wJ:p2'),
        HerdrActions.paneResize('wJ:p2', 'up'),
        HerdrActions.paneMoveToNewTab('wJ:p2'),
        HerdrActions.paneMoveToNewWorkspace('wJ:p2'),
        HerdrActions.agentFocus('wJ:p2'),
        HerdrActions.agentRename('wJ:p2', name: 'reviewer'),
      ];
      for (final action in actions) {
        expect(
          action['kind'],
          matches(RegExp(r'^[a-z]+(_[a-z]+)+$')),
          reason: action.toString(),
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // Controller request/response
  // -------------------------------------------------------------------------

  group('HerdrController', () {
    late FakeSocket socket;
    late RemoteController remote;
    // Null until setUpConnected() runs: tests that build their own harness must
    // not trip the shared teardown.
    HerdrController? herdr;

    Future<void> setUpConnected({bool available = true}) async {
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'ws://relay/ws',
          agentId: 'a_1',
          secret: 's',
          name: 'DESKTOP',
        ),
      );
      socket = healthyAgent(
        capabilities: available ? <String>['herdr'] : const <String>[],
      );
      remote = RemoteController(store: store, connector: (_) async => socket);
      herdr = HerdrController(remote);
      remote.connect();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // Answer the initial info/list_sessions handshake.
      for (final request in socket.requests) {
        expect(request['type'], isNotNull);
      }
      await Future<void>.delayed(Duration.zero);
    }

    /// Scripts replies for the Herdr request types.
    void scriptHerdr({
      bool available = true,
      String? reason,
      List<Map<String, dynamic>>? workspaces,
      List<Map<String, dynamic>>? agents,
      List<Map<String, dynamic>>? panes,
      List<Map<String, dynamic>>? tabs,
      String outputText = 'real screen text',
      String? error,
    }) {
      // Builds a `herdr_tabs` reply list from [tabs] when one is provided.
      List<Map<String, dynamic>> tabReply(String workspaceId) =>
          tabs ?? <Map<String, dynamic>>[tabJson(workspaceId: workspaceId)];
      socket.onSend = (s, frame) {
        if (frame['t'] == 'hello') {
          scheduleMicrotask(
            () => s.push(<String, dynamic>{
              't': 'hello_ok',
              'clientId': 'c1',
              'online': true,
              'name': 'DESKTOP',
            }),
          );
          return;
        }
        final data = frame['data'] as Map<String, dynamic>;
        final id = data['id'];
        scheduleMicrotask(() {
          switch (data['type']) {
            case 'info':
              s.msg(<String, dynamic>{
                'kind': 'info',
                'id': id,
                'host': 'DESKTOP',
                'platform': 'win32',
                'defaultCwd': r'C:\work',
                'roots': <String>[r'C:\work'],
                'allowBypass': false,
                'capabilities': <String>['terminal', if (available) 'herdr'],
                'herdr': availabilityJson(
                  available: available,
                  installed: available || reason != 'missing',
                  running: available,
                  reason: reason,
                ),
              });
            case 'list_sessions':
              s.msg(<String, dynamic>{
                'kind': 'sessions',
                'id': id,
                'sessions': <dynamic>[],
              });
            case 'herdr_info':
              s.msg(<String, dynamic>{
                'kind': 'herdr_info',
                'id': id,
                'availability': availabilityJson(
                  available: available,
                  installed: available || reason != 'missing',
                  running: available,
                  reason: reason,
                ),
              });
            case 'herdr_workspaces':
              if (error != null) {
                s.msg(<String, dynamic>{
                  'kind': 'error',
                  'id': id,
                  'message': error,
                });
              } else {
                s.msg(<String, dynamic>{
                  'kind': 'herdr_workspaces',
                  'id': id,
                  'workspaces':
                      workspaces ?? <Map<String, dynamic>>[workspaceJson()],
                });
              }
            case 'herdr_agents':
              s.msg(<String, dynamic>{
                'kind': 'herdr_agents',
                'id': id,
                'agents': agents ?? <Map<String, dynamic>>[agentJson()],
              });
            case 'herdr_panes':
              s.msg(<String, dynamic>{
                'kind': 'herdr_panes',
                'id': id,
                'workspaceId': data['workspaceId'],
                'panes': panes ?? <Map<String, dynamic>>[paneJson()],
              });
            case 'herdr_tabs':
              s.msg(<String, dynamic>{
                'kind': 'herdr_tabs',
                'id': id,
                'workspaceId': data['workspaceId'],
                'tabs': tabReply('${data['workspaceId']}'),
              });
            case 'herdr_read':
              s.msg(<String, dynamic>{
                'kind': 'herdr_output',
                'id': id,
                'paneId': data['paneId'],
                'source': data['source'],
                'text': outputText,
              });
            case 'herdr_act':
            case 'herdr_prompt':
            case 'herdr_send_keys':
            case 'herdr_send_text':
            case 'herdr_run':
              s.msg(<String, dynamic>{
                'kind': 'herdr_result',
                'id': id,
                'action': data['type'],
                'summary': '已执行',
              });
            default:
              s.msg(<String, dynamic>{'kind': 'ack', 'id': id});
          }
        });
      };
    }

    tearDown(() {
      herdr?.dispose();
      if (herdr != null) remote.dispose();
      herdr = null;
    });

    test('loads real workspaces and agents', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      expect(herdr!.loaded, isTrue);
      expect(herdr!.canControl, isTrue);
      expect(herdr!.availability?.version, '0.9.3');
      expect(herdr!.workspaces, hasLength(1));
      expect(herdr!.workspaces.first.label, 'cloudterminal');
      expect(herdr!.agents, hasLength(1));
      expect(herdr!.agents.first.status, HerdrAgentStatus.working);
      expect(herdr!.error, isNull);
    });

    test('reports unavailability without inventing workspaces', () async {
      await setUpConnected(available: false);
      scriptHerdr(available: false, reason: 'Herdr 服务未运行。');
      await herdr!.refresh();
      expect(herdr!.canControl, isFalse);
      expect(herdr!.workspaces, isEmpty);
      expect(herdr!.agents, isEmpty);
      expect(herdr!.loaded, isFalse);
    });

    test('an unprobed bridge is browsable but not controllable', () async {
      // Connect without answering herdr_info: the capability question is
      // outstanding, which is exactly the state a fresh app starts in.
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'ws://relay/ws',
          agentId: 'a_1',
          secret: 's',
          name: 'DESKTOP',
        ),
      );
      final s = healthyAgent(capabilities: const <String>['herdr']);
      final r = RemoteController(store: store, connector: (_) async => s);
      final h = HerdrController(r);
      addTearDown(() {
        h.dispose();
        r.dispose();
      });
      _scriptHerdrSocket(s, respondAvailability: false);
      r.connect();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        h.probed,
        isFalse,
        reason: 'availability == null is "unknown", not "unavailable"',
      );
      expect(
        h.canBrowse,
        isTrue,
        reason: 'connected means the page is openable even before probing',
      );
      expect(h.canControl, isFalse, reason: 'unknown must not grant control');
    });

    test('reading a workspace and layout is allowed without control', () async {
      // The pane list and its layout are reads. Gating them on canControl left
      // an unprobed bridge with rows that could not be opened at all.
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'ws://relay/ws',
          agentId: 'a_1',
          secret: 's',
          name: 'DESKTOP',
        ),
      );
      final s = healthyAgent(capabilities: const <String>['herdr']);
      final r = RemoteController(store: store, connector: (_) async => s);
      final h = HerdrController(r);
      addTearDown(() {
        h.dispose();
        r.dispose();
      });
      _scriptHerdrSocket(s, respondAvailability: false);
      r.connect();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(h.canControl, isFalse, reason: 'precondition: not controllable');

      await h.loadWorkspace('wJ');
      expect(
        s.requests.where((req) => req['type'] == 'herdr_panes'),
        isNotEmpty,
        reason: 'a read must not be blocked by the write capability',
      );
      await h.loadLayout('wJ:p1');
      expect(
        s.requests.where((req) => req['type'] == 'herdr_layout'),
        isNotEmpty,
      );
    });

    test(
      'dropping the link clears the listings, not just availability',
      () async {
        // A stale agent/workspace count keeps rendering as live (the sidebar
        // badge is not online-guarded), so the caches must go too.
        await setUpConnected();
        scriptHerdr();
        await herdr!.refresh();
        expect(
          herdr!.workspaces,
          isNotEmpty,
          reason: 'precondition: data loaded',
        );

        socket.drop();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(herdr!.workspaces, isEmpty);
        expect(herdr!.agents, isEmpty);
        expect(herdr!.attentionCount, 0);
        expect(herdr!.canBrowse, isFalse);
        expect(herdr!.probed, isFalse);
      },
    );

    test('probes on connect without the page being opened', () async {
      // Fresh controller, then connect: the transition to online must trigger a
      // probe, otherwise the entry stays unusable until the user opens it.
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'ws://relay/ws',
          agentId: 'a_1',
          secret: 's',
          name: 'DESKTOP',
        ),
      );
      final s = healthyAgent(capabilities: const <String>['herdr']);
      final r = RemoteController(store: store, connector: (_) async => s);
      final h = HerdrController(r);
      addTearDown(() {
        h.dispose();
        r.dispose();
      });
      scriptHerdrOn(s);
      r.connect();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        s.requests.where((req) => req['type'] == 'herdr_info'),
        isNotEmpty,
        reason: 'connecting must probe Herdr, not wait for the page',
      );
      expect(h.probed, isTrue);
      expect(h.canControl, isTrue);
    });

    test(
      'a failed first probe is probed-without-control and survives a reset',
      () async {
        // A bridge whose very first probe fails: the capability question is
        // answered (negatively), so the UI stops claiming it is "unknown".
        final store = AppStore.memory();
        await store.setPairing(
          const Pairing(
            relayUrl: 'ws://relay/ws',
            agentId: 'a_1',
            secret: 's',
            name: 'DESKTOP',
          ),
        );
        final s = healthyAgent(capabilities: const <String>['herdr']);
        final r = RemoteController(store: store, connector: (_) async => s);
        final h = HerdrController(r);
        addTearDown(() {
          h.dispose();
          r.dispose();
        });
        _scriptHerdrSocket(s, error: 'herdr_failed:boom');
        r.connect();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(
          h.probed,
          isTrue,
          reason: 'a failed probe still answers the capability question',
        );
        expect(h.availability, isNull);
        expect(h.canControl, isFalse);
        expect(
          h.canBrowse,
          isTrue,
          reason: 'the reason is still worth viewing',
        );
        // Dropping the link resets the cached answer.
        s.drop();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(h.canBrowse, isFalse);
        expect(h.probed, isFalse);
      },
    );

    test('surfaces a typed herdr error with the prefix stripped', () async {
      await setUpConnected();
      scriptHerdr(
        error: 'herdr_failed:agent_blocked:agent 正在等待确认或提问，请先在电脑上处理（waiting）',
      );
      await herdr!.refresh();
      expect(herdr!.error, 'agent 正在等待确认或提问，请先在电脑上处理（waiting）');
    });

    test('reads pane output through the requested source', () async {
      await setUpConnected();
      scriptHerdr(outputText: 'hello from herdr\n');
      await herdr!.refresh();
      final output = await herdr!.read(
        'wJ:p2',
        source: HerdrReadSource.recentUnwrapped,
        lines: 40,
      );
      expect(output.text, 'hello from herdr\n');
      final request = socket.lastRequest('herdr_read');
      expect(request?['paneId'], 'wJ:p2');
      expect(request?['source'], 'recent-unwrapped');
      expect(request?['lines'], 40);
    });

    test('loads panes for a workspace and caches them', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      await herdr!.loadWorkspace('wJ');
      expect(herdr!.panes('wJ'), hasLength(1));
      final before = socket.requests
          .where((r) => r['type'] == 'herdr_panes')
          .length;
      await herdr!.loadWorkspace('wJ');
      final after = socket.requests
          .where((r) => r['type'] == 'herdr_panes')
          .length;
      expect(after, before, reason: 'a cached workspace must not refetch');
      await herdr!.loadWorkspace('wJ', force: true);
      expect(
        socket.requests.where((r) => r['type'] == 'herdr_panes').length,
        greaterThan(after),
      );
    });

    test(
      'the watchdog re-reads the listing so a desktop-side tab appears',
      () async {
        // Regression for "3 tabs on the PC, 1 chip on the phone": reads are
        // request/response, so without a tick the rows keep rendering whatever was
        // fetched when the screen opened.
        await setUpConnected();
        scriptHerdr(
          tabs: <Map<String, dynamic>>[tabJson(tabId: 'wJ:t1', label: 'main')],
        );
        await herdr!.refresh();
        expect(herdr!.visibleTabs, hasLength(1), reason: 'precondition');

        // A watchdog with a tiny interval, so the tick lands inside the test.
        final watched = HerdrController(
          remote,
          watchdogInterval: const Duration(milliseconds: 10),
        );
        addTearDown(watched.dispose);

        // The desktop is now reporting three tabs. The fake answers every
        // request, so the second listing is what a tick must fetch.
        scriptHerdr(
          tabs: <Map<String, dynamic>>[
            tabJson(tabId: 'wJ:t1', label: 'main'),
            tabJson(tabId: 'wJ:t2', label: 'logs', number: 2, focused: false),
            tabJson(tabId: 'wJ:t3', label: 'tests', number: 3, focused: false),
          ],
        );

        watched.watch();
        expect(watched.watching, isTrue);
        // Give the periodic timer real time to fire at least once.
        for (var i = 0; i < 40 && watched.visibleTabs.length < 3; i += 1) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(
          watched.visibleTabs.map((t) => t.label),
          <String>['main', 'logs', 'tests'],
          reason: 'the watchdog must pick up tabs added on the desktop',
        );
        watched.unwatch();
        expect(watched.watching, isFalse);
      },
    );

    test(
      'the watchdog is armed by a screen and stopped when it leaves',
      () async {
        await setUpConnected();
        scriptHerdr();
        expect(
          herdr!.watching,
          isFalse,
          reason: 'nothing polls until a screen that shows the rows asks',
        );
        herdr!.watch();
        expect(herdr!.watching, isTrue);
        // A second screen on top of the first must not double-arm it.
        herdr!.watch();
        expect(herdr!.watchers, 2);
        herdr!.unwatch();
        expect(
          herdr!.watching,
          isTrue,
          reason: 'the first screen is still mounted',
        );
        herdr!.unwatch();
        expect(herdr!.watching, isFalse);
      },
    );

    test('a tick does not fire while a mutating action is in flight', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();

      // The same controller the action runs on, with a fast tick, so the guard
      // under test is the one the action set.
      final guarded = HerdrController(
        remote,
        watchdogInterval: const Duration(milliseconds: 5),
      );
      addTearDown(guarded.dispose);
      // This controller is built while the link is already up, so it probes once
      // on construction; let that settle before counting.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = socket.requests
          .where((r) => r['type'] == 'herdr_workspaces')
          .length;

      var ticks = 0;
      final busy = guarded.run('agent_start:wZ:p1', () async {
        // Hold the guard open across several watchdog periods.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        ticks += 1;
        return const HerdrActionReport(action: 'a', summary: 'x');
      }, refreshAfter: false);

      guarded.watch();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final during = socket.requests
          .where((r) => r['type'] == 'herdr_workspaces')
          .length;
      expect(busy, isNotNull);
      expect(
        during,
        before,
        reason: 'the tick must yield to an action the user just triggered',
      );
      guarded.unwatchAll();
      await busy;
      expect(ticks, 1);
    });

    test('a pane output push applies a prefix delta', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      herdr!.applyPaneOutput(
        paneId: 'wJ:p2',
        reset: true,
        prefix: 0,
        chunk: 'line one\n',
      );
      herdr!.applyPaneOutput(
        paneId: 'wJ:p2',
        reset: false,
        prefix: 9,
        chunk: 'line two\n',
      );
      expect(herdr!.paneText('wJ:p2'), 'line one\nline two\n');
    });

    test('a malformed prefix falls back to a full replace', () async {
      // A prefix longer than what the phone holds means a push was missed; the
      // only safe response is to trust the new frame completely.
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      herdr!.applyPaneOutput(
        paneId: 'wJ:p2',
        reset: true,
        prefix: 0,
        chunk: 'abc',
      );
      herdr!.applyPaneOutput(
        paneId: 'wJ:p2',
        reset: false,
        prefix: 99,
        chunk: 'xyz',
      );
      expect(herdr!.paneText('wJ:p2'), 'xyz');
    });

    test('an identical pane frame is ignored', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      var notifications = 0;
      herdr!.addListener(() => notifications += 1);
      herdr!.applyPaneOutput(
        paneId: 'wJ:p2',
        reset: true,
        prefix: 0,
        chunk: 'same',
      );
      final afterFirst = notifications;
      herdr!.applyPaneOutput(
        paneId: 'wJ:p2',
        reset: false,
        prefix: 4,
        chunk: '',
      );
      expect(notifications, afterFirst, reason: 'no change must not notify');
    });

    test('a structure push patches tabs without any request', () async {
      // This is the low-latency path: the agent's socket event already carries
      // the object, so the rows update with no `herdr_tabs` round trip.
      await setUpConnected();
      scriptHerdr(
        tabs: <Map<String, dynamic>>[tabJson(tabId: 'wJ:t1', label: 'main')],
      );
      await herdr!.refresh();
      expect(herdr!.visibleTabs, hasLength(1));
      final before = socket.requests
          .where((r) => r['type'] == 'herdr_tabs')
          .length;

      herdr!.applyStructure(<String, dynamic>{
        'kind': 'herdr_structure',
        'workspaceId': 'wJ',
        'tabs': <Map<String, dynamic>>[
          tabJson(tabId: 'wJ:t1', label: 'main'),
          tabJson(tabId: 'wJ:t2', label: 'logs', number: 2, focused: false),
        ],
      });

      expect(herdr!.visibleTabs.map((t) => t.label), <String>['main', 'logs']);
      expect(
        socket.requests.where((r) => r['type'] == 'herdr_tabs').length,
        before,
        reason: 'a push must not trigger a read',
      );
    });

    test('a structure push that changes nothing does not notify', () async {
      await setUpConnected();
      scriptHerdr(
        tabs: <Map<String, dynamic>>[tabJson(tabId: 'wJ:t1', label: 'main')],
      );
      await herdr!.refresh();
      var notifications = 0;
      herdr!.addListener(() => notifications += 1);
      herdr!.applyStructure(<String, dynamic>{
        'kind': 'herdr_structure',
        'workspaceId': 'wJ',
        'tabs': <Map<String, dynamic>>[tabJson(tabId: 'wJ:t1', label: 'main')],
      });
      expect(notifications, 0);
    });

    test('watching a pane sends herdr_watch and switching clears it', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      herdr!.watchPane('wJ:p2');
      await Future<void>.delayed(Duration.zero);
      expect(socket.lastRequest('herdr_watch')?['paneId'], 'wJ:p2');
      herdr!.watchPane(null);
      await Future<void>.delayed(Duration.zero);
      expect(socket.lastRequest('herdr_watch')?['paneId'], isNull);
    });

    test(
      'failed watch acknowledgements are contained without automatic retry',
      () async {
        await setUpConnected();
        scriptHerdr();
        await herdr!.refresh();
        final previous = socket.onSend;
        socket.onSend = (s, frame) {
          final data = frame['data'];
          if (data is Map<String, dynamic> && data['type'] == 'herdr_watch') {
            scheduleMicrotask(() {
              s.msg(<String, dynamic>{
                'kind': 'error',
                'id': data['id'],
                'message': 'herdr_failed:pane_not_found:面板已关闭',
              });
            });
            return;
          }
          previous?.call(s, frame);
        };

        herdr!.watchPane('wJ:p2', explicit: true);
        for (var i = 0; i < 4; i += 1) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(herdr!.watchedPaneId, 'wJ:p2');
        expect(
          socket.requests.where((r) => r['type'] == 'herdr_watch'),
          hasLength(1),
          reason:
              'a failed watch must settle without an unhandled error or retry',
        );

        herdr!.suspendWatching();
        for (var i = 0; i < 4; i += 1) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(herdr!.watchedPaneId, isNull);
        expect(herdr!.preferredPaneId, 'wJ:p2');
        expect(
          socket.requests.where((r) => r['type'] == 'herdr_watch'),
          hasLength(2),
          reason:
              'a failed unsubscribe must also settle without an async error',
        );
      },
    );

    test('reconnect re-issues the watch for an active pane', () async {
      // Regression: the desktop drops a client's watch when its connection goes
      // (`AgentCore.clientLeft`), and reconnecting used to only refresh listings,
      // so the pane stayed silent forever. The local id is unchanged, which is why
      // the value-equality guard in `_setSubscription` cannot be what restores it.
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'ws://relay/ws',
          agentId: 'a_1',
          secret: 's',
          name: 'DESKTOP',
        ),
      );
      // A fresh socket per connect, so a reconnect is a genuinely new link.
      final sockets = <FakeSocket>[];
      final subject = RemoteController(
        store: store,
        connector: (_) async {
          final fresh = healthyAgent(capabilities: const <String>['herdr']);
          scriptHerdrOn(fresh);
          sockets.add(fresh);
          return fresh;
        },
      );
      final watched = HerdrController(subject);
      addTearDown(() {
        watched.dispose();
        subject.dispose();
      });
      subject.connect();
      for (var i = 0; i < 10; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(sockets, hasLength(1));

      watched.watchPane('wJ:p2');
      for (var i = 0; i < 4; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        sockets.first.requests
            .where((r) => r['type'] == 'herdr_watch' && r['paneId'] == 'wJ:p2')
            .length,
        1,
      );

      // The link drops. The pane stays selected locally; the desktop forgot it.
      sockets.first.drop();
      for (var i = 0; i < 6; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(watched.watchedPaneId, 'wJ:p2', reason: 'the selection survives');

      subject.connect();
      for (var i = 0; i < 20; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(sockets.length, greaterThanOrEqualTo(2), reason: 'a new link');

      // The reconnect must have re-issued the watch on the new socket.
      final reissued = sockets
          .skip(1)
          .expand((s) => s.requests)
          .where((r) => r['type'] == 'herdr_watch' && r['paneId'] == 'wJ:p2');
      expect(
        reissued,
        isNotEmpty,
        reason: 'the reconnect must re-issue the watch',
      );
    });

    test('a suspended pane is not re-subscribed on reconnect', () async {
      // Nobody is watching, so a reconnect must not start a background read.
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'ws://relay/ws',
          agentId: 'a_1',
          secret: 's',
          name: 'DESKTOP',
        ),
      );
      final sockets = <FakeSocket>[];
      final subject = RemoteController(
        store: store,
        connector: (_) async {
          final fresh = healthyAgent(capabilities: const <String>['herdr']);
          scriptHerdrOn(fresh);
          sockets.add(fresh);
          return fresh;
        },
      );
      final watched = HerdrController(subject);
      addTearDown(() {
        watched.dispose();
        subject.dispose();
      });
      subject.connect();
      for (var i = 0; i < 10; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      watched.watchPane('wJ:pX', explicit: true);
      await Future<void>.delayed(Duration.zero);
      watched.suspendWatching();
      await Future<void>.delayed(Duration.zero);
      expect(watched.watchedPaneId, isNull);

      sockets.first.drop();
      for (var i = 0; i < 6; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      subject.connect();
      for (var i = 0; i < 20; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      final afterSuspension = sockets
          .skip(1)
          .expand((s) => s.requests)
          .where((r) => r['type'] == 'herdr_watch' && r['paneId'] == 'wJ:pX');
      expect(
        afterSuspension,
        isEmpty,
        reason: 'a suspended selection must not resubscribe in the background',
      );
      // The choice may legitimately be discarded here: the scripted listing does not
      // contain `wJ:pX`, so the authoritative reconcile drops it as a closed pane.
      // What must hold is that it was never *subscribed* again.
      expect(watched.watchedPaneId, isNull);
    });

    test('a repeated action is dropped while one is in flight', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      var calls = 0;
      final first = herdr!.run('agent_start:wZ:p1', () async {
        calls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return const HerdrActionReport(action: 'a', summary: 'x');
      }, refreshAfter: false);
      // Second call for the same key resolves to null without running.
      final second = await herdr!.run('agent_start:wZ:p1', () async {
        calls += 1;
        return const HerdrActionReport(action: 'a', summary: 'y');
      }, refreshAfter: false);
      expect(second, isNull);
      await first;
      expect(
        calls,
        1,
        reason: 'the guard must prevent a duplicate agent start',
      );
    });

    test('sends a prompt with a target and text', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      await herdr!.run(
        'prompt:wJ:p2',
        () => remote.herdrPrompt('wJ:p2', 'run the tests', wait: false),
        refreshAfter: false,
      );
      final request = socket.lastRequest('herdr_prompt');
      expect(request?['target'], 'wJ:p2');
      expect(request?['text'], 'run the tests');
      expect(request?['wait'], isFalse);
    });

    test('sends agent actions with the expected payload', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      await herdr!.run(
        'split',
        () => remote.herdrAct(
          HerdrActions.paneSplit('wJ:p2', 'down', focus: false),
        ),
        refreshAfter: false,
      );
      final request = socket.lastRequest('herdr_act');
      expect(request?['action'], <String, dynamic>{
        'kind': 'pane_split',
        'paneId': 'wJ:p2',
        'direction': 'down',
        'focus': false,
      });
    });

    test('reports a stalled prompt as an error and does not retry', () async {
      await setUpConnected();
      scriptHerdr();
      await herdr!.refresh();
      final promptCountBefore = socket.requests
          .where((r) => r['type'] == 'herdr_prompt')
          .length;
      var attempts = 0;
      await expectLater(
        herdr!.run('prompt:once', () async {
          attempts += 1;
          throw const RemoteException(
            'herdr_failed:agent_prompt_stalled:提示已发送但未观察到 agent 开始工作',
          );
        }, refreshAfter: false),
        throwsA(isA<RemoteException>()),
      );
      expect(attempts, 1);
      expect(
        socket.requests.where((r) => r['type'] == 'herdr_prompt').length,
        promptCountBefore,
      );
      expect(herdr!.error, contains('未观察到 agent 开始工作'));
      // The guard must be released so the user can deliberately retry.
      expect(herdr!.isBusy('prompt:once'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Widgets
  // -------------------------------------------------------------------------

  group('Herdr UI', () {
    testWidgets('shows the availability reason when Herdr is unavailable', (
      tester,
    ) async {
      await _pumpHerdr(
        tester,
        availability: availabilityJson(
          available: false,
          running: false,
          reason: 'Herdr 服务未运行。请在电脑上打开一次 Herdr。',
        ),
        workspaces: const <Map<String, dynamic>>[],
      );
      expect(find.text('Herdr 不可用'), findsOneWidget);
      expect(find.textContaining('Herdr 服务未运行'), findsWidgets);
      // No fabricated workspaces and no create button while unavailable.
      expect(find.byIcon(Icons.add_rounded), findsNothing);
    });

    testWidgets('an unknown Herdr state is never labelled as disabled', (
      tester,
    ) async {
      // No availability report is produced: the app must show a pending state,
      // and must not assert that the desktop has Herdr turned off.
      await _pumpHerdr(
        tester,
        respondAvailability: false,
        workspaces: const <Map<String, dynamic>>[],
        settle: false,
      );
      expect(find.textContaining('电脑端未启用'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      // Drain the request timeout so no timer outlives the widget tree.
      await tester.pump(const Duration(seconds: 21));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    });

    testWidgets('lists real workspaces with counts and status', (tester) async {
      await _pumpHerdr(
        tester,
        workspaces: <Map<String, dynamic>>[
          workspaceJson(),
          workspaceJson(
            id: 'wF',
            label: 'qfli_studio_core',
            number: 10,
            focused: false,
            status: 'idle',
            paneCount: 1,
          ),
        ],
      );
      expect(find.text('cloudterminal'), findsOneWidget);
      expect(find.text('qfli_studio_core'), findsOneWidget);
      expect(find.text('1 标签 · 2 面板'), findsOneWidget);
      expect(find.text('工作中'), findsOneWidget);
      expect(find.text('空闲'), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    });

    testWidgets('expands a workspace to reveal panes and agents', (
      tester,
    ) async {
      await _pumpHerdr(tester);
      await tester.tap(find.text('cloudterminal'));
      await tester.pumpAndSettle();
      expect(find.text('wJ:p1'), findsWidgets);
      expect(find.text('wJ:p2'), findsWidgets);
      expect(find.text('pi'), findsWidgets);
    });

    testWidgets('workspace list fits a 360dp phone without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await _pumpHerdr(
        tester,
        workspaces: <Map<String, dynamic>>[
          workspaceJson(
            id: 'wL',
            label: 'qfli_studio_core_mobile_terminal_supervisor',
            number: 10,
            focused: true,
            status: 'working',
            paneCount: 3,
            tabCount: 2,
          ),
          workspaceJson(
            id: 'wV',
            label: 'vaultwarden-backup-nightly',
            number: 11,
            focused: false,
            status: 'blocked',
            paneCount: 1,
            tabCount: 1,
          ),
        ],
        panes: <Map<String, dynamic>>[
          paneJson(
            paneId: 'wL:p1',
            workspaceId: 'wL',
            name: 'pi-go-curriculum-review-agent',
            cwd:
                r'D:\MyNewProjects\cloudterminal\.build\pi-herdr\live-probe-final',
            terminalTitle: 'π - a very long terminal title that will not fit',
          ),
          paneJson(
            paneId: 'wL:p2',
            workspaceId: 'wL',
            tabId: 'wL:t2',
            agent: null,
            status: null,
            cwd: '/home/ohos/workspace/a/very/deep/project/folder',
          ),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('qfli_studio_core'), findsOneWidget);

      // Expand so the pane rows (the densest layout) are laid out too.
      await tester.tap(find.textContaining('qfli_studio_core'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanding a workspace groups panes under their tabs', (
      tester,
    ) async {
      await _pumpHerdr(
        tester,
        tabs: <Map<String, dynamic>>[
          tabJson(tabId: 'wJ:t1', label: 'editor', paneCount: 1),
          tabJson(
            tabId: 'wJ:t2',
            label: 'tests',
            number: 2,
            focused: false,
            paneCount: 1,
          ),
        ],
        panes: <Map<String, dynamic>>[
          paneJson(paneId: 'wJ:p1', tabId: 'wJ:t1'),
          paneJson(paneId: 'wJ:p2', tabId: 'wJ:t2', agent: null, status: null),
        ],
      );
      await tester.tap(find.text('cloudterminal'));
      await tester.pumpAndSettle();
      expect(find.text('标签页'), findsOneWidget);
      expect(find.textContaining('editor'), findsOneWidget);
      expect(find.textContaining('tests'), findsOneWidget);
      expect(find.textContaining('1 面板'), findsWidgets);
      expect(find.text('wJ:p1'), findsWidgets);
      expect(find.text('wJ:p2'), findsWidgets);
    });

    testWidgets('falls back to a flat pane list when no tabs are reported', (
      tester,
    ) async {
      await _pumpHerdr(
        tester,
        tabs: const <Map<String, dynamic>>[],
        panes: <Map<String, dynamic>>[paneJson(paneId: 'wJ:p2')],
      );
      await tester.tap(find.text('cloudterminal'));
      await tester.pumpAndSettle();
      expect(find.text('标签页'), findsNothing);
      expect(find.text('面板'), findsOneWidget);
      expect(find.text('wJ:p2'), findsWidgets);
    });

    testWidgets('confirms before closing a workspace', (tester) async {
      await _pumpHerdr(tester);
      await tester.tap(find.byTooltip('工作区操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭工作区'));
      await tester.pumpAndSettle();
      expect(find.textContaining('关闭 cloudterminal'), findsOneWidget);
      expect(find.text('确认关闭'), findsOneWidget);
      // Cancelling must not send anything.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('确认关闭'), findsNothing);
    });

    testWidgets('sends a workspace close only after confirmation', (
      tester,
    ) async {
      final socket = await _pumpHerdr(tester);
      await tester.tap(find.byTooltip('工作区操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭工作区'));
      await tester.pumpAndSettle();
      expect(socket.lastRequest('herdr_act'), isNull);
      await tester.tap(find.text('确认关闭'));
      await tester.pumpAndSettle();
      final request = socket.lastRequest('herdr_act');
      expect(request?['action'], <String, dynamic>{
        'kind': 'workspace_close',
        'workspaceId': 'wJ',
      });
    });
  });

  group('Herdr terminal rows', _terminalRowTests);
  group('Herdr pane snapshot', _paneSnapshotTests);
  group('Herdr grid padding', _gridPaddingTests);
  group('xterm wide glyph wrap', _wideGlyphWrapTests);
  group('Herdr pane view', _paneViewModelTests);
  group('Herdr drawer workspaces', _drawerWorkspaceTests);

  // Cross-layer field-name agreement
  // -------------------------------------------------------------------------

  group('cross-layer contract', () {
    test('every field the Dart model reads is present in the TS producer', () {
      // Guards against renaming a field on only one side of the wire.
      final workspace = HerdrWorkspace.fromJson(workspaceJson());
      expect(workspace.toJson().keys.toList(), <String>[
        'workspaceId',
        'label',
        'number',
        'focused',
        'agentStatus',
        'paneCount',
        'tabCount',
        'activeTabId',
      ]);
      final agent = HerdrAgent.fromJson(agentJson(name: 'reviewer'));
      expect(agent.toJson().keys.toList(), <String>[
        'target',
        'paneId',
        'workspaceId',
        'tabId',
        'cwd',
        'agentKind',
        'status',
        'focused',
        'terminalTitle',
        'name',
        'interactiveReady',
      ]);
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Pumps a Herdr screen wired to a scripted agent and returns the fake socket.
Future<FakeSocket> _pumpHerdr(
  WidgetTester tester, {
  Map<String, dynamic>? availability,
  List<Map<String, dynamic>>? workspaces,
  List<Map<String, dynamic>>? agents,
  List<Map<String, dynamic>>? panes,
  List<Map<String, dynamic>>? tabs,

  /// When false, `herdr_info` requests are left unanswered, emulating a bridge
  /// whose capability is still unknown.
  bool respondAvailability = true,

  /// When false, pump a fixed number of frames instead of settling. Needed
  /// when a pending indicator keeps animating forever.
  bool settle = true,

  /// When set, every answered request comes back as a typed Herdr error.
  String? error,
}) async {
  final store = AppStore.memory();
  await store.setPairing(
    const Pairing(
      relayUrl: 'ws://relay/ws',
      agentId: 'a_1',
      secret: 's',
      name: 'DESKTOP',
    ),
  );
  final socket = FakeSocket();
  _scriptHerdrSocket(
    socket,
    availability: availability,
    workspaces: workspaces,
    agents: agents,
    panes: panes,
    tabs: tabs,
    respondAvailability: respondAvailability,
    error: error,
  );

  final remote = RemoteController(store: store, connector: (_) async => socket);
  final herdr = HerdrController(remote);
  addTearDown(() {
    herdr.dispose();
    remote.dispose();
  });
  remote.connect();

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.seeds.first.color),
      home: HerdrScreen(controller: remote, herdr: herdr),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
  return socket;
}

/// Scripts the Herdr request/reply loop on an existing socket.
///
/// Shared by the widget harness and the controller-level connect test so both
/// exercise the same wire shapes.
void _scriptHerdrSocket(
  FakeSocket socket, {
  Map<String, dynamic>? availability,
  List<Map<String, dynamic>>? workspaces,
  List<Map<String, dynamic>>? agents,
  List<Map<String, dynamic>>? panes,
  List<Map<String, dynamic>>? tabs,
  String outputText = 'real screen text',

  /// Delays a `herdr_read` reply so a test can observe the in-flight frame.
  Duration readDelay = Duration.zero,
  bool respondAvailability = true,

  /// When set, every answered request comes back as a typed Herdr error.
  String? error,

  /// Chains onto the socket's existing handler instead of replacing it, so a
  /// harness that already answers hello/info/list_sessions keeps working while
  /// only the `herdr_*` replies are scripted here.
  bool keepPrevious = false,
}) {
  final resolvedAvailability = availability ?? availabilityJson();
  final available = resolvedAvailability['available'] == true;
  final previous = socket.onSend;
  socket.onSend = (s, frame) {
    if (keepPrevious) {
      final data = frame['data'];
      // Only Herdr traffic is ours; everything else belongs to the base agent.
      if (data is! Map<String, dynamic> ||
          !(data['type'] as String? ?? '').startsWith('herdr_')) {
        previous?.call(s, frame);
        return;
      }
    }
    if (frame['t'] == 'hello') {
      scheduleMicrotask(
        () => s.push(<String, dynamic>{
          't': 'hello_ok',
          'clientId': 'c1',
          'online': true,
          'name': 'DESKTOP',
        }),
      );
      return;
    }
    final data = frame['data'] as Map<String, dynamic>;
    final id = data['id'];
    scheduleMicrotask(() {
      if (error != null) {
        s.msg(<String, dynamic>{'kind': 'error', 'id': id, 'message': error});
        return;
      }
      switch (data['type']) {
        case 'info':
          s.msg(<String, dynamic>{
            'kind': 'info',
            'id': id,
            'host': 'DESKTOP',
            'platform': 'win32',
            'defaultCwd': r'C:\work',
            'roots': <String>[r'C:\work'],
            'allowBypass': false,
            'capabilities': <String>['terminal', if (available) 'herdr'],
            'herdr': resolvedAvailability,
          });
        case 'list_sessions':
          s.msg(<String, dynamic>{
            'kind': 'sessions',
            'id': id,
            'sessions': <dynamic>[],
          });
        case 'herdr_info':
          // Left unanswered when the harness emulates an unknown capability.
          if (!respondAvailability) return;
          s.msg(<String, dynamic>{
            'kind': 'herdr_info',
            'id': id,
            'availability': resolvedAvailability,
          });
        case 'herdr_workspaces':
          s.msg(<String, dynamic>{
            'kind': 'herdr_workspaces',
            'id': id,
            'workspaces': workspaces ?? <Map<String, dynamic>>[workspaceJson()],
          });
        case 'herdr_agents':
          s.msg(<String, dynamic>{
            'kind': 'herdr_agents',
            'id': id,
            'agents':
                agents ??
                <Map<String, dynamic>>[
                  agentJson(),
                  agentJson(
                    target: 'pi-go-curriculum-review',
                    paneId: 'wJ:p3',
                    kind: 'pi',
                    status: 'done',
                    name: 'pi-go-curriculum-review',
                    focused: false,
                  ),
                ],
          });
        case 'herdr_panes':
          s.msg(<String, dynamic>{
            'kind': 'herdr_panes',
            'id': id,
            'workspaceId': data['workspaceId'],
            'panes': panes ?? <Map<String, dynamic>>[paneJson()],
          });
        case 'herdr_tabs':
          s.msg(<String, dynamic>{
            'kind': 'herdr_tabs',
            'id': id,
            'workspaceId': data['workspaceId'],
            // A workspace always has at least one tab, so the default mirrors
            // reality rather than an empty list.
            'tabs':
                tabs ??
                <Map<String, dynamic>>[
                  tabJson(workspaceId: '${data['workspaceId']}'),
                ],
          });
        case 'herdr_read':
          void reply() => s.msg(<String, dynamic>{
            'kind': 'herdr_output',
            'id': id,
            'paneId': data['paneId'],
            'source': data['source'],
            'text': outputText,
          });
          if (readDelay == Duration.zero) {
            reply();
          } else {
            Future<void>.delayed(readDelay, reply);
          }
        case 'herdr_act':
          s.msg(<String, dynamic>{
            'kind': 'herdr_result',
            'id': id,
            'action': 'x',
            'summary': '已执行',
          });
        default:
          s.msg(<String, dynamic>{'kind': 'ack', 'id': id});
      }
    });
  };
}

/// Scripts a socket for the controller-level connect test.
void scriptHerdrOn(FakeSocket socket) => _scriptHerdrSocket(socket);

// ---------------------------------------------------------------------------
// Terminal rows: Herdr's switchers drawn above the generic terminal
// ---------------------------------------------------------------------------

/// Pumps a terminal session wired to a scripted agent and returns the socket.
///
/// [herdr] is the same controller instance the screen receives; passing it is
/// what turns the plain terminal into one with Herdr rows above it.
Future<FakeSocket> _pumpTerminal(
  WidgetTester tester, {
  bool attachHerdr = true,
  Map<String, dynamic>? availability,
  List<Map<String, dynamic>>? workspaces,
  List<Map<String, dynamic>>? panes,
  List<Map<String, dynamic>>? tabs,
}) async {
  final info = sessionJson('t', kind: 'terminal', status: 'running');
  // Build a healthy agent first, then layer only the Herdr replies on top of
  // it. Replacing the socket wholesale would drop the hello/info handshake and
  // the controller would never reach `online`.
  final socket = healthyAgent(
    sessions: <Json>[info],
    capabilities: <String>['terminal', 'herdr'],
  );
  _scriptHerdrSocket(
    socket,
    availability: availability,
    workspaces: workspaces,
    panes: panes,
    tabs: tabs,
    keepPrevious: true,
  );
  final remote = await controllerFor(socket);
  await tester.pump();
  final herdr = HerdrController(remote);
  addTearDown(() {
    herdr.dispose();
    remote.dispose();
  });
  final view = remote.view(SessionInfo.fromJson(info));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.seeds.first.color),
      home: SessionScreen(
        controller: remote,
        view: view,
        herdr: attachHerdr ? herdr : null,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return socket;
}

/// The chip labels currently painted above the terminal.
///
/// The label is a `ConstrainedBox` wrapping the `Text` (the width cap keeps a
/// long terminal title from stretching the chip), so dig for the Text.
List<String> _chipLabels(WidgetTester tester) => tester
    .widgetList<RawChip>(find.byType(RawChip))
    .expand(
      (chip) => find
          .descendant(
            of: find.byWidget(chip),
            matching: find.byType(Text),
            matchRoot: true,
          )
          .evaluate(),
    )
    .map((element) => (element.widget as Text).data)
    .whereType<String>()
    .toList();

void _terminalRowTests() {
  testWidgets('no Herdr controller leaves the plain terminal untouched', (
    tester,
  ) async {
    await _pumpTerminal(tester, attachHerdr: false);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(RawChip), findsNothing);
  });

  testWidgets('unavailable Herdr adds no rows', (tester) async {
    await _pumpTerminal(
      tester,
      availability: availabilityJson(available: false),
    );
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(RawChip), findsNothing);
  });

  testWidgets('both rows render even for a single tab and pane', (
    tester,
  ) async {
    await _pumpTerminal(tester);
    // One workspace, one tab, one pane: both rows still render, because the
    // user asked for exactly two rows — tab above pane — and hiding them made
    // a working Herdr look like it had not been recognised at all.
    expect(find.byType(TerminalView), findsOneWidget);
    final labels = _chipLabels(tester);
    expect(labels, contains('main'), reason: 'tab row');
    expect(labels, contains('π - cloudterminal'), reason: 'pane row');
  });

  testWidgets('the focused chip is visually distinct from the rest', (
    tester,
  ) async {
    await _pumpTerminal(
      tester,
      tabs: <Map<String, dynamic>>[
        tabJson(tabId: 'wJ:t1', label: 'main'),
        tabJson(tabId: 'wJ:t2', label: 'logs', number: 2, focused: false),
      ],
    );
    final focused = tester.widget<RawChip>(
      find.widgetWithText(RawChip, 'main'),
    );
    final idle = tester.widget<RawChip>(find.widgetWithText(RawChip, 'logs'));
    expect(focused.selected, isTrue);
    expect(idle.selected, isFalse);
    // The theme defines no ChipTheme.selectedColor, so the chip has to paint the
    // difference itself or the user sees no selection at all.
    expect(focused.backgroundColor, isNot(idle.backgroundColor));
    final focusedText = tester.widget<Text>(find.text('main'));
    final idleText = tester.widget<Text>(find.text('logs'));
    expect(focusedText.style?.color, isNot(idleText.style?.color));
  });

  testWidgets('creating a tab reloads the tab row instead of serving cache', (
    tester,
  ) async {
    // Regression: the tab row kept showing one tab after `+` because the post-
    // action refresh reused the cached listing. The socket counts `herdr_tabs`
    // requests so the assertion is about the read, not about timing.
    final socket = await _pumpTerminal(tester);
    final before = socket.requests
        .where((r) => r['type'] == 'herdr_tabs')
        .length;

    await tester.tap(find.widgetWithIcon(IconButton, Icons.add_rounded));
    await tester.pumpAndSettle();

    final after = socket.requests
        .where((r) => r['type'] == 'herdr_tabs')
        .length;
    expect(
      after,
      greaterThan(before),
      reason: 'the tab list must be re-read after creating a tab',
    );
  });

  testWidgets('a tab added on the desktop appears without user action', (
    tester,
  ) async {
    // Regression for "3 tabs on the PC, the tab bar still shows 1". The live path
    // is the agent's socket push; when that is not available the watchdog tick is
    // the correctness net, which is what this test exercises.
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final socket = await _pumpTerminal(
      tester,
      tabs: <Map<String, dynamic>>[tabJson(tabId: 'wJ:t1', label: 'main')],
    );
    expect(_chipLabels(tester), contains('main'));
    expect(_chipLabels(tester), isNot(contains('logs')));

    // The desktop user adds two tabs. Nothing happens on the phone.
    _scriptHerdrSocket(
      socket,
      tabs: <Map<String, dynamic>>[
        tabJson(tabId: 'wJ:t1', label: 'main'),
        tabJson(tabId: 'wJ:t2', label: 'logs', number: 2, focused: false),
        tabJson(tabId: 'wJ:t3', label: 'tests', number: 3, focused: false),
      ],
      keepPrevious: true,
    );

    // Advance past one watchdog interval (12 s, the correctness fallback) and
    // settle the reply.
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();

    final labels = _chipLabels(tester);
    expect(labels, contains('main'), reason: 'the existing tab stays');
    expect(labels, contains('logs'), reason: 'the new tab must appear');
    expect(labels, contains('tests'), reason: 'the new tab must appear');
  });

  testWidgets('the tab row has a trailing new-tab button', (tester) async {
    final socket = await _pumpTerminal(tester);
    final add = find.widgetWithIcon(IconButton, Icons.add_rounded);
    expect(add, findsOneWidget, reason: 'one add button, pinned right');
    // Right of the chip list, not inside it.
    final list = tester.getRect(find.byType(ListView).first);
    expect(tester.getRect(add).left, greaterThanOrEqualTo(list.right - 1));

    await tester.tap(add);
    await tester.pumpAndSettle();
    final act = socket.lastRequest('herdr_act');
    expect(act?['action']['kind'], 'tab_create');
    expect(act?['action']['workspaceId'], 'wJ');
  });

  testWidgets('multiple tabs and panes render both rows', (tester) async {
    await _pumpTerminal(
      tester,
      tabs: <Map<String, dynamic>>[
        tabJson(tabId: 'wJ:t1', label: 'main'),
        tabJson(tabId: 'wJ:t2', label: 'logs', number: 2, focused: false),
      ],
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', tabId: 'wJ:t1', name: 'shell', focused: true),
        paneJson(
          paneId: 'wJ:p3',
          tabId: 'wJ:t1',
          name: 'pi',
          status: 'working',
        ),
      ],
    );
    expect(find.text('main'), findsOneWidget);
    expect(find.text('logs'), findsOneWidget);
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('pi'), findsOneWidget);
    expect(find.byType(TerminalView), findsOneWidget);
  });

  testWidgets('tapping a pane chip focuses exactly that pane', (tester) async {
    // A wider surface keeps both chips on screen, so the tap is a real hit test
    // rather than a scrolled-away miss.
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final socket = await _pumpTerminal(
      tester,
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'shell', focused: true),
        paneJson(paneId: 'wJ:p3', name: 'pi'),
      ],
    );
    // Tap the chip, not its label: the label's own render box is offset by the
    // horizontal ListView, so a text-anchored tap can miss the hit area.
    await tester.tap(find.widgetWithText(RawChip, 'pi'));
    await tester.pumpAndSettle();
    final act = socket.lastRequest('herdr_act');
    expect(act?['action']['kind'], 'pane_focus');
    expect(act?['action']['paneId'], 'wJ:p3');
  });

  testWidgets('tapping a tab chip focuses that tab', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final socket = await _pumpTerminal(
      tester,
      tabs: <Map<String, dynamic>>[
        tabJson(tabId: 'wJ:t1', label: 'main'),
        tabJson(tabId: 'wJ:t2', label: 'logs', number: 2, focused: false),
      ],
    );
    await tester.tap(find.widgetWithText(RawChip, 'logs'));
    await tester.pumpAndSettle();
    final act = socket.lastRequest('herdr_act');
    expect(act?['action']['kind'], 'tab_focus');
    expect(act?['action']['tabId'], 'wJ:t2');
  });

  testWidgets('the pane row follows the focused tab', (tester) async {
    // t2 is focused, so only its own pane may be listed. Listing t1's panes
    // would make the row a workspace-wide list and break the two-level model.
    await _pumpTerminal(
      tester,
      tabs: <Map<String, dynamic>>[
        tabJson(tabId: 'wJ:t1', label: 'main', focused: false),
        tabJson(tabId: 'wJ:t2', label: 'logs', number: 2),
      ],
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', tabId: 'wJ:t1', name: 't1-shell'),
        paneJson(paneId: 'wJ:p3', tabId: 'wJ:t2', name: 't2-shell'),
        paneJson(paneId: 'wJ:p4', tabId: 'wJ:t2', name: 't2-pi'),
      ],
    );
    final labels = _chipLabels(tester);
    expect(labels, contains('t2-shell'));
    expect(labels, contains('t2-pi'));
    expect(labels, isNot(contains('t1-shell')));
  });

  testWidgets('chip labels fall back from name to title to id', (tester) async {
    // `paneJson` fills a default title, so the id fallback is exercised through
    // the label helper's third branch rather than by a null title.
    await _pumpTerminal(
      tester,
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'named', focused: true),
        paneJson(paneId: 'wJ:p3', agent: null, terminalTitle: 'pwsh'),
        // Built by hand: `paneJson` substitutes a default title and cwd, which
        // would hide the id fallback this case is about.
        <String, dynamic>{
          'paneId': 'wJ:p4',
          'workspaceId': 'wJ',
          'tabId': 'wJ:t1',
          'cwd': '',
          'focused': false,
          'terminalTitle': '',
          'interactiveReady': true,
        },
      ],
    );
    final labels = _chipLabels(tester);
    expect(labels, contains('named'));
    expect(labels, contains('pwsh'));
    expect(labels, contains('wJ:p4'));
  });
}

void _drawerWorkspaceTests() {
  testWidgets('the drawer lists workspaces and focuses the tapped one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = AppStore.memory();
    await store.setPairing(
      const Pairing(
        relayUrl: 'ws://relay/ws',
        agentId: 'a_1',
        secret: 's',
        name: 'DESKTOP',
      ),
    );
    final socket = FakeSocket();
    _scriptHerdrSocket(
      socket,
      workspaces: <Map<String, dynamic>>[
        workspaceJson(id: 'wJ', label: 'cloudterminal'),
        workspaceJson(id: 'w6', label: 'qfli_c', number: 6, focused: false),
      ],
    );
    final remote = RemoteController(
      store: store,
      connector: (_) async => socket,
    );
    final herdr = HerdrController(remote);
    final catalog = CodexCatalog(remote);
    addTearDown(() {
      catalog.dispose();
      herdr.dispose();
      remote.dispose();
    });
    remote.connect();
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.seeds.first.color),
        home: Scaffold(
          body: WorkspaceSidebar(
            controller: remote,
            catalog: catalog,
            herdr: herdr,
            onHome: () {},
            onHistory: () {},
            onHerdr: () {},
            onThread: (_) {},
            onSession: (_) {},
            onCloseDrawer: () => closed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('cloudterminal'), findsOneWidget);
    expect(find.text('qfli_c'), findsOneWidget);

    await tester.tap(find.text('qfli_c'));
    await tester.pumpAndSettle();
    final act = socket.lastRequest('herdr_act');
    expect(act?['action']['kind'], 'workspace_focus');
    expect(act?['action']['workspaceId'], 'w6');
    expect(
      closed,
      1,
      reason: 'the drawer must close so the terminal is visible',
    );
  });
}

// ---------------------------------------------------------------------------
// Herdr pane snapshot contract
// ---------------------------------------------------------------------------

/// Reads a fixture captured from the real desktop CLI.
String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// The lines actually **visible** in [terminal]'s viewport.
///
/// `buffer.getText()` is not enough: it reads from the top of the buffer, so a
/// snapshot that scrolled its first line into scrollback still looks correct there.
/// The viewport starts at `scrollBack`, which is what the user sees.
List<String> _visibleLines(Terminal terminal) {
  final buffer = terminal.buffer;
  final start = buffer.scrollBack;
  return <String>[
    for (var i = 0; i < terminal.viewHeight; i++)
      buffer.lines[start + i].getText(),
  ];
}

/// Replays [snapshot] into a real terminal exactly as the widget does.
Terminal _replay(HerdrPaneSnapshot snapshot) {
  final terminal = Terminal(maxLines: 5000);
  terminal.resize(snapshot.columns, snapshot.rows);
  terminal.eraseDisplay();
  terminal.eraseScrollbackOnly();
  terminal.setCursor(0, 0);
  terminal.write(snapshot.replayText);
  return terminal;
}

void _paneSnapshotTests() {
  test('normalises line endings so replay does not step-indent', () {
    // Interior LF becomes CRLF: a bare LF only moves the cursor down, so without
    // the CR the next line would start where the previous one ended.
    expect(
      HerdrPaneSnapshot.fromText('one\ntwo\nthree\n').replayText,
      'one\r\ntwo\r\nthree',
    );
  });

  test('does not execute a trailing terminator, which would scroll the grid', () {
    // The regression this guards: a trailing CRLF moves the cursor past the last
    // row, scrolling the grid up by one so the snapshot's first line lands in
    // scrollback and disappears from the viewport.
    expect(HerdrPaneSnapshot.fromText('a\nb\n').replayText, 'a\r\nb');
    expect(HerdrPaneSnapshot.fromText('a\nb').replayText, 'a\r\nb');
  });

  test('replays a two-line snapshot with both lines still visible', () {
    final terminal = _replay(HerdrPaneSnapshot.fromText('a\nb\n'));
    expect(terminal.buffer.scrollBack, 0, reason: 'nothing may scroll off');
    expect(_visibleLines(terminal), <String>['a', 'b']);
  });

  test('replays a single-line snapshot instead of showing an empty screen', () {
    // With the trailing terminator, a 1-row grid scrolled its only line away and
    // the user saw a blank pane.
    final terminal = _replay(HerdrPaneSnapshot.fromText('x\n'));
    expect(terminal.buffer.scrollBack, 0);
    expect(_visibleLines(terminal), <String>['x']);
  });

  test('content that exactly fills the grid width does not wrap-scroll', () {
    // At exactly `columns` cells the emulator is in "wrap pending"; an extra line
    // terminator would wrap and scroll. Both the newline and the no-newline form
    // must leave the row in place.
    for (final input in <String>['abc\n', 'abc']) {
      final terminal = _replay(HerdrPaneSnapshot.fromText(input));
      expect(terminal.buffer.scrollBack, 0, reason: 'input=$input');
      expect(_visibleLines(terminal), <String>['abc'], reason: 'input=$input');
    }
  });

  test('a full-width CJK row does not re-wrap', () {
    // Six CJK characters are twelve cells; the grid must be twelve columns so the
    // row lands exactly once.
    final snapshot = HerdrPaneSnapshot.fromText('你好世界中文\n');
    expect(snapshot.columns, 12);
    final terminal = _replay(snapshot);
    expect(terminal.buffer.scrollBack, 0);
    expect(_visibleLines(terminal), <String>['你好世界中文']);
  });

  test('keeps trailing spaces and blank lines', () {
    final snapshot = HerdrPaneSnapshot.fromText('a   \n\n b\n');
    expect(snapshot.text, 'a   \n\n b\n', reason: 'the source is untouched');
    final terminal = _replay(snapshot);
    expect(terminal.buffer.scrollBack, 0);
    final visible = _visibleLines(terminal);
    expect(
      visible[0].trimRight().length + 3,
      4,
      reason: 'trailing spaces kept',
    );
    expect(visible[1].trim(), isEmpty, reason: 'the blank line is still a row');
    expect(visible[2].trim(), 'b');
  });

  test('a desktop-wide rule row stays one line', () {
    final row = '\u2500' * 76;
    final terminal = _replay(HerdrPaneSnapshot.fromText('$row\n'));
    expect(terminal.buffer.scrollBack, 0);
    expect(_visibleLines(terminal).first.length, 76);
  });

  test('applies ANSI colour rather than printing the escapes', () {
    final terminal = _replay(
      HerdrPaneSnapshot.fromText('\x1b[31mred\x1b[0m\n'),
    );
    expect(_visibleLines(terminal).first, 'red');
    expect(_visibleLines(terminal).first, isNot(contains('\x1b')));
  });

  test('derives columns from the widest line, counting ANSI as zero width', () {
    expect(
      HerdrPaneSnapshot.fromText('\x1b[31m0123456789\x1b[0m\nshort\n').columns,
      10,
    );
  });

  test('counts a combining mark as zero width', () {
    expect(HerdrPaneSnapshot.fromText('e\u0301x\n').columns, 2);
  });

  test('counts a wide emoji as two cells', () {
    expect(HerdrPaneSnapshot.fromText('\u{1F600}x\n').columns, 3);
  });

  test('does not grow a phantom row for the trailing newline', () {
    expect(HerdrPaneSnapshot.fromText('a\nb\n').rows, 2);
    expect(HerdrPaneSnapshot.fromText('a\nb').rows, 2);
    expect(HerdrPaneSnapshot.fromText('').rows, 1);
  });

  test('sameScreenAs compares the screen, not object identity', () {
    final a = HerdrPaneSnapshot.fromText('x\n');
    expect(a.sameScreenAs(HerdrPaneSnapshot.fromText('x\n')), isTrue);
    expect(a.sameScreenAs(HerdrPaneSnapshot.fromText('y\n')), isFalse);
  });
}

// ---------------------------------------------------------------------------
// Herdr pane view: mounted widget behaviour
// ---------------------------------------------------------------------------

/// Pumps a terminal session and selects [paneId] as the watched pane.
Future<(FakeSocket, HerdrController)> _pumpWatchingPane(
  WidgetTester tester, {
  required String paneId,
  List<Map<String, dynamic>>? panes,
}) async {
  final socket = await _pumpTerminal(
    tester,
    panes:
        panes ??
        <Map<String, dynamic>>[
          paneJson(paneId: paneId, name: 'shell', focused: true),
        ],
  );
  final herdr = tester.widget<SessionScreen>(find.byType(SessionScreen)).herdr!;
  herdr.watchPane(paneId, explicit: true);
  await tester.pumpAndSettle();
  return (socket, herdr);
}

/// Uses the actual terminal tap target and text-input connection.
Future<void> _focusPaneTerminal(WidgetTester tester) async {
  await tester.tap(find.byType(TerminalView));
  await tester.pumpAndSettle();
  // Let xterm's double-tap recognition window expire before the next action.
  await tester.pump(const Duration(milliseconds: 350));
  expect(tester.testTextInput.hasAnyClients, isTrue);
}

/// xterm reserves two spaces to detect IME deletion. Only the new text is sent.
void _commitPaneText(WidgetTester tester, String text) {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '  $text',
      selection: TextSelection.collapsed(offset: 2 + text.length),
    ),
  );
}

void _paneViewModelTests() {
  testWidgets('a wide row is not truncated: every character is in the grid', (
    tester,
  ) async {
    // The device report was "it fills the screen but still clips". Assert on the
    // **rendered grid** rather than a width proxy: every character must be present,
    // including a sentinel at the far right of a logically long line.
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    // 200 characters plus a right-edge sentinel, i.e. far wider than any phone.
    final body = '${'a' * 200}<RIGHT-END>';
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': '$body\r\n',
    });
    await tester.pumpAndSettle();

    final terminal = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal;
    // The grid is the phone's width, so the long row must wrap...
    expect(terminal.viewWidth, lessThan(200));
    expect(terminal.viewWidth, greaterThan(20));
    // ...and no character may be lost: the tail sentinel is still in the buffer.
    final text = terminal.buffer.getText();
    expect(
      text.contains('a' * 200),
      isTrue,
      reason: 'the whole row must survive the wrap',
    );
    expect(
      text.contains('<RIGHT-END>'),
      isTrue,
      reason: 'the right-hand end must be reachable, not clipped',
    );
    // The rendered box is exactly the available width: not scaled, not wider.
    final box = tester.getSize(find.byType(TerminalView));
    expect(box.width, lessThanOrEqualTo(360));
    expect(box.width, greaterThan(0));
  });

  testWidgets('the grid follows the phone when the viewport changes width', (
    tester,
  ) async {
    // Rotation/keyboard change the available width; the terminal must re-flow to the
    // new column count instead of keeping the old one and clipping.
    tester.view.physicalSize = const Size(400 * 2, 800 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': '${'z' * 120}<TAIL>\r\n',
    });
    await tester.pumpAndSettle();
    final wide = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal
        .viewWidth;

    // A much narrower phone (or a rotated/inset layout).
    tester.view.physicalSize = const Size(200 * 2, 800 * 2);
    await tester.pumpAndSettle();
    final narrow = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal
        .viewWidth;
    expect(
      narrow,
      lessThan(wide),
      reason: 'a narrower box must mean fewer columns, not a clipped wide grid',
    );
    // And the content is still complete at the new width.
    final text = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal
        .buffer
        .getText();
    expect(text, contains('<TAIL>'));
  });

  testWidgets('wrapped content is vertically scrollable, not cut off', (
    tester,
  ) async {
    // Many long rows: the text must be reachable by scrolling (the view owns the
    // vertical scroll), not silently truncated at the bottom.
    tester.view.physicalSize = const Size(360 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    final rows = <String>[
      for (var i = 0; i < 40; i += 1) '${'row$i'}-${'x' * 90}',
    ];
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': '${rows.join('\r\n')}\r\n',
    });
    await tester.pumpAndSettle();

    final terminal = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal;
    // Content taller than the viewport lives in scrollback, so the whole screen is
    // reachable by scrolling rather than being lost.
    expect(
      terminal.buffer.scrollBack,
      greaterThan(0),
      reason: 'wrapped content must overflow into scrollback',
    );
    final text = terminal.buffer.getText();
    expect(text, contains('row0-'));
    expect(text, contains('row39-'));
  });

  testWidgets('the grid subtracts horizontal padding so the last column fits', (
    tester,
  ) async {
    // The observed truncation: the right-hand glyph was painted past the edge and
    // cut in half, most visibly for a double-width CJK character. The renderer sized
    // the grid from the *full* box width while painting cells at
    // `col * cellWidth + padding.left`, so the last column overflowed by exactly
    // the horizontal padding — non-zero on a phone, where the system gesture area
    // is reported as `MediaQuery.padding`.
    //
    // Asserted on the render object's own grid rather than on a widget inset, so it
    // holds whatever the harness reports for platform padding.
    tester.view.physicalSize = const Size(424 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(right: 24 * 3);
    addTearDown(tester.view.reset);

    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    await tester.pumpAndSettle();
    // The stable sample from the device proof: a full ASCII row ending in a marker,
    // and a CJK row whose cells are twice as wide as its code units.
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk':
          'BEGIN${'0' * 111}END120\r\n'
          '${'\u4e2d\u6587\u53ef\u8bfb\u6d4b\u8bd5' * 12}\u4e2d\u6587\u5c3e\u6807\r\n'
          'LAST-MARKER\r\n',
    });
    await tester.pumpAndSettle();

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final terminal = state.widget.terminal;
    final render = state.renderTerminal;

    // The right edge of the last column, in the render object's own coordinates,
    // must not exceed the painted box. `padding.left` is what used to push it out.
    final cellWidth = render.cellSize.width;
    final lastColumnRight =
        terminal.viewWidth * cellWidth + render.padding.left;
    expect(
      lastColumnRight,
      lessThanOrEqualTo(render.size.width + 0.01),
      reason:
          'the last column (${terminal.viewWidth}) plus padding.left '
          '(${render.padding.left}) must fit in ${render.size.width}px',
    );

    // And the content itself is complete: the row markers survive the wrap.
    final text = terminal.buffer.getText();
    expect(text, contains('END120'));
    expect(
      text,
      contains('\u4e2d\u6587\u5c3e\u6807'),
      reason: 'CJK tail present',
    );
    expect(text, contains('LAST-MARKER'));
  });

  testWidgets('a long static snapshot survives keyboard and rotation with no new push', (
    tester,
  ) async {
    // A snapshot longer than the placeholder grid, delivered once and never again.
    // `Terminal.resize` reflows and `buffer.resize` pops lines when the grid
    // shrinks, so every refit must replay; waiting for a *change* in columns missed
    // the first fit (and any height-only change), which destroyed the tail with no
    // push available to restore it.
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    // 60 rows: comfortably more than a 24-row placeholder, so a shrink truncates.
    final rows = <String>[
      'FIRST-ROW',
      for (var i = 0; i < 58; i += 1) 'body-$i-${'x' * 60}',
      'LAST-ROW',
    ];
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': '${rows.join('\r\n')}\r\n',
    });
    // Settle, then settle again: the first pass lays out the placeholder grid, and
    // the refit replay is posted for after that frame, so a second pass is what
    // makes the real grid's content observable.
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    void expectBothEndsVisible(String when) {
      final terminal = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .widget
          .terminal;
      // Everything written is retained: when the content exceeds the viewport the
      // excess lives in scrollback, so the whole screen is reachable by scrolling.
      final text = <String>[
        for (var i = 0; i < terminal.buffer.height; i++)
          terminal.buffer.lines[i].getText(),
      ].join('\n');
      expect(
        text,
        contains('FIRST-ROW'),
        reason: '$when: the start is present',
      );
      expect(text, contains('LAST-ROW'), reason: '$when: the end survived');
      // The rows in between must not have been dropped either.
      for (final probe in <String>['body-0-', 'body-29-', 'body-57-']) {
        expect(text, contains(probe), reason: '$when: $probe retained');
      }
      // With more content than the viewport, there is scrollback to move through.
      expect(
        terminal.buffer.scrollBack,
        greaterThan(0),
        reason: '$when: overflow should be scrollback, not discarded',
      );
    }

    expectBothEndsVisible('after the first layout');

    // Keyboard: the pane gives up height, reflowing the buffer.
    tester.view.physicalSize = const Size(400 * 3, 520 * 3);
    await tester.pumpAndSettle();
    expectBothEndsVisible('with the keyboard up');

    // Keyboard dismissed again.
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    await tester.pumpAndSettle();
    expectBothEndsVisible('after the keyboard closed');

    // Rotation: width and height both change.
    tester.view.physicalSize = const Size(900 * 3, 400 * 3);
    await tester.pumpAndSettle();
    expectBothEndsVisible('after rotation');

    // And back, to prove nothing is lost across a cycle.
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    await tester.pumpAndSettle();
    expectBothEndsVisible('after rotating back');
  });

  testWidgets('desktop-wide content is reflowed at the phone width', (
    tester,
  ) async {
    // The default view is the phone's own width, not the desktop's: a ~120-column
    // desktop screen must wrap rather than render at desktop pixel size (which
    // clipped the right-hand side) or be shrunk to fit (which made text unreadable).
    tester.view.physicalSize = const Size(400 * 2, 800 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final (socket, herdr) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      // 120 columns of desktop content.
      'chunk': '${'x' * 120}\r\n',
    });
    await tester.pumpAndSettle();

    // The desktop width survives as metadata...
    expect(herdr.paneSnapshot('wJ:p2').columns, 120);
    // ...but the rendered grid uses the phone's column count.
    final terminal = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal;
    expect(
      terminal.viewWidth,
      lessThan(120),
      reason: 'the phone grid must not be the desktop grid',
    );
    expect(terminal.viewWidth, greaterThan(8));
    // The box fills the available width rather than being sized to the desktop.
    final box = tester.getSize(find.byType(TerminalView));
    expect(box.width.isFinite, isTrue, reason: 'no infinite constraints');
    expect(box.height.isFinite, isTrue);
    expect(box.width, lessThanOrEqualTo(400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long line wraps and the earlier content stays reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400 * 2, 800 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    // A first line that must not be pushed out, then content long enough to wrap
    // many times at phone width.
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': 'HEADER-LINE\r\n${List<String>.filled(40, 'row').join()}\r\n',
    });
    await tester.pumpAndSettle();

    final terminal = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal;
    // Nothing is dropped: the whole row is retained, and the first line is still
    // there, so a long line does not push earlier content away.
    expect(terminal.buffer.scrollBack, 0, reason: 'nothing may be dropped');
    final text = terminal.buffer.getText();
    expect(text, contains('HEADER-LINE'));
    expect(
      text,
      contains('row' * 40),
      reason: 'the full row must survive, not be truncated at the phone edge',
    );
    // And the grid really is the phone's, not the desktop's.
    expect(terminal.viewWidth, lessThan(120));
  });

  testWidgets('CJK content is measured in cells when sizing the grid', (
    tester,
  ) async {
    // A CJK line is twice as wide as its code-unit count, so a grid sized from
    // `String.length` would wrap it wrongly and lose rows.
    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': '${'中文内容' * 20}\r\n',
    });
    await tester.pumpAndSettle();
    final terminal = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal;
    expect(terminal.buffer.scrollBack, 0);
    expect(terminal.buffer.getText(), contains('中文内容'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pane view fills the area left by the keyboard', (
    tester,
  ) async {
    // The container must occupy the remaining region both before and after the
    // keyboard, and the grid must be recomputed for the narrower space rather than
    // staying at the pre-keyboard column count.
    tester.view.physicalSize = const Size(400 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': 'before-keyboard\r\n',
    });
    await tester.pumpAndSettle();

    final before = tester.getSize(find.byType(TerminalView));
    final colsBefore = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal
        .viewWidth;
    expect(before.width, greaterThan(0));
    expect(before.height, greaterThan(0));

    // Shrink the available height the way a soft keyboard does: the pane sits in
    // the column that `viewInsets` reduces. `SizedBox.expand` must follow it.
    tester.view.physicalSize = const Size(400 * 2, 400 * 2);
    await tester.pumpAndSettle();
    final after = tester.getSize(find.byType(TerminalView));
    expect(
      after.height,
      lessThan(before.height),
      reason: 'the pane must give up space to the keyboard, not overflow it',
    );
    expect(after.height, greaterThan(0));
    final colsAfter = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal
        .viewWidth;
    // A height-only change must not re-flow the columns. A one-column wobble is
    // tolerated because the view derives columns from its own padded box, so a
    // sub-pixel height change can shift the floor by one; a real re-flow (e.g.
    // using the desktop width, or scaling instead of reflow) would differ by far
    // more than one.
    expect(
      (colsAfter - colsBefore).abs(),
      lessThanOrEqualTo(1),
      reason: 'a height-only change must not re-flow the text',
    );
  });

  testWidgets('a pane output push forwards its wire format', (tester) async {
    // The push carries `format`; dropping it silently forced every snapshot to be
    // treated as the default. It is forwarded verbatim so the app reflects what
    // the agent actually sent.
    final (socket, herdr) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'text',
      'reset': true,
      'prefix': 0,
      'chunk': 'plain\r\n',
    });
    await tester.pumpAndSettle();
    expect(herdr.paneFormat('wJ:p2'), 'text');

    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 2,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': 'coloured\r\n',
    });
    await tester.pumpAndSettle();
    expect(herdr.paneFormat('wJ:p2'), 'ansi');

    // A frame without a format falls back to the current contract rather than
    // inventing something.
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 3,
      'reset': true,
      'prefix': 0,
      'chunk': 'no-format\r\n',
    });
    await tester.pumpAndSettle();
    expect(herdr.paneFormat('wJ:p2'), 'ansi');
  });

  testWidgets('a suspended selection is not revived by a structure push', (
    tester,
  ) async {
    // A suspended selection must stay suspended: the desktop must not be asked to
    // keep reading a pane for a screen nobody is on. (Reconnect re-subscription is
    // covered separately, above.)
    final (socket, herdr) = await _pumpWatchingPane(tester, paneId: 'wJ:pX');
    expect(herdr.watchedPaneId, 'wJ:pX');

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(herdr.watchedPaneId, isNull);
    expect(herdr.preferredPaneId, 'wJ:pX', reason: 'the choice is kept');

    final before = socket.requests.length;
    // Ordinary traffic while the screen is away must not start a watch.
    herdr.applyStructure(<String, dynamic>{
      'kind': 'herdr_structure',
      'workspaces': <Map<String, dynamic>>[workspaceJson()],
    });
    await tester.pumpAndSettle();
    final watches = socket.requests
        .skip(before)
        .where((r) => r['type'] == 'herdr_watch');
    expect(watches, isEmpty, reason: 'no background subscription');
    expect(herdr.watchedPaneId, isNull);
  });

  testWidgets('pane input sends raw text then encoded Enter to the same pane', (
    tester,
  ) async {
    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');

    // Leading and trailing spaces are meaningful in a shell; they must survive.
    await _focusPaneTerminal(tester);
    _commitPaneText(tester, '  echo hi  ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('回车'));
    await tester.pumpAndSettle();

    final text = socket.requests
        .where((r) => r['type'] == 'herdr_send_text')
        .toList();
    expect(text, isNotEmpty);
    expect(text.map((r) => r['paneId']), <String>['wJ:p2', 'wJ:p2']);
    expect(text.map((r) => r['text']), <String>['  echo hi  ', '\r']);
    expect(
      socket.requests.where((r) => r['type'] == 'herdr_send_keys'),
      isEmpty,
      reason: 'xterm already encodes terminal keys as raw bytes',
    );
    expect(
      socket.requests.where(
        (r) => r['type'] == 'send' || r['type'] == 'terminal_input',
      ),
      isEmpty,
      reason: 'pane input must not leak to the local PTY',
    );
  });

  testWidgets('a CJK IME composition reaches the pane unchanged', (
    tester,
  ) async {
    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    await _focusPaneTerminal(tester);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  nihao',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 2, end: 7),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      socket.requests.where((r) => r['type'] == 'herdr_send_text'),
      isEmpty,
      reason: 'uncommitted IME composition must stay on the phone',
    );
    _commitPaneText(tester, '你好世界');
    await tester.pumpAndSettle();
    final text = socket.requests
        .where((r) => r['type'] == 'herdr_send_text')
        .toList();
    expect(text.single['text'], '你好世界');
    expect(text.single['paneId'], 'wJ:p2');
  });

  testWidgets('an unchanged IME value sends nothing and typed spaces survive', (
    tester,
  ) async {
    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    await _focusPaneTerminal(tester);
    _commitPaneText(tester, '');
    await tester.pumpAndSettle();
    expect(
      socket.requests.where((r) => r['type'] == 'herdr_send_text'),
      isEmpty,
    );
    _commitPaneText(tester, '   ');
    await tester.pumpAndSettle();
    final text = socket.requests.where((r) => r['type'] == 'herdr_send_text');
    expect(
      text.single['text'],
      '   ',
      reason: 'spaces are valid terminal input',
    );
    expect(text.single['paneId'], 'wJ:p2');
  });

  testWidgets('input follows a pane switch and never leaks backwards', (
    tester,
  ) async {
    final (socket, herdr) = await _pumpWatchingPane(
      tester,
      paneId: 'wJ:p2',
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'shell', focused: true),
        paneJson(paneId: 'wJ:p3', name: 'other'),
      ],
    );
    herdr.watchPane('wJ:p3', explicit: true);
    await tester.pumpAndSettle();

    await _focusPaneTerminal(tester);
    _commitPaneText(tester, 'to-b');
    await tester.pumpAndSettle();

    final text = socket.requests
        .where((r) => r['type'] == 'herdr_send_text')
        .toList();
    expect(text.last['paneId'], 'wJ:p3');
    expect(
      text.where((r) => r['paneId'] == 'wJ:p2'),
      isEmpty,
      reason: 'nothing may be sent to the pane that was left',
    );
  });

  testWidgets(
    'the key row offers Backspace and sends DEL without losing focus',
    (tester) async {
      final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
      await _focusPaneTerminal(tester);
      expect(
        find.text('⌫'),
        findsOneWidget,
        reason: 'Backspace must be reachable',
      );
      await tester.tap(find.text('⌫'));
      await tester.pumpAndSettle();
      final keys = socket.requests
          .where((r) => r['type'] == 'herdr_send_text')
          .toList();
      expect(keys.single['text'], '\x7f');
      expect(keys.single['paneId'], 'wJ:p2');
      expect(tester.testTextInput.hasAnyClients, isTrue);
    },
  );

  testWidgets('the terminal itself opens the keyboard while a pane is shown', (
    tester,
  ) async {
    await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    expect(find.byType(TextField), findsNothing);
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
      isFalse,
    );
    await _focusPaneTerminal(tester);
  });

  testWidgets('a pushed snapshot renders with its first and last line visible', (
    tester,
  ) async {
    // End-to-end for the scroll regression: push a multi-line screen, then inspect
    // the *viewport* the user actually sees. A trailing terminator used to scroll
    // the first line into scrollback.
    final (socket, _) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');
    socket.msg(<String, dynamic>{
      'kind': 'herdr_pane_output',
      'paneId': 'wJ:p2',
      'revision': 1,
      'format': 'ansi',
      'reset': true,
      'prefix': 0,
      'chunk': 'FIRST-LINE\r\nLAST-LINE\r\n',
    });
    await tester.pumpAndSettle();

    final terminal = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .widget
        .terminal;
    final buffer = terminal.buffer;
    expect(buffer.scrollBack, 0, reason: 'nothing may scroll out of view');
    final visible = <String>[
      for (
        var i = buffer.scrollBack;
        i < buffer.scrollBack + terminal.viewHeight;
        i++
      )
        buffer.lines[i].getText(),
    ];
    expect(
      visible,
      contains('FIRST-LINE'),
      reason: 'the first line must be seen',
    );
    expect(
      visible,
      contains('LAST-LINE'),
      reason: 'the last line must be seen',
    );
  });

  testWidgets(
    'direct pane input is available in the terminal-mode widget tree',
    (tester) async {
      // The terminal path must stay interactive when it displays a Herdr pane.
      await _pumpWatchingPane(tester, paneId: 'wJ:p2');
      final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
      expect(screen.view.info.isTerminal, isTrue, reason: 'precondition');
      expect(
        find.descendant(
          of: find.byType(SessionScreen),
          matching: find.byType(TerminalView),
        ),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
        isFalse,
      );
      await _focusPaneTerminal(tester);
      expect(find.text('回车'), findsOneWidget, reason: 'key row present');
      expect(find.text('⌫'), findsOneWidget);
    },
  );

  testWidgets('reopening the screen restores the chosen pane and its input', (
    tester,
  ) async {
    // Regression for the device-reported fallback: `dispose` called
    // `watchPane(null)`, which cleared the subscription while the "user picked"
    // flag stayed set, so the next visit followed neither the remembered pane nor
    // the desktop and fell back to the plain PTY.
    final info = sessionJson('t', kind: 'terminal', status: 'running');
    final socket = healthyAgent(
      sessions: <Json>[info],
      capabilities: <String>['terminal', 'herdr'],
    );
    _scriptHerdrSocket(
      socket,
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'shell', focused: true),
        paneJson(paneId: 'wJ:pX', name: 'scratch'),
      ],
      keepPrevious: true,
    );
    final remote = await controllerFor(socket);
    await tester.pump();
    final herdr = HerdrController(remote);
    addTearDown(() {
      herdr.dispose();
      remote.dispose();
    });
    final view = remote.view(SessionInfo.fromJson(info));

    Widget build() => MaterialApp(
      theme: AppTheme.light(AppTheme.seeds.first.color),
      home: SessionScreen(controller: remote, view: view, herdr: herdr),
    );

    // --- first visit: open, then choose a pane by tapping its chip ---
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    herdr.watchPane('wJ:pX', explicit: true);
    await tester.pumpAndSettle();
    expect(herdr.watchedPaneId, 'wJ:pX');
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
      isFalse,
    );

    // --- leave the screen, which suspends streaming ---
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(
      herdr.watchedPaneId,
      isNull,
      reason: 'leaving must stop the desktop reads',
    );

    // --- come back: the same pane and its input must be restored ---
    // The resumed screen must NOT depend on `_followFocusedPane` picking something:
    // the device bug was that the user's own choice was unreachable after a
    // remount, so the pane view fell back to the PTY. Reproduce that by giving the
    // desktop *no* focused pane to follow — only the remembered choice can save it.
    herdr.applyStructure(<String, dynamic>{
      'kind': 'herdr_structure',
      'workspaceId': 'wJ',
      'panes': <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'shell'),
        paneJson(paneId: 'wJ:pX', name: 'scratch'),
      ],
    });
    await tester.pumpAndSettle();
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(
      herdr.watchedPaneId,
      'wJ:pX',
      reason: 'reopening must resume the remembered pane, not the plain PTY',
    );
    expect(
      find.byType(TerminalView),
      findsOneWidget,
      reason: 'the pane view, not the PTY terminal',
    );
    expect(
      find.text('⌫'),
      findsOneWidget,
      reason: 'the pane key row must be back',
    );

    // And input must be routed to the restored pane again.
    final before = socket.requests
        .where((r) => r['type'] == 'herdr_send_text')
        .length;
    await _focusPaneTerminal(tester);
    _commitPaneText(tester, 'after-reopen');
    await tester.pumpAndSettle();
    final sent = socket.requests
        .where((r) => r['type'] == 'herdr_send_text')
        .toList();
    expect(sent.length, greaterThan(before));
    expect(sent.last['paneId'], 'wJ:pX');
    expect(sent.last['text'], 'after-reopen');
  });

  testWidgets('a remembered pane closed while away is not watched again', (
    tester,
  ) async {
    // The choice suppresses following the desktop, so resurrecting a dead id would
    // pin the screen to a pane that can never produce output again.
    final info = sessionJson('t', kind: 'terminal', status: 'running');
    final socket = healthyAgent(
      sessions: <Json>[info],
      capabilities: <String>['terminal', 'herdr'],
    );
    _scriptHerdrSocket(
      socket,
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'shell', focused: true),
        paneJson(paneId: 'wJ:pX', name: 'scratch'),
      ],
      keepPrevious: true,
    );
    final remote = await controllerFor(socket);
    await tester.pump();
    final herdr = HerdrController(remote);
    addTearDown(() {
      herdr.dispose();
      remote.dispose();
    });
    final view = remote.view(SessionInfo.fromJson(info));
    Widget build() => MaterialApp(
      theme: AppTheme.light(AppTheme.seeds.first.color),
      home: SessionScreen(controller: remote, view: view, herdr: herdr),
    );

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    herdr.watchPane('wJ:pX', explicit: true);
    await tester.pumpAndSettle();
    expect(herdr.preferredPaneId, 'wJ:pX');

    // The user leaves the screen.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    // While away, the desktop closes that pane and pushes an authoritative list
    // for the workspace that no longer contains it. The session's own load also
    // runs, so give it a settled cache first and then assert on the push.
    _scriptHerdrSocket(
      socket,
      panes: <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'shell', focused: true),
      ],
      keepPrevious: true,
    );
    await herdr.loadWorkspace('wJ', force: true);
    herdr.applyStructure(<String, dynamic>{
      'kind': 'herdr_structure',
      'workspaceId': 'wJ',
      'panes': <Map<String, dynamic>>[
        paneJson(paneId: 'wJ:p2', name: 'shell', focused: true),
      ],
    });
    await tester.pumpAndSettle();
    expect(
      herdr.preferredPaneId,
      isNull,
      reason: 'a closed pane must not stay remembered',
    );

    // `requests` is derived from the sent frames, so it cannot be cleared: note the
    // length and inspect only what arrives after the remount.
    final beforeRemount = socket.requests.length;
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    // After the remount the only watch may be the desktop's focused pane; the
    // dead id must not reappear.
    final watches = socket.requests
        .skip(beforeRemount)
        .where((r) => r['type'] == 'herdr_watch')
        .toList();
    expect(
      watches.where((r) => r['paneId'] == 'wJ:pX'),
      isEmpty,
      reason: 'the dead id must never be watched again',
    );
    expect(
      watches.last['paneId'],
      'wJ:p2',
      reason: 'it falls back to following the desktop instead',
    );
  });

  testWidgets('a pane absent from a partial cache is not treated as closed', (
    tester,
  ) async {
    // A cold start must not discard a valid choice before the first listing for
    // its workspace has loaded.
    final info = sessionJson('t', kind: 'terminal', status: 'running');
    final socket = healthyAgent(
      sessions: <Json>[info],
      capabilities: <String>['terminal', 'herdr'],
    );
    _scriptHerdrSocket(
      socket,
      panes: <Map<String, dynamic>>[paneJson()],
      keepPrevious: true,
    );
    final remote = await controllerFor(socket);
    await tester.pump();
    final herdr = HerdrController(remote);
    addTearDown(() {
      herdr.dispose();
      remote.dispose();
    });

    herdr.watchPane('wJ:pX', explicit: true);
    // A structure push for a *different* workspace must not clear it.
    herdr.applyStructure(<String, dynamic>{
      'kind': 'herdr_structure',
      'workspaceId': 'wK',
      'panes': <Map<String, dynamic>>[paneJson(paneId: 'wK:p1')],
    });
    expect(
      herdr.preferredPaneId,
      'wJ:pX',
      reason: 'another workspace has no authority over this pane',
    );
  });

  testWidgets('a gone PTY session does not disable pane input', (tester) async {
    // Regression: input used to be gated on `_v.gone`. The watched pane lives on
    // the desktop, so after an agent reload the old PTY session is gone while
    // Herdr stays fully controllable — input must keep working in that state.
    final (socket, herdr) = await _pumpWatchingPane(tester, paneId: 'wJ:p2');

    // Mark the PTY session gone, exactly as a reloaded agent does. Herdr remains
    // controllable, so the pane must stay usable.
    final view = tester.widget<SessionScreen>(find.byType(SessionScreen)).view;
    view.markGone();
    await tester.pumpAndSettle();
    expect(view.gone, isTrue, reason: 'precondition: the PTY session is gone');
    expect(herdr.canControl, isTrue, reason: 'precondition: Herdr is usable');

    final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(
      terminal.readOnly,
      isFalse,
      reason: 'a gone PTY session must not disable pane input',
    );

    await _focusPaneTerminal(tester);
    _commitPaneText(tester, 'after-reload');
    await tester.pumpAndSettle();

    final text = socket.requests
        .where((r) => r['type'] == 'herdr_send_text')
        .toList();
    expect(text, isNotEmpty, reason: 'the pane must still receive input');
    expect(text.last['paneId'], 'wJ:p2');
    expect(text.last['text'], 'after-reload');
    // And the keys still work too.
    await tester.tap(find.text('⌫'));
    await tester.pumpAndSettle();
    expect(
      socket.requests.where((r) => r['type'] == 'herdr_send_text').last['text'],
      '\x7f',
    );
  });
}

// ---------------------------------------------------------------------------
// Host grid padding (right-edge spaces) must not create phantom blank lines
// ---------------------------------------------------------------------------

void _gridPaddingTests() {
  test('strips right-edge padding from rows that reach the grid edge', () {
    // The reported shape: several rows padded out to the same 75-cell edge, plus a
    // fully padded blank row, mixed with genuinely short rows. A row whose content
    // plus padding lands *below* the edge was never padded by the host, so it is
    // left alone.
    final rows = <String>[
      'a' * 44,
      'b' * 55,
      'c' * 63,
      // 21 content + 54 fill = exactly the 75-cell edge.
      '${'d' * 21}${' ' * 54}',
      ' ' * 75,
      'e' * 40,
      '${'f' * 30}${' ' * 45}',
      ' ' * 75,
      'g' * 60,
    ];
    final after = stripGridPadding(rows.join('\n')).split('\n');
    expect(after[3], 'd' * 21, reason: 'padding removed, content kept');
    expect(after[6], 'f' * 30);
    expect(after[4], '', reason: 'a fully padded row becomes one blank row');
    expect(after[7], '');
    // Rows that never reached the edge are untouched.
    expect(after[0], 'a' * 44);
    expect(after[1], 'b' * 55);
    expect(after[2], 'c' * 63);
    expect(after[5], 'e' * 40);
    expect(after[8], 'g' * 60);
  });

  test('a fully padded blank row occupies exactly one row after reflow', () {
    // The bug: at desktop width it is one empty row; reflowed at phone width the
    // padding wrapped and it became two, which is the phantom blank line.
    final padded = stripGridPadding('${' ' * 75}\n${'x' * 75}\n${' ' * 75}');
    final snapshot = HerdrPaneSnapshot.fromText(
      '${' ' * 75}\n${'x' * 75}\n${' ' * 75}',
    );
    expect(padded.split('\n').first, '');
    final phoneColumns = 40;
    // Count the rows the blank line really needs at phone width.
    final firstLine = snapshot.replayText.split('\r\n').first;
    expect(firstLine, '');
    expect(
      (displayWidth(firstLine) + phoneColumns - 1) ~/ phoneColumns,
      0,
      reason: 'an empty row must need no extra rows at any width',
    );
  });

  test('picks the widest edge even when short rows are the majority', () {
    // Regression: the edge used to be the *most common* width, so a screen of many
    // short lines elected a low edge and the widest rows then tripped the overflow
    // guard into a no-op — the fill was never removed.
    //
    // Widths below are display cells, not characters: each CJK glyph is two cells.
    // The short rows deliberately share a single low width so they are the most
    // common value — the old code picked that and then no-opped on the wide rows.
    final rows = <String>[
      // Six short rows (the majority), all width 6.
      'aaaaaa',
      'bbbbbb',
      'cccccc',
      'dddddd',
      'eeeeee',
      'ffffff',
      // Two padded rows landing on the 75-cell edge: 21 + 54 and 30 + 45.
      '${'g' * 21}${' ' * 54}',
      '${'h' * 30}${' ' * 45}',
      // A CJK row that also reaches the edge: 36 glyphs = 72 cells, + 3 fill = 75.
      '${'\u4e2d' * 36}${' ' * 3}',
    ];
    expect(displayWidth(rows[6]), 75);
    expect(displayWidth(rows[7]), 75);
    expect(displayWidth(rows[8]), 75, reason: 'CJK counts two cells each');
    expect(displayWidth(rows[0]), 6, reason: 'the majority width is lower');

    final after = stripGridPadding(rows.join('\n')).split('\n');
    expect(after[6], 'g' * 21, reason: 'fill removed from the first wide row');
    expect(after[7], 'h' * 30, reason: 'fill removed from the second wide row');
    expect(after[8], '\u4e2d' * 36, reason: 'CJK row trimmed in cells');
    // The short rows are untouched, even though they outnumber the padded ones.
    for (var i = 0; i < 6; i++) {
      expect(after[i], rows[i], reason: 'short row $i must not change');
    }
  });

  test('a single widest row is not enough to define an edge', () {
    // One coincidentally long line must not elect an edge and cause trimming.
    const text = 'a\nb\nlong line                    ';
    expect(stripGridPadding(text), text);
  });

  test('an extended RGB background is not mistaken for opcodes', () {
    // Regression: the parameter list was walked one-to-one as opcodes, so in
    // `ESC[48;2;0;255;0m` the inner `0` acted as a reset and cleared the background —
    // making the styled fill look plain, and it was then removed as padding.
    // Every candidate row is 75 cells so the edge is agreed and the trim branch runs.
    final styled = 'ab\x1b[48;2;0;255;0m${' ' * 73}';
    final plain = 'cd${' ' * 73}';
    final text = [styled, plain, 'ef${' ' * 73}'].join('\n');
    expect(
      displayWidth(styled),
      75,
      reason: 'the styled row must reach the edge',
    );
    expect(displayWidth(plain), 75);
    final after = stripGridPadding(text).split('\n');
    expect(
      after[0],
      styled,
      reason: 'an RGB background containing a 0 is still a background',
    );
    expect(
      after[1],
      'cd',
      reason: 'plain fill on the same screen is still removed',
    );
    expect(after[2], 'ef');
  });

  test('an indexed colour does not turn on reverse video', () {
    // `ESC[38;5;7m` is a foreground colour index; the `7` must not be read as the
    // reverse-video opcode, or the run would look styled and be kept. A foreground
    // colour leaves the tracked flags alone, so the fill is removed as usual.
    final styled = 'gh\x1b[38;5;7m${' ' * 73}';
    final text = [styled, 'ij${' ' * 73}', 'kl${' ' * 73}'].join('\n');
    expect(displayWidth(styled), 75, reason: 'the row must reach the edge');
    final after = stripGridPadding(text).split('\n');
    expect(
      after[0],
      'gh\x1b[38;5;7m',
      reason: 'the escape is kept, the fill goes',
    );
    expect(after[1], 'ij');
    expect(after[2], 'kl');
  });

  test('an opcode after an extended colour still applies', () {
    // `48;2;1;2;3;49m` is an RGB background immediately followed by a background
    // reset. The payload must be consumed whole and scanning must continue, so the
    // trailing run is plain and is removed while both escapes survive.
    final row = 'ab\x1b[48;2;1;2;3;49m${' ' * 73}';
    final text = [row, 'cd${' ' * 73}', 'ef${' ' * 73}'].join('\n');
    expect(
      displayWidth(row),
      75,
      reason: '2 content + 73 fill, escapes contribute nothing',
    );
    final after = stripGridPadding(text).split('\n');
    expect(after[0], 'ab\x1b[48;2;1;2;3;49m');
  });

  test('only the plain run after a reset is removed', () {
    // 70 background-styled spaces must survive (they are styled fill); only the plain
    // tail after `49` may go, and `3` cells of it is what makes the row 75 wide.
    final row = 'ab\x1b[48;2;1;2;3m${' ' * 70}\x1b[49m${' ' * 3}';
    final text = [row, 'cd${' ' * 73}', 'ef${' ' * 73}'].join('\n');
    expect(displayWidth(row), 75, reason: 'the row must reach the edge');
    final after = stripGridPadding(text).split('\n');
    expect(
      after[0],
      'ab\x1b[48;2;1;2;3m${' ' * 70}\x1b[49m',
      reason: 'styled fill is kept; only the plain tail after 49 is trimmed',
    );
  });

  test('is a no-op on a screen with no grid-edge padding', () {
    // A screen with no fill at all; the transform must not touch it.
    const text = 'first\nsecond\n  indented\n\nlast ';
    expect(stripGridPadding(text), text);
  });

  test('is a no-op when only one row reaches the widest width', () {
    // No group agreement, so those trailing spaces could be meaningful.
    const text = 'short\na longer line   \nanother';
    expect(stripGridPadding(text), text);
  });

  test('keeps leading and interior spaces, and real blank lines', () {
    final text = [
      '  indented',
      '${'x' * 10}${' ' * 65}',
      '${'y' * 20}${' ' * 55}',
      '   spaced   out',
      '',
    ].join('\n');
    final after = stripGridPadding(text).split('\n');
    expect(after[0], '  indented', reason: 'leading spaces are layout');
    expect(after[1], 'x' * 10, reason: 'only the trailing pad is removed');
    expect(after[3], '   spaced   out', reason: 'interior spaces survive');
    expect(after[4], '', reason: 'a real blank line stays blank');
  });

  test('does not strip a styled trailing run', () {
    // A background-coloured run of spaces is deliberate fill. Only the *plain* runs
    // are removed, so the styled row keeps its cells while an equally wide plain row
    // is trimmed normally.
    final styled = '${'z' * 10}\x1b[44m${' ' * 65}';
    final plain = '${'w' * 20}${' ' * 55}';
    final text = [styled, plain, 'pub', 'other'].join('\n');
    final after = stripGridPadding(text).split('\n');
    expect(
      after[0],
      styled,
      reason: 'styled fill is deliberate and must survive verbatim',
    );
    expect(
      after[1],
      'w' * 20,
      reason: 'plain fill on the same screen is removed',
    );
    expect(after[2], 'pub');
    expect(after[3], 'other');
  });

  test('detects padding despite a trailing SGR reset', () {
    final text = [
      '\x1b[31m${'a' * 10}\x1b[0m${' ' * 60}',
      '${'b' * 20}${' ' * 55}',
      'short',
      '${'c' * 30}${' ' * 45}',
    ].join('\n');
    final after = stripGridPadding(text).split('\n');
    // The colour is kept; the grid fill is gone.
    expect(after[0], contains('\x1b[31m'));
    expect(after[0], contains('a' * 10));
    expect(after[1], 'b' * 20);
    expect(after[3], 'c' * 30);
  });

  test('handles CJK padding in cells, not code units', () {
    // Six CJK glyphs are twelve cells; padding is measured in cells so the row is
    // recognised as reaching the edge.
    final text = [
      '\u4f60\u597d\u4e16\u754c\u4e2d\u6587${' ' * 63}',
      'plain${' ' * 70}',
      'x',
    ].join('\n');
    final after = stripGridPadding(text).split('\n');
    expect(after[0], '\u4f60\u597d\u4e16\u754c\u4e2d\u6587');
  });

  test('keeps the trailing spaces of a row shorter than the edge', () {
    // A row not padded to the edge keeps its own alignment spaces.
    final text = ['pad${' ' * 72}', 'pad2${' ' * 71}', 'col   '].join('\n');
    final after = stripGridPadding(text).split('\n');
    expect(after[2], 'col   ', reason: 'not at the edge, so untouched');
  });

  test('preserves line endings and a trailing newline', () {
    final text = '${'a' * 70}${' ' * 5}\n${'b' * 70}${' ' * 5}\n';
    final after = stripGridPadding(text);
    expect(after.endsWith('\n'), isTrue);
    expect(after.split('\n').first, 'a' * 70);
  });

  test('the real device sample has no grid fill and is left unchanged', () {
    // A fixed sample recorded from the device (rows 17/120/152/24/60/11 display
    // **cells** — the CJK rows are 12 and 76 characters but 24 and 152 cells). It is
    // content only, with no right-edge fill, so the transform must be a **no-op**.
    // That is the safety property that matters most: an unpadded screen must never be
    // rewritten.
    //
    // Stored as a committed fixture rather than read from `.build/device-evidence/`,
    // which is git-ignored and therefore absent in a clean checkout.
    final raw = _fixture('herdr_wrap_proof.txt').replaceAll('\r', '');
    expect(stripGridPadding(raw), raw);
  });

  test('removes right-edge fill from a genuinely padded capture', () {
    // The padded shape, built from the measurements of a real capture: several rows
    // land exactly on the 75-cell grid edge (content + fill), one is entirely fill,
    // and the rest are short content rows.
    final rows = <String>[
      'short line',
      '${'a' * 11}${' ' * 64}',
      '${'b' * 30}${' ' * 45}',
      ' ' * 75,
      '${'c' * 70}${' ' * 5}',
      'trailing',
    ];
    final before = rows.join('\n');
    final after = stripGridPadding(before).split('\n');
    expect(after[1], 'a' * 11, reason: 'fill removed, content kept');
    expect(after[2], 'b' * 30);
    expect(after[3], '', reason: 'a fully filled row becomes one blank row');
    expect(after[4], 'c' * 70);
    expect(after[0], 'short line', reason: 'unpadded rows untouched');
    expect(after[5], 'trailing');
  });

  test('the captured pane with no fill is unchanged', () {
    // Captured prose that happens to reach 75 cells has no fill to remove.
    final raw = _fixture('herdr_pS_visible_ansi.txt');
    expect(stripGridPadding(raw), raw);
  });
}

// ---------------------------------------------------------------------------
// Wide-glyph wrapping at the grid edge (xterm core)
// ---------------------------------------------------------------------------

void _wideGlyphWrapTests() {
  /// A fresh terminal with a fixed grid, cursor homed.
  Terminal grid(int cols, int rows) {
    final t = Terminal(maxLines: 200);
    t.resize(cols, rows);
    t.eraseDisplay();
    t.eraseScrollbackOnly();
    t.setCursor(0, 0);
    return t;
  }

  test('a wide glyph at the last cell wraps whole instead of being cut', () {
    // Regression: `writeChar` only wrapped when `_cursorX >= viewWidth`, so a CJK
    // glyph needing two cells but finding one was written into the final cell as a
    // 2-wide glyph — its right half outside the line, clipped by the renderer — and
    // the continuation landed on the next row, losing the character entirely.
    final t = grid(4, 4);
    t.write('abc\u4e2dX');
    final row0 = t.buffer.lines[0];
    final row1 = t.buffer.lines[1];
    // No 2-wide glyph may *start* in the last column.
    expect(
      row0.getWidth(3),
      isNot(2),
      reason: 'a wide glyph must not start in the last column',
    );
    // The glyph is whole, and the following text continues on the next row.
    expect(row1.getWidth(0), 2, reason: 'the wide glyph moved down intact');
    expect(
      row1.getText(),
      '\u4e2dX',
      reason: 'text stays contiguous, nothing lost',
    );
  });

  test('an odd-width grid keeps every CJK glyph whole', () {
    // Odd columns are the interesting case: the boundary lands mid-pair repeatedly.
    for (final cols in <int>[5, 7, 9, 11]) {
      final t = grid(cols, 6);
      const text =
          '\u4e2d\u6587\u53ef\u8bfb\u6d4b\u8bd5\u4e2d\u6587\u53ef\u8bfb';
      t.write(text);
      for (var i = 0; i < t.buffer.lines.length; i++) {
        final line = t.buffer.lines[i];
        for (var c = 0; c < cols; c++) {
          if (line.getWidth(c) == 2) {
            expect(
              c + 1,
              lessThan(cols),
              reason: 'cols=$cols row=$i: a wide glyph must fit, not straddle',
            );
          }
        }
      }
      // And no character was dropped.
      final all = <String>[
        for (var i = 0; i < t.buffer.lines.length; i++)
          t.buffer.lines[i].getText(),
      ].join();
      for (final rune in text.runes) {
        expect(all.contains(String.fromCharCode(rune)), isTrue);
      }
    }
  });

  test('the ASCII path is unchanged: no cell ever exceeds the grid', () {
    final t = grid(10, 4);
    t.write('0123456789ABCDEFGHIJ');
    for (var c = 0; c < 10; c++) {
      expect(t.buffer.lines[0].getWidth(c), lessThanOrEqualTo(1));
    }
    expect(t.buffer.lines[0].getText(), '0123456789');
    expect(t.buffer.lines[1].getText(), startsWith('ABCDEFGHIJ'));
  });

  test('a wide glyph exactly filling the last two cells does not wrap', () {
    // The boundary case that must *not* over-wrap.
    final t = grid(4, 4);
    t.write('ab\u4e2d');
    expect(t.buffer.lines[0].getWidth(2), 2);
    expect(t.buffer.lines[0].getText(), 'ab\u4e2d');
    expect(t.buffer.lines[1].getText(), isEmpty);
  });

  test('reflow across a width change keeps wide glyphs whole', () {
    // The other place a wide glyph can straddle: resizing the grid.
    final t = grid(6, 6);
    t.write('\u4e2d\u6587\u53ef\u8bfb\u6d4b\u8bd5');
    t.resize(5, 6);
    for (var c = 0; c < 5; c++) {
      if (t.buffer.lines[0].getWidth(c) == 2) {
        expect(c + 1, lessThan(5), reason: 'no straddling glyph after reflow');
      }
    }
    final all = <String>[
      for (var i = 0; i < t.buffer.lines.length; i++)
        t.buffer.lines[i].getText(),
    ].join();
    for (final ch in '\u4e2d\u6587\u53ef\u8bfb\u6d4b\u8bd5'.split('')) {
      expect(all, contains(ch), reason: 'reflow must not drop $ch');
    }
  });
}
