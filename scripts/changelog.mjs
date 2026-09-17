#!/usr/bin/env node
// Read one release's notes out of CHANGELOG.md.
//
// Sections are keyed by *product version* (`## [1.0.0]`), not by release name, so
// every candidate of a line and the stable release that ends it share a section.
// Two reasons: the rc ordinal is derived from the tags, so nobody could write its
// heading in advance, and "what is in 1.0.0" is the unit a user cares about.
//
//   node scripts/changelog.mjs 1.0.0     # prints that section, or fails
//
// `release-plan.mjs` refuses a release whose version has no section, and the tag
// job copies the same text into the tag annotation — which is where the GitHub
// release page gets its notes from.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

/// A heading line. The version is the key, so anything after it — a date, a note —
/// does not hide the section from the release that looks it up.
const HEADING = /^##\s+\[?([^\]\s]+)\]?/;

/// The pubspec's sibling changelog.
export function readChangelog() {
  const path = resolve(repoRoot, 'CHANGELOG.md');
  try {
    return readFileSync(path, 'utf8');
  } catch {
    throw new Error(`${path} is missing; a release needs its notes.`);
  }
}

/// The body of `## [<version>]`, up to the next heading of the same level.
function sectionFor(text, version) {
  const lines = text.split('\n');
  const headings = [];
  lines.forEach((line, index) => {
    const match = HEADING.exec(line);
    if (match) headings.push({ name: match[1], index });
  });

  for (const [position, heading] of headings.entries()) {
    if (heading.name !== version) continue;
    const end = headings[position + 1]?.index ?? lines.length;
    return lines.slice(heading.index + 1, end).join('\n').trim();
  }
  return null;
}

/// The notes for [version], or an error explaining what to add.
///
/// The lookup is exact rather than "the newest section": a release name is known
/// before the notes are read, and guessing would publish the wrong notes the first
/// time the file is out of order. Missing notes are a refusal, not a warning.
export function notesFor(text, version) {
  const body = sectionFor(text, version);
  if (body == null) {
    const unreleased = /^##\s+\[?unreleased\]?\s*$/im.test(text);
    throw new Error(
      `CHANGELOG.md has no "## [${version}]" section, so this release would ship ` +
        `without notes. Add one.` +
        (unreleased
          ? ` (There is an "Unreleased" section: notes belong under the version ` +
            `they are released as, because that is what the release looks up.)`
          : ''),
    );
  }
  // Headings and comments are not notes: a section that has only those would put
  // an empty release page in front of users, so it counts as missing.
  const entries = body
    .split('\n')
    .filter((line) => {
      const trimmed = line.trim();
      return trimmed !== '' && !trimmed.startsWith('#') && !trimmed.startsWith('<!--');
    });
  if (entries.length === 0) {
    throw new Error(
      `"## [${version}]" in CHANGELOG.md has no entries — headings and comments ` +
        `are not notes. Write what this version changes; the release page is ` +
        `built from this section.`,
    );
  }
  return body;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const version = process.argv[2];
    if (!version) throw new Error('Usage: node scripts/changelog.mjs <version>');
    process.stdout.write(`${notesFor(readChangelog(), version)}\n`);
  } catch (err) {
    console.error(`[changelog] ${err.message}`);
    process.exit(1);
  }
}
