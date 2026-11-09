# Error Handling

## Scope / Trigger

Request dispatch and relay authentication/transport failures. Sources: `server/src/agent/core.ts`, `server/src/relay/relay.ts`, `server/src/shared/protocol.ts`, `lib/state/remote_controller.dart`.

## Signatures

`AgentCore.handle(clientId: string, msg: ClientMessage): Promise<void>` catches dispatch errors and replies to the requesting client. Dispatch uses ordinary `Error`, not a custom error hierarchy.

## Contracts

Success without a special reply produces `{ kind: 'ack', id }`. Failure produces `{ kind: 'error', id, message }` targeted to the requester. Relay failure uses the outer `{ t: 'error', code, message }` envelope. The Dart controller correlates IDs and converts agent errors to `RemoteException`. Asynchronous session failures use events/state.

## Validation & Error Matrix

| Condition | Behavior |
| --- | --- |
| Missing session | Agent error |
| Empty/outside-root path | Agent error before filesystem operation |
| Non-directory cwd | Agent error before creating session |
| Unknown mode / disabled bypass | Agent error |
| Active-session limit | Agent error before spawning |
| Bad relay credentials | `unauthorized`; app enters `authFailed` |
| Agent offline | App fails pending requests |
| Request timeout | App RemoteException (20-second default) |

Path confinement selects a working directory; it does not sandbox programs run inside it.

## Good / Base / Bad Cases

Good: a request failure goes only to its sender. Base: list_sessions preserves its ID. Bad: an uncaught dispatch error leaves the phone waiting for timeout.

## Tests Required

Extend `server/test/core.test.ts` for validation/routing, `server/test/relay.test.ts` for auth, and `test/remote_controller_test.dart` for request failures/disconnects.

## Wrong vs Correct

```ts
// Wrong: no request ID, broadcasts private failure.
this.emit({ kind: 'error', message });
// Correct (AgentCore.handle):
this.emit({ kind: 'error', id, message }, clientId);
```
