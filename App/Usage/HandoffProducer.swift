import Foundation

/// Asks an agent for its handover by running its CLI, not by typing into it.
///
/// The first attempt typed a request into the live session and asked it to
/// write a file. That failed for a reason worth recording: a session runs in
/// whatever permission mode the user chose, and in the default one the agent
/// cannot write a file without asking — so it sat waiting for an approval
/// nobody was watching for, and the handover never appeared.
///
/// Both CLIs already have a non-interactive mode that resumes a conversation,
/// answers once, and exits. That is what this uses. Three things follow from
/// it, and all three are improvements rather than workarounds:
///
/// - **No write permission is needed.** The answer comes back on stdout.
/// - **The live session is untouched.** Claude forks the conversation rather
///   than continuing it, so the user's own session keeps its history and its
///   turn.
/// - **The bypass flag belongs here and only here.** Nobody is watching this
///   process, so an approval prompt would hang it; the session the user
///   actually works in still starts in the provider's default mode.
///
/// Both invocations below were run by hand against the real CLIs before being
/// written down. Uncoil adds no flag it has not seen work.
enum HandoffProducer {

    struct Result {
        var json: JSONValue?
        /// Why there is no answer, in words fit to show the next agent.
        var failure: String?
        /// What the CLI printed, kept for diagnostics only.
        var rawLength: Int = 0
    }

    /// Whether this provider can be asked at all.
    ///
    /// Gemini is absent because its non-interactive resume has not been
    /// verified, and an unverified invocation is a process that fails in a way
    /// nobody can read.
    static func canProduce(_ provider: AgentProvider) -> Bool {
        provider == .claude || provider == .codex
    }

    /// Runs a CLI the way a terminal would: through the login shell, with the
    /// prompt on standard input.
    ///
    /// Both halves of that are load-bearing and both were learned the hard way.
    ///
    /// **The login shell**, because a scrubbed environment makes Claude answer
    /// `"Not logged in"`. `ProcessRunner` trims a child's environment to
    /// PATH/HOME/LANG so that nothing of ours leaks into an untrusted process —
    /// right for an extension, wrong here, where the child *is* the user's own
    /// agent and needs the environment their shell gives it.
    ///
    /// **Standard input**, because the request is a multi-line block with
    /// braces and quotes in it. Interpolating that into a shell command line is
    /// a quoting bug waiting to happen; a redirect has nothing to escape.
    private static func runThroughShell(
        command: String,
        arguments: [String],
        stdin: String,
        workingDirectory: String,
        timeout: TimeInterval
    ) -> (output: String, launched: Bool, timedOut: Bool) {
        let promptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-handoff-req-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: promptFile) }
        try? stdin.write(to: promptFile, atomically: true, encoding: .utf8)

        // Every argument here is one this file produced; the prompt, the only
        // free text in play, never reaches the command line.
        let line = ([command] + arguments).joined(separator: " ")
            + " < '\(promptFile.path)'"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let run = ProcessRunner.run(
            executable: shell,
            arguments: ["-l", "-c", line],
            cwd: workingDirectory,
            timeout: timeout
        )
        return (run.stdoutString, run.launched, run.timedOut)
    }

    /// Runs the provider's one-shot CLI and returns whatever JSON it produced.
    ///
    /// Blocking; call it off the main actor.
    static func produce(
        provider: AgentProvider,
        executable: String,
        providerSessionID: String?,
        workingDirectory: String,
        request: String,
        timeout: TimeInterval = 180
    ) -> Result {
        guard canProduce(provider) else {
            return Result(failure: String(localized: "Uncoil cannot ask \(provider.displayName) for a handover."))
        }
        // No id is not the same as no conversation. Uncoil learns the
        // provider's own session id from hook events, and a session that never
        // sent one still has a conversation on disk — both CLIs can resume the
        // most recent one in a directory, and the session's working directory
        // is exactly the right scope for that. Refusing here was what made the
        // whole feature look broken while the flags were fine.
        let resume = providerSessionID.flatMap { $0.isEmpty ? nil : $0 }

        switch provider {
        case .claude:
            return produceWithClaude(
                executable: executable, sessionID: resume,
                workingDirectory: workingDirectory, request: request, timeout: timeout
            )
        case .codex:
            return produceWithCodex(
                executable: executable, sessionID: resume,
                workingDirectory: workingDirectory, request: request, timeout: timeout
            )
        default:
            return Result(failure: String(localized: "unsupported provider"))
        }
    }

    // MARK: - Claude

    /// `claude -p … --resume <id> --fork-session --output-format json`
    ///
    /// `--fork-session` is the important one: it reads the conversation and
    /// answers under a *new* id, so the session the user is still looking at
    /// does not gain a turn it did not ask for.
    private static func produceWithClaude(
        executable: String,
        sessionID: String?,
        workingDirectory: String,
        request: String,
        timeout: TimeInterval
    ) -> Result {
        let run = runThroughShell(
            command: shellQuoted(executable),
            arguments: ["-p"]
                // `--continue` picks the most recent conversation in this
                // directory, which is what the session is. `--fork-session`
                // applies to both and is why neither disturbs it.
                + (sessionID.map { ["--resume", shellQuoted($0)] } ?? ["--continue"])
                + ["--fork-session", "--output-format", "json",
                   "--dangerously-skip-permissions"],
            stdin: request,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        guard run.launched else {
            return Result(failure: String(localized: "its CLI could not be started"))
        }
        if run.timedOut {
            return Result(failure: String(localized: "it did not answer in time"))
        }

        // The envelope wraps the model's text in `result`; everything else in
        // it is accounting — including whether the run failed, which it reports
        // in the envelope rather than in an exit code.
        guard let envelope = extractJSON(from: run.output)?.objectValue else {
            return Result(
                failure: whatItSaid(run.output) ?? String(localized: "its answer could not be read"),
                rawLength: run.output.count
            )
        }
        guard let text = envelope["result"]?.stringValue else {
            return Result(
                failure: String(localized: "its answer had no result"),
                rawLength: run.output.count
            )
        }
        // "Not logged in" arrives as a perfectly well-formed envelope with
        // `is_error` set; reading only `result` would take the excuse for an
        // answer.
        if envelope["is_error"]?.boolValue == true {
            return Result(failure: shortened(text), rawLength: run.output.count)
        }
        return Result(json: extractJSON(from: text), rawLength: run.output.count)
    }

    // MARK: - Codex

    /// `codex exec resume <id> … -o <file>`
    ///
    /// The last message goes to a file rather than being picked out of the
    /// event stream: `codex exec` prints hooks, token counts and its own
    /// chrome around the answer, and `-o` is the CLI's own way of saying which
    /// part was the answer.
    private static func produceWithCodex(
        executable: String,
        sessionID: String?,
        workingDirectory: String,
        request: String,
        timeout: TimeInterval
    ) -> Result {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-handoff-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        let run = runThroughShell(
            command: shellQuoted(executable),
            arguments: ["exec", "resume"]
                // `--last` is the newest recorded session, filtered by working
                // directory — the same conversation, reached without an id.
                + (sessionID.map { [shellQuoted($0)] } ?? ["--last"])
                // `-` is Codex's own "read the prompt from stdin".
                + ["-",
                   "--skip-git-repo-check",
                   "--dangerously-bypass-approvals-and-sandbox",
                   "-o", shellQuoted(outputFile.path)],
            stdin: request,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        guard run.launched else {
            return Result(failure: String(localized: "its CLI could not be started"))
        }
        if run.timedOut {
            return Result(failure: String(localized: "it did not answer in time"))
        }
        guard let data = FileManager.default.contents(atPath: outputFile.path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return Result(
                failure: whatItSaid(run.output) ?? String(localized: "it produced no answer"),
                rawLength: run.output.count
            )
        }
        return Result(json: extractJSON(from: text), rawLength: text.count)
    }

    // MARK: - Saying what happened

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shortened(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return clean.count > 120 ? String(clean.prefix(120)) + "…" : clean
    }

    /// The first thing the CLI said, for a failure message.
    ///
    /// Shown because "its answer could not be read" is not a diagnosis — it
    /// hid `Not logged in` for a whole evening. Truncated and stripped of
    /// anything credential-shaped on the way out.
    private static func whatItSaid(_ output: String) -> String? {
        let line = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return shortened(UsageCredentials.redacted(line))
    }

    // MARK: - Reading the answer

    /// Pulls the JSON object out of whatever the model wrote around it.
    ///
    /// Asked for bare JSON, a model still sometimes fences it or adds a
    /// sentence. Taking the outermost braces is enough and costs nothing;
    /// refusing the answer over a stray "Here you go:" would throw away the
    /// whole handover.
    static func extractJSON(from text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
           direct.objectValue != nil {
            return direct
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(trimmed[start...end])
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(slice.utf8)),
              decoded.objectValue != nil else { return nil }
        return decoded
    }
}
