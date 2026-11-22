#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
host_libs="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host"
xcrun swiftc -I "$host_libs" -L "$host_libs" -Xlinker -rpath -Xlinker "$host_libs" \
    Scripts/CommentLint.swift -o "$temp/comment-lint"

if [[ "${1:-}" == --base && "$#" == 2 ]]; then
    base="$(git rev-parse --verify "$2^{commit}")"
    if [[ -n "$(git ls-tree "$base" -- .comment-baseline.json)" ]]; then
        git show "$base:.comment-baseline.json" > "$temp/base.json"
    else
        printf '{}\n' > "$temp/base.json"
    fi
    set -- --base "$temp/base.json"
fi

git ls-files --cached --others --exclude-standard --deduplicate -z | "$temp/comment-lint" "$@"
