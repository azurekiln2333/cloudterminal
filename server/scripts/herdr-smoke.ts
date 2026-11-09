// Opt-in smoke test against the REAL local Herdr installation.
//
//   cd server
//   $env:CLOUDTERMINAL_HERDR_SMOKE=1; node scripts/herdr-smoke.ts
//
// Safety contract:
//   * Refuses to run without the explicit env opt-in.
//   * Only ever creates, inspects and closes workspaces labelled `ct-probe-*`.
//   * Sweeps up leftovers from previous aborted runs first.
//   * Never focuses, renames or closes a pre-existing workspace.
//   * Never starts an agent.
//   * Asserts the workspace count returns to its starting value at the end.

import { HerdrBridge } from '../src/agent/herdr.ts';

const PROBE_PREFIX = 'ct-probe-';

function line(text = ''): void {
  process.stdout.write(`${text}\n`);
}

function step(label: string): void {
  line(`\n=== ${label} ===`);
}

async function main(): Promise<void> {
  if (process.env.CLOUDTERMINAL_HERDR_SMOKE !== '1') {
    line('Refusing to run: set CLOUDTERMINAL_HERDR_SMOKE=1 to allow touching the live Herdr server.');
    line('This script creates and closes a workspace labelled ct-probe-* and nothing else.');
    process.exit(2);
  }

  const bridge = new HerdrBridge({
    logger: { info: () => {}, warn: () => {}, error: () => {} },
  });

  step('availability');
  const availability = await bridge.availability(true);
  line(JSON.stringify(availability, null, 2));
  if (!availability.available) {
    line(`Herdr is not controllable: ${availability.reason ?? 'unknown'}`);
    process.exit(1);
  }

  step('read-only: workspace list');
  const before = await bridge.workspaces();
  const baselineIds = new Set(before.map((w) => w.workspaceId));
  line(`${before.length} workspaces; ids: ${before.map((w) => w.workspaceId).join(' ')}`);

  step('read-only: agent list');
  const agents = await bridge.agents();
  line(`${agents.length} agents`);
  for (const agent of agents.slice(0, 5)) {
    line(`  ${agent.target.padEnd(28)} ${agent.agentKind.padEnd(8)} ${agent.status.padEnd(8)} ${agent.paneId}  ${agent.cwd}`);
  }

  step('read-only: pane output (real screen text)');
  const probePane = agents.find((a) => a.cwd.replace(/\\/g, '/').endsWith('cloudterminal'));
  if (probePane) {
    for (const source of ['visible', 'recent-unwrapped'] as const) {
      const output = await bridge.read(probePane.paneId, source, 12);
      line(`--- ${probePane.paneId} ${source} (${output.text.length} chars) ---`);
      line(output.text.split('\n').slice(0, 8).join('\n'));
    }
  } else {
    line('no cloudterminal pane found; skipping output probe');
  }

  step('sweep leftovers from previous runs');
  for (const workspace of before) {
    if (workspace.label.startsWith(PROBE_PREFIX)) {
      line(`closing leftover ${workspace.workspaceId} (${workspace.label})`);
      await bridge.act({ kind: 'workspace_close', workspaceId: workspace.workspaceId });
    }
  }

  step('create a probe workspace');
  const label = `${PROBE_PREFIX}${Date.now().toString(16)}`;
  const created = await bridge.act({ kind: 'workspace_create', label, focus: false });
  line(created.summary);
  const createdId = (created.data as { workspace?: { workspace_id?: string } } | undefined)?.workspace?.workspace_id;
  line(`created workspace id: ${createdId ?? '(not reported)'}`);

  let ok = true;
  let probeId = createdId;

  step('verify the probe workspace is visible');
  const during = await bridge.workspaces();
  const found = during.find((w) => w.label === label);
  if (!found) {
    line('FAIL: the created workspace does not appear in workspace list');
    ok = false;
  } else {
    probeId = found.workspaceId;
    line(`found ${found.workspaceId} number=${found.number} panes=${found.paneCount} tabs=${found.tabCount} status=${found.agentStatus}`);
    const tabs = await bridge.tabs(found.workspaceId);
    const panes = await bridge.panes(found.workspaceId);
    line(`tabs=${tabs.length} panes=${panes.length} rootPane=${panes[0]?.paneId ?? '?'} cwd=${panes[0]?.cwd ?? '?'}`);
    const layout = await bridge.layout(panes[0]!.paneId);
    line(`layout panes=${layout.panes.length} area=${layout.area.width}x${layout.area.height}`);
  }

  step('close all probe workspaces');
  for (const workspace of await bridge.workspaces()) {
    if (workspace.label.startsWith(PROBE_PREFIX)) {
      line(`closing ${workspace.workspaceId} (${workspace.label})`);
      await bridge.act({ kind: 'workspace_close', workspaceId: workspace.workspaceId });
    }
  }

  step('verify removal and that nothing pre-existing changed');
  const after = await bridge.workspaces();
  if (after.some((w) => w.label.startsWith(PROBE_PREFIX))) {
    line('FAIL: a probe workspace is still present');
    ok = false;
  }
  const afterIds = new Set(after.map((w) => w.workspaceId));
  const missing = [...baselineIds].filter((id) => !afterIds.has(id));
  const added = [...afterIds].filter((id) => !baselineIds.has(id));
  line(`workspaces before=${before.length} after=${after.length}`);
  if (missing.length) {
    line(`FAIL: pre-existing workspaces disappeared: ${missing.join(' ')}`);
    ok = false;
  }
  if (added.length) {
    line(`FAIL: unexpected new workspaces: ${added.join(' ')}`);
    ok = false;
  }
  if (!missing.length && !added.length) line('OK: workspace set is unchanged');

  step('error handling on a bad pane id');
  try {
    await bridge.layout('wZ:p999');
    line('FAIL: expected pane_not_found');
    ok = false;
  } catch (err) {
    line(`expected failure: ${(err as Error).message}`);
  }

  line(`\n${ok ? 'SMOKE PASSED' : 'SMOKE FAILED'}`);
  process.exit(ok ? 0 : 1);
}

await main();
