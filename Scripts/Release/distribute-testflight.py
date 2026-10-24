#!/usr/bin/env python3
"""Assign an uploaded build to CloudNow's external TestFlight group."""

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen


API_ROOT = "https://api.appstoreconnect.apple.com/v1"
EXTERNAL_GROUP_NAME = "Testers"
POLL_SECONDS = 60
MAX_WAIT_SECONDS = 5 * 60 * 60


class ReleaseError(Exception):
    """An expected App Store Connect or release-state error."""


def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def read_der_length(data, offset):
    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    width = first & 0x7F
    if width == 0 or width > 4 or offset + width > len(data):
        raise ReleaseError("OpenSSL returned an invalid ECDSA signature.")
    length = int.from_bytes(data[offset : offset + width], "big")
    return length, offset + width


def der_ecdsa_to_jose(signature):
    if not signature or signature[0] != 0x30:
        raise ReleaseError("OpenSSL returned an invalid ECDSA signature.")
    sequence_length, offset = read_der_length(signature, 1)
    if offset + sequence_length != len(signature):
        raise ReleaseError("OpenSSL returned an invalid ECDSA signature.")

    integers = []
    for _ in range(2):
        if offset >= len(signature) or signature[offset] != 0x02:
            raise ReleaseError("OpenSSL returned an invalid ECDSA signature.")
        integer_length, offset = read_der_length(signature, offset + 1)
        end = offset + integer_length
        if end > len(signature):
            raise ReleaseError("OpenSSL returned an invalid ECDSA signature.")
        integer = signature[offset:end].lstrip(b"\x00")
        if len(integer) > 32:
            raise ReleaseError("OpenSSL returned an invalid ECDSA signature.")
        integers.append(integer.rjust(32, b"\x00"))
        offset = end
    if offset != len(signature):
        raise ReleaseError("OpenSSL returned an invalid ECDSA signature.")
    return b"".join(integers)


class AppStoreConnect:
    def __init__(self, key_id, issuer_id, private_key):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.token = None
        self.token_expires_at = 0
        self.temp_dir = tempfile.TemporaryDirectory(prefix="testflight-api-")
        os.chmod(self.temp_dir.name, 0o700)
        self.key_path = Path(self.temp_dir.name) / "AuthKey.p8"
        self.key_path.write_text(private_key)
        self.key_path.chmod(0o600)

    def close(self):
        self.temp_dir.cleanup()

    def authorization_token(self):
        now = int(time.time())
        if self.token and now < self.token_expires_at - 60:
            return self.token

        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        claims = {
            "iss": self.issuer_id,
            "iat": now,
            "exp": now + 15 * 60,
            "aud": "appstoreconnect-v1",
        }
        unsigned = b".".join(
            (b64url(json.dumps(header, separators=(",", ":")).encode()),
             b64url(json.dumps(claims, separators=(",", ":")).encode()))
        )
        try:
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", str(self.key_path)],
                input=unsigned,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise ReleaseError("Could not sign an App Store Connect API token.") from error

        signature = b64url(der_ecdsa_to_jose(result.stdout))
        self.token = b".".join((unsigned, signature)).decode("ascii")
        self.token_expires_at = now + 15 * 60
        return self.token

    def request(self, method, path, body=None):
        url = f"{API_ROOT}{path}" if path.startswith("/") else path
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com":
            raise ReleaseError("App Store Connect returned an unexpected API URL.")

        data = None if body is None else json.dumps(body).encode("utf-8")
        request = Request(url, data=data, method=method)
        request.add_header("Authorization", f"Bearer {self.authorization_token()}")
        request.add_header("Accept", "application/json")
        if data is not None:
            request.add_header("Content-Type", "application/json")

        try:
            with urlopen(request, timeout=30) as response:
                payload = response.read()
        except HTTPError as error:
            raise ReleaseError(
                f"App Store Connect API returned HTTP {error.code} for {method} {parsed.path}."
            ) from error
        except (OSError, URLError) as error:
            raise ReleaseError(f"App Store Connect API request failed for {parsed.path}.") from error

        return json.loads(payload) if payload else {}

    def list_resources(self, path, params):
        url = f"{API_ROOT}{path}?{urlencode(params)}"
        resources = []
        while url:
            response = self.request("GET", url)
            resources.extend(response.get("data", []))
            url = response.get("links", {}).get("next")
        return resources


def unique_resource(resources, predicate, description):
    matches = [resource for resource in resources if predicate(resource)]
    if len(matches) != 1:
        raise ReleaseError(f"Expected exactly one {description}; found {len(matches)}.")
    return matches[0]


def find_app(client, bundle_id):
    apps = client.list_resources(
        "/apps",
        [("filter[bundleId]", bundle_id), ("fields[apps]", "bundleId,primaryLocale"), ("limit", "200")],
    )
    app = unique_resource(
        apps,
        lambda item: item.get("attributes", {}).get("bundleId") == bundle_id,
        "App Store Connect app for the configured Bundle ID",
    )
    return app["id"], app.get("attributes", {}).get("primaryLocale")


def find_build(client, app_id, version, build_number, deadline):
    params = [
        ("filter[app]", app_id),
        ("filter[version]", build_number),
        ("include", "preReleaseVersion"),
        ("fields[builds]", "version,processingState,buildAudienceType,preReleaseVersion"),
        ("fields[preReleaseVersions]", "version,platform"),
        ("limit", "200"),
    ]
    last_state = None
    while time.monotonic() < deadline:
        response = client.request("GET", f"/builds?{urlencode(params)}")
        included = {item["id"]: item for item in response.get("included", [])}
        candidates = []
        for build in response.get("data", []):
            relationships = build.get("relationships", {})
            prerelease = relationships.get("preReleaseVersion", {}).get("data") or {}
            prerelease_version = included.get(prerelease.get("id"), {}).get("attributes", {})
            attributes = build.get("attributes", {})
            if (
                attributes.get("version") == build_number
                and prerelease_version.get("version") == version
                and prerelease_version.get("platform") == "TV_OS"
            ):
                candidates.append(build)

        if candidates:
            build = unique_resource(candidates, lambda _: True, "matching tvOS build")
            state = build.get("attributes", {}).get("processingState")
            if state != last_state:
                print(f"App Store Connect build processing state: {state or 'unknown'}")
                last_state = state
            if state == "VALID":
                if build.get("attributes", {}).get("buildAudienceType") == "INTERNAL_ONLY":
                    raise ReleaseError("The uploaded build is marked TestFlight Internal Only.")
                return build
            if state in {"FAILED", "INVALID"}:
                raise ReleaseError(f"Apple could not process the uploaded build ({state}).")

        time.sleep(min(POLL_SECONDS, max(1, deadline - time.monotonic())))
    raise ReleaseError("Timed out waiting for Apple to finish processing this build.")


def find_external_group(client, app_id):
    groups = client.list_resources(
        f"/apps/{app_id}/betaGroups",
        [("fields[betaGroups]", "name,isInternalGroup"), ("limit", "200")],
    )
    group = unique_resource(
        groups,
        lambda item: item.get("attributes", {}).get("name") == EXTERNAL_GROUP_NAME
        and item.get("attributes", {}).get("isInternalGroup") is False,
        f'external beta group named "{EXTERNAL_GROUP_NAME}"',
    )
    return group["id"]


def set_what_to_test(client, build_id, locale, notes):
    if not notes.strip():
        print("No What to Test notes provided; leaving build notes unchanged.")
        return
    if not locale:
        raise ReleaseError("App Store Connect did not provide a primary app locale for build notes.")

    localizations = client.list_resources(
        f"/builds/{build_id}/betaBuildLocalizations",
        [("fields[betaBuildLocalizations]", "locale,whatsNew"), ("limit", "200")],
    )
    existing = [
        item for item in localizations
        if item.get("attributes", {}).get("locale") == locale
    ]
    if len(existing) > 1:
        raise ReleaseError("App Store Connect returned duplicate build-note localizations.")
    if existing:
        localization = existing[0]
        client.request(
            "PATCH",
            f"/betaBuildLocalizations/{localization['id']}",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": localization["id"],
                    "attributes": {"whatsNew": notes},
                }
            },
        )
    else:
        client.request(
            "POST",
            "/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": locale, "whatsNew": notes},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )
    print("Updated the TestFlight What to Test notes.")


def add_group_access(client, build_id, group_id):
    builds = client.list_resources(
        f"/betaGroups/{group_id}/relationships/builds",
        [("limit", "200")],
    )
    if any(build.get("id") == build_id for build in builds):
        print(f'Build is already assigned to the "{EXTERNAL_GROUP_NAME}" group.')
        return
    client.request(
        "POST",
        f"/betaGroups/{group_id}/relationships/builds",
        {"data": [{"type": "builds", "id": build_id}]},
    )
    print(f'Assigned build to the "{EXTERNAL_GROUP_NAME}" external group.')


def list_review_submissions(client, build_id):
    return client.list_resources(
        "/betaAppReviewSubmissions",
        [
            ("filter[build]", build_id),
            ("fields[betaAppReviewSubmissions]", "betaReviewState"),
            ("limit", "200"),
        ],
    )


def submit_for_review(client, build_id):
    submissions = list_review_submissions(client, build_id)
    if submissions:
        return unique_resource(submissions, lambda _: True, "beta review submission")

    try:
        response = client.request(
            "POST",
            "/betaAppReviewSubmissions",
            {
                "data": {
                    "type": "betaAppReviewSubmissions",
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )
        if response.get("data"):
            return response["data"]
    except ReleaseError as error:
        # A previous accepted request can race with the first status lookup.
        if "HTTP 409" not in str(error):
            raise
    submissions = list_review_submissions(client, build_id)
    return unique_resource(submissions, lambda _: True, "beta review submission")


def wait_for_approval(client, build_id, deadline):
    last_state = None
    while time.monotonic() < deadline:
        submissions = list_review_submissions(client, build_id)
        if len(submissions) > 1:
            raise ReleaseError("App Store Connect returned multiple beta review submissions for this build.")
        if submissions:
            state = submissions[0].get("attributes", {}).get("betaReviewState")
            if state != last_state:
                print(f"Apple beta review state: {state or 'unknown'}")
                last_state = state
            if state == "APPROVED":
                return
            if state == "REJECTED":
                raise ReleaseError("Apple rejected the build for external TestFlight testing.")
        time.sleep(min(POLL_SECONDS, max(1, deadline - time.monotonic())))
    raise ReleaseError(
        "Apple beta review is still pending. The build is assigned to Testers; automatic notifications are enabled for external testers."
    )


def enable_automatic_tester_notifications(client, build_id):
    response = client.request("GET", f"/builds/{build_id}/buildBetaDetail")
    detail = response.get("data", {})
    detail_id = detail.get("id")
    if not detail_id:
        raise ReleaseError("App Store Connect did not return beta details for this build.")
    if detail.get("attributes", {}).get("autoNotifyEnabled") is not True:
        client.request(
            "PATCH",
            f"/buildBetaDetails/{detail_id}",
            {
                "data": {
                    "type": "buildBetaDetails",
                    "id": detail_id,
                    "attributes": {"autoNotifyEnabled": True},
                }
            },
        )
    print("Automatic TestFlight notifications enabled for external testers.")


def required_env(name):
    value = os.environ.pop(name, "")
    if not value.strip():
        raise ReleaseError(f"Missing required workflow secret or value: {name}.")
    return value


def main():
    key_id = required_env("ASC_KEY_ID")
    issuer_id = required_env("ASC_ISSUER_ID")
    private_key = required_env("ASC_PRIVATE_KEY")
    bundle_id = required_env("APPLE_BUNDLE_ID")
    version = required_env("VERSION")
    build_number = required_env("BUILD_NUMBER")
    notes = os.environ.pop("WHAT_TO_TEST", "")

    if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
        raise ReleaseError("ASC_KEY_ID must be a 10-character App Store Connect key ID.")
    if not re.fullmatch(r"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}", issuer_id):
        raise ReleaseError("ASC_ISSUER_ID must be the Team API key issuer UUID.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ReleaseError("APPLE_BUNDLE_ID is not a valid bundle identifier.")
    if not re.fullmatch(r"[0-9]{1,4}\.[0-9]{1,2}(?:\.[0-9]{1,2})?", version):
        raise ReleaseError("VERSION is not a valid app version.")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", build_number):
        raise ReleaseError("BUILD_NUMBER is not a valid build number.")

    client = AppStoreConnect(key_id, issuer_id, private_key)
    del private_key
    deadline = time.monotonic() + MAX_WAIT_SECONDS
    try:
        app_id, locale = find_app(client, bundle_id)
        build = find_build(client, app_id, version, build_number, deadline)
        build_id = build["id"]
        group_id = find_external_group(client, app_id)
        set_what_to_test(client, build_id, locale, notes)
        enable_automatic_tester_notifications(client, build_id)
        add_group_access(client, build_id, group_id)
        submission = submit_for_review(client, build_id)
        state = submission.get("attributes", {}).get("betaReviewState")
        if state != "APPROVED":
            print("Build submitted for Apple TestFlight beta review.")
            wait_for_approval(client, build_id, deadline)
        summary = (
            f"Build {version} ({build_number}) was approved for external TestFlight testing and "
            f"automatic notifications are enabled for eligible testers in the {EXTERNAL_GROUP_NAME} group.\n"
        )
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as summary_file:
                summary_file.write(summary)
    finally:
        client.close()


if __name__ == "__main__":
    try:
        main()
    except ReleaseError as error:
        print(f"::error::{error}")
        raise SystemExit(1) from None
