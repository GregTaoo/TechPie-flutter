#!/usr/bin/env bash
# Print the release name of a release tag.
#
#   scripts/release-name.sh v1.0.1+5               -> 1.0.1
#   scripts/release-name.sh v1.0.1-rc.2+5          -> 1.0.1-rc.2
#   scripts/release-name.sh android-v1.0.0-rc.1+3  -> 1.0.0-rc.1
#
# This is the one place the tag-to-release-name rule lives, because four things
# have to agree with it: the artifact file names, the release title, the release
# page and the tags themselves (CLAUDE.md → Artifact names). The build number is
# deliberately not part of the result: it is global history, not a version, and a
# file name has to say which version it is.
set -euo pipefail

tag="${1:-}"
if [[ -z "$tag" ]]; then
  echo "usage: release-name.sh <release tag>" >&2
  exit 2
fi

# Group 1 is the legacy `android-` prefix, 2 is X.Y.Z, 3 the pre-release name,
# 4 the build number: POSIX ERE has no non-capturing groups, hence the offset.
if [[ ! "$tag" =~ ^(android-)?v([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z][0-9A-Za-z.-]*)?\+([0-9]+)$ ]]; then
  echo "release-name.sh: not a release tag: $tag" >&2
  echo "expected vX.Y.Z+B, or vX.Y.Z-rc.N+B for a candidate" >&2
  exit 1
fi

printf '%s%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
