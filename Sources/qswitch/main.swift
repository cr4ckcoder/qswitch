import Foundation

/// Minimal argument parser: positionals plus `--name value` / `--name=value` options and
/// boolean `--flag`s. Options may repeat (e.g. `--file a --file b`).
struct Args {
    static let booleanFlags: Set<String> = ["verify", "force", "edit", "clear-hooks", "help"]

    var positional: [String] = []
    var options: [String: [String]] = [:]

    init(_ argv: [String]) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                positional += argv[(i + 1)...]
                break
            }
            if a.hasPrefix("--") {
                var key = String(a.dropFirst(2))
                var value: String?
                if let eq = key.firstIndex(of: "=") {
                    value = String(key[key.index(after: eq)...])
                    key = String(key[..<eq])
                }
                if Args.booleanFlags.contains(key) {
                    options[key, default: []].append(value ?? "true")
                } else {
                    if value == nil {
                        i += 1
                        guard i < argv.count else { throw QError("--\(key) needs a value") }
                        value = argv[i]
                    }
                    options[key, default: []].append(value!)
                }
            } else if a == "-h" {
                options["help", default: []].append("true")
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func value(_ key: String) -> String? { options[key]?.last }
    func values(_ key: String) -> [String] { options[key] ?? [] }
    func has(_ key: String) -> Bool { options[key] != nil }
    func flag(_ key: String) -> Bool { options[key] != nil }

    func dropFirst() -> Args {
        var copy = self
        copy.positional = Array(positional.dropFirst())
        return copy
    }
}

extension String {
    private static let color = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    private func ansi(_ code: String) -> String { String.color ? "\u{1B}[\(code)m\(self)\u{1B}[0m" : self }
    var bold: String { ansi("1") }
    var dim: String { ansi("2") }
    var green: String { ansi("32") }
    var yellow: String { ansi("33") }
}

let usage = """
qswitch — switch between CLI accounts without logging out and back in

Usage:
  qswitch [status] [provider] [--verify]   Show the active profile per provider
  qswitch list [provider]                  List saved profiles (* = active)
  qswitch use <provider> [profile]         Switch account (prompts if profile omitted)
  qswitch add <provider> <profile>         Log in to a new account and save it
  qswitch save <provider> <profile>        Save the currently logged-in account
  qswitch set <provider> <profile>         Change --account / --on-switch hooks
  qswitch rename <provider> <old> <new>
  qswitch remove <provider> <profile>
  qswitch whoami <provider>                Run the provider's whoami command
  qswitch provider list|show|add|remove    Manage providers (CLIs)
  qswitch config [--edit]                  Print (or edit) the config file path

Profile options (add / save / set):
  --account ID         Account passed to the switch command (command providers)
  --on-switch CMD      Shell command run after switching to this profile (repeatable),
                       e.g. --on-switch 'git config --global user.email me@work.com'
  --clear-hooks        (set) remove existing on-switch hooks first

Provider options (provider add <name>):
  --login CMD          Interactive login command, e.g. 'npx wrangler login'
  --file PATH          File or directory holding the login (repeatable)
  --keychain SVC[:ACCT] Keychain item holding the login (repeatable)
  --switch CMD         Use the CLI's own switch command instead; {account} is substituted
  --account-cmd CMD    Prints the current account id (used when --account is omitted)
  --whoami CMD         Shows who is logged in
  --description TEXT
  --force              Replace an existing provider definition

Examples:
  qswitch add vercel work                  # runs `vercel login`, saves as "work"
  qswitch save vercel personal             # save the login you already have
  qswitch use vercel personal
  qswitch provider add wrangler --login 'npx wrangler login' \\
      --file '~/Library/Preferences/.wrangler/config/default.toml'
"""

func run() throws {
    let argv = Array(CommandLine.arguments.dropFirst())
    let args = try Args(argv)
    if args.flag("help") && args.positional.isEmpty {
        print(usage)
        return
    }
    let command = args.positional.first ?? "status"
    let rest = args.dropFirst()
    switch command {
    case "status", "st": try Commands.status(rest)
    case "list", "ls": try Commands.list(rest)
    case "use", "switch", "sw": try Commands.use(rest)
    case "add", "login": try Commands.add(rest)
    case "save", "capture": try Commands.save(rest)
    case "set": try Commands.set(rest)
    case "rename", "mv": try Commands.rename(rest)
    case "remove", "rm": try Commands.remove(rest)
    case "whoami": try Commands.whoami(rest)
    case "provider", "providers": try Commands.providers(rest)
    case "config": try Commands.configCommand(rest)
    case "help": print(usage)
    default:
        // `qswitch vercel [profile]` as shorthand for `qswitch use vercel [profile]`.
        if (try? Store.load().provider(command)) != nil {
            try Commands.use(args)
        } else {
            throw QError("unknown command '\(command)'. Run `qswitch help`.")
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("qswitch: \(error)\n".utf8))
    exit(1)
}
