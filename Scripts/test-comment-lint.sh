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
cat > quotes.sh <<'BASH'
message='first
# literal single-quoted text
last'
message="first\"
# literal double-quoted text
last"
BASH
cat > heredocs.sh <<'BASH'
cat <<EOF-JSON
# literal data
EOF-JSON
cat <<E"OF".J\ SON
# literal data
EOF.J SON
cat <<-TAB.JSON
	# literal tab-indented data
	TAB.JSON
BASH
cat > quotes.yml <<'YAML'
single: 'first''s
  # literal single-quoted text
  last'
double: "first\"
  # literal double-quoted text
  last"
plain: team's value
YAML
cat > properties.yml <<'YAML'
anchored: &shared "literal # hash"
tagged: !!str 'literal # hash'
both: !<tag:yaml.org,2002:str> &other "literal # hash"
YAML
cat > backticks.sh <<'BASH'
echo "`printf '%s' '# literal'`"
echo "literal \` tick # quoted"
echo "`printf '%s' '\`'`"
BASH

for script in build.sh quotes.sh heredocs.sh backticks.sh; do /bin/bash -n "$script"; done

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
printf '(( size = (base << shift) ))\necho "# literal" # Shell comment\n' >> build.sh
printf 'size=$(( (base << shift) )) # Shell comment\n' >> build.sh
cat >> build.sh <<'BASH'
echo "$(printf '%s' '"')" # Shell comment after command substitution
BASH
printf '# Shell comment after heredoc\n' >> heredocs.sh
cat >> quotes.sh <<'BASH'
message='first
# literal text
last' # Shell comment after quote
BASH
cat >> quotes.yml <<'YAML'
more: 'first
  # literal text
  last' # YAML comment after quote
plain_with_comment: team's value # YAML comment after plain scalar
YAML
cat >> properties.yml <<'YAML'
with_anchor: &more "literal # hash" # YAML comment after anchored value
with_tag: !!str 'literal # hash' # YAML comment after tagged value
YAML
cat >> backticks.sh <<'BASH'
echo "`printf '%s' '"'`" # Shell comment after backticks
# Shell comment after backtick line
echo "`printf '%s' '\`'`" # Shell comment after escaped backtick
echo "`printf '%s' '"'
# Shell comment inside backticks
`" # Shell comment after multiline substitution
BASH
/bin/bash -n backticks.sh
printf 'key: "# literal" # YAML comment\n' >> .github/workflows/workflow.yml
cat >> .github/workflows/workflow.yml <<'YAML'
with-script:
  run: |
    # Workflow shell comment
    message="first
    # literal text
    last" # Workflow shell comment after quote
YAML
cat > .github/workflows/variants.yml <<'YAML'
jobs:
  job:
    steps:
      - "run": |
          echo "`printf '%s' '"'`" # Workflow shell comment after backticks
      - 'run': |
          # Workflow shell comment in single-quoted run
      - run : |
          # Workflow shell comment in spaced run
YAML
printf '<!-- XML comment -->\n' >> icon.svg
if Scripts/check-comments.sh --base HEAD > "$temp/result"; then
    echo 'Expected new comments to fail lint' >&2
    exit 1
fi
for location in legacy.swift:2:1 legacy.swift:3:14 legacy.swift:3:40 legacy.swift:4:1 \
    build.sh:7:18 build.sh:8:29 build.sh:9:27 heredocs.sh:10:1 quotes.sh:9:7 quotes.yml:10:9 quotes.yml:11:34 \
    properties.yml:4:37 properties.yml:5:34 backticks.sh:4:26 backticks.sh:5:1 backticks.sh:6:27 \
    backticks.sh:8:1 backticks.sh:9:4 .github/workflows/variants.yml:5:36 \
    .github/workflows/variants.yml:7:11 .github/workflows/variants.yml:9:11 \
    .github/workflows/workflow.yml:13:18 .github/workflows/workflow.yml:16:5 \
    .github/workflows/workflow.yml:19:11 icon.svg:2:1; do
    if ! grep -Fq "$location:" "$temp/result"; then
        printf 'Expected a diagnostic at %s\n' "$location" >&2
        cat "$temp/result" >&2
        exit 1
    fi
done
test "$(wc -l < "$temp/result")" -eq 25

git restore legacy.swift build.sh heredocs.sh quotes.sh quotes.yml properties.yml backticks.sh .github/workflows/workflow.yml icon.svg
rm .github/workflows/variants.yml
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

printf 'cat <<MISSING\n# skipped by an unfinished heredoc\n' > unfinished.sh
if Scripts/check-comments.sh --base HEAD > "$temp/result" 2>&1; then
    echo 'Expected an unfinished heredoc to fail lint' >&2
    exit 1
fi
grep -Fq 'unfinished.sh: could not find the end of heredoc "MISSING"' "$temp/result"
