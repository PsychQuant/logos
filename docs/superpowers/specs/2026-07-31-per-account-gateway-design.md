# Design: per-account inference gateway

**Issue:** to be filed as the IDD entry point when implementation starts — no existing Logos issue
covers gateway/proxy routing (verified against all 100 issues, open and closed).
**Date:** 2026-07-31
**Status:** approved (brainstorming) — ready for implementation plan
**Related:** #12 (per-account `CLAUDE_CONFIG_DIR` credential isolation), #21 (never override `HOME`), #54 (system-default "main" account zero-touch), #50/#80 (`AccountReaper` guarded deletion).

## Context

Logos isolates accounts at the **credential** layer: `ClaudeConfigEnvironment.apply` sets
`CLAUDE_CONFIG_DIR` + `CLAUDE_SECURESTORAGE_CONFIG_DIR` per account, so each account's OAuth
token lands in its own `Claude Code-credentials-<hash>` keychain item (#12).

It does nothing at the **transport** layer. Where an account's API requests actually go is
decided entirely by claude itself, from whatever `ANTHROPIC_BASE_URL` it resolves. Measured on
the maintainer's machine (2026-07-30), that produces an asymmetry nobody chose:

```
main (system-default)  → reads ~/.claude/settings.json
                       → env.ANTHROPIC_BASE_URL = http://127.0.0.1:8787
                       → claude-hot-limit rate-limit-proxy ──→ api.anthropic.com

isolated accounts × 66 → read ~/.logos/accounts/<id>/.claude/settings.json
                       → no env block at all
                       → direct ────────────────────────────→ api.anthropic.com
```

All 66 isolated account dirs were enumerated; **none** carries `ANTHROPIC_BASE_URL` (most have no
`settings.json`, a few have an empty `{}`). So exactly one of 67 accounts is observable to the
rate-limit proxy, and the proxy's pacing decisions run on a ~1.5% sample of real traffic.

Two distinct problems follow, and they need different fixes:

1. **Coverage.** 66 accounts bypass any gateway, so `claude-hot-limit`'s `rate-state.jsonl` and
   its pacing guard are blind to them.
2. **Shared accounting.** Pointing all 67 at the *same* gateway would be worse than the status
   quo for the primary use case: Anthropic rate limits are **per account**, but the proxy keys
   its state on one file per state-directory. One account hitting 429 would make the admission
   gate hold requests for every other account — destroying the entire point of keeping multiple
   accounts to rotate between.

The requirement, as stated by the maintainer: *不同帳號應該要走完全不同的 gateway.* Confirmed to
mean all four of — quota non-interference, full observability, per-account upstream, and
architectural (not merely incidental) isolation.

## Verified facts (not assumed)

Three findings constrain the design. Each was checked against the primary source rather than
recalled.

### 1. A settings-file `env` entry beats a process env var

From the Claude Code [environment variables](https://code.claude.com/docs/en/env-vars) doc,
§ Precedence:

> "When the same variable is set in both your shell and a settings file `env` block, **the
> settings file value applies**. Claude Code writes each `env` entry into the process environment
> at startup and again when the file changes, replacing the value inherited from the shell."

**Consequence.** Injecting `ANTHROPIC_BASE_URL` into the spawned process's environment works for
an isolated account (whose `settings.json` is absent or empty) but is *silently overridden* for
main, whose settings come from the user's global `~/.claude/settings.json`. Logos cannot route
main by env injection, and per #54 it must not write into the user's global settings.

### 2. Routing off `api.anthropic.com` disables Remote Control

Same doc, `ANTHROPIC_BASE_URL` row:

> "As of v2.1.196, [Remote Control] is disabled when this points at a host other than
> `api.anthropic.com`" — and MCP tool search is disabled by default unless `ENABLE_TOOL_SEARCH=true`.

**Consequence.** The 66 isolated accounts currently keep Remote Control precisely *because* they
go direct. Routing them through a gateway takes it away. This is an accepted, documented cost,
not a regression to fix later.

### 3. The proxy's readiness line prints the *requested* port, not the bound one

`rate-limit-proxy.py` `main()`:

```python
port = int(os.environ.get("RATE_LIMIT_PROXY_PORT", DEFAULT_PORT))
server = ThreadingHTTPServer(("127.0.0.1", port), ProxyHandler)
...
print("[rate-limit-proxy] listening on 127.0.0.1:%d, upstream=%s" % (port, resolve_upstream()))
```

**Consequence.** `RATE_LIMIT_PROXY_PORT=0` would let the OS assign a free port but print
`127.0.0.1:0`, so the actual port is unrecoverable from stdout. Logos must therefore allocate the
port itself and pass a concrete number. (A one-line upstream fix — printing
`server.server_address[1]` — would remove this constraint; out of scope here.)

The proxy already exposes every knob the design needs, so **no plugin change is required**:
`RATE_LIMIT_PROXY_PORT`, `RATE_LIMIT_PROXY_UPSTREAM`, and `CLAUDE_HOT_LIMIT_DATA` (state dir).

## Design

A new module, `Sources/LogosGateway/`, owns gateway lifecycle. Logos spawns, supervises, and
reaps gateway processes, but stays ignorant of the proxy's wire protocol — it runs a **configured
command**, defaulting to an auto-detected `claude-hot-limit` proxy.

### Granularity: per active account, refcounted

Not per window: two windows on the same account genuinely spend the same quota, so they *should*
share one rate-limit bucket. Not per registered account either: 66 resident Python processes for
the handful actually running would be absurd. The pool is therefore **lazy and refcounted** —
the first session to use an account starts its gateway, the last one to leave tears it down.

### Components

| Type | Responsibility | Kind |
|------|----------------|------|
| `GatewayDescriptor` | What to run for one account: argv, port, state dir, upstream. Computed `baseURL` = `http://127.0.0.1:<port>` | value |
| `GatewayCommandResolver` | Resolve the default command by globbing `~/.claude/plugins/cache/claude-hot-limit/*/proxy/rate-limit-proxy.py` and picking the highest **semver**. Returns nil when absent | pure (injected fs) |
| `PortAllocator` | Bind `127.0.0.1:0`, read back the assigned port, close, return it; remember ports already handed out this process | actor |
| `GatewayProcess` | One supervised child: spawn, readiness, health, `SIGTERM` → grace → `SIGKILL` | actor |
| `GatewayPool` | Refcounted registry keyed by `account.id`: `acquire` / `release` / `shutdown` | actor |

Each unit is separately testable: the resolver and the env transform are pure; the pool's
refcount semantics are exercised against a stub launcher; `GatewayProcess` runs a fake script
rather than the real proxy.

### main stays out of the pool

`acquire(account:)` returns `nil` for the system-default account. Main keeps whatever
`~/.claude/settings.json` specifies, and Logos never touches it — the same zero-touch
principle #54 established for its credentials, applied to its routing.

This is the design's largest compromise, and it is load-bearing rather than lazy: fact 1 above
makes env injection ineffective for main, and the alternatives are worse. Giving main a
Logos-managed config dir would reopen the keychain breakage #54 exists to prevent; writing into
the user's global settings would mutate configuration Logos does not own.

The compromise also mostly dissolves on inspection. Once the other 66 accounts are routed to
their own ports, `8787` is used by main alone, so main *does* end up on a gateway of its own —
just an ambient one, shared with non-Logos `claude` sessions running as the same identity, which
is correct since they spend the same quota.

### Env transform: inject, and strip

`ClaudeConfigEnvironment.apply` gains a `gatewayBaseURL: URL?` parameter and keeps its existing
red line — it still only sets environment variables, and never reads, writes, or moves a
credential.

```
gatewayBaseURL != nil  → env["ANTHROPIC_BASE_URL"] = url.absoluteString
gatewayBaseURL == nil  → env.removeValue(forKey: "ANTHROPIC_BASE_URL")
```

The `nil` branch is not defensive boilerplate. It mirrors the existing #54 strip of a stale
inherited `CLAUDE_CONFIG_DIR`, and guards the same failure shape: if Logos is ever launched from
a shell that exports `ANTHROPIC_BASE_URL`, `LoginShellEnvironment` captures it and every account
silently joins main's gateway — the exact bug this change exists to fix, re-entering through the
back door.

### Semver, not lexicographic

The resolver must order plugin versions numerically. The maintainer's machine currently holds
both `1.9.0` and `1.19.0`; a lexicographic `max()` picks `1.9.0`. This is the resolver's first
test case, not a hypothetical.

### Data layout

Per-account proxy state lives at `~/.logos/accounts/<id>/hot-limit/` — **inside** the account
directory. `AccountReaper` already removes `~/.logos/accounts/<id>` wholesale, so state is
cleaned up with the account and the reaper needs no change.

The ordering constraint that does need code: `AccountManager.remove` must call
`GatewayPool.shutdown(account:)` **before** handing off to the reaper, or the reaper deletes the
working directory of a live process.

### Settings surface

- `AdvancedSettings.gatewayEnabled: Bool` — default `true`.
- `AdvancedSettings.gatewayCommand: [String]?` — `nil` means auto-detect. Stored as **argv**, not
  a shell string, so nothing is ever handed to a shell for word-splitting and a path containing
  spaces needs no quoting. It is the first user-editable persisted argv in `AdvancedSettings`
  (`claudeExtraArgs` is `[String]` but derived from a Bool, not stored), so it needs its own
  `PersistedDTO` field and a `decodeIfPresent` default of `nil`.
- `Account.upstream: String?` — per-account upstream override, persisted in `index.json`, decoded
  with the same `decodeIfPresent` backward-compatibility pattern `isSystemDefault` already uses so
  existing indexes keep loading.

## Failure policy

Calibrated to whether the account has a custom upstream, because the two cases fail differently:

| Case | Policy | Why |
|------|--------|-----|
| Default upstream (`api.anthropic.com`) | **Fail open**, with a persistent in-window banner | The gateway is only pacing/observability. Falling back to direct loses telemetry but the account still works; bricking it would be a worse trade. |
| Custom upstream configured | **Fail closed** — refuse to spawn, explain why | Silently falling back would send traffic to `api.anthropic.com` when the operator directed it elsewhere. That is a routing-policy violation, not a degradation. |

Both surface through the same in-window banner slot the existing `NoActiveAccountBanner` uses
(`WindowAccountResolver` already degrades to a banner rather than spawning into a phantom
config), so this adds a banner case rather than a new presentation mechanism. Fail-open renders
the banner **with** a live terminal beneath it; fail-closed renders it **instead of** one.

## Units and boundaries

- `GatewayCommandResolver` and the extended `ClaudeConfigEnvironment.apply` are pure functions:
  input → output, no process or filesystem side effects at their boundary (the resolver takes an
  injected filesystem).
- `GatewayPool` is the only type that knows about refcounts; `GatewayProcess` is the only type
  that knows about `Process`, signals, and readiness. Neither can be observed through the other.
- `ClaudeProcessConfig` gains one `gatewayBaseURL` parameter and stays a descriptor — the spawn
  site awaits `pool.acquire(account:)` and passes the result in.

## Edge cases & error handling

- **Port race.** `PortAllocator` closes the probe socket before the child binds, leaving a small
  TOCTOU window. Accepted and documented; a bind failure is retried with a fresh port, bounded.
- **Gateway crash mid-session.** `GatewayProcess` restarts with bounded backoff. Exhausted
  backoff surfaces through the failure policy above.
- **Plugin absent.** Resolver returns nil → treated as "no gateway configured" → the failure
  policy decides (fail-open for a default upstream).
- **Rapid session churn.** Teardown lingers **5 seconds** at refcount 0 so an immediate restart
  (account switch, window reopen) reuses the running gateway instead of paying spawn + readiness
  again. Long enough to cover a switch, short enough that a genuinely idle gateway does not
  outlive its usefulness. A re-`acquire` during the linger cancels the pending teardown.
- **Remote Control loss.** Documented in the settings UI next to the gateway toggle, since it is
  a real capability the user gives up (fact 2).

## Testing (TDD)

Plain `swift test` (the hard gate):

- `GatewayCommandResolver`: semver ordering (`1.19.0` > `1.9.0`), absent plugin → nil, explicit
  override wins over auto-detect.
- `ClaudeConfigEnvironment.apply`: injects when given a URL; **strips** an inherited
  `ANTHROPIC_BASE_URL` when given nil; leaves the existing `CLAUDE_CONFIG_DIR` behavior unchanged.
- `GatewayPool` against a stub launcher: `acquire` ×2 spawns once; `release` ×1 keeps it alive;
  `release` ×2 tears it down; system-default → nil without spawning.
- `PortAllocator`: returns distinct, bindable ports.
- `GatewayProcess` against a fake script: readiness detection, termination, restart-on-crash.

Track A smoke: assert the `os.Logger` trail shows gateway spawn ordered before the claude spawn,
and that the account's process received the expected base URL.

## Non-goals

- Changing `claude-hot-limit` itself (including the `server.server_address[1]` readiness fix).
- Routing main through a Logos-managed gateway.
- A native Swift reimplementation of the proxy (evaluated and rejected: SSE transparent
  forwarding plus rate-limit header capture is substantial, and it would discard hot-limit's
  existing admission/pacing logic).
- Per-account *model* routing or any gateway-side request rewriting.

## Acceptance criteria

1. Two isolated accounts running concurrently hold two distinct gateway processes on distinct
   ports with distinct state directories, and one hitting 429 does not hold the other's requests.
2. An isolated account's claude reports the Logos-assigned `ANTHROPIC_BASE_URL`, not `8787`.
3. Main's routing is byte-for-byte unchanged from today.
4. An account launched from a shell exporting `ANTHROPIC_BASE_URL` does **not** inherit it.
5. Removing an account terminates its gateway before its directory is deleted; no orphan process
   survives app exit.
6. With the plugin absent: default-upstream accounts still launch (with a warning);
   custom-upstream accounts refuse to launch and say why.
