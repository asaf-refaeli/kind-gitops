#!/usr/bin/env bash
# Emergency rollback: undo the last release-notes deploy in this repo.
# Argo CD then puts the previous image back on dev and prod.
# The app code revert is a separate, normal PR in the release-notes repo.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Must be logged in to GitHub (the script never logs in by itself).
if ! gh auth status > /dev/null 2>&1; then
  echo "Not logged in. Run: gh auth login"
  exit 1
fi

# 2. Get the latest main.
git fetch origin main

# 3. Find the last commit that changed the release-notes values (the deploy).
commit=$(git log origin/main -1 --format=%h -- workloads/apps/release-notes)
message=$(git log -1 --format=%s "$commit")
echo "Last deploy commit: $commit $message"

# 4. If it is already a rollback, stop: reverting it would bring the bad version back.
if [[ "$message" == Revert* ]]; then
  echo "Already rolled back. Nothing to do."
  exit 1
fi

# 5. Ask before doing anything.
read -p "Roll it back? (y/n) " answer
if [ "$answer" != "y" ]; then
  echo "Stopped. Nothing changed."
  exit 0
fi

# 6. Undo that commit on a new branch.
git switch -c "rollback-$commit" origin/main
git revert --no-edit "$commit"
git push -u origin "rollback-$commit"

# 7. Open a PR and merge it (main only accepts changes through a PR).
gh pr create --fill
gh pr merge --squash --delete-branch
