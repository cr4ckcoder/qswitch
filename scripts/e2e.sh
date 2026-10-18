#!/bin/bash
# End-to-end test against a sandboxed HOME, config dir and keychain service.
# Never touches real CLI logins. Usage: scripts/e2e.sh [path/to/qswitch]
set -euo pipefail

BIN="${1:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/qswitch}"
SANDBOX="$(mktemp -d)"
TAG="qswitch-e2e-$$"
FAKE_KC="$TAG-fake"
export HOME="$SANDBOX/home" QSWITCH_HOME="$SANDBOX/qs" QSWITCH_KEYCHAIN_SERVICE="$TAG" NO_COLOR=1
export QSWITCH_KEYCHAIN="$SANDBOX/test.keychain-db"
mkdir -p "$HOME"
# Throwaway keychain file so the user's login keychain is never touched.
security create-keychain -p test "$QSWITCH_KEYCHAIN"
security unlock-keychain -p test "$QSWITCH_KEYCHAIN"

cleanup() {
  security delete-keychain "$QSWITCH_KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

pass=0
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
  else echo "FAIL $1: expected [$2] got [$3]"; exit 1; fi
}
live_file() { cat "$HOME/.fake/token" 2>/dev/null || echo "<none>"; }
live_kc() { security find-generic-password -s "$FAKE_KC" -a me -w "$QSWITCH_KEYCHAIN" 2>/dev/null || echo "<none>"; }
q() { "$BIN" "$@" >/dev/null; }

# A fake CLI whose "login" writes a token file and a keychain item for $FAKE_USER.
LOGIN='[ -z "$FAKE_FAIL" ] || exit 3; mkdir -p ~/.fake && echo "$FAKE_USER-token" > ~/.fake/token && security add-generic-password -U -s '"$FAKE_KC"' -a me -w "$FAKE_USER-secret" "$QSWITCH_KEYCHAIN"'
q provider add fake --login "$LOGIN" --file '~/.fake/token' --keychain "$FAKE_KC:me" --whoami 'cat ~/.fake/token'

FAKE_USER=alice q add fake alice
check "add alice: file" "alice-token" "$(live_file)"
FAKE_USER=bob q add fake bob
check "add bob: file" "bob-token" "$(live_file)"
check "add bob: keychain" "bob-secret" "$(live_kc)"

q use fake alice
check "use alice: file" "alice-token" "$(live_file)"
check "use alice: keychain" "alice-secret" "$(live_kc)"
check "file mode preserved" "644" "$(stat -f %Lp "$HOME/.fake/token")"

# Token refreshed while alice is active must survive a round trip.
echo "alice-refreshed" > "$HOME/.fake/token"
q use fake bob
check "use bob" "bob-token" "$(live_file)"
q use fake alice
check "refreshed token kept" "alice-refreshed" "$(live_file)"

# Re-selecting the active profile must not roll back live tokens.
echo "alice-refreshed-2" > "$HOME/.fake/token"
q use fake alice
check "re-use active keeps live" "alice-refreshed-2" "$(live_file)"

# Shorthand + interactive picker.
q fake bob
check "shorthand use" "bob-token" "$(live_file)"
echo 1 | q use fake
check "picker by number" "alice-refreshed-2" "$(live_file)"

# Vault files are encrypted.
if grep -rq "alice" "$QSWITCH_HOME/vault"; then echo "FAIL vault contains plaintext"; exit 1; fi
check "vault encrypted" "0" "0"

# Failed login restores the previous profile.
if FAKE_FAIL=1 FAKE_USER=carol "$BIN" add fake carol >/dev/null 2>&1; then echo "FAIL add should fail"; exit 1; fi
check "failed login restores previous" "alice-refreshed-2" "$(live_file)"
check "failed login restores keychain" "alice-secret" "$(live_kc)"

# Hooks get profile env vars.
q set fake bob --on-switch 'echo "$QSWITCH_PROVIDER/$QSWITCH_PROFILE" > ~/hook'
q use fake bob
check "on-switch hook" "fake/bob" "$(cat "$HOME/hook")"

# Command-strategy provider with awkward account names.
q provider add cmdp --login true --switch 'printf %s {account} > ~/current'
q save cmdp one --account "acct-one"
q save cmdp two --account "it's two; rm -rf /"
q use cmdp one
check "command switch" "acct-one" "$(cat "$HOME/current")"
q use cmdp two
check "command switch quoting" "it's two; rm -rf /" "$(cat "$HOME/current")"

# Directory tracking: stale files from another profile are removed.
mkdir -p "$HOME/dirp/sub"; echo a1 > "$HOME/dirp/one"; echo a2 > "$HOME/dirp/sub/two"
q provider add dirp --file '~/dirp'
q save dirp a
rm -rf "$HOME/dirp"; mkdir -p "$HOME/dirp"; echo b1 > "$HOME/dirp/only-b"
q save dirp b
q use dirp a
check "dir restore nested" "a2" "$(cat "$HOME/dirp/sub/two")"
check "dir stale file removed" "no" "$([[ -e "$HOME/dirp/only-b" ]] && echo yes || echo no)"

# Tracked file absent from the target snapshot gets removed.
q provider add opt --file '~/opt-a' --file '~/opt-b'
echo x > "$HOME/opt-a"; q save opt first
echo y > "$HOME/opt-b"; q save opt second
q use opt first
check "absent file removed" "no" "$([[ -e "$HOME/opt-b" ]] && echo yes || echo no)"

# Rename / remove.
q rename fake bob robert
check "rename keeps active" "fake  robert" "$("$BIN" status fake)"
q use fake alice
q use fake robert
check "renamed snapshot usable" "bob-token" "$(live_file)"
q remove fake alice
if "$BIN" use fake alice >/dev/null 2>&1; then echo "FAIL removed profile still usable"; exit 1; fi
check "remove" "no" "$([[ -e "$QSWITCH_HOME/vault/fake/alice.snap" ]] && echo yes || echo no)"
if "$BIN" provider remove fake >/dev/null 2>&1; then echo "FAIL provider remove without --force"; exit 1; fi
q provider remove fake --force
check "provider remove" "no" "$([[ -d "$QSWITCH_HOME/vault/fake" && -n "$(ls "$QSWITCH_HOME/vault/fake")" ]] && echo yes || echo no)"

check "builtins seeded" "yes" "$("$BIN" provider list | grep -q '^vercel' && "$BIN" provider list | grep -q '^gh' && echo yes || echo no)"

echo "all $pass checks passed"
