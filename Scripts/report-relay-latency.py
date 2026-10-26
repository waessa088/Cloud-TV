#!/usr/bin/env python3
"""Surface the relay loopback benchmark line from the newest .xcresult."""
import glob
import os
import re
import subprocess

pattern = re.compile(r"RELAY_LOOPBACK_LATENCY[^\n\"\\]*")
results = sorted(glob.glob("TestArtifacts/**/*.xcresult", recursive=True), key=os.path.getmtime)
found = set()
for path in reversed(results):
    for log_type in ("console", "action"):
        out = subprocess.run(
            ["xcrun", "xcresulttool", "get", "log", "--path", path, "--type", log_type],
            capture_output=True, text=True,
        )
        found.update(pattern.findall(out.stdout))
    if found:
        break
if not found:
    out = subprocess.run(["grep", "-raoh", "RELAY_LOOPBACK_LATENCY[^\"]*", "TestArtifacts"], capture_output=True, text=True)
    found.update(line.strip() for line in out.stdout.splitlines()[:3])
for line in sorted(found)[:3]:
    print(f"::notice::{line}")
if not found:
    print("::warning::Relay benchmark line not found in test output")
