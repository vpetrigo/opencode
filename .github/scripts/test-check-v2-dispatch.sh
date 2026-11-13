#!/usr/bin/env bash
set -euo pipefail

workflow="$(dirname "$0")/../workflows/check-upstream-release.yml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python - "$workflow" "$tmp/check-v2.sh" <<'PY'
from pathlib import Path
import re
import sys

workflow = Path(sys.argv[1]).read_text()
run = re.search(r"(?m)^        run: \|\n((?:          .*\n|\s*\n)+)", workflow[workflow.index("  check-v2:"):])
assert run, "could not extract check-v2 run block"
Path(sys.argv[2]).write_text("\n".join(line[10:] if line.startswith("          ") else "" for line in run.group(1).splitlines()) + "\n")
PY

mkdir "$tmp/bin"
cat > "$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
printf 'abc refs/tags/v2.2.7\n'
SH
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'repos/test/releases?per_page=100'*)
    [[ "$MODE" != api_error ]] || { echo 'HTTP 500' >&2; exit 1; }
    case "$MODE" in
      matching) printf '[[{"tag_name":"v2-pagination-v2.2.7-deadbeef","draft":false,"prerelease":true,"assets":%s}]]\n' "$ASSETS" ;;
      incomplete) printf '[[{"tag_name":"v2-pagination-v2.2.7-deadbeef","draft":false,"prerelease":true,"assets":[]}]]\n' ;;
      unrelated) printf '[[{"tag_name":"v2-pagination-v2.2.70-deadbeef","draft":false,"prerelease":true,"assets":%s}]]\n' "$ASSETS" ;;
      invalid_suffix) printf '[[{"tag_name":"v2-pagination-v2.2.7-foo-deadbeef","draft":false,"prerelease":true,"assets":%s}]]\n' "$ASSETS" ;;
      *) printf '[[]]\n' ;;
    esac ;;
  *'matching-refs/tags/v2-pagination-v2.2.7-'*)
    [[ "$MODE" != refs_error ]] || { echo 'HTTP 500' >&2; exit 1; }
    if [[ "$MODE" == orphan ]]; then printf '[[{"ref":"refs/tags/v2-pagination-v2.2.7-deadbeef"}]]\n'; else printf '[[]]\n'; fi ;;
  *'workflow run'*) echo dispatch >> "$DISPATCH_LOG" ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/"*

assets='[{"name":"opencode-v2-linux-x64.zip"},{"name":"opencode-v2-linux-x64.sha256"},{"name":"opencode-v2-linux-x64.build-info.md"},{"name":"opencode-v2-windows-x64.zip"},{"name":"opencode-v2-windows-x64.sha256"},{"name":"opencode-v2-windows-x64.build-info.md"},{"name":"prepared-v2.bundle"}]'
run_case() {
  local mode=$1 expected=$2 status=0
  : > "$tmp/dispatch.log"
  ASSETS="$assets" MODE="$mode" DISPATCH_LOG="$tmp/dispatch.log" PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=test GITHUB_REF_NAME=verification bash "$tmp/check-v2.sh" >"$tmp/out" 2>&1 || status=$?
  if [[ $expected == dispatch ]]; then
    [[ $status == 0 && -s "$tmp/dispatch.log" ]] || { cat "$tmp/out"; return 1; }
  elif [[ $expected == skip ]]; then
    [[ $status == 0 && ! -s "$tmp/dispatch.log" ]] || { cat "$tmp/out"; return 1; }
  else
    [[ $status != 0 && ! -s "$tmp/dispatch.log" ]] || { cat "$tmp/out"; return 1; }
  fi
}

run_case matching skip
run_case unrelated dispatch
run_case missing dispatch
run_case api_error fail
run_case invalid_suffix dispatch
run_case incomplete fail
run_case orphan fail
run_case refs_error fail
echo 'check-v2 dispatch regression checks passed'
