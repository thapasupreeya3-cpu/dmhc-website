#!/usr/bin/env python3
"""
DMHC website form handler
=========================
Receives contact and referral submissions from dmhcare.com.au and emails them
to the business inbox over authenticated SMTP.

Design notes:
  * Binds to 127.0.0.1 only. Caddy reverse-proxies https://dmhcare.com.au/api/*
    to it, so this process is never reachable directly from the internet.
  * The recipient address is fixed by configuration, never by the request,
    so this cannot be abused as an open mail relay.
  * Standard library only - nothing to install, nothing to keep patched.

Configuration comes from environment variables (see dmhc-forms.env.example):
  DMHC_SMTP_HOST  default smtp.zoho.com.au
  DMHC_SMTP_PORT  default 465 (implicit TLS)
  DMHC_SMTP_USER  the mailbox that authenticates and appears as the sender
  DMHC_SMTP_PASS  an app-specific password, NOT the account password
  DMHC_MAIL_TO    where submissions are delivered
  DMHC_PORT       default 8787
"""

import json
import os
import re
import smtplib
import ssl
import sys
import time
from collections import defaultdict, deque
from datetime import datetime
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    from zoneinfo import ZoneInfo
    SYDNEY = ZoneInfo("Australia/Sydney")
except Exception:  # pragma: no cover - very old Python
    SYDNEY = None

SMTP_HOST = os.environ.get("DMHC_SMTP_HOST", "smtp.zoho.com.au")
SMTP_PORT = int(os.environ.get("DMHC_SMTP_PORT", "465"))
SMTP_USER = os.environ.get("DMHC_SMTP_USER", "")
SMTP_PASS = os.environ.get("DMHC_SMTP_PASS", "")
MAIL_TO = os.environ.get("DMHC_MAIL_TO", "info@dmhcare.com.au")
SENDER_NAME = os.environ.get("DMHC_SENDER_NAME", "DMHC Website")
PORT = int(os.environ.get("DMHC_PORT", "8787"))

MAX_BODY = 64 * 1024          # bytes accepted on the wire
MAX_TEXT = 20000              # characters of message body
MAX_SUBJECT = 180             # characters of subject line
PER_IP_LIMIT = 5              # submissions ...
PER_IP_WINDOW = 15 * 60       # ... per this many seconds
GLOBAL_LIMIT = 120            # submissions ...
GLOBAL_WINDOW = 60 * 60       # ... per this many seconds

EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$")

_ip_hits = defaultdict(deque)
_global_hits = deque()


def log(*parts):
    stamp = datetime.now(SYDNEY).strftime("%Y-%m-%d %H:%M:%S") if SYDNEY else time.strftime("%Y-%m-%d %H:%M:%S")
    print(stamp, *parts, flush=True)


def rate_limited(ip):
    """Simple sliding window. Returns a reason string, or None if allowed."""
    now = time.time()

    while _global_hits and now - _global_hits[0] > GLOBAL_WINDOW:
        _global_hits.popleft()
    if len(_global_hits) >= GLOBAL_LIMIT:
        return "global"

    hits = _ip_hits[ip]
    while hits and now - hits[0] > PER_IP_WINDOW:
        hits.popleft()
    if len(hits) >= PER_IP_LIMIT:
        return "per-ip"

    hits.append(now)
    _global_hits.append(now)

    if len(_ip_hits) > 5000:  # keep the table from growing without bound
        for key in [k for k, v in _ip_hits.items() if not v]:
            del _ip_hits[key]

    return None


def clean_subject(raw):
    subject = re.sub(r"[\r\n]+", " ", str(raw or "")).strip()
    subject = subject[:MAX_SUBJECT]
    return subject or "Website enquiry"


def build_message(form_kind, subject, text, reply_to):
    msg = EmailMessage()
    msg["From"] = "{0} <{1}>".format(SENDER_NAME, SMTP_USER)
    msg["To"] = MAIL_TO
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="dmhcare.com.au")
    msg["Auto-Submitted"] = "auto-generated"
    if reply_to:
        msg["Reply-To"] = reply_to

    received = datetime.now(SYDNEY).strftime("%A %d %B %Y at %I:%M %p") if SYDNEY else time.strftime("%c")
    header = "Sent from the {0} form on dmhcare.com.au\nReceived {1} (Sydney time)\n".format(form_kind, received)
    footer = ""
    if reply_to:
        footer = "\n\n---\nReplying to this email will go straight back to {0}.".format(reply_to)
    else:
        footer = "\n\n---\nNo email address was supplied, so use the contact details in the message above."

    msg.set_content(header + "\n" + text + footer)
    return msg


def send_mail(msg):
    context = ssl.create_default_context()
    last_error = None
    for attempt in (1, 2):
        try:
            if SMTP_PORT == 465:
                with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=20, context=context) as smtp:
                    smtp.login(SMTP_USER, SMTP_PASS)
                    smtp.send_message(msg)
            else:
                with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as smtp:
                    smtp.starttls(context=context)
                    smtp.login(SMTP_USER, SMTP_PASS)
                    smtp.send_message(msg)
            return True, None
        except smtplib.SMTPAuthenticationError as exc:
            return False, "auth failed: {0}".format(exc)
        except Exception as exc:  # transient network / greylisting
            last_error = exc
            log("send attempt", attempt, "failed:", repr(exc))
            if attempt == 1:
                time.sleep(2)
    return False, repr(last_error)


class Handler(BaseHTTPRequestHandler):
    server_version = "dmhc-forms"
    sys_version = ""

    def log_message(self, fmt, *args):  # quieten the default noisy logger
        pass

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def client_ip(self):
        # Caddy appends the real peer address to the end of X-Forwarded-For.
        # Anything earlier in the list was supplied by the caller and could be
        # invented, so the LAST entry is the one worth rate limiting on.
        fwd = self.headers.get("X-Forwarded-For", "")
        if fwd:
            parts = [p.strip() for p in fwd.split(",") if p.strip()]
            if parts:
                return parts[-1]
        return self.client_address[0]

    def do_GET(self):
        if self.path.rstrip("/").endswith("/health"):
            self._json(200, {"ok": True, "service": "dmhc-forms"})
        else:
            self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/send"):
            self._json(404, {"ok": False, "error": "not found"})
            return

        ip = self.client_ip()

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self._json(413, {"ok": False, "error": "bad size"})
            return

        try:
            data = json.loads(self.rfile.read(length).decode("utf-8", "replace"))
            if not isinstance(data, dict):
                raise ValueError("not an object")
        except Exception:
            self._json(400, {"ok": False, "error": "bad request"})
            return

        # Honeypot: real people never fill a hidden field in.
        if str(data.get("website", "")).strip():
            log("honeypot triggered from", ip)
            self._json(200, {"ok": True})  # look successful to the bot
            return

        text = str(data.get("text", "")).strip()
        if not text:
            self._json(400, {"ok": False, "error": "empty message"})
            return
        text = text[:MAX_TEXT]

        form_kind = "referral" if str(data.get("form", "")) == "referral" else "contact"
        subject = clean_subject(data.get("subject"))
        reply_to = str(data.get("reply_to", "")).strip()
        if not EMAIL_RE.match(reply_to):
            reply_to = ""

        reason = rate_limited(ip)
        if reason:
            log("rate limited (", reason, ") from", ip)
            self._json(429, {"ok": False, "error": "too many"})
            return

        if not SMTP_USER or not SMTP_PASS:
            log("REFUSING TO SEND: SMTP credentials are not configured")
            self._json(500, {"ok": False, "error": "not configured"})
            return

        ok, err = send_mail(build_message(form_kind, subject, text, reply_to))
        if ok:
            log("sent", form_kind, "from", ip, "reply-to:", reply_to or "(none)")
            self._json(200, {"ok": True})
        else:
            log("FAILED to send", form_kind, "from", ip, "-", err)
            self._json(502, {"ok": False, "error": "send failed"})


def main():
    if not SMTP_USER or not SMTP_PASS:
        log("WARNING: DMHC_SMTP_USER / DMHC_SMTP_PASS are not set - submissions will be refused")
    log("dmhc-forms listening on 127.0.0.1:{0}, delivering to {1}".format(PORT, MAIL_TO))
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
