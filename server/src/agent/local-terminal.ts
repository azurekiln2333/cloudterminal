import type { TerminalSession } from './terminal-session.ts';

/** Ctrl-] releases local control only. Remote clients and the PTY stay alive. */
export function attachLocalTerminal(session: TerminalSession, onDetach: () => void): () => void {
  const input = process.stdin;
  const output = process.stdout;
  const wasRaw = input.isRaw;
  const resize = () => {
    if (session.status !== 'closed') session.resize(Math.max(2, Math.min(500, output.columns || 80)), Math.max(1, Math.min(300, output.rows || 24)));
  };
  let detached = false;
  let release = () => {};
  const detach = () => {
    if (detached) return;
    detached = true;
    input.removeListener('data', data);
    output.removeListener('resize', resize);
    clearInterval(checkExit);
    release();
    if (input.isTTY && input.isRaw !== wasRaw) input.setRawMode(wasRaw ?? false);
    output.write('\x1b[?1049l');
    onDetach();
  };
  const data = (chunk: string) => {
    const index = chunk.indexOf('\x1d');
    try {
      if (index < 0) session.write(chunk);
      else { if (index) session.write(chunk.slice(0, index)); detach(); }
    } catch { detach(); }
  };
  input.setEncoding('utf8');
  if (input.isTTY && !input.isRaw) input.setRawMode(true);
  resize();
  output.write('\x1b[?1049h\x1b[2J\x1b[H');
  release = session.attach((chunk) => output.write(chunk));
  input.on('data', data);
  input.resume();
  output.on('resize', resize);
  const checkExit = setInterval(() => { if (session.status === 'closed') detach(); }, 100);
  checkExit.unref();
  return detach;
}
