#!/usr/bin/env bash
# Deterministic TODO claim marking for the multi-tab /todo workflow.
#
# TODO.md is the SINGLE source of truth — the task list and the occupancy record
# are the same file, the same line. A free item reads `- []`, an item some tab is
# working on reads `- [-] <body>  #<slug>`, a finished one `- [x]`. There is no
# side ledger: the owner slug lives in the line itself, so nothing can drift out
# of sync with the list, and a human ticking `[-]` -> `[x]` releases the claim as
# a side effect of marking it done (no reaping needed).
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
#   todo.sh release [lineno...]  # release this tab's claims (all, or the given)
#   todo.sh mine                 # items currently claimed by this tab
#
# Selection is BY LINE NUMBER (of the item in TODO.md): `list` prints the line
# number next to each item; the caller passes those to `claim`. Every mutation
# takes the lock, rewrites the whole file, and renames it into place, so two tabs
# racing on the same line cannot both win.
set -euo pipefail

# --- resolve the single source of truth (primary checkout), from any worktree --
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
TODO="$MAIN/TODO.md"
[ -f "$TODO" ] || touch "$TODO"      # gitignored scratchpad; may not exist on a fresh clone
LOCK="$TODO.lock"                    # mutex directory — mkdir is atomic; macOS ships no flock(1)

# --- slug = this tab's claim-owner id: the checkout's own directory name --------
# Deliberately NOT derived from the branch: branch naming is a convention the
# worktree scripts happen to follow, and reading it here means every new naming
# convention has to be taught to this script too. The directory name is unique
# per worktree by construction, and in the primary checkout it is the repo name.
SLUG=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

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
#           applied to `[-]` lines, so prose that happens to end in `#word` on a
#           `[]` / `[x]` line is never mistaken for an owner.
AWKLIB='
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
function body(s){ return trim(substr(s, index(s,"]")+2)) }
function owner(b){
	BODY=b; OWNER=""
	if (match(b, /[ \t]+#[A-Za-z0-9_-]+$/)) {
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
		/^- \[x\] / { d++ }
		END {
			print ""
			if (ip != "") printf "  ── 진행중(점유, 선택 불가) ──\n%s\n", ip
			else          printf "  진행중(점유): 없음\n\n"
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
			} else {
				printf "  skipped  L%d (선택 불가 — [] 항목이 아님)\n", FNR > "/dev/stderr"
			}
		}
		{ print }
	'
	release_lock
	;;
release)
	# `- [-] body  #SLUG` -> `- [] body`, but only for lines this tab owns.
	# With no args, every line this tab holds; with line numbers, only those.
	want=" $* "; all=0; [ "$#" -gt 0 ] || all=1
	acquire_lock
	rewrite -v want="$want" -v all="$all" -v slug="$SLUG" "$AWKLIB"'
		/^- \[-\] / {
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
		/^- \[-\] / { owner(body($0)); if (OWNER == slug) printf "  L%d %s\n", FNR, BODY }
	' "$TODO"
	;;
slug)  echo "$SLUG" ;;
main)  echo "$MAIN" ;;
*)     echo "todo.sh: unknown command: $cmd (list|add|claim|release|mine)" >&2; exit 2 ;;
esac
