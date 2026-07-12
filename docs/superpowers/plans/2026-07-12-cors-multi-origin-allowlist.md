# Multi-origin CORS from FMS OAuth Allow List — Implementation Plan

> **For agentic workers:** implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Design spec: [`docs/superpowers/specs/2026-07-12-cors-multi-origin-allowlist-design.md`](../specs/2026-07-12-cors-multi-origin-allowlist-design.md).

**Goal:** Teach [`scripts/patch-fms-nginx-cors.sh`](../../../scripts/patch-fms-nginx-cors.sh) to emit an nginx `map $http_origin` CORS allowlist derived from the FMS OAuth Allow List (`--from-fms`, read from `dbs_config.xml`) or an explicit `--allow-origin` set — while keeping today's single-origin and `*` behavior. Accept bare hosts (assume `https://`); exact-host match only; fail loudly if FMS's allow list is disabled/empty.

**Architecture:** One self-contained bash script on the FMS host, edited in place. The current script does a single incremental `perl -pe` pass that comments out the stock CORS trio and inserts our lines. Bolting three modes + a `map` block + mode-switching onto that incremental pass makes idempotency fragile. **This plan restructures the transform to "revert-to-stock, then apply-target" run every time**, so re-runs, `*`→map, and map→different-map all become the same deterministic operation, and idempotency is a byte-compare of the generated result against the current file.

**Tech stack:** Bash + `perl` (already the script's engine). No new dependencies. Runs on the FMS Ubuntu host; developed/tested against copies in `/tmp` on macOS (note `timeout` is Linux-only — the script already degrades gracefully).

## Global constraints

- Match the existing script's style: `set -euo pipefail`, tab indentation, `perl` single-quoted heredocs so literal nginx text (`$hostname`, `$http_origin`) is never shell/perl-interpolated. Values passed to perl via env vars (as `ORIGIN` is today).
- **Backward compatible for explicit args:** `patch-fms-nginx-cors.sh '*'` and `patch-fms-nginx-cors.sh https://wim.ets.fm` must still produce today's exact single-value output (stock lines commented, `always` on all four lines, no map block). **Note the one intentional break:** the *bare* zero-arg invocation now defaults to `--from-fms` (map) instead of `*` — capture goldens accordingly (explicit `*`/single unchanged; zero-arg golden is the FMS-derived map).
- Preserve every current guarantee: idempotent, timestamped backup before write, structural validation with restore-on-failure, edits **both** server blocks, `always` on all CORS lines, **no** service restart, dry-run needs no write access to the conf dir, opt-in `--nginx-test` with FIFO passphrase feeding.
- The script only **reads** `dbs_config.xml`; never writes it. No cert/include changes.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File structure

- `scripts/patch-fms-nginx-cors.sh` (modify) — new flags, origin resolution + normalization, revert-to-stock transform, mode-aware apply transform (server blocks + map block), extended validation, updated help/next-steps.
- `docs/fms-server-cors-config.md` (modify) — "Allowing multiple web origins" subsection.
- `README.md` (modify) — one-line pointer in "Server-side setup".
- `test/patch-cors.test.sh` (create) — standalone bash test harness driving the script against fixtures in a temp dir (no FMS needed).

---

## Task 1: Origin resolution + normalization (pure helpers, with tests)

**Files:** modify `scripts/patch-fms-nginx-cors.sh` (arg parsing ~L60-95, add helpers); create `test/patch-cors.test.sh`.

**Interfaces produced:**
- `normalize_origin(raw) -> stdout` — trim whitespace; if no `://`, prefix `https://`; validate against `^https?://[A-Za-z0-9.-]+(:[0-9]+)?$` (return non-zero + message on failure).
- `read_fms_allowlist(dbs_config_path) -> stdout (one host per line)` — extract `OAuthAllowList` and `OAuthDomainName`; exit non-zero with the specific spec error when the file is missing, `OAuthAllowList != 1`, or `OAuthDomainName` yields no hosts.
- New globals from arg parse: `FROM_FMS` (0/1), `ALLOW_ORIGINS` (array), `DBS_CONFIG` (default `/fms/Data/Preferences/dbs_config.xml`), plus existing `ORIGIN`/`CONF`/`DRY_RUN`/`NGINX_TEST`/`PASSPHRASE`.
- `MODE` resolved to one of `map` | `single` | `wildcard`, and `ORIGIN_SET` (sorted, de-duplicated array of full origins) when `MODE=map`.

**Resolution rules (from spec §1):**
- **No positional and no flags → `MODE=map` via `--from-fms` (the default).**
- `--from-fms` or ≥1 `--allow-origin` → `MODE=map`; union both sources; if a positional ORIGIN was also given, warn it's ignored.
- positional `*` → `MODE=wildcard` (explicit opt-in).
- specific positional → `MODE=single`.

- [ ] **Step 1: Write the failing test** — create `test/patch-cors.test.sh` (bash, `set -u`, exits non-zero on any failure; run with `bash test/patch-cors.test.sh`). It sources the script with a `PATCH_CORS_LIB=1` guard (see Step 3) so only functions load, no main flow runs. Assert:
  - `normalize_origin 'wim.ets.fm'` → `https://wim.ets.fm`; `'  site.ets.fm '` → `https://site.ets.fm`; `'https://x.fm'` unchanged; `'ht!tp://bad'` → non-zero.
  - `read_fms_allowlist` against three fixtures written by the test into a temp dir: (a) enabled + `wim.ets.fm, site.ets.fm` → two lines; (b) `OAuthAllowList=0` → non-zero + "disabled" message; (c) enabled + empty `OAuthDomainName` → non-zero + "empty" message.
- [ ] **Step 2: Add `normalize_origin` and `read_fms_allowlist`** near the top of the script (after `usage`). `read_fms_allowlist` uses `perl -ne` to pull the two `<key .../>` values from the plain-XML file (`OAuthAllowList` integer, `OAuthDomainName` string), split `OAuthDomainName` on comma, trim, drop empties.
- [ ] **Step 3: Add the lib guard** — wrap the main flow (everything after the function/heredoc definitions) in `if [ "${PATCH_CORS_LIB:-0}" != 1 ]; then ... fi`, or `return 0` early when sourced, so the test can load helpers without executing. Keep this minimal and clearly commented.
- [ ] **Step 4: Extend arg parsing** — add `--from-fms`, `--allow-origin HOST` (repeatable, appends to `ALLOW_ORIGINS`), `--dbs-config PATH`. Then a resolution block computing `MODE` and `ORIGIN_SET`. Run the test → green.

**DoD:** `bash test/patch-cors.test.sh` passes; `bash -n scripts/patch-fms-nginx-cors.sh` clean; `--help` unchanged so far.

---

## Task 2: Revert-to-stock transform (idempotency foundation)

**Files:** modify `scripts/patch-fms-nginx-cors.sh` (replace the single `PERL_PROG` at ~L143-162 with two transforms).

**Why:** So every run starts from a known base regardless of current state (pristine stock, or previously patched in any mode). Enables clean re-runs and mode switching.

**Interface:** `REVERT_PROG` (perl, slurp mode `-0777`) that, given any managed conf, returns it to pristine stock CORS:
- Re-activate commented stock lines: `# add_header 'Access-Control-Allow-Origin' $hostname;` → uncommented; same for the `Content-Type,Authorization` Allow-Headers line.
- Delete lines we add: our `Access-Control-Allow-Origin '<literal|$fms_cors_allow_origin>' always;`, the `Allow-Credentials ... always;` (revert to no-`always`), the expanded `Allow-Headers ... always;`, and the `Expose-Headers ... always;`.
- Remove the sentinel-wrapped map block (Task 3) entirely, including surrounding blank line.

- [ ] **Step 1: Add revert test cases** to `test/patch-cors.test.sh`: feed a fixture already patched in single mode and one in map mode through `REVERT_PROG`; assert the result equals the pristine stock fixture byte-for-byte (both server blocks show the original stock trio; no map block; brace count back to 29/29).
- [ ] **Step 2: Implement `REVERT_PROG`** as a `perl -0777 -pe` program in a single-quoted heredoc. Anchor on the exact managed strings (the same literals the apply step writes) so it can't touch unrelated config.
- [ ] **Step 3:** Wire a `revert_to_stock <file> > <out>` helper and cover it in the test. Green.

**DoD:** revert of any mode → pristine stock, verified byte-exact against the stock fixture.

---

## Task 3: Mode-aware apply transform (server blocks + map block)

**Files:** modify `scripts/patch-fms-nginx-cors.sh`.

**Interfaces:**
- `APPLY_SERVER_PROG` (perl) — from pristine stock, comment the stock trio and insert our four `always` lines, with the ACAO **value** taken from env `ACAO_VALUE`: a quoted literal (`'*'` or `'https://…'`) in single/wildcard, or the bare token `$fms_cors_allow_origin` in map mode. (One transform; only the ACAO value differs by mode.)
- `render_map_block(origins…) -> stdout` — the sentinel-wrapped `map $http_origin $fms_cors_allow_origin { default ""; "<origin>" "<origin>"; … }` text (spec §2a).
- `APPLY_MAP_PROG` (perl `-0777`) — insert the rendered map block immediately after the existing `map $http_upgrade $connection_upgrade { … }` block. Map mode only.

- [ ] **Step 1: Add apply test cases**: for each mode, `revert_to_stock` then apply, assert:
  - wildcard → identical to today's `*` output (golden file captured from the current script before changes).
  - single → identical to today's `https://wim.ets.fm` output.
  - map (`https://wim.ets.fm`, `https://site.ets.fm`) → one map block after the upgrade map; ACAO reads `$fms_cors_allow_origin` in **both** server blocks; map contains exactly the two origins.
- [ ] **Step 2: Implement `APPLY_SERVER_PROG`** (generalize the current transform; ACAO value via `ACAO_VALUE` env). Preserve leading-whitespace capture so both 3-space and 4-space blocks match.
- [ ] **Step 3: Implement `render_map_block` + `APPLY_MAP_PROG`** with `# BEGIN/END fms-oauth-cors-allowlist` sentinels. Insert after the upgrade-map block; assert exactly one map block exists afterward.
- [ ] **Step 4: Build `generate_output <src>`** = `revert_to_stock` → `APPLY_SERVER_PROG` (with mode's `ACAO_VALUE`) → (map mode) `APPLY_MAP_PROG`. This is the single source of the desired file. Green.

**DoD:** all three modes generate correct output from both stock and already-patched inputs; back-compat golden files match exactly.

---

## Task 4: Rewire main flow — idempotency, dry-run, backup, commit

**Files:** modify `scripts/patch-fms-nginx-cors.sh` (state detection ~L110-138, dry-run ~L164-177, apply/validate/commit ~L179-221).

**Design:** Replace marker-counting idempotency with **generate-and-compare**:
1. Preflight (existing): conf exists; write access unless dry-run. For `--from-fms`, also resolve `ORIGIN_SET` now (so a disabled/empty FMS list fails *before* any file work).
2. `generate_output "$CONF" > "$GEN"` (in a temp file).
3. **Sanity gate** (replaces the "exactly 2 stock blocks" guard): the source must be a *recognized* state — either pristine stock (2 stock ACAO lines) or already-managed (2 `Expose-Headers` lines). If neither, abort "unrecognized conf (version drift?) — inspect manually" and don't write. This keeps the current safety property while allowing already-patched inputs.
4. **Idempotency:** if `cmp -s "$GEN" "$CONF"` → "already configured for <mode>; nothing to do" and exit 0 (works for dry-run and real).
5. **Dry-run:** `diff -u "$CONF" "$GEN"` (temp in writable dir, as today), print resolved mode + origin set, exit 0.
6. **Real:** backup (existing), `mv "$GEN" "$CONF"` after validation.

- [ ] **Step 1:** Extend the test to drive the whole script end-to-end against a temp conf: real run (stock→map), re-run (no-op "already configured"), change `ORIGIN_SET` and re-run (map updated in place, one block), then run `'*'` (converts map→wildcard, map block removed), confirming revert path works across modes. Assert backups created only on real writes.
- [ ] **Step 2:** Implement the generate-and-compare main flow; wire `--from-fms` resolution into preflight so FMS-not-configured aborts early with the spec's messages.
- [ ] **Step 3:** Update dry-run to diff the generated file and print mode/origins. Green.

**DoD:** idempotent across re-runs and mode switches; FMS-disabled/empty aborts before touching the file; dry-run writes nothing and needs no conf-dir write access.

---

## Task 5: Validation extensions

**Files:** modify `scripts/patch-fms-nginx-cors.sh` (validation ~L189-216).

Keep restore-on-failure. Validate the generated file before commit:
- [ ] **Step 1:** **Brace balance** — compare open/close counts of `$GEN` to the *reverted-stock* base plus the expected delta (0 for single/wildcard, +1 pair for map). Compute the expected delta from `MODE`, not a hardcoded 29/30 (robust to FMS version line drift).
- [ ] **Step 2:** Exactly **2** `Expose-Headers` lines; **0** un-commented stock ACAO lines (existing checks, retained).
- [ ] **Step 3:** Map mode only — exactly **one** `map $http_origin $fms_cors_allow_origin` block; the set of quoted origins in it equals `ORIGIN_SET`; every server-block ACAO reads `$fms_cors_allow_origin` (not a literal). Non-map mode — assert **no** map block/sentinels remain.
- [ ] **Step 4:** Add validation-failure test cases (e.g. corrupt the generated file via a stub to prove restore-on-failure leaves the original intact). Green.

**DoD:** malformed generation is caught and the original conf is left byte-identical.

---

## Task 6: Help text, next-steps, and docs

**Files:** modify `scripts/patch-fms-nginx-cors.sh` (header ~L35-54, next-steps ~L276-293), `docs/fms-server-cors-config.md`, `README.md`.

- [ ] **Step 1:** Update the script header/usage block to document `--from-fms`, `--allow-origin`, `--dbs-config`, bare-host normalization, and the three modes. (Recall `usage()` prints the header comment verbatim.)
- [ ] **Step 2:** Next-steps output: unchanged for `nginx -t` / restart / Custom Home URL. In map mode, add a line noting the nginx allowlist now mirrors the FMS OAuth Allow List and that changing domains in Admin Console means re-running `--from-fms`.
- [ ] **Step 3:** `docs/fms-server-cors-config.md` — add "Allowing multiple web origins" under section 1: ACAO single-value limitation, the `map` idiom, `--from-fms` as recommended, where FMS stores it (`/fms/Data/Preferences/dbs_config.xml`, `OAuthDomainName`), and that the two layers are enforced independently. Cross-link the spec.
- [ ] **Step 4:** `README.md` — one line in "Server-side setup": for several sites against one FMS, run `--from-fms` instead of `*`.

**DoD:** `--help` reflects reality; docs explain the multi-origin path and the FMS↔nginx relationship.

---

## Task 7: End-to-end verification on the FMS box (.82)

Read-only-safe until the final apply; do not restart httpserver.

- [ ] **Step 1:** `scp` the script up; `--dry-run --from-fms` against the live `dbs_config.xml` (currently enabled, `wim.ets.fm, site.ets.fm`) → diff shows the map with both `https://` origins and `$fms_cors_allow_origin` in both blocks. (Note: the live conf may currently be stock after the server restore — the revert step still yields a clean apply.)
- [ ] **Step 2:** Temporarily test the failure path with a copy: `--from-fms --dbs-config /tmp/copy_disabled.xml` (OAuthAllowList=0) → aborts, no write.
- [ ] **Step 3:** Real `sudo … --from-fms`, then `--nginx-test --passphrase '<self-signed pass>'` (self-signed cert, since no custom cert installed). Confirm brace/structure validation passes.
- [ ] **Step 4:** Once WebDirect is re-enabled (endpoint not 502), run the spec's per-origin `curl` loop and confirm the two FMS origins are echoed and a third is denied (no ACAO header). Record results; do not commit anything from the box.

**DoD:** live dry-run matches expectation; failure path aborts cleanly; (when WebDirect up) header reflection matches the FMS allow list.

---

## Sequencing & risk

- Tasks 1→5 are pure local script work with the bash test harness; 6 is docs; 7 is on-box. Land 1-6 behind the test harness, verify on .82 last.
- **Highest-risk piece:** the revert/apply perl transforms must be exact inverses of each other and byte-stable, or idempotency breaks. Task 2/3 golden-file tests are the guard. Keep the managed literals identical between apply and revert (define them once as shell vars if it reduces drift).
- **Back-compat risk:** capture golden `*` and single-origin outputs from the *current* committed script before editing, and assert the refactor still reproduces them (Task 3 Step 1).
- No change to client JS or the FMS contract; the only new FMS interaction is a read of `dbs_config.xml`.
