import Foundation

struct QError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var out: String { String(decoding: stdout, as: UTF8.self) }
        var err: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs an executable with captured stdout/stderr, optionally feeding stdin.
    @discardableResult
    static func capture(_ executable: String, _ args: [String], stdin: Data? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe { p.standardInput = inPipe }
        try p.run()
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        // Read both pipes concurrently so a chatty stderr can't deadlock us.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: outData, stderr: errData)
    }

    /// Runs a shell command line attached to the user's terminal (for interactive logins).
    @discardableResult
    static func interactive(_ command: String, env: [String: String] = [:]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        if !env.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Runs a shell command line and returns trimmed stdout (stderr passes through to the terminal).
    static func output(_ command: String) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        try p.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Replaces {account} / {profile} placeholders with shell-quoted values.
    static func render(_ template: String, account: String, profile: String) -> String {
        template
            .replacingOccurrences(of: "{account}", with: quote(account))
            .replacingOccurrences(of: "{profile}", with: quote(profile))
    }
}
