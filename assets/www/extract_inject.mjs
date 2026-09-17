// Regenerates assets/www/techpie_inject.js from the Dart source of truth.
//
// The document-start script lives in lib/services/webview_bridge.dart as a
// raw Dart string. assets/www/techpie_inject.js is a snapshot of it, used to
// inject the same script into a plain browser (DevTools / CDP) when testing
// the campus pages without building the app. Run this after editing the Dart
// constant so the snapshot cannot silently drift:
//
//   node assets/www/extract_inject.mjs
//
// Exits non-zero if the snapshot was out of date.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const dartPath = join(here, "..", "..", "lib", "services", "webview_bridge.dart");
const outPath = join(here, "techpie_inject.js");

const dart = readFileSync(dartPath, "utf8");
const match = /const String techPieDocumentStartScript = r'''(.*?)''';/s.exec(dart);
if (!match) {
  console.error(`Could not find techPieDocumentStartScript in ${dartPath}`);
  process.exit(1);
}

const script = match[1];
let current = null;
try {
  current = readFileSync(outPath, "utf8");
} catch {
  // snapshot does not exist yet
}

if (current === script) {
  console.log(`up to date (${script.length} bytes)`);
  process.exit(0);
}

writeFileSync(outPath, script);
console.log(`wrote ${outPath} (${script.length} bytes)`);
process.exit(1);
