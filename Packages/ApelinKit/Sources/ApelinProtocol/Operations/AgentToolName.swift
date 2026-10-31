/// Every tool an agent session offers, by the name the model calls it and
/// the session's events record it. ApelinAgent says what each one does
/// (`ToolCatalog`); the session host and the app read the names from here,
/// so a rename reaches all three at once.
///
/// A tool that acts on what Apelin keeps — its projects and templates, the
/// packages it installs, the device, toolchains and SDKs, conversations,
/// memory, skills, its settings — or reaches past the device, as the web
/// fetch does, is `apelin_<scope>_<verb>`; a generic verb on the session's
/// own project is `<domain>_<verb>`: `file_*`, `shell_run` and the
/// repository's `git_*`. MCP tools keep kwwk's `mcp__<server>__<tool>`.
public enum AgentToolName: String, Sendable, Hashable, Codable, CaseIterable {
    case fileWrite = "file_write"
    case fileEdit = "file_edit"
    case fileCreate = "file_create"
    case fileRead = "file_read"
    case fileList = "file_list"
    case fileGrep = "file_grep"
    case fileFind = "file_find"
    case fileShow = "file_show"
    case shellRun = "shell_run"
    case sdkAnalyzeFramework = "apelin_sdk_analyze_framework"
    case sdkReadHeader = "apelin_sdk_read_header"
    case projectBuild = "apelin_project_build"
    case packageInstall = "apelin_package_install"
    case packageRemove = "apelin_package_remove"
    case packageList = "apelin_package_list"
    case packagePublish = "apelin_package_publish"
    case deviceRespring = "apelin_device_respring"
    case packageConfirmLoaded = "apelin_package_confirm_loaded"
    case logRead = "apelin_log_read"
    case crashList = "apelin_crash_list"
    case crashRead = "apelin_crash_read"
    case crashSymbolicate = "apelin_crash_symbolicate"
    case screenCapture = "apelin_screen_capture"
    case screenReadTree = "apelin_screen_read_tree"
    case screenInteract = "apelin_screen_interact"
    case memoryList = "apelin_memory_list"
    case memorySave = "apelin_memory_save"
    case memoryDelete = "apelin_memory_delete"
    case skillList = "apelin_skill_list"
    case skillRead = "apelin_skill_read"
    case skillSave = "apelin_skill_save"
    case skillRemove = "apelin_skill_remove"
    case notificationSend = "apelin_notification_send"
    case webFetch = "apelin_web_fetch"
    case feedbackSend = "apelin_feedback_send"
    case feedbackRead = "apelin_feedback_read"
    case feedbackEdit = "apelin_feedback_edit"
    case projectCheckDistribution = "apelin_project_check_distribution"
    case templateList = "apelin_template_list"
    case projectList = "apelin_project_list"
    case projectCreate = "apelin_project_create"
    case projectRename = "apelin_project_rename"
    case projectDelete = "apelin_project_delete"
    case gitStatus = "git_status"
    case gitDiff = "git_diff"
    case gitStage = "git_stage"
    case gitUnstage = "git_unstage"
    case gitCommit = "git_commit"
    case gitInit = "git_init"
    case gitFetch = "git_fetch"
    case gitPull = "git_pull"
    case gitPush = "git_push"
    case gitClone = "git_clone"
    case gitSquash = "git_squash"
    case gitRemoteList = "git_remote_list"
    case gitRemoteSet = "git_remote_set"
    case gitRemoteRemove = "git_remote_remove"
    case gitResetToRemote = "git_reset_to_remote"
    case gitReadSettings = "apelin_git_read_settings"
    case gitSetAuthor = "apelin_git_set_author"
    case gitSaveCredential = "apelin_git_save_credential"
    case gitRemoveCredential = "apelin_git_remove_credential"
    case gitCreateRepository = "apelin_git_create_repository"
    case gitCreateIssue = "apelin_git_create_issue"
    case conversationCreate = "apelin_conversation_create"
    case conversationSend = "apelin_conversation_send"
    case conversationList = "apelin_conversation_list"
    case conversationRead = "apelin_conversation_read"
    case conversationStop = "apelin_conversation_stop"
    case toolchainList = "apelin_toolchain_list"
    case sdkList = "apelin_sdk_list"
    case toolchainSetup = "apelin_toolchain_setup"
    case sdkImport = "apelin_sdk_import"
    case toolchainSelfTest = "apelin_toolchain_self_test"
    case projectSetEnvironment = "apelin_project_set_environment"
}

public extension AgentToolName {
    /// The names earlier builds gave a tool (0.1.8 and before, and
    /// `notify_user` after it), for the events and transcripts recorded
    /// then. None of them is a current name.
    static let legacyNames: [String: AgentToolName] = [
        "write_file": .fileWrite,
        "patch_file": .fileEdit,
        "create_file": .fileCreate,
        "read_file": .fileRead,
        "list": .fileList,
        "grep": .fileGrep,
        "find": .fileFind,
        "run_code": .shellRun,
        "analyze_framework": .sdkAnalyzeFramework,
        "framework_header": .sdkReadHeader,
        "build": .projectBuild,
        "install": .packageInstall,
        "remove_package": .packageRemove,
        "respring": .deviceRespring,
        "confirm_loaded": .packageConfirmLoaded,
        "read_logs": .logRead,
        "list_crashes": .crashList,
        "read_crash": .crashRead,
        "symbolicate_crash": .crashSymbolicate,
        "capture_screen": .screenCapture,
        "read_ui_tree": .screenReadTree,
        "ui_action": .screenInteract,
        "memory_list": .memoryList,
        "memory_save": .memorySave,
        "memory_delete": .memoryDelete,
        "read_skill": .skillRead,
        "notify_user": .notificationSend,
        "check_distribution": .projectCheckDistribution,
        "project_template_list": .templateList,
        "project_create": .projectCreate,
        "git_settings": .gitReadSettings,
        "git_set_author": .gitSetAuthor,
        "git_save_credential": .gitSaveCredential,
        "git_remove_credential": .gitRemoveCredential,
        "conversation_create": .conversationCreate,
        "conversation_send": .conversationSend,
        "conversation_list": .conversationList,
        "conversation_read": .conversationRead,
        "conversation_stop": .conversationStop,
        "toolchain_list": .toolchainList,
        "sdk_list": .sdkList,
        "toolchain_setup": .toolchainSetup,
        "sdk_import": .sdkImport,
        "toolchain_self_test": .toolchainSelfTest,
        "project_environment_set": .projectSetEnvironment,
    ]

    /// The tool a recorded name means: a current name or one an earlier
    /// release used; nil for any other, such as an MCP server's.
    static func canonical(_ name: String) -> AgentToolName? {
        AgentToolName(rawValue: name) ?? legacyNames[name]
    }
}
