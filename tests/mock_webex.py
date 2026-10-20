"""Stand-in for the Webex token endpoint and Contact Center config-service, for local testing.

Run: python mock_webex.py   (listens on 127.0.0.1:8765)
Point a test data\\config.json at it: TokenUrl http://127.0.0.1:8765/v1/access_token, ConfigBaseUrl http://127.0.0.1:8765
Team IDs T1 and T2 have preset numbers; any team ID starting with 00000000 returns 404.
Client secret "bad" -> invalid_client. Refresh token "expired" -> invalid_grant. Stale access token -> 401.
"""
import json, http.server, urllib.parse, re
state={"dn":{"T1":"15415550104","T2":"15415550105"},"tok":"good0","tokcalls":0}
NAMES={"T1":"ACH Helpdesk Transfer to OnCall","T2":"ACH IT Admin Transfer to OnCall"}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,code,obj):
        b=json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def tid(self): return self.path.rstrip('/').split('/')[-1]
    def do_POST(self):
        import urllib.parse as up
        n=int(self.headers["Content-Length"]); f=up.parse_qs(self.rfile.read(n).decode())
        if f.get("client_secret",[""])[0]=="bad": return self.send(400,{"error":"invalid_client","error_description":"Invalid client"})
        if f.get("refresh_token",[""])[0]=="expired": return self.send(400,{"error":"invalid_grant","error_description":"expired"})
        state["tokcalls"]+=1; state["tok"]="good%d"%state["tokcalls"]
        self.send(200,{"access_token":state["tok"],"expires_in":1209599,"refresh_token":"rt%d"%state["tokcalls"],"refresh_token_expires_in":7776000})
    def auth(self): return self.headers.get("Authorization")=="Bearer "+state["tok"]
    def do_GET(self):
        if not self.auth(): return self.send(401,{})
        t=self.tid()
        if t.startswith("00000000"): return self.send(404,{"error":"team not found"})
        self.send(200,{"id":t,"name":NAMES.get(t,t),"teamType":"CAPACITY_BASED","dialedNumber":state["dn"].get(t)})
    def do_PUT(self):
        if not self.auth(): return self.send(401,{})
        n=int(self.headers["Content-Length"]); body=json.loads(self.rfile.read(n)); state["dn"][self.tid()]=body["dialedNumber"]; self.send(200,body)
http.server.HTTPServer(("127.0.0.1",8765),H).serve_forever()
