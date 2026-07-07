# cov-analysis - Fuzzing Code Coverage for AFL++, libFuzzer, libafl, and honggfuzz

Replacing `afl-cov` and `libfuzzer-cov` with modern coverage gathering and great features!

Version: 1.1-dev

- [Introduction](#introduction)
- [Prerequisites](#prerequisites)
- [Supported Fuzzers](#supported-fuzzers)
- [Workflow](#workflow)
  - [Step 1: Build a Coverage Binary](#step-1-build-a-coverage-binary)
  - [Step 2: Generate Coverage Report](#step-2-generate-coverage-report)
  - [Step 3: Diff Two Coverage Reports](#step-3-diff-two-coverage-reports)
  - [Step 4: Identifying unstable code lines](#step-4-identifying-unstable-code-lines)
  - [Step 5: Search which inputs reach a line](#step-5-search-which-inputs-reach-a-line)
  - [Parallelized AFL Execution](#parallelized-afl-execution)
- [Usage Information](#usage-information)
  - [cov-analysis report (default)](#cov-analysis-report-default)
  - [cov-analysis build](#cov-analysis-build)
  - [cov-analysis driver](#cov-analysis-driver)
  - [cov-analysis diff](#cov-analysis-diff)
  - [cov-analysis stability](#cov-analysis-stability)
  - [cov-analysis search](#cov-analysis-search)
- [License](#license)

## Introduction

`cov-analysis` generates **LLVM source-based code coverage** reports from a fuzzing corpus. It auto-detects the on-disk layout used by [AFL++](https://github.com/AFLplusplus/AFLplusplus) (queue/crashes/timeouts directories, single or parallel), libFuzzer and libafl (flat corpus dir plus `crash-*`/`leak-*`/`oom-*` artifacts), and honggfuzz (flat corpus plus `SIG*.fuzz` crash files). It replays each input through a coverage-instrumented binary, merges the raw profiles, and produces HTML, text, and JSON reports via `llvm-profdata` and `llvm-cov`.

This is a rewrite of the original cov-analysis. Key changes in 1.0:
- New: diff reports comparing coverage between two runs
- New: stability analysis identifying source lines with non-deterministic hit counts
- Replaced gcov/lcov/genhtml with LLVM source-based coverage (`-fprofile-instr-generate`, `llvm-profdata`, `llvm-cov`) - faster, more accurate under optimization
- `cov-analysis build` sets compiler flags and builds the target; `cov-analysis driver` emits a ready-to-use `coverage_driver.c` for `LLVMFuzzerTestOneInput` harnesses
- `cov-analysis diff` generates an HTML diff report comparing coverage between two JSON exports
- Rewritten in bash (was Python)

The coverage reports can be augmented with harness reachability information from [fuzz-reachability](https://github.com/AFLplusplus/fuzz-reachability)

## Prerequisites

- `clang` (any version down to 11)
- `llvm-profdata` and `llvm-cov` — auto-detected to match the selected clang
  version. When a versioned compiler is chosen (e.g. `CC=clang-22`, or the
  default `clang` reports version 22), the matching `llvm-profdata-22` /
  `llvm-cov-22` are used so the raw profiles merge without a version mismatch.
- AFL++ (`afl-fuzz`), libafl, libfuzzer, Honggfuzz, ... - only needed to produce the corpus, not to run `cov-analysis`

## Supported Fuzzers

| Fuzzer     | Detected by                                | Input files replayed                                                          |
|------------|--------------------------------------------|-------------------------------------------------------------------------------|
| AFL++      | `<dir>/queue/` or `<dir>/*/queue/` exists  | `queue/id:*`, `crashes/id:*`, `timeouts/id:*`                                 |
| libFuzzer  | flat directory of files, no `queue/`       | all files except `crash-*`/`leak-*`/`oom-*`/`timeout-*`/`slow-unit-*`        |
| libafl     | flat directory of files, no `queue/`       | all files except `crash-*`/`leak-*`/`oom-*`/`timeout-*`/`slow-unit-*`        |
| honggfuzz  | flat directory of files, no `queue/`       | all files except `SIG*.fuzz` and `HONGGFUZZ.REPORT.TXT`                       |

For libFuzzer, libafl and honggfuzz, crash-like files (above) are still replayed, but under the `-T` timeout so a hanging input can't stall the run.

Override auto-detection with `--layout afl|flat`.

## Workflow

Note: `cov-analysis` uses the `TMPDIR` environment variable if present.

### Step 1: Build a Coverage Binary

Use `cov-analysis build` to set the correct compiler flags and build your target:

```bash
# Set up a coverage build (run once per build step)
cd /path/to/project-cov/
cov-analysis build ./configure --disable-shared
cov-analysis build make -j$(nproc)
```

`cov-analysis build` sets:
```
CC=clang  CXX=clang++
CFLAGS="-fprofile-instr-generate -fcoverage-mapping -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1"
LDFLAGS="-fprofile-instr-generate"
```

**Important:** `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1` must match what was used during fuzzing - it disables the same checksums/HMACs that AFL++ bypassed.

#### For `LLVMFuzzerTestOneInput` harnesses

Generate a replay driver and link it against your coverage-instrumented library:

```bash
cov-analysis driver -o coverage_driver.c
clang -fprofile-instr-generate -fcoverage-mapping \
  -c coverage_driver.c -o coverage_driver.o
clang -fprofile-instr-generate \
  coverage_driver.o -L./build -ltarget -o cov
```

The driver loops over all file arguments, calls `LLVMFuzzerTestOneInput` for each, and installs a crash handler that flushes profiling data so crashing inputs still contribute to the report.

### Step 2: Generate Coverage Report

This step produces an `llvm-cov` coverage report with regions and branches:

<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/report-overview.png" alt="report overview">

<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/report-detail.png" alt="report detail">

```bash
cd /path/to/project-cov/
cov-analysis -d /path/to/afl-fuzz-output/ -e "./cov @@"
```

To replay coverage with multiple workers, add `-t`:

```bash
cov-analysis -d /path/to/afl-fuzz-output/ -e "./cov @@" -t 8
```

`cov-analysis` will for AFL++:
1. Replay all `queue/id:*` files in batch (fast)
2. Replay `crashes/id:*` and `timeouts/id:*` one-by-one with a timeout
3. Merge `.profraw` profiles with `llvm-profdata`
4. Generate reports in `/path/to/afl-fuzz-output/cov/`

For libfuzzer/libafl/Honggfuzz `cov-analysis` will:
1. Replay all files in the directory
2. Crash files are replayed one-by-one with a timeout

Output:
```
/path/to/afl-fuzz-output/cov/
  html/index.html     ← browse this for annotated source coverage
  text/               ← text format, suitable for automated analysis
  summary.txt         ← per-file line/branch/function percentages
  coverage.json       ← machine-readable export
  coverage.profdata   ← merged profile (baseline for iterative improvement)
```

For stdin-based targets (binary reads from stdin, no file argument):

```bash
cov-analysis -d /path/to/afl-fuzz-output/ -e "./target"
```

#### libFuzzer corpus

```bash
cov-analysis -d /path/to/libfuzzer-corpus/ -e "./cov @@"
```

Corpus files are replayed in batch mode. If your libFuzzer run used `-artifact_prefix=./crashes/`, point a second run at that directory to cover crash inputs too — or move artifacts into the corpus dir beforehand.

#### honggfuzz workspace

```bash
cov-analysis -d /path/to/hfuzz-workdir/ -e "./cov @@"
```

`SIG*.fuzz` crash files are replayed under the `-T` timeout. The `HONGGFUZZ.REPORT.TXT` metadata file is ignored automatically.

#### Cross-referencing static reachability

If you have run the companion [fuzz-reachability](https://github.com/AFLplusplus/fuzz-reachability)
analyzer, pass its output with `--reachability` to tell apart coverage gaps that
are worth chasing from dead weight you can safely ignore:

```bash
cov-analysis -d /path/to/afl-fuzz-output/ -e "./cov @@" \
  --reachability /path/to/reachability/test.json
```

`--reachability` accepts the analyzer's JSON report, its output directory, or
a single SanitizerCoverage allow/ignore `.txt` list. When a directory is
passed, a `reachability.json` inside it is preferred (it carries richer data —
indirect-call confidence, file/line, both mangled and demangled names) over
the `reached.txt` / `not_reached.txt` lists, which are used only as a
fallback when no `reachability.json` is present. The normal `llvm-cov` HTML
and text reports are annotated **in place** (no separate report). In the
HTML file view each function's lines are tinted:

- **covered** — keeps `llvm-cov`'s usual coloring
- **amber** — statically *reachable* but never reached (the actionable gap),
  shaded by the analyzer's per-function `confidence` (JSON mode only; the txt
  lists carry no confidence, so they always render the plain shade): darkest
  amber for `high` (a direct edge, or no confidence data at all), a lighter
  amber for `medium` (reachable only through an indirect call with value-flow
  evidence), and the lightest amber for `low` (an indirect call matched only
  by type — the likely-spurious surface of the over-approximation)
- **dark grey** — statically *unreachable*, so it is expected to stay
  uncovered — ignore it
- **purple** — covered yet flagged unreachable (a static-analysis anomaly worth
  a look, since the analyzer claims it never under-reports)

The HTML `index.html` gains a tally banner. The text source view (`text/`) gets
a per-line marker column (`U` unreachable, `R` reachable-but-unreached,
`A` anomaly), and `summary.txt` gains a reachability tally plus the explicit
list of reachable-but-not-reached functions to go after.

> **Rust name/key matching only tolerates legacy mangling.** The name/`key`
> join above tolerates the *legacy* Rust mangling scheme's `17h<hash>`
> disambiguator drifting between the analyzed build and the coverage build.
> Under Rust's **v0** mangling scheme (`_R…` symbols, which
> `-Cinstrument-coverage` forces), fuzz-reachability's `key` equals the raw
> mangled name — the normalization is inert for v0 — so a v0-mangled
> instance whose disambiguator differs between the two builds will not match
> by name or `key`. When the reachability report is the JSON report (not the
> `.txt` lists) and carries `file`/`line` for the function (i.e. the
> analyzed bitcode has debug info), the `(file, line)` fallback used above
> still classifies it correctly; without debug info the function has no
> fallback and is left `unknown`. See fuzz-reachability's README for the
> full explanation; full v0-aware key normalization is a future enhancement
> there, not yet implemented.

**The coverage numbers themselves are recomputed to exclude unreachable
functions.** Normally a function coverage of `5/6` counts a statically-dead
function in the denominator even though the harness can never reach it. With
`--reachability`, the Function / Line / Region / Branch numbers in both
`index.html` and `summary.txt` drop every statically-unreachable function from
the denominators (and numerators), so the percentages reflect only code the
harness can actually reach — e.g. that `5/6` becomes `5/5`. The numbers come
straight from `llvm-cov report -show-functions` (so they match llvm-cov's own
math exactly), re-summed over the reachable set; the unmodified figures remain
in `coverage.json`. With `--reachability` the HTML index is rendered flat
(directory grouping disabled) so its cells can be rewritten reliably.

`cov-analysis diff` accepts the same `--reachability` flag; it splits the
"still uncovered functions" list in the diff report into reachable (amber,
actionable) and unreachable (grey, expected dead).

### Step 3: Diff Two Coverage Reports

Compare coverage between two `llvm-cov` JSON exports and generate an HTML diff report:

```bash
cov-analysis diff coverage_old.json coverage_new.json
```

If you use the same output directory for a subsequent run, `cov-analysis` renames the existing `coverage.json` to `coverage_old.json` automatically, so `cov-analysis diff` works with no arguments.

The report is written to `<report-dir>/coverage_diff.html` and shows:
- Newly covered and no-longer-covered lines per file
- Newly covered and lost functions
- Source code snippets annotated with coverage change

If the JSON paths are omitted, `cov-analysis diff` defaults to `<report-dir>/coverage_old.json` and `<report-dir>/coverage.json`. Run with no arguments and neither default report present in the current directory, it prints the help instead of an error.

The HTML diff report looks like this:

<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/diff-overview.png" alt="diff overview">
<img align="left" src="https://raw.githubusercontent.com/AFLplusplus/cov-analysis/main/diff-detail.png" alt="diff detail">

### Step 4: Identifying unstable code lines

Ever wondered which source lines cause AFL++ or libafl to report instability in a fuzz target?
The `stability` command identifies them.

```bash
cov-analysis stability -d ../afl/out -e "./cov @@"
```

This will give you the exact lines that are problematic, e.g.:
```
Stability Report
--------------------------------------------------------
Corpus size : 2 inputs
Runs        : 8
Stability   : 74.0% (91/123 executed lines stable)

~~ Variable-count lines (32 lines):
   Lines with varying hit counts:

  /prg/cov-analysis/tests/unstable.c:35-37
  /prg/cov-analysis/tests/unstable.c:43
  /prg/cov-analysis/tests/unstable.c:46-48
  /prg/cov-analysis/tests/unstable.c:51-52
  /prg/cov-analysis/tests/unstable.c:55-61
  /prg/cov-analysis/tests/unstable.c:64-66
  /prg/cov-analysis/tests/unstable.c:69-70
  /prg/cov-analysis/tests/unstable.c:75-85

[!] Unstable coverage detected.
```

### Step 5: Search which inputs reach a line

Wonder which corpus entries actually exercise a particular source line? The
`search` command replays each input in isolation and reports the ones that
reach `FILE:LINE`:

```bash
cov-analysis search src/parser.c:142 -d ../afl/out -e "./cov @@"
```

Matching input paths are printed to stdout (one per line, sorted) so the result
pipes cleanly; progress and the summary go to stderr:

```
src/parser.c:142 is reachable; scanning...
out/queue/id:000017,...
out/queue/id:000094,...
[+] 2 of 142 inputs reach src/parser.c:142
```

By default only queue/corpus entries are scanned. Add `--crashes` to also scan
crash and timeout inputs, and `-t N` to parallelize:

```bash
cov-analysis search src/parser.c:142 -d ../afl/out -e "./cov @@" --crashes -t 8
```

A fast union pre-check replays the whole corpus once first; if no input reaches
the line, `search` reports `0 of N` immediately (and tells you whether the line
is merely unreached or not present in the coverage data at all) without the full
per-input scan.

Pipe the reaching inputs straight into another tool:

```bash
cov-analysis search src/parser.c:142 -d ../afl/out -e "./cov @@" | xargs -I{} cp {} ./hits/
```

### Parallelized AFL Execution

For parallel AFL runs (`afl-fuzz -o sync_dir`), point `-d` at the top-level sync directory. `cov-analysis` automatically discovers all fuzzer instance subdirectories:

```bash
cov-analysis -d /path/to/sync_dir/ -e "./cov @@"
```

## Usage Information

### cov-analysis report (default)

```
Usage: cov-analysis [report] [options]

Required:
  -d <dir>    Fuzzing output directory (AFL++, libFuzzer, libafl, or honggfuzz)
  -e <cmd>    Coverage command. Use @@ as input file placeholder.
              Omit @@ to feed input via stdin instead. For a cov-analysis
              driver binary (which reads files, not stdin), @@ is appended
              automatically when omitted.

Optional:
  -o <dir>           Report output directory (default: <afl-dir>/cov)
  -t <num>           Parallel replay workers/forks (default: 1)
  -T <secs>          Timeout for crash/timeout replay (default: 5)
  --layout <kind>    Force layout: 'afl' or 'flat' (default: auto-detect)
  --ignore-regex <r> Filename regex to exclude from llvm-cov reports
                     (default: /usr/include/)
  --reachability <p> Cross-reference fuzz-reachability output (its JSON report,
                     output directory — reachability.json when present, else
                     reached.txt/not_reached.txt — or a sancov allow/ignore
                     .txt list) and annotate the HTML + text reports in
                     place: functions tinted amber=reachable but not
                     reached, dark grey=unreachable,
                     purple=covered yet flagged unreachable; text gets a U/R/A
                     marker column and summary.txt a reachability tally.
  -v                 Verbose output
  -q                 Quiet mode
  -V                 Print version and exit
  -h, --help         Print this help and exit
```

### cov-analysis build

```
Usage: cov-analysis build <build-command> [args...]

  Sets CC/CXX/CFLAGS/CXXFLAGS/LDFLAGS for LLVM source-based coverage and
  runs the given build command.
```

### cov-analysis driver

```
Usage: cov-analysis driver [-o output.c]

  Emits coverage_driver.c source to stdout (or to -o FILE).
  Use this for LLVMFuzzerTestOneInput harnesses to replay corpus files.

  The driver loops over all file arguments, calls LLVMFuzzerTestOneInput
  for each, and installs a crash handler that flushes profiling data so
  crashing inputs still contribute to the coverage report.

Options:
  -o <file>     Write driver source to FILE instead of stdout
```

### cov-analysis diff

```
Usage: cov-analysis diff [-o <dir>] [--reachability <p>] [<OLD_JSON> <NEW_JSON>]

  Compare coverage between two llvm-cov JSON exports and generate an
  HTML diff report showing newly covered, lost, and still-uncovered
  lines and functions.

  Defaults to <report-dir>/coverage_old.json and <report-dir>/coverage.json.

  --reachability <p> cross-references fuzz-reachability output (JSON, output
  directory — reachability.json when present, else reached.txt/not_reached.txt
  — or a sancov .txt list) and splits the still-uncovered functions into
  reachable (amber, actionable) vs unreachable (grey, expected dead).
```

### cov-analysis stability

```
Usage: cov-analysis stability [options]

  Run each corpus input N times with LLVM coverage, collect per-line hit
  counts, and flag lines where counts vary across runs as "unstable."
  Reports a stability percentage. If instability is found with the default
  4 runs, reruns for a total of 8 to confirm.

  Resilient to flaky passes: a pass whose profiles cannot be collected or
  merged (e.g. a crashing input that left a truncated .profraw behind) is
  skipped and the run continues with the remaining passes, as long as at
  least 2 passes succeed.

Required:
  -d <dir>    Fuzzing output directory (AFL++, libFuzzer, libafl, or honggfuzz)
  -e <cmd>    Coverage command. Use @@ as input file placeholder.
              Omit @@ to feed input via stdin instead. For a cov-analysis
              driver binary (which reads files, not stdin), @@ is appended
              automatically when omitted.

Optional:
  -n <num>           Number of runs per corpus pass (default: 4)
  -s <prefix>        Only consider source lines whose file path contains
                     this prefix (e.g. -s src/)
  -t <num>           Parallel replay workers (default: 1)
  --layout <kind>    Force layout: 'afl' or 'flat' (default: auto-detect)
  -v                 Verbose output
  -q                 Quiet mode (suppress all [+] output)
  -V                 Print version and exit
  -h, --help         Print this help and exit
```

The command outputs a **Stability Report** showing corpus size, number of runs, and the stability percentage (stable executed lines / total executed lines). If unstable lines are found, they are listed with file paths and line number ranges. If any pass failed to collect or merge its profiles, it is skipped and the report notes how many runs were actually analyzed.

Examples:

```bash
cov-analysis stability -d out/ -e "./cov @@"
cov-analysis stability -d out/ -e "./cov @@" -n 8 -s src/
cov-analysis stability -d ./corpus -e "./cov @@" -t 4
```

### cov-analysis search

```
Usage: cov-analysis search FILE:LINE -d <dir> -e "<cmd>" [options]

  Report which corpus entries reach a given source line. Each input is replayed
  in isolation; an input "reaches" FILE:LINE when its line-execution count for
  that line is > 0. Matching input paths print to stdout (sorted, one per line);
  progress and the summary go to stderr.

Required:
  FILE:LINE   Source location, e.g. src/foo.c:123 (single line)
  -d <dir>    Fuzzing output directory (AFL++, libFuzzer, libafl, or honggfuzz)
  -e <cmd>    Coverage command. Use @@ as input file placeholder.
              Omit @@ to feed input via stdin instead. For a cov-analysis
              driver binary (which reads files, not stdin), @@ is appended
              automatically when omitted.

Optional:
  --crashes          Also scan crash and timeout inputs (default: corpus only)
  -t <num>           Parallel workers for the per-input scan (default: 1)
  -T <secs>          Per-input replay timeout in seconds (default: 5)
  --layout <kind>    Force layout: 'afl' or 'flat' (default: auto-detect)
  -v                 Verbose output
  -q                 Quiet mode
  -V                 Print version and exit
  -h, --help         Print this help and exit
```

## License

`cov-analysis` is released under the **GNU Affero General Public License 3**.
