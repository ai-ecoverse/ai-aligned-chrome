#!/bin/bash
#
# test.sh - behavioural tests for ai-aligned-chrome.
#
# Builds fake browser bundles whose "Chrome" is a tiny Mach-O that records its
# argv, under a throwaway root. Never touches the real caches, the real
# LaunchAgent, or the keychain.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SCRIPT_DIR/executable_ai-aligned-chrome"

TMP="$(mktemp -d -t aac-test)"
trap 'rm -rf "$TMP"' EXIT

export AI_ALIGNED_CHROME_HOME="$TMP/state"
export AI_ALIGNED_CHROME_ROOTS="$TMP/cache-a:$TMP/cache-b"
export AI_ALIGNED_CHROME_SETTLE=0  # the default, made explicit
unset AI_ALIGNED_CHROME_DISABLE

PASS=0; FAIL=0
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
ok()    { printf '%s✓%s %s\n' "$GREEN" "$NC" "$1"; PASS=$((PASS+1)); }
no()    { printf '%s✗%s %s\n' "$RED" "$NC" "$1"; printf '    %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$3', got '$2'"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "'$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1" "'$3' unexpectedly in: $2" ;; *) ok "$1" ;; esac; }

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s-%s all tests skipped: not macOS\n' "$YELLOW" "$NC"; exit 0
fi
command -v clang >/dev/null || { echo "clang is required"; exit 1; }

cat >"$TMP/fake.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    const char *out = getenv("FAKE_OUT");
    FILE *f = out ? fopen(out, "w") : stdout;
    for (int i = 0; i < argc; i++) fprintf(f, "%s\n", argv[i]);
    return 0;
}
EOF
clang -w -o "$TMP/fake" "$TMP/fake.c" || { echo "cannot build fake browser"; exit 1; }

# make_app DIR NAME BUNDLE_ID EXECUTABLE
make_app() {
    local app="$1/$2.app"
    mkdir -p "$app/Contents/MacOS"
    cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundleExecutable</key><string>$4</string>
<key>CFBundleShortVersionString</key><string>999.0.0.1</string>
</dict></plist>
EOF
    cp "$TMP/fake" "$app/Contents/MacOS/$4"
    printf '%s\n' "$app"
}

CFT="$(make_app "$TMP/cache-a/chrome-999/chrome-mac-arm64" "Google Chrome for Testing" com.google.chrome.for.testing "Google Chrome for Testing")"
CHROMIUM="$(make_app "$TMP/cache-b/chromium-1/chrome-mac" "Chromium" org.chromium.Chromium Chromium)"
OTHER="$(make_app "$TMP/cache-a/firefox" "Nightly" org.mozilla.nightly firefox)"
REAL_CHROME="$(make_app "$TMP/cache-a/real" "Google Chrome" com.google.Chrome "Google Chrome")"
CFT_EXE="$CFT/Contents/MacOS/Google Chrome for Testing"

run() { FAKE_OUT="$TMP/argv" "$@" >/dev/null 2>&1; tr '\n' ' ' <"$TMP/argv"; }

echo "== discovery"
status="$("$TOOL" status)"
has   "status lists Chrome for Testing as unwrapped" "$status" "UNWRAPPED  999.0.0.1        $CFT"
has   "status lists Chromium" "$status" "$CHROMIUM"
hasnt "status ignores non-Chromium bundles" "$status" "Nightly.app"
hasnt "status ignores real Google Chrome" "$status" "Google Chrome.app"

echo "== wrap"
out="$("$TOOL" wrap)"
has   "wrap reports Chrome for Testing" "$out" "wrapped   $CFT"
has   "wrap reports Chromium" "$out" "wrapped   $CHROMIUM"
check "wrap leaves other bundles alone" "$(cmp -s "$OTHER/Contents/MacOS/firefox" "$TMP/fake" && echo same)" "same"
check "wrap leaves real Chrome alone" "$(cmp -s "$REAL_CHROME/Contents/MacOS/Google Chrome" "$TMP/fake" && echo same)" "same"
check "original kept aside" "$(cmp -s "$CFT/Contents/MacOS/.Google Chrome for Testing.real" "$TMP/fake" && echo same)" "same"
has   "executable is now the launcher" "$(head -3 "$CFT_EXE")" "# ai-aligned-chrome launcher"
check "launcher is executable" "$([ -x "$CFT_EXE" ] && echo yes)" "yes"
out="$("$TOOL" wrap)"
has   "wrap is idempotent" "$out" "0 newly wrapped"
has   "status shows wrapped" "$("$TOOL" status)" "wrapped    999.0.0.1        $CFT"

echo "== launcher: injection"
TP="$(mktemp -d)"
argv="$(run "$CFT_EXE" --headless=new "--user-data-dir=$TP" about:blank)"
has   "temp profile gets --use-mock-keychain" "$argv" "--use-mock-keychain --password-store=basic --headless=new"
has   "caller's arguments are preserved" "$argv" "--user-data-dir=$TP about:blank"
check "argv[0] is the path the caller used" "$(head -1 "$TMP/argv")" "$CFT_EXE"

argv="$(run "$CFT_EXE" --user-data-dir=/tmp/aac-profile)"
has   "/tmp profile gets the flags" "$argv" "--use-mock-keychain"
argv="$(run "$CFT_EXE" --user-data-dir=/private/var/folders/xx/T/p)"
has   "/private/var/folders profile gets the flags" "$argv" "--use-mock-keychain"

argv="$(cd "$TMPDIR" && run "$CFT_EXE" --user-data-dir=rel-profile)"
has   "relative profile under the temp dir gets the flags" "$argv" "--use-mock-keychain"

argv="$(run "$CFT_EXE" --use-mock-keychain "--user-data-dir=$TP")"
check "flag already present is not duplicated" "$(printf '%s' "$argv" | grep -o -- '--use-mock-keychain' | wc -l | tr -d ' ')" "1"

echo "== launcher: pass-through"
argv="$(run "$CFT_EXE" "--user-data-dir=$HOME/Library/Application Support/slicc/seven-profiles/chrome")"
hasnt "persistent profile keeps the real keychain" "$argv" "--use-mock-keychain"
argv="$(run "$CFT_EXE" --version)"
hasnt "no --user-data-dir: untouched" "$argv" "--use-mock-keychain"
argv="$(AI_ALIGNED_CHROME_DISABLE=1 run "$CFT_EXE" "--user-data-dir=$TP")"
hasnt "AI_ALIGNED_CHROME_DISABLE skips injection" "$argv" "--use-mock-keychain"

ln -s "$CFT_EXE" "$TMP/chrome-link"
argv="$(run "$TMP/chrome-link" "--user-data-dir=$TP")"
has   "works when invoked through a symlink" "$argv" "--use-mock-keychain"

argv="$(cd "$(dirname "$CFT_EXE")" && run "./Google Chrome for Testing" "--user-data-dir=$TP")"
has   "works when invoked by relative path" "$argv" "--use-mock-keychain"

echo "== re-extraction and refresh"
cp "$TMP/fake" "$CFT_EXE"
check "a re-extracted binary counts as unwrapped" "$("$TOOL" status | grep -c "^UNWRAPPED .*$CFT")" "1"
"$TOOL" wrap >/dev/null
has   "and is wrapped again" "$("$TOOL" status)" "wrapped    999.0.0.1        $CFT"
check "with the new binary aside" "$(cmp -s "$CFT/Contents/MacOS/.Google Chrome for Testing.real" "$TMP/fake" && echo same)" "same"

sed -i '' 's/launcher v1/launcher v0/' "$CFT_EXE"
"$TOOL" wrap "$CFT" >/dev/null
has   "an older launcher is refreshed" "$(head -3 "$CFT_EXE")" "# ai-aligned-chrome launcher v1"

echo "== settling"
FRESH="$(make_app "$TMP/cache-b/fresh/chrome-mac-arm64" "Google Chrome for Testing" com.google.chrome.for.testing "Google Chrome for Testing")"
out="$(AI_ALIGNED_CHROME_SETTLE=60 "$TOOL" wrap)"
has   "a just-written executable is left for the next pass" "$out" "pending   $FRESH"
check "and not touched" "$(cmp -s "$FRESH/Contents/MacOS/Google Chrome for Testing" "$TMP/fake" && echo same)" "same"

echo "== watch (fsevents)"
"$TOOL" wrap >/dev/null
"$TOOL" watch & WP=$!
for _ in $(seq 60); do grep -q 'watch ready' "$AI_ALIGNED_CHROME_HOME/wrap.log" 2>/dev/null && break; sleep 0.25; done
has   "watch uses the FSEvents helper" "$(grep 'watch started' "$AI_ALIGNED_CHROME_HOME/wrap.log" | tail -1)" "fsevents"
NEW="$(make_app "$TMP/cache-a/chrome-1000/chrome-mac-arm64" "Google Chrome for Testing" com.google.chrome.for.testing "Google Chrome for Testing")"
for _ in $(seq 30); do
    [ -e "$NEW/Contents/MacOS/.Google Chrome for Testing.real" ] && break; sleep 0.2
done
kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null
check "watch wraps a new download" "$([ -e "$NEW/Contents/MacOS/.Google Chrome for Testing.real" ] && echo yes)" "yes"

echo "== watch (polling fallback)"
AI_ALIGNED_CHROME_POLL=1 AI_ALIGNED_CHROME_INTERVAL=0.2 "$TOOL" watch & WP=$!
sleep 0.5
cp "$TMP/fake" "$NEW/Contents/MacOS/Google Chrome for Testing.tmp"
mv -f "$NEW/Contents/MacOS/Google Chrome for Testing.tmp" "$NEW/Contents/MacOS/Google Chrome for Testing"
for _ in $(seq 30); do
    head -c 200 "$NEW/Contents/MacOS/Google Chrome for Testing" | grep -q "ai-aligned-chrome launcher" && break; sleep 0.2
done
kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null
has   "watch re-wraps a binary replaced over the launcher" "$(head -3 "$NEW/Contents/MacOS/Google Chrome for Testing")" "# ai-aligned-chrome launcher"

echo "== unwrap"
"$TOOL" unwrap >/dev/null
check "unwrap restores the original" "$(cmp -s "$CFT_EXE" "$TMP/fake" && echo same)" "same"
check "unwrap removes the aside copy" "$([ -e "$CFT/Contents/MacOS/.Google Chrome for Testing.real" ] && echo present || echo gone)" "gone"
check "nothing is left wrapped" "$("$TOOL" status | grep -c '^wrapped')" "0"

echo "== explicit paths"
out="$("$TOOL" wrap "$OTHER" 2>&1)"
has   "refuses a non-Chromium bundle given explicitly" "$out" "not a test browser"
"$TOOL" wrap "$CFT_EXE" >/dev/null
has   "accepts a path inside the bundle" "$("$TOOL" status)" "wrapped    999.0.0.1        $CFT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
