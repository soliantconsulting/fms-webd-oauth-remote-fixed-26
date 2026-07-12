#!/usr/bin/env bash
#
# patch-fms-nginx-cors.sh
# -----------------------
# Re-applies the CORS changes this repo's remote OAuth login flow needs to the
# FileMaker Server nginx config. FMS regenerates that config on upgrade (and
# sometimes on restart), which wipes hand edits -- so this script is safe to
# re-run any time the CORS block reverts to stock.
#
# THREE MODES:
#   1. map mode (default) -- derive CORS allowlist from FMS OAuth Allow List
#      or explicit --allow-origin flags; emits an nginx map block that echoes
#      the request Origin only when allowlisted.
#   2. single-origin mode -- one specific static origin (positional arg).
#   3. wildcard mode -- Access-Control-Allow-Origin: * (explicit '*' arg).
#
# WHAT IT CHANGES:
#   In BOTH nginx `server` blocks (listen 80 and listen 443), the stock CORS
#   policy is replaced. The stock lines:
#       add_header 'Access-Control-Allow-Origin' $hostname;
#       add_header 'Access-Control-Allow-Credentials' 'True';
#       add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';
#   become (stock lines commented, not deleted):
#       # add_header 'Access-Control-Allow-Origin' $hostname;
#       add_header 'Access-Control-Allow-Origin' '<VALUE>' always;
#       add_header 'Access-Control-Allow-Credentials' 'True' always;
#       # add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';
#       add_header 'Access-Control-Allow-Headers' 'X-FMS-Application-Version,...' always;
#       add_header 'Access-Control-Expose-Headers' 'X-FMS-Request-ID,...' always;
#   where VALUE is '*', a specific origin, or $fms_cors_allow_origin (map mode).
#
#   In map mode, also inserts a map block after the existing upgrade map:
#       # BEGIN fms-oauth-cors-allowlist (managed by patch-fms-nginx-cors.sh)
#       map $http_origin $fms_cors_allow_origin {
#           default        "";
#           "https://wim.ets.fm"   "https://wim.ets.fm";
#           ...
#       }
#       # END fms-oauth-cors-allowlist
#
# WHAT IT DOES NOT DO:
#   * No SSL certificate / key changes and no port-80 include swap.
#   * No service restart -- the final restart stays a manual step.
#   * The Admin Console "Custom Home URL" setting is a separate manual step.
#
# Run this ON THE FileMaker Server host. See docs/fms-server-cors-config.md.
#
# Usage:
#   sudo ./patch-fms-nginx-cors.sh [ORIGIN] [--from-fms] [--allow-origin HOST]...
#        [--dbs-config PATH] [--conf PATH] [--dry-run] [--nginx-test] [--passphrase P]
#
#   ORIGIN          Single origin or '*' (wildcard). Omit for map mode via --from-fms.
#   --from-fms      Read the OAuth Allow List from FMS (OAuthDomainName in dbs_config.xml)
#                   and generate a CORS map. This is the default when no args given.
#   --allow-origin HOST   Add a host/origin to the map (repeatable). Bare hosts are
#                   normalized to https://<host>. Can be combined with --from-fms.
#   --dbs-config PATH   Override FMS prefs path (default /fms/Data/Preferences/dbs_config.xml).
#   --conf PATH     Override nginx conf path (default: FMS install path below).
#   --dry-run       Show a diff of the intended change and exit; no writes.
#   --nginx-test    After patching, run `nginx -t -c <conf>` as a syntax check.
#   --passphrase P  SSL certificate key passphrase for --nginx-test. May also be set
#                   via $FMS_SSL_PASSPHRASE. This is the passphrase for whichever
#                   cert FMS is using (built-in self-signed if no custom cert).
#                   Pass an EMPTY string (--passphrase '') when the SSL key has no
#                   passphrase (e.g. a deployed custom cert) -- the script feeds an
#                   empty line to the FIFO so nginx -t proceeds. This is distinct
#                   from OMITTING the flag, which skips the check when the FIFO
#                   would otherwise block.
#   -h, --help      This help.
#
# Resolution rules:
#   - No positional and no flags -> --from-fms (map mode, FMS-derived).
#   - --from-fms or >=1 --allow-origin -> map mode (union both sources).
#   - positional '*' -> wildcard mode (explicit opt-in).
#   - positional specific origin -> single-origin mode.
#
# Origin normalization:
#   All host inputs (FMS-derived, --allow-origin, positional) are normalized:
#   trim whitespace; if no ://, prefix https://; validate against
#   ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$; deduplicate.

set -euo pipefail

DEFAULT_CONF="/opt/FileMaker/FileMaker Server/NginxServer/conf/fms_nginx.conf"
DEFAULT_DBS_CONFIG="/fms/Data/Preferences/dbs_config.xml"

# ---- defaults / arg parsing -------------------------------------------------
ORIGIN=""
CONF="$DEFAULT_CONF"
DBS_CONFIG="$DEFAULT_DBS_CONFIG"
DRY_RUN=0
NGINX_TEST=0
PASSPHRASE="${FMS_SSL_PASSPHRASE:-}"
# PASSPHRASE_SET tracks whether a passphrase was PROVIDED at all (even an empty
# string counts). This is distinct from PASSPHRASE being empty: an empty
# passphrase means "the SSL key has no passphrase -- feed an empty line to the
# FIFO", whereas not-provided means "skip the nginx -t check". Use the ${VAR+x}
# form so a set-but-empty $FMS_SSL_PASSPHRASE counts as provided.
PASSPHRASE_SET=0
if [ -n "${FMS_SSL_PASSPHRASE+x}" ]; then
	PASSPHRASE_SET=1
fi
FROM_FMS=0
ALLOW_ORIGINS=()
origin_set=0

usage() {
	# Print the header comment block (everything up to the first blank line
	# after the shebang) as help text.
	sed -n '2,/^$/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

# ---- helper functions -------------------------------------------------------

# Decide what the --nginx-test path should do, given whether the discovered
# ssl_password_file is a FIFO and whether a passphrase was provided at all.
# Prints exactly one of: skip | feed | direct
#   skip   -- FIFO present but no passphrase provided; nginx -t would block.
#   feed   -- FIFO present and a passphrase was provided (empty counts, meaning
#             "no-passphrase key -- feed an empty line").
#   direct -- not a FIFO (plain file or none); nginx -t won't block.
nginx_test_action() {
	local is_fifo="$1"        # 1 if ssl_password_file is a FIFO, else 0
	local passphrase_set="$2" # 1 if --passphrase / $FMS_SSL_PASSPHRASE provided
	if [ "$is_fifo" -eq 1 ] && [ "$passphrase_set" -eq 0 ]; then
		echo "skip"
	elif [ "$is_fifo" -eq 1 ]; then
		echo "feed"
	else
		echo "direct"
	fi
}

normalize_origin() {
	local raw="$1"
	# Trim whitespace
	raw=$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	# If no scheme, prepend https://
	if ! echo "$raw" | grep -qE '^https?://'; then
		raw="https://$raw"
	fi
	# Validate
	if ! echo "$raw" | grep -qE '^https?://[A-Za-z0-9.-]+(:[0-9]+)?$'; then
		echo "ERROR: invalid origin: $raw" >&2
		return 1
	fi
	echo "$raw"
}

read_fms_allowlist() {
	local dbs_path="$1"
	if [ ! -f "$dbs_path" ]; then
		echo "ERROR: dbs_config.xml not found: $dbs_path" >&2
		echo "       Run this on the FMS host, or pass --dbs-config PATH." >&2
		return 1
	fi

	# Extract OAuthAllowList and OAuthDomainName. FMS's dbs_config.xml uses BOTH
	# attribute orderings -- oAuthProviders keys are type-first, Preferences keys
	# are name-first -- so match name="..." in either position ([^>]* spans any
	# other attributes, before or after).
	local allow_list
	local domain_name
	allow_list=$(perl -ne 'print $1 if /<key[^>]*\bname="OAuthAllowList"[^>]*>([^<]*)<\/key>/' "$dbs_path" || true)
	domain_name=$(perl -ne 'print $1 if /<key[^>]*\bname="OAuthDomainName"[^>]*>([^<]*)<\/key>/' "$dbs_path" || true)

	if [ "$allow_list" != "1" ]; then
		echo "ERROR: FMS OAuth Allow List is disabled (OAuthAllowList != 1)." >&2
		echo "       Enable it in Admin Console -> External Authentication -> OAuth Allow List" >&2
		echo "       before running --from-fms." >&2
		return 1
	fi

	if [ -z "$domain_name" ]; then
		echo "ERROR: FMS OAuth Allow List is empty (OAuthDomainName is empty)." >&2
		echo "       Add at least one allowed domain in Admin Console first." >&2
		return 1
	fi

	# Split on comma, trim, output one per line
	echo "$domain_name" | tr ',' '\n' | while IFS= read -r host; do
		host=$(echo "$host" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		if [ -n "$host" ]; then
			echo "$host"
		fi
	done
}

revert_to_stock() {
	local src="$1"
	# Revert any patched CORS blocks to pristine stock
	perl -0777 -pe '
		# Re-activate commented stock ACAO
		s/^(\s*)# add_header '\''Access-Control-Allow-Origin'\'' \$hostname;$/$1add_header '\''Access-Control-Allow-Origin'\'' \$hostname;/gm;

		# Remove our custom ACAO (literal or variable)
		s/^(\s*)add_header '\''Access-Control-Allow-Origin'\'' (?:'\''[^'\'']*'\''|\$fms_cors_allow_origin) always;\n//gm;

		# Revert Allow-Credentials: remove "always"
		s/^(\s*)add_header '\''Access-Control-Allow-Credentials'\'' '\''True'\'' always;$/$1add_header '\''Access-Control-Allow-Credentials'\'' '\''True'\'';/gm;

		# Re-activate commented stock Allow-Headers
		s/^(\s*)# add_header '\''Access-Control-Allow-Headers'\'' '\''Content-Type,Authorization'\'';$/$1add_header '\''Access-Control-Allow-Headers'\'' '\''Content-Type,Authorization'\'';/gm;

		# Remove our expanded Allow-Headers
		s/^(\s*)add_header '\''Access-Control-Allow-Headers'\'' '\''X-FMS-Application-Version,x-fms-application-type,X-FMS-Return-URL,Origin,Content-Type,Authorization'\'' always;\n//gm;

		# Remove our Expose-Headers
		s/^(\s*)add_header '\''Access-Control-Expose-Headers'\'' '\''X-FMS-Request-ID,Content-Type,Authorization,Content-Range'\'' always;\n//gm;

		# Remove map block (including sentinels and surrounding blank lines)
		s/\n# BEGIN fms-oauth-cors-allowlist \(managed by patch-fms-nginx-cors\.sh\)\nmap \$http_origin \$fms_cors_allow_origin \{[^}]+\}\n# END fms-oauth-cors-allowlist\n/\n/gs;
	' "$src"
}

render_map_block() {
	# Args: list of normalized origins
	local origins=("$@")
	echo "# BEGIN fms-oauth-cors-allowlist (managed by patch-fms-nginx-cors.sh)"
	echo "map \$http_origin \$fms_cors_allow_origin {"
	echo "    default        \"\";"
	for origin in "${origins[@]}"; do
		echo "    \"$origin\"   \"$origin\";"
	done
	echo "}"
	echo "# END fms-oauth-cors-allowlist"
}

apply_server_block() {
	local src="$1"
	local acao_value="$2"
	# From pristine stock, comment stock trio and insert our four always lines
	ACAO_VALUE="$acao_value" perl -pe '
		BEGIN { $o = $ENV{ACAO_VALUE}; }
		if (/^(\s*)add_header '\''Access-Control-Allow-Origin'\'' \$hostname;\s*$/) {
			my $ws = $1;
			$_ = "${ws}# add_header '\''Access-Control-Allow-Origin'\'' \$hostname;\n"
			   . "${ws}add_header '\''Access-Control-Allow-Origin'\'' $o always;\n";
			next;
		}
		if (/^(\s*)add_header '\''Access-Control-Allow-Credentials'\'' '\''True'\'';\s*$/) {
			$_ = "$1add_header '\''Access-Control-Allow-Credentials'\'' '\''True'\'' always;\n";
			next;
		}
		if (/^(\s*)add_header '\''Access-Control-Allow-Headers'\'' '\''Content-Type,Authorization'\'';\s*$/) {
			my $ws = $1;
			$_ = "${ws}# add_header '\''Access-Control-Allow-Headers'\'' '\''Content-Type,Authorization'\'';\n"
			   . "${ws}add_header '\''Access-Control-Allow-Headers'\'' '\''X-FMS-Application-Version,x-fms-application-type,X-FMS-Return-URL,Origin,Content-Type,Authorization'\'' always;\n"
			   . "${ws}add_header '\''Access-Control-Expose-Headers'\'' '\''X-FMS-Request-ID,Content-Type,Authorization,Content-Range'\'' always;\n";
			next;
		}
	' "$src"
}

apply_map_block() {
	local src="$1"
	shift
	local origins=("$@")
	# Insert map block after the upgrade map
	local map_text
	map_text=$(render_map_block "${origins[@]}")

	MAP_TEXT="$map_text" perl -0777 -pe '
		BEGIN { $map = $ENV{MAP_TEXT}; }
		# Insert after the upgrade map block (map_text already has trailing newline)
		s/(map \$http_upgrade \$connection_upgrade \{[^}]+\}\n)/$1\n$map/s;
	' "$src"
}

generate_output() {
	local src="$1"
	local mode="$2"
	local acao_arg="$3"
	shift 3
	local origins=("$@")

	# Step 1: revert to stock
	local reverted
	reverted=$(revert_to_stock "$src")

	# Step 2: apply server block changes
	local acao_value
	if [ "$mode" = "wildcard" ]; then
		acao_value="'*'"
	elif [ "$mode" = "single" ]; then
		acao_value="'$acao_arg'"
	else
		# map mode
		acao_value="\$fms_cors_allow_origin"
	fi

	local with_server
	with_server=$(echo "$reverted" | apply_server_block /dev/stdin "$acao_value")

	# Step 3: apply map block if map mode
	if [ "$mode" = "map" ]; then
		echo "$with_server" | apply_map_block /dev/stdin "${origins[@]}"
	else
		echo "$with_server"
	fi
}

# ---- lib mode guard ---------------------------------------------------------
# When sourced with PATCH_CORS_LIB=1, stop here so the test can call functions
if [ "${PATCH_CORS_LIB:-0}" = "1" ]; then
	return 0 2>/dev/null || exit 0
fi

# ---- arg parsing ------------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
		--from-fms)
			FROM_FMS=1; shift ;;
		--allow-origin)
			[ $# -ge 2 ] || { echo "ERROR: --allow-origin needs a value" >&2; exit 2; }
			ALLOW_ORIGINS+=("$2"); shift 2 ;;
		--allow-origin=*)
			ALLOW_ORIGINS+=("${1#*=}"); shift ;;
		--dbs-config)
			[ $# -ge 2 ] || { echo "ERROR: --dbs-config needs a path" >&2; exit 2; }
			DBS_CONFIG="$2"; shift 2 ;;
		--dbs-config=*)
			DBS_CONFIG="${1#*=}"; shift ;;
		--conf)
			[ $# -ge 2 ] || { echo "ERROR: --conf needs a path" >&2; exit 2; }
			CONF="$2"; shift 2 ;;
		--conf=*)
			CONF="${1#*=}"; shift ;;
		--dry-run)
			DRY_RUN=1; shift ;;
		--nginx-test)
			NGINX_TEST=1; shift ;;
		--passphrase)
			[ $# -ge 2 ] || { echo "ERROR: --passphrase needs a value" >&2; exit 2; }
			PASSPHRASE="$2"; PASSPHRASE_SET=1; shift 2 ;;
		--passphrase=*)
			PASSPHRASE="${1#*=}"; PASSPHRASE_SET=1; shift ;;
		-h|--help)
			usage; exit 0 ;;
		--)
			shift; break ;;
		-*)
			echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
		*)
			if [ "$origin_set" -eq 1 ]; then
				echo "ERROR: unexpected extra argument: $1" >&2; exit 2
			fi
			ORIGIN="$1"; origin_set=1; shift ;;
	esac
done

# ---- mode resolution --------------------------------------------------------

MODE=""
ORIGIN_SET=()

# Default: no positional and no flags -> --from-fms
if [ -z "$ORIGIN" ] && [ "$FROM_FMS" -eq 0 ] && [ ${#ALLOW_ORIGINS[@]} -eq 0 ]; then
	FROM_FMS=1
fi

# Map mode: --from-fms or >=1 --allow-origin
if [ "$FROM_FMS" -eq 1 ] || [ ${#ALLOW_ORIGINS[@]} -gt 0 ]; then
	MODE="map"

	# Warn if positional given alongside
	if [ -n "$ORIGIN" ]; then
		echo "WARNING: positional origin '$ORIGIN' ignored in map mode (--from-fms or --allow-origin)" >&2
	fi

	# Collect origins
	if [ "$FROM_FMS" -eq 1 ]; then
		# Must be done here before file operations, so we can fail early if FMS not configured
		FMS_HOSTS=$(read_fms_allowlist "$DBS_CONFIG") || exit $?
		while IFS= read -r host; do
			[ -z "$host" ] && continue
			normalized=$(normalize_origin "$host")
			ORIGIN_SET+=("$normalized")
		done <<< "$FMS_HOSTS"
	fi

	if [ ${#ALLOW_ORIGINS[@]} -gt 0 ]; then
		for raw in "${ALLOW_ORIGINS[@]}"; do
			normalized=$(normalize_origin "$raw")
			ORIGIN_SET+=("$normalized")
		done
	fi

	# Deduplicate and sort
	IFS=$'\n' ORIGIN_SET=($(printf '%s\n' "${ORIGIN_SET[@]}" | sort -u))
	unset IFS

	if [ ${#ORIGIN_SET[@]} -eq 0 ]; then
		echo "ERROR: map mode requires at least one origin" >&2
		exit 1
	fi

elif [ "$ORIGIN" = "*" ]; then
	MODE="wildcard"
elif [ -n "$ORIGIN" ]; then
	MODE="single"
	ORIGIN=$(normalize_origin "$ORIGIN")
else
	echo "ERROR: no origin specified" >&2
	usage >&2
	exit 2
fi

# ---- preflight --------------------------------------------------------------

if [ ! -f "$CONF" ]; then
	echo "ERROR: conf file not found: $CONF" >&2
	echo "       Run this on the FileMaker Server host, or pass --conf PATH." >&2
	exit 1
fi

if [ "$DRY_RUN" -eq 0 ] && [ ! -w "$CONF" ]; then
	echo "ERROR: no write permission on: $CONF" >&2
	echo "       Re-run with sudo." >&2
	exit 1
fi

# ---- sanity: recognized state -----------------------------------------------

STOCK_RE="^[[:space:]]*add_header 'Access-Control-Allow-Origin' \\\$hostname;"
DONE_MARKER="Access-Control-Expose-Headers' 'X-FMS-Request-ID"

stock_count=$(grep -cE "$STOCK_RE" "$CONF" || true)
done_count=$(grep -cF "$DONE_MARKER" "$CONF" || true)

# Must be either pristine stock (2 stock ACAO) or already managed (>= 1 Expose-Headers)
if [ "$stock_count" -ne 2 ] && [ "$done_count" -lt 1 ]; then
	echo "ERROR: unrecognized conf state (neither stock nor managed)" >&2
	echo "       Expected 2 stock CORS blocks or managed Expose-Headers marker." >&2
	echo "       Found stock=$stock_count, done=$done_count in: $CONF" >&2
	echo "       This may be a different FMS version -- inspect manually." >&2
	exit 1
fi

# ---- generate target and check idempotency ----------------------------------

GEN=$(mktemp "${TMPDIR:-/tmp}/fms_nginx_gen.XXXXXX")
trap 'rm -f "$GEN"' EXIT

if [ "$MODE" = "map" ]; then
	generate_output "$CONF" map "" "${ORIGIN_SET[@]}" > "$GEN"
elif [ "$MODE" = "single" ]; then
	generate_output "$CONF" single "$ORIGIN" > "$GEN"
else
	generate_output "$CONF" wildcard "*" > "$GEN"
fi

# Idempotency: if generated equals current, nothing to do
if cmp -s "$GEN" "$CONF"; then
	prefix=""; [ "$DRY_RUN" -eq 1 ] && prefix="(dry-run) "
	echo "${prefix}Already configured for $MODE mode; nothing to do."
	[ "$MODE" = "map" ] && echo "Origins: ${ORIGIN_SET[*]}"
	exit 0
fi

# ---- dry run: show diff and exit --------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
	echo "(dry-run) Proposed change to: $CONF"
	echo "(dry-run) Mode: $MODE"
	if [ "$MODE" = "map" ]; then
		echo "(dry-run) Origins: ${ORIGIN_SET[*]}"
	elif [ "$MODE" = "single" ]; then
		echo "(dry-run) Origin: $ORIGIN"
	else
		echo "(dry-run) Origin: *"
	fi
	echo
	# diff exits 1 when files differ -- expected, so don't let set -e abort
	diff -u "$CONF" "$GEN" || true
	exit 0
fi

# ---- backup -----------------------------------------------------------------

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$CONF.bak.$STAMP"
cp -p "$CONF" "$BACKUP"
echo "Backup written: $BACKUP"

# ---- validate ---------------------------------------------------------------

fail_restore() {
	echo "ERROR: $1" >&2
	echo "       Restoring original from backup; conf left unchanged." >&2
	mv "$BACKUP" "$CONF"
	exit 1
}

# Compute expected brace delta from mode
BRACE_DELTA=0
if [ "$MODE" = "map" ]; then
	BRACE_DELTA=1  # one map block adds one pair
fi

# Revert the original to stock as baseline
BASELINE=$(mktemp "${TMPDIR:-/tmp}/fms_nginx_baseline.XXXXXX")
trap 'rm -f "$GEN" "$BASELINE"' EXIT
revert_to_stock "$CONF" > "$BASELINE"

braces_base=$(tr -cd '{' < "$BASELINE" | wc -c | tr -d ' ')
braces_base_close=$(tr -cd '}' < "$BASELINE" | wc -c | tr -d ' ')
braces_gen=$(tr -cd '{' < "$GEN" | wc -c | tr -d ' ')
braces_gen_close=$(tr -cd '}' < "$GEN" | wc -c | tr -d ' ')

expected_open=$((braces_base + BRACE_DELTA))
expected_close=$((braces_base_close + BRACE_DELTA))

if [ "$braces_gen" != "$expected_open" ] || [ "$braces_gen_close" != "$expected_close" ]; then
	fail_restore "brace count mismatch ({ expected $expected_open got $braces_gen, } expected $expected_close got $braces_gen_close)"
fi

# Exactly two Expose-Headers lines
new_done=$(grep -cF "$DONE_MARKER" "$GEN" || true)
if [ "$new_done" -ne 2 ]; then
	fail_restore "expected 2 patched CORS blocks after edit, got $new_done"
fi

# No stock Allow-Origin lines left uncommented
remaining_stock=$(grep -cE "^[[:space:]]*add_header 'Access-Control-Allow-Origin' \\\$hostname;" "$GEN" || true)
if [ "$remaining_stock" -ne 0 ]; then
	fail_restore "found $remaining_stock un-commented stock Allow-Origin line(s) after edit"
fi

# Mode-specific validation
if [ "$MODE" = "map" ]; then
	# Exactly one map block
	map_count=$(grep -c "# BEGIN fms-oauth-cors-allowlist" "$GEN" || true)
	if [ "$map_count" -ne 1 ]; then
		fail_restore "expected 1 map block in map mode, found $map_count"
	fi

	# Quoted origins in map match ORIGIN_SET
	for origin in "${ORIGIN_SET[@]}"; do
		if ! grep -qF "\"$origin\"" "$GEN"; then
			fail_restore "map missing expected origin: $origin"
		fi
	done

	# Both server blocks use variable
	acao_var_count=$(grep -c 'Access-Control-Allow-Origin.*\$fms_cors_allow_origin' "$GEN" || true)
	if [ "$acao_var_count" -ne 2 ]; then
		fail_restore "expected ACAO to use \$fms_cors_allow_origin in 2 blocks, found $acao_var_count"
	fi
else
	# Non-map: no map block should remain
	if grep -q "# BEGIN fms-oauth-cors-allowlist" "$GEN"; then
		fail_restore "map block present in non-map mode"
	fi
fi

# ---- commit -----------------------------------------------------------------

mv "$GEN" "$CONF"
echo "Patched $new_done CORS block(s) in: $CONF"
if [ "$MODE" = "map" ]; then
	echo "Mode: map (${#ORIGIN_SET[@]} origins)"
	for origin in "${ORIGIN_SET[@]}"; do
		echo "  - $origin"
	done
elif [ "$MODE" = "single" ]; then
	echo "Mode: single-origin"
	echo "Access-Control-Allow-Origin: $ORIGIN"
else
	echo "Mode: wildcard"
	echo "Access-Control-Allow-Origin: *"
fi

# ---- optional nginx syntax check -------------------------------------------

run_nginx_t() {
	if command -v timeout >/dev/null 2>&1; then
		timeout 30 nginx -t -c "$CONF"
	else
		nginx -t -c "$CONF"
	fi
}

if [ "$NGINX_TEST" -eq 1 ]; then
	echo
	if ! command -v nginx >/dev/null 2>&1; then
		echo "(--nginx-test: nginx not on PATH; skipping. Run the check manually -- see next steps.)"
	else
		# Discover the passphrase FIFO nginx will read from this conf
		PW_FILE=$(perl -ne 'print $1 if /^\s*ssl_password_file\s+"?([^";]+)"?\s*;/' "$CONF" | head -1)

		is_fifo=0
		[ -n "$PW_FILE" ] && [ -p "$PW_FILE" ] && is_fifo=1
		action=$(nginx_test_action "$is_fifo" "$PASSPHRASE_SET")

		if [ "$action" = "skip" ]; then
			# FIFO exists but no passphrase was provided at all -- nginx -t would
			# block. Skip. (To drive a no-passphrase key, pass --passphrase '' so
			# an empty line is fed to the FIFO.)
			echo "(--nginx-test: the SSL passphrase file is a FIFO and no passphrase was"
			echo " given, so nginx -t would block. Skipping. Pass --passphrase /"
			echo " \$FMS_SSL_PASSPHRASE (use --passphrase '' if the key has no"
			echo " passphrase), or run the manual command in the next steps.)"
		elif [ "$action" = "feed" ]; then
			# Passphrase was provided (possibly empty). Feed it to the FIFO -- an
			# empty PASSPHRASE writes just a newline, which is what a no-passphrase
			# key (e.g. a deployed custom cert) expects.
			echo "Running nginx syntax check (feeding the SSL passphrase FIFO)..."
			( printf '%s\n' "$PASSPHRASE" > "$PW_FILE" ) &
			writer_pid=$!
			run_nginx_t || \
				echo "(nginx -t did not confirm -- re-run manually once httpserver is up; see next steps)"
			kill "$writer_pid" 2>/dev/null || true
			wait "$writer_pid" 2>/dev/null || true
		else
			# direct: not a FIFO (plain passphrase file, or none) -- won't block.
			echo "Running nginx syntax check..."
			run_nginx_t || \
				echo "(nginx -t did not confirm -- re-run manually once httpserver is up; see next steps)"
		fi
	fi
fi

# ---- next steps -------------------------------------------------------------

PW_FILE=$(perl -ne 'print $1 if /^\s*ssl_password_file\s+"?([^";]+)"?\s*;/' "$CONF" | head -1)
: "${PW_FILE:=/opt/FileMaker/FileMaker Server/CStore/.passphrase}"

cat <<NEXT

Done. To finish (these are NOT automated on purpose):

  # 1. Verify syntax. nginx reads the key passphrase from a FIFO, so a bare
  #    'nginx -t' HANGS -- feed the passphrase into the FIFO in the background
  #    first (use the passphrase for whichever cert FMS is using):
  ( printf '%s\n' 'YOUR_SSL_PASSPHRASE' > "$PW_FILE" ) & \\
    sudo nginx -t -c "$CONF"
  #    If the key has NO passphrase (e.g. a deployed custom cert), feed an
  #    empty line instead:
  ( printf '\\n' > "$PW_FILE" ) & \\
    sudo nginx -t -c "$CONF"

  # 2. Apply (needs FMS admin-console credentials):
  fmsadmin restart httpserver

  # 3. Separately, in the FMS Admin Console: Connectors -> Web Publishing ->
  #    Claris FileMaker WebDirect -> Custom Home URL = https://<webDNS>
  #    (see docs/fms-server-cors-config.md section 2 -- not done by this script)
NEXT

if [ "$MODE" = "map" ]; then
	cat <<MAP_NOTE

  Note: In map mode, the nginx CORS allowlist now mirrors the FMS OAuth Allow List.
  If you change allowed domains in Admin Console, re-run this script with --from-fms
  to update the nginx config to match.
MAP_NOTE
fi
