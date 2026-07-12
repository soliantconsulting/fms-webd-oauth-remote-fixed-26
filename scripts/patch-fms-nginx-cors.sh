#!/usr/bin/env bash
#
# patch-fms-nginx-cors.sh
# -----------------------
# Re-applies the CORS changes this repo's remote OAuth login flow needs to the
# FileMaker Server nginx config. FMS regenerates that config on upgrade (and
# sometimes on restart), which wipes hand edits -- so this script is safe to
# re-run any time the CORS block reverts to stock.
#
# WHAT IT CHANGES (and only this):
#   In BOTH nginx `server` blocks (listen 80 and listen 443), the stock CORS
#   policy
#       add_header 'Access-Control-Allow-Origin' $hostname;
#       add_header 'Access-Control-Allow-Credentials' 'True';
#       add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';
#   is replaced with (stock lines commented out, not deleted):
#       # add_header 'Access-Control-Allow-Origin' $hostname;
#       add_header 'Access-Control-Allow-Origin' '<ORIGIN>' always;
#       add_header 'Access-Control-Allow-Credentials' 'True' always;
#       # add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';
#       add_header 'Access-Control-Allow-Headers' 'X-FMS-Application-Version,x-fms-application-type,X-FMS-Return-URL,Origin,Content-Type,Authorization' always;
#       add_header 'Access-Control-Expose-Headers' 'X-FMS-Request-ID,Content-Type,Authorization,Content-Range' always;
#
# WHAT IT DOES NOT DO:
#   * No SSL certificate / key changes and no port-80 include swap -- those are
#     environment-specific (custom cert) and unrelated to this repo's function.
#   * No service restart -- `fmsadmin` needs FMS admin-console credentials, so
#     the final restart stays a manual step (printed at the end).
#   * The Admin Console "Custom Home URL" setting (section 2 of the CORS doc) is
#     a separate manual step this script does not touch.
#
# Run this ON THE FileMaker Server host. See docs/fms-server-cors-config.md for
# the full manual procedure and the reasoning behind each change.
#
# Usage:
#   sudo ./patch-fms-nginx-cors.sh [ORIGIN] [--conf PATH] [--dry-run] [--nginx-test]
#
#   ORIGIN         Value for Access-Control-Allow-Origin. Default: *
#                  For production pass your web origin, e.g. https://wim.ets.fm
#   --conf PATH    Override the conf path (default: the FMS install path below).
#   --dry-run      Show a unified diff of the intended change and exit; no writes.
#   --nginx-test   After patching, run `nginx -t -c <conf>` as a syntax check.
#                  nginx reads the SSL key passphrase from a named pipe (FIFO)
#                  at `ssl_password_file`, so `nginx -t` BLOCKS unless a
#                  passphrase is written to that FIFO in the background first.
#                  Supply it via --passphrase / $FMS_SSL_PASSPHRASE and the
#                  script feeds the FIFO for you; without a passphrase the check
#                  is skipped and the exact manual command is printed instead.
#   --passphrase P The SSL certificate key passphrase, used only to feed the
#                  FIFO for --nginx-test. May also be given via the
#                  $FMS_SSL_PASSPHRASE environment variable. This is the
#                  passphrase for whichever cert FMS is using -- the built-in
#                  self-signed cert if you have not installed a custom one.
#   -h, --help     This help.

set -euo pipefail

DEFAULT_CONF="/opt/FileMaker/FileMaker Server/NginxServer/conf/fms_nginx.conf"

# ---- defaults / arg parsing -------------------------------------------------
ORIGIN="*"
CONF="$DEFAULT_CONF"
DRY_RUN=0
NGINX_TEST=0
PASSPHRASE="${FMS_SSL_PASSPHRASE:-}"
origin_set=0

usage() {
	# Print the header comment block (everything up to the first blank line
	# after the shebang) as help text.
	sed -n '2,/^$/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case "$1" in
		--conf)
			[ $# -ge 2 ] || { echo "ERROR: --conf needs a path" >&2; exit 2; }
			CONF="$2"; shift 2 ;;
		--conf=*)   CONF="${1#*=}"; shift ;;
		--dry-run)  DRY_RUN=1; shift ;;
		--nginx-test) NGINX_TEST=1; shift ;;
		--passphrase)
			[ $# -ge 2 ] || { echo "ERROR: --passphrase needs a value" >&2; exit 2; }
			PASSPHRASE="$2"; shift 2 ;;
		--passphrase=*) PASSPHRASE="${1#*=}"; shift ;;
		-h|--help)  usage; exit 0 ;;
		--) shift; break ;;
		-*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
		*)
			if [ "$origin_set" -eq 1 ]; then
				echo "ERROR: unexpected extra argument: $1" >&2; exit 2
			fi
			ORIGIN="$1"; origin_set=1; shift ;;
	esac
done

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

# Markers used for state detection.
#   STOCK_RE  anchors to optional leading whitespace + `add_header` so an
#             already-commented (`# add_header ...`) line does NOT count -- this
#             is what makes re-runs idempotent rather than re-patching.
STOCK_RE="^[[:space:]]*add_header 'Access-Control-Allow-Origin' \\\$hostname;"
DONE_MARKER="Access-Control-Expose-Headers' 'X-FMS-Request-ID"

done_count=$(grep -cF "$DONE_MARKER" "$CONF" || true)
stock_count=$(grep -cE "$STOCK_RE" "$CONF" || true)

# ---- idempotency: already patched ------------------------------------------
if [ "$done_count" -ge 1 ] && [ "$stock_count" -eq 0 ]; then
	prefix=""; [ "$DRY_RUN" -eq 1 ] && prefix="(dry-run) "
	echo "${prefix}Already configured: found $done_count patched CORS block(s); nothing to do."
	exit 0
fi

# ---- sanity: expect exactly the two stock CORS blocks ----------------------
# (Skip this guard if the file is already fully patched -- handled above.)
if [ "$stock_count" -ne 2 ]; then
	echo "ERROR: expected 2 stock CORS blocks (marker: Access-Control-Allow-Origin \$hostname)," >&2
	echo "       but found $stock_count in: $CONF" >&2
	if [ "$done_count" -ge 1 ]; then
		echo "       The file appears partially patched -- inspect it manually." >&2
	else
		echo "       The conf may be a different FMS version -- inspect it manually." >&2
	fi
	exit 1
fi

# ---- the transform ----------------------------------------------------------
# perl program in a single-quoted heredoc so neither the shell nor perl touch
# the literal nginx text ($hostname stays literal). ORIGIN comes in via env.
read -r -d '' PERL_PROG <<'PERL' || true
BEGIN { $o = $ENV{ORIGIN}; }
if (/^(\s*)add_header 'Access-Control-Allow-Origin' \$hostname;\s*$/) {
	my $ws = $1;
	$_ = "${ws}# add_header 'Access-Control-Allow-Origin' \$hostname;\n"
	   . "${ws}add_header 'Access-Control-Allow-Origin' '$o' always;\n";
	next;
}
if (/^(\s*)add_header 'Access-Control-Allow-Credentials' 'True';\s*$/) {
	$_ = "$1add_header 'Access-Control-Allow-Credentials' 'True' always;\n";
	next;
}
if (/^(\s*)add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';\s*$/) {
	my $ws = $1;
	$_ = "${ws}# add_header 'Access-Control-Allow-Headers' 'Content-Type,Authorization';\n"
	   . "${ws}add_header 'Access-Control-Allow-Headers' 'X-FMS-Application-Version,x-fms-application-type,X-FMS-Return-URL,Origin,Content-Type,Authorization' always;\n"
	   . "${ws}add_header 'Access-Control-Expose-Headers' 'X-FMS-Request-ID,Content-Type,Authorization,Content-Range' always;\n";
	next;
}
PERL

# ---- dry run: show diff and exit -------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
	echo "(dry-run) Proposed change to: $CONF"
	echo "(dry-run) Access-Control-Allow-Origin => '$ORIGIN'"
	echo
	# Preview file goes in a writable temp dir, not next to $CONF -- a dry-run
	# must not require write access to the (root-owned) conf directory.
	PREVIEW=$(mktemp "${TMPDIR:-/tmp}/fms_nginx_preview.XXXXXX")
	ORIGIN="$ORIGIN" perl -pe "$PERL_PROG" "$CONF" > "$PREVIEW"
	# diff exits 1 when files differ -- expected, so don't let set -e abort.
	diff -u "$CONF" "$PREVIEW" || true
	rm -f "$PREVIEW"
	exit 0
fi

# ---- backup -----------------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$CONF.bak.$STAMP"
cp -p "$CONF" "$BACKUP"
echo "Backup written: $BACKUP"

# ---- apply ------------------------------------------------------------------
TMP="$CONF.patched.$$"
ORIGIN="$ORIGIN" perl -pe "$PERL_PROG" "$CONF" > "$TMP"

# ---- validate (deterministic, no cert/passphrase needed) -------------------
fail_restore() {
	echo "ERROR: $1" >&2
	echo "       Restoring original from backup; conf left unchanged." >&2
	rm -f "$TMP"
	exit 1
}

# 1. brace balance must be unchanged vs. the backup
braces_before=$(tr -cd '{' < "$BACKUP" | wc -c | tr -d ' ')
braces_before_close=$(tr -cd '}' < "$BACKUP" | wc -c | tr -d ' ')
braces_after=$(tr -cd '{' < "$TMP" | wc -c | tr -d ' ')
braces_after_close=$(tr -cd '}' < "$TMP" | wc -c | tr -d ' ')
if [ "$braces_before" != "$braces_after" ] || [ "$braces_before_close" != "$braces_after_close" ]; then
	fail_restore "brace count changed ({ $braces_before->$braces_after, } $braces_before_close->$braces_after_close)"
fi

# 2. exactly two Expose-Headers lines now present
new_done=$(grep -cF "$DONE_MARKER" "$TMP" || true)
if [ "$new_done" -ne 2 ]; then
	fail_restore "expected 2 patched CORS blocks after edit, got $new_done"
fi

# 3. no stock Allow-Origin lines left uncommented
remaining_stock=$(grep -cE "^[[:space:]]*add_header 'Access-Control-Allow-Origin' \\\$hostname;" "$TMP" || true)
if [ "$remaining_stock" -ne 0 ]; then
	fail_restore "found $remaining_stock un-commented stock Allow-Origin line(s) after edit"
fi

# ---- commit -----------------------------------------------------------------
mv "$TMP" "$CONF"
echo "Patched $new_done CORS block(s) in: $CONF"
echo "Access-Control-Allow-Origin set to: '$ORIGIN'"

# ---- optional nginx syntax check -------------------------------------------
# nginx reads the SSL key passphrase from `ssl_password_file`, which on FMS is a
# named pipe (FIFO). `nginx -t` opens that file and BLOCKS until something
# writes the passphrase to it -- so a bare `nginx -t` hangs forever. The correct
# pattern is to background a writer that feeds the passphrase into the FIFO,
# then run `nginx -t`. See docs/fms-server-cors-config.md.
# Run `nginx -t`, bounded by `timeout` when that command is available (it is on
# Linux; not on stock macOS). Never gates the patch's success.
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
		# Discover the passphrase FIFO nginx will read from this conf.
		PW_FILE=$(perl -ne 'print $1 if /^\s*ssl_password_file\s+"?([^";]+)"?\s*;/' "$CONF" | head -1)

		if [ -n "$PW_FILE" ] && [ -p "$PW_FILE" ] && [ -z "$PASSPHRASE" ]; then
			# FIFO passphrase file + no passphrase => nginx -t would block. Skip.
			echo "(--nginx-test: the SSL passphrase file is a FIFO and no passphrase was"
			echo " given, so nginx -t would block. Skipping. Pass --passphrase /"
			echo " \$FMS_SSL_PASSPHRASE, or run the manual command in the next steps.)"
		elif [ -n "$PW_FILE" ] && [ -p "$PW_FILE" ]; then
			echo "Running nginx syntax check (feeding the SSL passphrase FIFO)..."
			# Background a writer for the FIFO; nginx drains it as it loads the key.
			( printf '%s\n' "$PASSPHRASE" > "$PW_FILE" ) &
			writer_pid=$!
			run_nginx_t || \
				echo "(nginx -t did not confirm -- re-run manually once httpserver is up; see next steps)"
			# If nginx never opened the FIFO, the writer is still blocked; clean up.
			kill "$writer_pid" 2>/dev/null || true
			wait "$writer_pid" 2>/dev/null || true
		else
			# Not a FIFO (plain passphrase file, or none) -- nginx -t won't block.
			echo "Running nginx syntax check..."
			run_nginx_t || \
				echo "(nginx -t did not confirm -- re-run manually once httpserver is up; see next steps)"
		fi
	fi
fi

# ---- next steps -------------------------------------------------------------
# Show the FIFO path this conf actually uses so the printed command is correct.
PW_FILE=$(perl -ne 'print $1 if /^\s*ssl_password_file\s+"?([^";]+)"?\s*;/' "$CONF" | head -1)
: "${PW_FILE:=/opt/FileMaker/FileMaker Server/CStore/.passphrase}"

cat <<NEXT

Done. To finish (these are NOT automated on purpose):

  # 1. Verify syntax. nginx reads the key passphrase from a FIFO, so a bare
  #    'nginx -t' HANGS -- feed the passphrase into the FIFO in the background
  #    first (use the passphrase for whichever cert FMS is using; the built-in
  #    self-signed cert if no custom cert is installed):
  ( printf '%s\n' 'YOUR_SSL_PASSPHRASE' > "$PW_FILE" ) & \\
    sudo nginx -t -c "$CONF"

  # 2. Apply (needs FMS admin-console credentials):
  fmsadmin restart httpserver

  # 3. Separately, in the FMS Admin Console: Connectors -> Web Publishing ->
  #    Claris FileMaker WebDirect -> Custom Home URL = https://<webDNS>
  #    (see docs/fms-server-cors-config.md section 2 -- not done by this script)
NEXT
