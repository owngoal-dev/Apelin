#!/bin/bash
# Compile the app's event-to-transcript reducer, how it reads past a reopened
# session's replay, how it adopts the conversations agents open, how far it
# follows a turn, how the trace sheet lists a summary's steps, how dropped
# messages go back to the composer, which conversations a deleted project
# takes with it, which tool results are builds the star prompt counts and
# how often it asks, the order the sidebar lists conversations in, which
# projects the project menu lists at its top, which conversations offer
# Delete and when it asks first, and which replies leave a conversation
# unread, against the harness modules.
# Usage: test-chat-transcript.sh <ApelinKit modules directory>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
modules="$1"
work="$(mktemp -d -t apelin-chat-transcript)"
trap 'rm -rf -- "${work:?}"' EXIT

sources=(
    "$root/Apelin/Interface/Chats/ChatSummary.swift"
    "$root/Apelin/Interface/Chats/ChatUnread.swift"
    "$root/Apelin/Interface/Chats/Composer/ComposerDraft.swift"
    "$root/Apelin/Interface/Chats/Messages/ChatMessage.swift"
    "$root/Apelin/Interface/Chats/Messages/ApprovalCardText.swift"
    "$root/Apelin/Interface/Chats/Messages/ToolCallBanner.swift"
    "$root/Apelin/Interface/Chats/Messages/ToolCallDetail.swift"
    "$root/Apelin/Interface/Chats/Messages/TraceStep.swift"
    "$root/Apelin/Interface/Chats/ChatTranscript.swift"
    "$root/Apelin/Interface/Chats/ChatTranscriptCache.swift"
    "$root/Apelin/Interface/Chats/ChatStore.swift"
    "$root/Apelin/Interface/Chats/ChatAdoption.swift"
    "$root/Apelin/Interface/Chats/DroppedMessages.swift"
    "$root/Apelin/Interface/Chats/DeletedProjects.swift"
    "$root/Apelin/Interface/Chats/ChatDeletion.swift"
    "$root/Apelin/Interface/Chats/TurnFollowing.swift"
    "$root/Apelin/Interface/Root/SidebarOrder.swift"
    "$root/Apelin/Interface/Root/ProjectMenuOrder.swift"
    "$root/Apelin/Interface/Root/ChatRowAction.swift"
    "$root/Apelin/Interface/Feedback/CompletedBuilds.swift"
    "$root/Apelin/Interface/Feedback/StarPromptState.swift"
    "$root/Tests/ChatTranscript/TranscriptFold.swift"
    "$root/Tests/ChatTranscript/ToolCallDetailCheck.swift"
    "$root/Tests/ChatTranscript/TraceStepCheck.swift"
    "$root/Tests/ChatTranscript/ReplayEndCheck.swift"
    "$root/Tests/ChatTranscript/DroppedMessagesCheck.swift"
    "$root/Tests/ChatTranscript/DeletedProjectsCheck.swift"
    "$root/Tests/ChatTranscript/CompletedBuildsCheck.swift"
    "$root/Tests/ChatTranscript/StarPromptStateCheck.swift"
    "$root/Tests/ChatTranscript/SidebarOrderCheck.swift"
    "$root/Tests/ChatTranscript/ProjectMenuOrderCheck.swift"
    "$root/Tests/ChatTranscript/ChatDeletionCheck.swift"
    "$root/Tests/ChatTranscript/ChatUnreadCheck.swift"
    "$root/Tests/ChatTranscript/main.swift"
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
    "${objects[@]}" "${sources[@]}" -o "$work/chat-transcript"
"$work/chat-transcript"
