#!/usr/bin/env bash
# What this session has actually spent, and where.
#
#   session-cost.sh here [<CONFIRMED 건수>]  # 지금 세션: 문맥·요청 수·비용, 압축 시 예상 절약
#   session-cost.sh since <문자열>           # 그 문자열이 처음 나온 지점 이후 구간만
#   session-cost.sh subagents                # 서브에이전트별 cache_read·비용
#   session-cost.sh reads [<문자열>]         # Read 호출 수 (재-Read 세금의 측정 단위)
#
#   session-cost.sh list                     # 이 디렉터리의 세션들
#   session-cost.sh --session <id접두사> …   # 기본값(가장 최근)이 아닌 세션을 겨눈다
#
# `--session` 없이는 가장 최근 세션을 본다, 즉 보통은 지금 이 세션이다. 지나간 리뷰를
# 조사할 때는 겨냥이 필요하다 — 그게 이 도구를 만든 이유의 절반이다.
#
# THE ONE RULE, same as verify.sh: this script only READS. It never runs anything
# and never writes to the repo. It exists because every cost claim in
# docs/review-loop.md was hand-computed once, in a session, and then could not be
# re-checked by anyone — including the next version of this plugin.
#
# WHY A TOOL AND NOT A DOC. Two questions kept coming back with no way to answer
# them: "is the fan-out actually cheaper than doing it in-session" and "are the
# reviewers honouring their cost rule". Both are one aggregation over the
# transcript. Doing it by hand each time is how the numbers in that document got
# out of date in the first place — §4 claimed subagents dominated, and they do
# not; the orchestrator's carried context is half to two thirds.
#
# ACCURACY. Costs are DERIVED from token counts and a price table, not read from
# the transcript — Claude Code does not record a per-request price. Treat the
# absolute dollars as an estimate and the RATIOS as the real output; every
# decision this tool feeds (compact or not, tighten the reviewer prompt or not)
# is a comparison between two numbers computed the same way.
set -euo pipefail

command -v python3 >/dev/null 2>&1 || {
	echo "wt-cost: python3 가 없다 — 집계를 건너뛴다" >&2
	exit 0
}

SESSION=''
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--session)
			[ $# -ge 2 ] || { echo "wt-cost: --session 에 값이 없다" >&2; exit 2; }
			SESSION=$2; shift 2 ;;
		*) ARGS+=("$1"); shift ;;
	esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

cmd="${1:-here}"; shift || true

PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# The transcript directory name is the session's cwd with `/` and `.` folded to
# `-`. Derived rather than configured so this keeps working in a worktree, where
# the cwd is not the repo root and no session id is exported to the shell.
#
# Walking UP is the part that matters: the session's cwd is the directory Claude
# Code started in, but the caller may be several levels below it (this script's
# first run failed exactly that way, from plugins/wt). Stop at $HOME rather than
# `/` so a session started outside the home tree cannot be misattributed.
DIR=''
probe=$(pwd -P)
while :; do
	cand="$PROJECTS/$(printf '%s' "$probe" | sed 's/[\/.]/-/g')"
	if [ -d "$cand" ]; then DIR=$cand; break; fi
	[ "$probe" != "/" ] && [ "$probe" != "$HOME" ] || break
	probe=$(dirname "$probe")
done

[ -n "$DIR" ] || {
	echo "wt-cost: 이 디렉터리(와 상위)의 트랜스크립트를 못 찾았다: $(pwd -P)" >&2
	exit 0
}

# Say so when the transcript came from an ancestor rather than here. The walk-up
# is what makes the tool work from a subdirectory, but it also means a directory
# with no session of its own silently adopts its parent's — and the numbers would
# be reported as "this session" while belonging to entirely different work.
# Costs that name the wrong session are worse than no costs.
[ "$DIR" = "$PROJECTS/$(pwd -P | sed 's/[\/.]/-/g')" ] || \
	echo "wt-cost: 여기가 아니라 상위 디렉터리의 세션을 본다 → $probe" >&2

python3 - "$DIR" "$cmd" "${1:-}" "$SESSION" <<'PY'
import glob, json, os, sys

# stdout is block-buffered when piped, stderr is not, so a `wt-cost … | tail`
# showed the error before the output it belonged to — or swallowed it entirely.
sys.stdout.reconfigure(line_buffering=True)

dirpath, cmd, arg, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# Per-Mtok. Keyed by model because a session can switch models mid-run and the
# whole point of this tool is that the numbers survive scrutiny.
PRICES = {
    "opus":   dict(inp=5.0,  cc5=6.25, cc1h=10.0, cr=0.5, out=25.0),
    "sonnet": dict(inp=3.0,  cc5=3.75, cc1h=6.0,  cr=0.3, out=15.0),
    "haiku":  dict(inp=1.0,  cc5=1.25, cc1h=2.0,  cr=0.1, out=5.0),
}

def price_for(model):
    m = (model or "").lower()
    for key in PRICES:
        if key in m:
            return PRICES[key]
    return PRICES["opus"]          # unknown model: assume the expensive one

def load(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                pass                # a half-written last line during a live session
    return out

def sessions():
    return sorted(glob.glob(os.path.join(dirpath, "*.jsonl")),
                  key=os.path.getmtime, reverse=True)

def pick_session():
    files = sessions()
    if not files:
        return None
    if not want:
        return files[0]
    hits = [p for p in files if os.path.basename(p).startswith(want)]
    if not hits:
        sys.stderr.write("wt-cost: '%s' 로 시작하는 세션이 없다 — `wt-cost list` 로 확인해라\n" % want)
        sys.exit(1)
    return hits[0]

def usage(e):
    return ((e.get("message") or {}).get("usage")) or {}

def billable(e):
    u = usage(e)
    cc = u.get("cache_creation") or {}
    return dict(
        inp=u.get("input_tokens", 0),
        cc5=cc.get("ephemeral_5m_input_tokens", u.get("cache_creation_input_tokens", 0)),
        cc1h=cc.get("ephemeral_1h_input_tokens", 0),
        cr=u.get("cache_read_input_tokens", 0),
        out=u.get("output_tokens", 0),
        model=(e.get("message") or {}).get("model"),
    )

def cost_of(b):
    p = price_for(b["model"])
    return sum(b[k] * p[k] / 1e6 for k in ("inp", "cc5", "cc1h", "cr", "out"))

def requests(events):
    for e in events:
        if e.get("type") != "assistant":
            continue
        b = billable(e)
        if b["inp"] + b["cc5"] + b["cc1h"] + b["cr"] + b["out"] == 0:
            continue               # a continuation block of an already-billed turn
        yield e, b

def ctx(b):
    return b["inp"] + b["cc5"] + b["cc1h"] + b["cr"]

def summarise(events, label):
    n = 0; total = 0.0; ctxs = []; cr = 0
    for _, b in requests(events):
        n += 1; total += cost_of(b); ctxs.append(ctx(b)); cr += b["cr"]
    if n == 0:
        print(f"  {label}: 요청 없음")
        return None
    print(f"  {label}: 요청 {n}  문맥 {ctxs[0]:,}→{ctxs[-1]:,} (평균 {sum(ctxs)//n:,})"
          f"  cache_read {cr:,}  ${total:.2f}")
    return n, sum(ctxs) // n, ctxs[-1], total

def find_from(events, needle):
    # Match against the raw entry so a tool call, its result, or a message all
    # count — the caller knows a string they saw, not which field carried it.
    for i, e in enumerate(events):
        if needle in json.dumps(e, ensure_ascii=False):
            return i
    return None

if cmd == "list":
    files = sessions()
    if not files:
        print("  세션 없음")
        sys.exit(0)
    print(f"  {dirpath}")
    for p in files[:15]:
        ev = load(p)
        n = sum(1 for _ in requests(ev))
        subs = len(glob.glob(os.path.join(p[:-6], "subagents", "*.jsonl")))
        print(f"  {os.path.basename(p)[:8]}  엔트리 {len(ev):>6,}  요청 {n:>4}  서브에이전트 {subs:>3}")
    sys.exit(0)

sess = pick_session()
if not sess:
    sys.stderr.write("wt-cost: 트랜스크립트 파일이 없다\n")
    sys.exit(0)

events = load(sess)
print(f"세션 {os.path.basename(sess)[:8]} · 엔트리 {len(events):,}")

if cmd == "here":
    r = summarise(events, "전체")
    if r:
        n, avg, last, total = r
        # The estimate the 4->5 compaction prompt in commands/review.md needs.
        # 6 requests per CONFIRMED finding is measured, not assumed: 13 findings
        # took 79 requests end to end (receive -> fix -> recheck -> report).
        try:
            confirmed = int(arg)
        except (TypeError, ValueError):
            confirmed = 0
        if confirmed > 0:
            est_req = confirmed * 6
            floor = 60_000
            saved = max(0, last - floor) * est_req * 0.5 / 1e6
            print(f"  → CONFIRMED {confirmed}건이면 5단계는 대략 {est_req}요청. "
                  f"지금({last:,}) 압축하고 시작하면 약 ${saved:.2f} 절약")
            if last < 150_000:
                print("  → 다만 문맥이 150k 미만이다. 압축값과 캐시 재작성값이 절약을 먹는다 — 권하지 않는다")

elif cmd == "since":
    if not arg:
        sys.stderr.write("wt-cost: since <문자열>\n")
        sys.exit(2)
    i = find_from(events, arg)
    if i is None:
        sys.stderr.write("wt-cost: '%s' 를 트랜스크립트에서 못 찾았다\n" % arg)
        sys.exit(1)
    print(f"  기준: '{arg}' 가 처음 나온 엔트리 {i}")
    summarise(events[:i], "이전")
    summarise(events[i:], "이후")

elif cmd == "subagents":
    sub = os.path.join(sess[:-6], "subagents")
    files = sorted(glob.glob(os.path.join(sub, "*.jsonl")))
    if not files:
        print("  서브에이전트 기록 없음")
        sys.exit(0)
    rows = []
    for f in files:
        n = 0; total = 0.0; cr = 0
        for _, b in requests(load(f)):
            n += 1; total += cost_of(b); cr += b["cr"]
        rows.append((total, cr, n, os.path.basename(f)[:20]))
    rows.sort(reverse=True)
    print(f"  서브에이전트 {len(rows)}개 · 합계 ${sum(r[0] for r in rows):.2f}")
    print(f"  {'비용':>8} {'cache_read':>12} {'요청':>5}  에이전트")
    for total, cr, n, name in rows:
        print(f"  {('$%.2f' % total):>8} {cr:>12,} {n:>5}  {name}")
    # The reviewer prompt says opening a whole file is the most expensive thing it
    # can do. A high per-agent cache_read is what that rule being ignored looks
    # like: context that grew because files kept landing in it.
    #
    # Keyed on cache_read, NOT on rows[0]. The table is sorted by cost, and the two
    # orders disagree — a short agent on an expensive model can outrank a long one
    # that read half the repo, which is precisely the agent this line is looking for.
    worst = max(rows, key=lambda r: r[1])
    if worst[1] > 1_000_000:
        print(f"  → 최대 {worst[1]:,} ({worst[3]}) — 리뷰어의 '파일을 통째로 열지 마라' 규칙을 의심할 크기다")

elif cmd == "reads":
    scope = events
    if arg:
        i = find_from(events, arg)
        if i is None:
            sys.stderr.write("wt-cost: '%s' 를 못 찾았다\n" % arg)
            sys.exit(1)
        scope = events[i:]
        print(f"  기준: '{arg}' 이후")
    reads = {}
    for e in scope:
        if e.get("type") != "assistant":
            continue
        for block in ((e.get("message") or {}).get("content") or []):
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Read":
                p = (block.get("input") or {}).get("file_path", "?")
                reads[p] = reads.get(p, 0) + 1
    total = sum(reads.values())
    repeats = sum(v - 1 for v in reads.values() if v > 1)
    print(f"  Read 호출 {total}회 · 파일 {len(reads)}개 · 같은 파일 재호출 {repeats}회")
    for p, v in sorted(reads.items(), key=lambda kv: -kv[1])[:10]:
        if v > 1:
            print(f"    {v:>3}회  {p}")

else:
    sys.stderr.write("wt-cost: 모르는 명령: %s (here|since|subagents|reads|list)\n" % cmd)
    sys.exit(2)
PY
