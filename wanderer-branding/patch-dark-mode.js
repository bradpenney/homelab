// Forces the theme to 'dark' everywhere ("looks way better" — Brad).
// Three independent code paths decide the theme, so all three are patched:
//  1. The SSR shell's inline pre-hydration <script> (avoids a flash of the
//     wrong theme before JS loads) — lives in the server's internal.js chunk.
//  2. The client store's initial resolver, run again on hydration.
//  3. The theme-toggle button's click handler — hardcoded to always land on
//     'dark' instead of flipping the current value, so clicking it is a
//     harmless no-op.
// Plain string find/replace (no regex) deliberately — the literal text here
// is full of backticks, brackets, and backslash-escaped quotes that make
// sed's BRE patterns unreliable (bracket expressions, escape handling, and a
// sed delimiter that silently came out empty under this image's busybox
// shell all bit us in turn). Invoked by patch-branding.sh with $BUILD as
// argv[2]; finds its own targets by content since chunk filenames are
// content-hashed and change on every Wanderer image update.
"use strict";
const fs = require("fs");
const path = require("path");

const build = process.argv[2];
if (!build) process.exit(0);

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
			console.log(`[branding] dark-mode patch applied: ${label}`);
			return true;
		}
	}
	return false;
}

const files = [];
walk(build, files);

// 1. SSR pre-hydration inline script.
applyTo(
	files,
	"const storedTheme = localStorage.theme;",
	"const storedTheme = 'dark';",
	"ssr-inline-script",
);

// 2. Client store's initial resolver.
applyTo(
	files,
	"function r(){let e=localStorage.getItem(`theme`);return e===`dark`||e===`light`?e:document.documentElement.classList.contains(`dark`)?`dark`:document.documentElement.classList.contains(`light`)?`light`:window.matchMedia(`(prefers-color-scheme: dark)`).matches?`dark`:`light`}",
	"function r(){return`dark`}",
	"theme-resolver",
);

// 3. Theme-toggle click handler.
applyTo(
	files,
	"function i(){let e=t(n),r=e===`light`?`dark`:`light`;document.documentElement.classList.remove(e),document.documentElement.classList.add(r),document.querySelector(`meta[name='color-scheme']`)?.setAttribute(`content`,r),n.set(r),localStorage.setItem(`theme`,r)}",
	"function i(){let e=t(n),r=`dark`;document.documentElement.classList.remove(e),document.documentElement.classList.add(r),document.querySelector(`meta[name='color-scheme']`)?.setAttribute(`content`,r),n.set(r),localStorage.setItem(`theme`,r)}",
	"theme-toggle",
);
