#!/usr/bin/env bash
# Upload release assets, retrying the failures GitHub's upload service returns
# when several platform jobs attach to the same release at the same time.
#
#   scripts/attach-release-asset.sh <tag> <path>...
#
# `--clobber` is what makes a retry safe: the second attempt replaces whatever
# the first one managed to create, so the step is idempotent. 1.0.1-rc.2 lost
# its OHOS hap to `HTTP 500: Error creating asset temp dir` while three other
# jobs were uploading to the same release — the build itself had succeeded, and
# the same upload had gone through when that job ran alone.
set -euo pipefail

tag="${1:-}"
shift || true

if [[ -z "$tag" || "$#" -eq 0 ]]; then
  echo "usage: attach-release-asset.sh <tag> <path>..." >&2
  exit 2
fi

attempts=4
for ((attempt = 1; attempt <= attempts; attempt++)); do
  if gh release upload "$tag" "$@" --clobber; then
    exit 0
  fi

  if ((attempt == attempts)); then
    echo "::error::Uploading to $tag failed after $attempts attempts." >&2
    exit 1
  fi

  backoff=$((attempt * 10))
  echo "Upload failed (attempt $attempt of $attempts); retrying in ${backoff}s." >&2
  sleep "$backoff"
done
