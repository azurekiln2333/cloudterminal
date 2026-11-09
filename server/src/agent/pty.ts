import { spawn } from 'node-pty';

export type PtyHandle = {
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(): void | Promise<void>;
  onData(callback: (data: string) => void): { dispose(): void };
  onExit(callback: (event: { exitCode: number; signal?: number }) => void): { dispose(): void };
};
export type PtyFactory = (options: { cwd: string; cols: number; rows: number }) => PtyHandle;

/** Only this adapter imports native PTY code; tests inject a structural handle. */
export const nativePty: PtyFactory = ({ cwd, cols, rows }) => {
  const windows = process.platform === 'win32';
  const shell = windows ? (process.env.ComSpec ?? 'cmd.exe') : (process.env.SHELL || '/bin/sh');
  const pty = spawn(shell, windows ? [] : ['-i'], {
    name: 'xterm-256color', cwd, cols, rows,
    env: { ...process.env, TERM: 'xterm-256color' },
  });
  // node-pty 1.1.0 leaks its worker on natural exit and races console
  // enumeration against destruction on explicit kill. Keep this version-bound
  // workaround on this instance: enumerate before kill, then reuse the result.
  type WindowsAgent = {
    _getConsoleProcessList?: () => Promise<number[]>;
    _conoutSocketWorker?: { dispose(): void };
  };
  const agent = (pty as unknown as { _agent?: WindowsAgent })._agent;
  let exited = false;
  let disposal: Promise<void> | undefined;
  const dispose = (): Promise<void> => disposal ??= (async () => {
    if (windows && agent?._getConsoleProcessList) {
      const processes = exited ? [] : await agent._getConsoleProcessList();
      agent._getConsoleProcessList = async () => processes;
    }
    try { pty.kill(); } catch (err) {
      if (!exited) throw err;
    } finally {
      if (windows) agent?._conoutSocketWorker?.dispose();
    }
  })();
  if (windows) pty.onExit(() => {
    exited = true;
    void dispose().catch(() => { agent?._conoutSocketWorker?.dispose(); });
  });
  return {
    write: (data) => pty.write(data),
    resize: (cols, rows) => pty.resize(cols, rows),
    kill: dispose,
    onData: (callback) => pty.onData(callback),
    onExit: (callback) => pty.onExit(callback),
  };
};
