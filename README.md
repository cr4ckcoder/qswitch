# qswitch

Switch between accounts in command-line tools (Vercel, GitHub, or anything else) on macOS without logging out and back in.

```sh
qswitch save vercel personal      # save the Vercel login you already have
qswitch add vercel work           # runs `vercel login` for a second account, saves it
qswitch use vercel personal       # switch: no re-login
qswitch vercel                    # pick from a list
qswitch                           # show the active profile for every provider
```

## Install

```sh
git clone https://github.com/cr4ckcoder/qswitch.git
cd qswitch
make install            # builds a release binary into ~/.local/bin/qswitch
make install PREFIX=/usr/local
```

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools). Make sure `~/.local/bin` is on your `PATH`.

## How it works

Each CLI is a **provider**. Each provider uses one of two strategies:

- **snapshot**: qswitch keeps a copy of the provider's credential files and keychain items for each profile. Switching saves the live state back into the current profile, then restores the target profile's copy. The save-back step keeps refreshed or rotated tokens (Vercel rotates its refresh token) from going stale.
- **command**: the CLI already supports multiple accounts, so qswitch just runs its switch command. For example, `gh` uses `gh auth switch --user {account}`.

Built-in providers, seeded into the config on first run:

| Provider | Strategy | What it does |
| --- | --- | --- |
| `vercel` | snapshot | Swaps `~/Library/Application Support/com.vercel.cli/{auth,config}.json`. `config.json` holds the current team, so that switches too. |
| `gh` | command | `gh auth switch`. Accounts are added with `gh auth login`, which keeps them all. The profile's account is detected with `gh api user`. |

### Adding any other CLI

Point qswitch at the files or keychain items where the CLI stores its login. The paths below are examples and can differ between CLI versions, so check yours first.

```sh
qswitch provider add wrangler --login 'npx wrangler login' \
    --file '~/Library/Preferences/.wrangler/config/default.toml'
qswitch provider add netlify --login 'netlify login' --file '~/Library/Preferences/netlify/config.json'
qswitch provider add mytool --login 'mytool auth' --keychain 'mytool-service:account-name'
```

If the CLI can switch accounts itself, hand that job to it:

```sh
qswitch provider add gcloud --login 'gcloud auth login' \
    --switch 'gcloud config configurations activate {account}'
```

`--file` accepts directories as well. A directory is restored as an exact copy, so files that belong only to another profile are removed. Snapshots are capped at 5 MB.

### Per-profile hooks

Run commands after switching, such as setting your git identity to match the GitHub account:

```sh
qswitch set gh work --on-switch 'git config --global user.email me@company.com' \
                    --on-switch 'git config --global user.name "Me (Work)"'
```

Hooks receive `QSWITCH_PROVIDER`, `QSWITCH_PROFILE` and `QSWITCH_ACCOUNT` as environment variables.

## Security

- Snapshots are stored in `~/.config/qswitch/vault/<provider>/<profile>.snap`, encrypted with AES-256-GCM.
- The encryption key lives in your login keychain (service `qswitch`, account `vault-master-key`). Delete that item and every saved profile becomes unreadable.
- All keychain access goes through `/usr/bin/security`, so rebuilding qswitch never triggers keychain prompts. Secrets are written over stdin, never as command arguments.
- The config file `~/.config/qswitch/config.json` contains no secrets. You can edit it with `qswitch config --edit`.

## Caveats

- Log in to new accounts with `qswitch add`, not the CLI's own login command. If you run `vercel login` directly while a profile is active, the next switch saves that new login into the active profile.
- Keychain secrets of tracked items must be under about 1.9 KB, a limit of `security -i`. Tokens are usually far smaller.

## Development

```sh
make build      # debug build
make test       # end-to-end test in a sandboxed HOME + throwaway keychain
```

## License

MIT. See [LICENSE](LICENSE).
