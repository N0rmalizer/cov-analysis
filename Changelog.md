# v1.1-dev
- reachability: `report` and `diff` now share one Python library (`reach_py_lib`) so both classify functions identically
- reachability: match Rust legacy-mangling disambiguators (`17h<hash>E`) and fall back to a (file, line) join for v0-mangled names
- reachability: file-qualify `static` function matches so same-named statics in different files no longer collide
- reachability: the reachable-only coverage recompute now disambiguates statics by `(file, symbol)` (the same qualified key the tally uses) and resolves any residual bare-name collision reachable-wins, so it never drops a live function from the denominators or contradicts the tally banner
- reachability: a `--reachability` directory now prefers a `reachability.json` inside it over `reached.txt`/`not_reached.txt`
- reachability: the amber "reachable but not reached" tint is now graded by the JSON report's per-function `confidence` (`reach-amber`/`reach-amber-indirect`/`reach-amber-low` for `high`/`medium`/`low`) instead of a plain `indirect_only` two-way split

# v1.0
- initial release
