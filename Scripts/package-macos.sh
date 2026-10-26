#!/usr/bin/env bash
# Packages the Mac Catalyst archive as Nimbus.app inside a zip.
# Apple Silicon refuses to run unsigned code, so the app is signed ad hoc
# (no Apple account involved); Gatekeeper still asks the user to approve it once.
set -euo pipefail

archive="$1"
output="$2"
work="$(mktemp -d)"

cp -R "$archive/Products/Applications/CloudNow.app" "$work/Nimbus.app"
codesign --force --deep --sign - "$work/Nimbus.app"
codesign --verify --deep --strict "$work/Nimbus.app"
ditto -c -k --keepParent "$work/Nimbus.app" "$output"
echo "Packaged $output"
