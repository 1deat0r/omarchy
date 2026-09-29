# Plan: Agent accounts — several Claude and Codex subscriptions, one switch

Revision 2 — updated to match the implementation on this branch.

## Problem

Omarchy knows exactly one Claude subscription and one Codex subscription. `omarchy-agent-usage-claude` reads `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`, `omarchy-agent-usage-codex` asks `codex app-server` in `${CODEX_HOME:-~/.codex}`, and the Agents panel draws one record per provider. Someone paying for two Claude Max plans (or a personal and a work seat) has to log out and back in to move between them — and `claude auth logout` revokes the refresh token, so the account you left has to be logged into from scratch next time. When the active plan hits its five-hour or weekly limit mid-afternoon, there is no way to see that the other plan has headroom, and no way to move new sessions over without that dance.

## Shape

An account is a Claude or Codex login Omarchy keeps a home for. One account per provider is *active*: every new `claude` / `codex` launched from Omarchy — `cx`, `cy`, plain `claude` at a prompt, `omarchy-agent`, the bar's right-click picker — runs as it. The Agents panel shows every account's limits under its provider tab with the active one badged, lets you pick the active account, and adds new ones. A per-provider switch mode decides whether Omarchy moves the active account for you when it crosses a threshold (default 95%) or leaves it to you.

Running sessions are never touched. A switch changes where the *next* session goes; because conversation history is shared across accounts, `claude --continue` in the same directory picks the conversation up on the new plan.

## Rejected approaches

- **Swapping credential files in place** (claude-swap, omaclaude-swap, codex-account-switch). Tempting because everything stays in `~/.claude`, but a long-running session holds its account's refresh token in memory: when its access token expires (every 8 hours for Claude), it refreshes and writes its own credentials back over whatever was swapped in — silently undoing the switch, and rotating the refresh token so the parked copy of that account is now dead. Swapping is only safe with no sessions running, which is exactly when you don't need to switch. Codex has the same write-back.
- **Refreshing parked Claude tokens ourselves** against Anthropic's OAuth token endpoint, so every account's meters stay live. That reimplements a private client's auth flow, rotates refresh tokens out from under any session running in that home, and breaks the day the endpoint or client id changes. Parked accounts show last-known limits instead (see *Usage per account*).
- **Scraping `/usage` from `claude -p`** (ai-account-switcher). Spends a request per probe and parses human-readable text; the OAuth usage endpoint the collector already calls is the structured source.
- **Router binaries in `~/.local/bin`** shadowing `claude` / `codex`. Omarchy owns every launch path already (bash aliases, `omarchy-agent`), so a shell function and one line in `omarchy-agent` do it without putting executables ahead of mise on `PATH`. And no permission-bypass defaults.
- **A separate plugin next to `omarchy.agents`**. Two panels showing the same limits for the same subscriptions is the confusion this is meant to remove; accounts belong in the Agents panel.

## Design

### Homes

Each account is a full provider home, isolated where auth lives and shared everywhere else:

- The account you already have stays exactly where it is: `~/.claude` and `~/.codex` are the *primary* accounts, and nothing about a single-account setup changes on disk.
- Added accounts live under `~/.local/state/omarchy/agents/accounts/<provider>/<id>/` (0700). Claude homes get their own `.credentials.json` and `.claude.json` (the latter holds `oauthAccount`, so it can't be shared); everything else — `projects/`, `history.jsonl`, `settings.json`, `CLAUDE.md`, `skills/`, `agents/`, `commands/`, `plugins/`, `hooks/` — is a symlink into `~/.claude`. Codex homes get their own `auth.json`; `config.toml`, `AGENTS.md`, `sessions/`, `archived_sessions/`, `history.jsonl`, `prompts/` and `skills/` link into `~/.codex`.
- Shared `projects/` / `sessions/` is what makes `--continue` and `--resume` work across a switch, and what keeps the panel's token charts one per provider rather than one per account.
- Per-account `.claude.json` means user-scope MCP servers added with `claude mcp add` in one account don't appear in another. The add flow copies the `mcpServers` key from `~/.claude.json` into the new account's file; later additions are per account, and the manual says so.

`~/.local/state/omarchy/agents/accounts/<provider>.json` is the registry: `{ "active": "<id>", "switch": "manual|auto", "threshold": 95, "accounts": [{ "id", "label", "home", "email", "org", "plan", "accountId" }] }`. `id` is a slug of the label; `accountId` (Claude `oauthAccount.accountUuid`, Codex `tokens.account_id`) is what duplicate detection keys on. Written with flock plus atomic rename, 0600, like the usage records. Tokens never enter it.

### Routing new sessions

`omarchy-agent-account-home <provider>` prints the active account's home, or nothing for a primary account. Launches honor it:

- `default/bash/fns` gains `claude()` and `codex()` functions that export `CLAUDE_CONFIG_DIR` / `CODEX_HOME` from it for that one command — unless the variable is already set, so an explicit `CLAUDE_CONFIG_DIR=… claude` still wins. `cx`, `cy`, `icx` and every other alias go through these for free.
- `bin/omarchy-agent` does the same before exec, covering the menu, the bar picker, `omarchy-agent-prompt` and `omarchy-agent-crash`.
- Claude Desktop, Chromium's Claude app, and editors that spawn `claude` themselves don't follow; the manual says so.

The lookup reads one small JSON file, so it's cheap enough to run per launch.

### Commands

A new `agent-account` route under the existing `agent` group:

- `omarchy agent account list [claude|codex]` — accounts, active marker, last-known limits.
- `omarchy agent account add <claude|codex> [label]` — the add flow below.
- `omarchy agent account use <claude|codex> <id|next>` — make an account active; notifies "New Claude sessions now use Work (Max 20x). Running sessions stay on Personal."
- `omarchy agent account remove <claude|codex> <id>` — deletes an added account's home after confirming; the primary can't be removed. Never runs `claude auth logout`, which would revoke the token for every copy.
- `omarchy agent account mode <claude|codex> [manual|auto] [threshold]` — without arguments, says how switching is set.

`omarchy-agent-account-home` and `omarchy-agent-account-state` (the Python registry, identity and switching policy the commands share) are `# omarchy:hidden=true` plumbing.

### Adding an account

`omarchy agent account add claude Work`, from the panel, the menu, or a prompt:

1. Registers the primary if the registry doesn't exist yet, reading its identity from `~/.claude.json` / `~/.codex/auth.json`.
2. Creates a temporary home under the accounts dir, lays down the shared symlinks.
3. Opens a terminal running `CLAUDE_CONFIG_DIR=<tmp> claude auth login` (Codex: `CODEX_HOME=<tmp> codex login`). Before it starts, it prints the one thing people get wrong: *the browser will sign in as whoever is logged into claude.ai / chatgpt.com — switch accounts there first, or use a private window.* It never tells anyone to log out of the CLI.
4. Reads the new identity. If `accountId` matches an account already registered, it deletes the temp home and says "That's already Personal — sign the browser into the other account and try again."
5. Otherwise moves the temp home into place under its slug, appends it to the registry (not active), and runs one forced usage probe so the panel shows it immediately.

### Usage per account

The collectors already honor `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, so per-account limits are a loop, not a rewrite:

- `omarchy-agent-usage-claude` scans local stats once (they're shared), then probes limits once per registered account home and emits `accounts: [{ id, label, email, plan, active, limits, stale, fetchedAt }]` alongside the existing top-level `limits`, which keep meaning "the active account" so the bar icon and anything else reading the record keeps working. Codex does the same with one app-server per home.
- A parked Claude account's access token lasts 8 hours past its last use. After that the probe returns "Sign-in expired", and the collector keeps showing the account's last-known numbers marked stale — except that any window whose `resetsAt` has passed reads as 0%, which is exactly the information switching needs. The refresh token (about 30 days) revives the account the first time a session runs in it. An account left idle past its refresh token's lifetime shows "Sign in again" with a one-key re-login that reuses its home. Codex's app-server holds the refresh token and should refresh on its own when probed; if it does, Codex accounts stay live (see open questions).
- The limits cache moves from `claude-limits.json` to one file per account id.

### Switching

After every usage update, `omarchy-agent-usage-update` runs `omarchy-agent-account-state autoswitch`, which, for each provider with a registry:

1. Looks at the active account's highest limit (five-hour or weekly). Below the threshold: nothing.
2. Otherwise picks the account with the lowest highest-limit that is itself under the threshold, stale numbers adjusted for passed resets. Ties go to the account whose binding window resets soonest.
3. Switches to it and notifies: "Personal hit 95% of its five-hour limit — new Claude sessions now use Work (12%)."
4. If every account is over the threshold, it stays put and notifies once: "All Claude accounts are over 95% — Personal resets in 1h 12m." It won't repeat until something crosses back down.

Only an over-threshold active account triggers a move, so auto mode never flaps back to an account that just reset. Alert state lives in the registry so shell restarts and multiple monitors don't re-fire.

In `manual` mode the same crossing only notifies, with the switch as the notification's click action (`omarchy-notification-send --exec omarchy agent account use claude next`).

The 900-second refresh interval is too coarse to catch 95%. While the active account is above 80% of any window, `Main.qml` shortens the timer to 60 seconds (`--limits-only`, so it's one HTTP call per account), and returns to the configured interval once it drops back.

### Agents panel

Under the Claude and Codex tabs, the single limits block becomes an **Accounts** section when more than one account is registered — with one account, the panel looks exactly as it does today.

- One row per account: label, plan, email (dimmed), the five-hour and weekly meters with reset countdowns, *Active* badge on the active one, *stale* / *sign in again* states where they apply.
- Keys: `1`–`9` select an account row, `Enter` on a selected row makes it active (two keystrokes, so looking never switches — borrowed from claude-swap-panel), `a` adds an account, `m` toggles manual/auto. The same actions sit in a footer row for the mouse.
- The bar icon's warning reflects the active account, as it does now.
- Token-by-day and by-model charts stay per provider, labeled *All accounts*.

The registry is the only place switching is configured, so the CLI, the menu and the panel can't disagree: `m` in the panel and `omarchy agent account mode` both write it, and the record carries it back to the panel as `accountSwitch`. The threshold is set from the CLI.

### Menu

*Setup › Agent Accounts › Claude* and *› Codex* list each provider's accounts through volatile `claude-accounts` / `codex-accounts` menu providers, with the active one checked and selection switching to it, followed by an *Add Account* row.

## Tests

- `test/shell.d/agent-account-test.sh`: registry creation and primary detection from fixture homes, add-flow duplicate rejection by `accountId`, home symlink layout, `use`, `remove` refusing the primary, `home` output for primary vs. added.
- `test/shell.d/agent-account-autoswitch-test.sh`: threshold crossing, picking the lowest-usage candidate, stale-with-passed-reset treated as 0%, all-exhausted notifies once, no flap-back after a reset, manual mode only notifies.
- Extend `agent-usage-claude-limits-test.sh` / `agent-usage-codex-scanner-test.sh` for the `accounts` array and per-account caches.
- Shell function test: an explicit `CLAUDE_CONFIG_DIR` beats the active account.
- Visual verification of the panel with one and three accounts, including a stale account and a picked card, rendered from the branch against fixture records.

## Documentation

- `manual/17-ai.md`: *Several subscriptions* — adding, switching, auto mode, what doesn't follow the switch (running sessions, Claude Desktop, IDEs), the browser-account gotcha, and never logging out.
- `shell/plugins/agents/README.md`: the `accounts` record shape and the settings.

## Rollout

No migration needed: with no registry file, every command and the panel behave exactly as today, and the registry is created by the first `add`. The `bash/fns` change reaches existing users through the normal update.

## Open questions

- Does `claude auth status` refresh an expired access token? If it does, the collector can keep parked Claude accounts live without touching OAuth itself, and *stale* mostly disappears.
- Does `codex app-server` refresh an expired access token during `account/rateLimits/read`? Needs a check against an account parked for a day.
- Should auto mode also cover Codex from day one, or ship Claude-only first? The mechanism is identical; the difference is how often people actually hold two ChatGPT plans.
- Worth offering "move this session" — print `claude --continue` for the running session's directory in the switch notification — or is the notification enough?
