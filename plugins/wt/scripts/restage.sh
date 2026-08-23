#!/usr/bin/env bash
# Rebuild the staging branch from scratch — <base> plus every currently-open pull
# request — and, with `merge`, ship the pull requests that composite is made of.
#
#   wt-restage              rebuild <staging> = <base> + every open pull request
#   wt-restage manifest     what the current <staging> is made of (read-only)
#   wt-restage merge        merge the pull requests it is made of, then rebuild
#
# ## The shape
#
# <staging> is disposable and one-directional. Nothing is ever merged back *out*
# of it — pull requests still target <base> and get merged one at a time, each of
# those merges being its own deploy. So a rebuild writes exactly one ref,
# refs/heads/<staging>, and cannot touch a pull request, a branch, or anybody's
# checkout. Re-running it is always safe and is the way to fix a stale staging:
# merged and closed pull requests simply drop out of the open list.
#
# The pattern has a name — integration branch — and prior art. The README's
# `/wt:restage` section carries that argument; this file carries the mechanics.
#
# ## The merge commit subject IS the manifest
#
# Every fold is committed as `restage: #<num> <branch>` and its second parent is
# the head that went in. That is what makes `manifest`, and therefore `merge`,
# possible with no state file anywhere: the composite describes itself, and a
# pull request that has been pushed to since is caught by comparing those two
# shas. Change the subject format and `merge` goes blind — it will find nothing
# rather than merge the wrong thing, but it will find nothing.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-common.sh"

main=$(wt_primary "${CLAUDE_PROJECT_DIR:-$PWD}")
[ -n "$main" ] || { echo "wt-restage: git 레포가 아니다" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || { echo "wt-restage: gh CLI가 필요하다 (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || {
	echo "wt-restage: gh 로그인이 필요하다 — 프롬프트에 '! gh auth login'" >&2; exit 1
}

base=$(wt_base_branch "$main"); base=${base:-main}
staging=$(wt_cfg "$main" '.staging.branch'); staging=${staging:-staging}
method=$(wt_cfg "$main" '.staging.mergeMethod'); method=${method:-merge}

# A rebuild force-pushes <staging>. Pointed at <base> it would throw away the
# history every open pull request is based on, so this is a hard stop rather than
# a trust that nobody ever writes `"branch": "main"` into wt.json.
[ "$staging" != "$base" ] || {
	echo "wt-restage: staging과 base가 같다 ($base). .claude/wt.json의 .staging.branch를 다른 이름으로." >&2
	exit 1
}

# `gh pr merge` with several methods enabled and no flag blocks on a prompt, so
# the method is always explicit. Validated here rather than at merge time — a
# typo should not surface after the first pull request has already gone in.
case "$method" in
	merge|squash|rebase) ;;
	*) echo "wt-restage: .staging.mergeMethod는 merge|squash|rebase 중 하나 (지금: $method)" >&2; exit 1 ;;
esac

# Ascending pull request number, so the same set of open pull requests always
# composes to the same tree. `gh pr list` sorts newest-first, which would make
# the result depend on when it ran. `--base` keeps pull requests aimed somewhere
# else out of a composite that claims to be <base> plus the queue.
open_prs() {
	(cd "$main" && gh pr list --state open --base "$base" --json number,headRefName \
		-q '.[] | "\(.number)\t\(.headRefName)"') | sort -n
}

staging_urls() {
	local u
	u=$(wt_cfg_list "$main" '.staging.urls')
	[ -n "$u" ] || return 0
	echo
	printf '%s\n' "$u" | sed 's/^/  /'
}

rebuild() {
	local wt merged conflicted num br

	git -C "$main" fetch --prune --quiet origin

	# A throwaway detached worktree outside the repo: the caller's checkout — and
	# every other worktree — is never switched, stashed or rebased. Detached
	# because a local <staging> branch would be one more thing that goes stale;
	# the resulting sha is pushed straight at the remote ref instead.
	wt="${TMPDIR:-/tmp}/wt-restage-$(basename "$main")"
	git -C "$main" worktree remove --force "$wt" 2>/dev/null || true
	rm -rf "$wt"
	git -C "$main" worktree add --quiet --detach "$wt" "origin/$base"

	merged=""
	conflicted=""

	while IFS=$'\t' read -r num br; do
		[ -n "$br" ] || continue
		# A pull request opened *from* <staging> would fold the whole composite
		# back into itself. Degenerate, and silently wrong if allowed through.
		[ "$br" != "$staging" ] || continue
		# Both streams are swallowed: git narrates every merge and every
		# conflicted path, and the summary below is the only report worth reading.
		#
		# `--no-ff` forces a commit — the manifest depends on there being one per
		# fold. The exception is a branch already contained in <base>, where git
		# says "Already up to date" and commits nothing; that pull request then has
		# no row in `manifest` and `merge` leaves it alone. Correct, if quiet: there
		# is nothing of it that is not already shipped.
		if git -C "$wt" merge --no-ff -m "restage: #$num $br" "origin/$br" >/dev/null 2>&1; then
			merged="$merged  #$num $br"$'\n'
		else
			# A conflicting branch drops out of this round and gets named, the way
			# a merge queue kicks a pull request out of the queue. Stopping here
			# would let one pull request block everyone else's QA, and resolving
			# the conflict here would produce a merge nobody reviewed.
			git -C "$wt" merge --abort >/dev/null 2>&1 || true
			conflicted="$conflicted  #$num $br"$'\n'
		fi
	done < <(open_prs)

	git -C "$main" push --force --quiet origin \
		"$(git -C "$wt" rev-parse HEAD):refs/heads/$staging"
	git -C "$main" worktree remove --force "$wt"

	echo "$staging = origin/$base + 열린 PR"
	[ -n "$merged" ] || merged="  (없음 — $base 그대로)"$'\n'
	printf '%s' "$merged"
	if [ -n "$conflicted" ]; then
		echo
		echo "충돌로 빠진 PR — 그 브랜치에서 'git merge origin/$base' 뒤 다시 돌리세요:" >&2
		printf '%s' "$conflicted" >&2
	fi
	staging_urls
}

# One row per fold, tab-separated: status, number, branch, detail.
#
# `ok` is the only status `merge` acts on, and it means one specific thing — the
# pull request is still open and its head is *exactly* the commit this composite
# was built from. Anything else is a pull request that was pushed to, closed or
# left in draft since the last rebuild, and merging it would ship code that was
# never on staging. That check is the whole reason `merge` is allowed to exist.
classify() {
	local h subj num br staged json state head draft

	git -C "$main" fetch --prune --quiet origin
	git -C "$main" rev-parse --verify --quiet "refs/remotes/origin/$staging" >/dev/null || {
		echo "wt-restage: origin/${staging}이 없다. 인자 없이 한 번 돌려 만드세요." >&2
		return 1
	}

	while IFS=$'\t' read -r h subj; do
		case "$subj" in "restage: #"*) ;; *) continue ;; esac
		num=${subj#restage: #}
		br=${num#* }
		num=${num%% *}
		staged=$(git -C "$main" rev-parse "$h^2")
		json=$( (cd "$main" && gh pr view "$num" --json state,headRefOid,isDraft) 2>/dev/null ) || json=""
		if [ -z "$json" ]; then
			printf 'gone\t%s\t%s\t조회 실패\n' "$num" "$br"
			continue
		fi
		state=$(printf '%s' "$json" | jq -r '.state')
		head=$(printf '%s' "$json" | jq -r '.headRefOid')
		draft=$(printf '%s' "$json" | jq -r '.isDraft')
		if [ "$state" != "OPEN" ]; then
			printf 'gone\t%s\t%s\t이미 %s\n' "$num" "$br" "$state"
		elif [ "$head" != "$staged" ]; then
			printf 'stale\t%s\t%s\tPR head %s ≠ 합본에 오른 %s\n' \
				"$num" "$br" "${head:0:8}" "${staged:0:8}"
		elif [ "$draft" = "true" ]; then
			printf 'draft\t%s\t%s\t초안\n' "$num" "$br"
		else
			printf 'ok\t%s\t%s\t%s\n' "$num" "$br" "${staged:0:8}"
		fi
	done < <(git -C "$main" log --merges --format='%H%x09%s' "origin/$base..origin/$staging") |
		sort -t$'\t' -k2 -n
}

manifest() {
	local rows
	rows=$(classify) || return 1
	if [ -z "$rows" ]; then
		echo "origin/${staging}에 올라간 PR이 없다 — origin/$base 그대로다."
		return 0
	fi
	echo "origin/$staging = origin/$base + 아래"
	printf '%s\n' "$rows" | awk -F'\t' '{printf "  %-5s #%-5s %-42s %s\n", $1, $2, $3, $4}'
	echo
	printf '%s\n' "$rows" |
		awk -F'\t' '$1=="ok"{n++} END{printf "머지 가능(ok) %d / 전체 %d\n", n+0, NR}'
}

do_merge() {
	local rows oks shipped num br

	rows=$(classify) || return 1
	oks=$(printf '%s\n' "$rows" | awk -F'\t' '$1=="ok"{print $2"\t"$3}')

	printf '%s\n' "$rows" |
		awk -F'\t' '$1!="ok"{printf "건너뜀 %-5s #%s %s — %s\n", $1, $2, $3, $4}' >&2

	if [ -z "$oks" ]; then
		echo "머지할 PR이 없다. 'wt-restage manifest'로 이유를 보세요." >&2
		return 1
	fi

	shipped=""
	while IFS=$'\t' read -r num br; do
		[ -n "$num" ] || continue
		if (cd "$main" && gh pr merge "$num" "--$method"); then
			shipped="$shipped  #$num $br"$'\n'
		else
			echo >&2
			echo "#$num $br 머지 실패 — 여기서 멈춘다. 남은 것은 그대로 열려 있다." >&2
			if [ -n "$shipped" ]; then
				echo "이미 머지된 것:" >&2
				printf '%s' "$shipped" >&2
			fi
			return 1
		fi
	done <<-EOF
		$oks
	EOF

	echo "${base}에 머지:"
	printf '%s' "$shipped"

	# The merged pull requests have just dropped out of the open list, so this
	# recomputes the composite against the new <base> — the "머지 뒤 다시" step,
	# done here rather than left to somebody's memory.
	echo
	rebuild
}

case "${1:-rebuild}" in
	rebuild) rebuild ;;
	manifest) manifest ;;
	merge) do_merge ;;
	*) echo "usage: wt-restage [manifest|merge]" >&2; exit 2 ;;
esac
