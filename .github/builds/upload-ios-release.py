"""Upload a signed IPA to App Store Connect without EAS or App Review submission."""

import base64
import binascii
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import uuid


def validate_source(run, branch):
    if (
        run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != branch
        or run.get("path") != ".github/workflows/botone-release-ios.yml"
    ):
        raise ValueError("Reuse requires a successful manual BotONE iOS release run on the selected branch.")
    return int(run["id"]), f"botone-ios-release-{int(run['run_number'])}"


def select_source():
    source = os.environ.get("SOURCE_RUN_ID", "")
    if source:
        if not re.fullmatch(r"[1-9][0-9]*", source):
            raise ValueError("source_run_id must be the numeric Actions run ID, not its run number or URL.")
        request = Request(
            f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{source}",
            headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json"},
        )
        try:
            with urlopen(request, timeout=60) as response:
                run = json.load(response)
        except (HTTPError, URLError):
            raise RuntimeError("Could not read the source run from this repository; check its ID and Actions read permission.") from None
        run_id, artifact = validate_source(run, os.environ["GITHUB_REF_NAME"])
    else:
        run_id = int(os.environ["GITHUB_RUN_ID"])
        artifact = f"botone-ios-release-{int(os.environ['GITHUB_RUN_NUMBER'])}"
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"run_id={run_id}\nartifact={artifact}\n")


def credentials():
    names = ["APP_STORE_CONNECT_API_KEY_BASE64", "APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID"]
    for name in names:
        if not os.environ.get(name, "").strip():
            raise ValueError(f"Missing repository secret: {name}")
    key_id = os.environ[names[1]]
    issuer = os.environ[names[2]]
    if not re.fullmatch(r"[A-Za-z0-9]{10}", key_id):
        raise ValueError("APP_STORE_CONNECT_KEY_ID must be the 10-character API key ID.")
    try:
        uuid.UUID(issuer)
    except ValueError:
        raise ValueError("APP_STORE_CONNECT_ISSUER_ID must be an issuer UUID.") from None
    try:
        key = base64.b64decode(os.environ[names[0]], validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("APP_STORE_CONNECT_API_KEY_BASE64 must contain the Base64 of the complete .p8 file.") from None
    if not key.startswith(b"-----BEGIN PRIVATE KEY-----") or not key.rstrip().endswith(b"-----END PRIVATE KEY-----"):
        raise ValueError("APP_STORE_CONNECT_API_KEY_BASE64 must decode to a PEM private key (.p8).")
    return key_id, issuer, key


def upload(directory):
    key_id, issuer, key = credentials()
    ipas = list(Path(directory).glob("*.ipa"))
    if len(ipas) != 1 or not ipas[0].is_file():
        raise ValueError("Expected exactly one signed IPA in the downloaded artifact.")
    with tempfile.TemporaryDirectory(prefix="botone-asc-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        private_key = Path(temporary) / f"AuthKey_{key_id}.p8"
        with open(os.open(private_key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as output:
            output.write(key)
        try:
            result = subprocess.run(
                ["xcrun", "altool", "--upload-app", "--type", "ios", "--file", str(ipas[0]),
                 "--apiKey", key_id, "--apiIssuer", issuer, "--output-format", "json"],
                env={**os.environ, "API_PRIVATE_KEYS_DIR": temporary},
                capture_output=True, text=True, timeout=1200,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("App Store Connect upload timed out. Check TestFlight before retrying the same build.") from None
    # Apple's raw output may include account information; report numeric error codes only.
    errors = []
    for stream in [result.stdout, result.stderr]:
        try:
            payload = json.loads(stream)
        except (ValueError, TypeError):
            continue
        if isinstance(payload, dict):
            errors.extend(payload.get("product-errors") or [])
    if result.returncode or errors:
        codes = [str(error["code"]) for error in errors if isinstance(error, dict) and isinstance(error.get("code"), int)]
        detail = f"Apple error codes: {', '.join(codes)}." if codes else f"Uploader exit code: {result.returncode}."
        raise RuntimeError(
            f"App Store Connect upload failed. {detail} Check API key permissions, the app's Bundle ID, "
            "agreements and whether this version/build number was already uploaded."
        )
    print("IPA uploaded to App Store Connect. Apple processing and TestFlight setup are still required.")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--select-source"]:
            select_source()
        elif sys.argv[1:] == ["--validate-only"]:
            credentials()
            print("App Store Connect upload secrets validated.")
        elif len(sys.argv) == 2:
            upload(sys.argv[1])
        else:
            raise ValueError("Pass the IPA directory, --select-source or --validate-only.")
    except Exception as error:
        # Do not expose traceback, command arguments, credentials or raw service responses.
        message = str(error) if isinstance(error, (ValueError, RuntimeError)) else "App Store Connect upload preparation failed."
        print(f"::error::{message}", flush=True)
        raise SystemExit(1) from None
