#!/usr/bin/env bash
# Stubbed-gh tests for the merge-when-green race handling:
#   1. "Base branch was modified" -> update-branch (merge-style, never rebase) + exit 0
#   2. post-merge --delete-branch 404 "Reference does not exist" when the PR is merged -> exit 0
#   3. genuine merge failure -> nonzero
#
# Extracts the wrapper between the gate-merge-retry markers in the workflow file
# and runs it against a stub gh on PATH. No network, no real gh calls.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="${1:-}"
if [[ -z "$WF" ]]; then
  for cand in \
    "$ROOT/.github/workflows/merge-when-green.yaml" \
    "$ROOT/.github/workflows/merge-when-green.yml"
  do
    if [[ -f "$cand" ]]; then WF=$cand; break; fi
  done
fi
if [[ -z "${WF}" || ! -f "$WF" ]]; then
  echo "usage: $0 [path-to-merge-when-green.yaml]" >&2
  exit 2
fi

BEGIN='# --- gate-merge-retry begin ---'
END='# --- gate-merge-retry end ---'
if ! grep -qF "$BEGIN" "$WF" || ! grep -qF "$END" "$WF"; then
  echo "error: $WF is missing the gate-merge-retry markers" >&2
  exit 2
fi

# Strip the common leading indent from the extracted YAML script block.
WRAPPER=$(python3 - "$WF" << 'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
begin = "# --- gate-merge-retry begin ---"
end = "# --- gate-merge-retry end ---"
s = text.index(begin)
e = text.index(end) + len(end)
block = text[s:e]
lines = block.splitlines()
inds = [len(l) - len(l.lstrip(" ")) for l in lines if l.strip()]
base = min(inds) if inds else 0
print("\n".join(l[base:] if len(l) >= base else l for l in lines))
PY
)

fail_count=0
pass_count=0
report() {
  local name="$1" rc="$2" expect="$3" log="$4"
  if [[ "$expect" == 0 ]]; then
    if [[ "$rc" -eq 0 ]]; then
      echo "PASS  $name (exit $rc)"
      pass_count=$((pass_count + 1))
    else
      echo "FAIL  $name: expected exit 0, got $rc"
      echo "---- log ----"; cat "$log"; echo "--------------"
      fail_count=$((fail_count + 1))
    fi
  else
    if [[ "$rc" -ne 0 ]]; then
      echo "PASS  $name (exit $rc)"
      pass_count=$((pass_count + 1))
    else
      echo "FAIL  $name: expected nonzero, got 0"
      echo "---- log ----"; cat "$log"; echo "--------------"
      fail_count=$((fail_count + 1))
    fi
  fi
}

run_case() {
  local mode="$1"
  local work
  work=$(mktemp -d)
  mkdir -p "$work/bin"
  local log="$work/gh.log"
  : > "$log"
  cat > "$work/bin/gh" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "${GH_LOG}"
if [[ "$*" == *rebase* ]]; then
  echo "stub-gh: rebase is forbidden" >&2
  exit 99
fi
if [[ "$*" == *"pr merge"* ]]; then
  case "${STUB_MODE}" in
    base-modified)
      echo "GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)" >&2
      exit 1
      ;;
    delete-404)
      echo "GraphQL: Reference does not exist (deleteRef)" >&2
      exit 1
      ;;
    merge-fail)
      echo "GraphQL: Pull Request is not mergeable (mergePullRequest)" >&2
      exit 1
      ;;
    ok)
      echo "ok merged"
      exit 0
      ;;
    *)
      echo "stub-gh: unknown STUB_MODE=${STUB_MODE}" >&2
      exit 99
      ;;
  esac
fi
if [[ "$*" == *update-branch* ]]; then
  echo "ok updated"
  echo "UPDATE_BRANCH" >> "${GH_LOG}.events"
  exit 0
fi
if [[ "$*" == *"pr view"* ]]; then
  if [[ "${STUB_MODE}" == delete-404 ]]; then
    echo "2026-11-18T18:00:00Z"
  else
    echo ""
  fi
  exit 0
fi
echo "stub-gh: unexpected invocation: $*" >&2
exit 99
STUB
  chmod +x "$work/bin/gh"

  local body="$work/pr-body"
  printf 'body\n' > "$body"
  local gout="$work/github-output"
  : > "$gout"

  local rc=0
  set +e
  (
    set -euo pipefail
    export PATH="$work/bin:$PATH"
    export GH_LOG="$log"
    export STUB_MODE="$mode"
    export GH_TOKEN="github-token"
    export GATE_TOKEN="gate-token"
    export UPDATE_TOKEN=""
    export GH_REPO="example/repo"
    export PR="162"
    export PR_NUMBER="162"
    export SHA="abc123def"
    export HEAD_SHA="abc123def"
    export TITLE="Test PR"
    export LABEL="ready-to-merge"
    export BASE="main"
    export PR_BODY="closes nothing"
    export BODY_FILE="$body"
    export GITHUB_OUTPUT="$gout"
    note() { echo "::notice::$*"; }
    fail_unknown() { echo "fail_unknown: $*"; exit 2; }
    judge_one() {
      eval "$WRAPPER"
    }
    judge_one
  ) >"$work/out" 2>"$work/err"
  rc=$?
  set -e
  cat "$work/out" "$work/err" >> "$log"
  # return paths via globals
  LAST_RC=$rc
  LAST_LOG=$log
  LAST_WORK=$work
}

# 1. base-modified -> update + exit 0
run_case base-modified
if grep -q rebase "$LAST_LOG"; then
  echo "FAIL  base-modified: update used rebase"
  cat "$LAST_LOG"
  fail_count=$((fail_count + 1))
elif ! grep -q update-branch "$LAST_LOG"; then
  echo "FAIL  base-modified: update-branch was not invoked"
  cat "$LAST_LOG"
  fail_count=$((fail_count + 1))
else
  report base-modified "$LAST_RC" 0 "$LAST_LOG"
fi

# 2. delete-branch 404 after merge -> exit 0, must not update-branch
run_case delete-404
if grep -q UPDATE_BRANCH "$LAST_LOG.events" 2>/dev/null; then
  echo "FAIL  delete-404: update-branch should not run after a successful merge"
  cat "$LAST_LOG"
  fail_count=$((fail_count + 1))
else
  report delete-404 "$LAST_RC" 0 "$LAST_LOG"
fi

# 3. genuine merge failure -> nonzero, must not treat as success
run_case merge-fail
if grep -q UPDATE_BRANCH "$LAST_LOG.events" 2>/dev/null; then
  echo "FAIL  merge-fail: update-branch should not run on a genuine merge failure"
  cat "$LAST_LOG"
  fail_count=$((fail_count + 1))
else
  report merge-fail "$LAST_RC" 1 "$LAST_LOG"
fi

echo "Ran $((pass_count + fail_count)) cases on $WF ($pass_count passed, $fail_count failed)"
if [[ "$fail_count" -ne 0 ]]; then
  exit 1
fi
