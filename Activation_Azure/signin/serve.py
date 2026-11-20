#!/usr/bin/env python3
"""Container entry point of the Azure package: the Data Platform Console of the packaged tree, read-only, behind one
shared user name and password.

It loads the packaged console (tree/_tools/activation/console/server.py) unchanged and puts three things in front of
its request handler:

  the password   a sign-in page (/login) that sets a session cookie, from DEMO_USER (default "demo") and
                 DEMO_PASSWORD. Every path but /healthz and /login needs the cookie; HTTP basic auth with the same
                 user and password is accepted too, for scripts (smoke.sh, curl -u). No browser pop-up is used: some
                 managed browsers never show one. The server refuses to start without DEMO_PASSWORD unless
                 DEMO_AUTH=off is set on purpose. Serve it behind HTTPS (Container Apps ingress does that).
  read-only      the console opens a private copy of the shipped database (--snapshot), so nothing a visitor does
                 reaches the shipped file, and Run pipeline is refused by the console itself. The requests that would
                 start a build or call the mapping assistant are answered 403 here before they reach the console.
  /healthz       200 with no password, for the platform's probes. It says nothing about the content.

Settings (environment): DEMO_USER, DEMO_PASSWORD, DEMO_AUTH=off, PORT (default 8765), ACTIVATION_LLM (default none:
the free-text question box takes its deterministic paths and no key is needed).
"""
import base64
import hashlib
import hmac
import html
import importlib.util
import json
import os
import sys
import time
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.environ.get("ACTIVATION_TOOLS") or os.path.join(HERE, "tree", "_tools")
CONSOLE = os.path.join(TOOLS, "activation", "console", "server.py")
REFUSED = ("/api/build", "/api/map/propose")        # POSTs that start a build or call the mapping assistant
COOKIE = "console_session"
SESSION_HOURS = 12

LOGIN_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Data Platform Console: sign in</title>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f3f4f7;
       font:15px/1.4 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1c2330}
  form{background:#fff;padding:32px 32px 28px;border-radius:10px;box-shadow:0 2px 14px rgba(20,30,50,.12);width:300px}
  h1{font-size:19px;margin:0 0 4px} p{margin:0 0 20px;color:#5b6577;font-size:13px}
  label{display:block;font-size:12px;font-weight:600;margin:14px 0 5px;color:#3b4557}
  input{width:100%;box-sizing:border-box;padding:9px 10px;border:1px solid #c5cbd6;border-radius:6px;font:inherit}
  input:focus{outline:2px solid #2f6fed;outline-offset:1px;border-color:#2f6fed}
  button{margin-top:22px;width:100%;padding:10px;border:0;border-radius:6px;background:#1f4fbf;color:#fff;font:inherit;font-weight:600;cursor:pointer}
  .err{margin:14px 0 0;color:#b3261e;font-size:13px}
</style></head><body>
<form method="post" action="/login">
  <h1>Data Platform Console</h1><p>Sign in to continue.</p>
  <label for="u">User name</label><input id="u" name="username" autocomplete="username" value="__USER__" required autofocus>
  <label for="p">Password</label><input id="p" name="password" type="password" autocomplete="current-password" required>
  __ERROR__<button type="submit">Sign in</button>
</form></body></html>
"""


def credentials():
    if (os.environ.get("DEMO_AUTH") or "").lower() == "off":
        sys.stderr.write("warning: DEMO_AUTH=off, serving with no password\n")
        return None
    pw = os.environ.get("DEMO_PASSWORD") or ""
    if not pw:
        sys.exit("DEMO_PASSWORD is not set: refusing to serve without a password (DEMO_AUTH=off serves without one)")
    return (os.environ.get("DEMO_USER") or "demo", pw)


def load_console():
    """Loads the console module as running the file would, without starting it."""
    sys.path.insert(0, os.path.dirname(CONSOLE))        # what `python activation/console/server.py` puts first
    os.chdir(TOOLS)
    spec = importlib.util.spec_from_file_location("console_server", CONSOLE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["console_server"] = mod
    spec.loader.exec_module(mod)
    return mod


def guarded(base, creds):
    """The console's handler behind the sign-in page. A session is a signed expiry time, so it survives a restart and
    needs no store; changing the password ends every session."""
    user, password = creds or ("", "")
    basic = None if creds is None else "Basic " + base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    key = hashlib.sha256(f"console-session|{user}|{password}".encode("utf-8")).digest()

    def sign(expiry):
        return hmac.new(key, str(expiry).encode("ascii"), hashlib.sha256).hexdigest()

    def new_session():
        expiry = int(time.time()) + SESSION_HOURS * 3600
        return f"{expiry}.{sign(expiry)}"

    def valid_session(value):
        expiry, _, mac = (value or "").partition(".")
        return expiry.isdigit() and int(expiry) > time.time() and hmac.compare_digest(mac, sign(int(expiry)))

    class Guarded(base):
        def _reply(self, status, text, ctype="text/plain; charset=utf-8", headers=()):
            data = text.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(min(n, 65536)) if n else b""

        def _cookie(self, value, max_age):
            secure = "; Secure" if (self.headers.get("X-Forwarded-Proto") or "").lower() == "https" else ""
            return ("Set-Cookie", f"{COOKIE}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Lax{secure}")

        def _signed_in(self):
            if hmac.compare_digest((self.headers.get("Authorization") or "").encode("utf-8"), basic.encode("utf-8")):
                return True
            for part in (self.headers.get("Cookie") or "").split(";"):
                name, _, value = part.strip().partition("=")
                if name == COOKIE and valid_session(value):
                    return True
            return False

        def _login_page(self, status=200, error=""):
            page = LOGIN_PAGE.replace("__USER__", html.escape(user, quote=True)).replace(
                "__ERROR__", f'<div class="err">{html.escape(error)}</div>' if error else "")
            return self._reply(status, page, "text/html; charset=utf-8")

        def log_message(self, fmt, *args):
            if "/healthz" not in (args[0] if args and isinstance(args[0], str) else ""):
                super().log_message(fmt, *args)

        def handle_any(self, method):
            path = urlparse(self.path).path
            if path == "/healthz":
                return self._reply(200, "ok\n")
            if basic is not None:
                if path == "/login":
                    if method == "POST":
                        form = parse_qs(self._body().decode("utf-8", "replace"))
                        given_user = (form.get("username") or [""])[-1].strip()
                        given_pw = (form.get("password") or [""])[-1]
                        ok = hmac.compare_digest(given_user.encode("utf-8"), user.encode("utf-8")) & \
                            hmac.compare_digest(given_pw.encode("utf-8"), password.encode("utf-8"))
                        if ok:
                            return self._reply(303, "", headers=[("Location", "/"), self._cookie(new_session(), SESSION_HOURS * 3600)])
                        time.sleep(1)                       # slows guessing
                        return self._login_page(401, "That user name or password is not right.")
                    return self._reply(303, "", headers=[("Location", "/")]) if self._signed_in() else self._login_page()
                if path == "/logout":
                    self._body()
                    return self._reply(303, "", headers=[("Location", "/login"), self._cookie("", 0)])
                if not self._signed_in():
                    self._body()                            # drain so the connection stays usable
                    if method == "GET" and not path.startswith("/api/"):
                        return self._reply(303, "", headers=[("Location", "/login")])
                    return self._reply(401, json.dumps(dict(ok=False, error="sign in to continue", login="/login")),
                                       "application/json; charset=utf-8")
            if method == "POST" and path in REFUSED:
                self._body()
                return self.send(403, json.dumps(dict(ok=False, error="Read-only environment: runs disabled")))
            return super().handle_any(method)

    return Guarded


def main():
    creds = credentials()
    os.environ.setdefault("ACTIVATION_LLM", "none")
    os.environ.setdefault("ACTIVATION_RUNTIME", "duckdb")
    mod = load_console()
    mod.Handler = guarded(mod.Handler, creds)
    sys.argv = [CONSOLE, "--runtime", "duckdb", "--snapshot", "--host", os.environ.get("HOST") or "0.0.0.0",
                "--port", os.environ.get("PORT") or "8765"]
    mod.main()


if __name__ == "__main__":
    main()
