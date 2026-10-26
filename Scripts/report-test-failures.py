#!/usr/bin/env python3
"""Print failing tests from the newest .xcresult as GitHub error annotations."""
import glob
import json
import os
import subprocess
import sys

results = sorted(glob.glob("TestArtifacts/**/*.xcresult", recursive=True), key=os.path.getmtime)
if not results:
    print("::error::No .xcresult found")
    sys.exit(0)
path = results[-1]
raw = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path, "--compact"],
    capture_output=True, text=True,
)
if raw.returncode != 0:
    print(f"::error::xcresulttool failed: {raw.stderr.strip()[:300]}")
    sys.exit(0)
data = json.loads(raw.stdout)
count = 0


def walk(node, trail):
    global count
    name = node.get("name", "")
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
        messages = [
            child.get("name", "")
            for child in node.get("children", [])
            if child.get("nodeType") == "Failure Message"
        ]
        count += 1
        if count <= 40:
            detail = " | ".join(messages)[:600] or "failed"
            print(f"::error::{' / '.join(trail[-2:] + [name])}: {detail}")
    for child in node.get("children", []):
        walk(child, trail + [name] if name else trail)


for root in data.get("testNodes", []):
    walk(root, [])
print(f"::notice::{count} failing test case(s)")
