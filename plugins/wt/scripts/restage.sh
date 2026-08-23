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

# What a dropped-out pull request actually collides with. Prints one of:
#   base                 — it conflicts with <base> itself
#   pr\t<num>\t<branch>  — one line per pull request folded earlier this round
#                          that it conflicts with on its own
#   (nothing)            — clean against <base> and against each earlier fold
#                          separately; only their combination breaks it
#   unknown              — git cannot answer (see the version note below)
#
# Worth the code because the obvious answer is usually wrong. Folds go in
# ascending pull request number, so by the time a branch is tried the tree is
# already <base> plus everything ahead of it, and a conflict here is not
# evidence about <base> at all. The case that prompted this: #49 merged <base>
# perfectly cleanly and still dropped out, because what it disagreed with was
# #48, folded two steps earlier.
#
# Naming <base> anyway is worse than saying nothing. `git merge origin/<base>`
# in that branch *succeeds* — it is usually behind <base> for unrelated reasons
# — so it reads as progress, and the next rebuild fails on the identical files.
# The loop has no exit unless somebody thinks to distrust the message.
#
# Probes are `merge-tree --write-tree`: no worktree, no checkout, no index. The
# trees and probe commits it writes are unreferenced objects that the next `git
# gc` collects. Only a conflicting pull request ever gets here, so a clean round
# pays nothing at all.
conflict_probe() {
	local br=$1 folded=$2 rc=0 num cand tree probe

	# `--write-tree` arrived in git 2.38. Older git exits >1 here (unknown
	# option) rather than 1 (conflicts), which is what separates the two.
	git -C "$main" merge-tree --write-tree "origin/$base" "origin/$br" >/dev/null 2>&1 || rc=$?
	case $rc in
		0) ;;
		1) echo base; return 0 ;;
		*) echo unknown; return 0 ;;
	esac

	while IFS=$'\t' read -r num cand; do
		[ -n "$cand" ] || continue
		# <base> + that one pull request, then this branch on top. A candidate
		# that folded cleanly cannot conflict with <base>, so a failure to build
		# the pair is a real error and the candidate is simply skipped.
		tree=$(git -C "$main" merge-tree --write-tree "origin/$base" "origin/$cand" 2>/dev/null) || continue
		probe=$(git -C "$main" commit-tree "$tree" -p "origin/$base" -m probe 2>/dev/null) || continue
		git -C "$main" merge-tree --write-tree "$probe" "origin/$br" >/dev/null 2>&1 ||
			printf 'pr\t%s\t%s\n' "$num" "$cand"
	done <<-EOF
		$folded
	EOF
}

# The stderr block for one dropped-out pull request: what it hit, and the merge
# that would let it back in.
conflict_report() {
	local num=$1 br=$2 probe=$3 hits

	# Every sentence keeps its Korean particle off the ref name: branch names are
	# arbitrary and 은/는, 이/가, 와/과 all depend on the last syllable, so a ref
	# spliced mid-sentence comes out wrong about half the time.
	echo "  #$num $br"
	case "$probe" in
		base)
			echo "      충돌 상대는 base(origin/$base)입니다."
			echo "        git merge origin/$base"
			echo "      그 브랜치에서 위를 머지하고 다시 돌리세요."
			;;
		unknown)
			echo "      충돌 상대를 특정하지 못했습니다 (git 2.38 미만 — merge-tree --write-tree 없음)."
			echo "      base와 먼저 접힌 PR을 차례로 의심하세요."
			;;
		'')
			echo "      base와도, 먼저 접힌 PR 어느 하나와도 개별로는 충돌하지 않습니다."
			echo "      그것들이 함께 있을 때만 깨집니다 — 합본(origin/$staging)을 보고 직접 푸세요."
			;;
		*)
			hits=$(printf '%s\n' "$probe" | awk -F'\t' '{printf "#%s %s, ", $2, $3}')
			echo "      충돌 상대는 base가 아니라 먼저 접힌 PR입니다 — ${hits%, }"
			printf '%s\n' "$probe" | awk -F'\t' '{print "        git merge origin/" $3}'
			echo "      그 브랜치에서 위를 머지하고 다시 돌리세요."
			# The dependency this creates unwinds on its own, which is what makes
			# the advice safe to follow — and worth saying out loud, because being
			# told to merge another open pull request looks like the wrong thing.
			echo "      상대 PR이 base에 머지되면 그 머지 커밋은 저절로 접힙니다."
			;;
	esac
}

rebuild() {
	local wt merged conflicted folded num br probe

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
	# What has gone in ahead of the branch being tried, in fold order. Only
	# `conflict_probe` reads it, to work out which of them a casualty hit.
	folded=""

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
			folded="$folded$num	$br"$'\n'
		else
			# A conflicting branch drops out of this round and gets named, the way
			# a merge queue kicks a pull request out of the queue. Stopping here
			# would let one pull request block everyone else's QA, and resolving
			# the conflict here would produce a merge nobody reviewed.
			#
			# Named *with what it hit*: the branch is gone from staging until
			# somebody acts, and the one thing they need is which merge to run.
			git -C "$wt" merge --abort >/dev/null 2>&1 || true
			probe=$(conflict_probe "$br" "$folded")
			conflicted="$conflicted$(conflict_report "$num" "$br" "$probe")"$'\n'
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
		echo "충돌로 빠진 PR — 합본($staging)에 없으니 아무도 QA하지 않습니다:" >&2
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
