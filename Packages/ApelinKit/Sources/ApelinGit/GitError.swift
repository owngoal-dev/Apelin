internal import ApelinGitOptions
internal import GitKit
import Foundation

/// What a libgit2 call failed with: the error class and the message libgit2
/// left on this thread.
public struct GitError: Error, CustomStringConvertible, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The caller stopped the work (a progress callback said no).
        case cancelled
        /// The thing asked for is not there: no repository, no such path.
        case notFound
        /// The request makes no sense for this repository's state: nothing to
        /// commit, an unborn HEAD where a commit is needed, a bad path.
        case invalid
        /// The work would lose or overwrite something, so nothing was done:
        /// a checkout over a change or a file already in the work tree, or a
        /// clone into a folder that is already there.
        case conflict
        /// A pull that is not a fast-forward: the branch has commits its
        /// upstream does not, so moving it would lose them.
        case notFastForward
        /// The remote refused a push: its branch has commits this one does
        /// not, or a hook of its said no.
        case rejected
        /// A forced push's lease did not hold: the remote's branch is not at
        /// the commit the push was to replace, or the remote has no such
        /// branch. Nothing was pushed.
        case remoteChanged
        /// A forced push's local branch is not at the commit it was to send.
        /// Nothing was pushed.
        case localChanged
        /// A squash's branch is not at the commit it was to replace, or moved
        /// while it was squashed. Nothing was squashed.
        case headChanged
        /// The remote asked for a sign-in and had none, or refused the one
        /// it was given.
        case authenticationFailed
        /// Anything else libgit2 reported.
        case failed
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String {
        message
    }

    /// The error libgit2 just reported for `code`.
    static func last(_ code: Int32, _ what: String) -> GitError {
        var detail = "libgit2 error \(code)"
        if let error = git_error_last(), let message = error.pointee.message {
            detail = String(cString: message)
        }
        let kind: Kind = switch code {
        case GIT_EUSER.rawValue: .cancelled
        case GIT_ENOTFOUND.rawValue: .notFound
        case GIT_EEXISTS.rawValue, GIT_ECONFLICT.rawValue, GIT_EMERGECONFLICT.rawValue: .conflict
        case GIT_ENONFASTFORWARD.rawValue: .rejected
        case GIT_EAUTH.rawValue: .authenticationFailed
        case GIT_EUNBORNBRANCH.rawValue, GIT_EINVALIDSPEC.rawValue, GIT_EINVALID.rawValue: .invalid
        default: .failed
        }
        return GitError(kind, "\(what): \(detail)")
    }

    /// Throws the last libgit2 error when `code` is negative.
    @discardableResult
    static func check(_ code: Int32, _ what: @autoclosure () -> String) throws -> Int32 {
        guard code >= 0 else { throw last(code, what()) }
        return code
    }
}

/// libgit2 is initialised once per process and never shut down: the worker
/// lives as long as the host keeps it.
enum GitLibrary {
    /// How long a remote has to accept a connection, in milliseconds.
    static let connectTimeout: Int32 = 30000
    /// How long a remote may say nothing while a transfer waits on it, in
    /// milliseconds. A server that is working keeps the connection alive
    /// (git's own keep-alive is every 5 s), so only a stalled one is this
    /// silent.
    static let serverTimeout: Int32 = 120_000

    private static let initialised: Bool = {
        git_libgit2_init()
        // By default libgit2 waits on a silent server for ever. A transfer
        // that stalled never ended its task, and the conversation reading
        // that task could be neither stopped nor continued (#59).
        _ = apelin_git_set_option(Int32(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT.rawValue), connectTimeout)
        setServerTimeout(serverTimeout)
        return true
    }()

    /// Sets how long a remote may stay silent, in milliseconds.
    static func setServerTimeout(_ milliseconds: Int32) {
        _ = apelin_git_set_option(Int32(GIT_OPT_SET_SERVER_TIMEOUT.rawValue), milliseconds)
    }

    /// The limits libgit2 holds now, in milliseconds; nil for one it does
    /// not answer.
    static var timeouts: (connect: Int32?, server: Int32?) {
        func read(_ option: git_libgit2_opt_t) -> Int32? {
            var value: Int32 = 0
            return apelin_git_get_option(Int32(option.rawValue), &value) == 0 ? value : nil
        }
        return (read(GIT_OPT_GET_SERVER_CONNECT_TIMEOUT), read(GIT_OPT_GET_SERVER_TIMEOUT))
    }

    static func ensure() {
        _ = initialised
    }
}
