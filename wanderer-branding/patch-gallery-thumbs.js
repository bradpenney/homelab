// The trail/waypoint/summit-log photo galleries all pull their photo array
// from the PocketBase API as bare filenames, then build view URLs client-side
// via a getFileUrl-style helper that takes an optional third `thumb` arg
// (e.g. "600x0"). The trail *card* preview already passes that arg — the
// full galleries (and the PhotoSwipe lightbox they feed) don't, so opening
// a trail with two dozen phone photos pulls every original at full
// resolution (multi-MB each) instead of a sized-down version. Confirmed via
// the live API response (bare filenames, no thumb decision server-side) and
// the served page's photo URLs (no ?thumb= query param at all).
// Uses 600x0 — the *only* size actually whitelisted in the PocketBase
// collection schema's `thumbs` list for this field (confirmed via the admin
// API: `"thumbs": ["600x0"]`). Requesting any other size silently falls back
// to serving the full original — PocketBase doesn't resize on demand outside
// the schema's allowed list. A bigger size (e.g. 1920x0) would need adding
// to that list first; 600x0 already turns a ~9MB original into ~200KB and
// matches what the trail-card thumbnail already uses elsewhere.
// Plain string find/replace, no regex, for the same reason as
// patch-dark-mode.js: easier to get byte-exact than to get right through
// sed's BRE escaping.
// Invoked by patch-branding.sh with $BUILD as argv[2].
"use strict";
const fs = require("fs");
const path = require("path");

const build = process.argv[2];
if (!build) process.exit(0);
const THUMB = "600x0";

function walk(dir, out) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) walk(full, out);
		else if (entry.name.endsWith(".js")) out.push(full);
	}
}

function applyTo(files, find, replace, label) {
	for (const f of files) {
		const src = fs.readFileSync(f, "utf8");
		if (src.includes(find)) {
			fs.writeFileSync(f, src.split(find).join(replace));
			console.log(`[branding] gallery thumb patch applied: ${label}`);
			return true;
		}
	}
	return false;
}

const files = [];
walk(build, files);

// Trail's own photo gallery/lightbox (the shared gallery/lightbox component's
// `photos` prop). This one matches and applies fine.
applyTo(files, "photos.map(e=>W(b(Y),e))", `photos.map(e=>W(b(Y),e,\`${THUMB}\`))`, "trail-gallery");

// Trail detail page's photo MOSAIC (the row-span-2 grid of the first 3
// photos above the fold) is a SEPARATE code path from the gallery/lightbox
// above and was still serving full originals — confirmed via the live page's
// <img class="object-cover h-full w-full ... row-span-2"> tags carrying no
// ?thumb= param. Root cause the original "trail-gallery" applyTo above never
// caught: the real source is `b(Y).photos.slice(0,3).map(e=>W(b(Y),e))` — the
// `.slice(0,3)` sitting between `.photos` and `.map` meant the literal
// substring `"photos.map(e=>W(b(Y),e))"` never actually occurred verbatim in
// the file, so the find/replace silently no-opped. Confirmed live via
// `grep -o 'object-cover h-full w-full svelte-d39uqv' chunks/1H2IWdeR2.js`
// and tracing back to the `un()`/`dn` mosaic-array builder.
applyTo(
	files,
	"b(Y).photos.slice(0,3).map(e=>W(b(Y),e))",
	`b(Y).photos.slice(0,3).map(e=>W(b(Y),e,\`${THUMB}\`))`,
	"trail-mosaic",
);

// Waypoint photo gallery/lightbox. Also confirmed live to be unpatched — the
// original find-string assumed the same `W(b(i),e)` shape as the trail
// gallery, but the waypoint detail view's actual minified call is
// `r.waypoint.photos.map(e=>xe(r.waypoint,e))` (different helper alias `xe`
// and a `r.waypoint` receiver instead of `b(i)`).
applyTo(
	files,
	"r.waypoint.photos.map(e=>xe(r.waypoint,e))",
	`r.waypoint.photos.map(e=>xe(r.waypoint,e,\`${THUMB}\`))`,
	"waypoint-gallery",
);

// Summit log photo gallery/lightbox.
applyTo(files, "photos.map(e=>D(c.log,e))", `photos.map(e=>D(c.log,e,\`${THUMB}\`))`, "summit-log-gallery");

// --- SSR-rendered mosaics also need the fix, separately from the client bundle ---
// Everything above patches CLIENT chunks (/app/build/client), which only
// govern what happens AFTER hydration. The FIRST paint — what curl or a slow
// connection actually sees, and what a browser shows before JS takes over —
// comes from the SERVER bundle (/app/build/server), which is a completely
// separate, independently-compiled copy of the same components. Confirmed
// live: after the client-side patches above applied cleanly, the live page's
// <img src> still had no ?thumb= param, because the initial HTML is built by
// entries/pages/trail/view/.../trail_info_panel.js server chunk calling its
// own `getFileURL(entity, photo)` — unrelated code, unrelated minified names.
// Unlike the client chunks, the server bundle is NOT minified (readable
// function/variable names), so this uses a balanced-paren scan on the real
// `getFileURL(` call rather than a brittle literal string — more robust to
// future Wanderer version bumps than hunting a new single-letter name each time.
function findMatchingParen(src, openIdx) {
	let depth = 1;
	for (let i = openIdx + 1; i < src.length; i++) {
		if (src[i] === "(") depth++;
		else if (src[i] === ")") {
			depth--;
			if (depth === 0) return i;
		}
	}
	return -1;
}

function topLevelArgCount(argsStr) {
	let depth = 0,
		count = argsStr.trim() ? 1 : 0;
	for (const ch of argsStr) {
		if ("([{".includes(ch)) depth++;
		else if (")]}".includes(ch)) depth--;
		else if (ch === "," && depth === 0) count++;
	}
	return count;
}

function patchGetFileURLCalls(filePath, label) {
	let src = fs.readFileSync(filePath, "utf8");
	let out = "";
	let cursor = 0;
	let patched = 0;
	const needle = "getFileURL(";
	while (true) {
		const i = src.indexOf(needle, cursor);
		if (i === -1) break;
		const openIdx = i + needle.length - 1;
		const closeIdx = findMatchingParen(src, openIdx);
		if (closeIdx === -1) break;
		const argsStr = src.slice(openIdx + 1, closeIdx);
		out += src.slice(cursor, closeIdx);
		if (topLevelArgCount(argsStr) === 2) {
			out += `, "${THUMB}"`;
			patched++;
		}
		out += ")";
		cursor = closeIdx + 1;
	}
	out += src.slice(cursor);
	if (patched > 0) {
		fs.writeFileSync(filePath, out);
		console.log(`[branding] SSR gallery thumb patch applied: ${label} (${patched} call site${patched === 1 ? "" : "s"})`);
	}
	return patched;
}

const ssrTargets = [
	["trail_info_panel.js-", "trail-info-panel (trail mosaic + embedded waypoint mosaics)"],
	["feed_card.js-", "feed-card (homepage recommended-trails widget)"],
];
for (const f of files) {
	const base = path.basename(f);
	for (const [prefix, label] of ssrTargets) {
		if (base.startsWith(prefix)) patchGetFileURLCalls(f, label);
	}
}
