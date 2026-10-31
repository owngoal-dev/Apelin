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
    private static let initialised: Bool = {
        git_libgit2_init()
        return true
    }()

    static func ensure() {
        _ = initialised
    }
}
