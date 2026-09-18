#!/usr/bin/env bash
# Build the OHOS App Pack (`.app`) without signing material and stage it for a
# release.
#
# Used by .github/workflows/ohos-release.yml, and runnable locally on a machine
# with the OHOS Flutter fork + DevEco command-line tools on PATH:
#
#   scripts/build-ohos-app.sh
#
# Why this exists next to build-unsigned-hap.sh: a `.hap` is what you install on a
# device, and `.app` is what AppGallery publishes — a pack holding the hap(s)
# plus `pack.info`. Both are built here, and only the pack can be uploaded.
#
# Both are also unsigned, which is deliberate (CLAUDE.md → Releasing): the
# signing happens on the device owner's machine, so AppGallery upload is a
# maintainer step: sign this pack, then upload it.
#
# The build is judged by the artifact, not by flutter's exit code — the same trap
# as the hap. `flutter build app` ends by looking for `ohos-default-signed.app`,
# so with OHOS_UNSIGNED=1 it reports "Hvigor build failed to produce an app file"
# after hvigor has written the unsigned pack we want. Its message also names the
# wrong directory, which is how this script learned to glob.

set -euo pipefail

cd "$(dirname "$0")/.."

# Unsigned is the point of this script: with OHOS_UNSIGNED=1 the generator writes
# a build-profile.json5 with no signingConfigs block, which is what makes hvigor
# pack `-unsigned` artifacts instead of looking for a certificate. (`flutter build
# app` only refuses when that block is an *empty list*; absent is fine.)
export OHOS_UNSIGNED=1

pack_dir="ohos/build/outputs/default"

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

rm -rf "$pack_dir"

# Render the two gitignored manifests from their committed templates up front.
# hvigorfile.ts does this on every hvigor invocation, but flutter_tools discovers
# the `entry` module by reading ohos/build-profile.json5 *before* it starts
# hvigor — so a checkout that has never been built (CI's, or a fresh clone)
# otherwise stops at "this ohos project don't have a entry module".
node ohos/scripts/generate-build-profile.mjs

set +e
flutter build app --release
build_status=$?
set -e

# The pack is named after the project rather than the module, and flutter looks
# for the `-signed` one, so find whatever hvigor actually wrote.
shopt -s nullglob
built=("$pack_dir"/*-unsigned.app)
shopt -u nullglob

if (( ${#built[@]} == 0 )); then
  echo "hvigor produced no App Pack in $pack_dir (flutter exited $build_status)" >&2
  ls -l "$pack_dir" >&2 || true
  exit 1
fi
if (( ${#built[@]} > 1 )); then
  echo "More than one unsigned App Pack in $pack_dir:" >&2
  printf '  %s\n' "${built[@]}" >&2
  exit 1
fi

mkdir -p dist
# TechPie-<release name>-ohos-<arch>-unsigned.app, by the same grammar as every
# other artifact. The token names what the pack was built for, which is the one
# architecture the hap beside it carries.
artifact="TechPie-${release_name}-ohos-arm64v8-unsigned.app"
cp "${built[0]}" "dist/$artifact"

# Downloaders cannot verify what they cannot see, so publish the digest next to
# the artifact and let release notes reference it.
(
  cd dist
  sha256sum "$artifact" | tee "$artifact.sha256"
)
