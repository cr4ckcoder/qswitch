import Foundation

enum Commands {
    // MARK: status / list

    static func status(_ args: Args) throws {
        let config = try Store.load()
        let verify = args.flag("verify")
        let names = args.positional.isEmpty ? config.providers.keys.sorted() : [try config.provider(args.positional[0]).name]
        for name in names {
            let provider = try config.provider(name)
            let profiles = config.profiles[name] ?? []
            let active = config.active[name]
            print("\(name.bold)  \(active.map { $0.green } ?? (profiles.isEmpty ? "no profiles".dim : "no active profile".yellow))")
            if verify, let whoami = provider.whoami {
                _ = try? Shell.interactive(whoami)
            }
        }
    }

    static func list(_ args: Args) throws {
        let config = try Store.load()
        let names = args.positional.isEmpty ? config.providers.keys.sorted() : [try config.provider(args.positional[0]).name]
        for name in names {
            print(name.bold)
            let profiles = config.profiles[name] ?? []
            if profiles.isEmpty { print("  " + "(none) — add one with: qswitch add \(name) <profile>".dim) }
            for p in profiles {
                let mark = config.active[name] == p.name ? "*".green : " "
                var line = "\(mark) \(p.name)"
                if let account = p.account, account != p.name { line += "  " + "(\(account))".dim }
                if !p.onSwitch.isEmpty { line += "  " + "[\(p.onSwitch.count) hook\(p.onSwitch.count == 1 ? "" : "s")]".dim }
                print("  " + line)
            }
        }
    }

    // MARK: use

    static func use(_ args: Args) throws {
        guard let providerName = args.positional.first else { throw QError("usage: qswitch use <provider> [profile]") }
        var targetName = args.positional.count > 1 ? args.positional[1] : nil
        if targetName == nil {
            targetName = try pick(provider: providerName)
        }
        guard let target = targetName else { return }

        let profile: Profile = try Store.withLock {
            var config = try Store.load()
            let provider = try config.provider(providerName)
            var profile = try config.profile(providerName, target)
            let current = config.active[providerName]

            switch provider.strategy {
            case .snapshot:
                // Always save first (even when re-selecting the active profile) so restoring
                // never overwrites fresher live tokens with an older snapshot.
                if let current {
                    try saveLive(provider, as: current, config: config)
                }
                try Vault.load(provider: providerName, profile: target).restore(provider)
            case .command:
                guard let template = provider.switchCommand else { throw QError("\(providerName) has no switch command configured") }
                let cmd = Shell.render(template, account: profile.account ?? profile.name, profile: profile.name)
                let status = try Shell.interactive(cmd)
                guard status == 0 else { throw QError("switch command failed (exit \(status)): \(cmd)") }
            }

            profile.lastUsed = Date()
            config.upsert(profile, for: providerName)
            config.active[providerName] = target
            try Store.save(config)
            return profile
        }

        print("\(providerName.bold) → \(target.green)")
        try runHooks(profile, provider: providerName)
    }

    /// Snapshot strategy: write the live state back into the profile it belongs to, so token
    /// refreshes/rotations that happened while it was active aren't lost.
    private static func saveLive(_ provider: Provider, as profile: String, config: Config) throws {
        guard config.profiles[provider.name]?.contains(where: { $0.name == profile }) == true else { return }
        let live = try Snapshot.capture(provider)
        if live.isEmpty {
            warn("\(provider.name): no live login found; keeping the previously saved state of '\(profile)'")
            return
        }
        try Vault.save(live, provider: provider.name, profile: profile)
    }

    private static func pick(provider: String) throws -> String? {
        let config = try Store.load()
        _ = try config.provider(provider)
        let profiles = config.profiles[provider] ?? []
        guard !profiles.isEmpty else { throw QError("no profiles for \(provider). Add one with: qswitch add \(provider) <profile>") }
        for (i, p) in profiles.enumerated() {
            let mark = config.active[provider] == p.name ? "*".green : " "
            print(" \(mark) \(i + 1)) \(p.name)")
        }
        print("Switch \(provider) to [1-\(profiles.count)]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        if let n = Int(line), (1...profiles.count).contains(n) { return profiles[n - 1].name }
        if profiles.contains(where: { $0.name == line }) { return line }
        throw QError("invalid choice '\(line)'")
    }

    private static func runHooks(_ profile: Profile, provider: String) throws {
        let env = ["QSWITCH_PROVIDER": provider, "QSWITCH_PROFILE": profile.name, "QSWITCH_ACCOUNT": profile.account ?? profile.name]
        for hook in profile.onSwitch {
            let status = try Shell.interactive(hook, env: env)
            if status != 0 { warn("hook exited \(status): \(hook)") }
        }
    }

    // MARK: add / save

    /// Logs in to a new account interactively and stores it as a profile.
    static func add(_ args: Args) throws {
        guard args.positional.count == 2 else { throw QError("usage: qswitch add <provider> <profile> [--account ID] [--on-switch CMD]...") }
        let (providerName, name) = (args.positional[0], args.positional[1])
        try validateName(name)

        try Store.withLock {
            var config = try Store.load()
            let provider = try config.provider(providerName)
            if config.profiles[providerName]?.contains(where: { $0.name == name }) == true {
                throw QError("profile '\(name)' already exists for \(providerName); use `qswitch save` to overwrite it with the current login")
            }
            guard let login = provider.login else { throw QError("\(providerName) has no login command; log in manually and run `qswitch save \(providerName) \(name)`") }
            let previous = config.active[providerName]

            if provider.strategy == .snapshot {
                if let previous { try saveLive(provider, as: previous, config: config) }
                try Snapshot.clearLive(provider)
            }

            print("Running: \(login)".dim)
            let status = try Shell.interactive(login)
            guard status == 0 else {
                if provider.strategy == .snapshot, let previous {
                    try? Vault.load(provider: providerName, profile: previous).restore(provider)
                    warn("login failed; restored '\(previous)'")
                }
                throw QError("login command failed (exit \(status))")
            }

            try register(provider, name: name, args: args, config: &config)
        }
        print("Saved \(providerName.bold)/\(name.green) and made it active")
    }

    /// Stores whatever is currently logged in as a profile (import an existing login, or refresh one).
    static func save(_ args: Args) throws {
        guard args.positional.count == 2 else { throw QError("usage: qswitch save <provider> <profile> [--account ID] [--on-switch CMD]...") }
        let (providerName, name) = (args.positional[0], args.positional[1])
        try validateName(name)
        try Store.withLock {
            var config = try Store.load()
            let provider = try config.provider(providerName)
            try register(provider, name: name, args: args, config: &config)
        }
        print("Saved current \(providerName.bold) login as \(name.green) (active)")
    }

    private static func register(_ provider: Provider, name: String, args: Args, config: inout Config) throws {
        let existing = config.profiles[provider.name]?.first { $0.name == name }
        var profile = existing ?? Profile(name: name, createdAt: Date())

        switch provider.strategy {
        case .snapshot:
            let snap = try Snapshot.capture(provider)
            guard !snap.isEmpty else {
                throw QError("nothing to save: none of \(provider.name)'s tracked files/keychain items exist. Tracked: \(trackedDescription(provider))")
            }
            try Vault.save(snap, provider: provider.name, profile: name)
        case .command:
            if let account = args.value("account") {
                profile.account = account
            } else if profile.account == nil, let cmd = provider.accountCommand {
                let r = try Shell.output(cmd)
                guard r.status == 0, !r.out.isEmpty else { throw QError("could not detect account via `\(cmd)`; pass --account") }
                profile.account = r.out
            }
        }
        if provider.strategy == .snapshot, let account = args.value("account") { profile.account = account }
        if args.has("on-switch") { profile.onSwitch = args.values("on-switch") }
        profile.lastUsed = Date()
        config.upsert(profile, for: provider.name)
        config.active[provider.name] = name
        try Store.save(config)
    }

    // MARK: profile management

    static func remove(_ args: Args) throws {
        guard args.positional.count == 2 else { throw QError("usage: qswitch remove <provider> <profile>") }
        let (providerName, name) = (args.positional[0], args.positional[1])
        try Store.withLock {
            var config = try Store.load()
            _ = try config.profile(providerName, name)
            config.profiles[providerName]?.removeAll { $0.name == name }
            if config.active[providerName] == name { config.active[providerName] = nil }
            Vault.delete(provider: providerName, profile: name)
            try Store.save(config)
        }
        print("Removed \(providerName)/\(name) (your live login was not touched)")
    }

    static func rename(_ args: Args) throws {
        guard args.positional.count == 3 else { throw QError("usage: qswitch rename <provider> <old> <new>") }
        let (providerName, old, new) = (args.positional[0], args.positional[1], args.positional[2])
        try validateName(new)
        try Store.withLock {
            var config = try Store.load()
            var profile = try config.profile(providerName, old)
            if config.profiles[providerName]?.contains(where: { $0.name == new }) == true { throw QError("'\(new)' already exists") }
            try Vault.rename(provider: providerName, from: old, to: new)
            config.profiles[providerName]?.removeAll { $0.name == old }
            profile.name = new
            config.upsert(profile, for: providerName)
            if config.active[providerName] == old { config.active[providerName] = new }
            try Store.save(config)
        }
        print("Renamed \(providerName)/\(old) → \(new)")
    }

    /// Edits per-profile settings: account and on-switch hooks.
    static func set(_ args: Args) throws {
        guard args.positional.count == 2 else { throw QError("usage: qswitch set <provider> <profile> [--account ID] [--on-switch CMD]... [--clear-hooks]") }
        let (providerName, name) = (args.positional[0], args.positional[1])
        try Store.withLock {
            var config = try Store.load()
            var profile = try config.profile(providerName, name)
            if let account = args.value("account") { profile.account = account }
            if args.flag("clear-hooks") { profile.onSwitch = [] }
            profile.onSwitch += args.values("on-switch")
            config.upsert(profile, for: providerName)
            try Store.save(config)
        }
        print("Updated \(providerName)/\(name)")
    }

    static func whoami(_ args: Args) throws {
        guard let name = args.positional.first else { throw QError("usage: qswitch whoami <provider>") }
        let provider = try Store.load().provider(name)
        guard let cmd = provider.whoami else { throw QError("\(name) has no whoami command configured") }
        exit(try Shell.interactive(cmd))
    }

    // MARK: providers

    static func providers(_ args: Args) throws {
        let sub = args.positional.first ?? "list"
        let rest = args.dropFirst()
        switch sub {
        case "list", "ls": try providerList()
        case "add": try providerAdd(rest)
        case "remove", "rm": try providerRemove(rest)
        case "show": try providerShow(rest)
        default: throw QError("unknown subcommand 'provider \(sub)'. Try: list, add, show, remove")
        }
    }

    private static func providerList() throws {
        let config = try Store.load()
        for p in config.providers.values.sorted(by: { $0.name < $1.name }) {
            let count = config.profiles[p.name]?.count ?? 0
            print("\(p.name.bold)  \(p.strategy.rawValue.dim)  \(count) profile\(count == 1 ? "" : "s")" + (p.description.map { "  — \($0)" } ?? ""))
        }
    }

    private static func providerShow(_ args: Args) throws {
        guard let name = args.positional.first else { throw QError("usage: qswitch provider show <name>") }
        let p = try Store.load().provider(name)
        print("\(p.name.bold) (\(p.strategy.rawValue))")
        if let d = p.description { print("  description: \(d)") }
        if let l = p.login { print("  login:       \(l)") }
        for f in p.files { print("  file:        \(f)") }
        for k in p.keychain { print("  keychain:    \(k.display)") }
        if let s = p.switchCommand { print("  switch:      \(s)") }
        if let a = p.accountCommand { print("  account-cmd: \(a)") }
        if let w = p.whoami { print("  whoami:      \(w)") }
    }

    private static func providerAdd(_ args: Args) throws {
        guard let name = args.positional.first else {
            throw QError("usage: qswitch provider add <name> --login CMD (--file PATH... | --keychain SERVICE[:ACCOUNT]... | --switch CMD) [--whoami CMD] [--account-cmd CMD] [--description TEXT]")
        }
        try validateName(name)
        let files = args.values("file")
        let keychain = args.values("keychain").map(KeychainRef.init(spec:))
        let switchCommand = args.value("switch")
        let strategy: Strategy = switchCommand != nil ? .command : .snapshot
        if strategy == .snapshot && files.isEmpty && keychain.isEmpty {
            throw QError("a provider needs --file/--keychain (qswitch swaps them) or --switch (the CLI switches itself)")
        }
        if strategy == .command && (!files.isEmpty || !keychain.isEmpty) {
            throw QError("--switch can't be combined with --file/--keychain")
        }
        for f in files where !f.hasPrefix("/") && !f.hasPrefix("~") {
            throw QError("file paths must be absolute or start with ~: \(f)")
        }
        let provider = Provider(
            name: name, description: args.value("description"), strategy: strategy, login: args.value("login"),
            files: files, keychain: keychain, switchCommand: switchCommand,
            accountCommand: args.value("account-cmd"), whoami: args.value("whoami")
        )
        try Store.withLock {
            var config = try Store.load()
            if config.providers[name] != nil && !args.flag("force") {
                throw QError("provider '\(name)' already exists (pass --force to replace its definition)")
            }
            config.providers[name] = provider
            try Store.save(config)
        }
        print("Added provider \(name.bold). Next: qswitch add \(name) <profile>   (or `qswitch save \(name) <profile>` if already logged in)")
    }

    private static func providerRemove(_ args: Args) throws {
        guard let name = args.positional.first else { throw QError("usage: qswitch provider remove <name> [--force]") }
        try Store.withLock {
            var config = try Store.load()
            _ = try config.provider(name)
            let profiles = config.profiles[name] ?? []
            if !profiles.isEmpty && !args.flag("force") {
                throw QError("\(name) has \(profiles.count) saved profile(s); pass --force to delete them too")
            }
            for p in profiles { Vault.delete(provider: name, profile: p.name) }
            config.providers[name] = nil
            config.profiles[name] = nil
            config.active[name] = nil
            try Store.save(config)
        }
        print("Removed provider \(name)")
    }

    // MARK: misc

    static func configCommand(_ args: Args) throws {
        _ = try Store.load()
        if args.flag("edit") {
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
            exit(try Shell.interactive("\(editor) \(Shell.quote(Paths.configFile.path))"))
        }
        print(Paths.configFile.path)
    }

    private static func validateName(_ name: String) throws {
        let ok = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.@".contains($0) } && !name.hasPrefix(".")
        guard ok else { throw QError("invalid name '\(name)': use letters, digits, - _ . @") }
    }

    private static func trackedDescription(_ p: Provider) -> String {
        (p.files + p.keychain.map { "keychain:\($0.display)" }).joined(separator: ", ")
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("qswitch: \(message)\n".yellow.utf8))
}
