@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import Testing

/// The device passcode (owner, 2026-11-21): the user saves it in Settings,
/// and the agent gets past the lock screen with `press_button` `unlock`,
/// never by asking for the passcode, typing it or running icli's own
/// passcode command, which would spend an attempt Apelin's checks do not
/// see. The unlock is a UI action like the rest: Strict asks, and so does
/// Ask Before Using the Screen, in every mode.
@Suite("The agent's unlock")
struct DeviceUnlockPromptTests {
    let home: TemporaryHome
    let root: ScopedRoot

    init() throws {
        home = try TemporaryHome()
        root = try ScopedRoot(home.projectURL)
    }

    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test
    func `press_button takes unlock`() throws {
        defer { home.remove() }
        #expect(try ToolRunner.uiAction(["action": "press_button", "button": "unlock"]) == .pressButton("unlock"))
    }

    @Test
    func `an unlock asks as every screen action does, saying what it does`() {
        defer { home.remove() }
        var facts = InvocationFacts(tool: .local(.screenInteract))
        let unlock = ScreenControlApproval.interact(targetID: nil, action: .pressButton("unlock"))
        facts.screenControl = unlock
        for mode: ApprovalMode in [.confirm, .relaxed, .full] {
            let verdict = ApprovalPolicy(mode: mode, asksBeforeScreen: true).evaluate(facts, root: root)
            #expect(verdict == .ask(
                reason: "Unlocks the device, with the passcode saved in Apelin's Settings when it is locked, and goes to the Home Screen. \(ApprovalPolicy.screenNote)",
                detail: .screenControl(unlock),
            ), "\(mode)")
        }
        let strict = ApprovalPolicy(mode: .confirm, asksBeforeScreen: false).evaluate(facts, root: root)
        #expect(strict == .ask(reason: "This action changes this device. Review it before running.", detail: .none))
        #expect(ApprovalPolicy(mode: .relaxed, asksBeforeScreen: false).evaluate(facts, root: root) == .allow(.relaxed))
    }

    @Test
    func `the prompt, the tool and the skill send the agent to unlock and keep it off the passcode`() throws {
        defer { home.remove() }
        let prompt = Self.words(SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: []))
        #expect(prompt.contains("To get past the lock screen, press unlock with apelin_screen_interact, which uses the passcode the user saved and tested in Apelin's Settings; when it is refused or the lock screen stays, ask the user to unlock the device. Never guess a passcode, ask for one in the conversation or type one, and never run icli device passcode."))

        let tool = AgentToolName.screenInteract.summary
        #expect(tool.contains("To get past the lock screen press unlock, which uses the passcode the user saved and tested in Apelin's Settings"))
        #expect(tool.contains("Never ask for, read or type the passcode, and never run icli device passcode."))

        let icli = try Self.words(#require(BuiltInSkills.all.first { $0.name == "apelin-icli" }).body)
        #expect(icli.contains("`press_button` `unlock` wakes the device, unlocks it with the passcode the user saved and tested in Apelin's Settings ▸ Agent when it is locked, and goes to the Home Screen"))
        #expect(icli.contains("Apelin tries the saved passcode once, only while the device has no failed passcode attempt on record, and removes it when it is rejected."))
        #expect(icli.contains("never press unlock again to retry a rejection. Never ask for, read or type a passcode, in the conversation or on the screen, and never run `icli device passcode`"))
    }
}
