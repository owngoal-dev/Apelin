import enum ApelinProtocol.ScreenConsent
import Foundation

// MARK: - shell_run

/// How `shell_run` was classified, structurally (never by command prefix).
public enum RunCodeInvocation: Sendable, Hashable, Codable {
    /// A plain argv: an executable name or path, and arguments.
    case argv([String])
    /// Shell text that did not reduce to a plain argv: pipes, redirection,
    /// substitution, several commands, or anything unparsed.
    case shell(String)
    /// A script handed to an interpreter (`sh`, `bash`, `python3`, …).
    case script(interpreter: String, source: String)

    /// The program that opens apps and links or reads and acts on the
    /// screen (`ScreenConsent.programs`, icli first) that this runs, as the
    /// session host reads the request it is sent as; nil for any other
    /// command.
    var screenProgram: String? {
        switch self {
        case let .argv(argv): ScreenConsent.program(inArgv: argv)
        case let .shell(text): ScreenConsent.program(in: text)
        case let .script(interpreter, source): ScreenConsent.program(inArgv: [interpreter, source])
        }
    }
}

public struct RunCodeRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var invocation: RunCodeInvocation
    /// Relative to the project root; the host re-canonicalises it.
    public var workingDirectory: String
    public var timeoutSeconds: Int
    /// As root instead of mobile; the host decides again whether it may.
    public var asRoot: Bool

    public init(
        context: HostCallContext,
        invocation: RunCodeInvocation,
        workingDirectory: String,
        timeoutSeconds: Int,
        asRoot: Bool = false,
    ) {
        self.context = context
        self.invocation = invocation
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.asRoot = asRoot
    }
}

/// The host did not run a call the agent sent as a preset: its own rule
/// (Apelind's `AgentRunCode.preset`) does not count it as one. The call
/// needs the user's approval instead, which the runner asks for.
public struct HostRefusedPresetError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}

public struct RunCodeResponse: Sendable, Hashable, Codable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var truncated: Bool
    public var durationMilliseconds: Int
    /// The host killed it at the request's timeout; nil, and absent from
    /// what the model reads, when it was not.
    public var timedOut: Bool?

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        truncated: Bool = false,
        durationMilliseconds: Int = 0,
        timedOut: Bool = false,
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.durationMilliseconds = durationMilliseconds
        self.timedOut = timedOut ? true : nil
    }
}
