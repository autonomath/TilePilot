#!/usr/bin/env node
// Build the static TilePilot website into website/_site.
//
//   node website/build.mjs                       # copy and validate
//   node website/build.mjs --release release.json  # also point downloads at that GitHub release
//
// release.json is the GitHub API response for a release (gh api repos/OWNER/REPO/releases/latest).
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const out = join(root, '_site');
const shipped = ['index.html', 'styles.css', 'main.js', 'assets'];

function fail(message) {
  console.error('website build failed: ' + message);
  process.exit(1);
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
for (const entry of shipped) {
  const from = join(root, entry);
  if (!existsSync(from)) fail('missing ' + entry);
  cpSync(from, join(out, entry), { recursive: true });
}

let html = readFileSync(join(out, 'index.html'), 'utf8');

// Elements marked data-until="vX.Y.Z" announce something that ships in that release ("Coming in the
// next release"). They hold plain text only, and the build drops them once the published release
// is that version or newer.
const untilPattern = /<(span|p|div)\b[^>]*\bdata-until="([^"]*)"[^>]*>[^<]*<\/\1>/g;
const untilMarks = (html.match(/\bdata-until="/g) || []).length;
const untilElements = [...html.matchAll(untilPattern)];
if (untilElements.length !== untilMarks) fail('data-until elements must be span, p, or div with plain text only');
for (const [, , until] of untilElements) {
  if (!/^v\d+\.\d+\.\d+$/.test(until)) fail('unexpected data-until version ' + JSON.stringify(until));
}
const versionParts = (tag) => tag.slice(1).split('.').map(Number);
function isAtLeast(tag, until) {
  const [a, b] = [versionParts(tag), versionParts(until)];
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) return a[i] > b[i];
  }
  return true;
}

const releaseFlag = process.argv.indexOf('--release');
if (releaseFlag !== -1) {
  const releasePath = process.argv[releaseFlag + 1];
  if (!releasePath) fail('--release needs a path');
  const release = JSON.parse(readFileSync(releasePath, 'utf8'));
  if (release.draft || release.prerelease) fail('release ' + release.tag_name + ' is not a published stable release');
  const tag = String(release.tag_name || '');
  if (!/^v\d+\.\d+\.\d+$/.test(tag)) fail('unexpected release tag ' + JSON.stringify(tag));
  const dmg = (release.assets || []).find((asset) => asset.name === 'TilePilot-' + tag + '.dmg');
  if (!dmg) fail('release ' + tag + ' has no TilePilot-' + tag + '.dmg asset');
  const url = dmg.browser_download_url;
  if (!url.startsWith('https://github.com/autonomath/TilePilot/releases/download/')) fail('unexpected download URL ' + url);
  const size = (dmg.size / 1e6).toFixed(1) + ' MB';

  let downloads = 0;
  html = html.replace(/(<a\b[^>]*data-release="dmg"[^>]*\bhref=")[^"]*(")/g, (_, a, b) => { downloads += 1; return a + url + b; });
  html = html.replace(/(<span data-release="version">)[^<]*(<\/span>)/g, '$1' + tag + '$2');
  html = html.replace(/(<span data-release="size">)[^<]*(<\/span>)/g, '$1' + size + '$2');
  html = html.replace(/("softwareVersion": ")[^"]*(")/, '$1' + tag.slice(1) + '$2');
  html = html.replace(/("downloadUrl": ")[^"]*(")/, '$1' + url + '$2');
  if (downloads < 3) fail('expected at least 3 download links, found ' + downloads);
  console.log('release ' + tag + ': ' + downloads + ' download links -> ' + url + ' (' + size + ')');

  let shipped = 0;
  html = html.replace(untilPattern, (element, _name, until) => {
    if (!isAtLeast(tag, until)) return element;
    shipped += 1;
    return '';
  });
  if (untilElements.length) console.log('coming-soon labels: ' + shipped + ' removed, ' + (untilElements.length - shipped) + ' kept');
}

// Every local src/href must exist in the built site.
const missing = [];
for (const [, ref] of html.matchAll(/(?:src|href)="([^"#:]+)"/g)) {
  if (ref === './') continue;
  if (!existsSync(resolve(out, ref))) missing.push(ref);
}
const css = readFileSync(join(out, 'styles.css'), 'utf8');
for (const [, ref] of css.matchAll(/url\("([^"]+)"\)/g)) {
  if (!existsSync(resolve(out, ref))) missing.push('styles.css: ' + ref);
}
if (missing.length) fail('missing local files: ' + missing.join(', '));

writeFileSync(join(out, 'index.html'), html);
writeFileSync(join(out, '.nojekyll'), '');
console.log('built ' + out);
