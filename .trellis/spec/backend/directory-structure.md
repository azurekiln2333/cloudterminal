# Directory Structure (server/)

Node.js ≥ 23.6 runs the TypeScript directly (type stripping). There is no
build step; `tsc --noEmit` only type-checks.

```
server/
├── src/
│   ├── shared/        # protocol.ts (wire contract), crypto, log — no deps on relay/agent
│   ├── relay/         # relay.ts (createRelay), main.ts (entrypoint)
│   └── agent/
│       ├── session.ts   # one Claude session around SDK query(); structural SDK types
│       ├── normalize.ts # SDK message → EventBody (pure, defensive)
│       ├── core.ts      # AgentCore: request dispatch, subscriptions, path confinement
│       ├── link.ts      # RelayLink: outbound socket, reconnect, pairing codes
│       ├── sdk.ts       # the ONLY file importing @anthropic-ai/claude-agent-sdk
│       ├── config.ts    # ~/.cloudterminal/agent.json
│       └── main.ts      # CLI
├── test/              # node:test, *.test.ts; fake-query.ts / helpers.ts are support
└── scripts/           # e2e.ts (real Claude), demo-agent.ts (scripted Claude)
```

## Rules

- Imports use explicit `.ts` extensions and `import type` for types
  (`verbatimModuleSyntax`, `erasableSyntaxOnly`): no enums, no parameter
  properties, no namespaces.
- Code that talks to the SDK depends on the structural types in
  `session.ts` (`QueryFn`, `QueryHandle`), never on SDK types directly, so
  tests can inject `FakeQuery`. Only `sdk.ts` casts between the two.
- Every client-supplied path goes through `AgentCore.checkPath` (resolve +
  confine to `--root`).
- User-facing strings sent to the phone are Chinese; log messages are English.
