import hashlib
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import release

SHA = "a" * 40
OTHER_SHA = "b" * 40
REPO = "initor/ghostty-screensaver"


class FakeAPI:
    repo = REPO

    def __init__(self):
        self.tags = {"v1.7.1": OTHER_SHA}
        self.releases = {}
        self.writes = []
        self.compare = "ahead"
        self.run = {"head_sha": SHA, "head_branch": "main", "event": "push",
                    "conclusion": "success", "workflow_id": 7,
                    "head_repository": {"full_name": REPO}, "html_url": "https://example.com/run"}

    def request(self, path, data=None, method=None):
        if data is not None:
            self.writes.append((path, data, method))
            if path == "git/refs":
                tag = data["ref"].removeprefix("refs/tags/")
                if tag in self.tags:
                    raise ValueError("Tag conflict")
                self.tags[tag] = data["sha"]
            elif path == "releases/generate-notes":
                return {"body": "Generated notes"}
            elif path == "releases":
                self.releases[data["tag_name"]] = dict(data, id=1, assets=[])
                return self.releases[data["tag_name"]]
            return {}
        if path.startswith("compare/"):
            return {"status": self.compare}
        if path == "actions/workflows/build.yml":
            return {"id": 7}
        if path.startswith("actions/runs/"):
            return self.run
        raise AssertionError(path)

    def pages(self, path, key=None):
        if path == "tags":
            return [{"name": name, "commit": {"sha": sha}} for name, sha in self.tags.items()]
        return [self.run]

    def tag_sha(self, tag):
        return self.tags[tag]

    def release(self, tag):
        return self.releases.get(tag)


def complete():
    return {"draft": False, "assets": [{"name": release.ASSET, "state": "uploaded", "size": 1}]}


class ReleaseTests(unittest.TestCase):
    def auto(self, api):
        return release.prepare(api, "workflow_run", {"workflow_run": {"id": 123}})

    def test_api_only_treats_404_as_missing(self):
        for code in (404, 403, 500):
            error = urllib.error.HTTPError("https://api.github.com/", code, "error", {}, None)
            with self.subTest(code=code), patch.dict("os.environ", {"GH_TOKEN": "test"}), patch(
                    "release.urllib.request.urlopen", side_effect=error):
                if code == 404:
                    self.assertIsNone(release.API(REPO).release("v1.7.2"))
                else:
                    with self.assertRaises(urllib.error.HTTPError):
                        release.API(REPO).release("v1.7.2")

    def test_numeric_patch_and_stable_filter(self):
        self.assertEqual(release.next_tag(["v1.9.9", "v1.10.10", "v2.0.0-rc1", "garbage"]), "v1.10.11")
        self.assertEqual(release.next_tag([]), "v1.0.0")

    def test_invalid_versions(self):
        for tag in ["v01.2.3", "v1.2", "v1.2.3-rc1", "v1.2.3\n", 'v1.2.3;touch bad']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version(tag)

    def test_exact_sha_reservation(self):
        api = FakeAPI()
        result = self.auto(api)
        self.assertEqual((result["tag"], result["sha"], result["skip"]), ("v1.7.2", SHA, "false"))
        self.assertEqual(api.writes, [("git/refs", {"ref": "refs/tags/v1.7.2", "sha": SHA}, None)])

    def test_rerun_reuses_reserved_tag(self):
        api = FakeAPI()
        first = self.auto(api)
        self.assertEqual(self.auto(api), first)
        self.assertEqual(len(api.writes), 1)

    def test_published_commit_skips_without_increment(self):
        api = FakeAPI()
        api.tags["v1.7.2"] = SHA
        api.releases["v1.7.2"] = complete()
        self.assertEqual(self.auto(api)["skip"], "true")
        self.assertFalse(api.writes)

    def test_incomplete_published_release_fails_closed(self):
        api = FakeAPI()
        api.tags["v1.7.2"] = SHA
        api.releases["v1.7.2"] = {"draft": False, "assets": []}
        with self.assertRaises(ValueError):
            self.auto(api)
        self.assertFalse(api.writes)

    def test_multiple_unfinished_tags_fail(self):
        api = FakeAPI()
        api.tags.update({"v1.7.2": SHA, "v1.7.3": SHA})
        with self.assertRaises(ValueError):
            self.auto(api)

    def test_untrusted_or_unsuccessful_ci_rejected(self):
        for key, value in [("event", "pull_request"), ("conclusion", "failure"),
                           ("head_branch", "feature"), ("workflow_id", 99),
                           ("head_repository", {"full_name": "attacker/fork"})]:
            with self.subTest(key=key):
                api = FakeAPI()
                api.run[key] = value
                with self.assertRaises(ValueError):
                    self.auto(api)
                self.assertFalse(api.writes)

    def test_non_main_ancestor_rejected(self):
        api = FakeAPI()
        api.compare = "diverged"
        with self.assertRaises(ValueError):
            self.auto(api)

    def test_manual_and_tag_use_same_exact_ci_gate(self):
        for event_name, event, tag in [("push", {"ref": "refs/tags/v1.7.2"}, ""),
                                       ("workflow_dispatch", {}, "v1.7.2")]:
            with self.subTest(event=event_name):
                api = FakeAPI()
                api.tags["v1.7.2"] = SHA
                result = release.prepare(api, event_name, event, tag)
                self.assertEqual(result["sha"], SHA)
                self.assertFalse(api.writes)
                api.run["head_sha"] = OTHER_SHA
                with self.assertRaises(ValueError):
                    release.prepare(api, event_name, event, tag)

    def test_published_assets_never_uploaded_again(self):
        api = FakeAPI()
        api.tags["v1.7.2"] = SHA
        api.releases["v1.7.2"] = complete()
        with patch("release.subprocess.run") as upload:
            release.publish(api, "v1.7.2", SHA, Path("missing"), Path("missing"), "")
            upload.assert_not_called()
        self.assertFalse(api.writes)

    def test_moved_tag_rejected(self):
        api = FakeAPI()
        with self.assertRaises(ValueError):
            release.publish(api, "v1.7.1", SHA, Path("missing"), Path("missing"), "")
        self.assertFalse(api.writes)

    def test_draft_publish_and_digest_gate(self):
        for existing_draft in (True, False):
            for good_digest in (True, False):
                with self.subTest(draft=existing_draft, good_digest=good_digest), tempfile.TemporaryDirectory() as tmp:
                    api = FakeAPI()
                    api.tags["v1.7.2"] = SHA
                    if existing_draft:
                        api.releases["v1.7.2"] = {"id": 1, "draft": True, "assets": []}
                    asset = Path(tmp) / release.ASSET
                    asset.write_bytes(b"zip content")
                    notes = Path(tmp) / "notes"
                    notes.write_text("Installation")

                    def upload(*args, **kwargs):
                        api.releases["v1.7.2"]["assets"] = [{"name": release.ASSET, "state": "uploaded",
                            "digest": "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest() if good_digest else "bad"}]

                    with patch("release.subprocess.run", side_effect=upload):
                        if good_digest:
                            release.publish(api, "v1.7.2", SHA, asset, notes, "https://example.com/ci")
                        else:
                            with self.assertRaises(ValueError):
                                release.publish(api, "v1.7.2", SHA, asset, notes, "https://example.com/ci")
                    patches = [w for w in api.writes if w[2] == "PATCH"]
                    self.assertEqual(bool(patches), good_digest)
                    creates = [w for w in api.writes if w[0] == "releases"]
                    self.assertEqual(bool(creates), not existing_draft)


if __name__ == "__main__":
    unittest.main()
