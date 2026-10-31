import ApelinGit
import ApelinProtocol
import Foundation

/// The git operations that change a branch's history rather than add to it
/// (`Operations/GitHistory.swift`): a squash. The forced push is `push`'s,
/// with a lease.
public extension GitService {
    /// A preview answers what a squash would combine and changes nothing;
    /// otherwise the commits after `base` become one, as the request says.
    func squash(_ request: GitSquashRequest) throws -> GitSquashResponse {
        let repository = try open(request.projectID).repository
        guard request.preview == true else {
            guard let base = request.base, let expectedHead = request.expectedHead, request.count == nil else {
                throw ApelinError(.badRequest, "A squash names its base and the expected head as full commit IDs, which a preview answers.")
            }
            guard let message = request.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ApelinError(.badRequest, "A squash needs the message of the commit it makes.")
            }
            let author = try author(name: nil, email: nil, repository: repository)
            let result = try Self.mapping {
                try repository.squash(base: base, expectedHead: expectedHead, message: message, author: author)
            }
            return Self.response(result.plan, commit: result.commit)
        }
        let base: GitSquashBase
        switch (request.base, request.count) {
        case let (commit?, nil): base = .commit(commit)
        case let (nil, count?): base = .count(count)
        default: throw ApelinError(.badRequest, "Name the commits to squash by base or by count, one of the two.")
        }
        // A squash with no author to write it would fail once approved: the
        // preview says so first.
        _ = try author(name: nil, email: nil, repository: repository)
        return try Self.response(Self.mapping { try repository.squashPlan(base) }, commit: nil)
    }

    private static func response(_ plan: GitSquashPlan, commit: String?) -> GitSquashResponse {
        GitSquashResponse(
            branch: plan.branch,
            previousHead: plan.head,
            base: plan.base,
            commits: plan.commits.map { GitCommitSummary(commit: $0.commit, subject: $0.subject) },
            count: plan.count,
            upstream: plan.upstream,
            published: plan.published,
            commit: commit,
        )
    }
}
