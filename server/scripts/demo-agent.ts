// Relay + agent with a scripted stand-in for Claude. Lets you try the phone
// UI (streaming, tool calls, permission prompts, questions) without a real
// Claude session or any token usage.
//
//   npm run demo                     (prints a pairing code)
//   node scripts/demo-agent.ts --port 8790 --agent-id demo-agent-1 --secret demo-secret

import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { AgentCore } from '../src/agent/core.ts';
import { RelayLink } from '../src/agent/link.ts';
import { AsyncQueue } from '../src/agent/queue.ts';
import type { QueryFn, QueryHandle } from '../src/agent/session.ts';
import { createRelay } from '../src/relay/relay.ts';
import { consoleLogger } from '../src/shared/log.ts';

const { values } = parseArgs({
  options: {
    port: { type: 'string', default: '8790' },
    'agent-id': { type: 'string', default: 'demo-agent-0001' },
    secret: { type: 'string', default: 'demo-secret' },
    root: { type: 'string' },
    fast: { type: 'boolean' },
  },
});

const pause = (ms: number) => new Promise((r) => setTimeout(r, values.fast ? Math.min(ms, 5) : ms));

const demoQuery: QueryFn = ({ prompt, options }) => {
  const out = new AsyncQueue<unknown>();
  let aborted = new AbortController();
  let turn = 0;

  const emitText = async (text: string) => {
    for (const chunk of text.match(/.{1,6}/gsu) ?? []) {
      out.push({ type: 'stream_event', parent_tool_use_id: null, event: { type: 'content_block_delta', delta: { type: 'text_delta', text: chunk } } });
      await pause(40);
    }
    out.push({ type: 'assistant', parent_tool_use_id: null, message: { content: [{ type: 'text', text }] } });
  };

  const tool = async (id: string, name: string, input: Record<string, unknown>, result: string) => {
    out.push({ type: 'assistant', parent_tool_use_id: null, message: { content: [{ type: 'tool_use', id, name, input }] } });
    await pause(300);
    const decision = await options.canUseTool(name, input, { signal: aborted.signal, toolUseID: id, suggestions: [{ type: 'addRules' }] });
    const denied = decision.behavior === 'deny';
    out.push({
      type: 'user',
      parent_tool_use_id: null,
      message: { content: [{ type: 'tool_result', tool_use_id: id, content: denied ? `Denied: ${decision.message}` : result, is_error: denied }] },
    });
    return decision;
  };

  void (async () => {
    out.push({ type: 'system', subtype: 'init', session_id: `demo-${Date.now()}`, model: 'demo-model', cwd: options.cwd, permissionMode: options.permissionMode });
    for await (const msg of prompt) {
      turn++;
      aborted = new AbortController();
      const started = Date.now();
      try {
        out.push({ type: 'assistant', parent_tool_use_id: null, message: { content: [{ type: 'thinking', thinking: `The user said: "${msg.message.content}". Let me look at the project first.` }] } });
        await pause(400);
        await emitText('好的，我先看一下项目结构。');
        await tool(`t${turn}a`, 'Bash', { command: 'git status --short', description: '查看工作区状态' }, ' M lib/main.dart\n?? lib/new_file.dart');
        await pause(300);
        await emitText('有一个文件需要修改，我来更新它：\n\n```dart\nvoid main() => runApp(const App());\n```');
        await tool(`t${turn}b`, 'Edit', { file_path: path.join(options.cwd, 'lib', 'main.dart'), old_string: 'void main() {}', new_string: 'void main() => runApp(const App());' }, 'The file has been updated.');
        if (turn === 1) {
          const answer = await options.canUseTool(
            'AskUserQuestion',
            { questions: [{ question: '要同时补充单元测试吗？', header: '测试', multiSelect: false, options: [{ label: '要', description: '为修改的函数加测试' }, { label: '不用', description: '只改代码' }] }] },
            { signal: aborted.signal, toolUseID: `q${turn}` },
          );
          const picked = answer.behavior === 'allow' ? JSON.stringify(answer.updatedInput?.answers ?? {}) : '（未回答）';
          await emitText(`收到你的选择：${picked}`);
        }
        await emitText('完成了。');
        out.push({ type: 'result', subtype: 'success', is_error: false, result: '完成了。', total_cost_usd: 0.0123 * turn, duration_ms: Date.now() - started, num_turns: 3 });
      } catch (err) {
        out.push({ type: 'result', subtype: 'error_during_execution', is_error: true, errors: [String(err)], total_cost_usd: 0, duration_ms: 0, num_turns: 0 });
      }
    }
    out.end();
  })();

  const handle: QueryHandle = {
    [Symbol.asyncIterator]: () => out[Symbol.asyncIterator](),
    interrupt: async () => aborted.abort(),
    setPermissionMode: async () => {},
    close: () => out.end(),
  };
  return handle;
};

const log = consoleLogger('demo');
const port = Number(values.port);
const relay = createRelay({ logger: log });
await relay.listen(port, '0.0.0.0');
const root = values.root ?? (await mkdtemp(path.join(tmpdir(), 'ct-demo-')));
const core = new AgentCore({ queryFn: demoQuery, roots: [root], defaultCwd: root, logger: log });
const link = new RelayLink({
  url: `ws://127.0.0.1:${port}/ws`,
  agentId: values['agent-id']!,
  secret: values.secret!,
  name: 'demo-pc',
  core,
  logger: log,
  onOnline: async () => {
    const code = await link.requestPairCode();
    console.log(`DEMO READY port=${port} agentId=${values['agent-id']} pairCode=${code.display} root=${root}`);
  },
});
link.start();

process.on('SIGINT', () => {
  link.stop();
  void relay.close().then(() => process.exit(0));
});
process.on('SIGTERM', () => {
  link.stop();
  void relay.close().then(() => process.exit(0));
});
