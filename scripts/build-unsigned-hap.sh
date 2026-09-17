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

# Unsigned is the point of this script: with OHOS_UNSIGNED=1 the generator writes
# a build-profile.json5 with no signingConfigs block, which is what makes hvigor
# pack `entry-default-unsigned.hap` instead of looking for a certificate.
export OHOS_UNSIGNED=1

hap="ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"

# What the artifact is named after is the release name — `1.0.1`, or `1.0.1-rc.2`
# for a candidate (see CLAUDE.md → Artifact names). Three sources, in order of how
# much each knows: release.yml hands it over; a checkout sitting on a release tag
# *is* that release; a plain working copy only knows what pubspec declares, and
# the `-rc.N` of a candidate is derived from tags at release time, so pubspec
# alone cannot carry it. The build number is in none of them.
release_name="${RELEASE_NAME:-}"
if [[ -z "$release_name" ]]; then
  if tag="$(git describe --tags --exact-match --tags --match 'v*' 2>/dev/null)"; then
    release_name="${tag#v}"
  else
    release_name="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
    if [[ -z "$release_name" ]]; then
      echo "No version in pubspec.yaml, and RELEASE_NAME is unset" >&2
      exit 1
    fi
  fi
  release_name="${release_name%%+*}"
fi

rm -f "$hap"

# Render the two gitignored manifests from their committed templates up front.
# hvigorfile.ts does this on every hvigor invocation, but flutter_tools discovers
# the `entry` module by reading ohos/build-profile.json5 *before* it starts
# hvigor — so a checkout that has never been built (CI's, or a fresh clone)
# otherwise stops at "this ohos project don't have a entry module".
node ohos/scripts/generate-build-profile.mjs

set +e
flutter build hap --release
build_status=$?
set -e

if [[ ! -f "$hap" ]]; then
  echo "hvigor produced no $hap (flutter exited $build_status)" >&2
  exit 1
fi

mkdir -p dist
artifact="TechPie-${release_name}-ohos-arm64v8-unsigned.hap"
cp "$hap" "dist/$artifact"

# Downloaders cannot verify what they cannot see, so publish the digest next to
# the artifact and let release notes reference it.
(
  cd dist
  sha256sum "$artifact" | tee "$artifact.sha256"
)
