#!/usr/bin/env bash
#
# DMHC website form handler — installer
# =====================================
# Run this once on the Lightsail server, as root:
#
#     sudo bash /var/www/dmhcare/server/install-forms.sh
#
# It is safe to run again; anything already done is skipped.
#
# What it does, in order:
#   1. checks the files it needs are present
#   2. asks for the Zoho app password and writes /etc/dmhc-forms.env (root only)
#   3. installs and starts the dmhc-forms service
#   4. adds ONE routing rule to the Caddy config, after taking a backup
#   5. checks dmhcare.com.au AND bookit.life are both still healthy
#
# If anything at step 4 or 5 goes wrong it puts the old Caddy config back
# and reloads, so the two live websites are never left broken.

set -euo pipefail

SITE_ROOT="/var/www/dmhcare"
SERVER_DIR="$SITE_ROOT/server"
ENV_FILE="/etc/dmhc-forms.env"
UNIT_SRC="$SERVER_DIR/dmhc-forms.service"
UNIT_DST="/etc/systemd/system/dmhc-forms.service"
CADDYFILE="/etc/caddy/Caddyfile"
PORT="8787"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${CADDYFILE}.bak-${STAMP}"
RECONFIGURE="no"

[ "${1:-}" = "--reconfigure" ] && RECONFIGURE="yes"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }
warn() { printf '    \033[33mNOTE\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mSTOPPED:\033[0m %s\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. checks --
step "Checking everything is in place"

[ "$(id -u)" = "0" ] || die "Please run this with sudo:  sudo bash $0"
[ -f "$SERVER_DIR/dmhc-forms.py" ] || die "Cannot find $SERVER_DIR/dmhc-forms.py — did the 'git pull' finish?"
[ -f "$UNIT_SRC" ] || die "Cannot find $UNIT_SRC — did the 'git pull' finish?"
[ -f "$CADDYFILE" ] || die "Cannot find $CADDYFILE — is Caddy installed here?"
command -v python3 >/dev/null || die "python3 is not installed. Run: sudo apt install -y python3"
command -v curl    >/dev/null || die "curl is not installed. Run: sudo apt install -y curl"
command -v caddy   >/dev/null || die "The 'caddy' command was not found."

python3 -c "import smtplib, ssl, json, zoneinfo" 2>/dev/null \
  || die "This Python is missing a standard module the handler needs."
ok "files, python3, curl and caddy all present"

# Record how the two sites are behaving BEFORE we touch anything, so we can
# tell the difference between "we broke it" and "it was already like that".
probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo "000"; }
BEFORE_DMHC="$(probe https://dmhcare.com.au/)"
BEFORE_BOOKIT="$(probe https://bookit.life/)"
info "before we start:  dmhcare.com.au -> $BEFORE_DMHC   bookit.life -> $BEFORE_BOOKIT"

# ------------------------------------------------------------- 2. password --
step "Mail settings"

if [ -f "$ENV_FILE" ] && [ "$RECONFIGURE" = "no" ]; then
  ok "$ENV_FILE already exists — leaving it alone"
  info "to change the password later:  sudo bash $0 --reconfigure"
else
  echo
  echo "    Paste the Zoho APP PASSWORD for info@dmhcare.com.au."
  echo "    (Zoho Mail > Settings > Security > App Passwords > Generate New Password.)"
  echo "    Nothing will appear on screen as you paste — that is normal."
  echo
  printf '    App password: '
  read -rs APP_PASSWORD
  echo
  [ -n "$APP_PASSWORD" ] || die "No password entered — nothing has been changed."

  umask 077
  cat > "$ENV_FILE" <<ENVEOF
# Written by install-forms.sh on ${STAMP}.
# This file contains a password. Keep it at chmod 600 and never copy it
# into the website folder or into GitHub.
DMHC_SMTP_HOST=smtp.zoho.com.au
DMHC_SMTP_PORT=465
DMHC_SMTP_USER=info@dmhcare.com.au
DMHC_SMTP_PASS=${APP_PASSWORD}
DMHC_MAIL_TO=info@dmhcare.com.au
DMHC_SENDER_NAME=DMHC Website
DMHC_PORT=${PORT}
ENVEOF
  unset APP_PASSWORD
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "saved to $ENV_FILE (readable by root only)"
fi

# -------------------------------------------------------------- 3. service --
step "Installing the form handler service"

install -m 0644 -o root -g root "$UNIT_SRC" "$UNIT_DST"
systemctl daemon-reload
systemctl enable dmhc-forms >/dev/null 2>&1 || true
systemctl restart dmhc-forms
sleep 2

if ! systemctl is-active --quiet dmhc-forms; then
  echo
  journalctl -u dmhc-forms -n 25 --no-pager || true
  die "The dmhc-forms service did not start. The log above says why."
fi
ok "service is running, and will restart by itself after a reboot"

HEALTH="$(curl -s --max-time 5 "http://127.0.0.1:${PORT}/health" || true)"
case "$HEALTH" in
  *'"ok": true'*|*'"ok":true'*) ok "handler answering on 127.0.0.1:${PORT}" ;;
  *) die "The handler is not answering on port ${PORT}. Check: journalctl -u dmhc-forms -n 40" ;;
esac

# ---------------------------------------------------------------- 4. caddy --
step "Adding the /api route to Caddy"

if grep -q "127.0.0.1:${PORT}" "$CADDYFILE"; then
  ok "the route is already in $CADDYFILE — no change needed"
else
  cp -a "$CADDYFILE" "$BACKUP"
  ok "backed up the old config to $BACKUP"

  set +e
  python3 - "$CADDYFILE" "$PORT" <<'PYEOF'
import re, sys

path, port = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

# Walk the file and record every top-level { ... } block, ignoring braces that
# sit inside quotes or comments.
blocks, depth, start, i, n = [], 0, None, 0, len(src)
while i < n:
    c = src[i]
    if c == '"':
        i += 1
        while i < n and src[i] != '"':
            i += 2 if src[i] == "\\" else 1
    elif c == "#":
        while i < n and src[i] != "\n":
            i += 1
    elif c == "{":
        if depth == 0:
            start = i
        depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0 and start is not None:
            blocks.append((start, i))
            start = None
    i += 1

target = None
for open_i, close_i in blocks:
    if "/var/www/dmhcare" in src[open_i:close_i]:
        target = (open_i, close_i)
        break

if target is None:
    sys.stderr.write(
        "Could not find the dmhcare.com.au site block (nothing in the file\n"
        "points at /var/www/dmhcare). The config has not been changed.\n")
    sys.exit(2)

open_i, close_i = target
body = src[open_i + 1:close_i]

if re.search(r"(?m)^[ \t]*route[ \t]*\{", body):
    sys.stderr.write(
        "This site block uses a 'route' directive, which needs a judgement\n"
        "call to edit safely. The config has not been changed.\n")
    sys.exit(3)

indent = "\t"
m = re.search(r"(?m)^([ \t]+)\S", body)
if m:
    indent = m.group(1)

# A bare 'handle {' catches every request, so in that style the new rules have
# to be handle blocks too. Otherwise plain directives are fine: Caddy always
# runs respond, then reverse_proxy, then file_server, whatever the file order.
if re.search(r"(?m)^[ \t]*handle[ \t]*\{", body):
    lines = [
        "",
        "# Website forms: hand /api/* to the local handler (added by install-forms.sh)",
        "handle /api/* {",
        indent + "reverse_proxy 127.0.0.1:" + port,
        "}",
        "# Never serve the handler's own source code",
        "handle /server/* {",
        indent + "respond 404",
        "}",
        "",
    ]
    add = "\n".join((indent + ln) if ln else ln for ln in lines)
else:
    add = (
        "\n"
        "{i}# Website forms: hand /api/* to the local handler (added by install-forms.sh)\n"
        "{i}reverse_proxy /api/* 127.0.0.1:{p}\n"
        "{i}# Never serve the handler's own source code\n"
        "{i}respond /server/* 404\n"
    ).format(i=indent, p=port)

out = src[:open_i + 1] + add + src[open_i + 1:]
open(path, "w", encoding="utf-8").write(out)
print("    OK   added the route to the block starting on line %d"
      % (src[:open_i].count("\n") + 1))
PYEOF
  PATCH_RC=$?
  set -e

  if [ "$PATCH_RC" != "0" ]; then
    cp -a "$BACKUP" "$CADDYFILE"
    echo
    echo "    Nothing was changed. Send Claude the output of:"
    echo "        sudo cat $CADDYFILE"
    echo "    and the two lines can be added by hand instead."
    die "Could not edit the Caddy config automatically."
  fi

  restore_caddy() {
    cp -a "$BACKUP" "$CADDYFILE"
    systemctl reload caddy || systemctl restart caddy || true
    sleep 2
  }

  if ! caddy validate --adapter caddyfile --config "$CADDYFILE" >/tmp/caddy-validate.log 2>&1; then
    restore_caddy
    echo; tail -20 /tmp/caddy-validate.log
    die "The edited config did not pass Caddy's own check. The old one is back in place."
  fi
  ok "the edited config passes 'caddy validate'"

  if ! systemctl reload caddy; then
    restore_caddy
    die "Caddy refused to reload. The old config is back in place."
  fi
  sleep 2
  ok "Caddy reloaded"
fi

# --------------------------------------------------------------- 5. checks --
step "Checking both websites are still healthy"

LOCAL_IP="127.0.0.1"
api()  { curl -s --max-time 10 --resolve "dmhcare.com.au:443:$LOCAL_IP" "https://dmhcare.com.au/api/health" 2>/dev/null || true; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo "000"; }

API_BODY="$(api)"
AFTER_DMHC="$(code https://dmhcare.com.au/)"
AFTER_BOOKIT="$(code https://bookit.life/)"

FAILED=""
case "$API_BODY" in
  *'"ok": true'*|*'"ok":true'*) ok "https://dmhcare.com.au/api/health responds" ;;
  *) FAILED="the /api/health check did not respond" ;;
esac
[ "$AFTER_DMHC" = "200" ] || FAILED="${FAILED:+$FAILED; }dmhcare.com.au returned $AFTER_DMHC"
if [ "$BEFORE_BOOKIT" = "200" ] && [ "$AFTER_BOOKIT" != "200" ]; then
  FAILED="${FAILED:+$FAILED; }bookit.life was 200 before and is $AFTER_BOOKIT now"
fi

if [ -n "$FAILED" ]; then
  if [ -f "$BACKUP" ]; then
    cp -a "$BACKUP" "$CADDYFILE"
    systemctl reload caddy || systemctl restart caddy || true
    sleep 2
    echo
    warn "put the old Caddy config back: dmhcare.com.au -> $(code https://dmhcare.com.au/), bookit.life -> $(code https://bookit.life/)"
  fi
  die "$FAILED"
fi
ok "dmhcare.com.au -> $AFTER_DMHC   bookit.life -> $AFTER_BOOKIT"

# ---------------------------------------------------------------- finished --
cat <<DONE

────────────────────────────────────────────────────────────────────────
 Done. The form handler is live.

 Next: upload the new index.html to GitHub, then back here run
     cd /var/www/dmhcare && sudo git pull

 Then fill in the contact form at https://dmhcare.com.au/#/contact and
 watch the email arrive in info@dmhcare.com.au.

 Handy commands
     sudo systemctl status dmhc-forms      is it running?
     sudo journalctl -u dmhc-forms -f      watch submissions live
     sudo systemctl restart dmhc-forms     after changing the password

 If the Caddy change ever needs undoing
     sudo cp $BACKUP $CADDYFILE
     sudo systemctl reload caddy
────────────────────────────────────────────────────────────────────────

DONE
