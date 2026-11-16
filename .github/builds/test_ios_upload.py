import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError


spec = importlib.util.spec_from_file_location("ios_upload", Path(__file__).with_name("upload-ios-release.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

KEY = b"-----BEGIN PRIVATE KEY-----\nZmFrZSBrZXk=\n-----END PRIVATE KEY-----\n"


class ArtifactSource(unittest.TestCase):
    def setUp(self):
        self.run = {
            "id": 123, "run_number": 6, "conclusion": "success", "status": "completed",
            "event": "workflow_dispatch", "head_branch": "example-branch",
            "path": ".github/workflows/botone-release-ios.yml",
        }

    def test_selects_artifact_from_successful_manual_run_on_the_same_branch(self):
        self.assertEqual(module.validate_source(self.run, "example-branch"), (123, "botone-ios-release-6"))

    def test_rejects_failed_unfinished_other_workflow_or_other_branch_runs(self):
        for field, value in [
            ("conclusion", "failure"), ("status", "in_progress"), ("event", "pull_request"),
            ("head_branch", "another-branch"), ("path", ".github/workflows/untrusted.yml"),
        ]:
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    module.validate_source({**self.run, field: value}, "example-branch")

    def test_new_build_uses_current_artifact_without_requesting_another_run(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = {"GITHUB_RUN_ID": "456", "GITHUB_RUN_NUMBER": "7", "GITHUB_OUTPUT": str(output)}
            with patch.dict(os.environ, env, clear=True), patch.object(module, "urlopen") as request:
                module.select_source()
            request.assert_not_called()
            self.assertEqual(output.read_text(), "run_id=456\nartifact=botone-ios-release-7\n")

    def test_reuse_fetches_run_from_current_repository_and_selects_its_number(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = {
                "SOURCE_RUN_ID": "123", "GITHUB_REPOSITORY": "example/repository",
                "GITHUB_REF_NAME": "example-branch", "GH_TOKEN": "fake-token", "GITHUB_OUTPUT": str(output),
            }
            with patch.dict(os.environ, env, clear=True):
                with patch.object(module, "urlopen", return_value=io.BytesIO(json.dumps(self.run).encode())) as request:
                    module.select_source()
            self.assertEqual(request.call_args.args[0].full_url, "https://api.github.com/repos/example/repository/actions/runs/123")
            self.assertEqual(output.read_text(), "run_id=123\nartifact=botone-ios-release-6\n")

    def test_invalid_source_id_or_api_failure_produces_no_outputs_or_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = {
                "GITHUB_REPOSITORY": "example/repository", "GITHUB_REF_NAME": "example-branch",
                "GH_TOKEN": "fake-token", "GITHUB_OUTPUT": str(output),
            }
            for source_id in ["../123", "https://example.com/123", "0", "123"]:
                with self.subTest(source_id=source_id):
                    with patch.dict(os.environ, {**env, "SOURCE_RUN_ID": source_id}, clear=True):
                        with patch.object(module, "urlopen", side_effect=URLError("fake-token")):
                            with self.assertRaises((ValueError, RuntimeError)) as error:
                                module.select_source()
                    self.assertNotIn("fake-token", str(error.exception))
                    self.assertFalse(output.exists())


class AppStoreUpload(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.ipa = self.root / "BotONE.ipa"
        self.ipa.write_bytes(b"fake IPA")
        self.env = {
            "APP_STORE_CONNECT_API_KEY_BASE64": base64.b64encode(KEY).decode(),
            "APP_STORE_CONNECT_KEY_ID": "FAKEKEY123",
            "APP_STORE_CONNECT_ISSUER_ID": "00000000-0000-4000-8000-000000000000",
            "RUNNER_TEMP": str(self.root),
        }

    def test_upload_uses_private_temp_key_and_cleans_it_after_success(self):
        key_paths = []

        def run(args, **kwargs):
            self.assertEqual(args[:3], ["xcrun", "altool", "--upload-app"])
            self.assertEqual(args[args.index("--file") + 1], str(self.ipa))
            self.assertEqual(args[args.index("--type") + 1], "ios")
            key = Path(kwargs["env"]["API_PRIVATE_KEYS_DIR"]) / "AuthKey_FAKEKEY123.p8"
            self.assertEqual(key.read_bytes(), KEY)
            if os.name != "nt":
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            key_paths.append(key)
            return subprocess.CompletedProcess(args, 0, json.dumps({"product-errors": []}), "")

        with patch.dict(os.environ, self.env, clear=True), patch.object(module.subprocess, "run", side_effect=run):
            module.upload(self.root)
        self.assertEqual(len(key_paths), 1)
        self.assertFalse(key_paths[0].parent.exists())

    def test_rejects_missing_or_invalid_credentials_before_spawning_uploader(self):
        for name, value in [
            ("APP_STORE_CONNECT_API_KEY_BASE64", "not base64!"),
            ("APP_STORE_CONNECT_API_KEY_BASE64", base64.b64encode(b"not a PEM key").decode()),
            ("APP_STORE_CONNECT_KEY_ID", "../unsafe"),
            ("APP_STORE_CONNECT_ISSUER_ID", "not-a-uuid"),
            ("APP_STORE_CONNECT_KEY_ID", ""),
        ]:
            with self.subTest(name=name, value=value):
                with patch.dict(os.environ, {**self.env, name: value}, clear=True):
                    with patch.object(module.subprocess, "run") as run:
                        with self.assertRaises(ValueError):
                            module.upload(self.root)
                        run.assert_not_called()

    def test_rejects_zero_or_multiple_ipas(self):
        self.ipa.unlink()
        with patch.dict(os.environ, self.env, clear=True), patch.object(module.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                module.upload(self.root)
            self.ipa.write_bytes(b"first")
            (self.root / "Other.ipa").write_bytes(b"second")
            with self.assertRaises(ValueError):
                module.upload(self.root)
            run.assert_not_called()

    def test_apple_failure_is_not_reported_as_success_or_leaked_to_logs(self):
        for exit_code in [0, 1]:
            response = json.dumps({"product-errors": [{"code": -19232, "message": "private account detail"}]})
            result = subprocess.CompletedProcess([], exit_code, response, "private stderr")
            with self.subTest(exit_code=exit_code):
                with patch.dict(os.environ, self.env, clear=True), patch.object(module.subprocess, "run", return_value=result):
                    with self.assertRaisesRegex(RuntimeError, "-19232") as error:
                        module.upload(self.root)
                self.assertNotIn("private", str(error.exception))
                self.assertEqual(list(self.root.glob("botone-asc-*")), [])

    def test_timeout_cleans_up_key_and_does_not_leak_captured_output(self):
        error = subprocess.TimeoutExpired(["private command"], 1200, output="private output")
        with patch.dict(os.environ, self.env, clear=True), patch.object(module.subprocess, "run", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "timed out") as raised:
                module.upload(self.root)
        self.assertNotIn("private", str(raised.exception))
        self.assertEqual(list(self.root.glob("botone-asc-*")), [])


if __name__ == "__main__":
    unittest.main()
