import SwiftUI

extension ChatWidgetSnapshot.Chat {
    /// What its status is called, alone.
    var statusWord: String {
        switch status {
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Needs Approval")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        }
    }

    /// Name the approval action directly, e.g. "Approve: Install" or "允许安装".
    /// Keep it short enough for the small widget’s single status line.
    var statusLine: String {
        guard status == .waiting, let step = approvalStep else { return statusWord }
        return String(localized: "Approve: \(step)")
    }

    /// The project, or General Chat for a conversation in none.
    var projectName: String {
        project ?? String(localized: "General Chat")
    }

    /// The step a waiting approval is for, in a word.
    private var approvalStep: String? {
        switch approvalTool {
        case "apelin_package_install": String(localized: "Install")
        case "apelin_package_remove": String(localized: "Remove")
        case "apelin_project_build": String(localized: "Build")
        case "shell_run": String(localized: "Run")
        case "apelin_device_respring": String(localized: "Respring")
        case "file_write", "file_create", "file_edit": String(localized: "Edit")
        case "git_commit": String(localized: "Commit")
        case "git_pull": String(localized: "Pull")
        case "git_push": String(localized: "Push")
        case "apelin_package_publish", "apelin_package_release": String(localized: "Publish")
        case "apelin_git_set_author", "apelin_git_save_credential", "apelin_git_remove_credential": String(localized: "Git Settings")
        case "apelin_project_create": String(localized: "Create Project")
        case "apelin_project_rename": String(localized: "Rename Project")
        case "apelin_skill_save": String(localized: "Save Skill")
        case "apelin_skill_remove": String(localized: "Remove Skill")
        case "apelin_screen_interact": String(localized: "Control Screen")
        default: nil
        }
    }
}

extension ChatWidgetSnapshot {
    /// Prioritize pending approvals; otherwise show active work, or nothing when idle.
    var summaryLine: String? {
        if waitingCount > 0 {
            return String(localized: "\(waitingCount) awaiting approval")
        }
        if workingCount > 0 {
            return String(localized: "\(workingCount) working")
        }
        return nil
    }
}

/// The mark, the name and the counts trailing in the dim style.
struct ChatWidgetHeader: View {
    let snapshot: ChatWidgetSnapshot
    let theme: WidgetTheme

    var body: some View {
        HStack(alignment: .center, spacing: WidgetSpacing.line) {
            MarkView(size: 22, braces: theme.braces)
            Text(verbatim: "Apelin")
                .font(.rounded(.subheadline, .bold))
            Spacer(minLength: WidgetSpacing.line)
            if let summary = snapshot.summaryLine {
                Text(summary)
                    .font(.rounded(.subheadline))
                    .opacity(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One line per conversation — its status dot, its title and its project —
/// then how many more there are past the last.
struct ChatWidgetRows: View {
    let snapshot: ChatWidgetSnapshot
    let theme: WidgetTheme
    let limit: Int
    var spacing: CGFloat = WidgetSpacing.row
    /// Each row opens its conversation (the medium widget). The Live
    /// Activity opens one conversation for the whole card instead.
    var linksRows = false

    var body: some View {
        let shown = Array(snapshot.chats.prefix(limit))
        let hidden = snapshot.totalCount - shown.count
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(shown) { chat in
                if linksRows {
                    Link(destination: chat.link) {
                        ChatWidgetRow(chat: chat, theme: theme)
                    }
                } else {
                    ChatWidgetRow(chat: chat, theme: theme)
                }
            }
            if hidden > 0 {
                Text("\(hidden) more chats")
                    .font(.rounded(.footnote))
                    .opacity(0.5)
                    .padding(.leading, WidgetSpacing.dotColumn)
            }
        }
    }
}

struct ChatWidgetRow: View {
    let chat: ChatWidgetSnapshot.Chat
    let theme: WidgetTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WidgetSpacing.line) {
            StatusDot(color: theme.color(for: chat.status))
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] + 1.5 }
            Text(verbatim: chat.title)
                .font(.rounded(.subheadline))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: WidgetSpacing.line)
            Text(verbatim: chat.projectName)
                .font(.rounded(.footnote))
                .opacity(0.5)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(chat.statusLine))
    }
}
