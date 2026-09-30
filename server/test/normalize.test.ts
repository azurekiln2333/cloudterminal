import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { normalize, parseQuestions, summarizeTool, truncate } from '../src/agent/normalize.ts';
import { sdk } from './fake-query.ts';

describe('normalize', () => {
  it('maps init to session metadata and a system event', () => {
    const n = normalize(sdk.init('abc'));
    assert.deepEqual(n.init, { claudeSessionId: 'abc', model: 'claude-test', mode: 'default', cwd: '/tmp' });
    assert.equal(n.events[0]?.kind, 'system');
  });

  it('maps assistant text, thinking and tool_use blocks', () => {
    const n = normalize({
      type: 'assistant',
      parent_tool_use_id: null,
      message: {
        content: [
          { type: 'thinking', thinking: 'hmm' },
          { type: 'text', text: 'Running tests' },
          { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'npm test', description: 'Run tests' } },
        ],
      },
    });
    assert.deepEqual(
      n.events.map((e) => e.kind),
      ['thinking', 'assistant', 'tool_use'],
    );
    const tool = n.events[2];
    assert.ok(tool?.kind === 'tool_use');
    assert.equal(tool.summary, 'Run tests: npm test');
  });

  it('maps tool results and drops live user text unless asked', () => {
    assert.deepEqual(normalize(sdk.toolResult('t1', 'ok')).events, [
      { kind: 'tool_result', toolUseId: 't1', content: 'ok', isError: false },
    ]);
    const userText = { type: 'user', message: { content: 'hello' } };
    assert.equal(normalize(userText).events.length, 0);
    assert.deepEqual(normalize(userText, { includeUserText: true }).events, [{ kind: 'user', text: 'hello' }]);
  });

  it('joins array tool_result content', () => {
    const n = normalize({
      type: 'user',
      message: {
        content: [
          {
            type: 'tool_result',
            tool_use_id: 'x',
            content: [
              { type: 'text', text: 'a' },
              { type: 'text', text: 'b' },
            ],
          },
        ],
      },
    });
    assert.ok(n.events[0]?.kind === 'tool_result');
    assert.equal(n.events[0].content, 'a\nb');
  });

  it('maps results with cost and error text', () => {
    const ok = normalize(sdk.result(0.5));
    assert.equal(ok.result?.costUsd, 0.5);
    const err = normalize({ type: 'result', subtype: 'error_max_turns', is_error: true, errors: ['too many'] });
    assert.ok(err.events[0]?.kind === 'result');
    assert.equal(err.events[0].text, 'too many');
    assert.equal(err.events[0].isError, true);
  });

  it('extracts top-level text deltas only', () => {
    assert.equal(normalize(sdk.delta('Hel')).delta, 'Hel');
    assert.equal(normalize({ ...sdk.delta('x'), parent_tool_use_id: 'sub' }).delta, undefined);
  });

  it('reports permission mode from status messages', () => {
    assert.equal(normalize({ type: 'system', subtype: 'status', status: null, permissionMode: 'acceptEdits' }).mode, 'acceptEdits');
  });

  it('ignores unknown message types', () => {
    assert.deepEqual(normalize({ type: 'something_new' }).events, []);
    assert.deepEqual(normalize(null).events, []);
  });

  it('summarizes common tools', () => {
    assert.equal(summarizeTool('Read', { file_path: '/a/b.ts' }), '/a/b.ts');
    assert.equal(summarizeTool('Grep', { pattern: 'TODO' }), 'TODO');
    assert.equal(summarizeTool('mcp__x__y', { url: 'https://e.com' }), 'https://e.com');
    assert.equal(summarizeTool('Bash', { command: 'a'.repeat(300) }).length, 158);
  });

  it('parses AskUserQuestion input', () => {
    const q = parseQuestions({
      questions: [
        {
          question: 'Which DB?',
          header: 'DB',
          multiSelect: false,
          options: [
            { label: 'Postgres', description: 'relational' },
            { label: 'SQLite', description: 'embedded' },
          ],
        },
      ],
    });
    assert.equal(q?.[0]?.options.length, 2);
    assert.equal(parseQuestions({}), undefined);
  });

  it('truncates long text', () => {
    const t = truncate('x'.repeat(20), 10);
    assert.ok(t.startsWith('x'.repeat(10)));
    assert.match(t, /10 more characters/);
  });
});
