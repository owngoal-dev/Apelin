#!/bin/bash
# Settings ▸ Skills ▸ From GitHub against a scripted GitHub: the links it
# takes, refs with slashes, what a scan finds, leaves behind and refuses,
# GitHub's refusals in its words, and an import through SkillFolder, against
# the protocol/Core objects the harness built.
# Usage: test-github-skills.sh <ApelinKit modules directory>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
modules="$1"
work="$(mktemp -d -t apelin-github-skills)"
trap 'rm -rf -- "${work:?}"' EXIT
objects=()
for module in ApelinCore ApelinProtocol; do
    if [[ -f "$modules/$module.o" ]]; then
        objects+=("$modules/$module.o")
    else
        while IFS= read -r object; do objects+=("$object"); done < <(find "$modules/.." "$modules" -maxdepth 2 -path "*/$module.build/*.o" | sort -u)
    fi
done
[[ ${#objects[@]} -ge 2 ]] || { echo "error: GitHub skills tests need the harness modules" >&2; exit 1; }
xcrun --sdk macosx swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -I "$root/Shared/XPCShim" -I "$modules" "${objects[@]}" \
    "$root/Apelin/Interface/Settings/Skills/GitHub/GitHubSkillLink.swift" \
    "$root/Apelin/Interface/Settings/Skills/GitHub/GitHubSkillCandidate.swift" \
    "$root/Apelin/Interface/Settings/Skills/GitHub/GitHubSkillScanner.swift" \
    "$root/Tests/GitHubSkills/main.swift" -o "$work/github-skills"
"$work/github-skills"
