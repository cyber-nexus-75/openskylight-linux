#!/usr/bin/env bash
# Compares the latest release tag and main-branch head of both the upstream
# OpenSkyLight repo and the fork against the last-seen state. Emits a Markdown
# report of anything new that may need Linux-variant work, and updates the
# state file. Exit status is always 0 unless a tool call fails hard.
set -uo pipefail

STATE_FILE="${STATE_FILE:-state.json}"
REPOS="${REPOS:-lowerygt/OpenSkyLight cyber-nexus-75/OpenSkyLight}"
GH_TOKEN="${GH_TOKEN:-}"

[ -n "$GH_TOKEN" ] || { echo "GH_TOKEN not set" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

prev_tag_of() { jq -r --arg r "$1" '.[$r].tag // "none"' "$STATE_FILE" 2>/dev/null || echo none; }
prev_sha_of() { jq -r --arg r "$1" '.[$r].sha // ""' "$STATE_FILE" 2>/dev/null; }

report="$(mktemp)"
new_state="$(mktemp)"
changed=0

for repo in $REPOS; do
  tag="$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || echo none)"
  sha="$(gh api "repos/$repo/commits/main" -q .sha 2>/dev/null || echo unknown)"

  prev_tag="$(prev_tag_of "$repo")"
  prev_sha="$(prev_sha_of "$repo")"

  tag_changed=0
  [ "$tag" != "$prev_tag" ] && tag_changed=1
  sha_changed=0
  [ -n "$prev_sha" ] && [ "$sha" != "$prev_sha" ] && sha_changed=1

  if [ "$tag_changed" -eq 1 ] || [ "$sha_changed" -eq 1 ]; then
    changed=1
    {
      echo "## $repo"
      if [ "$tag_changed" -eq 1 ]; then
        echo "- New release: \`$prev_tag\` → \`$tag\` — check release notes for Linux-impacting changes (ports, firewall, file paths, session behavior)"
      fi
      if [ "$sha_changed" -eq 1 ]; then
        echo "- \`main\` moved (\`$sha\`) — new commits: https://github.com/$repo/compare/$prev_sha...main"
      fi
      echo
    } >> "$report"
  fi

  jq -n --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" \
    '{($repo): {tag: $tag, sha: $sha}}' > "$new_state.$(echo "$repo" | tr / _)"
done

if [ "$changed" -eq 1 ]; then
  cat "$report"
fi

# Merge per-repo states into the new state file
: > "$STATE_FILE.new"
echo "{" >> "$STATE_FILE.new"
first=1
for f in "$new_state".*; do
  [ "$first" -eq 0 ] && echo "," >> "$STATE_FILE.new"
  first=0
  tail -n +2 "$f" | head -n -1 >> "$STATE_FILE.new"
done
echo "}" >> "$STATE_FILE.new"
mv "$STATE_FILE.new" "$STATE_FILE"
rm -f "$report" "$new_state".*
