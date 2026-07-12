// Rewrites the /api/v1/trail/recommend handler so the homepage widget shows
// the newest trails instead of a random sample (upstream's random offset
// always lands on 0 while trail count <= requested size, so today it just
// looks like "oldest first" by coincidence — this makes it deterministic).
// Invoked by patch-branding.sh with the target file path as argv[2].
"use strict";
const fs = require("fs");

const target = process.argv[2];
if (!target) process.exit(0);

const find = [
	'\tconst maxOffset = Math.max(0, numberOfTrails - size);',
	"\tconst randomOffset = Math.floor(Math.random() * (maxOffset + 1));",
	'\treturn event.locals.ms.index("trails").search("", {',
	"\t\tlimit: size,",
	"\t\toffset: randomOffset,",
	"\t\tfilter",
	"\t});",
].join("\n");

const replace = [
	'\treturn event.locals.ms.index("trails").search("", {',
	"\t\tlimit: size,",
	"\t\toffset: 0,",
	"\t\tfilter,",
	'\t\tsort: ["created:desc"]',
	"\t});",
].join("\n");

const src = fs.readFileSync(target, "utf8");
if (src.includes(find)) {
	fs.writeFileSync(target, src.replace(find, replace));
	console.log("[branding] patched recommend endpoint (newest-first)");
}
