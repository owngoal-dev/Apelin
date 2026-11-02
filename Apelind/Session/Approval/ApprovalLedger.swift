import ApelinCore
import ApelinProtocol
import Foundation

/// The host's private record of Confirm-mode approvals (Milestone 1 §7,
/// Documents/Schemas/README.md ▸ How the host uses them).
///
/// Per project: the template's build and packaging description digests,
/// recorded when `projectCreate` answers, and every digest the user approved
/// since. It lives in `<state>/approvals/`, root's and 0700, where neither
/// the agent nor any project file can write; the agent reads it through
/// `approvalDigestState` and nothing writes it from outside the host.
///
/// Beside it, per agent session (the worker instance key): the approval mode
/// the app opened the session with, and single-use removal approvals —
/// managed package removal is confirmed every time under Confirm.
actor ApprovalLedger {
    struct ProjectLedger: Codable, Equatable {
        var templates: [ApprovalDescriptionKind: String] = [:]
        var approved: [ApprovalDescriptionKind: [String]] = [:]
    }

    /// Kept per kind and project; the oldest approvals drop off first.
    static let maximumApprovals = 64

    /// What `recordApproval` added: the digest, and the approval it pushed
    /// out at the cap, unless that one was itself still pending (never
    /// accepted, so never brought back). It stays pending until the worker
    /// it was relayed to accepts it (`confirmApproval`) or does not
    /// (`withdrawApproval`).
    struct Grant: Equatable {
        var digest: String
        var kind: ApprovalDescriptionKind
        var project: String
        var evicted: String?
    }

    /// A digest every grant of which is still pending: how many there are,
    /// and what the first one pushed out.
    private struct Pending {
        var grants: Int
        var evicted: String?
    }

    private struct PendingKey: Hashable {
        var project: String
        var kind: ApprovalDescriptionKind
        var digest: String
    }

    private let directory: URL
    private var cache: [String: ProjectLedger] = [:]
    /// In memory only, so the file keeps its format: a host that restarts
    /// mid-relay has lost the worker too, and keeps the approval as given.
    private var pending: [PendingKey: Pending] = [:]
    /// Each approval's place in age order, also in memory only: stamped in
    /// file order when a project is read, and again whenever a digest goes
    /// to the newest end. A pushed-out approval keeps its stamp while the
    /// grant that pushed it is pending, so a withdrawn grant puts it back
    /// among the others where it was, whatever order the grants are
    /// withdrawn in.
    private var ages: [PendingKey: UInt64] = [:]
    private var nextAge: UInt64 = 0
    private var modes: [String: ApprovalMode] = [:]
    private var removals: [String: Set<String>] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: Sessions

    /// Called when an agent session opens (AgentHandler), with the mode the app chose.
    func setMode(_ mode: ApprovalMode, session: String) {
        modes[session] = mode
    }

    func forgetSession(_ session: String) {
        modes[session] = nil
        removals[session] = nil
    }

    /// An agent session the host was never told about is held to Confirm.
    func mode(session: String?) -> ApprovalMode {
        session.flatMap { modes[$0] } ?? .confirm
    }

    /// The user approved removing this installation, once (AgentHandler,
    /// relaying `agentApprove` on a package-removal request). False when it
    /// was already allowed.
    @discardableResult
    func allowRemoval(installationID: String, session: String) -> Bool {
        removals[session, default: []].insert(installationID).inserted
    }

    /// Spends a removal approval.
    func takeRemoval(installationID: String, session: String) -> Bool {
        removals[session]?.remove(installationID) != nil
    }

    // MARK: Digests

    /// The template's digest for the project, from `projectCreate`. A later
    /// template upgrade does not move it: the first record wins.
    func recordTemplate(_ digest: String, kind: ApprovalDescriptionKind, project: String) throws {
        var ledger = try load(project)
        guard ledger.templates[kind] == nil else { return }
        ledger.templates[kind] = try Self.normalized(digest)
        try save(ledger, project)
    }

    /// The user approved this description (AgentHandler, relaying
    /// `agentApprove` on a description-changed request). Nil when it was
    /// approved already and accepted (it moves to the newest end): there is
    /// nothing to take back. A digest another session's relay still has
    /// pending is shared, one grant each, so a refusal of one leaves the
    /// other.
    @discardableResult
    func recordApproval(_ digest: String, kind: ApprovalDescriptionKind, project: String) throws -> Grant? {
        var ledger = try load(project)
        let digest = try Self.normalized(digest)
        let key = PendingKey(project: project, kind: kind, digest: digest)
        var list = ledger.approved[kind, default: []]
        if list.contains(digest) {
            if pending[key] != nil {
                pending[key]?.grants += 1
                return Grant(digest: digest, kind: kind, project: project)
            }
            // Approved again: it moves to the newest end, the last to drop
            // off at the cap.
            list.removeAll { $0 == digest }
            list.append(digest)
            ledger.approved[kind] = list
            try save(ledger, project)
            stamp(key)
            return nil
        }
        list.append(digest)
        var evicted = list.count > Self.maximumApprovals ? list.removeFirst() : nil
        // One pushed out while still pending was never accepted, so it is
        // not one to bring back: withdrawing this grant must not restore it.
        if let pushed = evicted {
            let pushedKey = PendingKey(project: project, kind: kind, digest: pushed)
            if pending.removeValue(forKey: pushedKey) != nil {
                ages[pushedKey] = nil
                evicted = nil
            }
        }
        ledger.approved[kind] = list
        try save(ledger, project)
        stamp(key)
        pending[key] = Pending(grants: 1, evicted: evicted)
        return Grant(digest: digest, kind: kind, project: project, evicted: evicted)
    }

    /// The worker took the approval: the digest holds whatever any other
    /// pending grant of it does next.
    func confirmApproval(_ grant: Grant) {
        let key = PendingKey(project: grant.project, kind: grant.kind, digest: grant.digest)
        // What it pushed out is gone for good now, and so is its place.
        if let evicted = pending.removeValue(forKey: key)?.evicted {
            ages[PendingKey(project: grant.project, kind: grant.kind, digest: evicted)] = nil
        }
    }

    /// Takes back a grant `recordApproval` made, when the worker it was meant
    /// for did not accept it. The digest goes only with its last pending
    /// grant, and then the approval it pushed out at the cap comes back.
    func withdrawApproval(_ grant: Grant) throws {
        let key = PendingKey(project: grant.project, kind: grant.kind, digest: grant.digest)
        guard var held = pending[key] else { return }
        held.grants -= 1
        guard held.grants == 0 else {
            pending[key] = held
            return
        }
        pending[key] = nil
        ages[key] = nil
        var ledger = try load(grant.project)
        var list = ledger.approved[grant.kind, default: []].filter { $0 != grant.digest }
        if let evicted = held.evicted, !list.contains(evicted), list.count < Self.maximumApprovals {
            // Back in front of the first approval younger than it, not
            // simply at the oldest end: another withdrawn grant may already
            // have put back one that was pushed out after it.
            let age = ages[PendingKey(project: grant.project, kind: grant.kind, digest: evicted)] ?? 0
            let younger = list.firstIndex { other in
                (ages[PendingKey(project: grant.project, kind: grant.kind, digest: other)] ?? .max) > age
            }
            list.insert(evicted, at: younger ?? list.endIndex)
        }
        ledger.approved[grant.kind] = list
        try save(ledger, grant.project)
    }

    /// Makes the digest the youngest approval of its kind and project.
    private func stamp(_ key: PendingKey) {
        ages[key] = nextAge
        nextAge += 1
    }

    func state(
        of digest: String,
        kind: ApprovalDescriptionKind,
        project: String,
    ) throws -> ApprovalDigestStateResponse {
        let ledger = try load(project)
        let digest = try Self.normalized(digest)
        let template = ledger.templates[kind]
        let approved = ledger.approved[kind] ?? []
        let baseline: ApprovalBaseline = if digest == template {
            .matchesTemplate
        } else if approved.contains(digest) {
            .approved
        } else {
            .changed
        }
        return ApprovalDigestStateResponse(
            baseline: baseline,
            templateDigest: template,
            lastApprovedDigest: approved.last,
        )
    }

    /// Whether a run bound to this digest may go ahead without asking.
    func allows(_ digest: String, kind: ApprovalDescriptionKind, project: String) throws -> Bool {
        try state(of: digest, kind: kind, project: project).baseline != .changed
    }

    // MARK: Storage

    /// `sha256:` and 64 lowercase hex digits; a bare hex digest is accepted.
    static func normalized(_ digest: String) throws -> String {
        let hex = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
        guard hex.count == 64, hex.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else {
            throw ApelinError(
                .badRequest,
                "a description digest is 64 lowercase hex digits, optionally prefixed with sha256:",
            )
        }
        return "sha256:" + hex
    }

    /// A project ID names a file here, so it is held to a file-safe alphabet.
    static func validProjectID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.hasPrefix(".")
            && id.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
                    || byte == 45 || byte == 46 || byte == 95
            }
    }

    private func url(_ project: String) throws -> URL {
        guard Self.validProjectID(project) else { throw ApelinError(.badRequest, "not a project ID: \(project)") }
        return directory.appendingPathComponent(project + ".json")
    }

    private func load(_ project: String) throws -> ProjectLedger {
        if let cached = cache[project] {
            return cached
        }
        let file = try url(project)
        guard let data = try? Data(contentsOf: file) else { return ProjectLedger() }
        let ledger: ProjectLedger
        do {
            ledger = try JSONCoding.decode(ProjectLedger.self, from: data)
        } catch {
            // Never written over by the next approval: kept beside, and the
            // project starts with nothing approved, which asks again.
            UnreadableFile.setAside(file)
            ledger = ProjectLedger()
        }
        cache[project] = ledger
        // The file lists each kind oldest first.
        for (kind, digests) in ledger.approved {
            for digest in digests {
                stamp(PendingKey(project: project, kind: kind, digest: digest))
            }
        }
        return ledger
    }

    private func save(_ ledger: ProjectLedger, _ project: String) throws {
        let file = try url(project)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        try JSONCoding.encode(ledger).write(to: file, options: .atomic)
        cache[project] = ledger
    }
}
