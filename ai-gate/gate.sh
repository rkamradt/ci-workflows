#!/usr/bin/env bash
# ai-gate/gate.sh — security + AI code gate
#
# Required env:
#   ANTHROPIC_API_KEY   — Claude API key
#   GH_TOKEN            — GitHub token (needs issues: write for issue creation)
#   GITHUB_SHA          — current commit SHA
#   GITHUB_REPOSITORY   — owner/repo
#   GITHUB_EVENT_BEFORE — SHA before the push (may be 0000... for new branches)
#   GATE_DIR            — path to the ai-gate/ directory in the ci-workflows checkout
#
# Optional env:
#   GATE_DIFF_FILE      — override diff computation (used in tests)

set -euo pipefail

RULES="$GATE_DIR/rules.md"

log()  { echo "[ai-gate] $*" >&2; }
warn() { echo "::warning title=AI Gate::$*"; }
err()  { echo "::error title=AI Gate::$*"; }

# ── 1. Compute diff ────────────────────────────────────────────────────────────
if [[ -n "${GATE_DIFF_FILE:-}" ]]; then
  log "Using override diff: $GATE_DIFF_FILE"
  DIFF=$(<"$GATE_DIFF_FILE")
  BASE="fixture"
  HEAD="${GITHUB_SHA:-HEAD}"
else
  HEAD="${GITHUB_SHA:-HEAD}"
  BASE="${GITHUB_EVENT_BEFORE:-}"
  if [[ -z "$BASE" || "$BASE" == "0000000000000000000000000000000000000000" ]]; then
    BASE=$(git log --format='%H' -2 | tail -1 2>/dev/null \
           || git rev-list --max-parents=0 HEAD)
  fi
  log "Diffing $BASE..$HEAD"
  DIFF=$(git diff "$BASE" "$HEAD" 2>&1) || { warn "git diff failed; passing."; exit 0; }
fi

if [[ -z "$DIFF" ]]; then
  log "Empty diff; passing."
  exit 0
fi

DIFF_FILE=$(mktemp)
echo "$DIFF" > "$DIFF_FILE"
trap 'rm -f "$DIFF_FILE"' EXIT

# ── 2. AI-Gate-Override commit trailer ────────────────────────────────────────
if [[ "${GATE_DIFF_FILE:-}" == "" ]]; then
  OVERRIDE=$(git log -1 --format='%(trailers:key=AI-Gate-Override,valueonly)' \
             "$HEAD" 2>/dev/null || true)
  if [[ -n "$OVERRIDE" ]]; then
    warn "AI-Gate-Override applied: $OVERRIDE"
    log "Override accepted; skipping gate checks."
    exit 0
  fi
fi

# ── 3. gitleaks ───────────────────────────────────────────────────────────────
log "Running gitleaks..."
GITLEAKS_JSON=""
GITLEAKS_EXIT=0

if [[ -n "${GATE_DIFF_FILE:-}" ]]; then
  # Test mode: scan the fixture file directly
  gitleaks detect --no-git --source "$(dirname "$GATE_DIFF_FILE")" \
    --report-format json --report-path /tmp/gitleaks.json \
    --exit-code 1 --redact 2>/dev/null || GITLEAKS_EXIT=$?
else
  gitleaks detect --log-opts="${BASE}..${HEAD}" \
    --report-format json --report-path /tmp/gitleaks.json \
    --exit-code 1 --redact 2>/dev/null || GITLEAKS_EXIT=$?
fi

if [[ "$GITLEAKS_EXIT" -ne 0 && -s /tmp/gitleaks.json ]]; then
  GITLEAKS_JSON=$(cat /tmp/gitleaks.json)
  log "gitleaks: secret(s) detected"
fi

# ── 4. kube-linter (K8s YAML only) ────────────────────────────────────────────
log "Checking for changed K8s YAML files..."
KUBELINT_JSON=""

if [[ -z "${GATE_DIFF_FILE:-}" ]]; then
  CHANGED_YAMLS=$(git diff --name-only "$BASE" "$HEAD" | grep -E '\.(yaml|yml)$' || true)
  K8S_FILES=""
  for f in $CHANGED_YAMLS; do
    [[ -f "$f" ]] && grep -q '^apiVersion:' "$f" 2>/dev/null && K8S_FILES+=" $f"
  done
  if [[ -n "$K8S_FILES" ]]; then
    log "Running kube-linter on:$K8S_FILES"
    KUBE_EXIT=0
    if ! command -v kube-linter &>/dev/null; then
      log "kube-linter not installed; skipping."
      K8S_FILES=""
    fi
    # shellcheck disable=SC2086
    [[ -n "$K8S_FILES" ]] && kube-linter lint $K8S_FILES --format json > /tmp/kubelint.json 2>&1 || KUBE_EXIT=$?
    if [[ "$KUBE_EXIT" -ne 0 && -s /tmp/kubelint.json ]]; then
      KUBELINT_JSON=$(cat /tmp/kubelint.json)
      log "kube-linter: issue(s) found"
    fi
  else
    log "No K8s YAML in diff; skipping kube-linter."
  fi
fi

# ── 5. Claude Code gate ────────────────────────────────────────────────────────
log "Running Claude AI gate..."
CLAUDE_BLOCK=false
CLAUDE_FINDINGS="[]"
GATE_JSON='{"block":false,"findings":[]}'

PROMPT_FILE=$(mktemp)
{ cat "$RULES"; printf '\n\n## Diff\n\n```diff\n'; cat "$DIFF_FILE"; printf '\n```\n'; } \
  > "$PROMPT_FILE"

CLAUDE_EXIT=0
CLAUDE_RAW=$(timeout 180 claude -p "$(cat "$PROMPT_FILE")" \
  --output-format text --no-update-check 2>&1) || CLAUDE_EXIT=$?
rm -f "$PROMPT_FILE"

if [[ "$CLAUDE_EXIT" -eq 124 ]]; then
  warn "Claude timed out (180 s); passing with advisory warning."
elif [[ "$CLAUDE_EXIT" -ne 0 ]]; then
  warn "Claude exited $CLAUDE_EXIT; passing with advisory warning. Output: ${CLAUDE_RAW:0:200}"
else
  # Extract JSON from Claude's text response
  GATE_JSON=$(python3 - <<'PY' "$CLAUDE_RAW"
import json, re, sys
text = sys.argv[1]
# Strip markdown fences if present
text = re.sub(r'^```[a-z]*\n?', '', text.strip(), flags=re.MULTILINE)
text = re.sub(r'\n?```$', '', text.strip(), flags=re.MULTILINE)
# Try full text as JSON first
for candidate in [text.strip()] + re.findall(r'\{[^{}]*"block"[^{}]*\}', text, re.DOTALL):
    try:
        obj = json.loads(candidate)
        if 'block' in obj:
            print(json.dumps(obj))
            sys.exit(0)
    except Exception:
        pass
print('{"block":false,"findings":[]}')
PY
) || GATE_JSON='{"block":false,"findings":[]}'

  CLAUDE_BLOCK=$(python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(str(d.get('block',False)).lower())" \
    <<< "$GATE_JSON" 2>/dev/null || echo "false")
  CLAUDE_FINDINGS=$(python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('findings',[])))" \
    <<< "$GATE_JSON" 2>/dev/null || echo "[]")
  log "Claude result: block=$CLAUDE_BLOCK"
fi

# ── 6. Verify each Claude finding has file+line evidence in the diff ──────────
if [[ "$CLAUDE_BLOCK" == "true" ]]; then
  VERIFIED=$(python3 - <<'PY' "$DIFF" "$CLAUDE_FINDINGS"
import json, re, sys

diff_text  = sys.argv[1]
findings   = json.loads(sys.argv[2])

# Build set of (file, line_number) from diff additions
additions = {}   # file -> set of line numbers
cur_file, line_num = None, 0

for line in diff_text.splitlines():
    if line.startswith('+++ b/'):
        cur_file  = line[6:]
        line_num  = 0
        additions.setdefault(cur_file, set())
    elif line.startswith('@@'):
        m = re.search(r'\+(\d+)', line)
        if m:
            line_num = int(m.group(1)) - 1
    elif line.startswith('+') and not line.startswith('+++'):
        line_num += 1
        if cur_file:
            additions[cur_file].add(line_num)
    elif not line.startswith('-') and not line.startswith('\\'):
        if cur_file:
            line_num += 1

for f in findings:
    fname = f.get('file', '')
    fline = int(f.get('line', 0))
    evidence = f.get('evidence', '')
    if not fname or not fline:
        continue
    # Match by basename or full path, with ±2 line tolerance
    for afile, alines in additions.items():
        if fname in afile or afile.endswith(fname):
            if any(abs(al - fline) <= 2 for al in alines):
                print("true"); sys.exit(0)
    # Also match by evidence string appearing on an added line
    if evidence:
        snip = evidence[:30]
        for line in diff_text.splitlines():
            if line.startswith('+') and snip in line:
                print("true"); sys.exit(0)

print("false")
PY
) || VERIFIED="true"

  if [[ "$VERIFIED" == "false" ]]; then
    log "Claude flagged issues not traceable to diff additions; treating as advisory."
    CLAUDE_BLOCK=false
  fi
fi

# ── 7. Final verdict ───────────────────────────────────────────────────────────
BLOCK=false
[[ "$CLAUDE_BLOCK"  == "true" ]] && BLOCK=true
[[ -n "$GITLEAKS_JSON" ]]        && BLOCK=true
[[ -n "$KUBELINT_JSON" ]]        && BLOCK=true

if [[ "$BLOCK" == "false" ]]; then
  log "AI gate passed."
  exit 0
fi

# ── 8. Open GitHub issue and fail ─────────────────────────────────────────────
err "AI gate blocked commit ${HEAD:0:7}."

BODY="## 🔒 AI Gate blocked \`${HEAD:0:7}\`
"

if [[ "$CLAUDE_BLOCK" == "true" ]]; then
  BODY+="
### Claude findings
\`\`\`json
$GATE_JSON
\`\`\`
"
fi

if [[ -n "$GITLEAKS_JSON" ]]; then
  BODY+="
### Secrets detected (gitleaks)
\`\`\`json
$GITLEAKS_JSON
\`\`\`
"
fi

if [[ -n "$KUBELINT_JSON" ]]; then
  BODY+="
### Kubernetes lint issues (kube-linter)
\`\`\`json
$KUBELINT_JSON
\`\`\`
"
fi

BODY+="
### How to resolve
1. Fix the findings above and push a new commit.
2. **To override with justification**, add this trailer to your commit message:
   \`\`\`
   AI-Gate-Override: <reason>
   \`\`\`

---
_Diff base: \`${BASE:0:7}\` → \`${HEAD:0:7}\`_"

gh issue create \
  --repo "$GITHUB_REPOSITORY" \
  --title "🔒 AI Gate blocked: ${HEAD:0:7}" \
  --body "$BODY" \
  2>/dev/null \
  || warn "Issue creation failed — ensure issues: write is in the calling workflow's permissions block."

exit 1
