#!/bin/sh
# Re-brand the stock Wanderer landing/UI to "Brad's Trails".
# Runs on every container start (wired via `command:` in compose.yaml) so it
# survives restarts and re-applies automatically after a Wanderer image update.
# Idempotent: once a token is replaced its pattern no longer matches.
# Targeted patterns only — deliberately avoids the `wanderer_diorama_*` asset
# paths and the "wanderer Diorama" alt text so the hero illustration keeps working.

set -eu
BUILD=/app/build
NEW="Brad's Trails"
SUB_OLD="Explore exciting trails, save your favorites, and experience the beauty of nature. Find your next adventure!"
SUB_NEW="Side-by-side rides and backcountry trails around Nova Scotia's South Shore — GPS tracks, ride stats, and photos from every run."

patch() { # <literal-find> <replacement>
  find_str="$1"; repl="$2"
  # Use a control char as the sed delimiter so literal '|', '/' etc. in the
  # find/replace strings are never mistaken for the delimiter.
  d=$(printf '\001')
  grep -rlF "$find_str" "$BUILD" 2>/dev/null | while IFS= read -r f; do
    sed -i "s${d}${find_str}${d}${repl}${d}g" "$f"
  done
}

patch '>wanderer</span>' ">$NEW</span>"   # hero heading
patch '>wanderer</h5>'   ">$NEW</h5>"     # nav-bar logo text
patch '| wanderer'       "| $NEW"         # all <title> tags
patch "$SUB_OLD"         "$SUB_NEW"        # hero subtitle
patch 'alt="wanderer Diorama"' 'alt="Rocky Lake — Lunenburg County, Nova Scotia"'

# --- About section: replace stock Wanderer copy with personal content ---
# Served as a static markdown file fetched at runtime (/md/about.md).
if [ -f /wanderer-branding/about.md ]; then
  find "$BUILD" -path '*/md/about.md' -exec cp /wanderer-branding/about.md {} \; 2>/dev/null
fi

# --- Hero image: replace the stock diorama with a ride photo (all formats) ---
# The hero uses a <picture> with avif/webp/png sources for both light & dark
# themes, so every variant must be overwritten or the browser falls back to the
# original. Files are content-hash named; we match by the stable glob prefix.
for ext in png webp avif; do
  src="/wanderer-branding/diorama.$ext"
  [ -f "$src" ] || continue
  find "$BUILD" -name "wanderer_diorama_*.$ext" -exec cp "$src" {} \; 2>/dev/null
done

# Custom CSS injected into every stylesheet:
#  1. Hide the original diorama 3D WebGL <canvas> that pokes out behind the photo
#     (the SVG starfield is a separate element and is left intact).
#  2. Shrink the hero photo so it doesn't crowd the edges (gives margin/breathing room).
#  3. Hide the "Getting Started" call-to-action section.
#  4. Fix the feed-card photo mosaic: upstream's row-span-2 class IS applied
#     correctly to the first tile, but the grid's rows are auto-sized while the
#     tile itself is height:100% — a circular dependency (the row can't size
#     from content that needs the row's size first), so browsers collapse it
#     and leave the spanned tile's second row blank. Give the rows a fixed
#     height so the percentage height has something definite to resolve against.
MARKER='/*brad-css*/'
# Hide the diorama canvas with visibility:hidden (NOT display:none) so it keeps
# its layout box — display:none collapses the container height, which zeroes out
# the photo's percentage max-height. Size the photo against the viewport (vh) so
# it never depends on the container height.
CSS='.left-\[40\%\] canvas{visibility:hidden!important}'
CSS="$CSS"'.left-\[40\%\] img{max-height:62vh!important;max-width:88%!important}'
CSS="$CSS"'#get-started{display:none!important}'
CSS="$CSS"'.grid-cols-\[8fr_5fr\]{grid-auto-rows:10rem!important}'
# Homepage "About" teaser renders an empty <div class="prose"> — a separate
# client-side fetch+markdown-render of /md/about.md (confirmed 200 OK with
# real content) silently fails somewhere between fetch and render; the error
# is swallowed by a bare console.warn with no way to see it without a live
# browser console. Stopgap until we can grab the actual console error: hide
# the section. The real About content still works fine at /about.
CSS="$CSS"'#about{display:none!important}'
find "$BUILD/client" -name '*.css' 2>/dev/null | while IFS= read -r f; do
  grep -qF "$MARKER" "$f" 2>/dev/null && continue
  printf '%s%s' "$MARKER" "$CSS" >> "$f"
done

# --- Force dark theme always ("looks way better" — Brad) ---
# See patch-dark-mode.js for why this is a dedicated node script rather than
# more `patch` calls: the literal text involved (backticks, brackets,
# backslash-escaped quotes) is unreliable to match with sed's BRE patterns.
node /wanderer-branding/patch-dark-mode.js "$BUILD"

# --- Gallery/lightbox photos: request a sized thumbnail, not the original ---
# Root cause of "photos load very very slow": see patch-gallery-thumbs.js.
node /wanderer-branding/patch-gallery-thumbs.js "$BUILD"

# --- Default sort order: /trails page + homepage recommendations ---
# Upstream defaults the trails browse page to oldest-first ascending, and the
# homepage widget is a random sample that (with only a handful of trails so
# far) always lands on offset 0, i.e. oldest-first by coincidence. Brad wants
# newest-first everywhere. Scoped narrowly (path/content match) so lists and
# profile pages, which weren't asked about, are left on their own defaults.

# /trails page: server-rendered initial filter (used before any localStorage
# sort preference is picked up client-side).
f=$(find "$BUILD" -path '*/entries/pages/trails/_page.ts.js-*.js' ! -name '*.map' 2>/dev/null | head -1)
[ -n "$f" ] && sed -i 's/sortOrder: "+"/sortOrder: "-"/' "$f"

# /trails page: client-side copy of the same initial filter, used on
# client-side (SPA) navigation to the page instead of a full SSR load.
# NOTE: 'elevationLossLimit' alone matches multiple route bundles (any page
# sharing the filter object shape) — the '.max_elevation_loss,sort:...' form
# below is the specific expression from the /trails +page.ts source and only
# ever matches the one file. Do not loosen this back to the shorter form.
f=$(grep -rlF '.max_elevation_loss,sort:`created`,sortOrder:`+`' "$BUILD/client" 2>/dev/null | head -1)
[ -n "$f" ] && sed -i 's/\.max_elevation_loss,sort:`created`,sortOrder:`+`/.max_elevation_loss,sort:`created`,sortOrder:`-`/' "$f"

# Homepage "recommended trails" widget: replace the random-sample logic with
# an explicit newest-first sort (see patch-recommend.js for the full diff).
f=$(find "$BUILD" -path '*/entries/endpoints/api/v1/trail/recommend/_server.ts.js-*.js' ! -name '*.map' 2>/dev/null | head -1)
[ -n "$f" ] && node /wanderer-branding/patch-recommend.js "$f"

# Wanderer ships pre-compressed .br/.gz copies of every JS/CSS asset and the
# node server serves those to browsers (which send Accept-Encoding: br). They
# still hold the ORIGINAL bytes, so every edit above would be bypassed. Drop them
# so the patched plain files are served (server falls back to them automatically).
find "$BUILD" \( -name '*.br' -o -name '*.gz' \) -delete 2>/dev/null

echo "[branding] patch-branding.sh applied ($NEW)"
