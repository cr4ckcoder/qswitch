# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

qswitch is a macOS Swift CLI (no dependencies, SwiftPM) that switches accounts for other CLIs (vercel, gh, user-defined) without re-login.

## Commands

- `make build`: debug build at `.build/debug/qswitch`
- `make test`: runs `scripts/e2e.sh`, the only test suite. XCTest is not available with Command Line Tools alone. To add a check, add a `check "<desc>" <expected> <actual>` line to that script.
- `make install`: release build copied to `~/.local/bin/qswitch`

**Never test against the real `~` or the login keychain.** `e2e.sh` sets `HOME`, `QSWITCH_HOME` (config root), `QSWITCH_KEYCHAIN_SERVICE` (vault key item name) and `QSWITCH_KEYCHAIN` (a keychain file it creates and deletes). Use the same variables for any manual experiments.

## Architecture

- **Providers** (`Config.swift`, `Builtins.swift`) have a `Strategy`:
  - `snapshot`: qswitch copies the tracked `files` (files or directories) and `keychain` items itself.
  - `command`: qswitch runs `switchCommand`, with `{account}`/`{profile}` shell-quoted by `Shell.render`.
- Built-ins are seeded into `config.json` only on first load. After that the config file is the source of truth, so changing `Builtins.swift` does not affect existing installs.
- **Switch invariant** (`Commands.use`): for snapshot providers, always capture the live state back into the currently active profile *before* restoring the target, even when re-selecting the active profile. This is what keeps rotated OAuth refresh tokens (Vercel) valid. `Snapshot.restore` makes the live state match exactly, so tracked paths missing from the snapshot are deleted.
- `add` (snapshot): saves the current profile, clears the live state, runs the login command and captures the result. On login failure it restores the previous profile.
- **Storage** (`Snapshot.swift`, `Vault`): each snapshot is JSON sealed with AES-GCM in `vault/<provider>/<profile>.snap`. The 32-byte key is in the keychain.
- **Keychain** (`Keychain.swift`): always shells out to `/usr/bin/security` rather than using Security.framework, so item ACLs trust a stable Apple binary and rebuilds don't trigger prompts. Writes go through `security -i` over stdin to keep secrets out of argv. That mode truncates lines at about 4 KB, hence `maxSecretBytes` and the reason snapshots live in encrypted files rather than the keychain.
- All mutating commands run inside `Store.withLock` (`flock` on `<root>/.lock`).
- `Args` (`main.swift`) is a hand-rolled parser. New boolean flags must be added to `Args.booleanFlags`, otherwise they consume the next argument as a value. Unknown first arguments that match a provider name act as `use <provider>`.
