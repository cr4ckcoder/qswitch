/// Providers seeded into config.json on first run. After that they live in the config and can be
/// edited or removed like any user-added provider.
enum Builtins {
    static let providers: [Provider] = [
        Provider(
            name: "vercel",
            description: "Vercel CLI",
            strategy: .snapshot,
            login: "vercel login",
            files: [
                "~/Library/Application Support/com.vercel.cli/auth.json",
                "~/Library/Application Support/com.vercel.cli/config.json",
            ],
            whoami: "vercel whoami"
        ),
        Provider(
            name: "gh",
            description: "GitHub CLI (uses gh's native multi-account support)",
            strategy: .command,
            login: "gh auth login --hostname github.com",
            switchCommand: "gh auth switch --hostname github.com --user {account}",
            accountCommand: "gh api user --jq .login",
            whoami: "gh auth status --active --hostname github.com"
        ),
    ]
}
