#!/usr/bin/env bash
# Build the OHOS hap without signing material and stage it for a release.
#
# Used by .github/workflows/ohos-release.yml, and runnable locally on a machine
# with the OHOS Flutter fork + DevEco command-line tools on PATH:
#
#   scripts/build-unsigned-hap.sh
#
# The build is judged by the artifact, not by flutter's exit code:
# `flutter build hap` ends by looking for the *signed* hap named after the
# signing config, so with OHOS_UNSIGNED=1 it reports "Hvigor build failed to
# produce an hap file" even though hvigor wrote the unsigned hap we want.

set -euo pipefail

cd "$(dirname "$0")/.."

hap="ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"
version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
if [[ -z "$version" ]]; then
  echo "No version in pubspec.yaml" >&2
  exit 1
fi

rm -f "$hap"

set +e
OHOS_UNSIGNED=1 flutter build hap --release
build_status=$?
set -e

if [[ ! -f "$hap" ]]; then
  echo "hvigor produced no $hap (flutter exited $build_status)" >&2
  exit 1
fi

mkdir -p dist
artifact="techpie-${version//+/_}-unsigned.hap"
cp "$hap" "dist/$artifact"

# Downloaders cannot verify what they cannot see, so publish the digest next to
# the artifact and let release notes reference it.
(
  cd dist
  sha256sum "$artifact" | tee "$artifact.sha256"
)
