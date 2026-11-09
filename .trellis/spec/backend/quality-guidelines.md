# Backend Quality Guidelines

`server/package.json` requires Node >=23.6 and runs TypeScript directly. `server/tsconfig.json` enables strict, noUncheckedIndexedAccess, verbatimModuleSyntax and erasableSyntaxOnly. Use explicit `.ts` extensions and `import type`; avoid runtime enums/parameter properties. There is no configured lint or transpilation build script.

SDK coupling stays in `server/src/agent/sdk.ts`. Structural QueryFn/QueryHandle interfaces in session.ts permit `server/test/fake-query.ts` without authenticated model calls.

## Quality Gate

From `server/`:

```sh
npm run check
npm test
```

Tests use node:test and node:assert/strict. Socket helpers are in `server/test/helpers.ts`. Inject fake dependencies for state transitions and use a local relay for routing/auth integration. Close sockets, processes and servers in teardown.

`npm run e2e` uses real Claude and requires local runtime/credentials; it can consume API usage. `scripts/demo-agent.ts` is scripted behavior and cannot verify real model execution.

## Review Boundaries

Update both protocol files and consumer tests for wire changes. Preserve request IDs, client targeting, event sequences and replay reset. Validate remote inputs at runtime; casts do not validate JSON. Keep resource limits and close paths explicit. Report skipped tests or missing native runtimes separately from passing unit tests.
