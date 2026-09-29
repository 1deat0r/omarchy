#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
notifications="$test_tmp/notifications"
mkdir -p "$mock_bin" "$test_tmp/home/.claude" "$test_tmp/home/.codex"

cat >"$mock_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_NOTIFICATIONS"
SH

# The CLIs report which home they were started in, and a login writes the
# identity a real one would into whichever home it was given.
cat >"$mock_bin/claude" <<'SH'
#!/bin/bash
if [[ ${1:-} == "auth" && ${2:-} == "login" ]]; then
  "$BROWSER" "https://claude.com/oauth/authorize"
  [[ -n ${OMARCHY_TEST_LOGIN_UUID:-} ]] || exit 1
  printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"%s","organizationName":"Work"}}\n' \
    "$OMARCHY_TEST_LOGIN_UUID" "$OMARCHY_TEST_LOGIN_EMAIL" >"$CLAUDE_CONFIG_DIR/.claude.json"
  echo '{"claudeAiOauth":{"rateLimitTier":"default_claude_max_5x","subscriptionType":"max"}}' >"$CLAUDE_CONFIG_DIR/.credentials.json"
  exit 0
fi
echo "claude home=${CLAUDE_CONFIG_DIR:-default} args=$*"
SH

cat >"$mock_bin/codex" <<'SH'
#!/bin/bash
if [[ ${1:-} == "login" ]]; then
  "$BROWSER" "https://auth.openai.com/oauth/authorize"
  claims=$(printf '{"email":"%s","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}' "$OMARCHY_TEST_LOGIN_EMAIL" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  printf '{"auth_mode":"chatgpt","tokens":{"account_id":"%s","id_token":"h.%s.s"}}\n' "$OMARCHY_TEST_LOGIN_UUID" "$claims" >"$CODEX_HOME/auth.json"
  exit 0
fi
echo "codex home=${CODEX_HOME:-default} args=$*"
SH

cat >"$mock_bin/omarchy-agent-usage-update" <<'SH'
#!/bin/bash
SH

cat >"$mock_bin/omarchy-default-agent" <<'SH'
#!/bin/bash
echo "${OMARCHY_TEST_DEFAULT_AGENT:-claude}"
SH

cat >"$mock_bin/omarchy-launch-browser" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_BROWSER_LOG"
SH

chmod +x "$mock_bin"/*

export HOME="$test_tmp/home"
export XDG_STATE_HOME="$test_tmp/state"
export PATH="$mock_bin:$ROOT/bin:$PATH"
export OMARCHY_PATH="$ROOT"
export OMARCHY_TEST_NOTIFICATIONS="$notifications"
export OMARCHY_TEST_BROWSER_LOG="$test_tmp/browser"
unset CLAUDE_CONFIG_DIR CODEX_HOME

accounts="$XDG_STATE_HOME/omarchy/agents/accounts"

echo '{"oauthAccount":{"accountUuid":"u-main","emailAddress":"me@example.com","organizationName":"Me"},"mcpServers":{"docs":{"command":"docs-mcp"}}}' >"$HOME/.claude.json"
echo '{"claudeAiOauth":{"rateLimitTier":"default_claude_max_20x","subscriptionType":"max"}}' >"$HOME/.claude/.credentials.json"
echo '{"theme":"custom:omarchy"}' >"$HOME/.claude/settings.json"

# ---------------------------------------------------------------- single account

[[ -z $(omarchy-agent-account-home claude) ]] || fail "a machine with one account routes nowhere"
[[ ! -e $accounts/claude.json ]] || fail "reading the active home never creates a registry"
pass "a machine with one account launches exactly as before"

list=$(omarchy-agent-account-list claude --json)
[[ $(jq -c '.[0].accounts | map({id, label, plan, email, active, primary})' <<<"$list") == '[{"id":"main","label":"Main","plan":"Max 20x","email":"me@example.com","active":true,"primary":true}]' ]] ||
  fail "the existing login is listed as the primary account" "$list"
pass "the existing login is listed as the primary account"

# ------------------------------------------------------------------------- add

OMARCHY_TEST_LOGIN_UUID=u-work OMARCHY_TEST_LOGIN_EMAIL=work@example.com \
  omarchy-agent-account-add claude Work </dev/null >"$test_tmp/add-output"
grep -q "Added Work (work@example.com)" "$test_tmp/add-output" || fail "adding an account reports who signed in" "$(cat "$test_tmp/add-output")"
grep -q "private window that opens" "$test_tmp/add-output" || fail "adding an account says to sign in within the private window"
[[ $(head -1 "$OMARCHY_TEST_BROWSER_LOG") == "--private https://claude.com/oauth/authorize" ]] ||
  fail "a Claude login opens in a private window" "$(cat "$OMARCHY_TEST_BROWSER_LOG")"
pass "adding an account signs in through the CLI's own login"

work="$accounts/claude/work"
[[ -f $work/.credentials.json && ! -L $work/.credentials.json ]] || fail "an added account keeps its own credentials"
[[ $(readlink "$work/projects") == "$HOME/.claude/projects" ]] || fail "an added account shares conversation history with the primary"
[[ $(readlink "$work/settings.json") == "$HOME/.claude/settings.json" ]] || fail "an added account shares settings with the primary"
[[ ! -e $work/CLAUDE.md ]] || fail "a shared file the primary lacks is not linked"
[[ $(jq -c .mcpServers "$work/.claude.json") == '{"docs":{"command":"docs-mcp"}}' ]] || fail "an added account carries the primary's MCP servers"
[[ $(stat -c %a "$work") == 700 && $(stat -c %a "$accounts/claude.json") == 600 ]] || fail "account homes and the registry are private"
pass "an added account shares everything but its login with the primary"

if OMARCHY_TEST_LOGIN_UUID=u-work OMARCHY_TEST_LOGIN_EMAIL=work@example.com \
  omarchy-agent-account-add claude Again </dev/null >"$test_tmp/dup-output" 2>&1; then
  fail "adding the same account twice fails"
fi
grep -q "That's Work" "$test_tmp/dup-output" || fail "a duplicate login names the account it already is" "$(cat "$test_tmp/dup-output")"
[[ -z $(ls -A "$accounts/claude/.pending") ]] || fail "a duplicate login leaves no scratch home behind"
pass "adding an account that's already there is refused"

# Main was signed in to another account by hand since the registry was made;
# adding that login again is still the same subscription.
jq '.oauthAccount.accountUuid = "u-relogged"' "$HOME/.claude.json" >"$test_tmp/relogged.json"
cp "$HOME/.claude.json" "$test_tmp/original.json"
mv "$test_tmp/relogged.json" "$HOME/.claude.json"
if OMARCHY_TEST_LOGIN_UUID=u-relogged OMARCHY_TEST_LOGIN_EMAIL=me@example.com \
  omarchy-agent-account-add claude Twin </dev/null >"$test_tmp/twin-output" 2>&1; then
  fail "a login matching Main's current sign-in is refused"
fi
grep -q "That's Main" "$test_tmp/twin-output" || fail "a login matching Main's current sign-in names Main" "$(cat "$test_tmp/twin-output")"
mv "$test_tmp/original.json" "$HOME/.claude.json"
pass "duplicates are judged by who each home is signed in as now"

if OMARCHY_TEST_LOGIN_UUID="" omarchy-agent-account-add claude Nope </dev/null >/dev/null 2>&1; then
  fail "an abandoned login adds nothing"
fi
[[ $(omarchy-agent-account-list claude --json | jq '.[0].accounts | length') == 2 ]] || fail "an abandoned login adds nothing"
pass "an abandoned login adds nothing"

OMARCHY_TEST_LOGIN_UUID=u-next OMARCHY_TEST_LOGIN_EMAIL=next@example.com \
  omarchy-agent-account-add claude Next </dev/null >/dev/null
[[ $(omarchy-agent-account-list claude --json | jq -r '.[0].accounts[] | select(.label == "Next") | .id') == "next-2" ]] ||
  fail "an account label can't take an id that routing already answers to"
omarchy-agent-account-remove claude next-2 </dev/null >/dev/null
pass "account ids stay clear of routing keywords"

OMARCHY_TEST_LOGIN_UUID=acct-2 OMARCHY_TEST_LOGIN_EMAIL=side@example.com \
  omarchy-agent-account-add codex Side </dev/null >/dev/null
[[ $(omarchy-agent-account-list codex --json | jq -c '.[0].accounts[1] | {id, email, plan}') == '{"id":"side","email":"side@example.com","plan":"Pro"}' ]] ||
  fail "a Codex account reads its identity from the login's token claims"
[[ $(readlink "$accounts/codex/side/sessions") == "$HOME/.codex/sessions" ]] || fail "a Codex account shares sessions with the primary"
grep -qx -- "--private https://auth.openai.com/oauth/authorize" "$OMARCHY_TEST_BROWSER_LOG" ||
  fail "a Codex login opens in a private window" "$(cat "$OMARCHY_TEST_BROWSER_LOG")"
pass "Codex accounts are added the same way"

# ---------------------------------------------------------------------- routing

omarchy-agent-account-use claude work >/dev/null
[[ $(omarchy-agent-account-home claude) == "$work" ]] || fail "the active account's home is what launches use"
grep -q "New Claude sessions now use Work (Max 5x)" "$notifications" || fail "switching says where new sessions go"
pass "use makes an account active and says so"

source "$ROOT/default/bash/fns/agent-accounts"
[[ $(claude --version) == "claude home=$work args=--version" ]] || fail "claude at a prompt starts as the active account"
[[ $(CLAUDE_CONFIG_DIR=/elsewhere claude) == "claude home=/elsewhere args=" ]] || fail "an explicit CLAUDE_CONFIG_DIR wins over the active account"
[[ $(codex) == "codex home=default args=" ]] || fail "codex stays on its primary until switched"
pass "shell launches follow the active account"

[[ $(OMARCHY_TEST_DEFAULT_AGENT=claude omarchy-agent --inline) == "claude home=$work args=--permission-mode auto" ]] ||
  fail "omarchy-agent starts Claude as the active account"
omarchy-agent-account-use codex side >/dev/null
[[ $(OMARCHY_TEST_DEFAULT_AGENT=codex omarchy-agent --inline) == "codex home=$accounts/codex/side args=--approve-for-me" ]] ||
  fail "omarchy-agent starts Codex as the active account"
pass "omarchy-agent follows the active account"

omarchy-agent-account-use claude next >/dev/null
[[ -z $(omarchy-agent-account-home claude) ]] || fail "next cycles back to the primary"
pass "next cycles through accounts"

# With Claude as the default agent, the provider can be left out.
OMARCHY_TEST_DEFAULT_AGENT=claude omarchy-agent-account-use work >/dev/null
[[ $(omarchy-agent-account-home claude) == "$work" ]] || fail "use without a provider picks the default agent's account"
OMARCHY_TEST_DEFAULT_AGENT=claude omarchy-agent-account-use main >/dev/null
[[ -z $(omarchy-agent-account-home claude) ]] || fail "use without a provider switches back to Main"
OMARCHY_TEST_DEFAULT_AGENT=codex omarchy-agent-account-use main >/dev/null
[[ -z $(omarchy-agent-account-home codex) ]] || fail "the default agent decides which provider a short use means"
if OMARCHY_TEST_DEFAULT_AGENT=pi omarchy-agent-account-use work >/dev/null 2>&1; then
  fail "a default agent with no accounts still needs the provider named"
fi
pass "the provider defaults to your default agent"

# ------------------------------------------------------------ mode and remove

OMARCHY_TEST_DEFAULT_AGENT=claude omarchy-agent-account-mode auto 90 >/dev/null
[[ $(jq -c '{switch, threshold}' "$accounts/claude.json") == '{"switch":"auto","threshold":90}' ]] || fail "mode sets switching and threshold"
if omarchy-agent-account-mode claude sometimes >/dev/null 2>&1; then
  fail "mode refuses an unknown switch mode"
fi
pass "mode sets how switching happens"

if omarchy-agent-account-remove claude main </dev/null >/dev/null 2>&1; then
  fail "the primary account can't be removed"
fi
omarchy-agent-account-use claude work >/dev/null
omarchy-agent-account-remove claude work </dev/null >/dev/null
[[ ! -e $work && -d $HOME/.claude/projects && -f $HOME/.claude/settings.json ]] || fail "removing an account deletes its home and nothing it links to"
[[ -z $(omarchy-agent-account-home claude) ]] || fail "removing the active account falls back to the primary"
pass "remove forgets an added account without touching shared files"
