#!/usr/bin/env node
// Compute the release plan for a branch push, from the single version source:
// pubspec.yaml (`version: X.Y.Z[-pre.N]+B`).
//
// Called by .github/workflows/release.yml, and runnable locally:
//
//   node scripts/release-plan.mjs --ref master --changed true
//   node scripts/release-plan.mjs --ref release/1.0.0 --changed true
//
// The plan is written as `key=value` lines to stdout (GitHub Actions reads them
// via $GITHUB_OUTPUT). Channels:
//
//   master              → prerelease: every pubspec version change ships a
//                         pre-release, so a branch push is enough to publish.
//   release/X.Y.Z       → stable: the branch declares the version it freezes,
//                         and pubspec must agree with it.
//
// Version stamps handed to the platform builds never carry the pre-release
// part: iOS rejects a CFBundleShortVersionString like `1.0.0-rc.1`, and keeping
// Android identical means one artifact per release everywhere. The pre-release
// name lives in the release name and in the Android tag (which the Android
// workflow uses to mark the GitHub release as a pre-release).

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

function parseArgs(argv) {
  const opts = { ref: 'master', changed: 'true' };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const value = argv[++i];
    if (value == null) throw new Error(`Missing value for ${arg}`);
    opts[key] = value;
  }
  return opts;
}

/// `version: X.Y.Z[-pre.N]+B` → { base, pre, code }.
function readVersion() {
  const pubspecPath = resolve(repoRoot, 'pubspec.yaml');
  const match = /^version:\s*(\S+)\s*$/m.exec(readFileSync(pubspecPath, 'utf8'));
  if (!match) throw new Error(`No "version:" line in ${pubspecPath}`);
  const raw = match[1];
  const plus = raw.indexOf('+');
  if (plus < 0) {
    throw new Error(
      `pubspec version "${raw}" has no "+B" build number; the build number is ` +
        `what stores require to increase, so it must live in pubspec.yaml too.`,
    );
  }
  const name = raw.slice(0, plus);
  const codeText = raw.slice(plus + 1);
  const code = Number(codeText);
  if (!/^[0-9]+$/.test(codeText) || !Number.isInteger(code) || code <= 0) {
    throw new Error(`Unusable build number "${codeText}" in version "${raw}"`);
  }
  const dash = name.indexOf('-');
  const base = dash < 0 ? name : name.slice(0, dash);
  const pre = dash < 0 ? '' : name.slice(dash + 1);
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(base)) {
    throw new Error(`Version "${raw}" is not X.Y.Z[-pre.N]+B shaped`);
  }
  return { raw, base, pre, code };
}

function gitRevParse(rev) {
  return execFileSync('git', ['rev-parse', rev], { cwd: repoRoot, encoding: 'utf8' }).trim();
}

/// Tags that point at the commit being released. Re-running a workflow must be
/// a no-op, so these are excluded from every "what was released before" check.
function tagsAtHead(tags) {
  const head = gitRevParse('HEAD');
  const atHead = new Set();
  for (const tag of tags) {
    if (gitRevParse(tag) === head) atHead.add(tag);
  }
  return atHead;
}

function gitTags() {
  return execFileSync('git', ['tag', '--list'], { cwd: repoRoot, encoding: 'utf8' })
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

/// Highest build number already shipped on Android: the Play Store requires it
/// to increase across the whole application, so every Android tag counts.
function highestAndroidCode(tags) {
  let highest = 0;
  for (const tag of tags) {
    const match = /^android-v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\+([0-9]+)$/.exec(tag);
    if (match) highest = Math.max(highest, Number(match[1]));
  }
  return highest;
}

/// Highest build number already shipped for [base] on iOS. App Store Connect
/// only requires monotonicity inside a version train, which is also how the
/// iOS history here was tagged (`ios-v0.1.0+8` never constrained `0.3.0+1`).
function highestIosCode(tags, base) {
  const pattern = new RegExp(
    `^ios-v${base.replaceAll('.', '\\.')}\\+([0-9]+)$`,
  );
  let highest = 0;
  for (const tag of tags) {
    const match = pattern.exec(tag);
    if (match) highest = Math.max(highest, Number(match[1]));
  }
  return highest;
}

/// Pre-release ordinal for [base]: one past the highest already-tagged rc/beta
/// for the same base version, so `1.0.0-rc.1` is followed by `1.0.0-rc.2`.
function nextPrereleaseOrdinal(tags, base) {
  let highest = 0;
  for (const tag of tags) {
    const match = new RegExp(
      `^(?:android|ios)-v${base.replaceAll('.', '\\.')}-rc\\.([0-9]+)\\+[0-9]+$`,
    ).exec(tag);
    if (match) highest = Math.max(highest, Number(match[1]));
  }
  return highest + 1;
}

/// Highest product version already shipped as a *stable* Android release, so a
/// release branch cannot regress the line (e.g. release/1.0.0 after 1.1.0).
function highestStableBase(tags) {
  let highest = null;
  for (const tag of tags) {
    const match = /^android-v([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+$/.exec(tag);
    if (!match) continue;
    if (highest == null || compareVersions(match[1], highest) > 0) highest = match[1];
  }
  return highest;
}

/// -1 / 0 / 1 for X.Y.Z names.
function compareVersions(left, right) {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

function plan(opts) {
  const version = readVersion();
  const allTags = gitTags();
  const atHead = tagsAtHead(allTags);
  const tags = allTags.filter((tag) => !atHead.has(tag));

  const stableMatch = /^release\/([0-9]+\.[0-9]+\.[0-9]+)$/.exec(opts.ref);
  const channel = stableMatch ? 'stable' : 'prerelease';

  if (channel === 'stable') {
    const frozen = stableMatch[1];
    if (frozen !== version.base) {
      throw new Error(
        `Branch ${opts.ref} freezes ${frozen}, but pubspec.yaml says ${version.raw}. ` +
          `A release branch must carry exactly the version it releases.`,
      );
    }
    if (version.pre !== '') {
      throw new Error(
        `${opts.ref} is a stable release branch, but pubspec.yaml says ` +
          `${version.raw}; drop the "-${version.pre}" part (or drop the branch).`,
      );
    }
    // A patch branch for an older line is legitimate, so this is a warning, not
    // a refusal: the maintainer sees it in the run summary and decides.
    const shipped = highestStableBase(allTags.filter((tag) => !atHead.has(tag)));
    if (shipped != null && compareVersions(version.base, shipped) < 0) {
      console.error(
        `[release-plan] warning: ${opts.ref} releases ${version.base}, but ` +
          `${shipped} already shipped as a stable release. Continuing — say so ` +
          `explicitly if this is not a maintenance release.`,
      );
    }
  }

  // A pre-release name is either declared in pubspec (author's choice) or
  // derived from the version's own history: the next rc for this base version.
  const releaseName =
    channel === 'stable'
      ? version.base
      : version.pre !== ''
        ? version.raw.slice(0, version.raw.indexOf('+'))
        : `${version.base}-rc.${nextPrereleaseOrdinal(tags, version.base)}`;

  const androidHighest = highestAndroidCode(tags);
  const iosHighest = highestIosCode(tags, version.base);
  if (version.code <= androidHighest) {
    throw new Error(
      `pubspec build number ${version.code} is not above the released Android ` +
        `build ${androidHighest} (android-v…+${androidHighest}); Play requires an ` +
        `increase, so bump to "+${androidHighest + 1}" or higher.`,
    );
  }
  if (version.code <= iosHighest) {
    throw new Error(
      `pubspec build number ${version.code} is not above the released iOS build ` +
        `${iosHighest} for ${version.base}; App Store Connect refuses a lower ` +
        `build under the same version, so bump to "+${iosHighest + 1}" or higher.`,
    );
  }

  const tagAndroid = `android-v${releaseName}+${version.code}`;
  const tagIos = `ios-v${version.base}+${version.code}`;
  const existing = [tagAndroid, tagIos].filter((tag) => allTags.includes(tag));
  if (existing.length > 0) {
    // Same commit → this release already went out, so there is nothing to do.
    // A tag pointing somewhere else means the build number was reused.
    if (existing.some((tag) => !atHead.has(tag))) {
      throw new Error(
        `Tag(s) ${existing.join(', ')} already exist for a different commit; ` +
          `bump the build number in pubspec.yaml to publish another release.`,
      );
    }
    return {
      skip: true,
      reason: `release ${releaseName} (build ${version.code}) is already tagged at this commit`,
    };
  }

  return {
    skip: false,
    channel,
    version: version.raw,
    base: version.base,
    code: String(version.code),
    release_name: releaseName,
    tag_android: tagAndroid,
    tag_ios: tagIos,
    prerelease: channel === 'prerelease' ? 'true' : 'false',
  };
}

try {
  const opts = parseArgs(process.argv);
  const changed = opts.changed !== 'false';
  const result = !changed
    ? { skip: true, reason: 'pubspec.yaml version unchanged in this push' }
    : plan(opts);
  for (const [key, value] of Object.entries(result)) {
    console.log(`${key}=${value}`);
  }
  // Summary goes to stderr: stdout is parsed as key=value by the workflow.
  console.error(
    result.skip
      ? `[release-plan] no release: ${result.reason}`
      : `[release-plan] ${result.channel} ${result.release_name} (build ${result.code})` +
          ` → ${result.tag_android}, ${result.tag_ios}`,
  );
} catch (err) {
  console.error(`[release-plan] ${err.message}`);
  process.exit(1);
}
