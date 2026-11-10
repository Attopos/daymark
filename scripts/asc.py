#!/usr/bin/env python3
"""Small App Store Connect API client for Daymark releases. Standard library + openssl only.

    asc.py check                          show the app, its versions and recent builds
    asc.py next-version [--minor]         print the next version: 1.x.y -> 1.x.(y+1), or 1.(x+1).0
    asc.py project-version [--set V B]    print or set the app target's version and build in the project
    asc.py next-build VERSION             print the next free build number for VERSION
    asc.py submit VERSION BUILD [--notes-dir DIR] [--dry-run] [--timeout MIN]
        wait for the uploaded build to finish processing, attach it to the App Store
        version VERSION (created if needed), set "What's New" from DIR/<locale>.txt,
        then submit the version for App Review.

Credentials come from the environment (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), which
scripts/release.sh loads from ~/.appstoreconnect/daymark.env. Nothing secret lives in git.
"""
import argparse, base64, json, os, subprocess, sys, time, urllib.parse

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.shizhengcao.Daymark")
# App Store versions that can still take a new build. Anything else (in review, live, ...) is taken.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(sig):
    """ECDSA DER signature (from openssl) -> 64-byte r||s that JWT ES256 wants."""
    if sig[0] != 0x30:
        die("unexpected signature format from openssl")
    i = 2 if sig[1] < 0x80 else 2 + (sig[1] & 0x7F)
    out = b""
    for _ in range(2):
        if sig[i] != 0x02:
            die("unexpected signature format from openssl")
        n = sig[i + 1]
        out += sig[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + n
    return out


_token = {"value": None, "exp": 0}


def token():
    now = int(time.time())
    if _token["value"] and now < _token["exp"] - 60:
        return _token["value"]
    key_id, issuer = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    key_path = os.path.expanduser(os.environ.get("ASC_KEY_PATH", f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    if not key_id or not issuer:
        die("ASC_KEY_ID / ASC_ISSUER_ID not set (see ~/.appstoreconnect/daymark.env)")
    if not os.path.isfile(key_path):
        die(f"API key not found at {key_path}")
    exp = now + 15 * 60
    head = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iss": issuer, "iat": now, "exp": exp, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{head}.{body}".encode()
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    _token.update(value=f"{head}.{body}.{b64url(der_to_raw(sig))}", exp=exp)
    return _token["value"]


def call(method, path, params=None, body=None):
    # System curl, not urllib: python.org builds on macOS ship without a CA bundle.
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    cmd = ["curl", "-sS", "--max-time", "60", "-X", method, "-w", "\n%{http_code}",
           "-H", f"Authorization: Bearer {token()}", "-H", "Content-Type: application/json", url]
    if body is not None:
        cmd += ["--data-binary", "@-"]
    for attempt in range(4):  # retry network failures (not HTTP errors) with backoff
        r = subprocess.run(cmd, input=json.dumps(body).encode() if body is not None else None, capture_output=True)
        if r.returncode == 0:
            break
        if attempt < 3:
            print(f"   network error, retrying in {2 ** (attempt + 1)}s", file=sys.stderr)
            time.sleep(2 ** (attempt + 1))
    if r.returncode != 0:
        die(f"{method} {path} failed: {r.stderr.decode(errors='replace').strip()}")
    raw, _, code = r.stdout.decode(errors="replace").rpartition("\n")
    if not code.startswith("2"):
        detail = raw
        try:
            detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in json.loads(raw)["errors"])
        except Exception:
            pass
        die(f"{method} {path} -> HTTP {code}: {detail}")
    return json.loads(raw) if raw.strip() else {}


def get(path, **params):
    return call("GET", path, params or None)


def find_app():
    apps = get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID, "fields[apps]": "name,bundleId"})["data"]
    if not apps:
        die(f"no app with bundle id {BUNDLE_ID} in App Store Connect")
    return apps[0]


def builds_for(app_id, version, number=None):
    params = {"filter[app]": app_id, "filter[preReleaseVersion.version]": version,
              "fields[builds]": "version,processingState,uploadedDate", "sort": "-uploadedDate", "limit": 200}
    if number is not None:
        params["filter[version]"] = str(number)
    return get("/v1/builds", **params)["data"]


def versions(app_id):
    return get(f"/v1/apps/{app_id}/appStoreVersions", **{
        "filter[platform]": "IOS", "fields[appStoreVersions]": "versionString,appStoreState", "limit": 20})["data"]


def cmd_check(_):
    app = find_app()
    print(f"App: {app['attributes']['name']} ({BUNDLE_ID}, id {app['id']})")
    print("App Store versions:")
    for v in versions(app["id"])[:5]:
        print(f"  {v['attributes']['versionString']:<10} {v['attributes']['appStoreState']}")
    print("Recent builds:")
    recent = get("/v1/builds", **{"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 5,
                                  "include": "preReleaseVersion",
                                  "fields[builds]": "version,processingState,uploadedDate,preReleaseVersion"})
    pre = {x["id"]: x["attributes"]["version"] for x in recent.get("included", [])}
    for b in recent["data"]:
        rel = b["relationships"]["preReleaseVersion"]["data"]
        a = b["attributes"]
        print(f"  {pre.get(rel['id'] if rel else '', '?'):<10} build {a['version']:<5} "
              f"{a['processingState']:<10} {a['uploadedDate'][:16]}")


def cmd_next_version(args):
    """Versions are 1.x.y: bump y each release, or x (y back to 0) with --minor."""
    taken = []
    for v in versions(find_app()["id"]):
        parts = v["attributes"]["versionString"].split(".")
        if v["attributes"]["appStoreState"] not in EDITABLE and all(p.isdigit() for p in parts):
            taken.append(tuple(int(p) for p in (parts + ["0", "0"])[:3]))
    if not taken:
        die("no released version found to bump from; pass --version")
    major, minor, patch = max(taken)
    print(f"{major}.{minor + 1}.0" if args.minor else f"{major}.{minor}.{patch + 1}")


PBXPROJ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "daymark.xcodeproj", "project.pbxproj")


def cmd_project_version(args):
    """Print, or with --set rewrite, MARKETING_VERSION and CURRENT_PROJECT_VERSION of the app
    target (the build configurations whose bundle id is BUNDLE_ID; test targets are left alone)."""
    import re
    text = open(PBXPROJ, encoding="utf-8").read()
    blocks = [m for m in re.finditer(r"buildSettings = \{.*?\n\t\t\t\};", text, re.S)
              if f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};" in m.group(0)]
    if not blocks:
        die(f"no build configuration with bundle id {BUNDLE_ID} in {PBXPROJ}")
    if not args.set:
        b = blocks[0].group(0)
        ver = re.search(r"MARKETING_VERSION = ([^;]+);", b).group(1)
        num = re.search(r"CURRENT_PROJECT_VERSION = ([^;]+);", b).group(1)
        print(ver, num)
        return
    version, build = args.set
    for m in reversed(blocks):
        b = re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {version};", m.group(0))
        b = re.sub(r"CURRENT_PROJECT_VERSION = [^;]+;", f"CURRENT_PROJECT_VERSION = {build};", b)
        text = text[:m.start()] + b + text[m.end():]
    open(PBXPROJ, "w", encoding="utf-8").write(text)


def cmd_next_build(args):
    app = find_app()
    nums = [int(b["attributes"]["version"]) for b in builds_for(app["id"], args.version)
            if b["attributes"]["version"].isdigit()]
    print(max(nums, default=0) + 1)


def wait_for_build(app_id, version, number, timeout_min):
    deadline = time.time() + timeout_min * 60
    last = None
    while True:
        found = builds_for(app_id, version, number)
        state = found[0]["attributes"]["processingState"] if found else "NOT_YET_VISIBLE"
        if state != last:
            print(f"   build {version} ({number}): {state}", flush=True)
            last = state
        if state == "VALID":
            return found[0]
        if state in ("FAILED", "INVALID"):
            die(f"build {version} ({number}) processing ended as {state}")
        if time.time() > deadline:
            die(f"build {version} ({number}) still {state} after {timeout_min} min; rerun "
                f"`scripts/release.sh submit-only` later")
        time.sleep(30)


def read_notes(notes_dir):
    notes = {}
    if notes_dir:
        if not os.path.isdir(notes_dir):
            die(f"release notes folder not found: {notes_dir}")
        for name in sorted(os.listdir(notes_dir)):
            if name.endswith(".txt"):
                text = open(os.path.join(notes_dir, name), encoding="utf-8").read().strip()
                if text:
                    notes[name[:-4]] = text
    return notes


def cmd_submit(args):
    dry = args.dry_run
    act = (lambda what: print(f"   [dry-run] would {what}")) if dry else (lambda what: print(f"   {what}"))
    notes = read_notes(args.notes_dir)
    app = find_app()
    app_id = app["id"]
    print(f"==> {app['attributes']['name']} {args.version} ({args.build})")

    if dry:
        found = builds_for(app_id, args.version, args.build)
        build = found[0] if found else None
        print(f"   build state: {build['attributes']['processingState'] if build else 'not uploaded yet'}")
    else:
        build = wait_for_build(app_id, args.version, args.build, args.timeout)

    # One editable App Store version at a time: reuse ours, or rename the editable one.
    vs = versions(app_id)
    mine = next((v for v in vs if v["attributes"]["versionString"] == args.version), None)
    editable = next((v for v in vs if v["attributes"]["appStoreState"] in EDITABLE), None)
    if mine and mine["attributes"]["appStoreState"] not in EDITABLE:
        die(f"version {args.version} is already {mine['attributes']['appStoreState']}; bump MARKETING_VERSION")
    if mine:
        ver_id = mine["id"]
        print(f"   using App Store version {args.version} ({mine['attributes']['appStoreState']})")
    elif editable:
        ver_id = editable["id"]
        act(f"rename editable version {editable['attributes']['versionString']} to {args.version}")
        if not dry:
            call("PATCH", f"/v1/appStoreVersions/{ver_id}", body={"data": {
                "type": "appStoreVersions", "id": ver_id, "attributes": {"versionString": args.version}}})
    else:
        act(f"create App Store version {args.version}")
        ver_id = None
        if not dry:
            ver_id = call("POST", "/v1/appStoreVersions", body={"data": {
                "type": "appStoreVersions",
                "attributes": {"platform": "IOS", "versionString": args.version, "releaseType": "AFTER_APPROVAL"},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]["id"]

    act(f"attach build {args.build}")
    if not dry:
        call("PATCH", f"/v1/appStoreVersions/{ver_id}/relationships/build",
             body={"data": {"type": "builds", "id": build["id"]}})

    locs = get(f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations")["data"] if ver_id else []
    if not locs and editable is None and mine is None:
        # A new version copies the previous one's localizations; read those for the dry-run listing.
        prev = next((v for v in vs), None)
        locs = get(f"/v1/appStoreVersions/{prev['id']}/appStoreVersionLocalizations")["data"] if prev else []
    locales = [l["attributes"]["locale"] for l in locs]
    print(f"   localizations: {', '.join(locales) or 'none'}")
    missing = [l for l in locales if l not in notes]
    if notes and missing:
        die(f"no release notes for {', '.join(missing)} in {args.notes_dir} (add <locale>.txt)")
    for loc in locs:
        text = notes.get(loc["attributes"]["locale"])
        if text is None:
            continue
        act(f"set What's New for {loc['attributes']['locale']}: {text.splitlines()[0][:60]}")
        if not dry:
            call("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}", body={"data": {
                "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": text}}})

    # Reuse an open review submission if there is one, otherwise make a new one.
    open_subs = get("/v1/reviewSubmissions", **{"filter[app]": app_id, "filter[platform]": "IOS",
                                                "filter[state]": "READY_FOR_REVIEW"})["data"]
    if open_subs:
        sub_id = open_subs[0]["id"]
        print("   reusing open review submission")
    else:
        act("create review submission")
        sub_id = None
        if not dry:
            sub_id = call("POST", "/v1/reviewSubmissions", body={"data": {
                "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]["id"]
    if sub_id:
        items = get(f"/v1/reviewSubmissions/{sub_id}/items", **{"include": "appStoreVersion"})["data"]
        has_mine = any((i["relationships"].get("appStoreVersion", {}).get("data") or {}).get("id") == ver_id
                       for i in items)
    else:
        has_mine = False
    if not has_mine:
        act(f"add version {args.version} to the submission")
        if not dry:
            call("POST", "/v1/reviewSubmissionItems", body={"data": {
                "type": "reviewSubmissionItems", "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}})
    act("submit for App Review")
    if not dry:
        call("PATCH", f"/v1/reviewSubmissions/{sub_id}", body={"data": {
            "type": "reviewSubmissions", "id": sub_id, "attributes": {"submitted": True}}})
        print(f"==> Submitted {args.version} ({args.build}) for review")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check").set_defaults(fn=cmd_check)
    nv = sub.add_parser("next-version"); nv.add_argument("--minor", action="store_true")
    nv.set_defaults(fn=cmd_next_version)
    pv = sub.add_parser("project-version"); pv.add_argument("--set", nargs=2, metavar=("VERSION", "BUILD"))
    pv.set_defaults(fn=cmd_project_version)
    nb = sub.add_parser("next-build"); nb.add_argument("version"); nb.set_defaults(fn=cmd_next_build)
    s = sub.add_parser("submit")
    s.add_argument("version"); s.add_argument("build", type=int)
    s.add_argument("--notes-dir"); s.add_argument("--dry-run", action="store_true")
    s.add_argument("--timeout", type=int, default=60, help="minutes to wait for processing (default 60)")
    s.set_defaults(fn=cmd_submit)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
