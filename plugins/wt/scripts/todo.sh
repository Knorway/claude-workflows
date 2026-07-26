#!/usr/bin/env bash
# Deterministic TODO claim marking for the multi-tab /todo workflow.
#
# TODO.md is the SINGLE source of truth — the task list and the occupancy record
# are the same file, the same line. The lifecycle:
#
#   - [] body                 free, selectable
#   - [-] body  #<slug>       claimed, a tab is working on it
#   - [~] body  #<slug>       a pull request is up, waiting on merge
#   - [x] body                done (also releases the claim, see below)
#
# There is no side ledger for OCCUPANCY: the owner slug lives in the line itself,
# so nothing can drift out of sync with the list, and a human ticking a claimed
# line to `[x]` releases it as a side effect of marking it done (no reaping).
# (`wt-verify` keeps a ledger of its own for verification results, but that is a
# different file — .git/worktrees/<name>/wt/verify-<branch>.tsv — and never touches this one.)
#
# Every state is known to every reader here. Adding a marker that `list` doesn't
# match makes the item VANISH from the picker rather than change status, so a new
# state means teaching list/claim/release/mine all at once.
#
# The file is a machine-local scratchpad: gitignored, never committed, so git
# operations (checkout / switch / pull / merge) never touch it and its content
# never flips under you. It lives only in the PRIMARY checkout; every worktree
# reaches that one file via --git-common-dir. This script is the only thing that
# writes it, so notes and claims can never land in a worktree's own copy where
# other tabs can't see them.
#
#   todo.sh list                 # numbered picker of selectable items + context
#   todo.sh add   "<note>"       # append `- [] <note>` to the primary TODO.md
#   todo.sh claim  <lineno...>   # claim those items for this tab (if still free)
#   todo.sh pr    [lineno...]    # mark this tab's claims as "PR raised" ([-] -> [~])
#   todo.sh release [lineno...]  # release this tab's claims (all, or the given)
#   todo.sh mine                 # items currently held by this tab
#
# Selection is BY LINE NUMBER (of the item in TODO.md): `list` prints the line
# number next to each item; the caller passes those to `claim`. Every mutation
# takes the lock, rewrites the whole file, and renames it into place, so two tabs
# racing on the same line cannot both win.
set -euo pipefail

# --- resolve the single source of truth (primary checkout), from any worktree --
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
TODO="$MAIN/TODO.md"
LOCK="$TODO.lock"                    # mutex directory — mkdir is atomic; macOS ships no flock(1)

# --- refuse to work in a repo that would COMMIT the scratchpad -----------------
# This file is machine-local by design: claim markers (`[-] … #slug`), half-formed
# notes, whatever you were thinking at 2am. `/wt:remote-push` runs `git add -A`, so
# in a repo that doesn't ignore TODO.md all of that lands in the first pull request.
#
# The gate is "is it ignored", not "does it exist" — and it runs BEFORE the touch,
# because creating a file the repo is going to commit is exactly the thing to avoid.
# Asking for this in prose (commands/todo.md) was not enough: by the time anyone
# reads the prose the file is already there.
#
# But it only ever refuses to CREATE. When the file is already sitting there the
# refusal has nothing left to prevent and plenty to break: every subcommand —
# including `release`/`mine`/`pr`, the only way to get a claim back — would exit 1,
# and the claim could be undone by hand-editing TODO.md and nothing else. So an
# existing-but-unignored file warns and keeps going.
#
# `check-ignore` consults the index, so a TRACKED TODO.md reports "not ignored" no
# matter what .gitignore says. Adding the two lines therefore cannot fix that case
# on its own, which is why the message names `git rm --cached` when it applies —
# without it the instructions are a loop that never terminates.
ignored() { git -C "$MAIN" check-ignore -q "$1" 2>/dev/null; }
tracked() { git -C "$MAIN" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
if ! ignored "$TODO"; then
	{
		if [ -f "$TODO" ]; then
			echo "todo.sh: 경고 — $TODO 가 .gitignore되어 있지 않다. 계속 진행한다."
		else
			echo "todo.sh: $TODO 가 .gitignore되어 있지 않다 — 만들지 않았다."
		fi
		cat <<EOF

  TODO.md는 머신 로컬 스크래치패드다. 점유 마커(#slug)와 메모가 들어가고,
  /wt:remote-push 의 \`git add -A\` 가 그걸 그대로 커밋해 PR로 내보낸다.

  $MAIN/.gitignore 에 두 줄을 넣을 것:

    /TODO.md
    /TODO.md.lock
EOF
		tracked "$TODO" && cat <<EOF

  이 파일은 이미 git이 추적 중이라 .gitignore만으로는 부족하다. 함께 실행할 것:

    git -C "$MAIN" rm --cached TODO.md
EOF
	} >&2
	[ -f "$TODO" ] || exit 1
fi
ignored "$LOCK" || echo "todo.sh: 경고 — /TODO.md.lock 도 .gitignore에 넣을 것" >&2
[ -f "$TODO" ] || touch "$TODO"      # gitignored scratchpad; may not exist on a fresh clone

# --- slug = this tab's claim-owner id: the checkout's own directory name --------
# Deliberately NOT derived from the branch: branch naming is a convention the
# worktree scripts happen to follow, and reading it here means every new naming
# convention has to be taught to this script too. The directory name is unique
# per worktree by construction, and in the primary checkout it is the repo name.
#
# SANITISED, because a directory name can hold things owner() cannot read back —
# spaces, Korean, `@`. Widening owner()'s charset is the wrong end to fix: the
# writer must produce only what the reader accepts, or claim writes an owner that
# release/pr/mine can never match and the item is locked with no recovery but
# hand-editing TODO.md. Anything outside [A-Za-z0-9_.-] becomes `-`; a name that
# sanitises away entirely (all-Korean, say) falls back to a checksum of the
# original so two such checkouts still get distinct slugs.
raw_slug=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
SLUG=$(printf '%s' "$raw_slug" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-*$//')
[ -n "$SLUG" ] || SLUG="wt-$(printf '%s' "$raw_slug" | cksum | cut -d' ' -f1)"

cmd=${1:-list}; shift || true

# --- cross-process mutex over TODO.md (mkdir = atomic create-if-absent) --------
acquire_lock() {
	local tries=0
	until mkdir "$LOCK" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -gt 500 ] && { echo "todo.sh: TODO.md lock timeout ($LOCK)" >&2; exit 1; }
		sleep 0.02
	done
	trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM
}
release_lock() { rmdir "$LOCK" 2>/dev/null || true; trap - EXIT INT TERM; }

# --- shared awk helpers, textually prepended to each program --------------------
# trim()  — strip surrounding whitespace
# body()  — the item text after the checkbox
# owner() — the `#slug` suffix of a claimed line (globals OWNER / BODY); the
#           pattern is anchored at EOL over a narrow charset and is only ever
#           applied to `[-]` / `[~]` lines, so prose that happens to end in
#           `#word` on a `[]` / `[x]` line is never mistaken for an owner.
#           The charset must cover everything a DIRECTORY NAME can hold, since
#           that is where the slug comes from — `.` in particular (`my.app`).
#           Miss a character and claim writes an owner that owner() cannot read
#           back, so release/pr/mine silently match nothing and the item is
#           locked forever.
AWKLIB='
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
function body(s){ return trim(substr(s, index(s,"]")+2)) }
function owner(b){
	BODY=b; OWNER=""
	if (match(b, /[ \t]+#[A-Za-z0-9_.-]+$/)) {
		OWNER=substr(b, RSTART); sub(/^[ \t]+#/, "", OWNER)
		BODY=trim(substr(b, 1, RSTART-1))
	}
}
'

# rewrite TODO.md through an awk program, atomically (same-dir tmp + rename).
# Args are passed to awk verbatim, so any -v assignments must precede the program
# text — awk treats a -v that follows the program as a file operand.
rewrite() {
	local tmp="$TODO.tmp.$$"
	awk "$@" "$TODO" > "$tmp" && mv "$tmp" "$TODO"
}

case "$cmd" in
list)
	# Number the free ([] / [ ]) items; claimed ([-]) ones are pulled out into a
	# read-only "진행중" block with their owner. TODO.md is read, never written.
	awk "$AWKLIB"'
		/^- \[ ?\] / {
			sel++; b=body($0)
			printf "  [%d]  L%-3d %s\n", sel, FNR, b
			map = map (map ? " " : "") sel ":" FNR
			next
		}
		/^- \[-\] / {
			owner(body($0))
			ip = ip sprintf("  [-]  L%-3d %s  #%s\n", FNR, BODY, OWNER ? OWNER : "?")
			next
		}
		/^- \[~\] / {
			owner(body($0))
			pr = pr sprintf("  [~]  L%-3d %s  #%s\n", FNR, BODY, OWNER ? OWNER : "?")
			next
		}
		/^- \[x\] / { d++ }
		END {
			print ""
			if (ip != "") printf "  ── 진행중(점유, 선택 불가) ──\n%s\n", ip
			else          printf "  진행중(점유): 없음\n\n"
			if (pr != "") printf "  ── PR 올라감(머지 대기, 선택 불가) ──\n%s\n", pr
			printf "  완료: %d개\n", d+0
			printf "  # MAP %s\n", map
		}
	' "$TODO"
	;;
add)
	# Append a new item to the primary TODO.md from any worktree tab. Under the
	# lock so concurrent adds don't clobber; ensures a trailing newline first so
	# the note never glues onto the previous line.
	[ "$#" -gt 0 ] || { echo "usage: todo.sh add \"<note>\"" >&2; exit 2; }
	note="$*"
	acquire_lock
	if [ -s "$TODO" ] && [ -n "$(tail -c1 "$TODO")" ]; then printf '\n' >> "$TODO"; fi
	printf -- '- [] %s\n' "$note" >> "$TODO"
	release_lock
	echo "  added: - [] $note" >&2
	;;
claim)
	# `- [] body` -> `- [-] body  #SLUG` for each requested line, in one pass.
	# A line that is already claimed, or isn't a selectable item at all, is left
	# untouched and reported as skipped.
	[ "$#" -gt 0 ] || { echo "usage: todo.sh claim <lineno...>" >&2; exit 2; }
	want=" $* "
	acquire_lock
	rewrite -v want="$want" -v slug="$SLUG" "$AWKLIB"'
		index(want, " " FNR " ") > 0 {
			if ($0 ~ /^- \[ ?\] /) {
				b = body($0)
				printf "  claimed  L%d: %s\n", FNR, b > "/dev/stderr"
				printf "- [-] %s  #%s\n", b, slug
				next
			}
			if ($0 ~ /^- \[-\] /) {
				owner(body($0))
				printf "  skipped  L%d (이미 #%s 점유 — 다른 탭이 가져갔을 수 있음)\n", \
					FNR, OWNER ? OWNER : "?" > "/dev/stderr"
			} else if ($0 ~ /^- \[~\] /) {
				owner(body($0))
				printf "  skipped  L%d (#%s가 이미 PR을 올림 — 머지 대기)\n", \
					FNR, OWNER ? OWNER : "?" > "/dev/stderr"
			} else {
				printf "  skipped  L%d (선택 불가 — [] 항목이 아님)\n", FNR > "/dev/stderr"
			}
		}
		{ print }
	'
	release_lock
	;;
pr)
	# `- [-] body  #SLUG` -> `- [~] body  #SLUG`: a pull request is up, so the item
	# is no longer "being worked on" but is still this tab's and still not done.
	# Only lines this tab owns move; another tab's claim is never touched.
	# With no args every claim this tab holds moves, which is what /wt:remote-push
	# calls — it knows the branch, not the line numbers.
	want=" $* "; all=0; [ "$#" -gt 0 ] || all=1
	acquire_lock
	rewrite -v want="$want" -v all="$all" -v slug="$SLUG" "$AWKLIB"'
		/^- \[-\] / {
			if (all == "1" || index(want, " " FNR " ") > 0) {
				owner(body($0))
				if (OWNER == slug) {
					n++
					printf "  PR      L%d: %s\n", FNR, BODY > "/dev/stderr"
					printf "- [~] %s  #%s\n", BODY, slug
					next
				}
			}
		}
		{ print }
		# Always say something. Silence here is ambiguous — the caller
		# (/wt:remote-push) cannot tell "nothing was claimed" from "the owner
		# slug did not parse", and it is asked to report what moved.
		END {
			if (n) printf "  PR 표시: %d건 (#%s)\n", n, slug > "/dev/stderr"
			else   printf "  PR 표시할 점유 항목 없음 (#%s)\n", slug > "/dev/stderr"
		}
	'
	release_lock
	;;
release)
	# `- [-] body  #SLUG` (or `- [~] …`) -> `- [] body`, but only for lines this
	# tab owns. With no args, every line this tab holds; with line numbers, only
	# those. `[~]` is included on purpose: abandoning after a PR went up (closed
	# it, superseded it) must not leave the item stuck as nobody-can-select.
	want=" $* "; all=0; [ "$#" -gt 0 ] || all=1
	acquire_lock
	rewrite -v want="$want" -v all="$all" -v slug="$SLUG" "$AWKLIB"'
		/^- \[-\] |^- \[~\] / {
			if (all == "1" || index(want, " " FNR " ") > 0) {
				owner(body($0))
				if (OWNER == slug) {
					printf "  released %s\n", BODY > "/dev/stderr"
					printf "- [] %s\n", BODY
					next
				}
			}
		}
		{ print }
	'
	release_lock
	;;
mine)
	awk -v slug="$SLUG" "$AWKLIB"'
		/^- \[-\] / { owner(body($0)); if (OWNER == slug) printf "  [-] L%d %s\n", FNR, BODY }
		/^- \[~\] / { owner(body($0)); if (OWNER == slug) printf "  [~] L%d %s  (PR 올라감)\n", FNR, BODY }
	' "$TODO"
	;;
slug)  echo "$SLUG" ;;
main)  echo "$MAIN" ;;
*)     echo "todo.sh: unknown command: $cmd (list|add|claim|pr|release|mine)" >&2; exit 2 ;;
esac
