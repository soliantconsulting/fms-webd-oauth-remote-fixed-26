# Multi-origin CORS for the FMS nginx patch — `map`-based allowlist

**Date:** 2026-07-12
**Status:** Proposed design, pending approval
**Scope:** `scripts/patch-fms-nginx-cors.sh` + docs (`docs/fms-server-cors-config.md`, `README.md`). FMS-host nginx config only. No client JS or FMS-admin changes.

## Context / why now

FileMaker Server **26.1.1.15** (dev build on `mbp2013.ets.fm`) added an **OAuth Allow List** in
Admin Console → **External Authentication** that accepts **multiple** allowed domains for
programmatic OAuth / `X-FMS-Return-URL` requests. On the box this is persisted in
`/fms/Data/Preferences/dbs_config.xml` as a single comma-separated string:

```xml
<key name="OAuthDomainName" type="string">wim.ets.fm, site.ets.fm</key>
<key name="OAuthAllowList" type="integer">1</key>
```

So FMS can now authorize more than one remote web origin (e.g. `wim.ets.fm` **and**
`site.ets.fm`) to drive the OAuth handshake against the same server. Our current
[`scripts/patch-fms-nginx-cors.sh`](../../../scripts/patch-fms-nginx-cors.sh) cannot express that
on the CORS side.

**Match semantics — exact host only.** The persisted store carries just `OAuthDomainName` (a
comma-separated host string) and `OAuthAllowList` (0/1). There is **no** exact/prefix/subdomain
mode field. (An earlier read of the FAC bundle noted `allowlistStartsWith` / `allowSubDomains`
strings, but on inspection those belong to unrelated bundled code — `allowSubDomains` is the AWS
SDK's `isVirtualHostableS3Bucket`/`isValidHostLabel`, and `allowlistStartsWith`/`allowlistExact`
are a generic request-`req.path` bypass middleware. The real OAuth feature — `setOAuthAllowlist`,
`getOAuthAllowlistInfo`, `OAuthDomainName` — has no match-mode token beside it.) So this build does
exact-host matching, and the spec follows suit.

## Problem

The browser gate is nginx's `Access-Control-Allow-Origin` (ACAO), and **ACAO holds exactly one
value, or `*` — never a space/comma list**. Our script today writes a single static header:

```nginx
add_header 'Access-Control-Allow-Origin' '<ORIGIN>' always;   # ORIGIN defaults to '*'
```

Given the new multi-domain FMS reality, the two current options each fall short:

- **`*`** — works today because the client XHRs are **not credentialed** (confirmed: no
  `withCredentials` in `assets/js/oauth-*.js`), so `*` + `Access-Control-Allow-Credentials: True`
  isn't hit by the browser's credential rule on these requests. But `*` is exactly what the repo
  docs tell operators to tighten for production, and it defeats the point of FMS having a curated
  allow list.
- **A single specific origin** (`--nginx-cors https://wim.ets.fm`) — strict, but **breaks the
  second domain**: `site.ets.fm` is allowed by FMS yet blocked by CORS, producing the misleading
  "No 'Access-Control-Allow-Origin' header" error our docs describe.

There is no static `add_header` value that allows *two specific* origins. The standard nginx
idiom for "allow a set of specific origins" is a `map` that reflects the request's `Origin` back
only when it is on an allowlist.

## Goals

- **Derive the CORS allowlist from FMS itself** — read the enabled OAuth Allow List
  (`OAuthDomainName` / `OAuthAllowList`) out of `dbs_config.xml` and generate matching nginx CORS,
  so the two layers can't silently drift. The operator does not re-type the domains.
- **Fail loudly if FMS isn't configured yet** — if the OAuth Allow List is disabled or empty, stop
  with a clear message telling the operator to set it in Admin Console first (rather than emit an
  empty/permissive allowlist).
- Keep the existing single-origin and `*` behaviors working (backward compatible) for the cases
  that don't want FMS-derived origins.
- Preserve every other property of the current script: idempotent, backup-first, structural
  validation, `always` on all CORS lines, no service restart, edits **both** server blocks.
- Keep the emitted config reviewable and re-derivable (a re-run with unchanged FMS settings is a
  no-op).

## Non-goals (YAGNI)

- No subdomain / prefix / regex matching. FMS 26.1.1.15 stores exact hosts only (see Context), so
  v1 is **exact-origin** match. If a later FMS build adds a match-mode field to `dbs_config.xml`,
  revisit then.
- No change to client JS, `withCredentials`, or the FMS request/response contract.
- No change to the cert/include groups the script already deliberately leaves stock.
- No writing to `dbs_config.xml` — the script only **reads** it; the OAuth Allow List is managed in
  Admin Console.

## Design

### 1. New CLI surface — `scripts/patch-fms-nginx-cors.sh`

Default behavior gains an FMS-derived multi-origin mode; the positional `ORIGIN` still covers the
single/`*` case for backward compatibility.

```
sudo ./patch-fms-nginx-cors.sh [ORIGIN] [--from-fms] [--allow-origin HOST]... \
     [--dbs-config PATH] [--conf PATH] [--dry-run] [--nginx-test] [--passphrase P]
```

- **`--from-fms`** — **read the OAuth Allow List from FMS** (`OAuthDomainName` +
  `OAuthAllowList` in `dbs_config.xml`) and generate the CORS map from it. This is the
  recommended mode when serving one or more remote sites, and the reason the map exists.
- **`--allow-origin HOST`** (repeatable) — manual escape hatch: add a host/origin without reading
  FMS (useful for testing off-box or when the operator wants CORS to differ from FMS on purpose).
- **`--dbs-config PATH`** — override the FMS prefs path (default
  `/fms/Data/Preferences/dbs_config.xml`); mainly for testing against a copy.
- Resolution rules (single source of truth for what gets emitted):
  - **No positional and no flags → `--from-fms` (the default).** Running the script bare reads the
    FMS OAuth Allow List and emits the map. This is the recommended, drift-free path.
  - **`--from-fms`** or **≥1 `--allow-origin`** → **map mode** (section 2). If both are given,
    the sets are unioned. A positional `ORIGIN` given alongside is ignored in map mode (warn).
  - **positional `*`** → **wildcard mode** (explicit opt-in to the permissive header).
  - **positional a specific origin** → **single-origin mode** (static header).

**Host normalization (accept bare hosts, assume `https://`).** FMS stores bare hosts
(`wim.ets.fm`); a CORS `Origin` is scheme+host (`https://wim.ets.fm`). The script normalizes every
value — from `--from-fms`, `--allow-origin`, and any positional — through one rule:

- If the value has no `://`, prefix `https://` (the only scheme this flow uses).
- Trim surrounding whitespace (the FMS string is comma-**space** separated: `wim.ets.fm, site.ets.fm`).
- Reject anything that, after normalization, doesn't match `^https?://[A-Za-z0-9.-]+(:[0-9]+)?$`
  (abort with a clear message naming the bad value).
- De-duplicate the resulting origin set.

So `--from-fms` reading `wim.ets.fm, site.ets.fm` yields the origins `https://wim.ets.fm` and
`https://site.ets.fm`.

### 1a. Reading FMS (`--from-fms`)

- Parse `dbs_config.xml` for `<key name="OAuthAllowList" ...>` and
  `<key name="OAuthDomainName" ...>` (a small `perl`/`grep` extraction; the file is plain XML —
  no need to link FMS libraries).
- **Fail loudly when FMS isn't ready:**
  - file missing / unreadable → error: "run this on the FMS host, or pass --dbs-config".
  - `OAuthAllowList` != `1` → error: "FMS OAuth Allow List is disabled — enable it in Admin
    Console → External Authentication → OAuth Allow List before running --from-fms."
  - `OAuthDomainName` empty / no valid hosts → error: "FMS OAuth Allow List is empty — add at least
    one allowed domain in Admin Console first."
  - Non-`--dry-run` runs need root to read `dbs_config.xml` (owned `fmserver:fmsadmin`).
- The extracted, normalized origin set feeds section 2 exactly as a manual set would.

### 2. Map mode — what the script emits

Two coordinated edits, both idempotent and marker-guarded:

**(a) One `map` block in the `http {}` context** (once per file), inserted just after the existing
`map $http_upgrade $connection_upgrade { ... }` block so it sits with the other maps:

```nginx
# BEGIN fms-oauth-cors-allowlist (managed by patch-fms-nginx-cors.sh)
map $http_origin $fms_cors_allow_origin {
    default        "";
    "https://wim.ets.fm"   "https://wim.ets.fm";
    "https://site.ets.fm"  "https://site.ets.fm";
}
# END fms-oauth-cors-allowlist
```

`$fms_cors_allow_origin` echoes the request Origin only when it exactly matches an allowlisted
value, else empty string.

**(b) In each server block**, replace the stock CORS trio with the variable-driven form:

```nginx
# add_header 'Access-Control-Allow-Origin' $hostname;
add_header 'Access-Control-Allow-Origin' $fms_cors_allow_origin always;
add_header 'Access-Control-Allow-Credentials' 'True' always;
# add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';
add_header 'Access-Control-Allow-Headers' 'X-FMS-Application-Version,x-fms-application-type,X-FMS-Return-URL,Origin,Content-Type,Authorization' always;
add_header 'Access-Control-Expose-Headers' 'X-FMS-Request-ID,Content-Type,Authorization,Content-Range' always;
```

Only the ACAO line differs from single-origin mode — it references `$fms_cors_allow_origin`
instead of a literal. When the Origin isn't allowlisted the variable is empty and nginx **omits**
the ACAO header (empty `add_header` value emits nothing), so the browser correctly blocks it —
the desired deny behavior.

> **Note on `add_header` + variables:** nginx evaluates the variable per request, and an empty
> value suppresses the header. This is the documented idiom; no `if` is needed. `always` is kept
> so the header is present on 4xx/5xx too (the 502-masks-CORS pitfall from the CORS doc).

### 3. Idempotency & markers

- The `map` block is wrapped in `# BEGIN/END fms-oauth-cors-allowlist` sentinels. On re-run the
  script **replaces the content between the sentinels** (so changing the origin set is a clean
  update), and inserts the block only if the sentinels are absent.
- State detection extends the current logic (which keys off the stock `$hostname` line and the
  `Expose-Headers` marker) with a third axis: whether ACAO currently reads `$fms_cors_allow_origin`
  vs a literal. This lets the script convert **between** modes (e.g. `*` → map, or map → different
  map) rather than only patching a pristine stock file. The "already configured, no change" fast
  path fires only when the emitted bytes would be identical.

### 4. Validation (extends existing structural checks)

Keep the current gates (brace balance unchanged, exactly 2 patched server blocks, no un-commented
stock ACAO). Add:

- Exactly **one** `map $http_origin $fms_cors_allow_origin` block present after a map-mode edit.
- The set of quoted origins inside the map equals the normalized origin set derived from FMS /
  `--allow-origin` (guards a botched regex edit).
- `--nginx-test` path is unchanged (still opt-in, still feeds the passphrase FIFO).

Brace-balance still holds because the `map { }` block is balanced; the check will move from
29/29 to 30/30 — so the validation compares **against the freshly-generated file's own** open/close
delta expectation, not a hardcoded number (the current script already compares before/after the
edit, but the map insertion adds a pair — update the check to account for the one added block, or
compare parsed structure rather than raw counts).

### 5. Docs

- **`docs/fms-server-cors-config.md`** — new subsection "Allowing multiple web origins" under
  section 1: explain the ACAO single-value limitation, show the `map` block, and document
  `--from-fms` as the recommended path (nginx CORS derived from the Admin Console **OAuth Allow
  List**, `OAuthDomainName` in `/fms/Data/Preferences/dbs_config.xml`). Note the two layers are
  enforced independently (FMS authorizes the return URL; nginx authorizes the browser read), and
  that `--from-fms` keeps them in sync so they can't drift.
- **`README.md`** — in "Server-side setup", add one line: for several sites against one FMS, run
  `--from-fms` (CORS follows the FMS OAuth Allow List) instead of `*`.
- Script header/`--help` — document `--from-fms`, `--allow-origin`, `--dbs-config`, the bare-host
  normalization, and the resolution modes.

## Files touched

- `scripts/patch-fms-nginx-cors.sh` — add `--from-fms` (read `OAuthDomainName`/`OAuthAllowList`
  from `dbs_config.xml`, fail if disabled/empty), `--allow-origin` (repeatable), `--dbs-config`,
  bare-host normalization, mode resolution, `map` block emit/replace with sentinels,
  `$fms_cors_allow_origin` ACAO in both server blocks, extended validation. Single/`*` modes
  unchanged.
- `docs/fms-server-cors-config.md` — "Allowing multiple web origins" subsection.
- `README.md` — one-line pointer in "Server-side setup".

## Verification

1. **Local, no server** — copy a real `dbs_config.xml` to `/tmp` and use `--dbs-config` +
   `--conf /tmp/default_fms_nginx.conf`:
   - `--dry-run --from-fms --dbs-config /tmp/dbs_config.xml` (list enabled, `wim.ets.fm,
     site.ets.fm`) → diff shows the `map` block inserted once in `http{}` with origins
     `https://wim.ets.fm` / `https://site.ets.fm` (bare hosts normalized), and
     `$fms_cors_allow_origin` in **both** server blocks; nothing else changes.
   - `--from-fms` with a copy where `OAuthAllowList` = 0 → aborts with the "enable it in Admin
     Console" error, writes nothing.
   - `--from-fms` with empty `OAuthDomainName` → aborts with the "add at least one domain" error.
   - Manual mode: `--dry-run --allow-origin wim.ets.fm` (bare host) → normalized to
     `https://wim.ets.fm` in the map.
   - Real run, then re-run with unchanged FMS settings → second run is a no-op ("already
     configured"). Change `OAuthDomainName` in the copy, re-run → map updated in place, still one
     block, server blocks unchanged.
   - Back-compat: `--dry-run '*'` and `--dry-run https://wim.ets.fm` produce exactly today's
     single-value output (no map block).
2. **Structure:** `nginx -t` (via `--nginx-test --passphrase …` on the box, once httpserver is up)
   parses the map; brace balance validation passes.
3. **On the box, end-to-end** — `sudo ./patch-fms-nginx-cors.sh --from-fms` against the live
   `dbs_config.xml`, then (once WebDirect is enabled so the endpoint isn't 502):
   ```bash
   for o in https://wim.ets.fm https://site.ets.fm https://evil.example.com; do
     printf '%s -> ' "$o"
     curl -sk -D - -o /dev/null -H "Origin: $o" \
       https://mbp2013.ets.fm/fmi/webd/oauthapi/oauthproviderinfo | grep -i '^access-control-allow-origin' || echo '(none)'
   done
   ```
   Expect the two FMS-allowlisted origins echoed back verbatim, and `evil.example.com` to get
   **no** ACAO header — proving the nginx map matches the FMS `OAuthDomainName` set.

## Resolved decisions (2026-07-12)

- **Match mode — exact host only.** Not a deferral: FMS 26.1.1.15 stores exact hosts only
  (`OAuthDomainName` string + `OAuthAllowList` toggle; no match-mode field — see Context). The
  `allowlistStartsWith`/`allowSubDomains` strings in the FAC bundle are unrelated (AWS SDK / a
  request-path bypass middleware).
- **Read from FMS, fail if unconfigured.** `--from-fms` is the primary mode; it reads
  `dbs_config.xml` and aborts clearly if the OAuth Allow List is disabled or empty rather than
  emitting a permissive config. Keeps the CORS layer and FMS from drifting.
- **Accept bare hosts, assume `https://`.** All origin inputs (FMS-derived, `--allow-origin`,
  positional) are normalized: no-scheme → prefix `https://`; whitespace trimmed; validated;
  de-duplicated.

## Resolved: default mode (2026-07-12)

- **Running the script with no positional and no flags now defaults to `--from-fms`** (was `*`).
  This is an intentional behavior change: the bare invocation prefers the FMS-derived allowlist so
  the CORS layer tracks the Admin Console OAuth Allow List by default. `*` and single-origin remain
  available as explicit positional arguments. Docs and the plan's back-compat goldens account for
  this (the zero-arg golden changes from `*` to the FMS-derived map; explicit `*`/single unchanged).
