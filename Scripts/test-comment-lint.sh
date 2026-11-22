#!/usr/bin/env bash
set -euo pipefail
scripts="$(cd "$(dirname "$0")" && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
cd "$temp"
git init -q
mkdir -p Scripts .github/workflows
cp "$scripts"/{CommentLint.swift,check-comments.sh} Scripts/

cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.2
let string = #"https://example.com /* text */"#
let pattern = #/https?://[a-z]+/#
let multiline = """
// text in a string
"""
SWIFT
cat > build.sh <<'BASH'
#!/usr/bin/env bash
printf '%s\n' '# quoted text' "${value#prefix}" foo#bar
cat <<'DATA'
# literal heredoc data
DATA
BASH
cat > .github/workflows/workflow.yml <<'YAML'
jobs:
  job:
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000 # v7.0.1
      - run: |4-
            echo '# quoted text'
            cat <<'DATA'
            # literal heredoc data
            DATA
        name: '# quoted name'
data: |
  # literal block scalar data
YAML
cat > icon.svg <<'SVG'
<svg><text><![CDATA[<!-- literal -->]]></text></svg>
SVG

printf '// grandfathered\n' > legacy.swift
printf '{"legacy.swift":{"// grandfathered":1}}\n' > .comment-baseline.json
git add .
git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -qm baseline
Scripts/check-comments.sh --base HEAD

cat >> legacy.swift <<'SWIFT'
/// New documentation
let number = /* outer /* inner */ */ 1 // Inline note
// End-of-file note
SWIFT
printf '(( size = base << shift ))\necho "# literal" # Shell comment\n' >> build.sh
printf 'key: "# literal" # YAML comment\n' >> .github/workflows/workflow.yml
printf 'with-script:\n  run: |\n    # Workflow shell comment\n' >> .github/workflows/workflow.yml
printf '<!-- XML comment -->\n' >> icon.svg
if Scripts/check-comments.sh --base HEAD > "$temp/result"; then
    echo 'Expected new comments to fail lint' >&2
    exit 1
fi
for location in legacy.swift:2:1 legacy.swift:3:14 legacy.swift:3:40 legacy.swift:4:1 \
    build.sh:7:18 .github/workflows/workflow.yml:13:18 .github/workflows/workflow.yml:16:5 icon.svg:2:1; do
    if ! grep -Fq "$location:" "$temp/result"; then
        printf 'Expected a diagnostic at %s\n' "$location" >&2
        cat "$temp/result" >&2
        exit 1
    fi
done
test "$(wc -l < "$temp/result")" -eq 8

git restore legacy.swift build.sh .github/workflows/workflow.yml icon.svg
printf '// grandfathered\n' >> legacy.swift
if Scripts/check-comments.sh --base HEAD > "$temp/result"; then
    echo 'Expected a duplicate grandfathered comment to fail lint' >&2
    exit 1
fi
grep -Fq 'legacy.swift:2:1: new comment' "$temp/result"

printf '{"legacy.swift":{"// grandfathered":2}}\n' > .comment-baseline.json
if Scripts/check-comments.sh --base HEAD > "$temp/result"; then
    echo 'Expected baseline growth to fail lint' >&2
    exit 1
fi
grep -Fq 'comment baseline grew' "$temp/result"

git restore .comment-baseline.json
rm legacy.swift
if Scripts/check-comments.sh --base HEAD > "$temp/result"; then
    echo 'Expected a stale baseline entry to fail lint' >&2
    exit 1
fi
grep -Fq 'stale baseline entry' "$temp/result"
printf '{}\n' > .comment-baseline.json
Scripts/check-comments.sh --base HEAD
