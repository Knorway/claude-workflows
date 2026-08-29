#!/usr/bin/env bash
# PostToolUse hook. Says something when a source file has grown more comment
# than code.
#
# Why: this plugin already caps the convention docs, and the effect was to push
# prose one level down rather than to remove it. A file can end up six lines of
# configuration under a hundred and thirty lines of header explaining them, and
# nothing measures that — the header is where the model puts what the doc budget
# just refused. A rationale that no longer fits beside the thing it explains has
# usually stopped explaining it.
#
# A ratio, not a line count, because the right amount of comment is proportional
# to the code. A 900-line module with 200 lines of comment is fine; a 6-line
# config with 130 is not, and only the ratio tells them apart.
#
# Warning, not a denial. Unlike an e2e test, a long comment is not load-bearing
# and costs nothing to shorten later — and unlike a line count, "is this
# paragraph earning its place" is exactly the judgment a script cannot make. The
# floor keeps it quiet on the small files where the ratio is noise.
#
# Silent in any repo that has not declared a budget.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$path" ] || exit 0
[ -f "$path" ] || exit 0

case "$path" in
	*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) ;;
	*) exit 0 ;;
esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
{ [ -n "$cwd" ] && [ -d "$cwd" ]; } || cwd=$(dirname "$path")
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
cfg="$root/.claude/wt.json"
[ -f "$cfg" ] || exit 0

ratio=$(jq -r '.budgets.comment.ratio // empty' "$cfg" 2>/dev/null || true)
[ -n "$ratio" ] || exit 0
floor=$(jq -r '.budgets.comment.minComments // 40' "$cfg" 2>/dev/null || true)
case "$floor" in ''|*[!0-9]*) floor=40 ;; esac

# Line-oriented and deliberately crude: `//`, and anything inside or continuing
# a block comment. It does not parse strings, so a URL in code counts as code
# and a `//` inside a string counts as comment. Both errors are small and the
# answer only has to be right enough to notice a header that ate its file.
counts=$(awk '
	/^[[:space:]]*$/ { next }
	{
		line = $0
		if (inblock) { comment++; if (line ~ /\*\//) inblock = 0; next }
		if (line ~ /^[[:space:]]*\/\//) { comment++; next }
		if (line ~ /^[[:space:]]*\/\*/) { comment++; if (line !~ /\*\//) inblock = 1; next }
		code++
	}
	END { printf "%d %d", comment + 0, code + 0 }
' "$path")
comment=${counts% *}
code=${counts#* }

[ "$comment" -ge "$floor" ] || exit 0
[ "$code" -gt 0 ] || exit 0

# Integer arithmetic on a decimal ratio: compare comment*100 against
# code*ratio*100 so `2.5` works without bc.
scaled=$(awk -v r="$ratio" 'BEGIN { printf "%d", r * 100 }')
[ $((comment * 100)) -gt $((code * scaled)) ] || exit 0

cat >&2 <<EOF
[comment-budget] $path 는 주석 ${comment}줄 / 코드 ${code}줄이다 (상한 ${ratio}배).

주석을 지우라는 뜻이 아니다. **그 파일에 속하지 않는 주석이 있다는 신호**다. 한 문단씩 물어라:

1. 이 문단이 설명하는 코드가 **이 파일에** 있는가? 없으면 그 파일로 옮긴다.
2. 여러 파일에 걸친 불변식인가? 그건 CLAUDE.md다.
3. 길고 자주 안 읽는 절차인가? 그건 docs/ 다.
4. 코드를 읽으면 알 수 있는가? 그러면 지운다.

특히 **개수·목록·측정값을 산문에 적어두고 손으로 맞추는 문단**을 의심해라 — 그건 반드시
어긋나고, 어긋난 뒤에는 읽는 사람을 적극적으로 속인다. 도구가 출력할 수 있는 숫자는 적지 마라.
EOF
exit 2
