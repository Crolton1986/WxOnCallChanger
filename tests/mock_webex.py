"""Stand-in for the Webex token endpoint, Contact Center config-service and Webex login, for local testing.

Run: python mock_webex.py [port]   (listens on 127.0.0.1:8765 by default)
Point a test data/config.json at it:
  "Webex": { "TokenUrl": "http://127.0.0.1:8765/v1/access_token",
             "ConfigBaseUrl": "http://127.0.0.1:8765", "AuthBaseUrl": "http://127.0.0.1:8765",
             "OrgId": "11111111-2222-3333-4444-555555555555" }

Service App (config-service):
  Team IDs T1 and T2 have preset numbers; any team ID starting with 00000000 returns 404.
  Client secret "bad" -> invalid_client. Refresh token "expired" -> invalid_grant. Stale access token -> 401.

Webex login (Integration):
  GET /v1/authorize redirects straight back to redirect_uri with a code (no login screen).
  The person who "signs in" is set with GET /mock/user?email=a@b.com&org=<uuid>&name=Alex
  (defaults: admin@example.com in org 11111111-2222-3333-4444-555555555555).
  /v1/people/me returns the org ID base64-encoded, the way Webex does.
"""
import base64, json, http.server, sys, urllib.parse as up

ORG = "11111111-2222-3333-4444-555555555555"
state = {"dn": {"T1": "15555550104", "T2": "15555550105"}, "tok": "good0", "tokcalls": 0,
         "user": {"email": "admin@example.com", "org": ORG, "name": "Alex Admin"}, "codes": {}, "users": {}}
NAMES = {"T1": "Support On-Call", "T2": "Systems On-Call"}


def webex_org(uuid):
    return base64.b64encode(f"ciscospark://us/ORGANIZATION/{uuid}".encode()).decode().rstrip("=")


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, obj, headers=None):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    def tid(self): return self.path.split("?")[0].rstrip("/").split("/")[-1]

    def do_POST(self):
        n = int(self.headers["Content-Length"])
        f = up.parse_qs(self.rfile.read(n).decode())
        g = lambda k: f.get(k, [""])[0]
        if g("grant_type") == "authorization_code":
            if g("client_secret") == "bad": return self.send(401, {"error": "invalid_client"})
            user = state["codes"].pop(g("code"), None)
            if not user: return self.send(400, {"error": "invalid_grant"})
            tok = "user-%d" % len(state["users"])
            state["users"][tok] = user
            return self.send(200, {"access_token": tok, "expires_in": 1209599, "refresh_token": "x", "refresh_token_expires_in": 7776000})
        if g("client_secret") == "bad": return self.send(400, {"error": "invalid_client", "error_description": "Invalid client"})
        if g("refresh_token") == "expired": return self.send(400, {"error": "invalid_grant", "error_description": "expired"})
        state["tokcalls"] += 1
        state["tok"] = "good%d" % state["tokcalls"]
        self.send(200, {"access_token": state["tok"], "expires_in": 1209599, "refresh_token": "rt%d" % state["tokcalls"], "refresh_token_expires_in": 7776000})

    def auth(self): return self.headers.get("Authorization") == "Bearer " + state["tok"]

    def do_GET(self):
        path, _, query = self.path.partition("?")
        q = {k: v[0] for k, v in up.parse_qs(query).items()}
        if path == "/mock/user":
            state["user"] = {"email": q.get("email", "admin@example.com"), "org": q.get("org", ORG), "name": q.get("name", "Test User")}
            return self.send(200, state["user"])
        if path == "/v1/authorize":
            code = "c%d" % (len(state["codes"]) + len(state["users"]) + 1)
            state["codes"][code] = dict(state["user"])
            loc = q["redirect_uri"] + "?" + up.urlencode({"code": code, "state": q.get("state", "")})
            return self.send(302, {}, {"Location": loc})
        if path == "/v1/people/me":
            tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
            u = state["users"].get(tok)
            if not u: return self.send(401, {})
            return self.send(200, {"emails": [u["email"]], "displayName": u["name"], "orgId": webex_org(u["org"])})
        if not self.auth(): return self.send(401, {})
        t = self.tid()
        if t.startswith("00000000"): return self.send(404, {"error": "team not found"})
        self.send(200, {"id": t, "name": NAMES.get(t, t), "teamType": "CAPACITY_BASED", "dialedNumber": state["dn"].get(t)})

    def do_PUT(self):
        if not self.auth(): return self.send(401, {})
        n = int(self.headers["Content-Length"])
        body = json.loads(self.rfile.read(n))
        state["dn"][self.tid()] = body["dialedNumber"]
        self.send(200, body)


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
