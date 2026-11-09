import { randomUUID } from 'node:crypto';
import type { AgentMessage, CodexAvailability, CodexItem, CodexPendingRequest, CodexProject, CodexThread, CodexTurn } from '../shared/protocol.ts';
import { DesktopCodexRpc, type CodexRpc, type RpcFrame } from './codex-rpc.ts';

type ObjectValue = Record<string, unknown>;
const object = (value: unknown): ObjectValue => value && typeof value === 'object' && !Array.isArray(value) ? value as ObjectValue : {};
const array = (value: unknown): unknown[] => Array.isArray(value) ? value : [];
const string = (value: unknown): string => typeof value === 'string' ? value : '';
function required(value: unknown, name: string): string {
  if (typeof value !== 'string' || !value.trim() || value.length > 4096) throw new Error(`无效的 Codex ${name}`);
  return value;
}
function cursor(value: unknown): string | undefined { return value === undefined ? undefined : required(value, '分页游标'); }
const nextCursor = (value: unknown): string | undefined => string(value) || undefined;

export type CodexSnapshot = { thread: CodexThread; turns: CodexTurn[]; nextCursor?: string; pendingRequests: CodexPendingRequest[] };
type Pending = { id: string | number; threadId: string; turnId: string; method: string; params: ObjectValue; view: CodexPendingRequest };

export class CodexBridge {
  private readonly rpc: CodexRpc;
  private readonly pending = new Map<string, Pending>();
  private readonly joined = new Set<string>();
  private readonly busy = new Set<string>();
  private readonly dirty = new Set<string>();
  private changeTimer?: NodeJS.Timeout;
  private emit: (message: AgentMessage) => void = () => {};

  constructor(rpc: CodexRpc = new DesktopCodexRpc()) {
    this.rpc = rpc;
    rpc.onFrame = (frame) => this.frame(frame);
    rpc.onDisconnect = () => {
      this.pending.clear(); this.joined.clear();
      this.emit({ kind: 'codex_changed' });
    };
  }

  setEmitter(emit: (message: AgentMessage) => void): void { this.emit = emit; }
  async availability(): Promise<CodexAvailability> {
    try { await this.rpc.connect(); return { available: true, canControl: this.rpc.canControl, ...(!this.rpc.canControl ? { reason: '该 Codex daemon 版本仅支持查看，请更新桌面应用以启用控制' } : {}) }; }
    catch (err) { return { available: false, canControl: false, reason: err instanceof Error ? err.message : 'Codex Desktop 不可用' }; }
  }

  async projects(page?: string): Promise<{ projects: CodexProject[]; nextCursor?: string }> {
    const result = object(await this.rpc.request('project/list', { limit: 50, cursor: cursor(page) }));
    return { projects: array(result.data).map((value) => {
      const p = object(value);
      return { id: required(p.id, '项目 ID'), title: string(p.name), roots: array(p.roots).map((r) => string(object(r).path)).filter(Boolean) };
    }), nextCursor: nextCursor(result.nextCursor) };
  }

  async threads(projectId?: string, page?: string): Promise<{ threads: CodexThread[]; nextCursor?: string }> {
    const result = object(await this.rpc.request('thread/list', {
      limit: 50, cursor: cursor(page), sortKey: 'updated_at', sortDirection: 'desc', useStateDbOnly: true,
      ...(projectId === undefined ? {} : { projectId: required(projectId, '项目 ID') }),
    }));
    return { threads: array(result.data).map((t) => normalizeThread(t)), nextCursor: nextCursor(result.nextCursor) };
  }

  private async metadata(threadId: string): Promise<ObjectValue> {
    return object(object(await this.rpc.request('thread/read', { threadId: required(threadId, '会话 ID'), includeTurns: false })).thread);
  }

  async read(threadId: string, page?: string): Promise<CodexSnapshot> {
    const pageCursor = cursor(page);
    const raw = await this.metadata(threadId);
    const result = object(await this.rpc.request('thread/turns/list', { threadId, cursor: pageCursor, limit: 10, sortDirection: 'desc', itemsView: 'full' }));
    const turns = array(result.data).map(normalizeTurn).reverse();
    const thread = normalizeThread(raw);
    thread.activeTurnId = thread.status === 'active'
      ? (pageCursor ? await this.currentTurn(threadId) : turns.findLast((turn) => turn.status === 'inProgress')?.id)
      : undefined;
    return { thread, turns, nextCursor: nextCursor(result.nextCursor), pendingRequests: this.requests(threadId) };
  }

  private async exclusive<T>(threadId: string, fn: () => Promise<T>): Promise<T> {
    required(threadId, '会话 ID');
    if (this.busy.has(threadId)) throw new Error('此 Codex 会话有操作正在处理，请稍后重试');
    this.busy.add(threadId);
    try { return await fn(); } finally { this.busy.delete(threadId); }
  }

  async resume(threadId: string): Promise<CodexSnapshot> {
    return this.exclusive(threadId, async () => {
      const thread = normalizeThread(await this.metadata(threadId));
      if (!this.rpc.canControl) throw new Error('Codex daemon 版本不支持远程控制，请更新桌面应用');
      if (!thread.canResume) throw new Error('该会话由其他客户端管理，目前仅可查看');
      await this.join(threadId);
      return this.read(threadId);
    });
  }

  private async join(threadId: string): Promise<void> {
    const result = object(await this.rpc.request('thread/resume', { threadId, excludeTurns: true }));
    if (!normalizeThread(result.thread).canAcceptDirectInput) throw new Error('Codex Desktop 不允许直接控制该会话');
    this.joined.add(threadId);
  }

  private async controllable(threadId: string): Promise<CodexThread> {
    const thread = normalizeThread(await this.metadata(threadId));
    if (!this.rpc.canControl) throw new Error('Codex daemon 版本不支持远程控制，请更新桌面应用');
    if (!thread.canAcceptDirectInput) throw new Error('该 Codex 会话目前仅可查看；请先恢复可用的历史会话');
    return thread;
  }

  private async currentTurn(threadId: string): Promise<string | undefined> {
    const result = object(await this.rpc.request('thread/turns/list', { threadId, limit: 1, sortDirection: 'desc', itemsView: 'notLoaded' }));
    const turn = object(array(result.data)[0]);
    return turn.status === 'inProgress' ? string(turn.id) || undefined : undefined;
  }

  async send(threadId: string, text: string, turnId?: string): Promise<void> {
    if (typeof text !== 'string' || !text.trim() || text.length > 100_000) throw new Error('Codex 消息不能为空或超过 100000 字符');
    if (turnId !== undefined) required(turnId, '轮次 ID');
    await this.exclusive(threadId, async () => {
      const thread = await this.controllable(threadId);
      if (turnId && (thread.status !== 'active' || await this.currentTurn(threadId) !== turnId)) throw new Error('当前轮次已变化，请刷新后追加消息');
      if (!this.joined.has(threadId)) await this.join(threadId);
      const input = [{ type: 'text', text, text_elements: [] }];
      if (turnId) await this.rpc.request('turn/steer', { threadId, expectedTurnId: turnId, input });
      else {
        if (thread.status === 'active') throw new Error('会话正在运行，请刷新后使用当前轮次追加消息');
        // Preserve the desktop's sandbox, approval policy, reviewer and model.
        await this.rpc.request('turn/start', { threadId, input });
      }
      this.changed(threadId);
    });
  }

  async interrupt(threadId: string, turnId: string): Promise<void> {
    required(turnId, '轮次 ID');
    await this.exclusive(threadId, async () => {
      const thread = await this.controllable(threadId);
      if (thread.status !== 'active' || await this.currentTurn(threadId) !== turnId) throw new Error('当前轮次已结束或变化，请刷新');
      await this.rpc.request('turn/interrupt', { threadId, turnId });
      this.changed(threadId);
    });
  }

  async respond(threadId: string, requestId: string, decision: string, answers?: Record<string, string[]>): Promise<void> {
    required(threadId, '会话 ID'); required(requestId, '审批 ID');
    if (!['accept', 'decline', 'cancel'].includes(decision)) throw new Error('无效的 Codex 审批决定');
    const entry = this.pending.get(requestId);
    if (!entry || entry.threadId !== threadId) throw new Error('审批已完成或已失效，请刷新');
    if (decision === 'accept' && !entry.view.canAccept) throw new Error('此请求需要在 Codex Desktop 处理，手机仅可拒绝或取消');
    let result: unknown;
    if (entry.view.kind === 'userInput') {
      const mapped: Record<string, { answers: string[] }> = {};
      if (decision === 'accept') {
        const supplied = object(answers);
        for (const q of entry.view.questions ?? []) {
          const values = supplied[q.id];
          if (!Array.isArray(values) || values.length === 0 || values.length > 20 || values.some((v) => typeof v !== 'string' || !v.trim() || v.length > 10_000)) throw new Error('请回答所有 Codex 问题');
          mapped[q.id] = { answers: values as string[] };
        }
      }
      result = { answers: mapped };
    } else if (entry.view.kind === 'permissions') result = { permissions: {}, scope: 'turn' };
    else if (entry.view.kind === 'unsupported') {
      this.rpc.reject(entry.id, 'Remote client declined unsupported request; use Codex Desktop.');
      this.pending.delete(requestId); this.pendingChanged(threadId); return;
    } else if (entry.method === 'execCommandApproval' || entry.method === 'applyPatchApproval') {
      result = { decision: decision === 'accept' ? 'approved' : decision === 'cancel' ? 'abort' : 'denied' };
    } else result = { decision };
    this.rpc.respond(entry.id, result);
    this.pending.delete(requestId);
    this.pendingChanged(threadId);
  }

  private requests(threadId: string): CodexPendingRequest[] { return [...this.pending.values()].filter((r) => r.threadId === threadId).map((r) => r.view); }
  private pendingChanged(threadId: string): void { this.emit({ kind: 'codex_pending', threadId, requests: this.requests(threadId) }); }
  private changed(threadId: string): void {
    this.dirty.add(threadId);
    this.changeTimer ??= setTimeout(() => {
      this.changeTimer = undefined;
      for (const id of this.dirty) this.emit({ kind: 'codex_changed', threadId: id });
      this.dirty.clear();
    }, 250);
  }

  private frame(frame: RpcFrame): void {
    const params = object(frame.params);
    const threadId = string(params.threadId) || string(params.conversationId) || string(object(params.thread).id);
    if (frame.id !== undefined && frame.method) {
      if (!threadId || this.pending.size >= 128) { this.rpc.reject(frame.id, 'Unsupported client request'); return; }
      const requestId = randomUUID();
      let kind: CodexPendingRequest['kind'] = 'unsupported';
      if (frame.method === 'item/commandExecution/requestApproval' || frame.method === 'execCommandApproval') kind = 'command';
      if (frame.method === 'item/fileChange/requestApproval' || frame.method === 'applyPatchApproval') kind = 'fileChange';
      if (frame.method === 'item/tool/requestUserInput') kind = 'userInput';
      if (frame.method === 'item/permissions/requestApproval') kind = 'permissions';
      const allowed = params.availableDecisions;
      const view: CodexPendingRequest = {
        requestId, kind,
        title: kind === 'command' ? '执行命令' : kind === 'fileChange' ? '修改文件' : kind === 'userInput' ? '回答问题' : kind === 'permissions' ? '扩展权限（请在桌面审批）' : '请在 Codex Desktop 处理此请求',
        description: [string(params.command) || array(params.command).map(string).join(' '), string(params.reason), string(params.cwd), string(params.grantRoot)].filter(Boolean).join('\n').slice(0, 20_000),
        canAccept: (kind === 'command' && (!Array.isArray(allowed) || allowed.includes('accept'))) || (kind === 'fileChange' && !params.grantRoot) || kind === 'userInput',
      };
      if (kind === 'userInput') view.questions = array(params.questions).map((value) => {
        const q = object(value);
        return { id: string(q.id), header: string(q.header), question: string(q.question), isSecret: q.isSecret === true, isOther: q.isOther === true,
          options: array(q.options).map((o) => ({ label: string(object(o).label), description: string(object(o).description) })) };
      });
      this.pending.set(requestId, { id: frame.id, threadId, turnId: string(params.turnId), method: frame.method, params, view });
      this.pendingChanged(threadId);
      return;
    }
    if (frame.method === 'serverRequest/resolved') {
      for (const [key, request] of this.pending) if (request.threadId === threadId && request.id === params.requestId) this.pending.delete(key);
      this.pendingChanged(threadId);
    }
    if (frame.method === 'turn/completed' || frame.method === 'thread/closed') {
      const turnId = string(object(params.turn).id);
      for (const [key, request] of this.pending) if (request.threadId === threadId && (!turnId || request.turnId === turnId)) this.pending.delete(key);
      this.pendingChanged(threadId);
    }
    if (threadId) this.changed(threadId);
    else if (frame.method === 'project/changed') this.emit({ kind: 'codex_changed' });
  }

  close(): void { if (this.changeTimer) clearTimeout(this.changeTimer); this.changeTimer = undefined; this.dirty.clear(); this.rpc.close(); }
}

function normalizeThread(value: unknown): CodexThread {
  const t = object(value);
  const status = string(object(t.status).type) || 'unknown';
  const canAcceptDirectInput = t.canAcceptDirectInput === true;
  return {
    id: required(t.id, '会话 ID'), projectId: string(t.projectId) || undefined,
    title: string(t.name) || string(t.preview).slice(0, 120) || '未命名会话', cwd: string(t.cwd),
    updatedAt: typeof t.updatedAt === 'number' ? t.updatedAt * 1000 : 0,
    status, canAcceptDirectInput,
    canResume: canAcceptDirectInput || (status === 'notLoaded' && t.canAcceptDirectInput == null && t.ephemeral !== true),
  };
}

function normalizeTurn(value: unknown): CodexTurn {
  const t = object(value);
  const raw = array(t.items);
  // The mobile relay frame is 4 MiB. Keep a bounded, explicitly marked preview.
  const selected = raw.length > 200 ? [...raw.slice(0, 20), { type: 'omitted', id: 'omitted', text: `中间省略 ${raw.length - 200} 条记录，请在桌面查看完整内容` }, ...raw.slice(-180)] : raw;
  let budget = 50_000;
  const items = selected.map((value): CodexItem => {
    const i = object(value), type = string(i.type);
    let kind: CodexItem['kind'] = 'unknown', text = '', toolName: string | undefined;
    if (type === 'userMessage') { kind = 'user'; text = array(i.content).map((c) => string(object(c).text) || `[${string(object(c).type)}]`).join('\n'); }
    else if (type === 'agentMessage') { kind = 'assistant'; text = string(i.text); }
    else if (type === 'reasoning') { kind = 'thinking'; text = [...array(i.summary), ...array(i.content)].map(string).join('\n'); }
    else if (type === 'plan' || type === 'omitted') { kind = 'system'; text = string(i.text); }
    else if (type === 'commandExecution') { kind = 'tool'; toolName = 'command'; text = [string(i.command), string(i.aggregatedOutput)].filter(Boolean).join('\n'); }
    else if (type === 'fileChange') { kind = 'tool'; toolName = type; text = array(i.changes).map((c) => [string(object(c).path), string(object(c).diff)].filter(Boolean).join('\n')).join('\n'); }
    else if (type === 'mcpToolCall' || type === 'dynamicToolCall' || type === 'functionCallOutput') { kind = 'tool'; toolName = string(i.tool) || string(i.name); text = JSON.stringify(i.result ?? i.contentItems ?? i.output ?? i.error ?? i.arguments ?? ''); }
    else { text = `[${type || 'unknown'}] ${string(i.text) || string(i.review) || string(i.path)}`; }
    const limit = Math.min(12_000, budget);
    if (text.length > limit) text = `${text.slice(0, limit)}\n[内容较长，完整记录请在 Codex Desktop 查看]`;
    budget = Math.max(0, budget - text.length);
    return { id: string(i.id), kind, text, ...(toolName ? { toolName } : {}) };
  });
  if (t.error) items.push({ id: `${string(t.id)}-error`, kind: 'error', text: string(object(t.error).message).slice(0, 5000) });
  return { id: string(t.id), status: string(t.status), items };
}
