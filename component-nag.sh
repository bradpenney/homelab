#!/bin/bash
# Daily nudge about platform upgrades that are waiting on a human.
#
# WHY THIS RUNS HERE AND NOT IN GITHUB ACTIONS
# The `component-watch` workflow could notify directly, but only by storing the
# ntfy topic as a repo secret — and an ntfy topic is a PUBLISH CAPABILITY:
# anyone holding it can post to it. server1 already has the topic, so the nag
# runs here and the capability never leaves the house.
#
# WHAT IT NAGS ABOUT
# Open PRs and issues, NOT "you are behind". A component behind with no PR is a
# gap in automation, and component-watch opens one. A component behind WITH a PR
# is a decision deferred — one click from done — and that is the only thing
# worth a daily nudge. Silent when nothing is open, which is what stops it
# becoming noise you swipe away.
set -euo pipefail

cd "$(dirname "$0")"
REPOS=("bradpenney/substrate_config" "bradpenney/substrate")

lines=()
total=0

# Query, and treat a FAILED query as a failure — not as zero.
#
# The first version of this used `|| echo 0` on every gh call, so any error —
# expired token, rate limit, no network, $HOME unset so gh cannot find its
# credentials — produced a count of 0 and the script cheerfully reported
# "nothing open". A completely broken nag was indistinguishable from a quiet
# day, which is the one thing a nag must never be. Exiting non-zero here means
# OnFailure fires and the notifier says so.
gh_count() {
    local out
    if ! out=$("$@" 2>&1); then
        echo "QUERY FAILED: $* -> ${out}" >&2
        return 1
    fi
    # `gh --jq length` on an empty list prints 0; anything non-numeric means the
    # command "succeeded" but did not return what we asked for.
    if ! [[ "$out" =~ ^[0-9]+$ ]]; then
        echo "UNEXPECTED OUTPUT: $* -> ${out}" >&2
        return 1
    fi
    printf '%s' "$out"
}

for repo in "${REPOS[@]}"; do
    prs=$(gh_count gh pr list --repo "$repo" --state open \
            --label component-bump --json number --jq 'length')
    bumps=$(gh_count gh pr list --repo "$repo" --state open \
            --search 'head:bump/' --json number --jq 'length')
    issues=$(gh_count gh issue list --repo "$repo" --state open \
            --label component-review --json number --jq 'length')
    # A bump PR may carry the label, match the branch prefix, or both — count
    # each PR once.
    open_prs=$(( prs > bumps ? prs : bumps ))
    n=$(( open_prs + issues ))
    if [ "$n" -gt 0 ]; then
        lines+=("${repo##*/}: ${open_prs} PR(s), ${issues} issue(s)")
        total=$(( total + n ))
    fi
done

if [ "$total" -eq 0 ]; then
    echo "$(date -Is) nothing open — no notification sent"
    exit 0
fi

MESSAGE="$(printf '%s; ' "${lines[@]}")"
echo "$(date -Is) notifying: ${MESSAGE}"
./notify.sh "Platform upgrades waiting" "${MESSAGE%; } — review and merge to clear this."
