// Herdr bridge tests. The runner is always injected, so these never spawn a
// real Herdr process and never touch real workspaces.
//
// The list fixtures are copied verbatim from a live `herdr 0.9.3` session (see
// .trellis/tasks/10-12-herdr-mobile/research/herdr-cli-0.9.3.md) so a change in
// field names breaks these tests.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, it } from 'node:test';

import {
  HerdrArgumentError,
  HerdrBridge,
  HerdrError,
  HERDR_AGENT_KINDS,
  HERDR_KEYS,
  describeHerdrFailure,
  parseAgentStatus,
  parseHerdrStatus,
  requireAgentTarget,
  requireKeys,
  requireLabel,
  requireLines,
  requirePaneId,
  requireReadSource,
  requireTabId,
  type HerdrBridgeOptions,
  type HerdrResult,
  type HerdrRunOptions,
  type HerdrRunner,
} from '../src/agent/herdr.ts';
import { HerdrSocketError } from '../src/agent/herdr-socket.ts';
import { AgentCore } from '../src/agent/core.ts';
import type { AgentMessage, ClientMessage } from '../src/shared/protocol.ts';
import { fakeQueryFn } from './fake-query.ts';

// ---------------------------------------------------------------------------
// Fixtures recorded from the live CLI
// ---------------------------------------------------------------------------

const WORKSPACE_LIST = {
  workspaces: [
    { workspace_id: 'w6', label: 'qfli_c', number: 1, focused: false, agent_status: 'working', pane_count: 3, tab_count: 1, active_tab_id: 'w6:t1' },
    { workspace_id: 'wJ', label: 'cloudterminal', number: 13, focused: true, agent_status: 'working', pane_count: 2, tab_count: 1, active_tab_id: 'wJ:t1' },
  ],
};

const AGENT_LIST = {
  agents: [
    // Unnamed agent: the pane id is the target, `name` is absent.
    {
      pane_id: 'wJ:p1', workspace_id: 'wJ', tab_id: 'wJ:t1', cwd: 'D:\\MyNewProjects\\cloudterminal',
      terminal_title: '⠋ 指挥 pi 接入 herdr 手机操控功能 | cloudterminal',
      terminal_title_stripped: '指挥 pi 接入 herdr 手机操控功能 | cloudterminal',
      agent: 'codex', agent_status: 'working', focused: true, revision: 852, state_change_seq: 448,
    },
    // Named agent with an explicitly-named pi session.
    {
      pane_id: 'w8:p4', workspace_id: 'w8', tab_id: 'w8:t1', cwd: 'D:\\MyNewProjects\\qfli_go',
      terminal_title: 'π - qfli_go', terminal_title_stripped: 'π - qfli_go',
      name: 'pi-go-curriculum-review', agent: 'pi', agent_status: 'done', focused: false,
      interactive_ready: true, completion_seq: 447, state_change_seq: 447,
      agent_session: { agent: 'pi', kind: 'path', source: 'herdr:pi', value: 'C:\\x.jsonl' },
    },
  ],
};

const PANE_LIST = {
  panes: [
    // A pane with no agent at all.
    {
      pane_id: 'wF:p1', workspace_id: 'wF', tab_id: 'wF:t1', cwd: 'D:\\MyNewProjects\\qfli_studio_core',
      focused: true, terminal_title: 'π - qfli_studio_core', terminal_title_stripped: 'π - qfli_studio_core',
      agent: 'pi', agent_status: 'idle', revision: 3,
      scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 45 },
    },
    {
      pane_id: 'wJ:p2', workspace_id: 'wJ', tab_id: 'wJ:t1', cwd: 'D:\\MyNewProjects\\cloudterminal',
      focused: false, terminal_id: 'term_65d95862e3eb324',
      terminal_title: 'π - cloudterminal', terminal_title_stripped: 'π - cloudterminal',
      agent: 'pi', agent_status: 'idle', revision: 3,
      scroll: { offset_from_bottom: 0, max_offset_from_bottom: 0, viewport_rows: 43 },
    },
  ],
};

const LAYOUT = {
  layout: {
    workspace_id: 'wJ', tab_id: 'wJ:t1', zoomed: false, focused_pane_id: 'wJ:p1',
    area: { x: 0, y: 0, width: 153, height: 45 },
    panes: [
      { pane_id: 'wJ:p1', focused: true, rect: { x: 0, y: 0, width: 77, height: 45 } },
      { pane_id: 'wJ:p2', focused: false, rect: { x: 77, y: 0, width: 76, height: 45 } },
    ],
    splits: [{ id: 'split_0_root', direction: 'right', ratio: 0.5, rect: { x: 0, y: 0, width: 153, height: 45 } }],
  },
};

const STATUS_TEXT = [
  'client:',
  '  version: 0.9.3',
  '  channel: stable',
  '  protocol: 22',
  '',
  'server:',
  '  status: running',
  '  version: 0.9.3',
  '  socket: D:\\AppData\\Roaming\\herdr\\herdr.sock',
].join('\n');

// ---------------------------------------------------------------------------
// Fake runner
// ---------------------------------------------------------------------------

type Call = HerdrRunOptions & { argv: string[] };
type SocketCall = { path: string; method: string; params: Record<string, unknown>; timeoutMs?: number };
type BridgeTestOptions = Omit<HerdrBridgeOptions, 'binary' | 'runner' | 'logger'>;

function ok(result: unknown): HerdrResult {
  return { code: 0, stdout: JSON.stringify({ id: 'cli:test', result }), stderr: '', timedOut: false };
}

function raw(stdout: string, code = 0): HerdrResult {
  return { code, stdout, stderr: '', timedOut: false };
}

function err(code: string, message: string): HerdrResult {
  return { code: 1, stdout: JSON.stringify({ id: 'cli:test', error: { code, message } }), stderr: '', timedOut: false };
}

/** A bridge whose runner replays the given handler; every call is recorded. */
function bridgeWith(handler: (argv: string[]) => HerdrResult, options: BridgeTestOptions = {}) {
  const calls: Call[] = [];
  const socketCalls: SocketCall[] = [];
  const runner: HerdrRunner = async (options) => {
    calls.push(options as Call);
    return handler(options.argv);
  };
  const bridge = new HerdrBridge({
    ...options,
    binary: process.execPath,
    runner,
    logger: silentLogger(),
    socketCall: async (socketPath, method, params, timeoutMs, platform) => {
      socketCalls.push({ path: socketPath, method, params, timeoutMs });
      return options.socketCall
        ? options.socketCall(socketPath, method, params, timeoutMs, platform)
        : { id: 'ct1', result: { type: 'ok' } };
    },
  });
  return { bridge, calls, socketCalls };
}

function silentLogger() {
  return { info: () => {}, warn: () => {}, error: () => {} };
}

/** Availability-capable fake: --version and status succeed. */
function readyBridge(handler: (argv: string[]) => HerdrResult, options: BridgeTestOptions = {}) {
  return bridgeWith((argv) => {
    if (argv[0] === '--version') return raw('herdr 0.9.3\n');
    if (argv[0] === 'status') return raw(STATUS_TEXT);
    return handler(argv);
  }, options);
}

// ---------------------------------------------------------------------------
// Availability
// ---------------------------------------------------------------------------

describe('herdr availability', () => {
  it('reports missing installation with an actionable reason', async () => {
    const calls: Call[] = [];
    const bridge = new HerdrBridge({
      // A path that certainly does not exist means resolution fails.
      binary: path.join(process.cwd(), 'definitely-not-herdr.exe'),
      runner: async (o) => { calls.push(o as Call); return raw(''); },
      logger: silentLogger(),
    });
    const availability = await bridge.availability();
    assert.equal(availability.available, false);
    assert.equal(availability.installed, false);
    assert.equal(availability.canControl, false);
    assert.match(availability.reason ?? '', /没有安装 Herdr/);
    assert.equal(calls.length, 0, 'must not spawn anything when the binary is missing');
  });

  it('reports a stopped server separately from a missing install', async () => {
    const { bridge } = bridgeWith((argv) => {
      if (argv[0] === '--version') return raw('herdr 0.9.3\n');
      if (argv[0] === 'status') return raw('client:\n  version: 0.9.3\n\nserver:\n  status: stopped\n');
      return raw('');
    });
    const availability = await bridge.availability();
    assert.equal(availability.installed, true);
    assert.equal(availability.version, '0.9.3');
    assert.equal(availability.serverRunning, false);
    assert.match(availability.reason ?? '', /服务未运行/);
  });

  it('reports ready and caches the probe', async () => {
    const { bridge, calls } = readyBridge(() => ok({}));
    const first = await bridge.availability();
    assert.equal(first.available, true);
    assert.equal(first.version, '0.9.3');
    assert.equal(first.protocol, 22);
    assert.equal(first.socket, 'D:\\AppData\\Roaming\\herdr\\herdr.sock');
    const before = calls.length;
    await bridge.availability();
    assert.equal(calls.length, before, 'second probe should hit the cache');
    await bridge.availability(true);
    assert.ok(calls.length > before, 'force must bypass the cache');
  });

  it('coalesces concurrent discovery and shares the socket-path cache', async () => {
    const { bridge, calls } = readyBridge(() => err('x', 'unexpected command'));
    const [first, second, socketPath] = await Promise.all([
      bridge.availability(),
      bridge.availability(true),
      bridge.socketPath(),
    ]);
    assert.equal(first, second);
    assert.equal(socketPath, first.socket);
    await bridge.socketPath();
    assert.deepEqual(calls.map((call) => call.argv), [['--version'], ['status']]);
  });

  it('refreshes a moved socket after an explicit availability refresh', async () => {
    let statusText = STATUS_TEXT;
    const { bridge } = bridgeWith((argv) => argv[0] === '--version'
      ? raw('herdr 0.9.3\n')
      : raw(statusText));
    assert.equal(await bridge.socketPath(), 'D:\\AppData\\Roaming\\herdr\\herdr.sock');
    statusText = STATUS_TEXT.replace('herdr.sock', 'herdr-new.sock');
    await bridge.availability(true);
    assert.equal(await bridge.socketPath(), 'D:\\AppData\\Roaming\\herdr\\herdr-new.sock');
  });

  it('refuses control when a running server reports no version', async () => {
    const { bridge } = bridgeWith((argv) => {
      if (argv[0] === '--version') return raw('not herdr at all\n');
      if (argv[0] === 'status') return raw(STATUS_TEXT);
      return raw('');
    });
    const availability = await bridge.availability();
    assert.equal(availability.available, false);
    assert.equal(availability.installed, true);
    assert.match(availability.reason ?? '', /无法确认版本/);
  });

  it('parses the real status text layout', () => {
    const status = parseHerdrStatus(STATUS_TEXT);
    assert.equal(status.clientVersion, '0.9.3');
    assert.equal(status.clientProtocol, 22);
    assert.equal(status.serverStatus, 'running');
    assert.equal(status.serverVersion, '0.9.3');
    assert.equal(status.socket, 'D:\\AppData\\Roaming\\herdr\\herdr.sock');
  });
});

describe('herdr raw terminal input', () => {
  it('preserves whitespace, Unicode and control bytes while sharing discovery', async () => {
    const { bridge, calls, socketCalls } = readyBridge(() => err('x', 'unexpected command'));
    const inputs = [' \t中文🙂\r\n  ', '\u0000', '\u007f', '\u001b[A', '\u0003'];
    await Promise.all(inputs.map((input) => bridge.sendText('wJ:pB', input)));
    assert.deepEqual(socketCalls.map((call) => call.params), inputs.map((input) => ({
      pane_id: 'wJ:pB', text: input,
    })));
    assert.ok(socketCalls.every((call) => call.method === 'pane.send_text'));
    assert.deepEqual(calls.map((call) => call.argv), [['--version'], ['status']]);
    await bridge.sendText('wJ:pB', 'next key');
    assert.equal(calls.length, 2, 'cached typing must not spawn per-key CLI processes');
  });

  it('uses mode-aware input only for explicit clipboard paste and preserves its body', async () => {
    const { bridge, calls, socketCalls } = readyBridge(() => err('x', 'unexpected CLI mutation'));
    const input = '  中文🙂\t\u0000\r\n\u007f\u001b[A\u0003  ';
    await bridge.sendText('wJ:pB', input);
    await bridge.sendText('wJ:pB', input, false);
    await bridge.sendText('wJ:pB', input, true);
    assert.deepEqual(socketCalls.map((call) => ({ method: call.method, params: call.params })), [
      { method: 'pane.send_text', params: { pane_id: 'wJ:pB', text: input } },
      { method: 'pane.send_text', params: { pane_id: 'wJ:pB', text: input } },
      { method: 'pane.send_input', params: { pane_id: 'wJ:pB', text: input } },
    ]);
    assert.deepEqual(calls.map((call) => call.argv), [['--version'], ['status']]);
  });

  it('rejects a non-boolean paste flag before discovery or input delivery', async () => {
    const { bridge, calls, socketCalls } = readyBridge(() => ok({}));
    for (const paste of [null, 0, 1, 'true', 'false', {}, []]) {
      await assert.rejects(() => bridge.sendText('wJ:pB', 'clipboard', paste), (error: unknown) => {
        assert.ok(error instanceof HerdrArgumentError);
        assert.match(error.message, /粘贴.*布尔/);
        return true;
      });
    }
    assert.equal(calls.length, 0);
    assert.equal(socketCalls.length, 0);
  });

  it('validates input and pane identity before any discovery or socket operation', async () => {
    const { bridge, calls, socketCalls } = readyBridge(() => ok({}));
    for (const text of [undefined, 42, '', 'x'.repeat(65537)]) {
      await assert.rejects(() => bridge.sendText('wJ:pB', text), HerdrArgumentError);
    }
    await assert.rejects(() => bridge.sendText('wJ:pB; whoami', 'x'), HerdrArgumentError);
    assert.equal(calls.length, 0);
    assert.equal(socketCalls.length, 0);
    const boundary = '\u0000'.repeat(65536);
    await bridge.sendText('wJ:pB', boundary);
    assert.equal(socketCalls[0]?.params.text, boundary);
  });

  it('leaves prompt validation separate from raw terminal input', async () => {
    const { bridge, calls, socketCalls } = readyBridge(() => ok({}));
    await bridge.prompt('wJ:pB', 'a\u0000b');
    assert.deepEqual(calls.at(-1)?.argv, ['agent', 'prompt', 'wJ:pB', 'ab']);
    assert.equal(socketCalls.length, 0);
  });

  it('retains socket failure codes and never retries or falls back to CLI', async () => {
    for (const paste of [false, true]) {
      for (const code of ['pane_not_found', 'pane_send_failed', 'timeout', 'connection_closed']) {
        const { bridge, calls, socketCalls } = readyBridge(() => ok({}), {
          socketCall: async () => { throw new HerdrSocketError('input delivery failed', code); },
        });
        await assert.rejects(() => bridge.sendText('wJ:pB', '\u0003', paste), (error: unknown) => {
          assert.ok(error instanceof HerdrError);
          assert.equal(error.code, 'herdr_failed');
          assert.equal(error.herdrCode, code);
          assert.ok(error.wire().startsWith(`herdr_failed:${code}:`));
          return true;
        });
        assert.equal(socketCalls.length, 1, `${code} must not resend ambiguous input`);
        assert.equal(socketCalls[0]?.method, paste ? 'pane.send_input' : 'pane.send_text');
        assert.deepEqual(calls.map((call) => call.argv), [['--version'], ['status']]);
      }
    }
  });

  it('reports malformed success without resending input', async () => {
    for (const paste of [false, true]) {
      for (const result of [undefined, null, {}, { type: 'pane_read' }]) {
        const { bridge, calls, socketCalls } = readyBridge(() => ok({}), {
          socketCall: async () => ({ id: 'ct1', result }),
        });
        await assert.rejects(() => bridge.sendText('wJ:pB', 'x', paste), HerdrError);
        assert.equal(socketCalls.length, 1);
        assert.equal(socketCalls[0]?.method, paste ? 'pane.send_input' : 'pane.send_text');
        assert.equal(calls.length, 2);
      }
    }
  });

  it('rejects unavailable or missing socket discovery before writing', async () => {
    for (const statusText of [
      'server:\n  status: stopped\n',
      'client:\n  protocol: 22\nserver:\n  status: running\n',
    ]) {
      const { bridge, socketCalls } = bridgeWith((argv) => argv[0] === '--version'
        ? raw('herdr 0.9.3\n')
        : raw(statusText));
      await assert.rejects(() => bridge.sendText('wJ:pB', 'x'), (error: unknown) => {
        assert.ok(error instanceof HerdrError);
        assert.equal(error.code, 'herdr_unavailable');
        return true;
      });
      assert.equal(socketCalls.length, 0);
    }
  });
});

// ---------------------------------------------------------------------------
// Mapping
// ---------------------------------------------------------------------------

describe('herdr mapping', () => {
  it('maps the real workspace list shape', async () => {
    const { bridge } = readyBridge((argv) => (argv[0] === 'workspace' ? ok(WORKSPACE_LIST) : err('x', 'y')));
    const workspaces = await bridge.workspaces();
    assert.equal(workspaces.length, 2);
    assert.deepEqual(workspaces[1], {
      workspaceId: 'wJ', label: 'cloudterminal', number: 13, focused: true,
      agentStatus: 'working', paneCount: 2, tabCount: 1, activeTabId: 'wJ:t1',
    });
  });

  it('maps agents using the name as target and falls back to the pane id', async () => {
    const { bridge } = readyBridge((argv) => (argv[0] === 'agent' ? ok(AGENT_LIST) : err('x', 'y')));
    const agents = await bridge.agents();
    assert.equal(agents[0]?.target, 'wJ:p1', 'unnamed agent targets its pane');
    assert.equal(agents[0]?.name, undefined);
    assert.equal(agents[1]?.target, 'pi-go-curriculum-review');
    assert.equal(agents[1]?.agentKind, 'pi');
    assert.equal(agents[1]?.status, 'done');
    assert.equal(agents[1]?.interactiveReady, true);
    assert.equal(agents[1]?.completionSeq, 447);
  });

  it('maps panes including scroll state and prefers the stripped title', async () => {
    const { bridge } = readyBridge((argv) => (argv[0] === 'pane' ? ok(PANE_LIST) : err('x', 'y')));
    const panes = await bridge.panes('wJ');
    assert.equal(panes[0]?.terminalTitle, 'π - qfli_studio_core');
    assert.deepEqual(panes[0]?.scroll, { offsetFromBottom: 0, maxOffsetFromBottom: 0, viewportRows: 45 });
    assert.equal(panes[1]?.cwd, 'D:\\MyNewProjects\\cloudterminal');
    assert.equal(panes[1]?.agentStatus, 'idle');
  });

  it('maps the layout shape', async () => {
    const { bridge } = readyBridge((argv) => (argv[0] === 'pane' ? ok(LAYOUT) : err('x', 'y')));
    const layout = await bridge.layout('wJ:p1');
    assert.equal(layout.focusedPaneId, 'wJ:p1');
    assert.equal(layout.zoomed, false);
    assert.deepEqual(layout.area, { x: 0, y: 0, width: 153, height: 45 });
    assert.equal(layout.panes.length, 2);
    assert.equal(layout.splits[0]?.direction, 'right');
  });

  it('degrades unknown agent statuses to unknown instead of throwing', () => {
    assert.equal(parseAgentStatus('working'), 'working');
    assert.equal(parseAgentStatus('blocked'), 'blocked');
    assert.equal(parseAgentStatus('quiescent'), 'unknown');
    assert.equal(parseAgentStatus(undefined), 'unknown');
    assert.equal(parseAgentStatus(7), 'unknown');
  });

  it('tolerates missing optional fields in a listing', async () => {
    const { bridge } = readyBridge((argv) => (argv[0] === 'agent' ? ok({ agents: [{ pane_id: 'w1:p1' }] }) : err('x', 'y')));
    const agents = await bridge.agents();
    assert.equal(agents[0]?.target, 'w1:p1');
    assert.equal(agents[0]?.status, 'unknown');
    assert.equal(agents[0]?.cwd, '');
    assert.equal(agents[0]?.name, undefined);
  });
});

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

describe('herdr reads', () => {
  it('returns pane text for the requested source and line count', async () => {
    const { bridge, calls } = readyBridge((argv) => (argv[0] === 'pane' ? raw('line1\nline2\n') : err('x', 'y')));
    const output = await bridge.read('wJ:p2', 'recent-unwrapped', 40);
    assert.equal(output.text, 'line1\nline2\n');
    assert.equal(output.source, 'recent-unwrapped');
    assert.deepEqual(calls.at(-1)?.argv, ['pane', 'read', 'wJ:p2', '--source', 'recent-unwrapped', '--lines', '40']);
  });

  it('defaults the read source and line count', async () => {
    const { bridge, calls } = readyBridge(() => raw('x'));
    const output = await bridge.read('wJ:p2');
    assert.equal(output.source, 'visible');
    assert.deepEqual(calls.at(-1)?.argv, ['pane', 'read', 'wJ:p2', '--source', 'visible', '--lines', '200']);
  });

  it('rejects a read that returns an error envelope as raw text', async () => {
    // `pane read` prints raw text on success, so a failed read used to leak the
    // JSON error envelope through as screen output. It must be a typed error.
    const failure: HerdrResult = {
      code: 1,
      stdout: JSON.stringify({ error: { code: 'pane_not_found', message: 'pane wZ:p9 not found' }, id: 'cli:pane:read' }),
      stderr: '',
      timedOut: false,
    };
    const { bridge } = readyBridge((argv) => (argv[0] === 'pane' ? failure : err('x', 'y')));
    await assert.rejects(
      () => bridge.read('wZ:p9'),
      (e: unknown) => e instanceof HerdrError && e.herdrCode === 'pane_not_found',
    );
  });

  it('does not mistake ordinary JSON-looking pane text for an error', async () => {
    const { bridge } = readyBridge(() => raw('{"not":"an error"}\n'));
    const output = await bridge.read('wJ:p2');
    assert.equal(output.text, '{"not":"an error"}\n');
  });
});

// ---------------------------------------------------------------------------
// Validation — the security boundary
// ---------------------------------------------------------------------------

describe('herdr argument validation', () => {
  const injectionAttempts = [
    'w1; rm -rf /',
    'w1 && whoami',
    'w1 | cat /etc/passwd',
    '`id`',
    '$(id)',
    'w1\nw2',
    'w1:p1 --force',
    '../../etc/passwd',
    'w1:p1; echo pwned',
    'W1',
    '',
  ];

  it('rejects every injection attempt in an id slot', () => {
    for (const attempt of injectionAttempts) {
      assert.throws(() => requirePaneId(attempt), HerdrArgumentError, `pane id accepted: ${attempt}`);
    }
    for (const attempt of injectionAttempts) {
      assert.throws(() => requireAgentTarget(attempt), HerdrArgumentError, `target accepted: ${attempt}`);
    }
  });

  it('accepts only well-formed ids and targets', () => {
    assert.equal(requirePaneId('wJ:p2'), 'wJ:p2');
    assert.equal(requirePaneId('w1:p100'), 'w1:p100');
    // Real herdr ids use base-36 suffixes: panes `wJ:pB`/`wJ:pS`/`wJ:pC` and tabs
    // `wJ:tA`. A digits-only pattern rejected them, and because the same rule
    // guards `herdr_watch`, every pane tap failed with
    // `herdr_invalid_argument: 无效的面板 ID`.
    assert.equal(requirePaneId('wJ:pB'), 'wJ:pB');
    assert.equal(requirePaneId('wJ:pS'), 'wJ:pS');
    assert.equal(requireTabId('wJ:tA'), 'wJ:tA');
    assert.equal(requireAgentTarget('pi-go-curriculum-review'), 'pi-go-curriculum-review');
    assert.equal(requireAgentTarget('w8:p4'), 'w8:p4');
    assert.equal(requireAgentTarget('wJ:pB'), 'wJ:pB');
    // A bare kind is NOT a valid target, matching Herdr's own rule.
    assert.throws(() => requireAgentTarget('pi'), HerdrArgumentError);
    assert.throws(() => requireAgentTarget('Pi-Review'), HerdrArgumentError);
    assert.throws(() => requireAgentTarget('x'.repeat(33)), HerdrArgumentError);
  });

  it('rejects control characters and over-long labels', () => {
    assert.equal(requireLabel('  cloudterminal  '), 'cloudterminal');
    assert.throws(() => requireLabel('a\u0000b'), HerdrArgumentError);
    assert.throws(() => requireLabel('a\nb'), HerdrArgumentError);
    assert.throws(() => requireLabel('   '), HerdrArgumentError);
    assert.throws(() => requireLabel('x'.repeat(121)), HerdrArgumentError);
  });

  it('rejects bad read sources, line counts and keys', () => {
    assert.equal(requireReadSource(undefined), 'visible');
    assert.equal(requireReadSource('detection'), 'detection');
    assert.throws(() => requireReadSource('everything'), HerdrArgumentError);

    assert.equal(requireLines(undefined, 200), 200);
    assert.equal(requireLines(5000, 1), 5000);
    for (const bad of [0, -1, 1e9, 1.5, '100', Number.NaN]) {
      assert.throws(() => requireLines(bad, 1), HerdrArgumentError, `lines accepted ${String(bad)}`);
    }

    assert.deepEqual(requireKeys(['ctrl+c']), ['ctrl+c']);
    for (const bad of ['rm', 'ctrl+alt+del', 'F5', '', 'enter; rm -rf /']) {
      assert.throws(() => requireKeys([bad]), HerdrArgumentError, `key accepted: ${bad}`);
    }
    assert.throws(() => requireKeys([]), HerdrArgumentError);
    assert.throws(() => requireKeys('enter'), HerdrArgumentError);
  });

  it('keeps the key allowlist free of destructive combinations', () => {
    assert.ok(HERDR_KEYS.includes('ctrl+c'));
    assert.ok(!HERDR_KEYS.some((k) => /f\d|alt\+|super/i.test(k)));
  });

  it('exposes the real Herdr agent kinds only', () => {
    assert.ok(HERDR_AGENT_KINDS.includes('pi'));
    assert.ok(HERDR_AGENT_KINDS.includes('codex'));
    assert.ok(HERDR_AGENT_KINDS.includes('mastracode'));
    assert.equal(HERDR_AGENT_KINDS.length, 24);
  });
});

// ---------------------------------------------------------------------------
// argv construction
// ---------------------------------------------------------------------------

describe('herdr argv construction', () => {
  it('passes workspace create flags as separate argv elements', async () => {
    const { bridge, calls } = readyBridge(() => ok({ workspace: { workspace_id: 'wZ' } }));
    await bridge.act({ kind: 'workspace_create', label: 'ct-probe', focus: false });
    assert.deepEqual(calls.at(-1)?.argv, ['workspace', 'create', '--label', 'ct-probe', '--no-focus']);
  });

  it('splits panes with explicit ids and never uses the implicit caller pane', async () => {
    const { bridge, calls } = readyBridge(() => ok({ pane: { pane_id: 'wJ:p3' } }));
    await bridge.act({ kind: 'pane_split', paneId: 'wJ:p2', direction: 'right', ratio: 0.5 });
    assert.deepEqual(calls.at(-1)?.argv, ['pane', 'split', 'wJ:p2', '--direction', 'right', '--ratio', '0.5', '--focus']);
  });

  it('keeps prompt text in one argv element, even with newlines and metacharacters', async () => {
    const { bridge, calls } = readyBridge(() => ok({ agent: { pane_id: 'wJ:p2' } }));
    const text = 'line1\nline2; rm -rf / && `id` $(whoami)';
    await bridge.prompt('wJ:p2', text);
    const argv = calls.at(-1)?.argv ?? [];
    assert.deepEqual(argv, ['agent', 'prompt', 'wJ:p2', text]);
    assert.equal(argv.filter((a) => a === text).length, 1);
  });

  it('adds --wait and a timeout for a waited prompt', async () => {
    const { bridge, calls } = readyBridge(() => ok({}));
    await bridge.prompt('agent-one', 'do it', { wait: true, timeoutMs: 30_000 });
    assert.deepEqual(calls.at(-1)?.argv, ['agent', 'prompt', 'agent-one', 'do it', '--wait', '--timeout', '30000']);
  });

  it('sends keys to a pane through `pane send-keys`', async () => {
    // Regression: this used to always emit `agent send-keys`, so a plain shell
    // pane — which hosts no agent — could never receive Enter, Backspace or an
    // arrow. A pane id must take the pane verb.
    const { bridge, calls } = readyBridge(() => ok({}));
    await bridge.sendKeys('wJ:p2', ['esc', 'ctrl+c'], 2);
    assert.deepEqual(calls.at(-1)?.argv, [
      'pane', 'send-keys', 'wJ:p2', 'esc', 'ctrl+c', 'esc', 'ctrl+c',
    ]);
  });

  it('sends keys to a named agent through `agent send-keys`', async () => {
    // A live agent name keeps the agent verb, so existing agent-targeted
    // behaviour is unchanged.
    const { bridge, calls } = readyBridge(() => ok({}));
    await bridge.sendKeys('pi-go-curriculum-review', ['enter']);
    assert.deepEqual(calls.at(-1)?.argv, [
      'agent', 'send-keys', 'pi-go-curriculum-review', 'enter',
    ]);
  });

  it('sends Enter and Backspace to a shell pane and never as literal text', async () => {
    // The concrete user-visible failure: keys in a shell pane did nothing.
    const { bridge, calls } = readyBridge(() => ok({}));
    await bridge.sendKeys('wJ:pS', ['enter']);
    await bridge.sendKeys('wJ:pS', ['backspace']);
    const argvs = calls.filter((c) => c.argv[1] === 'send-keys').map((c) => c.argv);
    assert.deepEqual(argvs, [
      ['pane', 'send-keys', 'wJ:pS', 'enter'],
      ['pane', 'send-keys', 'wJ:pS', 'backspace'],
    ]);
  });

  it('rejects an injection-shaped key target before running anything', async () => {
    for (const bad of ['wJ:p2; rm -rf /', 'wJ:p2 && whoami', 'pi']) {
      const { bridge, calls } = readyBridge(() => ok({}));
      await assert.rejects(() => bridge.sendKeys(bad, ['enter']));
      assert.equal(
        calls.filter((c) => c.argv[1] === 'send-keys').length,
        0,
        `must not invoke for ${bad}`,
      );
    }
  });

  it('sends terminal text through the raw socket without spawning a text command', async () => {
    const { bridge, calls, socketCalls } = readyBridge(() => err('x', 'unexpected CLI mutation'));
    const summary = await bridge.sendText('wJ:p2', 'echo hi');
    assert.match(summary, /wJ:p2/);
    assert.deepEqual(calls.map((call) => call.argv), [['--version'], ['status']]);
    assert.deepEqual(socketCalls, [{
      path: 'D:\\AppData\\Roaming\\herdr\\herdr.sock',
      method: 'pane.send_text',
      params: { pane_id: 'wJ:p2', text: 'echo hi' },
      timeoutMs: 4000,
    }]);
  });

  it('treats an empty stdout from send-keys as success for both verbs', async () => {
    const { bridge, calls } = readyBridge(() => raw(''));
    await bridge.sendKeys('wJ:p2', ['enter']);
    await bridge.sendKeys('some-agent', ['enter']);
    const argvs = calls.filter((c) => c.argv[1] === 'send-keys').map((c) => c.argv);
    assert.deepEqual(argvs, [
      ['pane', 'send-keys', 'wJ:p2', 'enter'],
      ['agent', 'send-keys', 'some-agent', 'enter'],
    ]);
  });

  it('still fails a void mutation that exits non-zero with empty stdout', async () => {
    // Empty output is only acceptable on success; a failed write must be an error.
    const { bridge } = readyBridge(() => raw('', 1));
    await assert.rejects(() => bridge.sendKeys('wJ:p2', ['enter']), HerdrError);
  });

  it('still fails a void mutation that exits non-zero with an error envelope', async () => {
    const { bridge } = readyBridge(() => err('pane_not_found', 'no such pane'));
    await assert.rejects(() => bridge.sendKeys('wJ:p9', ['enter']), HerdrError);
  });

  it('does not excuse an empty stdout from a listing', async () => {
    // The allowance is scoped to void mutations on purpose: a listing or a read
    // returning nothing is bad data, not success.
    const { bridge } = readyBridge(() => raw(''));
    await assert.rejects(
      () => bridge.workspaces(),
      HerdrError,
      'an empty workspace list must not read as success',
    );
    await assert.rejects(() => bridge.agent('wJ:p2'), HerdrError);
    await assert.rejects(() => bridge.layout('wJ:p2'), HerdrError);
  });

  it('passes a pane command as a single opaque argument', async () => {
    const { bridge, calls } = readyBridge(() => ok({}));
    const command = 'echo hello; ls | grep x';
    await bridge.run('wJ:p2', command);
    assert.deepEqual(calls.at(-1)?.argv, ['pane', 'run', 'wJ:p2', command]);
  });

  it('builds the agent start command with a validated kind', async () => {
    const { bridge, calls } = readyBridge(() => ok({}));
    await bridge.act({ kind: 'agent_start', name: 'ct-probe-agent', agentKind: 'codex', paneId: 'wZ:p1' });
    assert.deepEqual(calls.at(-1)?.argv, ['agent', 'start', 'ct-probe-agent', '--kind', 'codex', '--pane', 'wZ:p1']);
  });

  it('rejects an unknown agent kind before running anything', async () => {
    const { bridge, calls } = readyBridge(() => ok({}));
    await assert.rejects(
      () => bridge.act({ kind: 'agent_start', name: 'ct-probe-agent', agentKind: 'not-a-kind', paneId: 'wZ:p1' }),
      HerdrArgumentError,
    );
    assert.equal(calls.length, 0);
  });

  it('covers the remaining lifecycle actions', async () => {
    const { bridge, calls } = readyBridge(() => ok({}));
    const cases: Array<[Parameters<typeof bridge.act>[0], string[]]> = [
      [{ kind: 'workspace_focus', workspaceId: 'wJ' }, ['workspace', 'focus', 'wJ']],
      [{ kind: 'workspace_close', workspaceId: 'wJ', group: true }, ['workspace', 'close', 'wJ', '--group']],
      [{ kind: 'tab_close', tabId: 'wJ:t1' }, ['tab', 'close', 'wJ:t1']],
      [{ kind: 'pane_zoom', paneId: 'wJ:p2', mode: 'on' }, ['pane', 'zoom', 'wJ:p2', '--on']],
      [{ kind: 'pane_rename', paneId: 'wJ:p2' }, ['pane', 'rename', 'wJ:p2', '--clear']],
      [{ kind: 'pane_resize', paneId: 'wJ:p2', direction: 'up', amount: 0.2 }, ['pane', 'resize', '--direction', 'up', '--amount', '0.2', '--pane', 'wJ:p2']],
      [{ kind: 'pane_move', paneId: 'wJ:p2', to: 'new_tab' }, ['pane', 'move', 'wJ:p2', '--new-tab']],
      [{ kind: 'agent_rename', target: 'wJ:p2', name: 'reviewer' }, ['agent', 'rename', 'wJ:p2', 'reviewer']],
      [{ kind: 'agent_focus', target: 'reviewer' }, ['agent', 'focus', 'reviewer']],
    ];
    for (const [action, expected] of cases) {
      await bridge.act(action);
      assert.deepEqual(calls.at(-1)?.argv, expected, action.kind);
    }
  });
});

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

describe('herdr error mapping', () => {
  it('maps the observed Herdr error codes to actionable messages', () => {
    assert.match(describeHerdrFailure('pane_not_found', 'pane wZ:p9 not found'), /面板不存在/);
    assert.match(describeHerdrFailure('pane_send_failed', 'write failed'), /检查当前面板.*确认输入是否已送达.*不会自动重发/);
    assert.match(describeHerdrFailure('connection_closed', 'EOF'), /无法确认本次输入是否送达.*检查当前面板.*不会自动重发/);
    assert.match(describeHerdrFailure('agent_not_found', 'agent nope not found'), /找不到该 agent/);
    assert.match(describeHerdrFailure('agent_not_ready', 'starting'), /还没准备好/);
    assert.match(describeHerdrFailure('agent_blocked', 'waiting on approval'), /等待确认/);
    assert.match(describeHerdrFailure('agent_prompt_stalled', 'no activity'), /不要重复发送/);
    assert.match(describeHerdrFailure('timeout', 'budget'), /等待超时/);
    assert.equal(describeHerdrFailure(undefined, 'boom'), 'boom');
  });

  it('surfaces a Herdr error envelope as a HerdrError with the raw code', async () => {
    const { bridge } = readyBridge(() => err('pane_not_found', 'pane wZ:p9 not found'));
    await assert.rejects(
      () => bridge.layout('wZ:p9'),
      (error: unknown) => {
        assert.ok(error instanceof HerdrError);
        assert.equal(error.code, 'herdr_failed');
        assert.equal(error.herdrCode, 'pane_not_found');
        assert.match(error.wire(), /^herdr_failed:pane_not_found:/);
        return true;
      },
    );
  });

  it('reports a timeout without pretending success', async () => {
    const { bridge } = readyBridge(() => ({ code: -1, stdout: '', stderr: '', timedOut: true }));
    await assert.rejects(() => bridge.workspaces(), (error: unknown) => {
      assert.ok(error instanceof HerdrError);
      assert.equal(error.herdrCode, 'timeout');
      return true;
    });
  });

  it('reports unparsable output instead of throwing a SyntaxError', async () => {
    const { bridge } = readyBridge(() => raw('this is not json'));
    await assert.rejects(() => bridge.workspaces(), (error: unknown) => {
      assert.ok(error instanceof HerdrError);
      assert.match(error.message, /无法解析/);
      return true;
    });
  });

  it('never retries a stalled prompt', async () => {
    let calls = 0;
    const { bridge } = bridgeWith((argv) => {
      if (argv[0] === '--version') return raw('herdr 0.9.3\n');
      if (argv[0] === 'status') return raw(STATUS_TEXT);
      calls += 1;
      return err('agent_prompt_stalled', 'no activity observed');
    });
    await assert.rejects(() => bridge.prompt('wJ:p2', 'hello', { wait: true }));
    assert.equal(calls, 1, 'prompt must be attempted exactly once');
  });
});

// ---------------------------------------------------------------------------
// AgentCore integration
// ---------------------------------------------------------------------------

function coreWithHerdr(handler?: (argv: string[]) => HerdrResult) {
  const sent: Array<{ msg: AgentMessage; to?: string }> = [];
  const bridgeState = handler ? readyBridge(handler) : undefined;
  const herdr = bridgeState?.bridge;
  const calls = bridgeState?.calls ?? [];
  const socketCalls = bridgeState?.socketCalls ?? [];
  const core = new AgentCore({
    queryFn: fakeQueryFn().fn,
    roots: [process.cwd()],
    defaultCwd: process.cwd(),
    ...(herdr ? { herdr } : {}),
  });
  core.setEmitter((msg, to) => sent.push({ msg, to }));
  return { core, sent, calls, socketCalls };
}

async function request(core: AgentCore, sent: Array<{ msg: AgentMessage; to?: string }>, msg: ClientMessage): Promise<AgentMessage> {
  const id = String(Math.random());
  await core.handle('phone', { ...msg, id });
  const reply = sent.find((s) => 'id' in s.msg && s.msg.id === id);
  assert.ok(reply, `no reply for ${msg.type}`);
  assert.equal(reply.to, 'phone', 'replies must be targeted at the requester');
  return reply.msg;
}

describe('AgentCore herdr routing', () => {
  it('reports the feature as unavailable when no bridge is configured', async () => {
    const { core, sent } = coreWithHerdr();
    const info = await request(core, sent, { type: 'info' });
    assert.ok(info.kind === 'info');
    assert.equal(info.herdr, undefined);
    assert.ok(!(info.capabilities ?? []).includes('herdr'));
    assert.ok(!(info.capabilities ?? []).includes('herdr_paste'));

    const reply = await request(core, sent, { type: 'herdr_workspaces' });
    assert.equal(reply.kind, 'error');
    assert.match(reply.message, /^herdr_unavailable:/);
  });

  it('advertises the herdr capability when the bridge is ready', async () => {
    const { core, sent } = coreWithHerdr(() => ok(WORKSPACE_LIST));
    const info = await request(core, sent, { type: 'info' });
    assert.ok(info.kind === 'info');
    assert.ok((info.capabilities ?? []).includes('herdr'));
    assert.ok((info.capabilities ?? []).includes('herdr_paste'));
    assert.equal(info.herdr?.available, true);
    assert.equal(info.herdr?.version, '0.9.3');
  });

  it('routes every herdr read request to the matching message kind', async () => {
    const { core, sent } = coreWithHerdr((argv) => {
      if (argv[0] === 'workspace') return ok(WORKSPACE_LIST);
      if (argv[0] === 'agent' && argv[1] === 'list') return ok(AGENT_LIST);
      if (argv[0] === 'agent' && argv[1] === 'get') return ok({ agent: AGENT_LIST.agents[0] });
      if (argv[0] === 'tab') return ok({ tabs: [] });
      if (argv[0] === 'pane' && argv[1] === 'list') return ok(PANE_LIST);
      if (argv[0] === 'pane' && argv[1] === 'layout') return ok(LAYOUT);
      if (argv[0] === 'pane' && argv[1] === 'read') return raw('terminal text');
      return err('x', 'unexpected');
    });

    const workspaces = await request(core, sent, { type: 'herdr_workspaces' });
    assert.ok(workspaces.kind === 'herdr_workspaces');
    assert.equal(workspaces.workspaces.length, 2);

    const tabs = await request(core, sent, { type: 'herdr_tabs', workspaceId: 'wJ' });
    assert.ok(tabs.kind === 'herdr_tabs');
    assert.equal(tabs.workspaceId, 'wJ');

    const panes = await request(core, sent, { type: 'herdr_panes', workspaceId: 'wJ' });
    assert.ok(panes.kind === 'herdr_panes');

    const agents = await request(core, sent, { type: 'herdr_agents' });
    assert.ok(agents.kind === 'herdr_agents');
    assert.equal(agents.agents[1]?.target, 'pi-go-curriculum-review');

    const agent = await request(core, sent, { type: 'herdr_agent', target: 'wJ:p1' });
    assert.ok(agent.kind === 'herdr_agent');

    const layout = await request(core, sent, { type: 'herdr_layout', paneId: 'wJ:p2' });
    assert.ok(layout.kind === 'herdr_layout');

    const output = await request(core, sent, { type: 'herdr_read', paneId: 'wJ:p2', source: 'recent-unwrapped', lines: 40 });
    assert.ok(output.kind === 'herdr_output');
    assert.equal(output.text, 'terminal text');
    assert.equal(output.source, 'recent-unwrapped');
  });

  it('routes mutating requests and reports a summary', async () => {
    const { core, sent, socketCalls } = coreWithHerdr((argv) =>
      argv[0] === 'pane' ? ok({ pane: { pane_id: 'wJ:p3' } }) : ok({}),
    );
    const split = await request(core, sent, {
      type: 'herdr_act',
      action: { kind: 'pane_split', paneId: 'wJ:p2', direction: 'down' },
    });
    assert.ok(split.kind === 'herdr_result');
    assert.equal(split.action, 'pane_split');
    assert.match(split.summary, /wJ:p3/);

    const prompt = await request(core, sent, { type: 'herdr_prompt', target: 'wJ:p2', text: 'hi' });
    assert.ok(prompt.kind === 'herdr_result');

    const keys = await request(core, sent, { type: 'herdr_send_keys', target: 'wJ:p2', keys: ['esc'] });
    assert.ok(keys.kind === 'herdr_result');

    const text = await request(core, sent, { type: 'herdr_send_text', paneId: 'wJ:p2', text: '\u0000 \u0003中文' });
    assert.ok(text.kind === 'herdr_result');
    assert.deepEqual(socketCalls[0]?.params, { pane_id: 'wJ:p2', text: '\u0000 \u0003中文' });

    const run = await request(core, sent, { type: 'herdr_run', paneId: 'wJ:p2', command: 'echo hi' });
    assert.ok(run.kind === 'herdr_result');
  });

  it('routes clipboard paste separately from default and explicit raw input', async () => {
    const { core, sent, socketCalls } = coreWithHerdr(() => err('x', 'unexpected CLI mutation'));
    const text = '  中文\t\u0000\r\n\u007f\u001b[A\u0003  ';
    for (const paste of [undefined, false, true]) {
      const reply = await request(core, sent, { type: 'herdr_send_text', paneId: 'wJ:p2', text, paste });
      assert.ok(reply.kind === 'herdr_result');
      assert.equal(reply.action, 'send_text');
    }
    assert.deepEqual(socketCalls.map((call) => ({ method: call.method, params: call.params })), [
      { method: 'pane.send_text', params: { pane_id: 'wJ:p2', text } },
      { method: 'pane.send_text', params: { pane_id: 'wJ:p2', text } },
      { method: 'pane.send_input', params: { pane_id: 'wJ:p2', text } },
    ]);
  });

  it('preserves invalid runtime paste flags for bridge validation', async () => {
    const { core, sent, calls, socketCalls } = coreWithHerdr(() => ok({}));
    for (const paste of [null, 'true', 1]) {
      const reply = await request(core, sent, {
        type: 'herdr_send_text', paneId: 'wJ:p2', text: 'clipboard', paste,
      } as unknown as ClientMessage);
      assert.ok(reply.kind === 'error');
      assert.match(reply.message, /^herdr_invalid_argument:/);
      assert.match(reply.message, /粘贴.*布尔/);
    }
    assert.equal(calls.length, 0);
    assert.equal(socketCalls.length, 0);
  });

  it('rejects an injection attempt routed through the request layer', async () => {
    const { core, sent, calls } = coreWithHerdr(() => ok({}));
    const reply = await request(core, sent, { type: 'herdr_read', paneId: 'wJ:p2; rm -rf /' });
    assert.equal(reply.kind, 'error');
    assert.match(reply.message, /^herdr_invalid_argument:/);
    // Availability probing is allowed; the malicious pane id must never be run.
    assert.ok(!calls.some((c) => c.argv.includes('wJ:p2; rm -rf /')));
  });

  it('keeps herdr failures typed through the wire message', async () => {
    const { core, sent } = coreWithHerdr(() => err('agent_blocked', 'waiting on approval'));
    const reply = await request(core, sent, { type: 'herdr_prompt', target: 'wJ:p2', text: 'go' });
    assert.equal(reply.kind, 'error');
    assert.match(reply.message, /^herdr_failed:agent_blocked:/);
    assert.match(reply.message, /等待确认/);
  });
});

// ---------------------------------------------------------------------------
// Recorded fixtures on disk stay parseable
// ---------------------------------------------------------------------------

describe('herdr probe fixtures', () => {
  // Tests run with cwd = server/, so walk up to the repo root.
  const dir = path.resolve('..', '.build', 'pi-herdr', 'herdr-probe');

  it('parses every recorded live probe file', async () => {
    const workspaceList = JSON.parse(await readFile(path.join(dir, 'workspace-list.json'), 'utf8'));
    const agentList = JSON.parse(await readFile(path.join(dir, 'agent-list.json'), 'utf8'));
    assert.ok(Array.isArray(workspaceList.result.workspaces));
    assert.ok(Array.isArray(agentList.result.agents));
    assert.ok(workspaceList.result.workspaces.length > 0);
    assert.ok(agentList.result.agents.length > 0);

    // Replay the recorded envelopes verbatim through the bridge.
    const { bridge } = readyBridge((argv) =>
      argv[0] === 'workspace' ? raw(JSON.stringify(workspaceList)) : raw(JSON.stringify(agentList)),
    );
    const workspaces = await bridge.workspaces();
    assert.ok(workspaces.every((w) => w.workspaceId.startsWith('w')));
    assert.ok(workspaces.every((w) => typeof w.label === 'string'));

    const agents = await bridge.agents();
    assert.ok(agents.every((a) => a.target.length > 0));
    assert.ok(agents.every((a) => a.paneId.includes(':')));
  });
});
