#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
source ./cov-analysis
set +e

TMP=$(mktmp)
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"

for cmd in timeout realpath mv; do
  real=$(command -v "$cmd")
  printf '#!/bin/bash\nif test "${1-}" = --version; then printf "%%s (uutils coreutils) 0.8.0\\n" "%s"; exit 0; fi\nexec "%s" "$@"\n' \
    "$cmd" "$real" > "$TOOLS/$cmd"
  chmod +x "$TOOLS/$cmd"
done

PATH="$TOOLS:$PATH"
for cmd in timeout realpath mv; do
  require_coreutils_command "$cmd" "cov-analysis test" \
    || die "uutils $cmd was rejected"
done

run_with_timeout 1 /bin/true || die "uutils timeout wrapper failed"
assert_eq "$(realpath -m -- "$TMP/missing/../report")" "$TMP/report" \
  "uutils realpath -m"

BAD="$TMP/bad"
mkdir "$BAD"
printf '#!/bin/bash\nprintf "timeout version BSD\\n"\n' > "$BAD/timeout"
chmod +x "$BAD/timeout"
if PATH="$BAD:$PATH" require_coreutils_command timeout "cov-analysis test" \
  2> "$TMP/bad.err"; then
  die "unsupported timeout implementation was accepted"
fi
grep -q 'GNU coreutils or uutils coreutils' "$TMP/bad.err" \
  || die "unsupported timeout error is not actionable"

echo "[PASS] test_uutils_coreutils"
