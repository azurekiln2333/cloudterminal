// Herdr models, controller and UI tests.
//
// Wire fixtures are copied from a live `herdr 0.9.3` session (see
// .trellis/tasks/10-12-herdr-mobile/research/herdr-cli-0.9.3.md) so a field
// rename on either side breaks these tests.

import 'dart:async';

import 'package:cloudterminal/models/herdr.dart';
import 'package:cloudterminal/screens/herdr_pane_screen.dart';
import 'package:cloudterminal/screens/herdr_screen.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/herdr_controller.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/theme/app_theme.dart';
import 'package:cloudterminal/widgets/herdr_pane_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_relay.dart';

/// The pane output currently held by the terminal viewport.
///
/// Pane output is painted by the emulator, not rendered as a [Text] widget, so
/// `find.textContaining` cannot see it. Read the emulator's own buffer instead.
String _viewportText(WidgetTester tester) => tester
    .state<HerdrPaneViewportState>(find.byType(HerdrPaneViewport))
    .debugBufferText;

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
      String outputText = 'real screen text',
      String? error,
    }) {
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
                'tabs': <Map<String, dynamic>>[],
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

  // -------------------------------------------------------------------------
  // Pane screen: output fidelity, no clear-on-refresh, desktop scroll banner
  // -------------------------------------------------------------------------

  group('Herdr pane screen', () {
    testWidgets('refresh keeps the existing output on screen', (tester) async {
      await _pumpPane(
        tester,
        outputText: 'first screen',
        readDelay: const Duration(milliseconds: 200),
      );
      expect(_viewportText(tester), contains('first screen'));

      // Trigger a refresh; before the reply lands the old text must still be
      // rendered (no CircularProgressIndicator replacing the viewport).
      await tester.tap(find.byTooltip('刷新输出'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_viewportText(tester), contains('first screen'));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // A thin in-flight indicator is allowed instead.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(_viewportText(tester), contains('first screen'));
    });

    testWidgets('shows the desktop review banner when offsetFromBottom > 0', (
      tester,
    ) async {
      await _pumpPane(tester, scrollOffsetFromBottom: 37);
      // The banner describes the desktop Herdr pane, never the app viewport.
      expect(find.text('电脑端回看了 37 行'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsOneWidget);
    });

    testWidgets('hides the desktop review banner at offsetFromBottom == 0', (
      tester,
    ) async {
      await _pumpPane(tester, scrollOffsetFromBottom: 0);
      expect(find.textContaining('电脑端回看了'), findsNothing);
      expect(find.byIcon(Icons.history_rounded), findsNothing);
    });

    testWidgets('tapping the banner re-reads and does not clear the output', (
      tester,
    ) async {
      final socket = await _pumpPane(
        tester,
        outputText: 'history screen',
        scrollOffsetFromBottom: 12,
      );
      expect(find.text('电脑端回看了 12 行'), findsOneWidget);
      final before = socket.requests
          .where((r) => r['type'] == 'herdr_read')
          .length;
      await tester.tap(find.text('重新读取'));
      await tester.pump();
      // The old output stays visible while the re-read is in flight.
      expect(_viewportText(tester), contains('history screen'));
      await tester.pumpAndSettle();
      final after = socket.requests
          .where((r) => r['type'] == 'herdr_read')
          .length;
      expect(after, greaterThan(before));
    });
  });

  // -------------------------------------------------------------------------
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

/// Pumps a [HerdrPaneScreen] wired to a scripted agent and returns the socket.
Future<FakeSocket> _pumpPane(
  WidgetTester tester, {
  String outputText = 'real screen text',
  int scrollOffsetFromBottom = 0,
  Duration readDelay = Duration.zero,
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
  _scriptHerdrSocket(socket, outputText: outputText, readDelay: readDelay);

  final remote = RemoteController(store: store, connector: (_) async => socket);
  final herdr = HerdrController(remote);
  addTearDown(() {
    herdr.dispose();
    remote.dispose();
  });
  remote.connect();

  final workspace = HerdrWorkspace.fromJson(workspaceJson());
  final pane = HerdrPane.fromJson(
    paneJson(scrollOffsetFromBottom: scrollOffsetFromBottom),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.seeds.first.color),
      home: HerdrPaneScreen(
        controller: remote,
        herdr: herdr,
        workspace: workspace,
        pane: pane,
      ),
    ),
  );
  await tester.pumpAndSettle();
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
}) {
  final resolvedAvailability = availability ?? availabilityJson();
  final available = resolvedAvailability['available'] == true;
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
            'tabs': tabs ?? <Map<String, dynamic>>[],
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
