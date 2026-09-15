#!/usr/bin/env python3
"""Reserve a CI-verified version and publish verified assets without replacing releases."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

VERSION = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SHA = re.compile(r"^[0-9a-f]{40}$")
ASSET = "ghostty.saver.zip"


def version(tag):
    match = VERSION.fullmatch(tag)
    if not match:
        raise ValueError(f"Not a stable version tag: {tag!r}")
    return tuple(map(int, match.groups()))


def next_tag(tags):
    versions = [version(tag) for tag in tags if VERSION.fullmatch(tag)]
    major, minor, patch = max(versions, default=(1, 0, -1))
    return f"v{major}.{minor}.{patch + 1}"


class API:
    def __init__(self, repo):
        self.repo = repo

    def request(self, path, data=None, method=None, missing=False):
        req = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}/{path}",
            data=json.dumps(data).encode() if data is not None else None,
            method=method,
            headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                     "Accept": "application/vnd.github+json",
                     "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2022-11-28"},
        )
        try:
            with urllib.request.urlopen(req) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise

    def pages(self, path, key=None):
        page = 1
        while True:
            sep = "&" if "?" in path else "?"
            result = self.request(f"{path}{sep}per_page=100&page={page}")
            rows = result[key] if key else result
            yield from rows
            if len(rows) < 100:
                break
            page += 1

    def tag_sha(self, tag):
        obj = self.request(f"git/ref/tags/{tag}")["object"]
        for _ in range(10):
            if obj["type"] == "commit":
                return obj["sha"]
            if obj["type"] != "tag":
                break
            obj = self.request(f"git/tags/{obj['sha']}")["object"]
        raise ValueError(f"Tag does not resolve to a commit: {tag}")

    def release(self, tag):
        published = self.request(f"releases/tags/{tag}", missing=True)
        if published:
            return published
        # The tag endpoint excludes drafts; the authenticated listing includes them.
        return next((r for r in self.pages("releases") if r["tag_name"] == tag), None)


def published_complete(release):
    if not release or release["draft"]:
        return False
    if not any(a["name"] == ASSET and a["state"] == "uploaded" and a["size"] > 0
               for a in release["assets"]):
        raise ValueError("Published release has no complete asset; refusing to modify it")
    return True


def verify_ci(api, sha, run=None):
    if not SHA.fullmatch(sha):
        raise ValueError("Invalid candidate commit SHA")
    compare = api.request(f"compare/{sha}...main")
    if compare["status"] not in ("ahead", "identical"):
        raise ValueError("Candidate is not an ancestor of main")
    workflow = api.request("actions/workflows/build.yml")
    runs = [run] if run else api.pages(
        f"actions/workflows/build.yml/runs?event=push&branch=main&head_sha={sha}",
        "workflow_runs")
    for item in runs:
        if (item["head_sha"] == sha and item["head_branch"] == "main"
                and item["event"] == "push" and item["conclusion"] == "success"
                and item["workflow_id"] == workflow["id"]
                and item["head_repository"]["full_name"] == api.repo):
            return item["html_url"]
    raise ValueError("No successful main-push CI run for the exact candidate SHA")


def prepare(api, event_name, event, manual_tag=""):
    automatic = event_name == "workflow_run"
    if automatic:
        run = api.request(f"actions/runs/{event['workflow_run']['id']}")
        sha = run["head_sha"]
        ci_url = verify_ci(api, sha, run)
        tags = list(api.pages("tags"))
        matches = sorted((t["name"] for t in tags if VERSION.fullmatch(t["name"])
                          and t["commit"]["sha"] == sha), key=version, reverse=True)
        for tag in matches:
            if published_complete(api.release(tag)):
                return {"tag": tag, "sha": sha, "skip": "true", "ci_url": ci_url}
        if len(matches) > 1:
            raise ValueError("Multiple unfinished version tags at candidate SHA")
        tag = matches[0] if matches else next_tag([t["name"] for t in tags])
        if not matches:
            # Explicit ref creation pins the version even if main advances later.
            api.request("git/refs", {"ref": f"refs/tags/{tag}", "sha": sha})
    elif event_name in ("push", "workflow_dispatch"):
        tag = manual_tag if event_name == "workflow_dispatch" else event["ref"].removeprefix("refs/tags/")
        version(tag)
        sha = api.tag_sha(tag)
        ci_url = verify_ci(api, sha)
    else:
        raise ValueError(f"Unsupported event: {event_name}")
    version(tag)
    if api.tag_sha(tag) != sha:
        raise ValueError("Tag SHA changed during preparation")
    return {"tag": tag, "version": tag[1:], "sha": sha,
            "skip": str(published_complete(api.release(tag))).lower(), "ci_url": ci_url}


def publish(api, tag, sha, asset, notes, ci_url):
    version(tag)
    if api.tag_sha(tag) != sha:
        raise ValueError("Tag no longer matches the verified build")
    release = api.release(tag)
    if published_complete(release):
        return
    if not asset.is_file() or asset.stat().st_size == 0 or asset.name != ASSET:
        raise ValueError("Missing or invalid release asset")
    digest = "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest()
    if not release:
        generated = api.request("releases/generate-notes", {"tag_name": tag, "target_commitish": sha})
        body = notes.read_text() + f"\nSource: {sha}\nCI: {ci_url}\n\n" + generated["body"]
        release = api.request("releases", {"tag_name": tag, "target_commitish": sha,
                                          "name": tag, "body": body, "draft": True})
    # Clobber is restricted to drafts; published assets are immutable here.
    subprocess.run(["gh", "release", "upload", tag, str(asset), "--clobber", "--repo", api.repo], check=True)
    current = api.release(tag)
    if not current or not current["draft"]:
        raise ValueError("Release changed state during upload")
    uploaded = next((a for a in current["assets"] if a["name"] == ASSET), None)
    if not uploaded or uploaded["state"] != "uploaded" or uploaded["digest"] != digest:
        raise ValueError("Uploaded asset digest does not match verified local ZIP")
    if api.tag_sha(tag) != sha:
        raise ValueError("Tag changed before publication")
    api.request(f"releases/{release['id']}", {"draft": False, "make_latest": "legacy"}, method="PATCH")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("prepare", "publish"))
    parser.add_argument("--asset", type=Path)
    parser.add_argument("--notes", type=Path)
    args = parser.parse_args()
    api = API(os.environ["GITHUB_REPOSITORY"])
    if args.command == "prepare":
        outputs = prepare(api, os.environ["GITHUB_EVENT_NAME"],
                          json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
                          os.environ.get("INPUT_TAG", ""))
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in outputs.items():
                output.write(f"{key}={value}\n")
    else:
        publish(api, os.environ["RELEASE_TAG"], os.environ["RELEASE_SHA"],
                args.asset, args.notes, os.environ["CI_URL"])


if __name__ == "__main__":
    main()
