#!/usr/bin/env bash
# Ship the commits on local main through the protected branch:
#   commits → branch → PR → auto-merge (squash) once the required checks pass → wait → local main synced.
#   usage (inside a repository, after committing on main): ship.sh "<PR title>"
# GH_USER (default MIERAI): gh account whose token is used.
set -euo pipefail
GH_TOKEN=$(gh auth token --user "${GH_USER:-MIERAI}"); export GH_TOKEN GIT_TERMINAL_PROMPT=0
title=$1
repo=$(git remote get-url origin | sed -E 's#.*github.com/##; s#\.git$##')
branch="change/$(date +%Y%m%d-%H%M%S)"
git fetch -q origin main
# Safety (main is reset to origin/main below): refuse with uncommitted changes or nothing to ship.
[ -z "$(git status --porcelain)" ] || { echo "✗ uncommitted changes: commit them first" >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "✗ not on main" >&2; exit 1; }
[ "$(git rev-list --count origin/main..HEAD)" -gt 0 ] || { echo "✗ no new commits on main" >&2; exit 1; }
git checkout -q -b "$branch"
git push -q origin "$branch"
git checkout -q main && git reset -q --hard origin/main
url=$(gh pr create -R "$repo" --base main --head "$branch" --title "$title" --body "$(git log --format=%B -1 "origin/$branch")")
gh pr merge "$url" --auto --squash >/dev/null
echo "PR: $url (auto-merge once the required checks pass)"
for _ in $(seq 1 120); do
  st=$(gh pr view "$url" --json state --jq .state)
  [ "$st" = MERGED ] && { git pull -q --rebase origin main; echo "✓ merged"; exit 0; }
  [ "$st" = CLOSED ] && { echo "✗ closed"; exit 1; }
  sleep 10
done
echo "✗ timeout (checks failing?): $url"; exit 1
