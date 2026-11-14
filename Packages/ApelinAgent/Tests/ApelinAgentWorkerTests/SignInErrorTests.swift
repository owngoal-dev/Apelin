import ApelinAgent
@testable import ApelinAgentWorker
import ApelinProtocol
import Testing

@Suite("A session's sign-in that cannot be used")
struct SignInErrorTests {
    /// A saved sign-in whose exchange failed is told apart from one that is
    /// not saved, and each is answered as the app reads it.
    @Test
    func `it is answered by why`() {
        let missing = AgentWorker.signInError(.missingCredentials("github-copilot"), inboxRejected: ["a.json: not JSON"])
        #expect(missing.code == .denied && missing.reason == nil)
        #expect(missing.message.contains("github-copilot") && missing.message.contains("a.json: not JSON"))
        let offline = AgentWorker.signInError(.unresolved(message: "offline", reason: .offline))
        #expect(offline.code == .unavailable && offline.reason == .offline && offline.message == "offline")
        let refused = AgentWorker.signInError(.unresolved(message: "invalid_grant", reason: nil))
        #expect(refused.code == .internal && refused.reason == nil && refused.message == "invalid_grant")
    }
}
