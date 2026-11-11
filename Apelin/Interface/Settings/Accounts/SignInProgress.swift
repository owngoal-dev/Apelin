import ApelinCore
import ApelinProtocol
import Foundation

/// What a sign-in task has asked for so far, read from its events
/// (AGENTS.md ▸ Decisions ▸ Agent sign-in). Only the latest ask matters:
/// a flow asks once, then waits for the user or ends.
struct SignInProgress {
    struct KeyField: Equatable {
        var field: AgentSignInField
        var required: Bool
        var secure: Bool
        var defaultValue: String?
        /// What the empty field shows, kwwk's own hint: never a real key.
        var placeholder: String?
    }

    enum Step: Equatable {
        /// Before the flow has said anything: apelin-agent starting, or
        /// GitHub answering for a device code.
        case starting
        /// A code the user enters on the provider's page.
        case deviceCode(code: String, page: URL, pageHoldsCode: Bool)
        /// A page to sign in on; the loopback listener waits for its redirect.
        case browser(page: URL, acceptsCallbackURL: Bool)
        /// The fields of a key.
        case keys([KeyField])
        case ended(TaskState, message: String?)
    }

    private(set) var step: Step = .starting

    var isFinished: Bool {
        if case .ended = step {
            return true
        }
        return false
    }

    mutating func apply(_ event: TaskEvent) {
        guard !isFinished else { return }
        let payload = event.payload
        switch event.kind {
        case "deviceCode":
            guard let code = payload?["code"]?.stringValue,
                  let page = payload?["verificationURL"]?.stringValue.flatMap(URL.init(string:))
            else { return }
            step = .deviceCode(code: code, page: page, pageHoldsCode: payload?["pageHoldsCode"] == .bool(true))
        case "authorize":
            guard let page = payload?["url"]?.stringValue.flatMap(URL.init(string:)) else { return }
            step = .browser(page: page, acceptsCallbackURL: payload?["acceptsCallbackURL"] == .bool(true))
        case "input":
            guard case let .array(entries)? = payload?["fields"] else { return }
            step = .keys(entries.compactMap { entry in
                guard let key = entry["key"]?.stringValue,
                      let field = AgentSignInField(rawValue: key)
                else { return nil }
                return KeyField(
                    field: field,
                    required: entry["required"] == .bool(true),
                    secure: entry["secure"] == .bool(true),
                    defaultValue: entry["defaultValue"]?.stringValue,
                    placeholder: entry["placeholder"]?.stringValue,
                )
            })
        case TaskEvent.stateKind:
            guard let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)), state.isTerminal else {
                return
            }
            step = .ended(state, message: payload?["message"]?.stringValue)
        default:
            break
        }
    }

    /// The task could not be read any more.
    mutating func lost(_ message: String) {
        guard !isFinished else { return }
        step = .ended(.failed, message: message)
    }
}

extension SignInProgress.Step {
    /// How a sign-in is finished from a browser on another device, for a
    /// page this device cannot show (claude.ai refuses iOS 16's WebKit, #49).
    enum Elsewhere: Equatable {
        /// The code is entered on the page there.
        case code
        /// Signing in on the page there is enough: the page's link carries
        /// the code, or the flow asks the provider until the user is in.
        case page
        /// The page there ends on a redirect to the listener on this
        /// device, which that browser cannot open; its address, pasted
        /// here, stands in for it.
        case redirect
    }

    /// Nil where there is no such way: nothing to open, or a page that
    /// sends the browser back to a listener on this device and takes no
    /// pasted address (Kiro, whose listener is kwwk's own).
    var elsewhere: Elsewhere? {
        switch self {
        case let .deviceCode(_, _, pageHoldsCode):
            pageHoldsCode ? .page : .code
        case let .browser(page, acceptsCallbackURL):
            if acceptsCallbackURL {
                .redirect
            } else if Self.returnsToThisDevice(page) {
                nil
            } else {
                .page
            }
        case .starting, .keys, .ended:
            nil
        }
    }

    /// Whether the page names a loopback address to send the browser back
    /// to, as a value of its query.
    static func returnsToThisDevice(_ page: URL) -> Bool {
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { item in
            guard let host = item.value.flatMap(URLComponents.init(string:))?.host?.lowercased() else { return false }
            return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }
    }
}
