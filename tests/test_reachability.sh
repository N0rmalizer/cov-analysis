#!/bin/bash
# Verify reachability-aware annotation of llvm-cov's own reports: cross coverage
# with the fuzz-reachability tool's output and, in place,
#   - tint each function's lines in the HTML file view (dark grey = unreachable,
#     amber = reachable but not reached, purple = covered-yet-unreachable),
#   - mark the text source view with a per-line U/R/A column,
#   - append a reachability tally + actionable list to summary.txt.
#
# Primary assertions run against synthetic llvm-cov-shaped fixtures (toolchain
# free). A clang-gated section then repeats end-to-end against real `llvm-cov
# show` output to guard against format drift.
set -uo pipefail

cd "$(dirname "$0")/.."
source tests/lib.sh
COV="$(pwd)/cov-analysis"

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not available"; exit 0; }

source ./cov-analysis

trap 'rm -rf "$TMP"' EXIT
TMP=$(mktmp)

# 4 functions at known line ranges (3 lines each, blank line between).
SRC=(
"int covered_fn(int x) {"        # L1  covered, reachable
"  return x + 1;"                # L2
"}"                              # L3
""                               # L4
"int reachable_unreached(int x) {"  # L5 uncovered, reachable (indirect_only)
"  return x - 1;"                # L6
"}"                              # L7
""                               # L8
"int dead_fn(int x) {"           # L9  uncovered, unreachable
"  return x * 2;"                # L10
"}"                              # L11
""                               # L12
"int anomaly_fn(int x) {"        # L13 covered yet unreachable (anomaly)
"  return x / 2;"                # L14
"}"                              # L15
)

# ── coverage.json (llvm-cov export shape) ────────────────────────────────────
cat > "$TMP/coverage.json" << EOF
{ "data": [ { "files": [ { "filename": "$TMP/foo.c", "segments": [], "summary": {} } ],
  "functions": [
    { "name": "covered_fn",          "count": 5, "filenames": ["$TMP/foo.c"], "regions": [[1,1,3,2,5,0,0,0]] },
    { "name": "reachable_unreached", "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[5,1,7,2,0,0,0,0]] },
    { "name": "dead_fn",             "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[9,1,11,2,0,0,0,0]] },
    { "name": "anomaly_fn",          "count": 3, "filenames": ["$TMP/foo.c"], "regions": [[13,1,15,2,3,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF

# ── reachability JSON: reachable (one indirect-only) + unreachable_defined ────
cat > "$TMP/reach.json" << 'EOF'
{ "reachable": [
    { "mangled": "covered_fn",          "file": "foo.c", "line": 1, "indirect_only": false },
    { "mangled": "reachable_unreached", "file": "foo.c", "line": 5, "indirect_only": true } ],
  "unreachable_defined": [
    { "mangled": "dead_fn",    "file": "foo.c", "line": 9 },
    { "mangled": "anomaly_fn", "file": "foo.c", "line": 13 } ] }
EOF

# ── synthetic llvm-cov HTML output (index + per-file + style.css) ─────────────
mkdir -p "$TMP/html/coverage" "$TMP/text/coverage"
printf "/* base */\n" > "$TMP/html/style.css"
# Flat index.html (as llvm-cov emits without -show-directory-coverage): a file
# row + Totals row, columns Function/Line/Region/Branch. Original numbers here
# are placeholders the annotator must overwrite with reachable-only figures.
{
  printf "%s" "<!doctype html><html><head></head><body><h2>Coverage Report</h2><div class='centered'><table>"
  printf "%s" "<tr><td class='column-entry-bold'>Filename</td><td class='column-entry-bold'>Function Coverage</td><td class='column-entry-bold'>Line Coverage</td><td class='column-entry-bold'>Region Coverage</td><td class='column-entry-bold'>Branch Coverage</td></tr>"
  printf "%s" "<tr class='light-row'><td><pre><a href='coverage${TMP}/foo.c.html'>${TMP}/foo.c</a></pre></td><td class='column-entry-red'><pre>  50.00% (2/4)</pre></td><td class='column-entry-red'><pre>  50.00% (6/12)</pre></td><td class='column-entry-red'><pre>  43.75% (7/16)</pre></td><td class='column-entry-gray'><pre>- (0/0)</pre></td></tr>"
  printf "%s" "<tr class='light-row-bold'><td><pre>Totals</pre></td><td class='column-entry-red'><pre>  50.00% (2/4)</pre></td><td class='column-entry-red'><pre>  50.00% (6/12)</pre></td><td class='column-entry-red'><pre>  43.75% (7/16)</pre></td><td class='column-entry-gray'><pre>- (0/0)</pre></td></tr>"
  printf "%s\n" "</table></div></body></html>"
} > "$TMP/html/index.html"

HFILE="$TMP/html/coverage/foo.c.html"
{
  printf "%s" "<!doctype html><html><head><link rel='stylesheet' type='text/css' href='../../style.css'></head><body><h2>Coverage Report</h2><div class='centered'><table><div class='source-name-title'><pre>$TMP/foo.c</pre></div>"
  printf "\n<tr><td><pre>Line</pre></td><td><pre>Count</pre></td><td><pre>Source</pre></td></tr>"
  for i in "${!SRC[@]}"; do
    ln=$((i + 1))
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='covered-line'><pre>1</pre></td><td class='code'><pre>%s</pre></td></tr>" "$ln" "$ln" "$ln" "${SRC[$i]}"
  done
  printf "\n</table></div></body></html>\n"
} > "$HFILE"

# ── synthetic llvm-cov text output ───────────────────────────────────────────
TFILE="$TMP/text/coverage/foo.c.txt"
{
  printf "Coverage Report\n"
  printf "Created: 2026\n"
  printf "%s:\n" "$TMP/foo.c"
  for i in "${!SRC[@]}"; do
    ln=$((i + 1))
    printf "%5d|%7d|%s\n" "$ln" 1 "${SRC[$i]}"
  done
} > "$TFILE"

# ── summary.txt (as llvm-cov report would leave it) ──────────────────────────
printf "Filename  Regions  Missed  Cover\nTOTAL  10  4  60.00%%\n" > "$TMP/summary.txt"

# ── per-function metrics (as `llvm-cov report -show-functions` emits) ────────
# covered_fn (reachable, executed), reachable_unreached (reachable, 0),
# dead_fn (unreachable, 0), anomaly_fn (unreachable but executed). Excluding the
# two unreachable functions leaves: Functions 1/2, Lines 3/6, Regions 3/8,
# Branches 1/4.
cat > "$TMP/perfunc.txt" << EOF
File '$TMP/foo.c':
Name                 Regions  Miss  Cover    Lines  Miss  Cover    Branches  Miss  Cover
covered_fn               4     1   75.00%      3     0  100.00%        2     1   50.00%
reachable_unreached      4     4    0.00%      3     3    0.00%        2     2    0.00%
dead_fn                  4     4    0.00%      3     3    0.00%        2     2    0.00%
anomaly_fn               4     0  100.00%      3     0  100.00%        2     0  100.00%
TOTAL                   16     9   43.75%     12     6   50.00%        8     5   37.50%
EOF

# ── run the annotator (6th arg = per-function report → recompute numbers) ────
TALLY="$(annotate_reachability "$TMP/coverage.json" "$TMP/reach.json" \
  "$TMP/html" "$TMP/text" "$TMP/summary.txt" "$TMP/perfunc.txt")" \
  || die "annotate_reachability returned non-zero"

# HTML file view: unreachable grey, reachable-unreached (indirect) amber,
# anomaly purple, covered untouched.
grep -q "reach-grey'><td class='line-number'><a name='L9'" "$HFILE" \
  || die "html: dead_fn line should get class reach-grey"
grep -q "reach-amber-indirect'><td class='line-number'><a name='L5'" "$HFILE" \
  || die "html: reachable_unreached (indirect) line should get reach-amber-indirect"
grep -q "reach-anomaly'><td class='line-number'><a name='L13'" "$HFILE" \
  || die "html: anomaly_fn line should get reach-anomaly"
grep -q "<tr><td class='line-number'><a name='L1'" "$HFILE" \
  || die "html: covered_fn line must stay untouched (plain <tr>)"
echo "[PASS] html file-view tinting"

# CSS rules appended once to the shared stylesheet.
grep -q 'reach-grey' "$TMP/html/style.css" \
  || die "style.css should gain the reachability CSS rules"
echo "[PASS] style.css rules"

# index.html banner with the tally.
grep -qi 'reachab' "$TMP/html/index.html" \
  || die "index.html should gain a reachability banner"
grep -q 'not yet reached' "$TMP/html/index.html" \
  || die "index.html banner should report the not-yet-reached count"
echo "[PASS] index.html banner"

# Text source view: U/R/A marker column + legend, covered stays blank.
grep -Eq '^ *9\|[^|]*\|U ' "$TFILE"  || die "text: dead_fn line should be marked U"
grep -Eq '^ *5\|[^|]*\|R ' "$TFILE"  || die "text: reachable_unreached line should be marked R"
grep -Eq '^ *13\|[^|]*\|A ' "$TFILE" || die "text: anomaly_fn line should be marked A"
grep -Eq '^ *1\|[^|]*\|  int covered_fn' "$TFILE" || die "text: covered_fn line must stay unmarked"
grep -q 'U=unreachable' "$TFILE" || die "text: should carry a reachability legend"
echo "[PASS] text marker column"

# summary.txt block.
grep -q 'Reachable but NOT reached' "$TMP/summary.txt" || die "summary.txt should list actionable functions"
grep -q 'reachable_unreached' "$TMP/summary.txt"       || die "summary.txt should name the actionable function"
grep -qi 'unreachable functions' "$TMP/summary.txt"    || die "summary.txt should count unreachable functions"
echo "[PASS] summary.txt block"

# summary.txt: reachable-only coverage table, excluding the 2 unreachable funcs.
grep -qi 'Reachable-only coverage' "$TMP/summary.txt" || die "summary.txt should carry the reachable-only table"
grep -q '1/2' "$TMP/summary.txt"  || die "summary.txt: functions should be 1/2 (dead+anomaly excluded)"
grep -q '3/8' "$TMP/summary.txt"  || die "summary.txt: regions should be 3/8"
grep -q '3/6' "$TMP/summary.txt"  || die "summary.txt: lines should be 3/6"
grep -q '1/4' "$TMP/summary.txt"  || die "summary.txt: branches should be 1/4"
echo "[PASS] summary.txt reachable-only numbers"

# index.html: file + Totals cells patched to the reachable-only figures.
grep -q '(1/2)' "$TMP/html/index.html" || die "index.html: function cell should become (1/2)"
grep -q '(3/6)' "$TMP/html/index.html" || die "index.html: line cell should become (3/6)"
grep -q '(3/8)' "$TMP/html/index.html" || die "index.html: region cell should become (3/8)"
grep -q '(1/4)' "$TMP/html/index.html" || die "index.html: branch cell should become (1/4)"
grep -q '(2/4)' "$TMP/html/index.html" && die "index.html: stale original (2/4) must be overwritten"
echo "[PASS] index.html cells patched"

# Tally on stdout.
printf '%s\n' "$TALLY" | grep -q 'unreachable=2' || die "tally should report unreachable=2 (got: $TALLY)"
echo "[PASS] stdout tally"

# ── dir-mode (reached.txt / not_reached.txt) still classifies ────────────────
mkdir -p "$TMP/lists"
printf '# SanitizerCoverage allowlist\nsrc:*\nfun:covered_fn\nfun:reachable_unreached\n' > "$TMP/lists/reached.txt"
printf '# SanitizerCoverage ignorelist\nfun:dead_fn\nfun:anomaly_fn\n' > "$TMP/lists/not_reached.txt"
# fresh copies so the in-place edits start clean
rm -rf "$TMP/html2" "$TMP/text2"; cp -r "$TMP/html" "$TMP/html2"; cp -r "$TMP/text" "$TMP/text2"
# strip prior edits from the copies' source pages
printf "%s" "<!doctype html><html><head><link rel='stylesheet' type='text/css' href='../../style.css'></head><body><div class='centered'><table><div class='source-name-title'><pre>$TMP/foo.c</pre></div>" > "$TMP/html2/coverage/foo.c.html"
{
  for i in "${!SRC[@]}"; do
    ln=$((i + 1))
    printf "\n<tr><td class='line-number'><a name='L%d' href='#L%d'><pre>%d</pre></a></td><td class='code'><pre>%s</pre></td></tr>" "$ln" "$ln" "$ln" "${SRC[$i]}"
  done
  printf "\n</table></div></body></html>\n"
} >> "$TMP/html2/coverage/foo.c.html"
cp "$TMP/html/style.css" "$TMP/html2/style.css"
printf "Coverage Report\n%s:\n" "$TMP/foo.c" > "$TMP/text2/coverage/foo.c.txt"
for i in "${!SRC[@]}"; do ln=$((i + 1)); printf "%5d|%7d|%s\n" "$ln" 1 "${SRC[$i]}" >> "$TMP/text2/coverage/foo.c.txt"; done
cp "$TMP/summary.txt" "$TMP/summary2.txt"
annotate_reachability "$TMP/coverage.json" "$TMP/lists" "$TMP/html2" "$TMP/text2" "$TMP/summary2.txt" >/dev/null \
  || die "annotate_reachability (dir mode) returned non-zero"
# txt lists carry no indirect_only info → plain amber
grep -q "reach-amber'><td class='line-number'><a name='L5'" "$TMP/html2/coverage/foo.c.html" \
  || die "dir-mode: reachable_unreached should be plain reach-amber"
grep -q "reach-grey'><td class='line-number'><a name='L9'" "$TMP/html2/coverage/foo.c.html" \
  || die "dir-mode: dead_fn should be reach-grey"
echo "[PASS] dir-mode (txt lists)"

# ── diff --reachability still splits still-uncovered functions ───────────────
cp "$TMP/coverage.json" "$TMP/new.json"
cat > "$TMP/old.json" << EOF
{ "data": [ { "files": [ { "filename": "$TMP/foo.c", "segments": [], "summary": {} } ],
  "functions": [
    { "name": "covered_fn",          "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[1,1,3,2,0,0,0,0]] },
    { "name": "reachable_unreached", "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[5,1,7,2,0,0,0,0]] },
    { "name": "dead_fn",             "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[9,1,11,2,0,0,0,0]] },
    { "name": "anomaly_fn",          "count": 0, "filenames": ["$TMP/foo.c"], "regions": [[13,1,15,2,0,0,0,0]] } ] } ],
  "type": "llvm.coverage.json.export", "version": "2.0.0" }
EOF
bash "$COV" diff --reachability "$TMP/reach.json" -o "$TMP" "$TMP/old.json" "$TMP/new.json" \
  || die "diff --reachability returned non-zero"
grep -q 'chip-amber">reachable_unreached<' "$TMP/coverage_diff.html" \
  || die "diff: reachable_unreached should render as an amber chip"
grep -q 'chip-grey">dead_fn<' "$TMP/coverage_diff.html" \
  || die "diff: dead_fn should render as a grey chip"
echo "[PASS] diff --reachability"

# ── clang-gated end-to-end against REAL llvm-cov output ──────────────────────
CLANG="$(detect_clang || true)"
COVTOOL=""
if [ -n "$CLANG" ]; then
  ver="${CLANG#clang}"; ver="${ver#-}"
  for c in "llvm-cov${ver:+-$ver}" llvm-cov; do command -v "$c" >/dev/null 2>&1 && { COVTOOL="$c"; break; }; done
  pd=""
  for p in "llvm-profdata${ver:+-$ver}" llvm-profdata; do command -v "$p" >/dev/null 2>&1 && { pd="$p"; break; }; done
fi
if [ -n "$CLANG" ] && [ -n "$COVTOOL" ] && [ -n "${pd:-}" ]; then
  E="$TMP/e2e"; mkdir -p "$E"
  cat > "$E/p.c" << 'EOF'
#include <stdio.h>
int covered_fn(int x) { return x + 1; }
int reachable_unreached(int x) { return x - 1; }
int dead_fn(int x) { return x * 2; }
int main(int argc, char **argv) { printf("%d\n", covered_fn(argc)); return 0; }
EOF
  "$CLANG" -O0 -g -fprofile-instr-generate -fcoverage-mapping -o "$E/p" "$E/p.c"
  LLVM_PROFILE_FILE="$E/p.profraw" "$E/p" >/dev/null
  "$pd" merge -sparse "$E/p.profraw" -o "$E/p.profdata"
  "$COVTOOL" show "$E/p" -instr-profile="$E/p.profdata" -show-line-counts-or-regions \
    -format=html -output-dir="$E/html" 2>/dev/null
  "$COVTOOL" show "$E/p" -instr-profile="$E/p.profdata" -show-line-counts-or-regions \
    -format=text -output-dir="$E/text" 2>/dev/null
  "$COVTOOL" export "$E/p" -instr-profile="$E/p.profdata" --format=text > "$E/coverage.json"
  "$COVTOOL" report "$E/p" -instr-profile="$E/p.profdata" > "$E/summary.txt"
  "$COVTOOL" report "$E/p" -instr-profile="$E/p.profdata" -show-functions "$E/p.c" > "$E/perfunc.txt" 2>/dev/null
  cat > "$E/reach.json" << EOF
{ "reachable": [ { "mangled": "covered_fn", "file": "p.c", "line": 2 },
                 { "mangled": "reachable_unreached", "file": "p.c", "line": 3 } ],
  "unreachable_defined": [ { "mangled": "dead_fn", "file": "p.c", "line": 4 } ] }
EOF
  annotate_reachability "$E/coverage.json" "$E/reach.json" "$E/html" "$E/text" "$E/summary.txt" "$E/perfunc.txt" >/dev/null \
    || die "e2e: annotate_reachability returned non-zero on real llvm-cov output"
  realhtml="$(find "$E/html/coverage" -name 'p.c.html')"
  realtext="$(find "$E/text/coverage" -name 'p.c.txt')"
  grep -q 'reach-grey' "$realhtml"  || die "e2e: real HTML should contain a reach-grey row for dead_fn"
  grep -q 'reach-amber' "$realhtml" || die "e2e: real HTML should contain a reach-amber row"
  grep -Eq '\|U ' "$realtext"       || die "e2e: real text should contain a U marker for dead_fn"
  grep -Eq '\|R ' "$realtext"       || die "e2e: real text should contain an R marker"
  grep -q 'Reachable but NOT reached' "$E/summary.txt" || die "e2e: summary.txt should gain the block"
  # reachable-only recompute: dead_fn excluded → functions 2/3 (covered_fn+main of 3 kept).
  grep -qi 'Reachable-only coverage' "$E/summary.txt" || die "e2e: summary.txt should carry reachable-only table"
  grep -q '(2/3)' "$E/html/index.html" || die "e2e: index.html function coverage should drop to (2/3)"
  echo "[PASS] end-to-end against real llvm-cov"
else
  echo "[SKIP] clang/llvm-cov not available — skipping real-llvm-cov e2e"
fi

echo "[PASS] test_reachability"
