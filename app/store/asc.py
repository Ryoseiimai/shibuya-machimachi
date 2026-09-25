#!/usr/bin/env python3
"""Minimal App Store Connect API client (reads key from ~/.appstoreconnect, never prints it)."""
import glob, json, os, sys, time, urllib.request, urllib.error
import jwt

BASE = "https://api.appstoreconnect.apple.com"
KEY_DIR = os.path.expanduser("~/.appstoreconnect/private_keys")

def _token():
    key_path = sorted(glob.glob(os.path.join(KEY_DIR, "AuthKey_*.p8")))[0]
    key_id = os.path.basename(key_path)[len("AuthKey_"):-len(".p8")]
    issuer = open(os.path.expanduser("~/.appstoreconnect/issuer_id")).read().strip()
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, open(key_path).read(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})

def call(method, path, body=None, raw=False):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + _token())
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            txt = r.read().decode()
            return r.status, (json.loads(txt) if txt else {})
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try:
            return e.code, json.loads(txt)
        except Exception:
            return e.code, {"raw": txt}

if __name__ == "__main__":
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, res = call(method, path, body)
    print(status)
    print(json.dumps(res, ensure_ascii=False, indent=1))
