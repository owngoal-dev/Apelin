#!/bin/bash
# The session host's macOS-runnable tests (Tests/SessionHost/main.swift),
# compiled with the Apelind sources they exercise against the ApelinCore and
# ApelinProtocol that `swift build` left in <modules>. Run by `make harness`.
#
# usage: test-session-host.sh <modules-dir> [<apelin-environment-harness>]
#
# With the second argument (built by `swift build --product
# apelin-environment-harness` in the same scratch path), the toolchain setup
# runs end to end: the real environment worker in its own process against
# this host's install bridge and a fake irisind.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
modules="$1"
harness="${2:-}"
work="$(mktemp -d /private/tmp/apelin-session-host.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT

sources=(
    "$root/Apelind/System.swift"
    "$root/Apelind/Spawn.swift"
    "$root/Apelind/Session/CallerPolicy.swift"
    "$root/Apelind/Session/TaskRegistry.swift"
    "$root/Apelind/Session/TaskResume.swift"
    "$root/Apelind/Session/Approval/ApprovalLedger.swift"
    "$root/Apelind/Session/Install/ArtifactRegistry.swift"
    "$root/Apelind/Session/Install/DebControlPeek.swift"
    "$root/Apelind/Session/Install/InstallBridge.swift"
    "$root/Apelind/Session/Install/InstallConflicts.swift"
    "$root/Apelind/Session/Install/InstallService.swift"
    "$root/Apelind/Session/Install/InstallationStore.swift"
    "$root/Apelind/Session/Install/ManagedPackagePolicy.swift"
    "$root/Apelind/Session/Install/ToolchainTreePruner.swift"
    "$root/Apelind/Session/Files/AtomicReplace.swift"
    "$root/Apelind/Session/Files/FileScopes.swift"
    "$root/Apelind/Session/Files/ProtectedEditPolicy.swift"
    "$root/Apelind/Session/Files/ProtectedEditor.swift"
    "$root/Apelind/Session/Terminal/TerminalSession.swift"
    "$root/Apelind/Session/Terminal/TerminalHost.swift"
    "$root/Apelind/Session/ToolHost/AttachmentCopies.swift"
    "$root/Apelind/Session/Agent/AgentProjects.swift"
    "$root/Apelind/Session/Agent/AgentRunCode.swift"
    "$root/Apelind/Session/Agent/AgentRunCodePresets.swift"
    "$root/Apelind/Session/Agent/AgentApprovals.swift"
    "$root/Apelind/Session/Agent/AgentOpenTurns.swift"
    "$root/Apelind/Session/Agent/AgentHostRun.swift"
    "$root/Apelind/Session/Agent/AgentConversationRules.swift"
    "$root/Apelind/Session/Agent/AgentConversationList.swift"
    "$root/Apelind/Session/Agent/AgentEnvironmentRules.swift"
    "$root/Apelind/Session/Agent/AgentExternalBuildRules.swift"
    "$root/Apelind/Session/Agent/AgentProjectRenameRules.swift"
    "$root/Apelind/Session/Agent/AgentProjectDeleteRules.swift"
    "$root/Apelind/Session/Agent/AgentUIActionRules.swift"
    "$root/Apelind/Session/Agent/AgentScreenRules.swift"
    "$root/Apelind/Session/Agent/AgentFeedbackRules.swift"
    "$root/Apelind/Session/Agent/AgentRepositoryCreateRules.swift"
    "$root/Apelind/Session/Agent/AgentIssueCreateRules.swift"
    "$root/Apelind/Session/Agent/AgentForcePushRules.swift"
    "$root/Apelind/Session/Agent/AgentSquashRules.swift"
    "$root/Apelind/Session/Agent/AgentResetToRemoteRules.swift"
    "$root/Apelind/Session/Agent/AgentPublishRules.swift"
    "$root/Apelind/Session/Notice/AgentNotices.swift"
    "$root/Tests/SessionHost/AgentNoticeChecks.swift"
    "$root/Tests/SessionHost/AgentOpenChecks.swift"
    "$root/Tests/SessionHost/AgentHostRunChecks.swift"
    "$root/Tests/SessionHost/RootRunChecks.swift"
    "$root/Tests/SessionHost/ScreenConsentChecks.swift"
    "$root/Tests/SessionHost/ResetToRemoteChecks.swift"
    "$root/Tests/SessionHost/ToolchainEndToEnd.swift"
    "$root/Tests/SessionHost/ToolchainPruneChecks.swift"
    "$root/Tests/SessionHost/main.swift"
)

# The objects: one per module (the new build system) or one per source file.
objects=()
for module in ApelinCore ApelinProtocol; do
    if [[ -f "$modules/$module.o" ]]; then
        objects+=("$modules/$module.o")
    else
        while IFS= read -r object; do objects+=("$object"); done < <(find "$modules/.." "$modules" -maxdepth 2 -path "*/$module.build/*.o" | sort -u)
    fi
done
[[ ${#objects[@]} -ge 2 ]] || { echo "error: no ApelinCore/ApelinProtocol objects near $modules" >&2; exit 1; }

xcrun --sdk macosx swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -I "$root/Shared/XPCShim" -I "$modules" \
    "${objects[@]}" "${sources[@]}" -o "$work/session-host"
APELIN_REPOSITORY="$root" APELIN_ENVIRONMENT_HARNESS="$harness" "$work/session-host"
