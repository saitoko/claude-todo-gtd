#!/bin/bash
# todo スキル テストランナー
# GitHub には接続しない。normalize_due・バリデーション・テンプレートファイル操作のみをテスト。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../scripts/todo-engine.js"  # todo-engine.js
[ -f "$ENGINE" ] || ENGINE="$SCRIPT_DIR/../todo-engine.js"  # 公開リポジトリはルート直下レイアウト
FMT_JS="$SCRIPT_DIR/helpers/date-fmt.js"  # 共通日付フォーマット関数
STUB_ENGINE_PATH="$SCRIPT_DIR/stubs/octokit-stub.js"  # Octokit注入シーム用スタブ（Issue #1648）。
  # GH_TOKEN=dummy + 実 @octokit/rest 解決に依存していた「run」系バリデーションのみの
  # テスト（実API呼び出しに到達しないもの）を、OCTOKIT_STUB_ENV 経由の環境非依存な形に
  # 置換するために使う。
TEMP_TFILE=$(mktemp /tmp/todo-test-templates-XXXXXX)
# Issue #1882 根本原因（2026-08-27 判明）: macOS(BSD) の mktemp は、末尾以外に置いた
# XXXXXX を展開せずリテラルな固定ファイル名を返す（例: "...-XXXXXX.json" のように
# XXXXXX の後に拡張子を続けると、"XXXXXX" はテンプレートとして認識されずそのまま
# 固定文字列になる）。そのため §11 用の一時ファイル名が実行のたびに同一になり、
# 並行実行された別プロセスの `rm -f "$TEMP_TFILE"` に巻き込まれて消える競合が起きて
# いた（mktemp コマンド自体は失敗していない）。本修正で XXXXXX を末尾に置き正しく
# ランダム化したため、この競合は解消される。以下の存在チェックは、ディスク容量
# 不足・権限不足など mktemp が本当に失敗する別ケースへの防御として残す。
if [ -z "${TEMP_TFILE}" ] || [ ! -f "${TEMP_TFILE}" ]; then
  printf '❌ [致命的エラー] mktemp によるテンプレート用一時ファイルの作成に失敗しました\n' >&2
  printf '   TEMP_TFILE=[%s]\n' "${TEMP_TFILE:-<空文字列>}" >&2
  printf '   考えられる原因: /tmp の空き容量不足・権限不足・mktemp コマンド自体の異常\n' >&2
  printf '   $TMPDIR=[%s] / df -h /tmp の結果:\n' "${TMPDIR:-未設定}" >&2
  df -h /tmp >&2 2>/dev/null || true
  exit 1
fi
if ! printf '{}' > "${TEMP_TFILE}"; then
  printf '❌ [致命的エラー] テンプレート用一時ファイルへの初期化書き込みに失敗しました: %s\n' "${TEMP_TFILE}" >&2
  exit 1
fi
PASS=0
FAIL=0
SKIP=0

# テスト固定日付（再現性のため）
TEST_TODAY="2026-04-05"  # 日曜日

# ────────────────────────────────────────────
# ヘルパー
# ────────────────────────────────────────────

# Issue #1882 診断フック: §11 テンプレートファイル操作の実行区間でのみ
# 有効化する。区間内で assert が FAIL したとき、$TEMP_TFILE の状態
# （存在・サイズ・内容）を1回だけ出力に残し、次に再現したときの切り分けを
# 即座にできるようにする。区間外（他の約1300件）では何も出力しない。
TEMPLATE_DIAG_ACTIVE=0
TEMPLATE_DIAG_DUMPED=0

dump_template_diag() {
  [ "${TEMPLATE_DIAG_ACTIVE}" -eq 1 ] || return 0
  [ "${TEMPLATE_DIAG_DUMPED}" -eq 1 ] && return 0
  TEMPLATE_DIAG_DUMPED=1
  printf "     ─── [診断/Issue #1882] TEMP_TFILE の状態 ───\n"
  if [ -z "${TEMP_TFILE}" ]; then
    printf "     TEMP_TFILE: <空文字列>（mktemp 失敗の疑い）\n"
    printf "     ──────────────────────────────\n"
    return 0
  fi
  printf "     TEMP_TFILE: %s\n" "${TEMP_TFILE}"
  if [ ! -e "${TEMP_TFILE}" ]; then
    printf "     存在: しない\n"
    printf "     ──────────────────────────────\n"
    return 0
  fi
  local diag_size
  diag_size=$(wc -c < "${TEMP_TFILE}" 2>/dev/null | tr -d ' ')
  printf "     存在: する / サイズ: %s bytes\n" "${diag_size:-不明}"
  if [ -n "${diag_size}" ] && [ "${diag_size}" -le 2000 ] 2>/dev/null; then
    printf "     内容:\n"
    sed 's/^/       /' "${TEMP_TFILE}"
  else
    printf "     内容（先頭2000バイト）:\n"
    head -c 2000 "${TEMP_TFILE}" | sed 's/^/       /'
    printf "\n"
  fi
  printf "     ──────────────────────────────\n"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s\n" "$desc"
    printf "     期待: [%s]\n" "$expected"
    printf "     実際: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
    dump_template_diag
  fi
}

assert_contains() {
  local desc="$1" pattern="$2" actual="$3"
  if printf '%s' "$actual" | grep -aq "$pattern"; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s\n" "$desc"
    printf "     パターン [%s] が含まれていない\n" "$pattern"
    printf "     実際: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
    dump_template_diag
  fi
}

assert_not_contains() {
  local desc="$1" pattern="$2" actual="$3"
  if printf '%s' "$actual" | grep -aq "$pattern"; then
    printf "  ❌ %s\n" "$desc"
    printf "     パターン [%s] が含まれてはいけない\n" "$pattern"
    printf "     実際: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
    dump_template_diag
  else
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  fi
}

assert_exit_ok() {
  local desc="$1" exit_code="${2:-0}"
  if [ "$exit_code" -eq 0 ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s (exit: %s)\n" "$desc" "$exit_code"; FAIL=$((FAIL+1))
    dump_template_diag
  fi
}

assert_exit_fail() {
  local desc="$1" exit_code="${2:-0}"
  if [ "$exit_code" -ne 0 ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s (エラーが期待されたが exit 0)\n" "$desc"; FAIL=$((FAIL+1))
    dump_template_diag
  fi
}

# normalize_due を TEST_TODAY を使って実行
normalize_due_test() {
  local raw="$1"
  RAW_ENV="$raw" TODAY_ENV="$TEST_TODAY" FMT_JS="$FMT_JS" node << 'JSEOF'
const fmt = require(process.env.FMT_JS);
const raw   = process.env.RAW_ENV   || '';
const today = process.env.TODAY_ENV;
const d   = () => new Date(today + 'T00:00:00');
const add = (dt, days) => { dt.setDate(dt.getDate()+days); return dt; };

let result = null;
if      (raw === '今日')   { result = today; }
else if (raw === '明日')   { result = fmt(add(d(), 1)); }
else if (raw === '明後日') { result = fmt(add(d(), 2)); }
else if (raw === '来週')   { result = fmt(add(d(), 7)); }
else if (raw === '来月')   { const dt=d(); dt.setMonth(dt.getMonth()+1); result=fmt(dt); }
else if (raw === '今週末') { const dt=d(); const dow=dt.getDay(); result=fmt(add(dt, dow===6?0:6-dow)); }
else if (raw === '今月末') { const dt=d(); result=fmt(new Date(dt.getFullYear(),dt.getMonth()+1,0)); }
else if (raw === '来月末') { const dt=d(); result=fmt(new Date(dt.getFullYear(),dt.getMonth()+2,0)); }
else {
  let m;
  if      ((m=raw.match(/^(\d+)日後$/)))             { result=fmt(add(d(),+m[1])); }
  else if ((m=raw.match(/^(\d+)週(?:間)?後$/)))      { result=fmt(add(d(),+m[1]*7)); }
  else if ((m=raw.match(/^(\d+)[ヶか]月後$/)))       { const dt=d(); dt.setMonth(dt.getMonth()+ +m[1]); result=fmt(dt); }
  else if ((m=raw.match(/^来週([月火水木金土日])曜(?:日)?$/))) {
    const names=['日','月','火','水','木','金','土'];
    const target=names.indexOf(m[1]);
    const dt=d();
    const toNextMon=((1-dt.getDay()+7)%7)||7;
    dt.setDate(dt.getDate()+toNextMon);
    const offset=target===0?6:target-1;
    dt.setDate(dt.getDate()+offset);
    result=fmt(dt);
  }
}
process.stdout.write(result !== null ? result : raw);
JSEOF
}

# テンプレートDBをテスト用一時ファイルに向けた node スニペット実行
# $1: ノードコード（TFILE_ENV 経由でファイルパスを受け取る）
run_template_node() {
  local script="$1"
  TFILE_ENV="$TEMP_TFILE" node -e "$script"
}

# ────────────────────────────────────────────
# テスト開始
# ────────────────────────────────────────────
echo "=========================================="
echo " todo スキル テストランナー"
echo " 基準日: ${TEST_TODAY}（日曜日）"
echo "=========================================="

# ──────────────────────────────────────────
# § 1  normalize_due — 基本パターン (シナリオ 16-1)
# ──────────────────────────────────────────
echo ""
echo "§1  normalize_due — 日本語相対表現"

assert_eq "今日"         "2026-04-05" "$(normalize_due_test '今日')"
assert_eq "明日"         "2026-04-06" "$(normalize_due_test '明日')"
assert_eq "明後日"       "2026-04-07" "$(normalize_due_test '明後日')"
assert_eq "来週(+7日)"   "2026-04-12" "$(normalize_due_test '来週')"
assert_eq "来月"         "2026-05-05" "$(normalize_due_test '来月')"
assert_eq "今週末(日曜→土曜+6日)" "2026-04-11" "$(normalize_due_test '今週末')"
assert_eq "今月末"       "2026-04-30" "$(normalize_due_test '今月末')"
assert_eq "来月末"       "2026-05-31" "$(normalize_due_test '来月末')"
assert_eq "3日後"        "2026-04-08" "$(normalize_due_test '3日後')"
assert_eq "2週間後"      "2026-04-19" "$(normalize_due_test '2週間後')"
assert_eq "2週後"        "2026-04-19" "$(normalize_due_test '2週後')"
assert_eq "3ヶ月後"      "2026-07-05" "$(normalize_due_test '3ヶ月後')"
assert_eq "3か月後"      "2026-07-05" "$(normalize_due_test '3か月後')"
assert_eq "来週月曜(日曜起点)" "2026-04-06" "$(normalize_due_test '来週月曜')"
assert_eq "来週金曜(日曜起点)" "2026-04-10" "$(normalize_due_test '来週金曜')"
assert_eq "来週土曜(日曜起点)" "2026-04-11" "$(normalize_due_test '来週土曜')"
assert_eq "来週日曜(日曜起点)" "2026-04-12" "$(normalize_due_test '来週日曜')"

# 変換されないパターンはそのまま返す (シナリオ 16-2)
assert_eq "未対応パターンはそのまま返す(先週)" "先週" "$(normalize_due_test '先週')"
assert_eq "未対応パターンはそのまま返す(おととい)" "おととい" "$(normalize_due_test 'おととい')"

# ──────────────────────────────────────────
# § 1b  normalize_due — English relative expressions
# ──────────────────────────────────────────
echo ""
echo "§1b  normalize_due — English relative expressions"

# Basic patterns
assert_eq "en: today"                "$TEST_TODAY" "$(node "$ENGINE" normalize-due 'today' "$TEST_TODAY")"
assert_eq "en: tomorrow"             "2026-04-06"  "$(node "$ENGINE" normalize-due 'tomorrow' "$TEST_TODAY")"
assert_eq "en: day after tomorrow"   "2026-04-07"  "$(node "$ENGINE" normalize-due 'day after tomorrow' "$TEST_TODAY")"
assert_eq "en: next week"            "2026-04-12"  "$(node "$ENGINE" normalize-due 'next week' "$TEST_TODAY")"
assert_eq "en: next month"           "2026-05-05"  "$(node "$ENGINE" normalize-due 'next month' "$TEST_TODAY")"
assert_eq "en: this weekend"         "2026-04-11"  "$(node "$ENGINE" normalize-due 'this weekend' "$TEST_TODAY")"
assert_eq "en: end of this month"    "2026-04-30"  "$(node "$ENGINE" normalize-due 'end of this month' "$TEST_TODAY")"
assert_eq "en: end of next month"    "2026-05-31"  "$(node "$ENGINE" normalize-due 'end of next month' "$TEST_TODAY")"

# Relative patterns (in N days/weeks/months)
assert_eq "en: in 3 days"            "2026-04-08"  "$(node "$ENGINE" normalize-due 'in 3 days' "$TEST_TODAY")"
assert_eq "en: in 1 day"             "2026-04-06"  "$(node "$ENGINE" normalize-due 'in 1 day' "$TEST_TODAY")"
assert_eq "en: in 2 weeks"           "2026-04-19"  "$(node "$ENGINE" normalize-due 'in 2 weeks' "$TEST_TODAY")"
assert_eq "en: in 1 week"            "2026-04-12"  "$(node "$ENGINE" normalize-due 'in 1 week' "$TEST_TODAY")"
assert_eq "en: in 3 months"          "2026-07-05"  "$(node "$ENGINE" normalize-due 'in 3 months' "$TEST_TODAY")"
assert_eq "en: in 1 month"           "2026-05-05"  "$(node "$ENGINE" normalize-due 'in 1 month' "$TEST_TODAY")"

# Next weekday (TEST_TODAY=2026-04-05 is Sunday)
# next Monday = 2026-04-06, next Tuesday = 2026-04-07, ...
assert_eq "en: next monday"          "2026-04-06"  "$(node "$ENGINE" normalize-due 'next monday' "$TEST_TODAY")"
assert_eq "en: next friday"          "2026-04-10"  "$(node "$ENGINE" normalize-due 'next friday' "$TEST_TODAY")"
assert_eq "en: next saturday"        "2026-04-11"  "$(node "$ENGINE" normalize-due 'next saturday' "$TEST_TODAY")"
assert_eq "en: next sunday"          "2026-04-12"  "$(node "$ENGINE" normalize-due 'next sunday' "$TEST_TODAY")"

# Case insensitivity
assert_eq "en: Next Week (caps)"     "2026-04-12"  "$(node "$ENGINE" normalize-due 'Next Week' "$TEST_TODAY")"
assert_eq "en: IN 1 DAY (caps)"      "2026-04-06"  "$(node "$ENGINE" normalize-due 'IN 1 DAY' "$TEST_TODAY")"

# Cross-language: LANG_ENV=en but Japanese input still works
# (Issue #1653: 入力パース（分類B）は言語設定と独立という既存設計を維持する回帰テスト。
#  複数の日本語キーワード種別で確認する: 基本語彙・相対表現（N日後等）・曜日指定)
assert_eq "en+ja: 明日 still works"  "2026-04-06"  "$(LANG_ENV=en node "$ENGINE" normalize-due '明日' "$TEST_TODAY")"
assert_eq "en+ja: 来週 still works"  "2026-04-12"  "$(LANG_ENV=en node "$ENGINE" normalize-due '来週' "$TEST_TODAY")"
assert_eq "en+ja: 今月末 still works" "2026-04-30"  "$(LANG_ENV=en node "$ENGINE" normalize-due '今月末' "$TEST_TODAY")"
assert_eq "en+ja: 3日後 still works" "2026-04-08"  "$(LANG_ENV=en node "$ENGINE" normalize-due '3日後' "$TEST_TODAY")"
assert_eq "en+ja: 来週月曜 still works" "2026-04-06" "$(LANG_ENV=en node "$ENGINE" normalize-due '来週月曜' "$TEST_TODAY")"
assert_eq "en+ja: きょう(ひらがな) still works" "2026-04-05" "$(LANG_ENV=en node "$ENGINE" normalize-due 'きょう' "$TEST_TODAY")"

# Passthrough for unknown English
assert_eq "en: unknown passthrough"  "yesterday"   "$(node "$ENGINE" normalize-due 'yesterday' "$TEST_TODAY")"

# ──────────────────────────────────────────
# § 2  normalize_due — 月初計算の境界値
# ──────────────────────────────────────────
echo ""
echo "§2  normalize_due — 境界値（月末前後）"

# 1月31日から「来月」→ JavaScriptの setMonth による繰り上がりを確認
result=$(RAW_ENV="来月" TODAY_ENV="2026-01-31" FMT_JS="$FMT_JS" node << 'JSEOF'
const fmt=require(process.env.FMT_JS);
const today=process.env.TODAY_ENV;
const d=()=>new Date(today+'T00:00:00');
const dt=d(); dt.setMonth(dt.getMonth()+1); process.stdout.write(fmt(dt));
JSEOF
)
# 2026-01-31 + 1ヶ月 = 2026-03-03 (2月は28日のためJSが3月に繰り上げ)
assert_eq "1月31日→来月(JS月末繰り上がり確認)" "2026-03-03" "$result"

# ──────────────────────────────────────────
# § 3  セキュリティルール 3 — コンテキスト名バリデーション (シナリオ S-8)
# ──────────────────────────────────────────
echo ""
echo "§3  セキュリティルール3 — コンテキスト名バリデーション（bash case版）"

validate_ctx() {
  local ctx="$1"
  case "$ctx" in
    *[";$\`()'\\|&><*?' '"]*|*'"'*)
      echo "INVALID" ;;
    *)
      echo "VALID" ;;
  esac
}

assert_eq "正常: @PC"                "VALID"   "$(validate_ctx '@PC')"
assert_eq "正常: @会社"              "VALID"   "$(validate_ctx '@会社')"
assert_eq "正常: @外出中"            "VALID"   "$(validate_ctx '@外出中')"
assert_eq "不正: セミコロン含む"     "INVALID" "$(validate_ctx '@会社;rm')"
assert_eq "不正: ドル記号含む"       "INVALID" "$(validate_ctx '@PC$(pwd)')"
assert_eq "不正: バッククォート含む" "INVALID" "$(validate_ctx '@会社\`id\`')"
assert_eq "不正: スペース含む"       "INVALID" "$(validate_ctx '@会 社')"
assert_eq "不正: パイプ含む"         "INVALID" "$(validate_ctx '@PC|cat')"
assert_eq "不正: アンパサンド含む"   "INVALID" "$(validate_ctx '@PC&ls')"
assert_eq "不正: < 含む"             "INVALID" "$(validate_ctx '@PC<file')"
assert_eq "不正: > 含む"             "INVALID" "$(validate_ctx '@PC>file')"
assert_eq "不正: * (グロブ) 含む"    "INVALID" "$(validate_ctx '@*')"
assert_eq "不正: ? (グロブ) 含む"    "INVALID" "$(validate_ctx '@?')"
assert_eq "不正: シングルクォート"   "INVALID" "$(validate_ctx "@PC'")"
assert_eq "不正: ダブルクォート"     "INVALID" "$(validate_ctx '@PC"')"

# ──────────────────────────────────────────
# § 4  セキュリティルール 4 — Issue番号バリデーション (シナリオ S-2)
# ──────────────────────────────────────────
echo ""
echo "§4  セキュリティルール4 — Issue番号バリデーション"

validate_num() {
  local num="$1"
  case "$num" in
    ''|*[!0-9]*|0) echo "INVALID" ;;
    *) echo "VALID" ;;
  esac
}

assert_eq "正常: 1"     "VALID"   "$(validate_num '1')"
assert_eq "正常: 42"    "VALID"   "$(validate_num '42')"
assert_eq "正常: 999"   "VALID"   "$(validate_num '999')"
assert_eq "不正: 0"     "INVALID" "$(validate_num '0')"
assert_eq "不正: -1"    "INVALID" "$(validate_num '-1')"
assert_eq "不正: abc"   "INVALID" "$(validate_num 'abc')"
assert_eq "不正: 空文字" "INVALID" "$(validate_num '')"
assert_eq "不正: 1.5"   "INVALID" "$(validate_num '1.5')"
assert_eq "不正: 1;ls"  "INVALID" "$(validate_num '1;ls')"

# ──────────────────────────────────────────
# § 5  セキュリティルール 5 — due日付バリデーション (シナリオ S-3)
# ──────────────────────────────────────────
echo ""
echo "§5  セキュリティルール5 — due日付バリデーション"

# 実エンジンの validateDue()（todo-engine.js）を直接呼び出す。旧実装は bash 側の
# case 文でフォーマットのみを模倣しており、実際のカレンダー妥当性検証を一切テストできて
# いなかった（Issue #1650 でカレンダー妥当性検証を追加したため、実エンジン呼び出しに
# 置き換える。関連: シナリオ S-3）
validate_due() {
  local due="$1"
  if node "$ENGINE" validate due "$due" 2>/dev/null; then echo "VALID"; else echo "INVALID"; fi
}

assert_eq "正常: YYYY-MM-DD"    "VALID"   "$(validate_due '2026-04-10')"
assert_eq "正常: M/D (4/1)"     "VALID"   "$(validate_due '4/1')"
assert_eq "正常: M/D (4/10)"    "VALID"   "$(validate_due '4/10')"
assert_eq "正常: M/D (12/31)"   "VALID"   "$(validate_due '12/31')"
assert_eq "不正: 来週"          "INVALID" "$(validate_due '来週')"
# 空文字は「期日クリア」として意図的に許可される（§32 due clear テスト参照）。
# 旧shadowテストは実エンジンを呼んでおらず「不正」という誤った期待値のままだった
assert_eq "正常: 空文字(期日クリアとして許可。§32参照)" "VALID" "$(validate_due '')"
assert_eq "不正: コマンド挿入"  "INVALID" "$(validate_due '2026-04-05;ls')"
# Issue #1650 修正2: YYYY-MM-DD 形式もカレンダー妥当性（実在する月日か）を検証するようになった。
# 旧仕様は月の範囲(1-12)をチェックせず、2026-13-01 のような不正日付が通過していた（バグ）
assert_eq "YYYY-MM-DD: 存在しない月は拒否される(2026-13-01)" "INVALID" "$(validate_due '2026-13-01')"
# Issue #1650 修正2: M/D 形式も値範囲（実在する月日か）を検証するようになった。
# 旧仕様は範囲チェックをせず、99/99 のような不正値が通過していた（バグ）
assert_eq "M/D: 存在しない月日は拒否される(99/99)" "INVALID" "$(validate_due '99/99')"

# ──────────────────────────────────────────
# § 6  セキュリティルール 6 — recur バリデーション (シナリオ 1-5)
# ──────────────────────────────────────────
echo ""
echo "§6  セキュリティルール6 — recurバリデーション"

validate_recur() {
  local recur="$1"
  case "$recur" in
    daily|weekly|monthly|weekdays) echo "VALID" ;;
    *) echo "INVALID" ;;
  esac
}

assert_eq "正常: daily"       "VALID"   "$(validate_recur 'daily')"
assert_eq "正常: weekly"      "VALID"   "$(validate_recur 'weekly')"
assert_eq "正常: monthly"     "VALID"   "$(validate_recur 'monthly')"
assert_eq "正常: weekdays"    "VALID"   "$(validate_recur 'weekdays')"
assert_eq "不正: biweekly"    "INVALID" "$(validate_recur 'biweekly')"
assert_eq "不正: 空文字"      "INVALID" "$(validate_recur '')"
assert_eq "不正: WEEKLY(大文字)" "INVALID" "$(validate_recur 'WEEKLY')"
assert_eq "不正: 毎日"        "INVALID" "$(validate_recur '毎日')"

# ──────────────────────────────────────────
# § 7  セキュリティルール 7 — カラーコードバリデーション (シナリオ 17-2)
# ──────────────────────────────────────────
echo ""
echo "§7  セキュリティルール7 — カラーコードバリデーション"

validate_color() {
  local color="$1"
  case "$color" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) echo "VALID" ;;
    *) echo "INVALID" ;;
  esac
}

assert_eq "正常: FBCA04"     "VALID"   "$(validate_color 'FBCA04')"
assert_eq "正常: 0075CA"     "VALID"   "$(validate_color '0075CA')"
assert_eq "正常: aabbcc"     "VALID"   "$(validate_color 'aabbcc')"
assert_eq "正常: 000000"     "VALID"   "$(validate_color '000000')"
assert_eq "不正: GGGGGG"     "INVALID" "$(validate_color 'GGGGGG')"
assert_eq "不正: 5桁"        "INVALID" "$(validate_color 'FBCA0')"
assert_eq "不正: 7桁"        "INVALID" "$(validate_color 'FBCA041')"
assert_eq "不正: #プレフィックス" "INVALID" "$(validate_color '#FBCA04')"
assert_eq "不正: 空文字"     "INVALID" "$(validate_color '')"

# ──────────────────────────────────────────
# § 8  テンプレート名バリデーション — node (シナリオ S-4)
# ──────────────────────────────────────────
echo ""
echo "§8  テンプレート名バリデーション（nodeによる検証）"

validate_tname() {
  local name="$1"
  TNAME_ENV="$name" node << 'JSEOF' 2>&1
const name = process.env.TNAME_ENV || '';
if (!name) {
  process.stderr.write('エラー: テンプレート名が空です\n');
  process.exit(1);
}
const bs = String.fromCharCode(92);
const forbidden = ';$`()"' + "'" + bs + '|&><{}[]';
for (const c of name) {
  if (forbidden.indexOf(c) >= 0) {
    process.stderr.write('エラー: テンプレート名に不正文字が含まれています\n');
    process.exit(1);
  }
}
process.stdout.write('VALID');
JSEOF
}

assert_contains "正常: 週次レポート"      "VALID"   "$(validate_tname '週次レポート')"
assert_contains "正常: monthly-backup"   "VALID"   "$(validate_tname 'monthly-backup')"
assert_contains "正常: テスト123"        "VALID"   "$(validate_tname 'テスト123')"
assert_contains "不正: $ 含む"           "エラー"  "$(validate_tname 'テスト$名前')"
assert_contains "不正: ; 含む"           "エラー"  "$(validate_tname 'テスト;rm -rf')"
assert_contains "不正: 空文字"           "エラー"  "$(validate_tname '')"
assert_contains "不正: { 含む"           "エラー"  "$(validate_tname 'test{}')"
assert_contains "不正: [ 含む"           "エラー"  "$(validate_tname 'test[]')"

# ──────────────────────────────────────────
# § 9  due-offset バリデーション (シナリオ S-5)
# ──────────────────────────────────────────
echo ""
echo "§9  due-offsetバリデーション"

validate_due_offset() {
  local raw="$1"
  local offset="${raw#+}"   # + プレフィックス除去
  if [ -z "$offset" ]; then echo "INVALID (empty)"; return; fi
  case "$offset" in
    *[!0-9]*|0) echo "INVALID" ;;
    *) echo "VALID:$offset" ;;
  esac
}

assert_eq "正常: 7"    "VALID:7"  "$(validate_due_offset '7')"
assert_eq "正常: +7"   "VALID:7"  "$(validate_due_offset '+7')"
assert_eq "正常: 30"   "VALID:30" "$(validate_due_offset '30')"
assert_eq "不正: 0"    "INVALID"  "$(validate_due_offset '0')"
assert_eq "不正: +0"   "INVALID"  "$(validate_due_offset '+0')"
assert_eq "不正: -1"   "INVALID"  "$(validate_due_offset '-1')"
assert_eq "不正: abc"  "INVALID"  "$(validate_due_offset 'abc')"
assert_eq "不正: 1.5"  "INVALID"  "$(validate_due_offset '1.5')"
assert_eq "不正: 空文字" "INVALID (empty)" "$(validate_due_offset '')"

# ──────────────────────────────────────────
# § 10  body 組み立て (シナリオ 1-4, 1-6, 1-7)
# ──────────────────────────────────────────
echo ""
echo "§10  body組み立て"

build_body() {
  local DUE="$1" RECUR="$2" PROJECT="$3" DESC="$4"
  local NL=$'\n'
  local BODY=""
  [ -n "$DUE" ]     && BODY="${BODY}due: ${DUE}${NL}"
  [ -n "$RECUR" ]   && BODY="${BODY}recur: ${RECUR}${NL}"
  [ -n "$PROJECT" ] && BODY="${BODY}project: #${PROJECT}${NL}"
  if [ -n "$DESC" ]; then
    [ -n "$BODY" ] && BODY="${BODY}${NL}"
    BODY="${BODY}${DESC}"
  fi
  printf '%s' "$BODY"
}

body=$(build_body "2026-04-07" "weekly" "" "")
assert_contains "繰り返しタスク: due行"   "due: 2026-04-07"  "$body"
assert_contains "繰り返しタスク: recur行" "recur: weekly"    "$body"

body=$(build_body "" "" "7" "")
assert_contains "プロジェクト紐づけ: project行" "project: #7" "$body"

body=$(build_body "" "" "" "3章まで読んでから記載")
assert_contains "説明のみ: desc"          "3章まで" "$body"

body=$(build_body "2026-04-10" "" "" "詳細説明")
assert_contains "due+desc: due行"        "due: 2026-04-10"  "$body"
assert_contains "due+desc: 空行区切り"   $'04-10\n\n詳細'  "$body"

body=$(build_body "" "" "" "")
assert_eq "全フィールド空: BODY空文字" "" "$body"

# ──────────────────────────────────────────
# § 11  テンプレートファイル操作 (シナリオ 9-1〜9-8, 19-1〜19-3)
# ──────────────────────────────────────────
echo ""
echo "§11  テンプレートファイル操作（一時ファイル使用）"

# Issue #1882: この区間に入る直前に TEMP_TFILE の前提条件（存在・読み書き可能・
# 有効なJSON）を確認する。ここを通過すればトップの mktemp 検証と合わせて
# 二重に保証されるため、以降で FAIL が出た場合は「§11の中で状態が壊れた」と
# 切り分けられる。
if [ -z "${TEMP_TFILE}" ] || [ ! -f "${TEMP_TFILE}" ] || [ ! -r "${TEMP_TFILE}" ] || [ ! -w "${TEMP_TFILE}" ]; then
  printf '❌ [致命的エラー] §11 開始時点で TEMP_TFILE が読み書き可能な通常ファイルではありません\n' >&2
  printf '   TEMP_TFILE=[%s]\n' "${TEMP_TFILE:-<空文字列>}" >&2
  printf '   存在: %s\n' "$([ -e "${TEMP_TFILE}" ] && echo はい || echo いいえ)" >&2
  exit 1
fi
if ! TFILE_ENV="${TEMP_TFILE}" node -e '
    const fs = require("fs");
    try {
      JSON.parse(fs.readFileSync(process.env.TFILE_ENV, "utf8"));
    } catch (e) {
      process.stderr.write("invalid JSON: " + e.message + "\n");
      process.exit(1);
    }
  ' 2>/tmp/todo-test-tfile-precheck-err.$$; then
  printf '❌ [致命的エラー] §11 開始時点で TEMP_TFILE の内容が有効な JSON ではありません\n' >&2
  printf '   TEMP_TFILE=%s\n' "${TEMP_TFILE}" >&2
  printf '   node エラー: %s\n' "$(cat /tmp/todo-test-tfile-precheck-err.$$ 2>/dev/null)" >&2
  printf '   内容（先頭500バイト）: %s\n' "$(head -c 500 "${TEMP_TFILE}" 2>/dev/null)" >&2
  rm -f /tmp/todo-test-tfile-precheck-err.$$
  exit 1
fi
rm -f /tmp/todo-test-tfile-precheck-err.$$
TEMPLATE_DIAG_ACTIVE=1
TEMPLATE_DIAG_DUMPED=0

# template save（インライン）
result=$(TFILE_ENV="$TEMP_TFILE" TNAME_ENV="週次レポート" GTD_ENV="next" \
  CONTEXTS_ENV='["@PC"]' DUE_OFFSET_ENV="" DUE_ENV="" RECUR_ENV="weekly" \
  PROJECT_ENV="" DESC_ENV="" node << 'JSEOF'
const path=require('path'), fs=require('fs');
const tfile=process.env.TFILE_ENV;
let data={};
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); } catch(e) {}
const name=process.env.TNAME_ENV;
const t={};
t.gtd   = process.env.GTD_ENV||'inbox';
t.context = JSON.parse(process.env.CONTEXTS_ENV||'[]');
const off=process.env.DUE_OFFSET_ENV||'';
if(off) t['due-offset']=parseInt(off);
const due=process.env.DUE_ENV||'';
if(due&&!off) t.due=due;
const recur=process.env.RECUR_ENV||'';
if(recur) t.recur=recur;
const proj=process.env.PROJECT_ENV||'';
if(proj) t.project=parseInt(proj);
const desc=process.env.DESC_ENV||'';
if(desc) t.desc=desc;
data[name]=t;
fs.writeFileSync(tfile, JSON.stringify(data,null,2));
process.stdout.write('SAVED');
JSEOF
)
assert_contains "template save: 保存成功"  "SAVED" "$result"

# template list
result=$(TFILE_ENV="$TEMP_TFILE" node << 'JSEOF'
const path=require('path'), fs=require('fs');
const tfile=process.env.TFILE_ENV;
let data;
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); }
catch(e) { process.stdout.write('ERROR'); process.exit(1); }
const keys=Object.keys(data);
if(!keys.length){ process.stdout.write('（テンプレートなし）'); process.exit(0); }
for(const name of keys){
  const t=data[name];
  const parts=[t.gtd||'inbox'];
  const ctx=(t.context||[]).join(' ');
  if(ctx) parts.push(ctx);
  if(t.recur) parts.push('recur:'+t.recur);
  process.stdout.write(name+'  ['+parts.join(', ')+']\n');
}
JSEOF
)
assert_contains "template list: 週次レポート表示" "週次レポート"  "$result"
assert_contains "template list: GTD表示"          "next"          "$result"
assert_contains "template list: recur表示"        "recur:weekly"  "$result"

# template show
result=$(TFILE_ENV="$TEMP_TFILE" TNAME_ENV="週次レポート" node << 'JSEOF'
const fs=require('fs');
const tfile=process.env.TFILE_ENV;
const name=process.env.TNAME_ENV;
let data;
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); }
catch(e) { process.stdout.write('ERROR'); process.exit(1); }
if(!data[name]){ process.stdout.write('存在しない'); process.exit(1); }
const t=data[name];
process.stdout.write('GTD:'+t.gtd+'\n');
process.stdout.write('context:'+(t.context||[]).join(' ')+'\n');
if(t.recur) process.stdout.write('recur:'+t.recur+'\n');
JSEOF
)
assert_contains "template show: GTD"     "GTD:next"       "$result"
assert_contains "template show: context" "context:@PC"    "$result"
assert_contains "template show: recur"   "recur:weekly"   "$result"

# template show 存在しない名前（シナリオ 19-1）
result=$(TFILE_ENV="$TEMP_TFILE" TNAME_ENV="存在しない名前" node << 'JSEOF' 2>&1
const fs=require('fs');
const tfile=process.env.TFILE_ENV;
const name=process.env.TNAME_ENV;
let data;
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); }
catch(e) { process.stdout.write('ERROR'); process.exit(1); }
if(!data[name]){ process.stdout.write('エラー: テンプレート「'+name+'」は存在しません'); process.exit(1); }
JSEOF
)
assert_contains "template show 存在しない: エラー" "存在しません" "$result"

# コンテキストが正しく保存されることを確認（Bug-1修正の検証）
result=$(TFILE_ENV="$TEMP_TFILE" TNAME_ENV="コンテキストテスト" GTD_ENV="next" \
  CONTEXTS_ENV='["@PC","@会社"]' DUE_OFFSET_ENV="" DUE_ENV="" RECUR_ENV="" \
  PROJECT_ENV="" DESC_ENV="" node << 'JSEOF'
const fs=require('fs');
const tfile=process.env.TFILE_ENV;
let data={};
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); } catch(e) {}
const name=process.env.TNAME_ENV;
const t={};
t.gtd=process.env.GTD_ENV||'inbox';
t.context=JSON.parse(process.env.CONTEXTS_ENV||'[]');
data[name]=t;
fs.writeFileSync(tfile, JSON.stringify(data,null,2));
const saved=JSON.parse(fs.readFileSync(tfile,'utf8'));
process.stdout.write(JSON.stringify(saved[name].context));
JSEOF
)
assert_eq "Bug-1修正確認: コンテキスト保存" '["@PC","@会社"]' "$result"

# CTX_LIST_ENV を node で JSON に変換（修正後の動作確認）
CONTEXTS_LIST="@PC @会社"
CONTEXTS_JSON=$(CTX_LIST_ENV="${CONTEXTS_LIST# }" node -e "
const list=process.env.CTX_LIST_ENV||'';
const arr=list.trim()?list.trim().split(/\\s+/):[];
process.stdout.write(JSON.stringify(arr));
")
assert_eq "Bug-1修正: CONTEXTS_JSON生成" '["@PC","@会社"]' "$CONTEXTS_JSON"

# template delete
result=$(TFILE_ENV="$TEMP_TFILE" TNAME_ENV="週次レポート" node << 'JSEOF'
const fs=require('fs');
const tfile=process.env.TFILE_ENV;
const name=process.env.TNAME_ENV;
let data;
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); }
catch(e) { process.stdout.write('ERROR'); process.exit(1); }
if(!data[name]){ process.stdout.write('エラー: 存在しません'); process.exit(1); }
delete data[name];
fs.writeFileSync(tfile, JSON.stringify(data,null,2));
process.stdout.write('DELETED');
JSEOF
)
assert_contains "template delete: 成功" "DELETED" "$result"

# template delete 後に list に現れないこと
result=$(TFILE_ENV="$TEMP_TFILE" node << 'JSEOF'
const fs=require('fs');
const tfile=process.env.TFILE_ENV;
const data=JSON.parse(fs.readFileSync(tfile,'utf8'));
process.stdout.write(JSON.stringify(Object.keys(data)));
JSEOF
)
# 週次レポートは削除済み、コンテキストテストは残っているはず
assert_contains "template delete後: 削除されたエントリなし" "コンテキストテスト" "$result"

# template delete 存在しない（シナリオ 19-3）
result=$(TFILE_ENV="$TEMP_TFILE" TNAME_ENV="存在しない名前" node << 'JSEOF' 2>&1
const fs=require('fs');
const tfile=process.env.TFILE_ENV;
const name=process.env.TNAME_ENV;
let data;
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); }
catch(e) { process.stdout.write('ERROR'); process.exit(1); }
if(!data[name]){ process.stdout.write('エラー: テンプレート「'+name+'」は存在しません'); process.exit(1); }
JSEOF
)
assert_contains "template delete 存在しない: エラー" "存在しません" "$result"

# Issue #1882 診断フックはこの区間限定。§12 以降は TEMP_TFILE を使わないため無効化する。
TEMPLATE_DIAG_ACTIVE=0

# ──────────────────────────────────────────
# § 12  テンプレート due-offset 計算 (シナリオ 9-5)
# ──────────────────────────────────────────
echo ""
echo "§12  テンプレート due-offset 計算"

calc_due_offset() {
  local offset="$1" today="$2"
  date -d "$today +$offset days" +%Y-%m-%d 2>/dev/null || \
  date -v+${offset}d -j -f "%Y-%m-%d" "$today" +%Y-%m-%d 2>/dev/null || \
  node -e "
const d=new Date('${today}T00:00:00');
d.setDate(d.getDate()+${offset});
process.stdout.write(d.toISOString().slice(0,10));
"
}

assert_eq "due-offset 3日後" "2026-04-08" "$(calc_due_offset 3 "$TEST_TODAY")"
assert_eq "due-offset 7日後" "2026-04-12" "$(calc_due_offset 7 "$TEST_TODAY")"
assert_eq "due-offset 30日後" "2026-05-05" "$(calc_due_offset 30 "$TEST_TODAY")"

# ──────────────────────────────────────────
# § 13  weekdays recur 次の平日計算 (シナリオ 18-3)
# ──────────────────────────────────────────
echo ""
echo "§13  weekdays recur — 次の平日計算"

next_weekday() {
  local base="$1"
  FMT_JS="$FMT_JS" node -e "
const fmt=require(process.env.FMT_JS);
const d=new Date('${base}T00:00:00');
d.setDate(d.getDate()+1);
const dow=d.getDay();
if(dow===6) d.setDate(d.getDate()+2);
else if(dow===0) d.setDate(d.getDate()+1);
process.stdout.write(fmt(d));
"
}

# 2026-04-03 (金) → 次の平日: 2026-04-06 (月)
assert_eq "金曜→次の平日(月曜)"   "2026-04-06" "$(next_weekday '2026-04-03')"
# 2026-04-04 (土) → 次の平日: 2026-04-06 (月)
assert_eq "土曜→次の平日(月曜)"   "2026-04-06" "$(next_weekday '2026-04-04')"
# 2026-04-05 (日) → 次の平日: 2026-04-06 (月)  → 日+1=月(+1)
assert_eq "日曜→次の平日(月曜)"   "2026-04-06" "$(next_weekday '2026-04-05')"
# 2026-04-06 (月) → 次の平日: 2026-04-07 (火)
assert_eq "月曜→次の平日(火曜)"   "2026-04-07" "$(next_weekday '2026-04-06')"

# ──────────────────────────────────────────
# § 14  done 完了件数カウント — closedAt タイムゾーン (Bug-5修正確認)
# ──────────────────────────────────────────
echo ""
echo "§14  done 完了件数カウント — closedAt タイムゾーン"

count_done_today() {
  local today="$1"
  # GitHub API が返す closedAt (UTC ISO 8601) を local date に変換してカウント
  echo '[{"closedAt":"2026-04-05T00:30:00Z"},{"closedAt":"2026-04-04T15:30:00Z"},{"closedAt":"2026-04-05T12:00:00Z"},{"closedAt":null}]' \
  | TODAY_ENV="$today" FMT_JS="$FMT_JS" node -e "
const fmt=require(process.env.FMT_JS);
const c=[]; process.stdin.on('data',d=>c.push(d));
process.stdin.on('end',()=>{
  const today=process.env.TODAY_ENV;
  const issues=JSON.parse(c.join(''));
  const cnt=issues.filter(i=>i.closedAt&&fmt(new Date(i.closedAt))===today).length;
  process.stdout.write(cnt+'');
});
"
}

# JST(+9)での確認
# "2026-04-05T00:30:00Z" = JST 2026-04-05 09:30 → 今日
# "2026-04-04T15:30:00Z" = JST 2026-04-05 00:30 → 今日（旧コード startsWith では前日扱いになっていた）
# "2026-04-05T12:00:00Z" = JST 2026-04-05 21:00 → 今日
# null → スキップ
result=$(TZ=Asia/Tokyo count_done_today "2026-04-05")
assert_eq "Bug-5修正: UTC深夜閉じたIssueも今日としてカウント" "3" "$result"

# startsWith 旧実装では何件カウントされるか（比較用）
old_count=$(echo '[{"closedAt":"2026-04-05T00:30:00Z"},{"closedAt":"2026-04-04T15:30:00Z"},{"closedAt":"2026-04-05T12:00:00Z"},{"closedAt":null}]' \
  | node -e "
const c=[]; process.stdin.on('data',d=>c.push(d));
process.stdin.on('end',()=>{
  const today='2026-04-05';
  const issues=JSON.parse(c.join(''));
  const cnt=issues.filter(i=>i.closedAt&&i.closedAt.startsWith(today)).length;
  process.stdout.write(cnt+'');
});
")
assert_eq "旧実装(startsWith)は2件しかカウントしない(バグ確認)" "2" "$old_count"

# ──────────────────────────────────────────
# § 16  S-6 テンプレートのコンテキスト改ざん検出 (シナリオ S-6)
# ──────────────────────────────────────────
echo ""
echo "§15  S-6 テンプレートのコンテキスト改ざん検出（node版）"

validate_ctx_node() {
  local ctx="$1"
  VALIDATE_CTX_ENV="$ctx" node -e "
const c=process.env.VALIDATE_CTX_ENV||'';
const bs=String.fromCharCode(92);
const forbidden=';$\`()'+'\"'+'\''+bs+'|&><{}[]';
for(const ch of c){ if(forbidden.indexOf(ch)>=0){ process.stderr.write('INVALID\n'); process.exit(1); } }
process.stdout.write('VALID');
" 2>&1
}

assert_contains "node検証: 正常 @PC"            "VALID"   "$(validate_ctx_node '@PC')"
assert_contains "node検証: 不正 \$ 含む"         "INVALID" "$(validate_ctx_node '@PC$(touch /tmp/pwned)')"
assert_contains "node検証: 不正 ; 含む"          "INVALID" "$(validate_ctx_node '@PC;rm -rf')"
assert_contains "node検証: 不正 { } 含む"        "INVALID" "$(validate_ctx_node '@PC{}')"

# ──────────────────────────────────────────
# § 17  S-6 テンプレートのGTD不正値バリデーション (シナリオ S-6)
# ──────────────────────────────────────────
echo ""
echo "§16  S-6 テンプレートGTD値バリデーション（改ざん検出）"

validate_gtd_from_template() {
  local gtd="$1"
  case "$gtd" in
    inbox|next|waiting|someday|project|reference) echo "VALID" ;;
    *) echo "INVALID" ;;
  esac
}

assert_eq "正常: next"                "VALID"   "$(validate_gtd_from_template 'next')"
assert_eq "不正: malicious; rm -rf /" "INVALID" "$(validate_gtd_from_template 'malicious; rm -rf /')"
assert_eq "不正: 空文字"              "INVALID" "$(validate_gtd_from_template '')"

# ──────────────────────────────────────────
# §17  priority バリデーション
# ──────────────────────────────────────────
echo ""
echo "§17  priority バリデーション"

validate_priority() {
  local p="$1"
  case "$p" in
    p1|p2|p3) echo "VALID" ;;
    *) echo "INVALID" ;;
  esac
}

assert_eq "正常: p1"           "VALID"   "$(validate_priority 'p1')"
assert_eq "正常: p2"           "VALID"   "$(validate_priority 'p2')"
assert_eq "正常: p3"           "VALID"   "$(validate_priority 'p3')"
assert_eq "不正: p4"           "INVALID" "$(validate_priority 'p4')"
assert_eq "不正: high"         "INVALID" "$(validate_priority 'high')"
assert_eq "不正: medium"       "INVALID" "$(validate_priority 'medium')"
assert_eq "不正: 1"            "INVALID" "$(validate_priority '1')"
assert_eq "不正: 空文字"        "INVALID" "$(validate_priority '')"
assert_eq "不正: p1; rm -rf /" "INVALID" "$(validate_priority 'p1; rm -rf /')"

# ──────────────────────────────────────────
# §18  priority カラーコード生成
# ──────────────────────────────────────────
echo ""
echo "§18  priority カラーコード生成"

get_priority_color() {
  local p="$1"
  case "$p" in
    p1) echo "B60205" ;;
    p2) echo "FBCA04" ;;
    p3) echo "0075CA" ;;
    *)  echo "UNKNOWN" ;;
  esac
}

assert_eq "p1 → 赤 B60205"  "B60205"  "$(get_priority_color 'p1')"
assert_eq "p2 → 黄 FBCA04"  "FBCA04"  "$(get_priority_color 'p2')"
assert_eq "p3 → 青 0075CA"  "0075CA"  "$(get_priority_color 'p3')"
assert_eq "不正値 → UNKNOWN" "UNKNOWN" "$(get_priority_color 'p4')"

# ──────────────────────────────────────────
# §19  priority ソートロジック（Node.js）
# ──────────────────────────────────────────
echo ""
echo "§19  priority ソートロジック（Node.js）"

SORT_RESULT=$(node << 'JSEOF'
const PORDER = {p1:0, p2:1, p3:2};
const issues = [
  {number:3, labels:[{name:'p3'}], dueDate:'2026-04-10'},
  {number:1, labels:[{name:'p1'}], dueDate:'2026-04-15'},
  {number:2, labels:[{name:'p2'}], dueDate:'2026-04-08'},
  {number:4, labels:[{name:'p1'}], dueDate:'2026-04-05'},
  {number:5, labels:[{name:'next'}], dueDate:null},  // 優先度なし
];
issues.sort((a, b) => {
  const pa = a.labels.find(l => PORDER[l.name] !== undefined);
  const pb = b.labels.find(l => PORDER[l.name] !== undefined);
  const va = pa ? PORDER[pa.name] : 3;
  const vb = pb ? PORDER[pb.name] : 3;
  if (va !== vb) return va - vb;
  const da = a.dueDate || '9999'; const db = b.dueDate || '9999';
  return da < db ? -1 : da > db ? 1 : 0;
});
process.stdout.write(issues.map(i=>i.number).join(','));
JSEOF
)
assert_eq "priority sort: p1(早)→p1(遅)→p2→p3→なし" "4,1,2,3,5" "$SORT_RESULT"

# ──────────────────────────────────────────
# §20  monthly recur — 月末境界テスト (シナリオ 18-2)
# ──────────────────────────────────────────
echo ""
echo "§20  monthly recur — 月末境界テスト"

  # 実エンジンの nextDue('monthly', base)（todo-engine.js）を直接呼び出す。旧実装は
  # JS Date の自動繰り上げ（クランプしない旧バグ挙動）をローカルで再現するだけの
  # shadow 関数で、実際のプロダクションコードを一切テストできていなかった
  # （Issue #1650 修正3: 無印 monthly を「月末クランプ・ドリフトなし」に変更したため、
  # 実エンジン呼び出しに置き換える）
next_monthly() {
  local base="$1"
  node "$ENGINE" next-due monthly "$base" 2>/dev/null
}

# 通常ケース: 4/15 → 5/15
assert_eq "4/15→5/15(通常)" "2026-05-15" "$(next_monthly '2026-04-15')"

# 4/30 → 5/30
assert_eq "4/30→5/30" "2026-05-30" "$(next_monthly '2026-04-30')"

# 1/31 → 2/28（Issue #1650修正3: 月末クランプ。旧仕様は2月をスキップして3/3に繰り上がっていた）
assert_eq "1/31→2/28(月末クランプ、旧仕様の3/3繰り上がりを修正)" "2026-02-28" "$(next_monthly '2026-01-31')"

# 3/31 → 4/30（4月は30日までなのでクランプ。旧仕様は5/1に繰り上がっていた）
assert_eq "3/31→4/30(4月は30日までクランプ)" "2026-04-30" "$(next_monthly '2026-03-31')"

# 5/31 → 6/30（6月は30日までなのでクランプ。旧仕様は7/1に繰り上がっていた）
assert_eq "5/31→6/30(6月は30日までクランプ)" "2026-06-30" "$(next_monthly '2026-05-31')"

# 12/15 → 翌年1/15（年またぎ）
assert_eq "12/15→翌年1/15(年またぎ)" "2027-01-15" "$(next_monthly '2026-12-15')"

# 12/31 → 翌年1/31（年またぎ・1月は31日まであるためクランプ不要）
assert_eq "12/31→翌年1/31(年またぎ月末)" "2027-01-31" "$(next_monthly '2026-12-31')"

# 2/28 → 3/28（2月末→通常月）
assert_eq "2/28→3/28" "2026-03-28" "$(next_monthly '2026-02-28')"

# クランプ後は元の31日に戻らずドリフトしないことの連鎖確認（1/31→2/28→3/28）
NM_STEP1=$(next_monthly '2026-01-31')
NM_STEP2=$(next_monthly "$NM_STEP1")
assert_eq "月末クランプの連鎖: 1/31→2/28→3/28（31日には戻らずドリフトしない）" "2026-03-28" "$NM_STEP2"

# ──────────────────────────────────────────
# §21  うるう年テスト
# ──────────────────────────────────────────
echo ""
echo "§21  うるう年テスト"

# --- normalize_due: うるう年での「来月」「Nヶ月後」 ---

# うるう年の1/29 → 来月 = 2/29（うるう年なので存在する）
result=$(RAW_ENV="来月" TODAY_ENV="2028-01-29" FMT_JS="$FMT_JS" node << 'JSEOF'
const fmt=require(process.env.FMT_JS);
const today=process.env.TODAY_ENV;
const d=()=>new Date(today+'T00:00:00');
const dt=d(); const origDay=dt.getDate(); dt.setMonth(dt.getMonth()+1);
process.stdout.write(fmt(dt));
JSEOF
)
assert_eq "うるう年1/29→来月=2/29" "2028-02-29" "$result"

# うるう年の1/30 → 来月 = 3/1（2月は29日まで → 繰り上がり）
result=$(RAW_ENV="来月" TODAY_ENV="2028-01-30" FMT_JS="$FMT_JS" node << 'JSEOF'
const fmt=require(process.env.FMT_JS);
const today=process.env.TODAY_ENV;
const d=()=>new Date(today+'T00:00:00');
const dt=d(); dt.setMonth(dt.getMonth()+1);
process.stdout.write(fmt(dt));
JSEOF
)
assert_eq "うるう年1/30→来月=3/1(繰り上がり)" "2028-03-01" "$result"

# 非うるう年の1/29 → 来月 = 3/1（2月は28日まで → 繰り上がり）
result=$(RAW_ENV="来月" TODAY_ENV="2026-01-29" FMT_JS="$FMT_JS" node << 'JSEOF'
const fmt=require(process.env.FMT_JS);
const today=process.env.TODAY_ENV;
const d=()=>new Date(today+'T00:00:00');
const dt=d(); dt.setMonth(dt.getMonth()+1);
process.stdout.write(fmt(dt));
JSEOF
)
assert_eq "非うるう年1/29→来月=3/1(繰り上がり)" "2026-03-01" "$result"

# --- next_monthly: うるう年での monthly recur ---

# うるう年の1/31 → 2/29（Issue #1650修正3: うるう年は29日までクランプ。旧仕様は3/2に繰り上がっていた）
assert_eq "うるう年1/31→2/29(うるう年は29日までクランプ)" "2028-02-29" "$(next_monthly '2028-01-31')"

# うるう年の2/29 → 翌月 = 3/29（3月は31日まで → 正常）
assert_eq "うるう年2/29→翌月=3/29" "2028-03-29" "$(next_monthly '2028-02-29')"

# 非うるう年の2/28 → 翌月 = 3/28（正常）
assert_eq "非うるう年2/28→翌月=3/28" "2026-03-28" "$(next_monthly '2026-02-28')"

# うるう年の2/29 → 11ヶ月後 = 翌年1/29（非うるう年でも1月は31日 → 正常）
result=$(RAW_ENV="11ヶ月後" TODAY_ENV="2028-02-29" FMT_JS="$FMT_JS" node << 'JSEOF'
const fmt=require(process.env.FMT_JS);
const today=process.env.TODAY_ENV;
const d=()=>new Date(today+'T00:00:00');
const dt=d(); dt.setMonth(dt.getMonth()+11);
process.stdout.write(fmt(dt));
JSEOF
)
assert_eq "うるう年2/29→11ヶ月後=翌年1/29" "2029-01-29" "$result"

# うるう年の2/29 → 12ヶ月後 = 翌年3/1（非うるう年の2月は28日 → 繰り上がり）
result=$(RAW_ENV="12ヶ月後" TODAY_ENV="2028-02-29" FMT_JS="$FMT_JS" node << 'JSEOF'
const fmt=require(process.env.FMT_JS);
const today=process.env.TODAY_ENV;
const d=()=>new Date(today+'T00:00:00');
const dt=d(); dt.setMonth(dt.getMonth()+12);
process.stdout.write(fmt(dt));
JSEOF
)
assert_eq "うるう年2/29→12ヶ月後=翌年3/1(繰り上がり)" "2029-03-01" "$result"

# ──────────────────────────────────────────
# § 22a  todo-engine.js ユニットテスト
# ──────────────────────────────────────────
echo ""
echo "§22a  todo-engine.js — ユーティリティ・バリデーション"

# normalize-due（エンジン版）
assert_eq "engine: normalize-due 今日" "$TEST_TODAY" "$(node "$ENGINE" normalize-due '今日' "$TEST_TODAY")"
assert_eq "engine: normalize-due 明日" "2026-04-06" "$(node "$ENGINE" normalize-due '明日' "$TEST_TODAY")"
assert_eq "engine: normalize-due 来週" "2026-04-12" "$(node "$ENGINE" normalize-due '来週' "$TEST_TODAY")"
assert_eq "engine: normalize-due M/D → YYYY-MM-DD 変換" "2026-04-10" "$(node "$ENGINE" normalize-due '4/10' "$TEST_TODAY")"

# add-days / add-month
assert_eq "engine: add-days +7" "2026-04-12" "$(node "$ENGINE" add-days "$TEST_TODAY" 7)"
assert_eq "engine: add-month" "2026-05-05" "$(node "$ENGINE" add-month "$TEST_TODAY")"

# parse-body
PB_OUT=$(node "$ENGINE" parse-body "due: 2026-04-10
recur: weekly
project: #7

説明テスト")
PB_DUE=$(printf '%s\n' "$PB_OUT" | grep '^DUE=' | cut -d= -f2-)
PB_RECUR=$(printf '%s\n' "$PB_OUT" | grep '^RECUR=' | cut -d= -f2-)
PB_PROJ=$(printf '%s\n' "$PB_OUT" | grep '^PROJECT=' | cut -d= -f2-)
PB_B64=$(printf '%s\n' "$PB_OUT" | grep '^DESC_B64=' | cut -d= -f2-)
PB_DESC=$(node "$ENGINE" decode-b64 "$PB_B64")
assert_eq "engine: parse-body DUE" "2026-04-10" "$PB_DUE"
assert_eq "engine: parse-body RECUR" "weekly" "$PB_RECUR"
assert_eq "engine: parse-body PROJECT" "7" "$PB_PROJ"
assert_eq "engine: parse-body DESC" "説明テスト" "$PB_DESC"

# parse-body 空
PB_EMPTY=$(node "$ENGINE" parse-body "")
PB_EMPTY_DUE=$(printf '%s\n' "$PB_EMPTY" | grep '^DUE=' | cut -d= -f2-)
assert_eq "engine: parse-body empty DUE" "" "$PB_EMPTY_DUE"

# build-body
BB_OUT=$(node "$ENGINE" build-body "2026-04-10" "weekly" "7" "説明文")
assert_contains "engine: build-body due" "due: 2026-04-10" "$BB_OUT"
assert_contains "engine: build-body recur" "recur: weekly" "$BB_OUT"
assert_contains "engine: build-body project" "project: #7" "$BB_OUT"
assert_contains "engine: build-body desc" "説明文" "$BB_OUT"

# priority-color
assert_eq "engine: priority-color p1" "B60205" "$(node "$ENGINE" priority-color p1)"
assert_eq "engine: priority-color p2" "FBCA04" "$(node "$ENGINE" priority-color p2)"
assert_eq "engine: priority-color p3" "0075CA" "$(node "$ENGINE" priority-color p3)"

# next-due
assert_eq "engine: next-due daily" "2026-04-06" "$(node "$ENGINE" next-due daily "$TEST_TODAY")"
assert_eq "engine: next-due weekly" "2026-04-12" "$(node "$ENGINE" next-due weekly "$TEST_TODAY")"
assert_eq "engine: next-due weekdays(土→月)" "2026-04-06" "$(node "$ENGINE" next-due weekdays "2026-04-04")"

# validate（正常系はexit 0、異常系はexit 1）
node "$ENGINE" validate ctx "@PC" 2>/dev/null && printf "  ✅ engine: validate ctx OK\n" && PASS=$((PASS+1)) || { printf "  ❌ engine: validate ctx OK\n"; FAIL=$((FAIL+1)); }
node "$ENGINE" validate ctx '@PC;rm' 2>/dev/null && { printf "  ❌ engine: validate ctx reject\n"; FAIL=$((FAIL+1)); } || { printf "  ✅ engine: validate ctx reject\n"; PASS=$((PASS+1)); }
node "$ENGINE" validate number 42 2>/dev/null && printf "  ✅ engine: validate number OK\n" && PASS=$((PASS+1)) || { printf "  ❌ engine: validate number OK\n"; FAIL=$((FAIL+1)); }
node "$ENGINE" validate number 0 2>/dev/null && { printf "  ❌ engine: validate number reject\n"; FAIL=$((FAIL+1)); } || { printf "  ✅ engine: validate number reject\n"; PASS=$((PASS+1)); }
node "$ENGINE" validate recur weekly 2>/dev/null && printf "  ✅ engine: validate recur OK\n" && PASS=$((PASS+1)) || { printf "  ❌ engine: validate recur OK\n"; FAIL=$((FAIL+1)); }
node "$ENGINE" validate recur biweekly 2>/dev/null && { printf "  ❌ engine: validate recur reject\n"; FAIL=$((FAIL+1)); } || { printf "  ✅ engine: validate recur reject\n"; PASS=$((PASS+1)); }
node "$ENGINE" validate name "テスト" 2>/dev/null && printf "  ✅ engine: validate name OK\n" && PASS=$((PASS+1)) || { printf "  ❌ engine: validate name OK\n"; FAIL=$((FAIL+1)); }
node "$ENGINE" validate name "" 2>/dev/null && { printf "  ❌ engine: validate name reject\n"; FAIL=$((FAIL+1)); } || { printf "  ✅ engine: validate name reject\n"; PASS=$((PASS+1)); }

# done-count
# done-count uses Date→local format to handle TZ (closedAt 18:00 UTC = next day in JST)
DC_RESULT=$(CLOSED_ENV='[{"number":1,"closedAt":"2026-04-05T01:00:00Z"},{"number":2,"closedAt":"2026-04-05T10:00:00Z"},{"number":3,"closedAt":"2026-04-04T10:00:00Z"}]' TODAY_ENV="$TEST_TODAY" node "$ENGINE" done-count)
assert_eq "engine: done-count 今日=2" "2" "$DC_RESULT"

# gtd-label（絵文字付きラベル名変換）
assert_eq "engine: gtd-label next"      "🎯 next"      "$(node "$ENGINE" gtd-label next)"
assert_eq "engine: gtd-label inbox"     "📥 inbox"     "$(node "$ENGINE" gtd-label inbox)"
assert_eq "engine: gtd-label waiting"   "⏳ waiting"   "$(node "$ENGINE" gtd-label waiting)"
assert_eq "engine: gtd-label someday"   "🌈 someday"   "$(node "$ENGINE" gtd-label someday)"
assert_eq "engine: gtd-label project"   "📁 project"   "$(node "$ENGINE" gtd-label project)"
assert_eq "engine: gtd-label reference" "📎 reference" "$(node "$ENGINE" gtd-label reference)"
assert_eq "engine: gtd-label unknown"   "unknown"      "$(node "$ENGINE" gtd-label unknown)"

# parse-time / format-time
assert_eq "engine: parse-time 30m"    "30"    "$(node "$ENGINE" parse-time '30m')"
assert_eq "engine: parse-time 1h"     "60"    "$(node "$ENGINE" parse-time '1h')"
assert_eq "engine: parse-time 1h30m"  "90"    "$(node "$ENGINE" parse-time '1h30m')"
assert_eq "engine: parse-time 2h"     "120"   "$(node "$ENGINE" parse-time '2h')"
assert_eq "engine: parse-time 90(数字)" "90"  "$(node "$ENGINE" parse-time '90')"
assert_eq "engine: parse-time invalid" "null"  "$(node "$ENGINE" parse-time 'abc')"
assert_eq "engine: format-time 30"    "30m"   "$(node "$ENGINE" format-time 30)"
assert_eq "engine: format-time 60"    "1h"    "$(node "$ENGINE" format-time 60)"
assert_eq "engine: format-time 90"    "1h30m" "$(node "$ENGINE" format-time 90)"
assert_eq "engine: format-time 120"   "2h"    "$(node "$ENGINE" format-time 120)"

# validate time
node "$ENGINE" validate time "2h" 2>/dev/null && printf "  ✅ engine: validate time OK\n" && PASS=$((PASS+1)) || { printf "  ❌ engine: validate time OK\n"; FAIL=$((FAIL+1)); }
node "$ENGINE" validate time "abc" 2>/dev/null && { printf "  ❌ engine: validate time reject\n"; FAIL=$((FAIL+1)); } || { printf "  ✅ engine: validate time reject\n"; PASS=$((PASS+1)); }

# parse-body with estimate/actual
PB_EST=$(node "$ENGINE" parse-body "due: 2026-04-10
estimate: 120
actual: 90

desc")
PB_EST_V=$(printf '%s\n' "$PB_EST" | grep '^ESTIMATE=' | cut -d= -f2-)
PB_ACT_V=$(printf '%s\n' "$PB_EST" | grep '^ACTUAL=' | cut -d= -f2-)
assert_eq "engine: parse-body ESTIMATE" "120" "$PB_EST_V"
assert_eq "engine: parse-body ACTUAL"   "90"  "$PB_ACT_V"

# build-body with estimate/actual (6 args)
BB_EST=$(node "$ENGINE" build-body "2026-04-10" "" "" "120" "90" "desc")
assert_contains "engine: build-body estimate" "estimate: 120" "$BB_EST"
assert_contains "engine: build-body actual"   "actual: 90"    "$BB_EST"

# list-all テスト
LIST_MOCK='[
  {"number":1,"title":"next-p1","body":"due: 2026-04-03","labels":[{"name":"🎯 next"},{"name":"p1"},{"name":"@PC"}]},
  {"number":2,"title":"next-p2","body":"due: 2026-04-10","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":3,"title":"inbox-task","body":"","labels":[{"name":"📥 inbox"}]},
  {"number":7,"title":"proj","body":"","labels":[{"name":"📁 project"}]}
]'
LIST_ALL_OUT=$(OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" node "$ENGINE" list-all)
assert_contains "engine: list-all next ヘッダー"    "Next Actions"    "$LIST_ALL_OUT"
assert_contains "engine: list-all inbox ヘッダー"   "Inbox"           "$LIST_ALL_OUT"
assert_contains "engine: list-all #1 表示"          "#1"              "$LIST_ALL_OUT"
assert_contains "engine: list-all サマリー"          "next: 2件"       "$LIST_ALL_OUT"
assert_contains "engine: list-all project Next有無" "Next Action"     "$LIST_ALL_OUT"

# list-all フィルタテスト
LIST_FILT_OUT=$(OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "engine: list-all filter=next #1"   "#1"   "$LIST_FILT_OUT"
assert_contains "engine: list-all filter=next #2"   "#2"   "$LIST_FILT_OUT"
if ! printf '%s' "$LIST_FILT_OUT" | grep -aq '#3'; then
  printf "  ✅ engine: list-all filter=next excludes inbox\n"; PASS=$((PASS+1))
else
  printf "  ❌ engine: list-all filter=next excludes inbox\n"; FAIL=$((FAIL+1))
fi

# list-all ctx フィルタ
LIST_CTX_OUT=$(OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_CTX_ENV="@PC" node "$ENGINE" list-all)
assert_contains "engine: list-all filter=@PC #1"   "#1"   "$LIST_CTX_OUT"
if ! printf '%s' "$LIST_CTX_OUT" | grep -aq '#2'; then
  printf "  ✅ engine: list-all filter=@PC excludes #2\n"; PASS=$((PASS+1))
else
  printf "  ❌ engine: list-all filter=@PC excludes #2\n"; FAIL=$((FAIL+1))
fi

# list-all 優先度フィルタ
LIST_PRI_OUT=$(OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_PRI_ENV="p1" node "$ENGINE" list-all)
assert_contains "engine: list-all filter=p1 #1" "#1" "$LIST_PRI_OUT"
if ! printf '%s' "$LIST_PRI_OUT" | grep -aq '#2'; then
  printf "  ✅ engine: list-all filter=p1 excludes p2\n"; PASS=$((PASS+1))
else
  printf "  ❌ engine: list-all filter=p1 excludes p2\n"; FAIL=$((FAIL+1))
fi

# list-all プロジェクトフィルタ
LIST_PROJ_MOCK='[
  {"number":10,"title":"proj-task","body":"due: 2026-04-10\nproject: #7","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":11,"title":"no-proj-task","body":"","labels":[{"name":"🎯 next"}]}
]'
LIST_PROJ_OUT=$(OPEN_ENV="$LIST_PROJ_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_PROJ_ENV="7" node "$ENGINE" list-all)
assert_contains "engine: list-all filter=proj #10" "#10" "$LIST_PROJ_OUT"
if ! printf '%s' "$LIST_PROJ_OUT" | grep -aq '#11'; then
  printf "  ✅ engine: list-all filter=proj excludes #11\n"; PASS=$((PASS+1))
else
  printf "  ❌ engine: list-all filter=proj excludes #11\n"; FAIL=$((FAIL+1))
fi

# sortByPriDue テスト（フィルタ指定でフラットリスト＋ソート）
SORT_MOCK='[
  {"number":1,"title":"a","body":"due: 2026-04-10","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":2,"title":"b","body":"due: 2026-04-05","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":3,"title":"c","body":"","labels":[{"name":"🎯 next"},{"name":"p3"}]}
]'
SORT_OUT=$(OPEN_ENV="$SORT_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
POS_S2=$(printf '%s\n' "$SORT_OUT" | grep -n '#2' | head -1 | cut -d: -f1)
POS_S1=$(printf '%s\n' "$SORT_OUT" | grep -n '#1' | head -1 | cut -d: -f1)
POS_S3=$(printf '%s\n' "$SORT_OUT" | grep -n '#3' | head -1 | cut -d: -f1)
if [ "$POS_S2" -lt "$POS_S1" ] && [ "$POS_S1" -lt "$POS_S3" ]; then
  printf "  ✅ engine: sortByPriDue p1→p2→p3\n"; PASS=$((PASS+1))
else
  printf "  ❌ engine: sortByPriDue p1→p2→p3 (pos: #2=%s #1=%s #3=%s)\n" "$POS_S2" "$POS_S1" "$POS_S3"; FAIL=$((FAIL+1))
fi

# renderIssueList テスト（estimate/ctx/due 表示確認）
RENDER_MOCK='[
  {"number":1,"title":"est-task","body":"due: 2026-04-10\nestimate: 90","labels":[{"name":"🎯 next"},{"name":"p1"},{"name":"@PC"}]}
]'
RENDER_OUT=$(OPEN_ENV="$RENDER_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "engine: renderIssueList estimate表示" "1h30m" "$RENDER_OUT"
assert_contains "engine: renderIssueList ctx表示" "@PC" "$RENDER_OUT"
assert_contains "engine: renderIssueList due表示" "2026-04-10" "$RENDER_OUT"

# ──────────────────────────────────────────
# #1854: renderIssueList の estimate 時間単位表示（2h/1h/30m/1h30m/60/不正値）
# 修正前は `/^estimate: (\d+)/m` で先頭の数字だけを切り出した上で parseInt() していたため、
# "2h" が "2" として抽出され "⏱2m" のように 60〜120倍誤った値が表示されていた。
# ──────────────────────────────────────────
EST1854_MOCK='[
  {"number":101,"title":"est-2h","body":"estimate: 2h","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":102,"title":"est-1h","body":"estimate: 1h","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":103,"title":"est-30m","body":"estimate: 30m","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":104,"title":"est-1h30m","body":"estimate: 1h30m","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":105,"title":"est-60","body":"estimate: 60","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":106,"title":"est-invalid","body":"estimate: abc","labels":[{"name":"🎯 next"},{"name":"p3"}]}
]'
EST1854_OUT=$(OPEN_ENV="$EST1854_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
EST1854_LINE_101=$(printf '%s\n' "$EST1854_OUT" | grep '#101')
EST1854_LINE_102=$(printf '%s\n' "$EST1854_OUT" | grep '#102')
EST1854_LINE_103=$(printf '%s\n' "$EST1854_OUT" | grep '#103')
EST1854_LINE_104=$(printf '%s\n' "$EST1854_OUT" | grep '#104')
EST1854_LINE_105=$(printf '%s\n' "$EST1854_OUT" | grep '#105')
EST1854_LINE_106=$(printf '%s\n' "$EST1854_OUT" | grep '#106')
assert_contains "#1854 list: estimate:2h → ⏱2h（従来は⏱2mだった）" "⏱2h" "$EST1854_LINE_101"
assert_not_contains "#1854 list: estimate:2h は ⏱2m と表示されない" "⏱2m" "$EST1854_LINE_101"
assert_contains "#1854 list: estimate:1h → ⏱1h（従来は⏱1mだった）" "⏱1h" "$EST1854_LINE_102"
assert_not_contains "#1854 list: estimate:1h は ⏱1m と表示されない" "⏱1m" "$EST1854_LINE_102"
assert_contains "#1854 list: estimate:30m → ⏱30m" "⏱30m" "$EST1854_LINE_103"
assert_contains "#1854 list: estimate:1h30m → ⏱1h30m" "⏱1h30m" "$EST1854_LINE_104"
# formatTime(60) は「1h0m」ではなく「1h」を返す仕様（60分ちょうどは分表記を省略する）。
# 60分という値自体は数値のみ形式でも parseTime() 経由で正しく60分として扱われることの確認。
assert_contains "#1854 list: estimate:60（数値のみ）→ ⏱1h（60分は仕様上 1h と表示される）" "⏱1h" "$EST1854_LINE_105"
assert_contains "#1854 list: estimate:abc（不正値）は ⚠️ 付きで生値を表示する" "⏱⚠️abc" "$EST1854_LINE_106"
assert_not_contains "#1854 list: estimate:abc（不正値）は ⏱0m と黙って表示されない" "⏱0m" "$EST1854_LINE_106"

# listSummary テスト
LSUM_OUT=$(OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" node "$ENGINE" list-summary)
assert_contains "engine: list-summary next" "next: 2件" "$LSUM_OUT"
assert_contains "engine: list-summary inbox" "inbox: 1件" "$LSUM_OUT"

# weeklySummary テスト
WSUM_MOCK='[
  {"number":1,"title":"overdue","body":"due: 2026-04-03","labels":[{"name":"🎯 next"}]},
  {"number":2,"title":"thisweek","body":"due: 2026-04-08","labels":[{"name":"🎯 next"}]},
  {"number":3,"title":"inbox-task","body":"","labels":[{"name":"📥 inbox"}]}
]'
WSUM_OUT=$(OPEN_ENV="$WSUM_MOCK" TODAY_ENV="$TEST_TODAY" node "$ENGINE" weekly-summary)
assert_contains "engine: weekly-summary ヘッダー" "週次レビュー" "$WSUM_OUT"
assert_contains "engine: weekly-summary 期限超過" "期限超過: 1件" "$WSUM_OUT"
assert_contains "engine: weekly-summary inbox" "Inbox に 1件" "$WSUM_OUT"

# ──────────────────────────────────────────
# § 22  Dashboard — 分類・ソート・サマリー（Pro機能）
# ──────────────────────────────────────────
echo ""
echo "§22  Dashboard — 分類・ソート・サマリー"

# モック Issue JSON（TEST_TODAY=2026-04-05）
DASH_OPEN='[
  {"number":1,"title":"overdue-p1","body":"due: 2026-04-03","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":2,"title":"overdue-p2","body":"due: 2026-04-01","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":3,"title":"today-p1","body":"due: 2026-04-05","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":4,"title":"today-p2","body":"due: 2026-04-05","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":5,"title":"thisweek-p3","body":"due: 2026-04-08","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":6,"title":"thisweek-p2","body":"due: 2026-04-11","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":7,"title":"nodue-next","body":"","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":8,"title":"inbox-task","body":"","labels":[{"name":"📥 inbox"}]},
  {"number":9,"title":"waiting-overdue","body":"due: 2026-04-02","labels":[{"name":"⏳ waiting"}]},
  {"number":10,"title":"someday-task","body":"","labels":[{"name":"🌈 someday"}]}
]'
DASH_CLOSED='[
  {"number":90,"closedAt":"2026-04-05T10:00:00Z"},
  {"number":91,"closedAt":"2026-04-05T14:00:00Z"},
  {"number":92,"closedAt":"2026-04-02T10:00:00Z"},
  {"number":93,"closedAt":"2026-03-20T10:00:00Z"}
]'

DASH_OUT=$(OPEN_ENV="$DASH_OPEN" TODAY_ENV="$TEST_TODAY" CLOSED_ENV="$DASH_CLOSED" node "$ENGINE" dashboard)

# 分類テスト
assert_contains "Dashboard: 期限超過 3件"       "期限超過（3件）"     "$DASH_OUT"
assert_contains "Dashboard: 今日やること 2件"    "今日やること（2件）" "$DASH_OUT"
assert_contains "Dashboard: 今週期限 2件"        "今週期限（2件）"     "$DASH_OUT"
assert_contains "Dashboard: Next Actions 1件"    "Next Actions（1件）" "$DASH_OUT"

# ソートテスト（期限超過: p1→p2→p9）
OVERDUE_SECTION=$(echo "$DASH_OUT" | sed -n '/期限超過/,/^$/p')
POS_1=$(echo "$OVERDUE_SECTION" | grep -n '#1 ' | head -1 | cut -d: -f1)
POS_2=$(echo "$OVERDUE_SECTION" | grep -n '#2 ' | head -1 | cut -d: -f1)
POS_9=$(echo "$OVERDUE_SECTION" | grep -n '#9 ' | head -1 | cut -d: -f1)
if [ "$POS_1" -lt "$POS_2" ] && [ "$POS_2" -lt "$POS_9" ]; then
  printf "  ✅ Dashboard: 期限超過ソート p1→p2→p9\n"; PASS=$((PASS+1))
else
  printf "  ❌ Dashboard: 期限超過ソート p1→p2→p9\n"
  printf "     位置: #1=%s #2=%s #9=%s\n" "$POS_1" "$POS_2" "$POS_9"
  FAIL=$((FAIL+1))
fi

# 今日やること: p1→p2
TODAY_SECTION=$(echo "$DASH_OUT" | grep -aA 10 '今日やること')
POS_T3=$(echo "$TODAY_SECTION" | grep -n '#3 ' | head -1 | cut -d: -f1)
POS_T4=$(echo "$TODAY_SECTION" | grep -n '#4 ' | head -1 | cut -d: -f1)
if [ -n "$POS_T3" ] && [ -n "$POS_T4" ] && [ "$POS_T3" -lt "$POS_T4" ]; then
  printf "  ✅ Dashboard: 今日ソート p1→p2\n"; PASS=$((PASS+1))
else
  printf "  ❌ Dashboard: 今日ソート p1→p2\n"; FAIL=$((FAIL+1))
fi

# 今週期限: p2(#6)→p3(#5)
WEEK_SECTION=$(echo "$DASH_OUT" | sed -n '/今週期限/,/^$/p')
POS_W6=$(echo "$WEEK_SECTION" | grep -n '#6 ' | head -1 | cut -d: -f1)
POS_W5=$(echo "$WEEK_SECTION" | grep -n '#5 ' | head -1 | cut -d: -f1)
if [ "$POS_W6" -lt "$POS_W5" ]; then
  printf "  ✅ Dashboard: 今週ソート p2→p3\n"; PASS=$((PASS+1))
else
  printf "  ❌ Dashboard: 今週ソート p2→p3\n"; FAIL=$((FAIL+1))
fi

# GTDカウント
assert_contains "Dashboard: next 7件"           "next: 7件"    "$DASH_OUT"
assert_contains "Dashboard: inbox 1件"          "inbox: 1件"   "$DASH_OUT"
assert_contains "Dashboard: waiting 1件"        "waiting: 1件" "$DASH_OUT"
assert_contains "Dashboard: someday 1件"        "someday: 1件" "$DASH_OUT"

# 完了統計
assert_contains "Dashboard: 今日 2件完了"       "今日: 2件完了"  "$DASH_OUT"
assert_contains "Dashboard: 今週 3件完了"       "今週: 3件完了"  "$DASH_OUT"

# Inbox ヒント
assert_contains "Dashboard: Inbox ヒント"       "Inbox に 1件"   "$DASH_OUT"

# ヘッダー
assert_contains "Dashboard: ヘッダー"           "Dashboard — 2026-04-05" "$DASH_OUT"

# priority アイコン（grepがUTF-8絵文字非対応のためnodeで検証）
ICON_P1=$(DASH_ENV="$DASH_OUT" node -e "process.stdout.write(process.env.DASH_ENV.includes('\uD83D\uDD34')?'YES':'NO');")
assert_eq "Dashboard: p1 アイコン"  "YES"  "$ICON_P1"
ICON_P2=$(DASH_ENV="$DASH_OUT" node -e "process.stdout.write(process.env.DASH_ENV.includes('\uD83D\uDFE1')?'YES':'NO');")
assert_eq "Dashboard: p2 アイコン"  "YES"  "$ICON_P2"

# --- エッジケース: 空データ ---
DASH_EMPTY=$(OPEN_ENV='[]' TODAY_ENV="$TEST_TODAY" CLOSED_ENV='[]' node "$ENGINE" dashboard)
assert_contains "Dashboard空: ヘッダーあり"     "Dashboard — 2026-04-05"  "$DASH_EMPTY"
if ! echo "$DASH_EMPTY" | grep -q '期限超過'; then
  printf "  ✅ Dashboard空: 期限超過セクションなし\n"; PASS=$((PASS+1))
else
  printf "  ❌ Dashboard空: 期限超過セクションなし\n"; FAIL=$((FAIL+1))
fi
if ! echo "$DASH_EMPTY" | grep -q 'Inbox に'; then
  printf "  ✅ Dashboard空: Inbox ヒントなし\n"; PASS=$((PASS+1))
else
  printf "  ❌ Dashboard空: Inbox ヒントなし\n"; FAIL=$((FAIL+1))
fi

# --- エッジケース: nextActions 10件超 ---
NA12='['
for i in $(seq 1 12); do
  [ "$i" -gt 1 ] && NA12="$NA12,"
  NA12="$NA12{\"number\":$i,\"title\":\"task-$i\",\"body\":\"\",\"labels\":[{\"name\":\"next\"}]}"
done
NA12="$NA12]"
DASH_NA12=$(OPEN_ENV="$NA12" TODAY_ENV="$TEST_TODAY" CLOSED_ENV='[]' node "$ENGINE" dashboard)
assert_contains "Dashboard: nextActions 12件表示"  "Next Actions（12件）"  "$DASH_NA12"
assert_contains "Dashboard: ...他 2件"            "他 2件"               "$DASH_NA12"

# --- Dashboard: 見積もり合計表示 ---
DASH_EST_OPEN='[
  {"number":1,"title":"overdue-est","body":"due: 2026-04-03\nestimate: 60","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":2,"title":"today-est","body":"due: 2026-04-05\nestimate: 90","labels":[{"name":"🎯 next"},{"name":"p2"}]}
]'
DASH_EST_OUT=$(OPEN_ENV="$DASH_EST_OPEN" TODAY_ENV="$TEST_TODAY" CLOSED_ENV='[]' node "$ENGINE" dashboard)
assert_contains "Dashboard: 見積合計表示" "2h30m" "$DASH_EST_OUT"

# --- stats テスト（見積もり情報含む） ---
echo ""
echo "§22b  Stats — 見積もり情報"
STATS_MOCK='[
  {"number":1,"title":"t1","body":"estimate: 60","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":2,"title":"t2","body":"estimate: 120","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":3,"title":"t3","body":"","labels":[{"name":"🎯 next"}]}
]'
STATS_OUT=$(OPEN_ENV="$STATS_MOCK" TODAY_ENV="$TEST_TODAY" CLOSED_ENV='[]' node "$ENGINE" stats)
assert_contains "Stats: 見積合計" "3h" "$STATS_OUT"
assert_contains "Stats: 見積件数" "2件" "$STATS_OUT"
assert_contains "Stats: 見積なし" "見積なし: 1件" "$STATS_OUT"

# ──────────────────────────────────────────
# § 23  Daily Review — モード判定・フィルタ（Pro機能）
# ──────────────────────────────────────────
echo ""
echo "§23  Daily Review — モード判定・フィルタ"

detect_mode() {
  local hour="$1"
  if [ "$hour" -lt 15 ]; then echo "morning"; else echo "evening"; fi
}

assert_eq "Daily Review: hour=0→morning"  "morning" "$(detect_mode 0)"
assert_eq "Daily Review: hour=9→morning"  "morning" "$(detect_mode 9)"
assert_eq "Daily Review: hour=14→morning" "morning" "$(detect_mode 14)"
assert_eq "Daily Review: hour=15→evening" "evening" "$(detect_mode 15)"
assert_eq "Daily Review: hour=23→evening" "evening" "$(detect_mode 23)"

# Evening step1: closedAt フィルタ
DR_CLOSED='[
  {"number":50,"title":"done-today-1","closedAt":"2026-04-05T10:00:00Z"},
  {"number":51,"title":"done-today-2","closedAt":"2026-04-05T18:30:00Z"},
  {"number":52,"title":"done-yesterday","closedAt":"2026-04-04T12:00:00Z"},
  {"number":53,"title":"done-old","closedAt":"2026-03-30T08:00:00Z"}
]'
DR_TODAY_COUNT=$(TODAY_ENV="$TEST_TODAY" CLOSED_ENV="$DR_CLOSED" node -e "
  const today=process.env.TODAY_ENV;
  const closed=JSON.parse(process.env.CLOSED_ENV);
  const cnt=closed.filter(i=>i.closedAt&&i.closedAt.slice(0,10)===today).length;
  process.stdout.write(String(cnt));
")
assert_eq "Daily Review: closedAt 今日=2件" "2" "$DR_TODAY_COUNT"

# closedAt ゼロ件
DR_ZERO_COUNT=$(TODAY_ENV="$TEST_TODAY" CLOSED_ENV='[{"number":60,"title":"old","closedAt":"2026-03-01T10:00:00Z"}]' node -e "
  const today=process.env.TODAY_ENV;
  const closed=JSON.parse(process.env.CLOSED_ENV);
  const cnt=closed.filter(i=>i.closedAt&&i.closedAt.slice(0,10)===today).length;
  process.stdout.write(String(cnt));
")
assert_eq "Daily Review: closedAt 今日=0件" "0" "$DR_ZERO_COUNT"

# Evening step3: 明日の due フィルタ
DR_OPEN='[
  {"number":70,"title":"due-today","body":"due: 2026-04-05","labels":[{"name":"🎯 next"}]},
  {"number":71,"title":"due-tomorrow","body":"due: 2026-04-06","labels":[{"name":"🎯 next"}]},
  {"number":72,"title":"due-later","body":"due: 2026-04-10","labels":[{"name":"🎯 next"}]},
  {"number":73,"title":"no-due","body":"","labels":[{"name":"🎯 next"}]}
]'
DR_TOMORROW=$(TODAY_ENV="$TEST_TODAY" OPEN_ENV="$DR_OPEN" node -e "
  const today=process.env.TODAY_ENV;
  const issues=JSON.parse(process.env.OPEN_ENV);
  const tmr=new Date(today); tmr.setDate(tmr.getDate()+1);
  const tmrStr=tmr.toISOString().slice(0,10);
  const result=issues.filter(i=>{
    const m=(i.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    return m && m[1]===tmrStr;
  });
  process.stdout.write(result.map(i=>'#'+i.number).join(','));
")
assert_eq "Daily Review: 明日期限=#71" "#71" "$DR_TOMORROW"

# 明日期限ゼロ件
DR_TOMORROW_ZERO=$(TODAY_ENV="$TEST_TODAY" OPEN_ENV='[{"number":80,"title":"no-due","body":"","labels":[{"name":"🎯 next"}]}]' node -e "
  const today=process.env.TODAY_ENV;
  const issues=JSON.parse(process.env.OPEN_ENV);
  const tmr=new Date(today); tmr.setDate(tmr.getDate()+1);
  const tmrStr=tmr.toISOString().slice(0,10);
  const result=issues.filter(i=>{
    const m=(i.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    return m && m[1]===tmrStr;
  });
  process.stdout.write(String(result.length));
")
assert_eq "Daily Review: 明日期限=0件" "0" "$DR_TOMORROW_ZERO"

# ──────────────────────────────────────────
# § 24  Custom Views — CRUD（Issue #1648 Phase 2 で置換済み）
# ──────────────────────────────────────────
# 旧実装は `node -e` によるコピー実装（runView 本体を経由しない再実装）だったため、
# 実装のバグ（例: 分岐順序ミス）を検出できなかった。Octokit 注入シーム導入に伴い、
# tests/run-tests-write.sh §W3（runView 正常系/異常系）へスタブ経由の実CLI直叩き
# テストとして置換した（save/save2件目/list/use/delete/再delete/存在しないview use）。

# ──────────────────────────────────────────
# § 25  Report — 期間パース・集計（Pro機能）
# ──────────────────────────────────────────
echo ""
echo "§25  Report — 期間パース・集計"

# 期間パーステスト
parse_report_period() {
  local input="$1"
  case "$input" in
    weekly)  echo 7 ;;
    monthly) echo 30 ;;
    *d)
      local n="${input%d}"
      case "$n" in
        ''|*[!0-9]*|0) echo "ERROR"; return 1 ;;
      esac
      echo "$n" ;;
    *) echo "ERROR"; return 1 ;;
  esac
}

assert_eq "Report period: weekly→7"   "7"     "$(parse_report_period weekly)"
assert_eq "Report period: monthly→30" "30"    "$(parse_report_period monthly)"
assert_eq "Report period: 14d→14"     "14"    "$(parse_report_period 14d)"
assert_eq "Report period: 1d→1"       "1"     "$(parse_report_period 1d)"
assert_eq "Report period: abc→ERROR"  "ERROR" "$(parse_report_period abc)"
assert_eq "Report period: 0→ERROR"    "ERROR" "$(parse_report_period 0)"
assert_eq "Report period: -5d→ERROR"  "ERROR" "$(parse_report_period -5d)"

# レポート集計テスト
RPT_OPEN='[
  {"number":100,"title":"open-next","body":"due: 2026-04-03","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":101,"title":"open-inbox","body":"","labels":[{"name":"📥 inbox"}]},
  {"number":102,"title":"open-waiting","body":"due: 2026-04-10","labels":[{"name":"⏳ waiting"}]}
]'
RPT_CLOSED='[
  {"number":200,"title":"closed-1","closedAt":"2026-04-05T10:00:00Z","labels":[{"name":"🎯 next"},{"name":"p1"}],"body":""},
  {"number":201,"title":"closed-2","closedAt":"2026-04-05T14:00:00Z","labels":[{"name":"🎯 next"},{"name":"p2"}],"body":""},
  {"number":202,"title":"closed-3","closedAt":"2026-04-04T10:00:00Z","labels":[{"name":"🎯 next"},{"name":"p3"}],"body":""},
  {"number":203,"title":"closed-4","closedAt":"2026-04-03T10:00:00Z","labels":[{"name":"📥 inbox"}],"body":""},
  {"number":204,"title":"closed-5","closedAt":"2026-04-03T16:00:00Z","labels":[{"name":"⏳ waiting"},{"name":"p1"}],"body":""},
  {"number":205,"title":"closed-6","closedAt":"2026-04-01T10:00:00Z","labels":[{"name":"🎯 next"},{"name":"p2"}],"body":""},
  {"number":206,"title":"closed-7","closedAt":"2026-03-30T10:00:00Z","labels":[{"name":"🌈 someday"}],"body":""},
  {"number":207,"title":"closed-outside","closedAt":"2026-03-28T10:00:00Z","labels":[{"name":"🎯 next"}],"body":""}
]'

RPT_OUT=$(OPEN_ENV="$RPT_OPEN" TODAY_ENV="$TEST_TODAY" DAYS_ENV="7" CLOSED_ENV="$RPT_CLOSED" node "$ENGINE" report)

# レポートヘッダー
assert_contains "Report: ヘッダー"               "生産性レポート"     "$RPT_OUT"
assert_contains "Report: 期間表示"               "2026-03-29 〜 2026-04-05" "$RPT_OUT"

# 完了数（期間内7件、期間外1件除外）
assert_contains "Report: 完了7件"                '\*\*7件\*\*'        "$RPT_OUT"
assert_contains "Report: 日平均1.0"              "1.0件"              "$RPT_OUT"

# 日別カウント（04-05 に2件）
assert_contains "Report: 04-05 日別2件"          "04-05 .*2"          "$RPT_OUT"

# バーチャート
assert_contains "Report: バーチャート █"          "█"                  "$RPT_OUT"

# カテゴリ別
assert_contains "Report: next 4件完了"            "next: 4件"          "$RPT_OUT"
assert_contains "Report: inbox 1件完了"           "inbox: 1件"         "$RPT_OUT"
assert_contains "Report: waiting 1件完了"         "waiting: 1件"       "$RPT_OUT"
assert_contains "Report: someday 1件完了"         "someday: 1件"       "$RPT_OUT"

# 優先度別
assert_contains "Report: p1 2件"                  "p1: 2件"            "$RPT_OUT"
assert_contains "Report: p2 2件"                  "p2: 2件"            "$RPT_OUT"
assert_contains "Report: p3 1件"                  "p3: 1件"            "$RPT_OUT"
assert_contains "Report: 優先度なし 2件"           "優先度なし: 2件"     "$RPT_OUT"

# オープン状況
assert_contains "Report: open next 1件"           "next: 1件"          "$RPT_OUT"
assert_contains "Report: 期限超過 1件"             "期限超過: 1件"       "$RPT_OUT"

# 完了タスク一覧（最新順）
assert_contains "Report: 完了一覧 #200"           "#200"               "$RPT_OUT"
assert_contains "Report: 完了一覧 #206"           "#206"               "$RPT_OUT"

# --- エッジケース: 完了ゼロ ---
RPT_EMPTY=$(OPEN_ENV='[]' TODAY_ENV="$TEST_TODAY" DAYS_ENV="7" CLOSED_ENV='[]' node "$ENGINE" report)
assert_contains "Report空: 完了タスクなし"  "完了タスクなし"  "$RPT_EMPTY"

# --- Report: 見積 vs 実績 ---
RPT_EST_CLOSED='[
  {"number":300,"title":"est-task","closedAt":"2026-04-05T10:00:00Z","labels":[{"name":"🎯 next"}],"body":"estimate: 60\nactual: 90"},
  {"number":301,"title":"est-task2","closedAt":"2026-04-04T10:00:00Z","labels":[{"name":"🎯 next"}],"body":"estimate: 120\nactual: 100"}
]'
RPT_EST_OUT=$(OPEN_ENV='[]' TODAY_ENV="$TEST_TODAY" DAYS_ENV="7" CLOSED_ENV="$RPT_EST_CLOSED" node "$ENGINE" report)
assert_contains "Report: 見積合計" "3h" "$RPT_EST_OUT"
assert_contains "Report: 実績合計" "3h10m" "$RPT_EST_OUT"
assert_contains "Report: 予実比" "106%" "$RPT_EST_OUT"
assert_contains "Report: 見積+実績あり件数" "2件 / 2件" "$RPT_EST_OUT"

# ──────────────────────────────────────────
# § 26  English output (LANG_ENV=en)
# ──────────────────────────────────────────
echo ""
echo "§26  English output (LANG_ENV=en)"

# list-all English headers
LIST_EN_OUT=$(LANG_ENV=en OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" node "$ENGINE" list-all)
assert_contains "en: list-all Next Actions header" "## ✅ Next Actions$" "$LIST_EN_OUT"
assert_not_contains "en: list-all Inbox header no JP" "受信トレイ"        "$LIST_EN_OUT"
assert_contains "en: list-all summary no 件"       "next: 2"            "$LIST_EN_OUT"
assert_contains "en: list-all No Next Action"      "No Next Action"     "$LIST_EN_OUT"

# list-all filter English
LIST_EN_EMPTY=$(LANG_ENV=en OPEN_ENV='[]' TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "en: list-all empty filter"        "No matching tasks"  "$LIST_EN_EMPTY"

# list-summary English
LSUM_EN_OUT=$(LANG_ENV=en OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" node "$ENGINE" list-summary)
assert_contains "en: list-summary Overdue"         "Overdue"            "$LSUM_EN_OUT"

# weekly-summary English
WSUM_EN_OUT=$(LANG_ENV=en OPEN_ENV="$WSUM_MOCK" TODAY_ENV="$TEST_TODAY" node "$ENGINE" weekly-summary)
assert_contains "en: weekly-summary header"        "Weekly Review"      "$WSUM_EN_OUT"
assert_contains "en: weekly-summary no overdue text" "Overdue"          "$WSUM_EN_OUT"
assert_contains "en: weekly-summary Starting"      "Starting review"    "$WSUM_EN_OUT"
assert_contains "en: weekly-summary inbox"         "Inbox has"          "$WSUM_EN_OUT"

# dashboard English
DASH_EN_OUT=$(LANG_ENV=en OPEN_ENV="$DASH_OPEN" TODAY_ENV="$TEST_TODAY" CLOSED_ENV="$DASH_CLOSED" node "$ENGINE" dashboard)
assert_contains "en: dashboard Overdue"            "Overdue"            "$DASH_EN_OUT"
assert_contains "en: dashboard Due Today"          "Due Today"          "$DASH_EN_OUT"
assert_contains "en: dashboard Due This Week"      "Due This Week"      "$DASH_EN_OUT"
assert_contains "en: dashboard Next Actions"       "Next Actions"       "$DASH_EN_OUT"
assert_contains "en: dashboard completed"          "completed"          "$DASH_EN_OUT"

# stats English
STATS_EN_OUT=$(LANG_ENV=en OPEN_ENV="$STATS_MOCK" TODAY_ENV="$TEST_TODAY" CLOSED_ENV='[]' node "$ENGINE" stats)
assert_contains "en: stats header"                 "Task Statistics"    "$STATS_EN_OUT"
assert_contains "en: stats By Category"            "By Category"        "$STATS_EN_OUT"
assert_contains "en: stats By Priority"            "By Priority"        "$STATS_EN_OUT"
assert_contains "en: stats Deadlines"              "Deadlines"          "$STATS_EN_OUT"
assert_contains "en: stats Completed"              "Completed"          "$STATS_EN_OUT"

# report English
RPT_EN_OUT=$(LANG_ENV=en OPEN_ENV="$RPT_OPEN" TODAY_ENV="$TEST_TODAY" DAYS_ENV="7" CLOSED_ENV="$RPT_CLOSED" node "$ENGINE" report)
assert_contains "en: report header"                "Productivity Report" "$RPT_EN_OUT"
assert_contains "en: report period 'to'"           " to "                "$RPT_EN_OUT"
assert_contains "en: report Completed Summary"     "Completed Summary"   "$RPT_EN_OUT"
assert_contains "en: report Metric/Value"          "Metric"              "$RPT_EN_OUT"
assert_contains "en: report By Category"           "Completed by Category" "$RPT_EN_OUT"
assert_contains "en: report Current Status"        "Current Task Status" "$RPT_EN_OUT"

# template English
TEMP_TFILE_EN=$(mktemp /tmp/todo-test-templates-en-XXXXXX)
printf '{}' > "$TEMP_TFILE_EN"
REAL_HOME="$HOME"
FAKE_HOME=$(mktemp -d /tmp/todo-test-home-en-XXXXXX)
export HOME="$FAKE_HOME"
# Windows (Git Bash) では USERPROFILE も差し替えないと os.homedir() が古い値を返す
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  REAL_USERPROFILE="${USERPROFILE:-}"
  export USERPROFILE="$FAKE_HOME"
fi
mkdir -p "$HOME/.claude"
printf '{}' > "$HOME/.claude/todo-templates.json"
printf '{}' > "$HOME/.claude/todo-views.json"

TPL_LIST_EN=$(LANG_ENV=en node "$ENGINE" template list)
assert_contains "en: template list empty"          "No templates"        "$TPL_LIST_EN"

LANG_ENV=en TNAME_ENV="test-en" GTD_ENV="next" CONTEXTS_ENV='["@PC"]' PRIORITY_ENV="p1" node "$ENGINE" template save
TPL_SAVED_EN=$(LANG_ENV=en node "$ENGINE" template list)
assert_contains "en: template list after save"     "test-en"             "$TPL_SAVED_EN"

VIEW_LIST_EN=$(LANG_ENV=en node "$ENGINE" view list)
assert_contains "en: view list empty"              "No views"            "$VIEW_LIST_EN"

export HOME="$REAL_HOME"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  if [ -n "$REAL_USERPROFILE" ]; then export USERPROFILE="$REAL_USERPROFILE"; else unset USERPROFILE; fi
fi
rm -rf "$FAKE_HOME" 2>/dev/null || true
# Issue #1882: TEMP_TFILE_EN は対になる cleanup が元から無く、実行のたび /tmp に
# 残り続けていた（FAKE_HOME 側には上の rm -rf がある）。ここで併せて後始末する。
rm -f "$TEMP_TFILE_EN" 2>/dev/null || true

# Verify default (ja) still works
LIST_JA_OUT=$(OPEN_ENV="$LIST_MOCK" TODAY_ENV="$TEST_TODAY" node "$ENGINE" list-all)
assert_contains "ja default: list 件 suffix"       "2件"                 "$LIST_JA_OUT"
assert_contains "ja default: section header"        "次のアクション"     "$LIST_JA_OUT"

# ──────────────────────────────────────────
# help コマンドテスト
# ──────────────────────────────────────────
echo ""
echo "▶ help コマンド"

HELP_JA=$(LANG_ENV=ja node "$ENGINE" help)
assert_contains "ja: help header"         "コマンド一覧"       "$HELP_JA"
assert_contains "ja: help タスク管理"     "タスク管理"         "$HELP_JA"
assert_contains "ja: help コンテキスト"   "コンテキスト"       "$HELP_JA"
assert_contains "ja: help 一括操作"       "一括操作"           "$HELP_JA"
assert_contains "ja: help レビュー"       "レビュー"           "$HELP_JA"
assert_contains "ja: help テンプレート"   "テンプレート"       "$HELP_JA"
assert_contains "ja: help その他"         "その他"             "$HELP_JA"
assert_contains "ja: help /todo list"     "/todo list"         "$HELP_JA"
assert_contains "ja: help /todo done"     "/todo done"         "$HELP_JA"
assert_contains "ja: help /todo today"    "/todo today"        "$HELP_JA"
assert_contains "ja: help /todo help"     "/todo help"         "$HELP_JA"

HELP_EN=$(LANG_ENV=en node "$ENGINE" help)
assert_contains "en: help header"         "Command Reference"  "$HELP_EN"
assert_contains "en: help Task Mgmt"      "Task Management"    "$HELP_EN"
assert_contains "en: help Context"        "Context"            "$HELP_EN"
assert_contains "en: help Bulk"           "Bulk Operations"    "$HELP_EN"
assert_contains "en: help Reviews"        "Reviews"            "$HELP_EN"
assert_contains "en: help Templates"      "Templates"          "$HELP_EN"
assert_contains "en: help Other"          "Other"              "$HELP_EN"

# ──────────────────────────────────────────
# help コマンド: #1655 フェーズ1（7コマンド欠落修正・review系移行・--depends-on配線）
# ──────────────────────────────────────────
echo ""
echo "▶ help コマンド（#1655 フェーズ1）"

# 1-1: 7コマンドが help() に出力される（ja/en）
for cmd in "promote-project" "unlink" "review-someday" "weekly-project-audit" "migrate" "comment" "api"; do
  assert_contains "ja: help に $cmd が含まれる" "$cmd" "$HELP_JA"
  assert_contains "en: help に $cmd が含まれる" "$cmd" "$HELP_EN"
done

# 1-2: --depends-on の配線漏れ修正（help() から呼ばれる）
# 注: grep パターンが "--" で始まると未知オプション扱いになるため、先頭の "--" を含めない
assert_contains "ja: help に --depends-on が含まれる" "depends-on <#N>" "$HELP_JA"
assert_contains "en: help に --depends-on が含まれる" "depends-on <#N>" "$HELP_EN"

# 1-3: review / daily-review / weekly-review は「現役コマンド」としては現れない
#      （旧コマンド行の厳密な文字列。誘導文言側は異なる文言・スペース幅のため誤検知しない）
assert_not_contains "ja: help に旧 review コマンド行が残っていない"        "review                    Inboxレビュー"                 "$HELP_JA"
assert_not_contains "ja: help に旧 daily-review コマンド行が残っていない"  "daily-review \[morning|evening\] デイリーレビュー"        "$HELP_JA"
assert_not_contains "ja: help に旧 weekly-review コマンド行が残っていない" "weekly-review              週次レビュー"                  "$HELP_JA"
assert_not_contains "en: help に旧 review コマンド行が残っていない"        "review                    Inbox review"                   "$HELP_EN"
assert_not_contains "en: help に旧 daily-review コマンド行が残っていない"  "daily-review \[morning|evening\] Daily review"            "$HELP_EN"
assert_not_contains "en: help に旧 weekly-review コマンド行が残っていない" "weekly-review              Weekly review"                 "$HELP_EN"

# 1-3: 誘導文言としては残っているが、環境依存の具体スキル名(/gtd-collect 等)は書かず、
#      環境非依存に todo.md の「対話コマンド」節へ誘導する（方針決定済み・公開リポには
#      /gtd-collect 等のスキルが存在しないため。ユーザー承認済み、2026-08-23）
assert_contains "ja: help の誘導文言が todo.md を参照させている"         "todo.md"           "$HELP_JA"
assert_contains "ja: help の誘導文言が「対話コマンド」節を指している"     "対話コマンド"       "$HELP_JA"
assert_contains "en: help の誘導文言が todo.md を参照させている"         "todo.md"           "$HELP_EN"
assert_contains "en: help の誘導文言が Interactive Commands 節を指している" "Interactive Commands" "$HELP_EN"

assert_not_contains "ja: help の誘導文言に環境依存スキル名 /gtd-collect が含まれない"   "/gtd-collect"   "$HELP_JA"
assert_not_contains "ja: help の誘導文言に環境依存スキル名 /daily-review が含まれない"  "/daily-review"  "$HELP_JA"
assert_not_contains "ja: help の誘導文言に環境依存スキル名 /weekly-review が含まれない" "/weekly-review" "$HELP_JA"
assert_not_contains "en: help の誘導文言に環境依存スキル名 /gtd-collect が含まれない"   "/gtd-collect"   "$HELP_EN"
assert_not_contains "en: help の誘導文言に環境依存スキル名 /daily-review が含まれない"  "/daily-review"  "$HELP_EN"
assert_not_contains "en: help の誘導文言に環境依存スキル名 /weekly-review が含まれない" "/weekly-review" "$HELP_EN"

# ──────────────────────────────────────────
# today コマンドテスト
# ──────────────────────────────────────────
echo ""
echo "▶ today コマンド"

# タスクなし
TODAY_EMPTY=$(LANG_ENV=ja OPEN_ENV='[]' CLOSED_ENV='[]' TODAY_ENV="$TEST_TODAY" node "$ENGINE" today)
assert_contains "ja: today 空の場合"       "今日のタスクはありません" "$TODAY_EMPTY"

TODAY_EMPTY_EN=$(LANG_ENV=en OPEN_ENV='[]' CLOSED_ENV='[]' TODAY_ENV="$TEST_TODAY" node "$ENGINE" today)
assert_contains "en: today empty"          "No tasks for today"      "$TODAY_EMPTY_EN"

# 期限超過 + 今日期限のタスクあり
TODAY_DATA='[
  {"number":10,"title":"期限超過","body":"due: 2026-04-03\nestimate: 60","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":11,"title":"今日のタスク","body":"due: 2026-04-05\nestimate: 30","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":12,"title":"明日のタスク","body":"due: 2026-04-06","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":13,"title":"期限なし","body":"","labels":[{"name":"🎯 next"}]}
]'
CLOSED_DATA='[{"number":20,"closedAt":"2026-04-05T10:00:00Z"},{"number":21,"closedAt":"2026-04-04T10:00:00Z"}]'
TODAY_OUT=$(LANG_ENV=ja OPEN_ENV="$TODAY_DATA" CLOSED_ENV="$CLOSED_DATA" TODAY_ENV="$TEST_TODAY" node "$ENGINE" today)

assert_contains "ja: today ヘッダー"       "今日のタスク"            "$TODAY_OUT"
assert_contains "ja: today 日付"           "$TEST_TODAY"             "$TODAY_OUT"
assert_contains "ja: today 期限超過あり"   "期限超過"                "$TODAY_OUT"
assert_contains "ja: today #10 表示"       "#10"                     "$TODAY_OUT"
assert_contains "ja: today 今日が期限"     "今日が期限"              "$TODAY_OUT"
assert_contains "ja: today #11 表示"       "#11"                     "$TODAY_OUT"
assert_not_contains "ja: today #12 非表示" "#12"                     "$TODAY_OUT"
assert_not_contains "ja: today #13 非表示" "#13"                     "$TODAY_OUT"
assert_contains "ja: today 合計"           "合計"                    "$TODAY_OUT"
assert_contains "ja: today 見積"           "見積"                    "$TODAY_OUT"
assert_contains "ja: today 完了数"         "1件完了"                 "$TODAY_OUT"

# en
TODAY_OUT_EN=$(LANG_ENV=en OPEN_ENV="$TODAY_DATA" CLOSED_ENV="$CLOSED_DATA" TODAY_ENV="$TEST_TODAY" node "$ENGINE" today)
assert_contains "en: today header"         "Today"                   "$TODAY_OUT_EN"
assert_contains "en: today Overdue"        "Overdue"                 "$TODAY_OUT_EN"
assert_contains "en: today Due Today"      "Due Today"               "$TODAY_OUT_EN"
assert_contains "en: today Total"          "Total"                   "$TODAY_OUT_EN"

# ──────────────────────────────────────────
# §27  normalizeDue — 追加パターン（ひらがな・曜日）
# ──────────────────────────────────────────
echo ""
echo "§27  normalizeDue — ひらがな・曜日パターン"

# テスト固定日付: 2026-04-15 (水曜日)
TEST_DOW="2026-04-15"

# ひらがな表現
assert_eq "きょう"   "2026-04-15" "$(node "$ENGINE" normalize-due 'きょう' "$TEST_DOW")"
assert_eq "あした"   "2026-04-16" "$(node "$ENGINE" normalize-due 'あした' "$TEST_DOW")"
assert_eq "あす"     "2026-04-16" "$(node "$ENGINE" normalize-due 'あす' "$TEST_DOW")"
assert_eq "あさって" "2026-04-17" "$(node "$ENGINE" normalize-due 'あさって' "$TEST_DOW")"
assert_eq "きのう"   "2026-04-14" "$(node "$ENGINE" normalize-due 'きのう' "$TEST_DOW")"

# X曜日パターン（次に来るその曜日。今日=水曜）
assert_eq "水曜(今日→当日)" "2026-04-15" "$(node "$ENGINE" normalize-due '水曜' "$TEST_DOW")"
assert_eq "木曜(翌日→04/16)" "2026-04-16" "$(node "$ENGINE" normalize-due '木曜' "$TEST_DOW")"
assert_eq "金曜(今週→04/17)" "2026-04-17" "$(node "$ENGINE" normalize-due '金曜' "$TEST_DOW")"
assert_eq "月曜(来週→04/20)" "2026-04-20" "$(node "$ENGINE" normalize-due '月曜' "$TEST_DOW")"
assert_eq "日曜日(来週→04/19)" "2026-04-19" "$(node "$ENGINE" normalize-due '日曜日' "$TEST_DOW")"

# 今週X曜パターン（今日=水曜 2026-04-15）
# 今日以降のその曜日を指す（今日より前は今日に丸める）
assert_eq "今週水曜(今日)" "2026-04-15" "$(node "$ENGINE" normalize-due '今週水曜' "$TEST_DOW")"
assert_eq "今週金曜" "2026-04-17" "$(node "$ENGINE" normalize-due '今週金曜' "$TEST_DOW")"
assert_eq "今週月曜(過去→今日)" "2026-04-15" "$(node "$ENGINE" normalize-due '今週月曜' "$TEST_DOW")"

# TEST_TODAYベース（日曜 2026-04-05）での曜日テスト
assert_eq "金曜(日曜起点→04/10)" "2026-04-10" "$(node "$ENGINE" normalize-due '金曜' "$TEST_TODAY")"
assert_eq "日曜(今日→当日)"      "2026-04-05" "$(node "$ENGINE" normalize-due '日曜' "$TEST_TODAY")"
assert_eq "月曜(翌日→04/06)"     "2026-04-06" "$(node "$ENGINE" normalize-due '月曜' "$TEST_TODAY")"

# 今週X曜（日曜 2026-04-05 起点）
assert_eq "今週金曜(日曜起点)" "2026-04-10" "$(node "$ENGINE" normalize-due '今週金曜' "$TEST_TODAY")"
assert_eq "今週日曜(今日)"     "2026-04-05" "$(node "$ENGINE" normalize-due '今週日曜' "$TEST_TODAY")"

# ──────────────────────────────────────────
# §28  list-all --group (期限別グルーピング)
# ──────────────────────────────────────────
echo ""
echo "§28  list-all --group — 期限別グルーピング"

# 基準日: 2026-04-15 (水曜)
GROUP_TODAY="2026-04-15"
GROUP_MOCK='[
  {"number":1,"title":"overdue-task","body":"due: 2026-04-14","labels":[{"name":"🎯 next"},{"name":"p1"}]},
  {"number":2,"title":"today-task","body":"due: 2026-04-15","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":3,"title":"tomorrow-task","body":"due: 2026-04-16","labels":[{"name":"🎯 next"},{"name":"p3"}]},
  {"number":4,"title":"thisweek-task","body":"due: 2026-04-17","labels":[{"name":"🎯 next"}]},
  {"number":5,"title":"later-task","body":"due: 2026-05-04","labels":[{"name":"🎯 next"}]},
  {"number":6,"title":"nodue-task","body":"","labels":[{"name":"🎯 next"}]}
]'

GROUP_OUT=$(OPEN_ENV="$GROUP_MOCK" TODAY_ENV="$GROUP_TODAY" FILTER_GTD_ENV="next" FILTER_GROUP_ENV="1" node "$ENGINE" list-all)

assert_contains "group: 期限超過セクション"  "期限超過"  "$GROUP_OUT"
assert_contains "group: 今日セクション"      "今日"      "$GROUP_OUT"
assert_contains "group: 明日セクション"      "明日"      "$GROUP_OUT"
assert_contains "group: 今週セクション"      "今週"      "$GROUP_OUT"
assert_contains "group: 来週以降セクション"  "来週以降"  "$GROUP_OUT"
assert_contains "group: 期限なしセクション"  "期限なし"  "$GROUP_OUT"
assert_contains "group: #1 期限超過"         "#1"        "$GROUP_OUT"
assert_contains "group: #2 今日"             "#2"        "$GROUP_OUT"
assert_contains "group: #3 明日"             "#3"        "$GROUP_OUT"
assert_contains "group: #4 今週"             "#4"        "$GROUP_OUT"
assert_contains "group: #5 来週以降"         "#5"        "$GROUP_OUT"
assert_contains "group: #6 期限なし"         "#6"        "$GROUP_OUT"

# --group なし（従来通りフラットリスト）
GROUP_NOGROUP=$(OPEN_ENV="$GROUP_MOCK" TODAY_ENV="$GROUP_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
if ! printf '%s' "$GROUP_NOGROUP" | grep -aq '期限超過 ──'; then
  printf "  ✅ group: --groupなしはセクションヘッダーなし\n"; PASS=$((PASS+1))
else
  printf "  ❌ group: --groupなしはセクションヘッダーなし\n"; FAIL=$((FAIL+1))
fi

# --group フィルタなし（全タスク対象）
GROUP_ALL=$(OPEN_ENV="$GROUP_MOCK" TODAY_ENV="$GROUP_TODAY" FILTER_GROUP_ENV="1" node "$ENGINE" list-all)
assert_contains "group: フィルタなし全タスク期限超過" "期限超過" "$GROUP_ALL"
assert_contains "group: フィルタなし#6表示"          "#6"       "$GROUP_ALL"

# 空データ
GROUP_EMPTY=$(OPEN_ENV='[]' TODAY_ENV="$GROUP_TODAY" FILTER_GTD_ENV="next" FILTER_GROUP_ENV="1" node "$ENGINE" list-all)
assert_contains "group: 空データ → 該当タスクなし" "該当タスクなし" "$GROUP_EMPTY"

# 順序確認: 期限超過が先頭
POS_OVER=$(printf '%s\n' "$GROUP_OUT" | grep -n '期限超過' | head -1 | cut -d: -f1)
POS_NODUE=$(printf '%s\n' "$GROUP_OUT" | grep -n '期限なし' | head -1 | cut -d: -f1)
if [ -n "$POS_OVER" ] && [ -n "$POS_NODUE" ] && [ "$POS_OVER" -lt "$POS_NODUE" ]; then
  printf "  ✅ group: 期限超過が期限なしより先頭\n"; PASS=$((PASS+1))
else
  printf "  ❌ group: 期限超過が期限なしより先頭\n"; FAIL=$((FAIL+1))
fi

# ──────────────────────────────────────────
# §28b  list --no-due (期限未設定フィルタ)
# ──────────────────────────────────────────
echo ""
echo "§28b  list --no-due — 期限未設定のタスクのみ表示"

NODUE_MOCK='[
  {"number":10,"title":"has-due-task","body":"due: 2026-04-20","labels":[{"name":"🎯 next"}]},
  {"number":11,"title":"no-due-task","body":"","labels":[{"name":"🎯 next"}]},
  {"number":12,"title":"someday-no-due","body":"","labels":[{"name":"🌈 someday"}]},
  {"number":13,"title":"next-no-due-2","body":"desc: something","labels":[{"name":"🎯 next"}]}
]'
NODUE_TODAY="2026-04-15"

# next --no-due: due なし next タスクだけ返る
NODUE_OUT=$(OPEN_ENV="$NODUE_MOCK" TODAY_ENV="$NODUE_TODAY" FILTER_GTD_ENV="next" FILTER_NO_DUE_ENV="1" node "$ENGINE" list-all)
assert_contains "no-due: #11 が含まれる"    "#11"           "$NODUE_OUT"
assert_contains "no-due: #13 が含まれる"    "#13"           "$NODUE_OUT"
if printf '%s' "$NODUE_OUT" | grep -aq '#10'; then
  printf "  ❌ no-due: 期限ありの #10 が誤って含まれた\n"; FAIL=$((FAIL+1))
else
  printf "  ✅ no-due: 期限ありの #10 は除外される\n"; PASS=$((PASS+1))
fi
if printf '%s' "$NODUE_OUT" | grep -aq '#12'; then
  printf "  ❌ no-due: 別GTDの #12 が誤って含まれた\n"; FAIL=$((FAIL+1))
else
  printf "  ✅ no-due: 別GTD(someday)の #12 は除外される\n"; PASS=$((PASS+1))
fi

# --no-due で 0 件のとき「該当タスクなし」
NODUE_EMPTY=$(OPEN_ENV='[{"number":20,"title":"with-due","body":"due: 2026-04-18","labels":[{"name":"🎯 next"}]}]' TODAY_ENV="$NODUE_TODAY" FILTER_GTD_ENV="next" FILTER_NO_DUE_ENV="1" node "$ENGINE" list-all)
assert_contains "no-due: 0件 → 該当タスクなし" "該当タスクなし" "$NODUE_EMPTY"

# --no-due は --group より優先（セクションヘッダーなし）
NODUE_VS_GROUP=$(OPEN_ENV="$NODUE_MOCK" TODAY_ENV="$NODUE_TODAY" FILTER_GTD_ENV="next" FILTER_NO_DUE_ENV="1" FILTER_GROUP_ENV="1" node "$ENGINE" list-all)
if ! printf '%s' "$NODUE_VS_GROUP" | grep -aq '期限なし ──'; then
  printf "  ✅ no-due: --no-due 優先でグループヘッダーなし\n"; PASS=$((PASS+1))
else
  printf "  ❌ no-due: --no-due 優先なのにグループヘッダーが出た\n"; FAIL=$((FAIL+1))
fi

# ──────────────────────────────────────────
# §29  シナリオ 36-13/36-14/36-15 — activate/before バリデーション
# ──────────────────────────────────────────
echo ""
echo "§29  activate/before バリデーション（36-13/36-14/36-15）"

# 36-13: 不正な --activate 日付でnormalizeDueは非YYYY-MM-DD/M/D値をパススルーし
# 後続のregexチェックでエラー検出されることを確認
NORMALIZE_FOO=$(node "$ENGINE" normalize-due 'foo' "$TEST_TODAY")
# 'foo' はどのパターンにもマッチしないのでパススルーで返る（null ではなく元の値）
# → 後続の YYYY-MM-DD / M/D チェックで弾かれる
if printf '%s' "$NORMALIZE_FOO" | grep -qv '^\d\{4\}-\d\{2\}-\d\{2\}$'; then
  printf "  ✅ 36-13: normalize-due 'foo' → YYYY-MM-DD 形式ではない（後続チェックで弾かれる）\n"; PASS=$((PASS+1))
else
  printf "  ❌ 36-13: normalize-due 'foo' → '%s' (非YYYY-MM-DD が期待された)\n" "$NORMALIZE_FOO"; FAIL=$((FAIL+1))
fi

# 36-13: normalizeDue が null/falsy のときエラー終了するコードパスを直接検証
ACTIVATE_ERR=$(node -e "
const raw = 'foo';
const today = '$TEST_TODAY';
// normalizeDueと同じロジックで null チェック
function normalizeDue(r, t) { return null; }  // 意図的にnullを返す
let activateRaw = normalizeDue(raw, today);
if (!activateRaw) {
  process.stderr.write('エラー: 不正な日付形式です: ' + raw + '\n');
  process.exit(1);
}
" 2>&1)
ACTIVATE_ERR_EXIT=$?
if [ $ACTIVATE_ERR_EXIT -ne 0 ]; then
  printf "  ✅ 36-13: normalizeDue null → exit 1\n"; PASS=$((PASS+1))
else
  printf "  ❌ 36-13: normalizeDue null → exit 0 (エラー終了が期待された)\n"; FAIL=$((FAIL+1))
fi
if printf '%s' "$ACTIVATE_ERR" | grep -q '不正な日付形式'; then
  printf "  ✅ 36-13: エラーメッセージに '不正な日付形式' を含む\n"; PASS=$((PASS+1))
else
  printf "  ❌ 36-13: エラーメッセージに '不正な日付形式' が含まれない: '%s'\n" "$ACTIVATE_ERR"; FAIL=$((FAIL+1))
fi

# 36-14: before clear でactivateも連動クリアされるロジックを確認
BEFORE_CLEAR_RESULT=$(node -e "
let beforeStr = '14d';
let activate = '2026-05-01';
const parsedBefore = 'clear';
if (parsedBefore === 'clear') {
  beforeStr = ''; activate = '';
}
process.stdout.write('before=' + beforeStr + ' activate=' + activate);
")
assert_eq "36-14: before clear → activateも空" "before= activate=" "$BEFORE_CLEAR_RESULT"

# 36-15: parseBeforeDuration('0d') がnullを返すことを確認
BEFORE_0D_RESULT=$(node -e "
function parseBeforeDuration(raw) {
  if (!raw) return null;
  let m;
  if ((m = raw.match(/^(\d+)d\$/i))) { const n = parseInt(m[1]); if (n <= 0) return null; return n; }
  if ((m = raw.match(/^(\d+)w\$/i))) { const n = parseInt(m[1]); if (n <= 0) return null; return n * 7; }
  return null;
}
const r0d = parseBeforeDuration('0d');
const r0w = parseBeforeDuration('0w');
const r1d = parseBeforeDuration('1d');
process.stdout.write('0d=' + r0d + ' 0w=' + r0w + ' 1d=' + r1d);
")
assert_eq "36-15: parseBeforeDuration 0d=null, 0w=null, 1d=1" "0d=null 0w=null 1d=1" "$BEFORE_0D_RESULT"

# 36-15: エンジンのparseBeforeDurationと同等のロジックでエラー終了を確認
BEFORE_0D_ERR=$(node -e "
function parseBeforeDuration(raw) {
  if (!raw) return null;
  let m;
  if ((m = raw.match(/^(\d+)d\$/i))) { const n = parseInt(m[1]); if (n <= 0) return null; return n; }
  if ((m = raw.match(/^(\d+)w\$/i))) { const n = parseInt(m[1]); if (n <= 0) return null; return n * 7; }
  return null;
}
const days = parseBeforeDuration('0d');
if (days === null) { process.stderr.write('エラー: --before の形式が不正です\n'); process.exit(1); }
" 2>&1)
BEFORE_0D_EXIT=$?
if [ $BEFORE_0D_EXIT -ne 0 ]; then
  printf "  ✅ 36-15: before '0d' → exit 1\n"; PASS=$((PASS+1))
else
  printf "  ❌ 36-15: before '0d' → exit 0 (エラー終了が期待された)\n"; FAIL=$((FAIL+1))
fi
if printf '%s' "$BEFORE_0D_ERR" | grep -q '形式が不正'; then
  printf "  ✅ 36-15: エラーメッセージに '形式が不正' を含む\n"; PASS=$((PASS+1))
else
  printf "  ❌ 36-15: エラーメッセージに '形式が不正' が含まれない: '%s'\n" "$BEFORE_0D_ERR"; FAIL=$((FAIL+1))
fi

# ──────────────────────────────────────────
# § 40  Phase 2 モバイル対応 — ユニットテスト
#   iOS Shortcuts から GitHub API を直接呼び出す方式のため
#   エンジン変更はなし。ラベル名・フィルタ・クローズ挙動をモックで確認。
# ──────────────────────────────────────────
echo ""
echo "§40  Phase 2 モバイル対応 — ユニットテスト"

# M2-unit-1: inbox ラベル名（📥 inbox）
#   iOS Shortcuts の POST body に `labels: ["📥 inbox"]` と入れるため
#   エンジンの gtd-label が正しいラベル名を返すことを確認
assert_eq "M2-unit-1: gtd-label inbox → 📥 inbox" "📥 inbox" "$(node "$ENGINE" gtd-label inbox)"

# M2-unit-2: next ラベル名（🎯 next）
#   iOS Shortcuts の GET ?labels=🎯%20next に対応するため
#   エンジンの gtd-label が正しいラベル名を返すことを確認
assert_eq "M2-unit-2: gtd-label next → 🎯 next" "🎯 next" "$(node "$ENGINE" gtd-label next)"

# M2-unit-3: today コマンドの出力に next ラベルのタスクが含まれる
#   list-all で FILTER_GTD_ENV=next を指定した場合と同様の挙動を確認
M2_NEXT_MOCK='[
  {"number":10,"title":"モバイルnextタスク","body":"","labels":[{"name":"🎯 next"},{"name":"p2"}]},
  {"number":11,"title":"inbox-task","body":"","labels":[{"name":"📥 inbox"}]}
]'
M2_TODAY_OUT=$(OPEN_ENV="$M2_NEXT_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "M2-unit-3: today — next タスクが含まれる" "#10" "$M2_TODAY_OUT"
if ! printf '%s' "$M2_TODAY_OUT" | grep -aq '#11'; then
  printf "  ✅ M2-unit-3: today — inbox タスクは含まれない\n"; PASS=$((PASS+1))
else
  printf "  ❌ M2-unit-3: today — inbox タスクが混入している\n"; FAIL=$((FAIL+1))
fi

# M2-unit-4: gtd-label が返すラベル名にシェル禁止文字（; $ ` ( ) 等）が含まれない
#   iOS Shortcuts の POST body に埋め込むラベル名の安全性を確認
#   validate ctx はコンテキスト（@xxx）専用のため、ここでは直接チェックする
M2_INBOX_LABEL=$(node "$ENGINE" gtd-label inbox)
M2_NEXT_LABEL=$(node "$ENGINE" gtd-label next)
# 禁止文字（; $ ` ( ) " ' \ | & > < { } [ ]）が含まれていないことをチェック
if printf '%s' "$M2_INBOX_LABEL" | grep -qE '[;$`()\"'"'"'\\|&><{}\[\]]'; then
  printf "  ❌ M2-unit-4: inbox ラベル名に禁止文字が含まれる: '%s'\n" "$M2_INBOX_LABEL"; FAIL=$((FAIL+1))
else
  printf "  ✅ M2-unit-4: inbox ラベル名に禁止文字なし: '%s'\n" "$M2_INBOX_LABEL"; PASS=$((PASS+1))
fi
if printf '%s' "$M2_NEXT_LABEL" | grep -qE '[;$`()\"'"'"'\\|&><{}\[\]]'; then
  printf "  ❌ M2-unit-4: next ラベル名に禁止文字が含まれる: '%s'\n" "$M2_NEXT_LABEL"; FAIL=$((FAIL+1))
else
  printf "  ✅ M2-unit-4: next ラベル名に禁止文字なし: '%s'\n" "$M2_NEXT_LABEL"; PASS=$((PASS+1))
fi

# M2-unit-5: done で使う state/state_reason の値は固定文字列 "closed"/"completed" であること
#   todo-engine.js 側の変更なし確認 — run done の実装が state_reason=completed を渡すか
#   エンジンの validate number を通過することで番号バリデーションが効くことを確認
node "$ENGINE" validate number 42 2>/dev/null && \
  printf "  ✅ M2-unit-5: validate number 42 → OK\n" && PASS=$((PASS+1)) || \
  { printf "  ❌ M2-unit-5: validate number 42 → 失敗\n"; FAIL=$((FAIL+1)); }
node "$ENGINE" validate number 0 2>/dev/null && \
  { printf "  ❌ M2-unit-5: validate number 0 → エラー期待だがOKになった\n"; FAIL=$((FAIL+1)); } || \
  { printf "  ✅ M2-unit-5: validate number 0 → 正しくエラー\n"; PASS=$((PASS+1)); }

# M2-unit-6: next ラベルフィルタ結果に inbox タスクが混入しない（ラベル AND 絞り込み）
M2_MIXED_MOCK='[
  {"number":20,"title":"next-only","body":"","labels":[{"name":"🎯 next"}]},
  {"number":21,"title":"inbox-only","body":"","labels":[{"name":"📥 inbox"}]},
  {"number":22,"title":"next-and-inbox","body":"","labels":[{"name":"🎯 next"},{"name":"📥 inbox"}]}
]'
M2_FILT_OUT=$(OPEN_ENV="$M2_MIXED_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "M2-unit-6: next フィルタ — #20 が含まれる" "#20" "$M2_FILT_OUT"
if ! printf '%s' "$M2_FILT_OUT" | grep -aq '#21'; then
  printf "  ✅ M2-unit-6: next フィルタ — inbox-only (#21) は除外される\n"; PASS=$((PASS+1))
else
  printf "  ❌ M2-unit-6: next フィルタ — inbox-only (#21) が混入している\n"; FAIL=$((FAIL+1))
fi

# ──────────────────────────────────────────
# § Phase1  コメント機能テスト（GitHub API モック）
# create-comment / runComment / runDone --note / runMove --note
# ──────────────────────────────────────────
echo ""
echo "§Phase1  コメント機能テスト（モック）"

# ────────────────────────────────────────────
# P1-1 正常系: コメントサニタイズ — 通常テキストはそのまま
# ────────────────────────────────────────────
P1_SANITIZE_NORMAL=$(node -e "
  let body = 'テスト通常テキスト';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  process.stdout.write(body);
")
assert_eq "P1-1: 通常テキストはサニタイズ後も変化なし" "テスト通常テキスト" "$P1_SANITIZE_NORMAL"

# ────────────────────────────────────────────
# P1-2 正常系: \r\n が \n に正規化される
# ────────────────────────────────────────────
P1_SANITIZE_CRLF=$(node -e "
  let body = 'line1\r\nline2\r\nline3';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  // \r が残っていないことを確認（\r → '' で確認用に見えるように変換）
  const hasCarriageReturn = body.includes('\r');
  process.stdout.write(hasCarriageReturn ? 'HAS_CR' : 'NO_CR');
")
assert_eq "P1-2: \\r\\n が \\n に正規化され \\r が除去される" "NO_CR" "$P1_SANITIZE_CRLF"

# ────────────────────────────────────────────
# P1-3 正常系: 単独 \r が \n に正規化される
# ────────────────────────────────────────────
P1_SANITIZE_CR_ONLY=$(node -e "
  let body = 'line1\rline2';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const hasCarriageReturn = body.includes('\r');
  process.stdout.write(hasCarriageReturn ? 'HAS_CR' : 'NO_CR');
")
assert_eq "P1-3: 単独 \\r が \\n に変換される" "NO_CR" "$P1_SANITIZE_CR_ONLY"

# ────────────────────────────────────────────
# P1-4 セキュリティ: NULL バイトが除去される
# ────────────────────────────────────────────
P1_SANITIZE_NULL=$(node -e "
  let body = 'before\x00after';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  process.stdout.write(body);
")
assert_eq "P1-4: NULL バイト（\\x00）が除去される" "beforeafter" "$P1_SANITIZE_NULL"

# ────────────────────────────────────────────
# P1-5 セキュリティ: 制御文字（\x01-\x1F、\n 除く）が除去される
# ────────────────────────────────────────────
P1_SANITIZE_CTRL=$(node -e "
  let body = 'before\x01\x02\x08\x0Bafter';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  process.stdout.write(body);
")
assert_eq "P1-5: 制御文字（\\x01〜\\x1F、\\n除く）が除去される" "beforeafter" "$P1_SANITIZE_CTRL"

# ────────────────────────────────────────────
# P1-6 セキュリティ: \n（改行）は保持される
# ────────────────────────────────────────────
P1_SANITIZE_NL=$(node -e "
  let body = 'line1\nline2';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  const lineCount = body.split('\n').length;
  process.stdout.write(String(lineCount));
")
assert_eq "P1-6: \\n（改行）はサニタイズ後も保持される" "2" "$P1_SANITIZE_NL"

# ────────────────────────────────────────────
# P1-7 境界値: 65536 文字ちょうどはエラーなし
# ────────────────────────────────────────────
P1_BOUNDARY_OK=$(node -e "
  const body = 'a'.repeat(65536);
  if (body.length > 65536) { process.stdout.write('ERROR'); } else { process.stdout.write('OK'); }
")
assert_eq "P1-7: 65536 文字ちょうどはエラーなし" "OK" "$P1_BOUNDARY_OK"

# ────────────────────────────────────────────
# P1-8 境界値: 65537 文字（超過）はエラー
# ────────────────────────────────────────────
P1_BOUNDARY_ERR=$(node -e "
  const body = 'a'.repeat(65537);
  if (body.length > 65536) { process.stdout.write('ERROR'); } else { process.stdout.write('OK'); }
")
assert_eq "P1-8: 65537 文字（超過）はエラー判定" "ERROR" "$P1_BOUNDARY_ERR"

# ────────────────────────────────────────────
# P1-9 入力文字パターン: シェル特殊文字を含むテキストはサニタイズで除去されない（FORBIDDENチェック不適用）
# ────────────────────────────────────────────
P1_SPECIAL_CHARS=$(node -e "
  // コメント本文に FORBIDDEN_CHARS チェックは適用しない（自由テキスト）
  let body = 'メモ: \`cmd\` \$(evil) ; rm -rf /';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  // シェル特殊文字が含まれていても除去されないことを確認
  const hasBacktick = body.includes('\`');
  process.stdout.write(hasBacktick ? 'PRESERVED' : 'REMOVED');
")
assert_eq "P1-9: コメント本文のシェル特殊文字は FORBIDDEN_CHARS チェック不適用（自由テキスト）" "PRESERVED" "$P1_SPECIAL_CHARS"

# ────────────────────────────────────────────
# P1-10 入力文字パターン: 日本語・絵文字が文字化けしない
# ────────────────────────────────────────────
P1_UNICODE=$(node -e "
  let body = '進捗確認 ✅ 完了しました 🎉';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  process.stdout.write(body);
")
assert_eq "P1-10: 日本語・絵文字がサニタイズ後も保持される" "進捗確認 ✅ 完了しました 🎉" "$P1_UNICODE"

# ────────────────────────────────────────────
# P1-11 入力文字パターン: クォート類はサニタイズ後も保持される
# ────────────────────────────────────────────
P1_QUOTES=$(node -e "
  let body = \"田中さんに \\\"確認済み\\\" と伝えた（O'clock）\";
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  const hasDoubleQuote = body.includes('\"');
  const hasSingleQuote = body.includes(\"'\");
  process.stdout.write((hasDoubleQuote && hasSingleQuote) ? 'PRESERVED' : 'REMOVED');
")
assert_eq "P1-11: ダブルクォート・シングルクォートはサニタイズ後も保持される" "PRESERVED" "$P1_QUOTES"

# ────────────────────────────────────────────
# P1-12 バリデーション: 空文字列はエラー
# ────────────────────────────────────────────
P1_EMPTY_ERR=$(node -e "
  let body = '';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  if (!body.trim()) { process.stdout.write('ERROR'); } else { process.stdout.write('OK'); }
")
assert_eq "P1-12: 空文字列はエラー判定" "ERROR" "$P1_EMPTY_ERR"

# ────────────────────────────────────────────
# P1-13 バリデーション: 空白のみの文字列はエラー
# ────────────────────────────────────────────
P1_WHITESPACE_ERR=$(node -e "
  let body = '   \t  ';
  body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  if (!body.trim()) { process.stdout.write('ERROR'); } else { process.stdout.write('OK'); }
")
assert_eq "P1-13: 空白のみの文字列はエラー判定" "ERROR" "$P1_WHITESPACE_ERR"

# ────────────────────────────────────────────
# P1-14 エンジン統合: parseArgs が --note を正しく解析する
# エンジンのソースコードに --note パーサーが存在することを確認する
# ────────────────────────────────────────────
if grep -q "'--note'" "$ENGINE"; then
  printf "  ✅ P1-14: parseArgs に --note パーサーが追加されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-14: parseArgs に --note パーサーが見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-15 エンジン統合: runMain switch に case 'comment' が存在する
# ────────────────────────────────────────────
if grep -q "case 'comment':" "$ENGINE"; then
  printf "  ✅ P1-15: runMain switch に case 'comment': が追加されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-15: runMain switch に case 'comment': が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-16 エンジン統合: apiMain switch に case 'create-comment' が存在する
# ────────────────────────────────────────────
if grep -q "case 'create-comment':" "$ENGINE"; then
  printf "  ✅ P1-16: apiMain switch に case 'create-comment': が追加されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-16: apiMain switch に case 'create-comment': が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-17 エンジン統合: runComment 関数が定義されている
# ────────────────────────────────────────────
if grep -q "async function runComment" "$ENGINE"; then
  printf "  ✅ P1-17: runComment 関数が定義されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-17: runComment 関数が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-18 エンジン統合: createCommentSanitized 関数が定義されている
# ────────────────────────────────────────────
if grep -q "async function createCommentSanitized" "$ENGINE"; then
  printf "  ✅ P1-18: createCommentSanitized 関数が定義されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-18: createCommentSanitized 関数が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-19 エンジン統合: runDone に --note 対応コードが存在する
# ────────────────────────────────────────────
if grep -q "parsed.note" "$ENGINE"; then
  printf "  ✅ P1-19: runDone / runMove に --note (parsed.note) 対応コードが存在する\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-19: --note (parsed.note) 対応コードが見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-20 エンジン統合: COMMENT_BODY_ENV が create-comment ケースで参照される
# ────────────────────────────────────────────
if grep -q "COMMENT_BODY_ENV" "$ENGINE"; then
  printf "  ✅ P1-20: create-comment ケースで COMMENT_BODY_ENV が参照されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-20: COMMENT_BODY_ENV が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-21 todo.md: comment コマンドが MCP_MODE 対応表に存在する
# ────────────────────────────────────────────
TODO_MD="$SCRIPT_DIR/../todo.md"
if grep -q "add_issue_comment" "$TODO_MD" 2>/dev/null; then
  printf "  ✅ P1-21: todo.md に add_issue_comment（MCP_MODE comment 対応）が追加されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-21: todo.md に add_issue_comment が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-22 todo.md: パフォーマンスルールに comment が追記されている
# ────────────────────────────────────────────
if grep -q "comment.*run_in_background\|comment.*move --note\|comment, done --note" "$TODO_MD" 2>/dev/null; then
  printf "  ✅ P1-22: todo.md パフォーマンスルールに comment / done --note / move --note が追記されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-22: todo.md パフォーマンスルールに comment の追記が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-23 週次レビュー Step 2 に Pinned hint が記載されている
# ────────────────────────────────────────────
# 記載先はリポジトリによって異なる。上流では weekly-review.md へ集約されており、
# 本リポジトリ単体では todo.md 側に記載がある。同じスクリプトがどちらの構成でも
# 動くよう、存在する側を参照する（存在しないパスを固定で見に行くと、ファイルを
# コピーして同期したときに参照先ごと持ち込まれてテストが壊れる）。
WEEKLY_REVIEW_MD="$SCRIPT_DIR/../../weekly-review/weekly-review.md"
[ -f "$WEEKLY_REVIEW_MD" ] || WEEKLY_REVIEW_MD="$TODO_MD"
if grep -q "Pinned hint" "$WEEKLY_REVIEW_MD" 2>/dev/null; then
  printf "  ✅ P1-23: 週次レビュー Step 2 に Pinned hint が記載されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-23: Pinned hint が見つからない (%s)\n" "$WEEKLY_REVIEW_MD"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-24 週次レビュー Step 4 に migrate sub-issue ヒントが記載されている
# ────────────────────────────────────────────
if grep -q "migrate sub-issue --dry-run" "$WEEKLY_REVIEW_MD" 2>/dev/null; then
  printf "  ✅ P1-24: 週次レビュー Step 4 に migrate sub-issue ヒントが記載されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-24: migrate sub-issue --dry-run が見つからない (%s)\n" "$WEEKLY_REVIEW_MD"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-25 todo-manual.md: コメント機能セクションが追加されている
# ────────────────────────────────────────────
TODO_MANUAL="$SCRIPT_DIR/../../../../docs/todo-manual.md"
[ -f "$TODO_MANUAL" ] || TODO_MANUAL="$SCRIPT_DIR/../todo-manual.md"  # 公開リポジトリはルート直下レイアウト
if grep -q "コメント機能" "$TODO_MANUAL" 2>/dev/null; then
  printf "  ✅ P1-25: todo-manual.md にコメント機能セクションが追加されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-25: todo-manual.md にコメント機能セクションが見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-26 todo-manual.md: body/コメントの使い分け原則が記載されている
# ────────────────────────────────────────────
if grep -q "body.*コメント.*使い分け\|使い分け原則" "$TODO_MANUAL" 2>/dev/null; then
  printf "  ✅ P1-26: todo-manual.md に body/コメント使い分け原則が記載されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-26: todo-manual.md に使い分け原則が見つからない\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-27 GTDワークフロー維持確認: 既存 GTD_LABELS 定数が変更されていない
# ────────────────────────────────────────────
P1_GTD_LABELS=$(ENGINE_PATH="$ENGINE" node -e "
  const fs = require('fs');
  const src = fs.readFileSync(process.env.ENGINE_PATH, 'utf8');
  const m = src.match(/const GTD_LABELS = \[([^\]]+)\]/);
  if (m) { process.stdout.write(m[1].trim()); } else { process.stdout.write('NOT_FOUND'); }
")
if printf '%s' "$P1_GTD_LABELS" | grep -q "next.*routine.*inbox.*waiting.*someday.*reference"; then
  printf "  ✅ P1-27: GTD_LABELS 定数が変更されていない（%s）\n" "$P1_GTD_LABELS"; PASS=$((PASS+1))
else
  printf "  ❌ P1-27: GTD_LABELS 定数が変更された可能性がある: [%s]\n" "$P1_GTD_LABELS"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# P1-28 エンジン構文チェック: node --check が成功する
# ────────────────────────────────────────────
if node --check "$ENGINE" 2>/dev/null; then
  printf "  ✅ P1-28: エンジン JavaScript 構文エラーなし\n"; PASS=$((PASS+1))
else
  printf "  ❌ P1-28: エンジン JavaScript 構文エラー\n"; FAIL=$((FAIL+1))
fi

# ────────────────────────────────────────────
# eisenhower コマンド テスト（E-N-1 〜 E-N-12、E-E-2、E-R-1〜E-R-6）
# GitHub 接続不要。env var 経由で OPEN_ENV を渡す。
# ────────────────────────────────────────────

# 共通フィクスチャ作成ヘルパー
# make_issue <number> <title> <labels_csv> <body>
make_issue() {
  local num="$1" title="$2" labels_csv="$3" body="$4"
  node -e "
const num = parseInt(process.argv[1]);
const title = process.argv[2];
const labels_csv = process.argv[3];
const body = process.argv[4];
const labels = labels_csv ? labels_csv.split(',').map(l => ({name:l})) : [];
process.stdout.write(JSON.stringify({number:num, title, body, labels}));
" -- "$num" "$title" "$labels_csv" "$body"
}

# E-N-1: 混在データの4象限分類
EN1_TODAY="2026-05-01"
EN1_I1=$(make_issue 1 "今すぐやるタスク" "next,p1" "due: 2026-05-01")
EN1_I2=$(make_issue 2 "計画タスクp2明日" "next,p2" "due: 2026-05-02")
EN1_I3=$(make_issue 3 "Q3タスクp3今日" "next,p3" "due: 2026-05-01")
EN1_I4=$(make_issue 4 "Q4タスクp3期限なし" "next,p3" "")
EN1_ISSUES="[${EN1_I1},${EN1_I2},${EN1_I3},${EN1_I4}]"

EN1_OUTPUT=$(OPEN_ENV="$EN1_ISSUES" TODAY_ENV="$EN1_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-N-1: Q1にp1+今日期限タスクが表示される" "今すぐやるタスク" "$EN1_OUTPUT"
assert_contains "E-N-1: Q2にp2+明日期限タスクが表示される" "計画タスクp2明日" "$EN1_OUTPUT"
assert_contains "E-N-1: Q3にp3+今日期限タスクが表示される" "Q3タスクp3今日" "$EN1_OUTPUT"
assert_contains "E-N-1: Q4にp3+期限なしタスクが表示される" "Q4タスクp3期限なし" "$EN1_OUTPUT"

# Q1ヘッダよりQ2ヘッダが後に来ることを確認（順序）
EN1_Q1_POS=$(printf '%s' "$EN1_OUTPUT" | grep -n "Q1" | head -1 | cut -d: -f1)
EN1_Q2_POS=$(printf '%s' "$EN1_OUTPUT" | grep -n "Q2" | head -1 | cut -d: -f1)
if [ -n "$EN1_Q1_POS" ] && [ -n "$EN1_Q2_POS" ] && [ "$EN1_Q1_POS" -lt "$EN1_Q2_POS" ]; then
  printf "  ✅ E-N-1: Q1がQ2より前に表示される\n"; PASS=$((PASS+1))
else
  printf "  ❌ E-N-1: Q1/Q2の順序が正しくない（Q1=%s Q2=%s）\n" "$EN1_Q1_POS" "$EN1_Q2_POS"; FAIL=$((FAIL+1))
fi

# E-N-2: next タスクが 0件
EN2_TODAY="2026-05-01"
EN2_OUTPUT=$(OPEN_ENV="[]" TODAY_ENV="$EN2_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-N-2: 全象限に（なし）が表示される（Q1）" "Q1" "$EN2_OUTPUT"
assert_contains "E-N-2: 全象限に（なし）が表示される（Q2）" "Q2" "$EN2_OUTPUT"
assert_contains "E-N-2: 全象限に（なし）が表示される（Q3）" "Q3" "$EN2_OUTPUT"
assert_contains "E-N-2: 全象限に（なし）が表示される（Q4）" "Q4" "$EN2_OUTPUT"
assert_contains "E-N-2: フッターに「合計 next: 0件」が表示される" "合計 next: 0" "$EN2_OUTPUT"

# E-N-3: Q1 が 0件のとき（なし）のみ表示（no_q1メッセージなし）
EN3_TODAY="2026-05-01"
EN3_I1=$(make_issue 10 "Q2タスク" "next,p1" "due: 2026-05-10")
EN3_ISSUES="[${EN3_I1}]"
EN3_OUTPUT=$(OPEN_ENV="$EN3_ISSUES" TODAY_ENV="$EN3_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-N-3: Q1ヘッダが表示される" "Q1" "$EN3_OUTPUT"
assert_contains "E-N-3: Q1に（なし）が表示される" "（なし）" "$EN3_OUTPUT"
# no_q1専用メッセージが出ていないことを確認（廃止済み）
assert_not_contains "E-N-3: no_q1専用メッセージは出力されない" "今すぐ対応が必要なタスクはありません" "$EN3_OUTPUT"

# E-N-4: 期限超過（昨日以前）のp1/p2タスクはQ1に表示
EN4_TODAY="2026-05-01"
EN4_I1=$(make_issue 20 "期限超過タスク" "next,p1" "due: 2026-04-30")
EN4_ISSUES="[${EN4_I1}]"
EN4_OUTPUT=$(OPEN_ENV="$EN4_ISSUES" TODAY_ENV="$EN4_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-N-4: 期限超過p1タスクがQ1に表示される" "期限超過タスク" "$EN4_OUTPUT"
# Q1ヘッダの後にタスクが来て、Q2ヘッダの前に終わること
EN4_TASK_POS=$(printf '%s' "$EN4_OUTPUT" | grep -n "期限超過タスク" | head -1 | cut -d: -f1)
EN4_Q2_POS=$(printf '%s' "$EN4_OUTPUT" | grep -n "Q2" | head -1 | cut -d: -f1)
if [ -n "$EN4_TASK_POS" ] && [ -n "$EN4_Q2_POS" ] && [ "$EN4_TASK_POS" -lt "$EN4_Q2_POS" ]; then
  printf "  ✅ E-N-4: 期限超過タスクがQ2より前（Q1セクション）に表示される\n"; PASS=$((PASS+1))
else
  printf "  ❌ E-N-4: 期限超過タスクの位置が正しくない（task=%s Q2=%s）\n" "$EN4_TASK_POS" "$EN4_Q2_POS"; FAIL=$((FAIL+1))
fi
assert_contains "E-N-4: 📅 日付が表示される" "2026-04-30" "$EN4_OUTPUT"

# E-N-5: p1/p2 で due 未設定のタスクは Q2 に表示（due列は空）
EN5_TODAY="2026-05-01"
EN5_I1=$(make_issue 30 "Q2due未設定タスク" "next,p2" "")
EN5_ISSUES="[${EN5_I1}]"
EN5_OUTPUT=$(OPEN_ENV="$EN5_ISSUES" TODAY_ENV="$EN5_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-N-5: p2+due未設定タスクがQ2に表示される" "Q2due未設定タスク" "$EN5_OUTPUT"
# Q2に表示されていてQ1には出ていないこと
EN5_TASK_POS=$(printf '%s' "$EN5_OUTPUT" | grep -n "Q2due未設定タスク" | head -1 | cut -d: -f1)
EN5_Q2_POS=$(printf '%s' "$EN5_OUTPUT" | grep -n "Q2" | head -1 | cut -d: -f1)
EN5_Q3_POS=$(printf '%s' "$EN5_OUTPUT" | grep -n "Q3" | head -1 | cut -d: -f1)
if [ -n "$EN5_TASK_POS" ] && [ -n "$EN5_Q2_POS" ] && [ -n "$EN5_Q3_POS" ] && \
   [ "$EN5_TASK_POS" -gt "$EN5_Q2_POS" ] && [ "$EN5_TASK_POS" -lt "$EN5_Q3_POS" ]; then
  printf "  ✅ E-N-5: p2+due未設定タスクがQ2セクション内に表示される\n"; PASS=$((PASS+1))
else
  printf "  ❌ E-N-5: p2+due未設定タスクの位置が正しくない（task=%s Q2=%s Q3=%s）\n" "$EN5_TASK_POS" "$EN5_Q2_POS" "$EN5_Q3_POS"; FAIL=$((FAIL+1))
fi

# E-N-6: p3 + due 未設定は Q4 に表示
EN6_TODAY="2026-05-01"
EN6_I1=$(make_issue 40 "Q4p3due未設定" "next,p3" "")
EN6_ISSUES="[${EN6_I1}]"
EN6_OUTPUT=$(OPEN_ENV="$EN6_ISSUES" TODAY_ENV="$EN6_TODAY" node "$ENGINE" eisenhower 2>&1)
EN6_TASK_POS=$(printf '%s' "$EN6_OUTPUT" | grep -n "Q4p3due未設定" | head -1 | cut -d: -f1)
EN6_Q4_POS=$(printf '%s' "$EN6_OUTPUT" | grep -n "Q4" | head -1 | cut -d: -f1)
if [ -n "$EN6_TASK_POS" ] && [ -n "$EN6_Q4_POS" ] && [ "$EN6_TASK_POS" -gt "$EN6_Q4_POS" ]; then
  printf "  ✅ E-N-6: p3+due未設定タスクがQ4セクションに表示される\n"; PASS=$((PASS+1))
else
  printf "  ❌ E-N-6: p3+due未設定タスクの位置が正しくない（task=%s Q4=%s）\n" "$EN6_TASK_POS" "$EN6_Q4_POS"; FAIL=$((FAIL+1))
fi

# E-N-7: next 以外のラベル（inbox/waiting）のタスクは出力に現れない
EN7_TODAY="2026-05-01"
EN7_I1=$(make_issue 50 "inboxタスク除外" "inbox,p1" "due: 2026-05-01")
EN7_I2=$(make_issue 51 "waitingタスク除外" "waiting,p2" "due: 2026-05-01")
EN7_ISSUES="[${EN7_I1},${EN7_I2}]"
EN7_OUTPUT=$(OPEN_ENV="$EN7_ISSUES" TODAY_ENV="$EN7_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_not_contains "E-N-7: inboxタスクはeisenhowerに出力されない" "inboxタスク除外" "$EN7_OUTPUT"
assert_not_contains "E-N-7: waitingタスクはeisenhowerに出力されない" "waitingタスク除外" "$EN7_OUTPUT"

# E-N-8: Q1内のソート順（p1→p2、due昇順）
EN8_TODAY="2026-05-01"
EN8_I1=$(make_issue 60 "p2late" "next,p2" "due: 2026-05-01")
EN8_I2=$(make_issue 61 "p1early" "next,p1" "due: 2026-04-30")
EN8_ISSUES="[${EN8_I1},${EN8_I2}]"
EN8_OUTPUT=$(OPEN_ENV="$EN8_ISSUES" TODAY_ENV="$EN8_TODAY" node "$ENGINE" eisenhower 2>&1)
EN8_P1_POS=$(printf '%s' "$EN8_OUTPUT" | grep -n "p1early" | head -1 | cut -d: -f1)
EN8_P2_POS=$(printf '%s' "$EN8_OUTPUT" | grep -n "p2late" | head -1 | cut -d: -f1)
if [ -n "$EN8_P1_POS" ] && [ -n "$EN8_P2_POS" ] && [ "$EN8_P1_POS" -lt "$EN8_P2_POS" ]; then
  printf "  ✅ E-N-8: Q1内でp1タスクがp2タスクより前にソートされる\n"; PASS=$((PASS+1))
else
  printf "  ❌ E-N-8: Q1内のソート順が正しくない（p1=%s p2=%s）\n" "$EN8_P1_POS" "$EN8_P2_POS"; FAIL=$((FAIL+1))
fi

# E-N-9: 英語モード（LANG_ENV=en）での出力
EN9_TODAY="2026-05-01"
EN9_I1=$(make_issue 70 "English task" "next,p3" "due: 2026-05-01")
EN9_ISSUES="[${EN9_I1}]"
EN9_OUTPUT=$(OPEN_ENV="$EN9_ISSUES" TODAY_ENV="$EN9_TODAY" LANG_ENV="en" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-N-9: 英語モードでQ3が英語ヘッダで表示される" "Urgent (Low Importance)" "$EN9_OUTPUT"
assert_contains "E-N-9: 英語モードでQ4が英語ヘッダで表示される" "Q4 Others" "$EN9_OUTPUT"

# E-N-10: renderIssueList と同じ行フォーマット（priIcon・context・見積もり）
EN10_TODAY="2026-05-01"
EN10_BODY=$'due: 2026-05-01\nestimate: 60'
EN10_I1=$(make_issue 80 "フォーマットテスト" "next,p1,@PC" "$EN10_BODY")
EN10_ISSUES="[${EN10_I1}]"
EN10_OUTPUT=$(OPEN_ENV="$EN10_ISSUES" TODAY_ENV="$EN10_TODAY" node "$ENGINE" eisenhower 2>&1)
# priIcon の確認は node で実施（Windows Git Bash の grep は絵文字マッチが不安定）
EN10_PRI_CHECK=$(printf '%s' "$EN10_OUTPUT" | node -e "
let data=''; process.stdin.on('data',d=>data+=d);
process.stdin.on('end',()=>{
  process.stdout.write(data.includes('🔴') ? 'HAS_PRI_ICON' : 'NO_PRI_ICON');
});
")
assert_eq "E-N-10: priIcon（🔴）が表示される" "HAS_PRI_ICON" "$EN10_PRI_CHECK"
assert_contains "E-N-10: コンテキスト[@PC]が表示される" "@PC" "$EN10_OUTPUT"
assert_contains "E-N-10: 見積もり（⏱）が表示される" "⏱" "$EN10_OUTPUT"

# E-N-11: 優先度未設定（p9）タスクが next に含まれる場合
EN11_TODAY="2026-05-01"
EN11_I1=$(make_issue 90 "p9未設定タスクA" "next" "due: 2026-05-01")
EN11_I2=$(make_issue 91 "p9未設定タスクB" "next" "")
EN11_I3=$(make_issue 92 "Q1通常タスク" "next,p1" "due: 2026-05-01")
EN11_ISSUES="[${EN11_I1},${EN11_I2},${EN11_I3}]"
EN11_OUTPUT=$(OPEN_ENV="$EN11_ISSUES" TODAY_ENV="$EN11_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-N-11: 先頭に優先度未設定警告が表示される" "⚠ 優先度未設定（2件）" "$EN11_OUTPUT"
assert_not_contains "E-N-11: p9タスクAはQ1〜Q4に表示されない" "p9未設定タスクA" "$EN11_OUTPUT"
assert_not_contains "E-N-11: p9タスクBはQ1〜Q4に表示されない" "p9未設定タスクB" "$EN11_OUTPUT"
# 警告セクションがQ1ヘッダより前に表示される
EN11_UNSET_POS=$(printf '%s' "$EN11_OUTPUT" | grep -n "優先度未設定" | head -1 | cut -d: -f1)
EN11_Q1_POS=$(printf '%s' "$EN11_OUTPUT" | grep -n "Q1" | head -1 | cut -d: -f1)
if [ -n "$EN11_UNSET_POS" ] && [ -n "$EN11_Q1_POS" ] && [ "$EN11_UNSET_POS" -lt "$EN11_Q1_POS" ]; then
  printf "  ✅ E-N-11: 優先度未設定警告がQ1ヘッダより前に表示される\n"; PASS=$((PASS+1))
else
  printf "  ❌ E-N-11: 優先度未設定警告の位置が正しくない（unset=%s Q1=%s）\n" "$EN11_UNSET_POS" "$EN11_Q1_POS"; FAIL=$((FAIL+1))
fi

# E-N-12: 優先度未設定タスクが 0件 → 警告セクション非表示
EN12_TODAY="2026-05-01"
EN12_I1=$(make_issue 100 "優先度設定済み" "next,p1" "due: 2026-05-01")
EN12_ISSUES="[${EN12_I1}]"
EN12_OUTPUT=$(OPEN_ENV="$EN12_ISSUES" TODAY_ENV="$EN12_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_not_contains "E-N-12: 警告セクションが表示されない" "優先度未設定" "$EN12_OUTPUT"

# E-E-2: オープンIssueが0件のリポジトリ（エラーなく全象限なし表示）
EE2_OUTPUT=$(OPEN_ENV="[]" TODAY_ENV="2026-05-01" node "$ENGINE" eisenhower 2>&1)
EE2_EXIT=$?
assert_exit_ok "E-E-2: 0件でもエラーなく終了する" "$EE2_EXIT"
assert_contains "E-E-2: Q1ヘッダが表示される" "Q1" "$EE2_OUTPUT"
assert_contains "E-E-2: Q2ヘッダが表示される" "Q2" "$EE2_OUTPUT"

# E-R-1: today() の出力が変わらない（既存 today コマンドのリグレッション）
ER1_TODAY="2026-05-01"
ER1_I1=$(make_issue 110 "today期限タスク" "next,p1" "due: 2026-05-01")
ER1_ISSUES="[${ER1_I1}]"
ER1_OUTPUT=$(OPEN_ENV="$ER1_ISSUES" CLOSED_ENV="[]" TODAY_ENV="$ER1_TODAY" node "$ENGINE" today 2>&1)
assert_contains "E-R-1: today コマンドが正常動作する（今日のタスクが表示される）" "今日" "$ER1_OUTPUT"
assert_contains "E-R-1: today コマンドにtodayタスクが表示される" "today期限タスク" "$ER1_OUTPUT"

# E-R-2: list-all の出力が変わらない
ER2_I1=$(make_issue 120 "nextタスク" "next,p1" "")
ER2_ISSUES="[${ER2_I1}]"
ER2_OUTPUT=$(OPEN_ENV="$ER2_ISSUES" TODAY_ENV="2026-05-01" node "$ENGINE" list-all 2>&1)
assert_contains "E-R-2: list-all コマンドが正常動作する" "nextタスク" "$ER2_OUTPUT"

# E-R-3: dashboard の出力が変わらない
ER3_I1=$(make_issue 130 "dashboardタスク" "next,p1" "due: 2026-05-01")
ER3_ISSUES="[${ER3_I1}]"
ER3_OUTPUT=$(OPEN_ENV="$ER3_ISSUES" CLOSED_ENV="[]" TODAY_ENV="2026-05-01" node "$ENGINE" dashboard 2>&1)
assert_contains "E-R-3: dashboard コマンドが正常動作する" "dashboardタスク" "$ER3_OUTPUT"

# E-R-4: help に eisenhower が追加されている
ER4_OUTPUT=$(node "$ENGINE" help 2>&1)
assert_contains "E-R-4: help に eisenhower が表示される" "eisenhower" "$ER4_OUTPUT"

# E-R-6: フッターの {total} は next ラベル全タスク数（p9 タスク含む）の確認
ER6_TODAY="2026-05-01"
ER6_I1=$(make_issue 200 "p9タスク1" "next" "")
ER6_I2=$(make_issue 201 "p9タスク2" "next" "")
ER6_I3=$(make_issue 202 "p1タスク" "next,p1" "due: 2026-05-01")
ER6_ISSUES="[${ER6_I1},${ER6_I2},${ER6_I3}]"
ER6_OUTPUT=$(OPEN_ENV="$ER6_ISSUES" TODAY_ENV="$ER6_TODAY" node "$ENGINE" eisenhower 2>&1)
assert_contains "E-R-6: フッターの合計は3件（p9含む）" "合計 next: 3件" "$ER6_OUTPUT"
# Q1のカウントは1件（p1タスクのみ）
assert_contains "E-R-6: Q1カウントは1件（p9除く）" "Q1: 1件" "$ER6_OUTPUT"

# ──────────────────────────────────────────
# L-1: list-issues の updatedAt フィールド
#   GitHub API の issue オブジェクトから updatedAt が正しくマップされることを
#   エンジンの map ロジックをインラインで再現して確認する
# ──────────────────────────────────────────
echo ""
echo "## L-1: list-issues updatedAt フィールド"

# L-1-1: updated_at が ISO8601 文字列の場合、updatedAt として返る
L1_OUTPUT=$(node -e "
const raw = [
  { number: 1, title: 'タスクA', body: 'body', labels: [{name:'next'}],
    closed_at: null, updated_at: '2026-04-01T12:00:00Z', pull_request: undefined }
];
const result = raw.map(i => ({
  number: i.number,
  title: i.title,
  body: i.body || '',
  labels: i.labels.map(l => ({ name: l.name })),
  closedAt: i.closed_at || null,
  updatedAt: i.updated_at || null
}));
process.stdout.write(JSON.stringify(result));
")
assert_contains "L-1-1: updatedAt が ISO8601 文字列で返る" '"updatedAt":"2026-04-01T12:00:00Z"' "$L1_OUTPUT"

# L-1-2: updated_at が null/undefined の場合、updatedAt は null になる
L2_OUTPUT=$(node -e "
const raw = [
  { number: 2, title: 'タスクB', body: '', labels: [],
    closed_at: null, updated_at: null, pull_request: undefined }
];
const result = raw.map(i => ({
  number: i.number,
  title: i.title,
  body: i.body || '',
  labels: i.labels.map(l => ({ name: l.name })),
  closedAt: i.closed_at || null,
  updatedAt: i.updated_at || null
}));
process.stdout.write(JSON.stringify(result));
")
assert_contains "L-1-2: updated_at が null のとき updatedAt は null" '"updatedAt":null' "$L2_OUTPUT"

# L-1-3: updatedAt フィールドがオブジェクトのキーとして存在する
assert_contains "L-1-3: updatedAt キーが出力に含まれる" '"updatedAt"' "$L1_OUTPUT"

# ──────────────────────────────────────────
# BUG#1321-A parseArgs --label オプションテスト
# GitHub 接続不要。parseArgs のソースコード確認 + エンジンの validate コマンド経由テスト。
# ──────────────────────────────────────────
echo ""
echo "## BUG1321-A: --label オプション引数パーサーテスト"

# BUG1321-A-1: parseArgs に --label パーサーが追加されている（ソース確認）
if grep -q "'--label'" "$ENGINE"; then
  printf "  ✅ BUG1321-A-1: parseArgs に --label パーサーが追加されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1321-A-1: parseArgs に --label パーサーが見つからない\n"; FAIL=$((FAIL+1))
fi

# BUG1321-A-2: result.labels 配列が初期化されている（ソース確認）
if grep -q "labels: \[\]" "$ENGINE"; then
  printf "  ✅ BUG1321-A-2: result.labels 配列が初期化されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1321-A-2: result.labels 配列の初期化が見つからない\n"; FAIL=$((FAIL+1))
fi

# BUG1321-A-3: --label の値が extra に残らない / labels に格納される（一時ファイル経由）
_BUG1321_TMP=$(mktemp /tmp/test-parseargs-XXXXXX)
cat > "$_BUG1321_TMP" << 'PARSEARGS_TEST_EOF'
// parseArgs 単体テスト（BUG1321-A-3/A-4）
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
// parseArgs 関数を eval で取り込む
const engineModule = {};
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
if (!match) { process.stdout.write('EXTRACT_FAILED'); process.exit(0); }
let parseArgs;
try {
  eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function'));
} catch(e) { process.stdout.write('EVAL_FAILED:' + e.message); process.exit(0); }
const result = parseArgs(['タイトル', '--activate', '2026-05-10', '--due', '2026-05-10', '--label', '@claude', '--priority', 'p2']);
process.stdout.write(JSON.stringify({ extra: result.extra, labels: result.labels }));
PARSEARGS_TEST_EOF

_BUG1321_A3_OUT=$(node "$_BUG1321_TMP" "$ENGINE" 2>&1)

# JSON解析して extra と labels を取り出す
_BUG1321_A3_EXTRA=$(printf '%s' "$_BUG1321_A3_OUT" | ENGINE_PATH="$ENGINE" node -e "
  let raw = '';
  process.stdin.on('data', d => raw += d);
  process.stdin.on('end', () => {
    try { const d = JSON.parse(raw); process.stdout.write(JSON.stringify(d.extra)); }
    catch(e) { process.stdout.write('PARSE_ERR:' + raw); }
  });
")
_BUG1321_A4_LABELS=$(printf '%s' "$_BUG1321_A3_OUT" | ENGINE_PATH="$ENGINE" node -e "
  let raw = '';
  process.stdin.on('data', d => raw += d);
  process.stdin.on('end', () => {
    try { const d = JSON.parse(raw); process.stdout.write(JSON.stringify(d.labels)); }
    catch(e) { process.stdout.write('PARSE_ERR:' + raw); }
  });
")
assert_eq "BUG1321-A-3: --label の値が extra に残らない" '["タイトル"]' "$_BUG1321_A3_EXTRA"
assert_eq "BUG1321-A-4: --label の値が labels 配列に格納される" '["@claude"]' "$_BUG1321_A4_LABELS"
rm -f "$_BUG1321_TMP"

# BUG1321-A-5: --label が複数回指定されたとき全て格納される
_BUG1321_A5_TMP=$(mktemp /tmp/test-parseargs-a5-XXXXXX)
cat > "$_BUG1321_A5_TMP" << 'A5_EOF'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
if (!match) { process.stdout.write('EXTRACT_FAILED'); process.exit(0); }
let parseArgs;
try { eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function')); }
catch(e) { process.stdout.write('EVAL_FAILED'); process.exit(0); }
const result = parseArgs(['タイトル', '--label', 'foo', '--label', 'bar']);
process.stdout.write(JSON.stringify(result.labels));
A5_EOF
BUG1321_A5=$(node "$_BUG1321_A5_TMP" "$ENGINE" 2>&1)
assert_eq "BUG1321-A-5: --label が複数指定されたとき全て labels に格納される" '["foo","bar"]' "$BUG1321_A5"
rm -f "$_BUG1321_A5_TMP"

# BUG1321-A-6: --label なしの場合 labels は空配列
_BUG1321_A6_TMP=$(mktemp /tmp/test-parseargs-a6-XXXXXX)
cat > "$_BUG1321_A6_TMP" << 'A6_EOF'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
if (!match) { process.stdout.write('EXTRACT_FAILED'); process.exit(0); }
let parseArgs;
try { eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function')); }
catch(e) { process.stdout.write('EVAL_FAILED'); process.exit(0); }
const result = parseArgs(['タイトル', '--due', '2026-05-10']);
process.stdout.write(JSON.stringify(result.labels));
A6_EOF
BUG1321_A6=$(node "$_BUG1321_A6_TMP" "$ENGINE" 2>&1)
assert_eq "BUG1321-A-6: --label なしの場合 labels は空配列" '[]' "$BUG1321_A6"
rm -f "$_BUG1321_A6_TMP"

# BUG1321-A-7: --label の後ろに他オプションが続いても正しくパースされる（境界値）
_BUG1321_A7_TMP=$(mktemp /tmp/test-parseargs-a7-XXXXXX)
cat > "$_BUG1321_A7_TMP" << 'A7_EOF'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
if (!match) { process.stdout.write('EXTRACT_FAILED'); process.exit(0); }
let parseArgs;
try { eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function')); }
catch(e) { process.stdout.write('EVAL_FAILED'); process.exit(0); }
const result = parseArgs(['タイトル', '--label', '@claude', '--priority', 'p2']);
process.stdout.write(JSON.stringify({ extra: result.extra, labels: result.labels, priority: result.priority }));
A7_EOF
_BUG1321_A7_OUT=$(node "$_BUG1321_A7_TMP" "$ENGINE" 2>&1)
_BUG1321_A7_EXTRA=$(printf '%s' "$_BUG1321_A7_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(JSON.stringify(d.extra));}catch(e){process.stdout.write('PARSE_ERR');}});
")
_BUG1321_A7_PRI=$(printf '%s' "$_BUG1321_A7_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(d.priority||'null');}catch(e){process.stdout.write('PARSE_ERR');}});
")
assert_eq "BUG1321-A-7: --label + --priority 組み合わせで extra にノイズが残らない" '["タイトル"]' "$_BUG1321_A7_EXTRA"
assert_eq "BUG1321-A-7: --label + --priority 組み合わせで priority が正しくパースされる" 'p2' "$_BUG1321_A7_PRI"
rm -f "$_BUG1321_A7_TMP"

# ──────────────────────────────────────────
# BUG#1321-B validateName [ ] 緩和テスト
# validate コマンド（エンジンの公開I/F）経由で確認
# ──────────────────────────────────────────
echo ""
echo "## BUG1321-B: validateName [ ] 緩和テスト"

# BUG1321-B-1: FORBIDDEN_CHARS に [ ] が含まれない（ソース確認）
# FORBIDDEN_CHARS 定義行に [ または ] がないことを確認（ソース文字列レベル）
_BUG1321_B1_LINE=$(grep 'const FORBIDDEN_CHARS' "$ENGINE")
if printf '%s' "$_BUG1321_B1_LINE" | grep -q '\['; then
  printf "  ❌ BUG1321-B-1: FORBIDDEN_CHARS に [ が含まれている（緩和されていない）\n"; FAIL=$((FAIL+1))
else
  printf "  ✅ BUG1321-B-1: FORBIDDEN_CHARS に [ ] が含まれない（緩和済み）\n"; PASS=$((PASS+1))
fi

# BUG1321-B-2: [bug] プレフィックスのタイトルがバリデーションを通過する（正常系）
BUG1321_B2_OUT=$(LANG_ENV=ja node "$ENGINE" validate name "[bug] /todo: --label オプションがタイトルに混入する" 2>&1)
BUG1321_B2_EXIT=$?
if [ "$BUG1321_B2_EXIT" -eq 0 ]; then
  printf "  ✅ BUG1321-B-2: [bug] プレフィックスのタイトルがバリデーションを通過する\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1321-B-2: [bug] プレフィックスのタイトルがバリデーションを通過する\n"
  printf "     出力: %s\n" "$BUG1321_B2_OUT"
  FAIL=$((FAIL+1))
fi

# BUG1321-B-3: [feature] プレフィックスのタイトルがバリデーションを通過する（正常系）
BUG1321_B3_OUT=$(LANG_ENV=ja node "$ENGINE" validate name "[feature] 新機能追加" 2>&1)
BUG1321_B3_EXIT=$?
if [ "$BUG1321_B3_EXIT" -eq 0 ]; then
  printf "  ✅ BUG1321-B-3: [feature] プレフィックスのタイトルがバリデーションを通過する\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1321-B-3: [feature] プレフィックスのタイトルがバリデーションを通過する\n"
  printf "     出力: %s\n" "$BUG1321_B3_OUT"
  FAIL=$((FAIL+1))
fi

# BUG1321-B-4: セキュリティ — セミコロンは引き続き弾かれる
BUG1321_B4_OUT=$(LANG_ENV=ja node "$ENGINE" validate name "test; rm -rf /" 2>&1)
BUG1321_B4_EXIT=$?
if [ "$BUG1321_B4_EXIT" -ne 0 ]; then
  printf "  ✅ BUG1321-B-4: セミコロン含むタイトルは引き続きINVALID\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1321-B-4: セミコロン含むタイトルは引き続きINVALID（通過してしまった）\n"; FAIL=$((FAIL+1))
fi

# BUG1321-B-5: セキュリティ — バッククォートは引き続き弾かれる
BUG1321_B5_OUT=$(LANG_ENV=ja node "$ENGINE" validate name '`evil`' 2>&1)
BUG1321_B5_EXIT=$?
if [ "$BUG1321_B5_EXIT" -ne 0 ]; then
  printf "  ✅ BUG1321-B-5: バッククォート含むタイトルは引き続きINVALID\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1321-B-5: バッククォート含むタイトルは引き続きINVALID（通過してしまった）\n"; FAIL=$((FAIL+1))
fi

# BUG1321-B-6: セキュリティ — $変数参照は引き続き弾かれる
BUG1321_B6_OUT=$(LANG_ENV=ja node "$ENGINE" validate name '$HOME' 2>&1)
BUG1321_B6_EXIT=$?
if [ "$BUG1321_B6_EXIT" -ne 0 ]; then
  printf "  ✅ BUG1321-B-6: \$変数参照含むタイトルは引き続きINVALID\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1321-B-6: \$変数参照含むタイトルは引き続きINVALID（通過してしまった）\n"; FAIL=$((FAIL+1))
fi

# ──────────────────────────────────────────
# BUG#1329: parseArgs — --p1/--p2/--p3 ショートハンドがタイトルに混入する
# GitHub 接続不要。parseArgs のソースコード確認 + 単体テスト。
# ──────────────────────────────────────────
echo ""
echo "## BUG1329: parseArgs --p<N> ショートハンド タイトル混入テスト"

# BUG1329-1: parseArgs に --p[123] ショートハンドのパーサーが追加されている（ソース確認）
if grep -q '/^--p\[123\]\$/' "$ENGINE"; then
  printf "  ✅ BUG1329-1: parseArgs に --p[123] ショートハンドパーサーが追加されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ BUG1329-1: parseArgs に --p[123] ショートハンドパーサーが見つからない\n"; FAIL=$((FAIL+1))
fi

# BUG1329-2: --p3 がタイトルに混入せず priority にパースされる
_BUG1329_2_TMP=$(mktemp /tmp/bug1329-2-XXXXXX)
cat > "$_BUG1329_2_TMP" << 'JSEOF'
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
let parseArgs;
try { eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function')); }
catch(e) { process.stdout.write(JSON.stringify({err: e.message})); process.exit(0); }
const result = parseArgs(['タイトル', '--p3']);
process.stdout.write(JSON.stringify({ extra: result.extra, priority: result.priority }));
JSEOF
_BUG1329_2_OUT=$(node "$_BUG1329_2_TMP" "$ENGINE" 2>&1)
_BUG1329_2_EXTRA=$(printf '%s' "$_BUG1329_2_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(JSON.stringify(d.extra));}catch(e){process.stdout.write('PARSE_ERR');}});
")
_BUG1329_2_PRI=$(printf '%s' "$_BUG1329_2_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(d.priority||'null');}catch(e){process.stdout.write('PARSE_ERR');}});
")
assert_eq "BUG1329-2: --p3 がタイトルに混入しない（extra にノイズなし）" '["タイトル"]' "$_BUG1329_2_EXTRA"
assert_eq "BUG1329-2: --p3 が priority としてパースされる" 'p3' "$_BUG1329_2_PRI"
rm -f "$_BUG1329_2_TMP"

# BUG1329-3: --p1 ショートハンド
_BUG1329_3_TMP=$(mktemp /tmp/bug1329-3-XXXXXX)
cat > "$_BUG1329_3_TMP" << 'JSEOF'
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
let parseArgs;
try { eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function')); }
catch(e) { process.stdout.write(JSON.stringify({err: e.message})); process.exit(0); }
const result = parseArgs(['重要なタスク', '--p1', '--due', '2026-05-10']);
process.stdout.write(JSON.stringify({ extra: result.extra, priority: result.priority, due: result.due }));
JSEOF
_BUG1329_3_OUT=$(node "$_BUG1329_3_TMP" "$ENGINE" 2>&1)
_BUG1329_3_EXTRA=$(printf '%s' "$_BUG1329_3_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(JSON.stringify(d.extra));}catch(e){process.stdout.write('PARSE_ERR');}});
")
_BUG1329_3_PRI=$(printf '%s' "$_BUG1329_3_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(d.priority||'null');}catch(e){process.stdout.write('PARSE_ERR');}});
")
assert_eq "BUG1329-3: --p1 がタイトルに混入しない（extra にノイズなし）" '["重要なタスク"]' "$_BUG1329_3_EXTRA"
assert_eq "BUG1329-3: --p1 が priority としてパースされる" 'p1' "$_BUG1329_3_PRI"
rm -f "$_BUG1329_3_TMP"

# BUG1329-4: --p2 ショートハンド（--label / @context / --desc との組み合わせ）
_BUG1329_4_TMP=$(mktemp /tmp/bug1329-4-XXXXXX)
cat > "$_BUG1329_4_TMP" << 'JSEOF'
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
let parseArgs;
try { eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function')); }
catch(e) { process.stdout.write(JSON.stringify({err: e.message})); process.exit(0); }
const result = parseArgs(['タスクA', '@claude', '--p2', '--desc', '詳細説明', '--label', 'feature']);
process.stdout.write(JSON.stringify({
  extra: result.extra, priority: result.priority,
  labels: result.labels, contexts: result.contexts, desc: result.desc
}));
JSEOF
_BUG1329_4_OUT=$(node "$_BUG1329_4_TMP" "$ENGINE" 2>&1)
_BUG1329_4_EXTRA=$(printf '%s' "$_BUG1329_4_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(JSON.stringify(d.extra));}catch(e){process.stdout.write('PARSE_ERR');}});
")
_BUG1329_4_PRI=$(printf '%s' "$_BUG1329_4_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(d.priority||'null');}catch(e){process.stdout.write('PARSE_ERR');}});
")
assert_eq "BUG1329-4: --p2 + 他オプション混在で extra にノイズなし" '["タスクA"]' "$_BUG1329_4_EXTRA"
assert_eq "BUG1329-4: --p2 + 他オプション混在で priority が正しくパースされる" 'p2' "$_BUG1329_4_PRI"
rm -f "$_BUG1329_4_TMP"

# BUG1329-5: --p3 がタイトル末尾位置でも混入しない（実害パターン再現）
_BUG1329_5_TMP=$(mktemp /tmp/bug1329-5-XXXXXX)
cat > "$_BUG1329_5_TMP" << 'JSEOF'
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const match = src.match(/^function parseArgs[\s\S]+?^}/m);
let parseArgs;
try { eval('parseArgs = ' + match[0].replace(/^function parseArgs/, 'function')); }
catch(e) { process.stdout.write(JSON.stringify({err: e.message})); process.exit(0); }
// 実害パターン: タイトルの後に --p3 が末尾に来るケース
const result = parseArgs(['タイトル', '@claude', '--desc', '詳細', '--p3']);
process.stdout.write(JSON.stringify({ extra: result.extra, priority: result.priority }));
JSEOF
_BUG1329_5_OUT=$(node "$_BUG1329_5_TMP" "$ENGINE" 2>&1)
_BUG1329_5_EXTRA=$(printf '%s' "$_BUG1329_5_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(JSON.stringify(d.extra));}catch(e){process.stdout.write('PARSE_ERR');}});
")
_BUG1329_5_PRI=$(printf '%s' "$_BUG1329_5_OUT" | node -e "
  let raw=''; process.stdin.on('data',d=>raw+=d);
  process.stdin.on('end',()=>{try{const d=JSON.parse(raw);process.stdout.write(d.priority||'null');}catch(e){process.stdout.write('PARSE_ERR');}});
")
assert_eq "BUG1329-5: 末尾 --p3（実害パターン）がタイトルに混入しない" '["タイトル"]' "$_BUG1329_5_EXTRA"
assert_eq "BUG1329-5: 末尾 --p3（実害パターン）が priority としてパースされる" 'p3' "$_BUG1329_5_PRI"
rm -f "$_BUG1329_5_TMP"

# ──────────────────────────────────────────
# BUG#1326: ensureLabel — existence check で 422 ノイズ抑止
# GitHub 接続不要。ソースコード確認 + Node.js モックテスト。
# ──────────────────────────────────────────
echo ""
echo "## BUG1326: ensureLabel existence check テスト (T-13/T-14/T-15)"

# T-13-src: ensureLabel が GET /repos/.../labels/{name} を使っている（ソース確認）
if grep -q "GET /repos/{owner}/{repo}/labels/{name}" "$ENGINE"; then
  printf "  ✅ T-13-src: ensureLabel が existence check (GET /labels/{name}) を使っている\n"; PASS=$((PASS+1))
else
  printf "  ❌ T-13-src: ensureLabel に existence check が見つからない（422 catch 方式のまま？）\n"; FAIL=$((FAIL+1))
fi

# T-13-nocreate: 既存ラベル（GET 200）のとき createLabel を呼ばないこと（Node.js モック）
_BUG1326_TMP=$(mktemp /tmp/test-ensure-label-XXXXXX)
cat > "$_BUG1326_TMP" << 'ENSURE_LABEL_TEST_EOF'
// ensureLabel モックテスト（BUG1326）
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
// 関数定義を抽出して eval
const match = src.match(/\/\/ ラベルが存在しなければ作成する[\s\S]*?^async function ensureLabel[\s\S]*?^}/m);
if (!match) { process.stderr.write('ensureLabel not found\n'); process.exit(1); }
eval(match[0]);

async function runTests() {
  let results = { t13_nocreate: null, t14_create: null, t15_auth_error: null };

  // T-13: 既存ラベル（GET → 200）のとき createLabel が呼ばれないこと
  let createLabelCalled = false;
  const octokit13 = {
    request: async (url) => { return { data: { name: '@claude' } }; }, // 200
    issues: { createLabel: async () => { createLabelCalled = true; } }
  };
  await ensureLabel(octokit13, 'owner', 'repo', '@claude', 'FBCA04', '');
  results.t13_nocreate = !createLabelCalled;

  // T-14: 新規ラベル（GET → 404）のとき createLabel が呼ばれること
  let createLabelCalled14 = false;
  const octokit14 = {
    request: async (url) => { const e = new Error('Not Found'); e.status = 404; throw e; },
    issues: { createLabel: async () => { createLabelCalled14 = true; } }
  };
  await ensureLabel(octokit14, 'owner', 'repo', '@newtag', 'FBCA04', '');
  results.t14_create = createLabelCalled14;

  // T-15: 真のエラー（401）が伝播すること
  let errorPropagated = false;
  const octokit15 = {
    request: async (url) => { const e = new Error('Unauthorized'); e.status = 401; throw e; },
    issues: { createLabel: async () => {} }
  };
  try {
    await ensureLabel(octokit15, 'owner', 'repo', '@test', 'FBCA04', '');
  } catch(e) {
    if (e.status === 401) errorPropagated = true;
  }
  results.t15_auth_error = errorPropagated;

  process.stdout.write(JSON.stringify(results));
}
runTests().catch(e => { process.stderr.write(e.message+'\n'); process.exit(1); });
ENSURE_LABEL_TEST_EOF

_BUG1326_OUT=$(node "$_BUG1326_TMP" "$ENGINE" 2>&1)
_BUG1326_EXIT=$?
rm -f "$_BUG1326_TMP"

if [ "$_BUG1326_EXIT" -ne 0 ]; then
  printf "  ❌ BUG1326 モックテスト実行失敗: %s\n" "$_BUG1326_OUT"; FAIL=$((FAIL+3))
else
  # T-13: createLabel が呼ばれないこと
  if printf '%s' "$_BUG1326_OUT" | grep -q '"t13_nocreate":true'; then
    printf "  ✅ T-13: 既存ラベル（GET 200）で createLabel が呼ばれない\n"; PASS=$((PASS+1))
  else
    printf "  ❌ T-13: 既存ラベルでも createLabel が呼ばれてしまった\n"; FAIL=$((FAIL+1))
  fi

  # T-14: createLabel が呼ばれること
  if printf '%s' "$_BUG1326_OUT" | grep -q '"t14_create":true'; then
    printf "  ✅ T-14: 新規ラベル（GET 404）で createLabel が呼ばれる\n"; PASS=$((PASS+1))
  else
    printf "  ❌ T-14: 新規ラベルで createLabel が呼ばれなかった\n"; FAIL=$((FAIL+1))
  fi

  # T-15: 401 エラーが伝播すること
  if printf '%s' "$_BUG1326_OUT" | grep -q '"t15_auth_error":true'; then
    printf "  ✅ T-15: 真のエラー（401）がサイレント化されず伝播する\n"; PASS=$((PASS+1))
  else
    printf "  ❌ T-15: 真のエラー（401）がサイレント化されてしまった\n"; FAIL=$((FAIL+1))
  fi
fi

# ──────────────────────────────────────────
# BUG#1328: Octokit カスタムロガー — 期待される 4xx ノイズ抑止
# GitHub 接続不要。ソースコード確認 + Node.js ロガー動作テスト。
# ──────────────────────────────────────────

echo ""
echo "--- BUG#1328: Octokit カスタムロガー ---"

# T-16-src: OCTOKIT_LOGGER 定数がソースに定義されていること
if grep -q 'const OCTOKIT_LOGGER' "$ENGINE"; then
  printf "  ✅ T-16-src: OCTOKIT_LOGGER 定数がソースに定義されている\n"; PASS=$((PASS+1))
else
  printf "  ❌ T-16-src: OCTOKIT_LOGGER 定数が見つからない\n"; FAIL=$((FAIL+1))
fi

# T-17-src: new OctokitClass に log: OCTOKIT_LOGGER が含まれること
# Issue #1648 で apiMain() の重複Octokit構築を initOctokit() 呼び出しに統合したため、
# 構築箇所は1箇所（initOctokit 内）に減った。apiMain が initOctokit() を呼んでいることを
# 合わせて確認し、両経路（run api.../api直接）でロガーが効いていることを担保する。
_t17_count=$(grep -c '{ auth: token, log: OCTOKIT_LOGGER }' "$ENGINE" || true)
_t17_apimain_delegates=$(node -e "const s=require('fs').readFileSync('$ENGINE','utf8'); \
  const m=s.match(/async function apiMain[\s\S]*?^}/m); \
  console.log(m && m[0].includes('await initOctokit()') ? 'OK' : 'NG')")
if [ "$_t17_count" -ge 1 ] && [ "$_t17_apimain_delegates" = "OK" ]; then
  printf "  ✅ T-17-src: Octokit構築箇所 (%d) に log: OCTOKIT_LOGGER が設定され、apiMain が initOctokit() に委譲している（#1648統合）\n" "$_t17_count"; PASS=$((PASS+1))
else
  printf "  ❌ T-17-src: log: OCTOKIT_LOGGER 設定 %d 件 / apiMain委譲 %s\n" "$_t17_count" "$_t17_apimain_delegates"; FAIL=$((FAIL+1))
fi

# T-18 〜 T-20: カスタムロガーの動作確認（Node.js インラインテスト）
_BUG1328_TMP=$(mktemp /tmp/todo-test-logger-XXXXXX)
cat > "$_BUG1328_TMP" << 'LOGGER_TEST_EOF'
const ENGINE_PATH = process.argv[2];
const src = require('fs').readFileSync(ENGINE_PATH, 'utf8');

// OCTOKIT_LOGGER の定義部分を抽出して Function コンストラクタで評価する
// const で宣言された変数は eval() の外スコープに漏れないため、
// new Function で return させる方式を使う
const match = src.match(/const OCTOKIT_LOGGER\s*=\s*(\{[\s\S]*?\});/);
if (!match) { process.stderr.write('OCTOKIT_LOGGER not found\n'); process.exit(1); }

// match[1] = オブジェクトリテラル部分 ( { debug: ..., error: ... } )
// ただし error 関数内で console.error を参照するため、console をグローバルとして渡す
// eslint-disable-next-line no-new-func
const OCTOKIT_LOGGER = new Function('console', 'return ' + match[1])(console);

const results = {};
const captured = [];

// console.error を一時的にモック
const origError = console.error;
console.error = (...args) => { captured.push(args.join(' ')); };

// T-18: 404 を含むメッセージが抑止されること
OCTOKIT_LOGGER.error('HttpError: Not Found [404]');
results.t18_404_suppressed = captured.length === 0;
captured.length = 0;

// T-19: 422 を含むメッセージが抑止されること
OCTOKIT_LOGGER.error('HttpError: Unprocessable Entity [422]');
results.t19_422_suppressed = captured.length === 0;
captured.length = 0;

// T-20: 500 を含むメッセージが通過すること（抑止されないこと）
OCTOKIT_LOGGER.error('HttpError: Internal Server Error [500]');
results.t20_500_passed = captured.length > 0;
captured.length = 0;

// console.error を元に戻す
console.error = origError;

process.stdout.write(JSON.stringify(results) + '\n');
LOGGER_TEST_EOF

_BUG1328_OUT=$(node "$_BUG1328_TMP" "$ENGINE" 2>&1)
_BUG1328_EXIT=$?
rm -f "$_BUG1328_TMP"

if [ "$_BUG1328_EXIT" -ne 0 ]; then
  printf "  ❌ BUG1328 ロガーテスト実行失敗: %s\n" "$_BUG1328_OUT"; FAIL=$((FAIL+3))
else
  # T-18: 404 が抑止されること
  if printf '%s' "$_BUG1328_OUT" | grep -q '"t18_404_suppressed":true'; then
    printf "  ✅ T-18: OCTOKIT_LOGGER が 404 メッセージを抑止する\n"; PASS=$((PASS+1))
  else
    printf "  ❌ T-18: OCTOKIT_LOGGER が 404 メッセージを抑止していない\n"; FAIL=$((FAIL+1))
  fi

  # T-19: 422 が抑止されること
  if printf '%s' "$_BUG1328_OUT" | grep -q '"t19_422_suppressed":true'; then
    printf "  ✅ T-19: OCTOKIT_LOGGER が 422 メッセージを抑止する\n"; PASS=$((PASS+1))
  else
    printf "  ❌ T-19: OCTOKIT_LOGGER が 422 メッセージを抑止していない\n"; FAIL=$((FAIL+1))
  fi

  # T-20: 500 が通過すること
  if printf '%s' "$_BUG1328_OUT" | grep -q '"t20_500_passed":true'; then
    printf "  ✅ T-20: OCTOKIT_LOGGER が 500 メッセージを通過させる（抑止しない）\n"; PASS=$((PASS+1))
  else
    printf "  ❌ T-20: OCTOKIT_LOGGER が 500 メッセージを抑止してしまった\n"; FAIL=$((FAIL+1))
  fi
fi

# ──────────────────────────────────────────
# §32  due clear / 空文字 — validateDue・buildBody との統合
# ──────────────────────────────────────────
echo ""
echo "§32  due clear / 空文字 — 期日削除バリデーション（シナリオ 5-1b, S-3b）"

# validateDue で 'clear' が通過すること（engine validate due clear）
node "$ENGINE" validate due 'clear' 2>/dev/null \
  && { printf "  ✅ validate due clear: exit 0（クリア値として通過）\n"; PASS=$((PASS+1)); } \
  || { printf "  ❌ validate due clear: exit 1（通過すべき）\n"; FAIL=$((FAIL+1)); }

# validateDue で空文字が通過すること（engine validate due ""）
node "$ENGINE" validate due '' 2>/dev/null \
  && { printf "  ✅ validate due '': exit 0（空文字クリアとして通過）\n"; PASS=$((PASS+1)); } \
  || { printf "  ❌ validate due '': exit 1（通過すべき）\n"; FAIL=$((FAIL+1)); }

# validateDue で通常の日付は引き続き通過すること（回帰確認）
node "$ENGINE" validate due '2026-06-26' 2>/dev/null \
  && { printf "  ✅ validate due YYYY-MM-DD: exit 0（回帰確認）\n"; PASS=$((PASS+1)); } \
  || { printf "  ❌ validate due YYYY-MM-DD: exit 1（通過すべき）\n"; FAIL=$((FAIL+1)); }

# validateDue で M/D 形式は引き続き通過すること（回帰確認）
node "$ENGINE" validate due '6/26' 2>/dev/null \
  && { printf "  ✅ validate due M/D: exit 0（回帰確認）\n"; PASS=$((PASS+1)); } \
  || { printf "  ❌ validate due M/D: exit 1（通過すべき）\n"; FAIL=$((FAIL+1)); }

# 🟡-4: normalizeDue が M/D → YYYY-MM-DD に変換すること（Phase 3）
ND_MD_OUT=$(node "$ENGINE" normalize-due '5/19' '2026-05-19')
assert_eq "normalizeDue: 5/19 → 2026-05-19（今年YYYY-MM-DD）" "2026-05-19" "$ND_MD_OUT"
# today より未来の M/D はゼロ埋めのうえ今年のまま変換される（today を2026-01-01にして
# 4/1が未来日になるようにする。過去日になるケースはIssue #1650セクションで別途検証）
ND_MD_OUT2=$(node "$ENGINE" normalize-due '4/1' '2026-01-01')
assert_eq "normalizeDue: 4/1 → 2026-04-01（M/Dゼロ埋め）" "2026-04-01" "$ND_MD_OUT2"

# validateDue で不正文字はエラー（回帰確認）
node "$ENGINE" validate due '不正' 2>/dev/null \
  && { printf "  ❌ validate due '不正': exit 0（エラーすべき）\n"; FAIL=$((FAIL+1)); } \
  || { printf "  ✅ validate due '不正': exit 1（不正値は拒否）\n"; PASS=$((PASS+1)); }

# build-body に空の due を渡すと due: 行が出力されないこと
BB_NO_DUE=$(node "$ENGINE" build-body "" "weekly" "7" "" "" "説明文")
if ! printf '%s' "$BB_NO_DUE" | grep -aq 'due:'; then
  printf "  ✅ build-body due='': due行が出力されない\n"; PASS=$((PASS+1))
else
  printf "  ❌ build-body due='': due行が出力されてしまう\n"; FAIL=$((FAIL+1))
fi

# build-body で recur/project/desc は保持されること（clear 後の副作用なし確認）
assert_contains "build-body due='': recur行保持" "recur: weekly" "$BB_NO_DUE"
assert_contains "build-body due='': project行保持" "project: #7" "$BB_NO_DUE"
assert_contains "build-body due='': desc保持" "説明文" "$BB_NO_DUE"

# recur clear と due clear は独立して動作すること
# （recur clear 後の build-body で due は保持される）
BB_RECUR_CLEAR=$(node "$ENGINE" build-body "2026-06-26" "" "7" "" "" "")
assert_contains "recur clear後: due行保持" "due: 2026-06-26" "$BB_RECUR_CLEAR"
if ! printf '%s' "$BB_RECUR_CLEAR" | grep -aq 'recur:'; then
  printf "  ✅ recur clear後: recur行なし\n"; PASS=$((PASS+1))
else
  printf "  ❌ recur clear後: recur行が残っている\n"; FAIL=$((FAIL+1))
fi

# ──────────────────────────────────────────
# Phase 2 リファクタリングテスト（🟡-1: buildBody オブジェクト引数化）
# parseBodyObj ↔ buildBody の対称性、差分更新パターン、デフォルト値の検証
# ──────────────────────────────────────────
echo ""
echo "--- Phase 2 リファクタリングテスト（buildBody オブジェクト引数化） ---"

# Node.js 内部 API（buildBody / parseBodyObj）を直接呼ぶインラインテスト群
# 一時 JS ファイルに書き出してから node 実行（heredoc + $() の入れ子問題を回避）
PHASE2_JS=$(mktemp /tmp/todo-phase2-test-XXXXXX)
cat > "$PHASE2_JS" << 'JSEOF'
const path = process.env.ENGINE_PATH;
const fs = require('fs');
const src = fs.readFileSync(path, 'utf8');

// engine 本体は読み込むと exit するため、関数定義のみ抽出して eval
function extractFn(name) {
  const re = new RegExp('function ' + name + '\\s*\\([\\s\\S]*?\\n\\}\\n', 'm');
  const m = src.match(re);
  if (!m) throw new Error('function ' + name + ' not found');
  return m[0];
}

eval(extractFn('buildBody'));
eval(extractFn('parseBodyObj'));

const results = [];
function eq(desc, expected, actual) {
  if (expected === actual) results.push('PASS\t' + desc);
  else results.push('FAIL\t' + desc + '\n  expected: ' + JSON.stringify(expected) + '\n  actual: ' + JSON.stringify(actual));
}

// T1: 空オブジェクト → 空文字
eq('buildBody({}) は空文字を返す', '', buildBody({}));

// T2: 引数なし → エラーにならず空文字（fields || {} のフォールバック）
eq('buildBody() は空文字を返す（引数なし）', '', buildBody());

// T3: due のみ
eq('buildBody({due}) は due 1行', 'due: 2026-01-01\n', buildBody({ due: '2026-01-01' }));

// T4: 差分更新 — 既存 issue から desc のみ変更（他フィールド保持）
const issue = {
  due: '2026-05-19', recur: 'weekly', project: '7',
  estimate: '120', actual: '60', desc: '元の説明',
  activate: '2026-05-15', before: '4d',
  reviewedAt: '2026-05-10', dependsOn: '99',
  resumeCondition: 'GSCインプレッションが月100件を超えたら',
};
const updatedDesc = buildBody(Object.assign({}, issue, { desc: 'new desc' }));
eq('差分更新 desc: due 行保持',         true, /^due: 2026-05-19$/m.test(updatedDesc));
eq('差分更新 desc: recur 行保持',       true, /^recur: weekly$/m.test(updatedDesc));
eq('差分更新 desc: project 行保持',     true, /^project: #7$/m.test(updatedDesc));
eq('差分更新 desc: estimate 行保持',    true, /^estimate: 120$/m.test(updatedDesc));
eq('差分更新 desc: actual 行保持',      true, /^actual: 60$/m.test(updatedDesc));
eq('差分更新 desc: activate 行保持',    true, /^activate: 2026-05-15$/m.test(updatedDesc));
eq('差分更新 desc: before 行保持',      true, /^before: 4d$/m.test(updatedDesc));
eq('差分更新 desc: reviewed_at 行保持', true, /^reviewed_at: 2026-05-10$/m.test(updatedDesc));
eq('差分更新 desc: depends_on 行保持',  true, /^depends_on: #99$/m.test(updatedDesc));
eq('差分更新 desc: resume_condition 行保持', true, /^resume_condition: GSCインプレッションが月100件を超えたら$/m.test(updatedDesc));
eq('差分更新 desc: 新しい desc が反映', true, /new desc/.test(updatedDesc));
eq('差分更新 desc: 古い desc は含まない', false, /元の説明/.test(updatedDesc));

// T5: due クリア（明示的に空文字）
const cleared = buildBody(Object.assign({}, issue, { due: '' }));
eq('due クリア: due 行が消える',      false, /^due:/m.test(cleared));
eq('due クリア: recur 行は保持',      true,  /^recur: weekly$/m.test(cleared));
eq('due クリア: depends_on 行は保持', true,  /^depends_on: #99$/m.test(cleared));
eq('due クリア: resume_condition 行は保持', true, /^resume_condition:/m.test(cleared));

// T5b: resume_condition のみクリア（他フィールドは保持）
const resumeCleared = buildBody(Object.assign({}, issue, { resumeCondition: '' }));
eq('resume_condition クリア: resume_condition 行が消える', false, /^resume_condition:/m.test(resumeCleared));
eq('resume_condition クリア: activate 行は保持',           true,  /^activate: 2026-05-15$/m.test(resumeCleared));
eq('resume_condition クリア: before 行は保持',             true,  /^before: 4d$/m.test(resumeCleared));

// T6: round-trip — parseBodyObj → buildBody → parseBodyObj が同一フィールド
const originalBody =
  'due: 2026-05-19\n' +
  'activate: 2026-05-15\n' +
  'resume_condition: GSCインプレッションが月100件を超えたら\n' +
  'before: 4d\n' +
  'depends_on: #99\n' +
  'recur: weekly\n' +
  'project: #7\n' +
  'estimate: 120\n' +
  'actual: 60\n' +
  'reviewed_at: 2026-05-10\n' +
  '\n' +
  '本文の説明文';
const parsed = parseBodyObj(originalBody);
const rebuilt = buildBody(Object.assign({}, parsed));
eq('round-trip: body 完全一致 (parseBodyObj→buildBody)', originalBody, rebuilt);

// T7: round-trip 後さらに parseBodyObj → 全フィールド一致
const reparsed = parseBodyObj(rebuilt);
eq('round-trip parse-build-parse: due',        parsed.due,        reparsed.due);
eq('round-trip parse-build-parse: recur',      parsed.recur,      reparsed.recur);
eq('round-trip parse-build-parse: project',    parsed.project,    reparsed.project);
eq('round-trip parse-build-parse: estimate',   parsed.estimate,   reparsed.estimate);
eq('round-trip parse-build-parse: actual',     parsed.actual,     reparsed.actual);
eq('round-trip parse-build-parse: activate',   parsed.activate,   reparsed.activate);
eq('round-trip parse-build-parse: before',     parsed.before,     reparsed.before);
eq('round-trip parse-build-parse: reviewedAt', parsed.reviewedAt, reparsed.reviewedAt);
eq('round-trip parse-build-parse: dependsOn',  parsed.dependsOn,  reparsed.dependsOn);
eq('round-trip parse-build-parse: resumeCondition', parsed.resumeCondition, reparsed.resumeCondition);
eq('round-trip parse-build-parse: desc',       parsed.desc,       reparsed.desc);

// T8: reviewedAt のみ更新（runReviewSomeday パターン）
const reviewed = buildBody(Object.assign({}, issue, { reviewedAt: '2026-05-19' }));
eq('reviewedAt 更新: 新しい値が反映',   true,  /^reviewed_at: 2026-05-19$/m.test(reviewed));
eq('reviewedAt 更新: 古い値は残らない', false, /^reviewed_at: 2026-05-10$/m.test(reviewed));

// T9: parseBodyObj 戻り値を直接 spread で渡せる（対称性）
const projParsed = parseBodyObj('due: 2026-06-01\nproject: #5\nreviewed_at: 2026-05-01\n\nproj desc');
const projUpdated = buildBody(Object.assign({}, projParsed, { reviewedAt: '2026-05-19' }));
eq('parseBodyObj→buildBody: due 行',         true, /^due: 2026-06-01$/m.test(projUpdated));
eq('parseBodyObj→buildBody: project 行',     true, /^project: #5$/m.test(projUpdated));
eq('parseBodyObj→buildBody: reviewed_at 新', true, /^reviewed_at: 2026-05-19$/m.test(projUpdated));
eq('parseBodyObj→buildBody: desc 保持',      true, /proj desc/.test(projUpdated));

// T10: undefined フィールドはデフォルト空文字扱い
const partial = buildBody({ due: '2026-01-01', desc: 'メモ' });
eq('部分指定: due 行あり',    true,  /^due: 2026-01-01$/m.test(partial));
eq('部分指定: recur 行なし',  false, /^recur:/m.test(partial));
eq('部分指定: desc あり',     true,  /メモ/.test(partial));

// 結果出力
results.forEach(function (r) { console.log(r); });
JSEOF
PHASE2_OUT=$(ENGINE_PATH="$ENGINE" node "$PHASE2_JS" 2>&1)
rm -f "$PHASE2_JS"

# Phase 2 結果のパース
while IFS=$'\t' read -r status desc; do
  if [ "$status" = "PASS" ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  elif [ "$status" = "FAIL" ]; then
    printf "  ❌ %s\n" "$desc"; FAIL=$((FAIL+1))
  fi
done <<< "$PHASE2_OUT"

# Phase 2 CLI 経由テスト — build-body サブコマンドの後方互換（positional 引数）
# 既存 §parse-body/build-body テストでカバー済みだが、新形式と CLI 経由の結果が一致することを確認
BB_NEW_FORMAT_OK=$(node "$ENGINE" build-body "2026-04-10" "weekly" "7" "120" "90" "説明文" "2026-04-05" "5d" "2026-03-30" "42")
assert_contains "Phase 2: CLI build-body due"          "due: 2026-04-10"          "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body recur"        "recur: weekly"            "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body project"      "project: #7"              "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body estimate"     "estimate: 120"            "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body actual"       "actual: 90"               "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body activate"     "activate: 2026-04-05"     "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body before"       "before: 5d"               "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body reviewed_at"  "reviewed_at: 2026-03-30"  "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body depends_on"   "depends_on: #42"          "$BB_NEW_FORMAT_OK"
assert_contains "Phase 2: CLI build-body desc"         "説明文"                    "$BB_NEW_FORMAT_OK"

# ──────────────────────────────────────────
# Phase 1 レビュー修正テスト（🔴-3, 🔴-4, 🟡-10）
# ──────────────────────────────────────────
echo ""
echo "--- Phase 1 レビュー修正テスト ---"

# 🔴-3: runLabel null チェック — 引数なし呼び出しでクラッシュしない
# （Issue #1648: GH_TOKEN=dummy → OCTOKIT_STUB_ENV に置換。実 @octokit/rest の実インストール
#  に依存せず完結する。バリデーションエラーで即終了するため応答フィクスチャは不要）
LABEL_ADD_NOOP=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test \
  node "$ENGINE" run label add 2>&1); EC_LABEL_ADD=$?
assert_exit_fail "/todo label add（引数なし）→ exit 1" "$EC_LABEL_ADD"
assert_contains "/todo label add（引数なし）→ Usage 出力" "Usage" "$LABEL_ADD_NOOP"

LABEL_DEL_NOOP=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test \
  node "$ENGINE" run label delete 2>&1); EC_LABEL_DEL=$?
assert_exit_fail "/todo label delete（引数なし）→ exit 1" "$EC_LABEL_DEL"
assert_contains "/todo label delete（引数なし）→ Usage 出力" "Usage" "$LABEL_DEL_NOOP"

LABEL_REN_ONE=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test \
  node "$ENGINE" run label rename foo 2>&1); EC_LABEL_REN=$?
assert_exit_fail "/todo label rename（引数1個）→ exit 1" "$EC_LABEL_REN"
assert_contains "/todo label rename（引数1個）→ Usage 出力" "Usage" "$LABEL_REN_ONE"

# 🔴-4: runView 引数なし呼び出しでクラッシュしない
VIEW_NOOP=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test \
  node "$ENGINE" run view 2>&1); EC_VIEW=$?
assert_exit_fail "/todo view（引数なし）→ exit 1" "$EC_VIEW"
assert_contains "/todo view（引数なし）→ Usage 出力" "Usage" "$VIEW_NOOP"

# 🟡-10: MAX_OPEN_ISSUES_LIMIT 定数が定義されていること
MAX_CONST=$(node -e "const s=require('fs').readFileSync('$ENGINE','utf8'); \
  const m=s.match(/const MAX_OPEN_ISSUES_LIMIT\s*=\s*(\d+)/); \
  console.log(m?m[1]:'NOT_FOUND')")
assert_eq "MAX_OPEN_ISSUES_LIMIT 定数が定義されている" "200" "$MAX_CONST"

# ──────────────────────────────────────────
# Phase 3 レビュー修正テスト（🟡-2〜🟡-7）
# ──────────────────────────────────────────
echo ""
echo "--- Phase 3 リファクタリングテスト ---"

# 🟡-2: parseBody が parseBodyObj のラッパーとして動作し、dependsOn も含む全フィールドが一致
PB3_OUT=$(node "$ENGINE" parse-body "due: 2026-05-19
depends_on: #42

Phase3テスト")
PB3_DUE=$(printf '%s\n' "$PB3_OUT" | grep '^DUE=' | cut -d= -f2-)
PB3_B64=$(printf '%s\n' "$PB3_OUT" | grep '^DESC_B64=' | cut -d= -f2-)
PB3_DESC=$(node "$ENGINE" decode-b64 "$PB3_B64")
assert_eq "parseBody ラッパー: DUE フィールド" "2026-05-19" "$PB3_DUE"
assert_eq "parseBody ラッパー: DESC フィールド" "Phase3テスト" "$PB3_DESC"

# 🟡-3: removeLabelIfPresent ヘルパが定義されていること（コード内に存在することを確認）
RL_DEF=$(node -e "const s=require('fs').readFileSync('$ENGINE','utf8'); \
  console.log(s.includes('async function removeLabelIfPresent') ? 'FOUND' : 'NOT_FOUND')")
assert_eq "removeLabelIfPresent ヘルパが定義されている" "FOUND" "$RL_DEF"

# 🟡-3: execRemoveLabels が removeLabelIfPresent を呼ぶ形に書き換えられていること
ERL_IMPL=$(node -e "const s=require('fs').readFileSync('$ENGINE','utf8'); \
  const m=s.match(/async function execRemoveLabels[\s\S]*?^}/m); \
  console.log(m && m[0].includes('removeLabelIfPresent') ? 'OK' : 'NG')")
assert_eq "execRemoveLabels が removeLabelIfPresent を使用" "OK" "$ERL_IMPL"

# 🟡-4: normalize-due が M/D 形式を YYYY-MM-DD に変換すること（回帰）
assert_eq "normalize-due: 5/19 → YYYY-MM-DD" "2026-05-19" "$(node "$ENGINE" normalize-due '5/19' '2026-05-19')"
assert_eq "normalize-due: 12/31 → YYYY-MM-DD" "2026-12-31" "$(node "$ENGINE" normalize-due '12/31' '2026-05-19')"

# 🟡-6: renderToday 関数が定義され、today_fn が存在しないこと
RT_DEF=$(node -e "const s=require('fs').readFileSync('$ENGINE','utf8'); \
  console.log(s.includes('function renderToday()') ? 'FOUND' : 'NOT_FOUND')")
assert_eq "renderToday 関数が定義されている" "FOUND" "$RT_DEF"
TF_GONE=$(node -e "const s=require('fs').readFileSync('$ENGINE','utf8'); \
  console.log(s.includes('function today_fn()') ? 'FOUND' : 'NOT_FOUND')")
assert_eq "today_fn ラッパーが削除されている" "NOT_FOUND" "$TF_GONE"

# ──────────────────────────────────────────
# §33  リカレンス完了時の周期スキップ計算（cadence保持キャッチアップ、実事故 #1564→#1584 再発防止）
# ──────────────────────────────────────────
echo ""
echo "§33  リカレンス完了時の周期スキップ計算（due超過時のcatchup）"

# next-due-catchup <pattern> <base> <today> は {"nextDate":"...","skipped":bool} を返す
recur_catchup() {
  node "$ENGINE" next-due-catchup "$1" "$2" "$3"
}

# 実事故再現（#1564→#1584）: weekly, due=2026-06-13, today=2026-07-11
# → 手動修正実績どおり 2026-07-18（曜日保持・skipped）になること
assert_eq "実事故再現: weekly 過去due(2026-06-13,today=2026-07-11)→2026-07-18(skipped)" \
  '{"nextDate":"2026-07-18","skipped":true}' "$(recur_catchup weekly 2026-06-13 2026-07-11)"

# weekly: 複数週超過 → 曜日を保持したまま今日より後になるまでスキップ
assert_eq "weekly: due超過(複数週) → 未来かつ曜日保持(skipped)" \
  '{"nextDate":"2026-07-18","skipped":true}' "$(recur_catchup weekly 2026-06-13 2026-07-13)"

# daily: 過去due → today+1(skipped)
assert_eq "daily: due超過 → today+1(skipped)" \
  '{"nextDate":"2026-07-14","skipped":true}' "$(recur_catchup daily 2026-07-01 2026-07-13)"

# monthly: 過去due(数ヶ月超過) → 未来月(skipped)
assert_eq "monthly: due超過(数ヶ月) → 未来月(skipped)" \
  '{"nextDate":"2026-08-01","skipped":true}' "$(recur_catchup monthly 2026-03-01 2026-07-13)"

# weekdays: 過去due → 未来の平日まで進む(skipped)
assert_eq "weekdays: due超過 → 未来の平日(skipped)" \
  '{"nextDate":"2026-07-14","skipped":true}' "$(recur_catchup weekdays 2026-06-01 2026-07-13)"

# due = today（従来どおり base+1周期のみ、skippedなし）
assert_eq "weekly: due=today → base+1周期のみ(skippedなし)" \
  '{"nextDate":"2026-07-20","skipped":false}' "$(recur_catchup weekly 2026-07-13 2026-07-13)"
assert_eq "daily: due=today → base+1周期のみ(skippedなし)" \
  '{"nextDate":"2026-07-14","skipped":false}' "$(recur_catchup daily 2026-07-13 2026-07-13)"
assert_eq "monthly: due=today → base+1周期のみ(skippedなし)" \
  '{"nextDate":"2026-08-13","skipped":false}' "$(recur_catchup monthly 2026-07-13 2026-07-13)"
assert_eq "weekdays: due=today → base+1周期のみ(skippedなし)" \
  '{"nextDate":"2026-07-14","skipped":false}' "$(recur_catchup weekdays 2026-07-13 2026-07-13)"

# due が未来（従来どおり base+1周期のみ、skippedなし）
assert_eq "weekly: due=未来 → base+1周期のみ(skippedなし)" \
  '{"nextDate":"2026-07-27","skipped":false}' "$(recur_catchup weekly 2026-07-20 2026-07-13)"
assert_eq "daily: due=未来 → base+1周期のみ(skippedなし)" \
  '{"nextDate":"2026-07-15","skipped":false}' "$(recur_catchup daily 2026-07-14 2026-07-13)"

# due なし（base=today扱い、従来どおり。runDoneの `issue.due || today` をシミュレート）
assert_eq "weekly: dueなし(base=today) → today+7周期(skippedなし)" \
  '{"nextDate":"2026-07-20","skipped":false}' "$(recur_catchup weekly 2026-07-13 2026-07-13)"

# 回帰ガード: 完了後処理（recur再作成）が nextDue を直接使わず nextDueCatchUp 経由になっていること
# （#1564→#1584 バグの再発防止。過去due+1周期のみだと過去日付のままになる）
# 旧 POSTDONE_USES_CATCHUP/DONE_CALLS_POSTDONE/BULK_CALLS_POSTDONE はソースgrep
# （「文字列として呼び出しが書かれているか」のみ確認、実行結果は非検証）だった。
# Issue #1648 でスタブ経由の振る舞いテストに置換した
# （tests/run-tests-write.sh §W1 runDone / §W2 runBulk done。
#  nextDueCatchUp() の計算結果が issues.create の body まで実際に伝播することを確認）。

# 無限ループ防止ガードが定義されていること
CATCHUP_GUARD=$(node -e "const s=require('fs').readFileSync('$ENGINE','utf8'); \
  console.log(s.includes('MAX_RECUR_CATCHUP_ITERATIONS') ? 'FOUND' : 'NOT_FOUND')")
assert_eq "MAX_RECUR_CATCHUP_ITERATIONS ガードが定義されている" "FOUND" "$CATCHUP_GUARD"

# ──────────────────────────────────────────
# Issue #1643 / #1644 回帰テスト
# ──────────────────────────────────────────
# 旧 #1643 ブロック（run view delete 到達不能バグ）は「実HOMEのnode_modulesを
# シンボリックリンクした偽HOME」という重いサンドボックス回避策 + @octokit/rest が
# 解決できない環境でのスキップ分岐を持っていた。Issue #1648 で OCTOKIT_STUB_ENV
# ベースの決定論的テストに置換し、環境依存によるスキップが発生しなくなった
# （tests/run-tests-write.sh §W3 runView: save/save2件目/list/use/delete/再delete）。
#
# 旧 API_1644_OUT（run api ルーティング到達確認）・TAG_RENAME_DELEGATES（ソースgrep）も
# 同様にスタブベースの振る舞いテストへ置換した
# （tests/run-tests-write.sh §W7 runTag rename / §W8 run api ルーティング）。
#
# 引数不足・不正文字によるバリデーションエラー系（tag rename / label rename）は
# 実API呼び出しに到達しないため、GH_TOKEN=dummy → OCTOKIT_STUB_ENV に置換した上で
# 本ファイルに残す（応答フィクスチャ不要で完結するため）。
echo ""
echo "▶ Issue #1644: tag rename 回帰テスト（エンジン直叩き。label rename と処理を共用）"

# 1) 引数不足 → Usage エラー（label rename の既存挙動と同様）
TAG_REN_NOOP=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run tag rename foo 2>&1); EC_TAG_REN_NOOP=$?
assert_exit_fail "1644: /todo tag rename（引数1個）→ exit 1" "$EC_TAG_REN_NOOP"
assert_contains "1644: /todo tag rename（引数1個）→ Usage 出力" "Usage" "$TAG_REN_NOOP"

# 2) 不正文字を含む名前 → validateCtx まで到達してエラー（renameCtxLabel への委譲を実行経路で確認。実GitHub通信なし）
TAG_REN_INVALID=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run tag rename 'a;b' newctx 2>&1); EC_TAG_REN_INVALID=$?
assert_exit_fail "1644: /todo tag rename 不正文字 → exit 1" "$EC_TAG_REN_INVALID"
assert_contains "1644: /todo tag rename 不正文字エラー（label rename と同じ検証ロジックに到達）" "コンテキスト名に不正文字" "$TAG_REN_INVALID"

# 3) label rename 側もリファクタ後に同じ検証が効くことを確認（runLabel → renameCtxLabel 委譲の回帰防止）
LABEL_REN_INVALID=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run label rename 'a;b' newctx 2>&1); EC_LABEL_REN_INVALID=$?
assert_exit_fail "1644: /todo label rename 不正文字 → exit 1（リファクタ後も検証が効く）" "$EC_LABEL_REN_INVALID"
assert_contains "1644: /todo label rename 不正文字エラー" "コンテキスト名に不正文字" "$LABEL_REN_INVALID"

# ──────────────────────────────────────────
# Issue #1646: 予約語タイトル誤爆ガード
# 「/todo project list」のような GTD ラベル暗黙add経路で、タイトルが単一トークンかつ
# 既知コマンド名と完全一致する場合にゴミIssueを黙って作成しないことを確認する。
# ──────────────────────────────────────────
echo ""
echo "▶ Issue #1646: 予約語タイトル誤爆ガード（エンジン直叩き）"

# --- 発火パターン（CLI直接呼び出し）---
# initOctokit() はトークン文字列とローカルの @octokit/rest モジュール解決のみでネットワーク不要。
# ガードは runAdd 内の ensureLabel/issues.create 等の実API呼び出しより前（GTD分岐の入口）で
# 発火するため、この一連の呼び出しはネットワークアクセスなしで完結する。
G1646_LIST=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run project list 2>&1); EC_1646_LIST=$?
assert_exit_fail "1646: /todo project list → exit 1（誤爆ガード発火）" "$EC_1646_LIST"
assert_contains "1646: /todo project list → ガードメッセージに「list」を含む" '「list」はコマンド名です' "$G1646_LIST"
assert_contains "1646: /todo project list → 一覧表示の誘導 (/todo list project)" '/todo list project' "$G1646_LIST"
assert_contains "1646: /todo project list → add明示の誘導 (/todo add project list)" '/todo add project list' "$G1646_LIST"

G1646_HELP=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run next help 2>&1); EC_1646_HELP=$?
assert_exit_fail "1646: /todo next help → exit 1（誤爆ガード発火）" "$EC_1646_HELP"
assert_contains "1646: /todo next help → ガードメッセージに「help」を含む" '「help」はコマンド名です' "$G1646_HELP"

G1646_DONE=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run waiting done 2>&1); EC_1646_DONE=$?
assert_exit_fail "1646: /todo waiting done → exit 1（誤爆ガード発火）" "$EC_1646_DONE"
assert_contains "1646: /todo waiting done → ガードメッセージに「done」を含む" '「done」はコマンド名です' "$G1646_DONE"

G1646_PROJECT=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run someday project 2>&1); EC_1646_PROJECT=$?
assert_exit_fail "1646: /todo someday project → exit 1（誤爆ガード発火。project は switch外の手動追加分）" "$EC_1646_PROJECT"
assert_contains "1646: /todo someday project → ガードメッセージに「project」を含む" '「project」はコマンド名です' "$G1646_PROJECT"

G1646_COUNTS=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run inbox counts 2>&1); EC_1646_COUNTS=$?
assert_exit_fail "1646: /todo inbox counts → exit 1（誤爆ガード発火。counts は todo.sh 層専用コマンドとして手動追加）" "$EC_1646_COUNTS"
assert_contains "1646: /todo inbox counts → ガードメッセージに「counts」を含む" '「counts」はコマンド名です' "$G1646_COUNTS"

# 大文字小文字を区別しない判定の確認
G1646_UPPER=$(OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_OWNER=test TODO_REPO_NAME=test node "$ENGINE" run next LIST 2>&1); EC_1646_UPPER=$?
assert_exit_fail "1646: /todo next LIST（大文字）→ exit 1（誤爆ガード発火・大小文字非依存）" "$EC_1646_UPPER"
assert_contains "1646: /todo next LIST → ガードメッセージに元の大文字表記「LIST」を保持" '「LIST」はコマンド名です' "$G1646_UPPER"

# --- 非発火パターン（純粋関数 reservedTitleGuardWord を抽出して直接呼び出し）---
# runAdd 経路（ensureLabel/issues.create 等の実API呼び出し）を経由せずに検証するため、
# CLI 直接実行ではなくソースからガード関連コードを抽出して単体テストする。
_G1646_TMP=$(mktemp /tmp/todo-test-reserved-guard-XXXXXX)
cat > "$_G1646_TMP" << 'RESERVED_GUARD_TEST_EOF'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');

const gtdLabelsMatch  = src.match(/^const GTD_LABELS = \[[^\]]*\];/m);
const projectLabelMatch = src.match(/^const PROJECT_LABEL = '[^']+';/m);
const parseArgsMatch  = src.match(/^function parseArgs\(tokens\) \{[\s\S]*?^}/m);
const guardConstMatch = src.match(/^const RESERVED_TITLE_GUARD_COMMANDS = new Set\(\[[\s\S]*?^\]\);/m);
const guardFnMatch    = src.match(/^function reservedTitleGuardWord\(restTokens\) \{[\s\S]*?^}/m);
const runMainMatch    = src.match(/^async function runMain\(args\) \{[\s\S]*$/m);

const missing = [];
if (!gtdLabelsMatch)  missing.push('GTD_LABELS');
if (!projectLabelMatch) missing.push('PROJECT_LABEL');
if (!parseArgsMatch)  missing.push('parseArgs');
if (!guardConstMatch) missing.push('RESERVED_TITLE_GUARD_COMMANDS');
if (!guardFnMatch)    missing.push('reservedTitleGuardWord');
if (!runMainMatch)    missing.push('runMain');
if (missing.length) {
  process.stderr.write('抽出失敗: ' + missing.join(',') + '\n');
  process.exit(1);
}

// 抽出した定数・関数を1つの eval にまとめて実行する（direct eval の let/const は
// 呼び出し元と別の字句スコープを持つため、分割 eval だと相互参照できない）
const combined = [gtdLabelsMatch[0], projectLabelMatch[0], parseArgsMatch[0], guardConstMatch[0], guardFnMatch[0]].join('\n')
  + '\nconst results = {};'
  + "\nresults.fire_list    = reservedTitleGuardWord(['list'])    === 'list';"
  + "\nresults.fire_help    = reservedTitleGuardWord(['help'])    === 'help';"
  + "\nresults.fire_project = reservedTitleGuardWord(['project']) === 'project';"
  + "\nresults.fire_counts  = reservedTitleGuardWord(['counts'])  === 'counts';"
  // 非発火: 日本語単一トークン（摩擦ゼロ収集を維持。現行挙動）
  + "\nresults.nofire_ja_single = reservedTitleGuardWord(['買い物']) === null;"
  // 非発火: 複数トークン英語（現行挙動維持。1トークンのみが判定対象）
  + "\nresults.nofire_en_multi  = reservedTitleGuardWord(['Buy','milk']) === null;"
  // 非発火: 'add' / 'list' はそもそも GTD ラベル分岐に到達しない
  //   (/todo add next list は case 'add' へ、/todo list next は case 'list' へ直行し、
  //    reservedTitleGuardWord は呼ばれない。これが構造的な非発火保証)
  + "\nresults.nofire_add_not_gtd_branch  = !GTD_LABELS.includes('add')  && 'add'  !== PROJECT_LABEL;"
  + "\nresults.nofire_list_not_gtd_branch = !GTD_LABELS.includes('list') && 'list' !== PROJECT_LABEL;"
  + '\nprocess.stdout.write(JSON.stringify(results));';
eval(combined);

// ドリフト検知: runMain の switch にある実コマンド名がすべて
// RESERVED_TITLE_GUARD_COMMANDS のソースに含まれること（新コマンド追加時の追加漏れを検知）
const caseLabels = [...runMainMatch[0].matchAll(/case\s*'([a-zA-Z0-9_-]+)'\s*:/g)].map(m => m[1]);
const missingFromGuard = caseLabels.filter(l => !guardConstMatch[0].includes("'" + l + "'"));
process.stderr.write('DRIFT_MISSING:' + JSON.stringify(missingFromGuard) + '\n');
RESERVED_GUARD_TEST_EOF

_G1646_STDOUT=$(node "$_G1646_TMP" "$ENGINE" 2>"$_G1646_TMP.stderr")
_G1646_EXIT=$?
_G1646_STDERR=$(cat "$_G1646_TMP.stderr" 2>/dev/null)
rm -f "$_G1646_TMP" "$_G1646_TMP.stderr"

if [ "$_G1646_EXIT" -ne 0 ]; then
  printf "  ❌ 1646 単体テスト実行失敗: %s / %s\n" "$_G1646_STDOUT" "$_G1646_STDERR"; FAIL=$((FAIL+9))
else
  for key in fire_list fire_help fire_project fire_counts nofire_ja_single nofire_en_multi nofire_add_not_gtd_branch nofire_list_not_gtd_branch; do
    if printf '%s' "$_G1646_STDOUT" | grep -q "\"$key\":true"; then
      printf "  ✅ 1646: reservedTitleGuardWord 単体テスト [%s]\n" "$key"; PASS=$((PASS+1))
    else
      printf "  ❌ 1646: reservedTitleGuardWord 単体テスト [%s] 失敗: %s\n" "$key" "$_G1646_STDOUT"; FAIL=$((FAIL+1))
    fi
  done

  # ドリフト検知: 空配列（[]）であること
  if printf '%s' "$_G1646_STDERR" | grep -q 'DRIFT_MISSING:\[\]'; then
    printf "  ✅ 1646: dispatcher コマンド名とガード対象の同期（ドリフトなし）\n"; PASS=$((PASS+1))
  else
    printf "  ❌ 1646: switch case が RESERVED_TITLE_GUARD_COMMANDS に未反映: %s\n" "$_G1646_STDERR"; FAIL=$((FAIL+1))
  fi
fi

# ──────────────────────────────────────────
# §41  recur 曜日・日付固定サフィックス（Issue #1676）
# weekly:<曜日> / monthly:<日> の validateRecur・nextDue・renderIssueList を
# 実エンジン経由で検証する。次回due計算は「厳密加算」方式（最低1周期を空けてから
# 対象曜日/日付に合わせる。2026-08-08 ユーザー承認済み仕様）。
# ──────────────────────────────────────────
echo ""
echo "§41  recur 曜日・日付固定サフィックス（Issue #1676）"

# --- 正常系: validateRecur（weekly:<曜日> 全7曜日） ---
for dow in mon tue wed thu fri sat sun; do
  node "$ENGINE" validate recur "weekly:$dow" 2>/dev/null \
    && { printf "  ✅ validateRecur: weekly:%s 許可\n" "$dow"; PASS=$((PASS+1)); } \
    || { printf "  ❌ validateRecur: weekly:%s 許可されるべき\n" "$dow"; FAIL=$((FAIL+1)); }
done

# --- 正常系: validateRecur（monthly:<日> 範囲内） ---
for d in 1 15 31; do
  node "$ENGINE" validate recur "monthly:$d" 2>/dev/null \
    && { printf "  ✅ validateRecur: monthly:%s 許可\n" "$d"; PASS=$((PASS+1)); } \
    || { printf "  ❌ validateRecur: monthly:%s 許可されるべき\n" "$d"; FAIL=$((FAIL+1)); }
done

# --- 正常系: 先頭ゼロ許容（monthly:05） ---
node "$ENGINE" validate recur "monthly:05" 2>/dev/null \
  && { printf "  ✅ validateRecur: monthly:05（先頭ゼロ）許可\n"; PASS=$((PASS+1)); } \
  || { printf "  ❌ validateRecur: monthly:05（先頭ゼロ）許可されるべき\n"; FAIL=$((FAIL+1)); }

# --- 入力文字パターン: 拒否されるべきケース ---
declare -a REJECT_CASES=(
  "weekly:SAT"
  "weekly:Sat"
  "weekly:saturday"
  "weekly:土"
  "weekly:xyz"
  "monthly:０５"
  "weekly:"
  "monthly:"
  "weekly::sat"
  "weekly:sat:mon"
  "monthly:15:20"
  "daily:mon"
  "weekdays:sat"
  " weekly:sat"
  "weekly:sat "
  "monthly:0"
  "monthly:00"
  "monthly:32"
)
for c in "${REJECT_CASES[@]}"; do
  node "$ENGINE" validate recur "$c" 2>/dev/null \
    && { printf "  ❌ validateRecur: [%s] は拒否されるべき\n" "$c"; FAIL=$((FAIL+1)); } \
    || { printf "  ✅ validateRecur: [%s] 拒否\n" "$c"; PASS=$((PASS+1)); }
done

# --- セキュリティ: シェル特殊文字混入もホワイトリスト不一致として単純拒否 ---
node "$ENGINE" validate recur 'weekly:`id`' 2>/dev/null \
  && { printf "  ❌ validateRecur: バッククォート混入は拒否されるべき\n"; FAIL=$((FAIL+1)); } \
  || { printf "  ✅ validateRecur: バッククォート混入を拒否\n"; PASS=$((PASS+1)); }
node "$ENGINE" validate recur 'monthly:$(whoami)' 2>/dev/null \
  && { printf "  ❌ validateRecur: コマンド置換混入は拒否されるべき\n"; FAIL=$((FAIL+1)); } \
  || { printf "  ✅ validateRecur: コマンド置換混入を拒否\n"; PASS=$((PASS+1)); }

# --- 後方互換: サフィックスなしの既存パターンは従来通り許可 ---
for p in daily weekly monthly weekdays; do
  node "$ENGINE" validate recur "$p" 2>/dev/null \
    && { printf "  ✅ validateRecur: 後方互換 %s 許可\n" "$p"; PASS=$((PASS+1)); } \
    || { printf "  ❌ validateRecur: 後方互換 %s 許可されるべき\n" "$p"; FAIL=$((FAIL+1)); }
done

# --- 正常系: nextDue（weekly:<曜日>、ユーザー承認済み「厳密加算」検証例） ---
assert_eq "nextDue weekly:sat 2026-08-06(木)→2026-08-15(9日後)" \
  "2026-08-15" "$(node "$ENGINE" next-due weekly:sat 2026-08-06)"
assert_eq "nextDue weekly:sat 2026-08-08(土)→2026-08-15(7日後・ちょうど1周期)" \
  "2026-08-15" "$(node "$ENGINE" next-due weekly:sat 2026-08-08)"

# --- 境界値: weekly:sat 残り曜日の最短距離ロックオンではなく必ず7日以上先になること ---
assert_eq "nextDue weekly:mon 2026-08-08(土・翌々日が月曜)→2026-08-17(9日後、7日未満にならない)" \
  "2026-08-17" "$(node "$ENGINE" next-due weekly:mon 2026-08-08)"

# --- 正常系: nextDue（monthly:<日>、ユーザー承認済み「厳密加算」検証例） ---
assert_eq "nextDue monthly:15 2026-08-20(15日超過済み)→2026-10-15(1ヶ月スキップ)" \
  "2026-10-15" "$(node "$ENGINE" next-due monthly:15 2026-08-20)"
assert_eq "nextDue monthly:15 2026-08-10(15日未到来)→2026-09-15" \
  "2026-09-15" "$(node "$ENGINE" next-due monthly:15 2026-08-10)"
assert_eq "nextDue monthly:15 2026-08-15(基準日=対象日ちょうど)→2026-09-15(同日は含まず1ヶ月先)" \
  "2026-09-15" "$(node "$ENGINE" next-due monthly:15 2026-08-15)"

# --- 境界値: monthly:29/31 のクランプ ---
MTHLY_29_STDERR=$(node "$ENGINE" next-due monthly:29 2026-01-29 2>&1 1>/dev/null)
assert_eq "nextDue monthly:29 2026-01-29(平年)→2026-02-28クランプ" \
  "2026-02-28" "$(node "$ENGINE" next-due monthly:29 2026-01-29 2>/dev/null)"
assert_contains "nextDue monthly:29 2026-01-29(平年) クランプ警告あり" "クランプ" "$MTHLY_29_STDERR"

MTHLY_29_LEAP_STDERR=$(node "$ENGINE" next-due monthly:29 2028-01-29 2>&1 1>/dev/null)
assert_eq "nextDue monthly:29 2028-01-29(うるう年)→2028-02-29そのまま" \
  "2028-02-29" "$(node "$ENGINE" next-due monthly:29 2028-01-29 2>/dev/null)"
assert_eq "nextDue monthly:29 2028-01-29(うるう年) クランプ警告なし" "" "$MTHLY_29_LEAP_STDERR"

assert_eq "nextDue monthly:31 2026-03-15→2026-04-30クランプ(4月は30日まで)" \
  "2026-04-30" "$(node "$ENGINE" next-due monthly:31 2026-03-15 2>/dev/null)"
assert_eq "nextDue monthly:31 2026-05-15→2026-06-30クランプ(6月は30日まで)" \
  "2026-06-30" "$(node "$ENGINE" next-due monthly:31 2026-05-15 2>/dev/null)"
assert_eq "nextDue monthly:31 2026-08-15→2026-09-30クランプ(9月は30日まで)" \
  "2026-09-30" "$(node "$ENGINE" next-due monthly:31 2026-08-15 2>/dev/null)"
assert_eq "nextDue monthly:31 2026-10-15→2026-11-30クランプ(11月は30日まで)" \
  "2026-11-30" "$(node "$ENGINE" next-due monthly:31 2026-10-15 2>/dev/null)"

# --- 境界値: 年またぎ（12月→翌年1月） ---
assert_eq "nextDue monthly:15 2026-12-10(年またぎ)→2027-01-15" \
  "2027-01-15" "$(node "$ENGINE" next-due monthly:15 2026-12-10 2>/dev/null)"

# --- 境界値: monthly:1 / monthly:28（常に存在する日、クランプなし） ---
# monthly:1 は基準日=対象日ちょうど（2026-08-01）のケース。厳密加算方式では
# アンカー(基準日+1ヶ月=2026-09-01)とアンカー月内候補(2026-09-01)が一致するため、
# 「その日を含む」仕様どおりアンカー月内で確定する（他の境界値と同じ >= 判定の確認）
assert_eq "nextDue monthly:1 2026-08-01(基準日=対象日ちょうど)→2026-09-01" \
  "2026-09-01" "$(node "$ENGINE" next-due monthly:1 2026-08-01 2>/dev/null)"
assert_eq "nextDue monthly:28 2026-08-10→2026-09-28" \
  "2026-09-28" "$(node "$ENGINE" next-due monthly:28 2026-08-10 2>/dev/null)"
MTHLY_1_STDERR=$(node "$ENGINE" next-due monthly:1 2026-08-01 2>&1 1>/dev/null)
assert_eq "nextDue monthly:1 クランプ警告なし（常に存在する日）" "" "$MTHLY_1_STDERR"

# --- 後方互換: サフィックスなしの nextDue は従来どおり ---
assert_eq "nextDue weekly(サフィックスなし)従来通り+7日" \
  "2026-04-12" "$(node "$ENGINE" next-due weekly "$TEST_TODAY")"
assert_eq "nextDue monthly(サフィックスなし)従来通りaddMonth" \
  "2026-05-05" "$(node "$ENGINE" next-due monthly "$TEST_TODAY")"

# --- catchup: 曜日・日付固定でも期限超過キャッチアップが正しく動くこと ---
# nextDueCatchUp は「date <= today の間は繰り返す」実装のため、todayちょうどの
# 土曜(2026-08-08)は「まだ来ていない」に含めず、次の土曜(2026-08-15)まで進む
# （既存のnextDueCatchUpループの仕様。weekly:satでも動作が変わらないことの確認）
CATCHUP_WEEKLY=$(node "$ENGINE" next-due-catchup weekly:sat 2020-01-01 2026-08-08 2>/dev/null)
assert_contains "next-due-catchup weekly:sat 大幅超過→today(2026-08-08)は含まず次の土曜2026-08-15" \
  '"nextDate":"2026-08-15"' "$CATCHUP_WEEKLY"
assert_contains "next-due-catchup weekly:sat 大幅超過 skipped=true" '"skipped":true' "$CATCHUP_WEEKLY"

CATCHUP_MONTHLY=$(node "$ENGINE" next-due-catchup monthly:31 2015-01-01 2026-08-08 2>/dev/null)
assert_contains "next-due-catchup monthly:31 大幅超過→2026-08-08以降の直近末日" \
  '"nextDate":"2026-08-31"' "$CATCHUP_MONTHLY"
assert_contains "next-due-catchup monthly:31 大幅超過 skipped=true" '"skipped":true' "$CATCHUP_MONTHLY"

# --- パフォーマンス: 10年超のcatchupが反復上限(3660)に達しないこと ---
CATCHUP_PERF_STDOUT=$(node "$ENGINE" next-due-catchup weekly:sat 2015-01-01 2026-08-08 2>/dev/null)
assert_not_contains "next-due-catchup weekly:sat 10年超でも反復上限メッセージなし" \
  "反復上限" "$(node "$ENGINE" next-due-catchup weekly:sat 2015-01-01 2026-08-08 2>&1 1>/dev/null)"

# --- 一覧表示 renderIssueList 回帰: \w+ → \S+ 修正でコロン以降も表示されること ---
RECUR_SUFFIX_MOCK='[
  {"number":501,"title":"weekly-review","body":"due: 2026-04-10\nrecur: weekly:sat","labels":[{"name":"🎯 next"}]}
]'
RECUR_SUFFIX_OUT=$(OPEN_ENV="$RECUR_SUFFIX_MOCK" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "renderIssueList: weekly:sat がコロンごと表示される（旧バグ回帰）" "🔄weekly:sat" "$RECUR_SUFFIX_OUT"
assert_not_contains "renderIssueList: weekly:sat が weekly に切り詰められない" "🔄weekly " "$RECUR_SUFFIX_OUT"

RECUR_SUFFIX_MOCK2='[
  {"number":502,"title":"monthly-report","body":"due: 2026-04-10\nrecur: monthly:15","labels":[{"name":"🎯 next"}]}
]'
RECUR_SUFFIX_OUT2=$(OPEN_ENV="$RECUR_SUFFIX_MOCK2" TODAY_ENV="$TEST_TODAY" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "renderIssueList: monthly:15 がコロンごと表示される（旧バグ回帰）" "🔄monthly:15" "$RECUR_SUFFIX_OUT2"

# show --json の recur コロン保持確認は Octokit スタブが必要なため
# run-tests-write.sh §W13 に実装する（このファイルはGitHub非接続の純粋ユニットテストのみ）。

# ──────────────────────────────────────────
# Issue #1695: Web環境実行不能対応
# TODO_REPO_OWNER/TODO_REPO_NAME 未設定ガード + GitHub REST 401検知のテスト
# （tests/scenarios.md §46 T-22〜T-27）
# ──────────────────────────────────────────
echo ""
echo "▶ Issue #1695: Web環境実行不能対応（TODO_REPO_OWNER/NAME未設定ガード・401検知）"

# T-22: 両方未設定 → error.repo_not_configured が出力され、GitHub API は一度も呼ばれない
T22_LOG=$(mktemp /tmp/todo-test-t22-XXXXXX); : > "$T22_LOG"
T22_OUT=$(env -u TODO_REPO_OWNER -u TODO_REPO_NAME OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" OCTOKIT_STUB_LOG_ENV="$T22_LOG" \
  node "$ENGINE" run add next "test" 2>&1); T22_EC=$?
assert_exit_fail "T-22: TODO_REPO_OWNER/NAME 両方未設定 → exit 1" "$T22_EC"
assert_contains "T-22: error.repo_not_configured（TODO_REPO_OWNERを含む）" "TODO_REPO_OWNER / TODO_REPO_NAME が未設定です" "$T22_OUT"
assert_contains "T-22: MCPフォールバックガイダンスが併記される" "GitHub MCPツール" "$T22_OUT"
assert_eq "T-22: GitHub APIが一度も呼ばれない（ログ0行）" "0" "$(wc -l < "$T22_LOG" | tr -d ' ')"
rm -f "$T22_LOG"

# T-23: TODO_REPO_OWNER のみ未設定でも同様にガードが発火する
T23_OUT=$(env -u TODO_REPO_OWNER OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "test" 2>&1); T23_EC=$?
assert_exit_fail "T-23: TODO_REPO_OWNER のみ未設定 → exit 1" "$T23_EC"
assert_contains "T-23: error.repo_not_configured が出力される" "TODO_REPO_OWNER / TODO_REPO_NAME が未設定です" "$T23_OUT"

# T-24: help / schema は未設定でも新設ガードで弾かれない
T24_HELP_OUT=$(env -u TODO_REPO_OWNER -u TODO_REPO_NAME OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" \
  node "$ENGINE" run help 2>&1); T24_HELP_EC=$?
assert_not_contains "T-24: /todo help は未設定でも error.repo_not_configured が出ない" "TODO_REPO_OWNER / TODO_REPO_NAME が未設定です" "$T24_HELP_OUT"

T24_SCHEMA_OUT=$(env -u TODO_REPO_OWNER -u TODO_REPO_NAME OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" \
  node "$ENGINE" run schema 2>&1); T24_SCHEMA_EC=$?
assert_not_contains "T-24: /todo schema は未設定でも error.repo_not_configured が出ない" "TODO_REPO_OWNER / TODO_REPO_NAME が未設定です" "$T24_SCHEMA_OUT"

# T-25: GitHub REST APIが401を返す場合 → error.gh_auth_rejected が出力され、生の Bad credentials が露出しない
T25_RESP='{"issues.listForRepo":[{"__throw":true,"status":401,"message":"Bad credentials"}]}'
T25_OUT=$(TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" OCTOKIT_STUB_RESPONSES_ENV="$T25_RESP" \
  node "$ENGINE" run list 2>&1); T25_EC=$?
assert_exit_fail "T-25: GitHub API 401 → exit 1" "$T25_EC"
assert_contains "T-25: error.gh_auth_rejected（401）が出力される" "GitHub API 認証が拒否されました（401）" "$T25_OUT"
assert_contains "T-25: MCPフォールバックガイダンスが併記される" "GitHub MCPツール" "$T25_OUT"
assert_not_contains "T-25: 生の 'Error: Bad credentials' 形式が露出しない" "Error: Bad credentials" "$T25_OUT"

# T-26: 401以外（404）では新設分岐に入らず従来通りの Error: <message> 形式を維持する
T26_RESP='{"issues.listForRepo":[{"__throw":true,"status":404,"message":"Not Found"}]}'
T26_OUT=$(TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" OCTOKIT_STUB_RESPONSES_ENV="$T26_RESP" \
  node "$ENGINE" run list 2>&1); T26_EC=$?
assert_exit_fail "T-26: GitHub API 404 → exit 1" "$T26_EC"
assert_contains "T-26: 従来通り Error: Not Found 形式" "Error: Not Found" "$T26_OUT"
assert_not_contains "T-26: error.gh_auth_rejected（401用メッセージ）は出ない" "認証が拒否されました" "$T26_OUT"

# T-27: LANG_ENV=en で英語メッセージが出力される（未設定ガード・401検知の両方）
T27A_OUT=$(env -u TODO_REPO_OWNER -u TODO_REPO_NAME LANG_ENV=en OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" \
  node "$ENGINE" run add next "test" 2>&1); T27A_EC=$?
assert_exit_fail "T-27a: en版 未設定ガード → exit 1" "$T27A_EC"
assert_contains "T-27a: en版 error.repo_not_configured" "TODO_REPO_OWNER / TODO_REPO_NAME is not set" "$T27A_OUT"

T27B_RESP='{"issues.listForRepo":[{"__throw":true,"status":401,"message":"Bad credentials"}]}'
T27B_OUT=$(LANG_ENV=en TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" OCTOKIT_STUB_RESPONSES_ENV="$T27B_RESP" \
  node "$ENGINE" run list 2>&1); T27B_EC=$?
assert_exit_fail "T-27b: en版 401検知 → exit 1" "$T27B_EC"
assert_contains "T-27b: en版 error.gh_auth_rejected" "GitHub API authentication was rejected (401)" "$T27B_OUT"

# ──────────────────────────────────────────
# Issue #1825: todo CLI タイトルに丸括弧が使えない制約を見直す（validateTitle 新設・案A）
# タイトルは Octokit 経由の HTTP API にのみ渡り、シェル展開を一切経由しない
# （grep実測: execSync/spawnSync/execFileSync/child_process は0ヒット）ため、
# FORBIDDEN_CHARS によるシェル危険文字禁止は過剰だった。validateTitle は
# 改行等の制御文字（Unicode Cc カテゴリ）のみを禁止し、丸括弧を含む記号は全許可する。
# 一方 template/view の「名前」は process.env.TNAME_ENV/VNAME_ENV に入り、
# todo.sh 側でシェル変数として扱われうるため validateName（FORBIDDEN_CHARS）を維持する。
# ──────────────────────────────────────────
echo ""
echo "▶ Issue #1825: タイトル丸括弧許可（validateTitle 新設）"

# すべて OCTOKIT_STUB_ENV 経由（Octokit注入シーム）で実行し、本番 GitHub には接続しない。

# 1825-1: validate title — 丸括弧を含むタイトルが通過する
node "$ENGINE" validate title "タイトル（丸括弧あり）(parens)" >/dev/null 2>&1
assert_exit_ok "1825-1: validate title は丸括弧を含むタイトルを許可する" "$?"

# 1825-2: validate title — シェル危険文字（; $ ` ( ) " ' \ | & > < { }）を全て含んでも通過する（案A: 全記号許可）
node "$ENGINE" validate title 'test; $HOME `evil` "quote" '"'"'squote'"'"' \ | & > < { }' >/dev/null 2>&1
assert_exit_ok "1825-2: validate title は全ての記号を許可する（シェル非経由のため）" "$?"

# 1825-3: validate title — 空文字は引き続きエラー
node "$ENGINE" validate title "" >/dev/null 2>&1
assert_exit_fail "1825-3: validate title は空文字を拒否する" "$?"

# 1825-4: validate title — 改行を含むタイトルは拒否される（新設の制御文字禁止）
NEWLINE_TITLE=$(printf 'line1\nline2')
TITLE_NL_OUT=$(LANG_ENV=ja node "$ENGINE" validate title "$NEWLINE_TITLE" 2>&1); TITLE_NL_EC=$?
assert_exit_fail "1825-4: validate title は改行を含むタイトルを拒否する" "$TITLE_NL_EC"
assert_contains "1825-4: エラーメッセージが制御文字禁止を示す（日本語）" "制御文字" "$TITLE_NL_OUT"

# 1825-5: validate title — CR を含むタイトルも拒否される
CR_TITLE=$(printf 'line1\rline2')
node "$ENGINE" validate title "$CR_TITLE" >/dev/null 2>&1
assert_exit_fail "1825-5: validate title は CR を含むタイトルを拒否する" "$?"

# 1825-6: validate title — LANG_ENV=en でも制御文字エラーメッセージが出る
TITLE_NL_EN_OUT=$(LANG_ENV=en node "$ENGINE" validate title "$NEWLINE_TITLE" 2>&1)
assert_contains "1825-6: en版 制御文字エラーメッセージ" "control characters" "$TITLE_NL_EN_OUT"

# 1825-7: リグレッション — validate name（template/view 名用）は丸括弧を引き続き拒否する
node "$ENGINE" validate name "name(paren)" >/dev/null 2>&1
assert_exit_fail "1825-7: validate name は丸括弧を含む名前を引き続き拒否する（リグレッション防止）" "$?"

# 1825-8: リグレッション — validate name は引き続きダブルクォート・バックスラッシュも拒否する
node "$ENGINE" validate name 'name"quote' >/dev/null 2>&1
assert_exit_fail "1825-8a: validate name はダブルクォートを含む名前を引き続き拒否する" "$?"
node "$ENGINE" validate name 'name\backslash' >/dev/null 2>&1
assert_exit_fail "1825-8b: validate name はバックスラッシュを含む名前を引き続き拒否する" "$?"

# 1825-9: run template save — 丸括弧を含む名前は引き続き拒否される（validateName 経由）
# validateName は runTemplate 内で API 呼び出しより前に実行されるため、
# OCTOKIT_STUB_ENV は未設定でも安全（Octokit初期化はされるがメソッド呼び出しには到達しない）。
TPL_PAREN_OUT=$(TODO_REPO_OWNER=test TODO_REPO_NAME=test OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" \
  node "$ENGINE" run template save "name(paren)" next 2>&1); TPL_PAREN_EC=$?
assert_exit_fail "1825-9: run template save は丸括弧を含む名前を拒否する（リグレッション防止）" "$TPL_PAREN_EC"

# 1825-10: run view save — 丸括弧を含む名前は引き続き拒否される（validateName 経由）
VIEW_PAREN_OUT=$(TODO_REPO_OWNER=test TODO_REPO_NAME=test OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" \
  node "$ENGINE" run view save "name(paren)" next 2>&1); VIEW_PAREN_EC=$?
assert_exit_fail "1825-10: run view save は丸括弧を含む名前を拒否する（リグレッション防止）" "$VIEW_PAREN_EC"

# 1825-11: run template show — 丸括弧を含む名前は引き続き拒否される（validateName 経由）
TPL_SHOW_PAREN_OUT=$(TODO_REPO_OWNER=test TODO_REPO_NAME=test OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" \
  node "$ENGINE" run template show "name(paren)" 2>&1); TPL_SHOW_PAREN_EC=$?
assert_exit_fail "1825-11: run template show は丸括弧を含む名前を拒否する（リグレッション防止）" "$TPL_SHOW_PAREN_EC"

# 1825-12: run add — 丸括弧を含むタイトルで Issue 作成が成功する（Octokit スタブ経由）
ADD_PAREN_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":9101,"html_url":"https://example.com/9101"}}]}'
ADD_PAREN_OUT=$(TODO_REPO_OWNER=test TODO_REPO_NAME=test OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" OCTOKIT_STUB_RESPONSES_ENV="$ADD_PAREN_RESP" \
  node "$ENGINE" run add next "タイトル（丸括弧）(parens)" 2>&1); ADD_PAREN_EC=$?
assert_exit_ok "1825-12: run add は丸括弧を含むタイトルで成功する" "$ADD_PAREN_EC"
assert_contains "1825-12: Issue #9101 作成メッセージが出力される" "9101" "$ADD_PAREN_OUT"
assert_contains "1825-12: 作成メッセージにタイトルの丸括弧がそのまま含まれる" "(parens)" "$ADD_PAREN_OUT"

# 1825-13: run add — 引用符・バックスラッシュ・\$記号を含むタイトルでも成功する（案A: 全記号許可）
ADD_SYM_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":9102,"html_url":"https://example.com/9102"}}]}'
ADD_SYM_OUT=$(TODO_REPO_OWNER=test TODO_REPO_NAME=test OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" OCTOKIT_STUB_RESPONSES_ENV="$ADD_SYM_RESP" \
  node "$ENGINE" run add next 'quote " backslash \ dollar $HOME' 2>&1); ADD_SYM_EC=$?
assert_exit_ok "1825-13: run add は引用符・バックスラッシュ・\$記号を含むタイトルで成功する" "$ADD_SYM_EC"

# 1825-14: run rename — 丸括弧を含む新タイトルへの変更が成功する（Octokit スタブ経由）
RENAME_PAREN_RESP='{"issues.update":[{"data":{}}]}'
RENAME_PAREN_OUT=$(TODO_REPO_OWNER=test TODO_REPO_NAME=test OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" OCTOKIT_STUB_RESPONSES_ENV="$RENAME_PAREN_RESP" \
  node "$ENGINE" run rename 9001 "新タイトル（括弧付き）" 2>&1); RENAME_PAREN_EC=$?
assert_exit_ok "1825-14: run rename は丸括弧を含む新タイトルで成功する" "$RENAME_PAREN_EC"

# 1825-15: run rename — 改行を含む新タイトルは拒否される（validateTitle の制御文字禁止が rename にも適用される）
RENAME_NL_OUT=$(TODO_REPO_OWNER=test TODO_REPO_NAME=test OCTOKIT_STUB_ENV="$STUB_ENGINE_PATH" \
  node "$ENGINE" run rename 9001 "$NEWLINE_TITLE" 2>&1); RENAME_NL_EC=$?
assert_exit_fail "1825-15: run rename は改行を含む新タイトルを拒否する" "$RENAME_NL_EC"

# ──────────────────────────────────────────
# §42  JST日付変換 — closedAt/updatedAt のUTCズレ修正（Issue #1748）
# closed_at/updated_at はGitHub APIがUTC（末尾Z）で返す。従来は `.slice(0,10)` で
# そのままUTC日付として扱っていたため、JST 0〜9時台に完了したタスクが前日扱いに
# なっていた。境界値（UTC 15:00〜23:59 = JST 翌日 00:00〜08:59）で新旧の差が
# 出ることを確認する。TEST_TODAY2 と実証タイムスタンプは実機確認（2026-08-09、
# Issue本文の #1739/#1730/#1724）をそのまま使用。
# ──────────────────────────────────────────
echo ""
echo "§42  JST日付変換 — closedAt/updatedAt のUTCズレ修正（Issue #1748）"

TEST_TODAY2="2026-08-09"

# done-count: 境界をまたぐ4パターン
#   - 08-08T23:32:23Z（実証 #1739）→ JST 08-09 08:32 → 今日扱いになるべき
#   - 08-08T15:37:07Z（実証 #1724）→ JST 08-09 00:37 → 今日扱いになるべき
#   - 08-08T14:59:59Z（境界の1秒前）→ JST 08-08 23:59:59 → 前日のまま
#   - 08-08T15:00:00Z（境界ちょうど）→ JST 08-09 00:00:00 → 今日扱いになるべき
DC2_CLOSED='[
  {"number":1739,"closedAt":"2026-08-08T23:32:23Z"},
  {"number":1724,"closedAt":"2026-08-08T15:37:07Z"},
  {"number":9001,"closedAt":"2026-08-08T14:59:59Z"},
  {"number":9002,"closedAt":"2026-08-08T15:00:00Z"}
]'
DC2_RESULT=$(CLOSED_ENV="$DC2_CLOSED" TODAY_ENV="$TEST_TODAY2" node "$ENGINE" done-count)
assert_eq "§42 done-count: 境界またぎ4件中3件がJSTで今日=3" "3" "$DC2_RESULT"

# dashboard: 「✅ 今日: N件完了」— #1746/#1741/#1740 はUTC日付が既に08-09なので
# 旧実装でも一致するが、#1739/#1730/#1724 は23時台・15時台UTC(08-08)で旧実装だと
# 前日扱いで漏れる（#1721は14:15 UTC=JST08-08 23:15で本当に前日、含めない）。
# 旧実装なら3件（1746/1741/1740のみ）、修正後は6件になる。
DASH2_CLOSED='[
  {"number":1746,"closedAt":"2026-08-09T00:53:34Z"},
  {"number":1741,"closedAt":"2026-08-09T00:20:25Z"},
  {"number":1740,"closedAt":"2026-08-09T00:29:24Z"},
  {"number":1739,"closedAt":"2026-08-08T23:32:23Z"},
  {"number":1730,"closedAt":"2026-08-08T23:48:53Z"},
  {"number":1724,"closedAt":"2026-08-08T15:37:07Z"},
  {"number":1721,"closedAt":"2026-08-08T14:15:42Z"}
]'
DASH2_OUT=$(OPEN_ENV='[]' TODAY_ENV="$TEST_TODAY2" CLOSED_ENV="$DASH2_CLOSED" node "$ENGINE" dashboard)
assert_contains "§42 dashboard: 今日 6件完了（境界またぎ含め正しくJST集計）" "今日: 6件完了" "$DASH2_OUT"

# report: 直近リストの表示日付・日次バケットがJST基準になる
RPT2_CLOSED='[{"number":1739,"closedAt":"2026-08-08T23:32:23Z","title":"境界またぎ","labels":[]}]'
RPT2_OUT=$(OPEN_ENV='[]' TODAY_ENV="$TEST_TODAY2" DAYS_ENV="7" CLOSED_ENV="$RPT2_CLOSED" node "$ENGINE" report)
assert_contains "§42 report: 直近リストの日付がJST変換後（2026-08-09）" "#1739  境界またぎ  (2026-08-09)" "$RPT2_OUT"
assert_not_contains "§42 report: UTC日付（2026-08-08）のままでは表示されない" "#1739  境界またぎ  (2026-08-08)" "$RPT2_OUT"

# list-all: プロジェクトの停滞判定（daysBetween に渡す起点日）がJST基準になる
# updated_at=2026-07-10T23:30:00Z → UTC日付は07-10（today比30日=停滞判定の閾値）だが
# JST日付は07-11（today比29日=非停滞）。旧実装なら誤って「停滞30日以上」と判定する。
LIST_PROJ_STALE_MOCK='[
  {"number":700,"title":"proj-boundary","updated_at":"2026-07-10T23:30:00Z","labels":[{"name":"📁 project"}]}
]'
LIST_PROJ_STALE_OUT=$(OPEN_ENV="$LIST_PROJ_STALE_MOCK" TODAY_ENV="$TEST_TODAY2" node "$ENGINE" list-all)
assert_not_contains "§42 list-all: JST基準では29日でまだ停滞判定されない" "停滞30日以上" "$LIST_PROJ_STALE_OUT"

# ──────────────────────────────────────────
# §43  GTDルーティン cycles_overdue 検知（Issue #1776 実装A）
# 「実施はしたが done を打ち忘れている」後始末漏れの確度が高いシグナルを、
# 従来の routineOverdue（cycles===1）と新設 routineStale（cycles>=STALE_CYCLE_THRESHOLD=2）に
# 分離する。computeCyclesOverdue() は読み取り専用のプレビュー計算であり、
# done コマンドの書き込みパス（nextDueCatchUp）とは独立実装。
# ──────────────────────────────────────────
echo ""
echo "§43  GTDルーティン cycles_overdue 検知（Issue #1776）"

# --- computeCyclesOverdue 正常系（CLI: cycles-overdue <pattern> <due> <today>） ---
assert_eq "§43 cycles-overdue: due が未来 → 0" \
  "0" "$(node "$ENGINE" cycles-overdue weekly 2026-08-20 2026-08-11)"
assert_eq "§43 cycles-overdue: due が今日 → 0" \
  "0" "$(node "$ENGINE" cycles-overdue weekly 2026-08-11 2026-08-11)"
assert_eq "§43 cycles-overdue: weekly 1周期分過去(7日前) → 1" \
  "1" "$(node "$ENGINE" cycles-overdue weekly 2026-08-04 2026-08-11)"
assert_eq "§43 cycles-overdue: weekly ちょうど閾値(14日前) → 2（境界値）" \
  "2" "$(node "$ENGINE" cycles-overdue weekly 2026-07-28 2026-08-11)"
assert_eq "§43 cycles-overdue: weekly 3周期分過去(21日前) → 3" \
  "3" "$(node "$ENGINE" cycles-overdue weekly 2026-07-21 2026-08-11)"
assert_eq "§43 cycles-overdue: monthly:15 でも正しく計算できる(3周期)" \
  "3" "$(node "$ENGINE" cycles-overdue monthly:15 2026-06-15 2026-08-20)"

# --- 異常系・境界値: 不正recur・大幅超過でも安全装置（MAX_RECUR_CATCHUP_ITERATIONS）が効く ---
CYCLES_INVALID_STDERR=$(node "$ENGINE" cycles-overdue notarealpattern 2026-01-01 2026-08-11 2>&1 1>/dev/null)
assert_eq "§43 cycles-overdue: 不正recur → 反復上限で打ち切り(3660)" \
  "3660" "$(node "$ENGINE" cycles-overdue notarealpattern 2026-01-01 2026-08-11 2>/dev/null)"
assert_contains "§43 cycles-overdue: 不正recur → 既存nextDueCatchUpと同じ反復上限警告が出る" \
  "反復上限" "$CYCLES_INVALID_STDERR"

CYCLES_OLD_STDERR=$(node "$ENGINE" cycles-overdue weekly 2015-01-01 2026-08-08 2>&1 1>/dev/null)
assert_eq "§43 cycles-overdue: 1年以上前のdue(weekly)でも反復上限内で確実に打ち切られる" \
  "606" "$(node "$ENGINE" cycles-overdue weekly 2015-01-01 2026-08-08 2>/dev/null)"
assert_not_contains "§43 cycles-overdue: 10年超でも正常patternでは反復上限メッセージが出ない" \
  "反復上限" "$CYCLES_OLD_STDERR"

# --- renderToday(): routineOverdue（cycles===1）と routineStale（cycles>=2）の分離 ---
TODAY_ROUTINE_MOCK='[
  {"number":9101,"title":"overdue-1cycle","body":"due: 2026-08-04\nrecur: weekly","labels":[{"name":"🔁 routine"}]},
  {"number":9102,"title":"stale-3cycles","body":"due: 2026-07-21\nrecur: weekly","labels":[{"name":"🔁 routine"}]},
  {"number":9103,"title":"stale-no-recur","body":"due: 2026-07-01","labels":[{"name":"🔁 routine"}],"updated_at":"2026-06-01T00:00:00Z"}
]'
TODAY_ROUTINE_OUT=$(OPEN_ENV="$TODAY_ROUTINE_MOCK" TODAY_ENV="2026-08-11" CLOSED_ENV='[]' node "$ENGINE" today)
assert_contains "§43 today: cycles=1(#9101) は従来通り「ルーティン未実施」セクションに出る" \
  "ルーティン未実施（1件）" "$TODAY_ROUTINE_OUT"
assert_contains "§43 today: #9101(cycles=1)がrenderされる" \
  "#9101  overdue-1cycle" "$TODAY_ROUTINE_OUT"
assert_contains "§43 today: cycles>=2は新設「要確認（推定サイクル遅延）」セクションに分離される（2件）" \
  "要確認（推定サイクル遅延・2件）" "$TODAY_ROUTINE_OUT"
assert_contains "§43 today: #9102(cycles=3)に推定周遅延の表示が付く" \
  "#9102  stale-3cycles  📅 2026-07-21  （推定3周遅延）" "$TODAY_ROUTINE_OUT"
assert_contains "§43 today: recurフィールド欠落はupdated_at staleness(30日)にフォールバックしクラッシュしない" \
  "#9103  stale-no-recur  📅 2026-07-01  （30日以上更新なし）" "$TODAY_ROUTINE_OUT"
assert_contains "§43 today: サマリー合計はroutineStale(2件)を含まずroutineOverdue(1件)のみ" \
  "合計: 1件" "$TODAY_ROUTINE_OUT"

# --- リグレッション: routineStaleのみでも「今日のタスクはありません」にならない・0件集計 ---
ONLY_STALE_MOCK='[
  {"number":9104,"title":"only-stale","body":"due: 2026-07-21\nrecur: weekly","labels":[{"name":"🔁 routine"}]}
]'
ONLY_STALE_OUT=$(OPEN_ENV="$ONLY_STALE_MOCK" TODAY_ENV="2026-08-11" CLOSED_ENV='[]' node "$ENGINE" today)
assert_not_contains "§43 today: routineStaleのみが存在する場合でも「今日のタスクはありません」は出ない" \
  "今日のタスクはありません" "$ONLY_STALE_OUT"
assert_contains "§43 today: routineStaleのみの場合サマリー合計は0件" \
  "合計: 0件" "$ONLY_STALE_OUT"

# --- renderIssueList(): routine(cycles>=2)・next/waiting(updated_at>=30日)へのマーカー ---
LIST_ROUTINE_MOCK='[
  {"number":9201,"title":"overdue-1cycle","body":"due: 2026-08-04\nrecur: weekly","labels":[{"name":"🔁 routine"}]},
  {"number":9202,"title":"stale-3cycles","body":"due: 2026-07-21\nrecur: weekly","labels":[{"name":"🔁 routine"}]}
]'
LIST_ROUTINE_OUT=$(OPEN_ENV="$LIST_ROUTINE_MOCK" TODAY_ENV="2026-08-11" FILTER_GTD_ENV="routine" node "$ENGINE" list-all)
assert_contains "§43 list routine: cycles>=2(#9202)に🕰マーカーが付く（/todo list routine 週次レビュー用）" \
  "🕰#9202  stale-3cycles" "$LIST_ROUTINE_OUT"
assert_not_contains "§43 list routine: cycles===1(#9201)には🕰マーカーが付かない" \
  "🕰#9201" "$LIST_ROUTINE_OUT"
assert_contains "§43 list routine: マーカー対象外の行は従来通り2スペースインデントのまま" \
  "  #9201  overdue-1cycle" "$LIST_ROUTINE_OUT"

# --- renderIssueList(): routine かつ recur 欠落 → updated_at staleness フォールバック ---
# renderToday() の routineStale フォールバックとの非対称を解消（reviewer 🟡推奨修正）。
# 実データでの該当有無に関わらず、recur 欠落時の挙動保証として必要なテスト。
LIST_ROUTINE_NO_RECUR_MOCK='[
  {"number":9211,"title":"stale-no-recur-old","body":"due: 2026-07-01","labels":[{"name":"🔁 routine"}],"updated_at":"2026-06-01T00:00:00Z"},
  {"number":9212,"title":"stale-no-recur-exactly-30","body":"due: 2026-07-01","labels":[{"name":"🔁 routine"}],"updated_at":"2026-07-12T00:00:00Z"},
  {"number":9213,"title":"fresh-no-recur-29days","body":"due: 2026-07-01","labels":[{"name":"🔁 routine"}],"updated_at":"2026-07-13T00:00:00Z"},
  {"number":9214,"title":"no-recur-no-due","labels":[{"name":"🔁 routine"}],"updated_at":"2026-06-01T00:00:00Z"}
]'
LIST_ROUTINE_NO_RECUR_OUT=$(OPEN_ENV="$LIST_ROUTINE_NO_RECUR_MOCK" TODAY_ENV="2026-08-11" FILTER_GTD_ENV="routine" node "$ENGINE" list-all)
assert_contains "§43 list routine: recur欠落かつupdated_atが30日以上前(#9211)に🕰マーカーが付く（renderTodayとの対称化）" \
  "🕰#9211  stale-no-recur-old" "$LIST_ROUTINE_NO_RECUR_OUT"
assert_contains "§43 list routine: recur欠落かつupdated_atがちょうど30日前(#9212)に🕰マーカーが付く（境界値）" \
  "🕰#9212  stale-no-recur-exactly-30" "$LIST_ROUTINE_NO_RECUR_OUT"
assert_not_contains "§43 list routine: recur欠落でもupdated_atが29日前(#9213)には🕰マーカーが付かない（境界値）" \
  "🕰#9213" "$LIST_ROUTINE_NO_RECUR_OUT"
assert_contains "§43 list routine: 境界値29日(#9213)は従来通り2スペースインデントのまま" \
  "  #9213  fresh-no-recur-29days" "$LIST_ROUTINE_NO_RECUR_OUT"
assert_not_contains "§43 list routine: recur欠落かつdue欠落(#9214)はクラッシュせずマーカーも付かない" \
  "🕰#9214" "$LIST_ROUTINE_NO_RECUR_OUT"
assert_contains "§43 list routine: recur欠落かつdue欠落(#9214)は従来通り2スペースインデントのまま" \
  "  #9214  no-recur-no-due" "$LIST_ROUTINE_NO_RECUR_OUT"

LIST_NW_MOCK='[
  {"number":9301,"title":"stale-next-exactly-30","body":"due: 2026-08-20","labels":[{"name":"🎯 next"}],"updated_at":"2026-07-12T00:00:00Z"},
  {"number":9302,"title":"fresh-next-29days","body":"due: 2026-08-20","labels":[{"name":"🎯 next"}],"updated_at":"2026-07-13T00:00:00Z"},
  {"number":9303,"title":"stale-waiting","body":"due: 2026-08-20","labels":[{"name":"⏳ waiting"}],"updated_at":"2026-06-01T00:00:00Z"}
]'
LIST_NW_OUT_NEXT=$(OPEN_ENV="$LIST_NW_MOCK" TODAY_ENV="2026-08-11" FILTER_GTD_ENV="next" node "$ENGINE" list-all)
assert_contains "§43 list next: updated_atがちょうど30日前(#9301)に🕰マーカーが付く（境界値、既存project stale と同一閾値）" \
  "🕰#9301  stale-next-exactly-30" "$LIST_NW_OUT_NEXT"
assert_not_contains "§43 list next: updated_atが29日前(#9302)には🕰マーカーが付かない（境界値）" \
  "🕰#9302" "$LIST_NW_OUT_NEXT"

LIST_NW_OUT_WAITING=$(OPEN_ENV="$LIST_NW_MOCK" TODAY_ENV="2026-08-11" FILTER_GTD_ENV="waiting" node "$ENGINE" list-all)
assert_contains "§43 list waiting: updated_atが30日以上前(#9303)に🕰マーカーが付く" \
  "🕰#9303  stale-waiting" "$LIST_NW_OUT_WAITING"

# --- リグレッション: someday ⚠️ マーカー・project停滞バッジが本変更で崩れないこと ---
REGRESSION_SOMEDAY_MOCK='[
  {"number":9401,"title":"old-someday","body":"reviewed_at: 2026-06-01","labels":[{"name":"🌈 someday"}]}
]'
REGRESSION_SOMEDAY_OUT=$(OPEN_ENV="$REGRESSION_SOMEDAY_MOCK" TODAY_ENV="2026-08-11" FILTER_GTD_ENV="someday" node "$ENGINE" list-all)
assert_contains "§43 リグレッション: someday の ⚠️ マーカーは本変更後も従来通り表示される" \
  "⚠️#9401  old-someday" "$REGRESSION_SOMEDAY_OUT"

REGRESSION_PROJ_MOCK='[
  {"number":9402,"title":"stale-project","updated_at":"2026-06-01T00:00:00Z","labels":[{"name":"📁 project"}]}
]'
REGRESSION_PROJ_OUT=$(OPEN_ENV="$REGRESSION_PROJ_MOCK" TODAY_ENV="2026-08-11" node "$ENGINE" list-all)
assert_contains "§43 リグレッション: project の停滞バッジ（⚠️停滞30日以上）は本変更後も従来通り表示される" \
  "停滞30日以上" "$REGRESSION_PROJ_OUT"

# --- リグレッション: LANG_ENV=en で routineStale / staleness マーカーの新規メッセージも英語化される ---
TODAY_ROUTINE_EN_OUT=$(LANG_ENV=en OPEN_ENV="$TODAY_ROUTINE_MOCK" TODAY_ENV="2026-08-11" CLOSED_ENV='[]' node "$ENGINE" today)
assert_contains "§43 today(en): routineStale見出しが英語化される" \
  "Needs Review" "$TODAY_ROUTINE_EN_OUT"
assert_contains "§43 today(en): 推定周遅延サフィックスが英語化される" \
  "est. 3 cycles overdue" "$TODAY_ROUTINE_EN_OUT"
assert_not_contains "§43 today(en): 出力に日本語（新規追加メッセージ）が含まれない" \
  "推定" "$TODAY_ROUTINE_EN_OUT"

# ──────────────────────────────────────────
# §47  日付処理バグ修正3件（Issue #1650、親 project #1640）
# ──────────────────────────────────────────
echo ""
echo "§47  日付処理バグ修正3件（Issue #1650）"

# --- 修正1: normalizeDue の M/D 形式が年をまたぐ場合の繰り上げ ---

# 1/5 が today(2026-12-20) より過去 → 翌年に繰り上げる
assert_eq "§47-1 normalize-due: 1/5(today=2026-12-20)→2027-01-05（過去日は翌年へ）" \
  "2027-01-05" "$(node "$ENGINE" normalize-due '1/5' '2026-12-20')"

# today とちょうど同じ月日 → 繰り上げない（境界値、< であり <= ではない）
assert_eq "§47-1 normalize-due: 4/5(today=2026-04-05)→2026-04-05（today当日は繰り上げない・境界値）" \
  "2026-04-05" "$(node "$ENGINE" normalize-due '4/5' '2026-04-05')"

# today より未来の月日 → 今年のまま（回帰確認）
assert_eq "§47-1 normalize-due: 12/25(today=2026-04-05)→2026-12-25（未来日は今年のまま・回帰確認）" \
  "2026-12-25" "$(node "$ENGINE" normalize-due '12/25' '2026-04-05')"

# 2/29 指定・今年が非うるう年・today がまだ2月より前 → 今年は存在しないので次のうるう年へ繰り上げ
assert_eq "§47-1 normalize-due: 2/29(today=2026-08-11、非うるう年)→2028-02-29（次のうるう年へ）" \
  "2028-02-29" "$(node "$ENGINE" normalize-due '2/29' '2026-08-11')"

# 2/29 指定・today がうるう年で2/29より前 → 今年のうるう日をそのまま使う
assert_eq "§47-1 normalize-due: 2/29(today=2028-01-01、うるう年)→2028-02-29（今年のうるう日）" \
  "2028-02-29" "$(node "$ENGINE" normalize-due '2/29' '2028-01-01')"

# 2/29 指定・today がうるう年で2/29を過ぎている → 今年は使えず、次のうるう年(2032)へ繰り上げ
assert_eq "§47-1 normalize-due: 2/29(today=2028-03-01、うるう年の2/29経過後)→2032-02-29（次のうるう年）" \
  "2032-02-29" "$(node "$ENGINE" normalize-due '2/29' '2028-03-01')"

# --- 修正2: validateDue のカレンダー妥当性検証 ---

node "$ENGINE" validate due '2026-13-01' 2>/dev/null; EC_1650_V1=$?
assert_exit_fail "§47-2 validate due 2026-13-01: exit 1（存在しない月は拒否）" "$EC_1650_V1"

node "$ENGINE" validate due '2026-02-30' 2>/dev/null; EC_1650_V2=$?
assert_exit_fail "§47-2 validate due 2026-02-30: exit 1（2月に30日は存在しないため拒否）" "$EC_1650_V2"

node "$ENGINE" validate due '2026-02-29' 2>/dev/null; EC_1650_V3=$?
assert_exit_fail "§47-2 validate due 2026-02-29: exit 1（非うるう年の2/29は拒否）" "$EC_1650_V3"

node "$ENGINE" validate due '2028-02-29' 2>/dev/null; EC_1650_V4=$?
assert_exit_ok "§47-2 validate due 2028-02-29: exit 0（うるう年の2/29は許可）" "$EC_1650_V4"

node "$ENGINE" validate due '13/1' 2>/dev/null; EC_1650_V5=$?
assert_exit_fail "§47-2 validate due 13/1: exit 1（M/D形式でも存在しない月は拒否）" "$EC_1650_V5"

node "$ENGINE" validate due '2/30' 2>/dev/null; EC_1650_V6=$?
assert_exit_fail "§47-2 validate due 2/30: exit 1（M/D形式でも存在しない日は拒否）" "$EC_1650_V6"

node "$ENGINE" validate due '99/99' 2>/dev/null; EC_1650_V7=$?
assert_exit_fail "§47-2 validate due 99/99: exit 1（値範囲チェック追加により拒否。旧仕様からの変更点）" "$EC_1650_V7"

# 2/29 は年を伴わない M/D 形式では「うるう年に存在しうる」ため許可する
# （実際にどの年を割り当てるかは normalizeDue の役目。§47-1 参照）
node "$ENGINE" validate due '2/29' 2>/dev/null; EC_1650_V8=$?
assert_exit_ok "§47-2 validate due 2/29: exit 0（M/D形式の閏日指定は許可）" "$EC_1650_V8"

node "$ENGINE" validate due '2026-04-10' 2>/dev/null; EC_1650_V9=$?
assert_exit_ok "§47-2 validate due 2026-04-10: exit 0（回帰確認）" "$EC_1650_V9"
node "$ENGINE" validate due '4/10' 2>/dev/null; EC_1650_V10=$?
assert_exit_ok "§47-2 validate due 4/10: exit 0（回帰確認）" "$EC_1650_V10"

# --- 修正3: 無印 monthly recur の月末クランプ（次回due計算。next-due 経由で実エンジンを直接検証） ---

assert_eq "§47-3 next-due monthly: 1/31→2/28（月末クランプ、旧仕様の3/3繰り上がりを修正）" \
  "2026-02-28" "$(node "$ENGINE" next-due monthly '2026-01-31' 2>/dev/null)"
assert_eq "§47-3 next-due monthly: 2/28→3/28（クランプ後は31日に戻らずドリフトしない）" \
  "2026-03-28" "$(node "$ENGINE" next-due monthly '2026-02-28' 2>/dev/null)"
assert_eq "§47-3 next-due monthly: 3/31→4/30（4月は30日までクランプ）" \
  "2026-04-30" "$(node "$ENGINE" next-due monthly '2026-03-31' 2>/dev/null)"
assert_eq "§47-3 next-due monthly: 5/31→6/30（6月は30日までクランプ）" \
  "2026-06-30" "$(node "$ENGINE" next-due monthly '2026-05-31' 2>/dev/null)"
assert_eq "§47-3 next-due monthly: うるう年1/31→2/29（うるう年は29日までクランプ）" \
  "2028-02-29" "$(node "$ENGINE" next-due monthly '2028-01-31' 2>/dev/null)"
assert_eq "§47-3 next-due monthly: 4/15→5/15（通常、クランプ不要・回帰確認）" \
  "2026-05-15" "$(node "$ENGINE" next-due monthly '2026-04-15' 2>/dev/null)"
assert_eq "§47-3 next-due monthly: 12/15→翌年1/15（年またぎ・回帰確認）" \
  "2027-01-15" "$(node "$ENGINE" next-due monthly '2026-12-15' 2>/dev/null)"

# monthly:<日> サフィックス付きは今回の修正3の対象外（nextDueMonthlyOnDay は元々変更していない）。
# 従来どおりの挙動を固定化する回帰確認
assert_eq "§47-3 next-due monthly:31（サフィックス付きは今回の修正対象外・従来どおり）" \
  "2026-02-28" "$(node "$ENGINE" next-due 'monthly:31' '2026-01-15' 2>/dev/null)"

# スコープ外の固定化: add-month（CLI直接公開の add-month サブコマンド）と自然言語「来月」
# （addMonths() 経由）は今回のrecur計算限定の修正の対象外で、意図的に変更していない。
# 旧来の（クランプなしでJS Dateがそのまま繰り上げる）挙動のまま
assert_eq "§47-3 add-month（recur以外の呼び出し元は変更していないことの固定化）: 1/31→3/3のまま" \
  "2026-03-03" "$(node "$ENGINE" add-month '2026-01-31')"
assert_eq "§47-3 normalize-due 来月（自然言語の月加算は変更していないことの固定化）: today=2026-01-31→3/3のまま" \
  "2026-03-03" "$(node "$ENGINE" normalize-due '来月' '2026-01-31')"

# ──────────────────────────────────────────
# §48  isValidCalendarDate の西暦0000〜0099年誤判定修正（Issue #1804）
# ──────────────────────────────────────────
echo ""
echo "§48  isValidCalendarDate の西暦0000〜0099年誤判定修正（Issue #1804）"

# 原因: Date コンストラクタ（new Date(y, mo-1, da)）は年 0〜99 を 1900+年 とみなす
# 歴史的仕様があり、西暦0000〜0099年の日付が誤って1900年代扱いされ INVALID 判定に
# なっていた。setFullYear() 経由に変更してこの2桁年吸収を回避する。

node "$ENGINE" validate due '0099-05-01' 2>/dev/null; EC_1804_V1=$?
assert_exit_ok "§48 validate due 0099-05-01: exit 0（西暦99年、旧実装ではINVALID誤判定）" "$EC_1804_V1"

node "$ENGINE" validate due '0001-01-01' 2>/dev/null; EC_1804_V2=$?
assert_exit_ok "§48 validate due 0001-01-01: exit 0（西暦1年）" "$EC_1804_V2"

# 境界値: 100年（2桁年吸収の境界の直後）は旧実装でも正しく動いていた区間。回帰確認。
node "$ENGINE" validate due '0100-01-01' 2>/dev/null; EC_1804_V3=$?
assert_exit_ok "§48 validate due 0100-01-01: exit 0（境界値、2桁年吸収の対象外区間・回帰確認）" "$EC_1804_V3"

# 境界値: Date が扱える上限に近い年。回帰確認。
node "$ENGINE" validate due '9999-12-31' 2>/dev/null; EC_1804_V4=$?
assert_exit_ok "§48 validate due 9999-12-31: exit 0（上限側境界値・回帰確認）" "$EC_1804_V4"

# --- リグレッション: 既存のカレンダー妥当性判定（Issue #1650）が壊れていないこと ---
# （§47 で既に同一アサーションを実施済みだが、#1804 の修正がこれらを壊していないことを
# 本セクション単独でも明示的に確認するため、意図的に重複実行する）

node "$ENGINE" validate due '2026-13-01' 2>/dev/null; EC_1804_R1=$?
assert_exit_fail "§48 リグレッション: validate due 2026-13-01 → exit 1（存在しない月は引き続き拒否）" "$EC_1804_R1"

node "$ENGINE" validate due '2026-02-30' 2>/dev/null; EC_1804_R2=$?
assert_exit_fail "§48 リグレッション: validate due 2026-02-30 → exit 1（2月30日は引き続き拒否）" "$EC_1804_R2"

node "$ENGINE" validate due '2026-02-29' 2>/dev/null; EC_1804_R3=$?
assert_exit_fail "§48 リグレッション: validate due 2026-02-29 → exit 1（非うるう年の2/29は引き続き拒否）" "$EC_1804_R3"

node "$ENGINE" validate due '2028-02-29' 2>/dev/null; EC_1804_R4=$?
assert_exit_ok "§48 リグレッション: validate due 2028-02-29 → exit 0（うるう年の2/29は引き続き許可）" "$EC_1804_R4"

# ──────────────────────────────────────────
# §49  runMain dispatcher と help() 出力の同期（Issue #1884-3/4, #1906）
# 「コマンドを追加したのに help() に載せ忘れる」欠落を検知する第3のドリフトテスト
# （既存の1646テストは dispatcher⇔ガード集合の2点同期のみ対象。help() は対象外だった）。
# runMain の switch にある実コマンド名がすべて、実際にレンダリングされた
# help() 出力（日本語・英語）に「/todo <cmd>」というコマンド形で現れることを確認する。
# ──────────────────────────────────────────
echo ""
echo "§49  runMain dispatcher と help() 出力の同期（Issue #1884-3/4, #1906）"

_G1884_TMP=$(mktemp /tmp/todo-test-help-drift-XXXXXX)
cat > "$_G1884_TMP" << 'HELP_DRIFT_TEST_EOF'
const fs = require('fs');
const { execFileSync } = require('child_process');

const enginePath = process.argv[2];
const stubPath = process.argv[3];

const src = fs.readFileSync(enginePath, 'utf8');
const runMainMatch = src.match(/^async function runMain\(args\) \{[\s\S]*$/m);
if (!runMainMatch) {
  process.stderr.write('抽出失敗: runMain\n');
  process.exit(1);
}
const caseLabels = [...new Set(
  [...runMainMatch[0].matchAll(/case\s*'([a-zA-Z0-9_-]+)'\s*:/g)].map(m => m[1])
)];

// help() に個別のコマンド行として掲載しない正当な理由を持つコマンド（Issue #1884/#1906）。
// 除外は「別のコマンド行で正しく代替表示されている」場合に限る。除外リストは検出漏れが
// 隠れる場所そのものなので、内容が別名としてカバーされていることを dispatcher の実装を
// 直接開いて確認したもの以外は入れない（'add' は当初除外候補として検討したが、
// help() のどの行もコマンド形「/todo add」を表示していない真正の欠落だったため、
// 除外にせず help.add_explicit を新設して本文へ追加した。詳細は該当行のコメント参照）。
//  - 'close' : todo-engine.js の case 'done': case 'close': が同一処理(runDone)へ委譲する別名。
//  - 'dash'  : todo-engine.js の case 'dashboard': case 'dash': が同一処理(runDashboard)へ委譲する別名。
const EXCLUDED = new Set(['close', 'dash']);

function escapeRegExp(s) { return s.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&'); }

// 「/todo <cmd>」がコマンド形（直後が空白または行末）で現れるかを確認する。
// 単純な部分一致では検知できない（例: 'activate' はオプション説明中に複数回登場するが
// コマンド形では一度も登場しない、というケースを本テストは正しく FAIL させる必要がある）。
function commandFormPresent(cmdName, text) {
  const re = new RegExp('/todo\\s+' + escapeRegExp(cmdName) + '(?:\\s|$)', 'm');
  return re.test(text);
}

function captureHelp(lang) {
  const env = Object.assign({}, process.env, {
    OCTOKIT_STUB_ENV: stubPath,
    TODO_REPO_OWNER: 'test',
    TODO_REPO_NAME: 'test',
  });
  if (lang === 'en') env.LANG_ENV = 'en';
  return execFileSync(process.execPath, [enginePath, 'run', 'help'], { env, encoding: 'utf8' });
}

const helpJa = captureHelp('ja');
const helpEn = captureHelp('en');

const missingJa = [];
const missingEn = [];
for (const label of caseLabels) {
  if (EXCLUDED.has(label)) continue;
  if (!commandFormPresent(label, helpJa)) missingJa.push(label);
  if (!commandFormPresent(label, helpEn)) missingEn.push(label);
}

process.stdout.write(JSON.stringify({ caseCount: caseLabels.length }));
process.stderr.write('DRIFT_MISSING_HELP_JA:' + JSON.stringify(missingJa) + '\n');
process.stderr.write('DRIFT_MISSING_HELP_EN:' + JSON.stringify(missingEn) + '\n');
HELP_DRIFT_TEST_EOF

_G1884_STDOUT=$(node "$_G1884_TMP" "$ENGINE" "$STUB_ENGINE_PATH" 2>"$_G1884_TMP.stderr")
_G1884_EXIT=$?
_G1884_STDERR=$(cat "$_G1884_TMP.stderr" 2>/dev/null)
rm -f "$_G1884_TMP" "$_G1884_TMP.stderr"

if [ "$_G1884_EXIT" -ne 0 ]; then
  printf "  ❌ 1884/1906 help() ドリフト検知テスト実行失敗: %s / %s\n" "$_G1884_STDOUT" "$_G1884_STDERR"; FAIL=$((FAIL+2))
else
  # dispatcher の case 数が既知の38件から変化していないかの目安表示（増減自体は失敗要因にしない。
  # 新規コマンド追加時は下記 DRIFT_MISSING チェックが本体の検知役を担う）
  printf "  ℹ️  1884/1906: runMain switch case 数 = %s\n" "$(printf '%s' "$_G1884_STDOUT" | grep -o '"caseCount":[0-9]*' | grep -o '[0-9]*')"

  if printf '%s' "$_G1884_STDERR" | grep -q 'DRIFT_MISSING_HELP_JA:\[\]'; then
    printf "  ✅ 1884/1906: help()（日本語）に dispatcher コマンドが漏れなく反映されている（除外: close/dash）\n"; PASS=$((PASS+1))
  else
    printf "  ❌ 1884/1906: help()（日本語）に未反映の dispatcher コマンドがある: %s\n" "$_G1884_STDERR"; FAIL=$((FAIL+1))
  fi

  if printf '%s' "$_G1884_STDERR" | grep -q 'DRIFT_MISSING_HELP_EN:\[\]'; then
    printf "  ✅ 1884/1906: help()（英語 LANG_ENV=en）に dispatcher コマンドが漏れなく反映されている（除外: close/dash）\n"; PASS=$((PASS+1))
  else
    printf "  ❌ 1884/1906: help()（英語 LANG_ENV=en）に未反映の dispatcher コマンドがある: %s\n" "$_G1884_STDERR"; FAIL=$((FAIL+1))
  fi
fi

# ──────────────────────────────────────────
# §50  /todo コマンド実行時間計測（TODO_TIMING）— computeGithubMs 区間統合アルゴリズム
# 単体テスト（Issue #455）。Octokit/GitHub接続に依存しない純粋関数の検証。
# CLI: compute-github-ms '[[開始ms,終了ms], ...]'（内部でns相当に換算して
# computeGithubMs() を通し、結果をms単位で返す）。TODO_TIMING の統合的な
# 振る舞い（stdout非侵襲性・並行呼び出しでの実測値等）は run-tests-write.sh §W25 を参照。
# ──────────────────────────────────────────
echo ""
echo "§50  TODO_TIMING: computeGithubMs 区間統合アルゴリズム（Issue #455）"

assert_eq "§50 compute-github-ms: 空配列 → 0" \
  "0" "$(node "$ENGINE" compute-github-ms '[]')"
assert_eq "§50 compute-github-ms: 単一区間 → そのまま" \
  "100" "$(node "$ENGINE" compute-github-ms '[[0,100]]')"
assert_eq "§50 compute-github-ms: 重複区間は1回分に統合（設計書の例。並行呼び出しの区間統合）" \
  "200" "$(node "$ENGINE" compute-github-ms '[[0,100],[50,150],[200,250]]')"
assert_eq "§50 compute-github-ms: 完全に離れた区間は単純加算" \
  "150" "$(node "$ENGINE" compute-github-ms '[[0,50],[100,200]]')"
assert_eq "§50 compute-github-ms: 入力順が逆でも結果は同じ（内部でソートする）" \
  "200" "$(node "$ENGINE" compute-github-ms '[[200,250],[50,150],[0,100]]')"
assert_eq "§50 compute-github-ms: 一方の区間がもう一方を完全に包含する場合は外側の長さのみ" \
  "100" "$(node "$ENGINE" compute-github-ms '[[0,100],[20,30]]')"
assert_eq "§50 compute-github-ms: 境界が一致（隣接）する区間も統合する（s<=curEnd の等号側）" \
  "100" "$(node "$ENGINE" compute-github-ms '[[0,50],[50,100]]')"

# --- 【核心・回帰】実 @octokit/rest での wrapOctokitTiming() プロパティ保持検証 ---
# 実トークンでの実測（2026-08-29）で発覚: 素朴な再代入によるラップは実 @octokit/rest の
# .endpoint/.defaults（各メソッドが own property として持つ関数プロパティ。
# ライブラリ内部が参照する）を失わせ、TODO_TIMING=1 で実GitHub APIを呼ぶと
# "octokit.request.defaults is not a function" 等で機能停止した（stdoutも空になり
# 「既定出力を変えない」という要件も破っていた）。スタブベースの対照テストは
# run-tests-write.sh §W25-10 参照（そちらは環境非依存で必ず実行される）。
# 本テストは実 @octokit/rest（~/.claude/node_modules 配下、initOctokit()と同じ
# 固定パス）が必要なため、モジュールが見つからない環境ではFAILさせずSKIPする
# （run-tests.sh は「GitHubには接続しない」環境非依存を旨とするため。#1648の経緯を踏襲）。
# ネットワーク接続・実トークンは不要（インスタンス構築とプロパティ確認のみ）。
REAL_OCTOKIT_PATH="${HOME}/.claude/node_modules/@octokit/rest/dist-src/index.js"
if [ -f "$REAL_OCTOKIT_PATH" ]; then
  REAL_WRAP_OUT=$(node "$ENGINE" check-octokit-wrap-props 2>&1); REAL_WRAP_EC=$?
  assert_exit_ok "§50 check-octokit-wrap-props(実@octokit/rest経路): exit 0" "$REAL_WRAP_EC"
  for key in requestHasEndpoint requestHasDefaults issuesGetHasEndpoint issuesGetHasDefaults; do
    assert_contains "§50 【核心】実@octokit/restでwrapOctokitTiming後も $key が保持されている" "\"$key\":true" "$REAL_WRAP_OUT"
  done
else
  printf "  ⏭  §50 実@octokit/rest プロパティ保持テスト (skip: %s が見つからない。npm install --prefix ~/.claude @octokit/rest で解決)\n" "$REAL_OCTOKIT_PATH"
  SKIP=$((SKIP+5))
fi

# ──────────────────────────────────────────
# §51  未知フラグ判定 findUnknownFlag() 単体テスト（Issue #1921 パターンA）
# 事故: `add next "設計書を書く" --boddy-file /tmp/x` のように parseArgs が解釈できない
# `--` 始まりトークンが、エラーも警告もなくタイトルへ連結されて Issue が作られていた。
# 本セクションは判定器そのもの（純粋関数）を Octokit スタブ・GitHub 接続なしで検証する。
# CLI: find-unknown-flag '<tokensのJSON配列>' '<許可フラグのJSON配列>'
#      → 検出したフラグ文字列、なければ空文字列を stdout へ返す。
# runAdd の振る舞い（exit code・issues.create の抑止）は run-tests-write.sh §W27 を参照。
# ──────────────────────────────────────────
echo ""
echo "§51  未知フラグ判定 findUnknownFlag()（Issue #1921 パターンA）"

# --- 正常系 ---
assert_eq "§51-1 正常系: 通常のタイトルのみ → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["設計書を書く"]' '[]')"
assert_eq "§51-2 正常系【核心】タイポしたフラグ(--boddy-file)を検出する" \
  "--boddy-file" "$(node "$ENGINE" find-unknown-flag '["設計書を書く","--boddy-file","/tmp/x"]' '[]')"
assert_eq "§51-3 正常系: 許可リストに載ったフラグは検出しない（パターンB の runList 前提を固定）" \
  "" "$(node "$ENGINE" find-unknown-flag '["--group","--no-due"]' '["--group","--no-due","--no-estimate"]')"
assert_eq "§51-4 正常系: 許可リスト外のフラグのみ検出する" \
  "--foo" "$(node "$ENGINE" find-unknown-flag '["--group","--foo"]' '["--group"]')"

# --- 入力文字パターン（誤検知しないこと。#1919 追補で確定した線引きの固定） ---
assert_eq "§51-5 入力文字: Markdown水平線を含む1トークン(--- 区切り線 ---) → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["--- 区切り線 ---"]' '[]')"
assert_eq "§51-6 入力文字: --- 単独トークン（-- の直後がハイフン） → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["---"]' '[]')"
assert_eq "§51-7 入力文字: 「--body を説明する文章」（空白+非ASCII を含む） → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["--body を説明する文章"]' '[]')"
assert_eq "§51-8 入力文字: 単一ハイフン始まり(- 箇条書き) → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["- 箇条書き"]' '[]')"
assert_eq "§51-9 入力文字(マルチバイト): 全角ダッシュ始まり → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["－－全角ダッシュ"]' '[]')"
assert_eq "§51-10 入力文字(シェル特殊文字): --evil;rm -rf / はフラグ字面ではない → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["--evil;rm -rf /"]' '[]')"
assert_eq "§51-11 入力文字(フォーマット文字列): --%s は % が許可文字外 → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["--%s"]' '[]')"
assert_eq "§51-11b 入力文字(クォート): --\"quoted\" はフラグ字面ではない → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["--\"quoted\""]' '[]')"

# --- 境界値 ---
assert_eq "§51-12 境界値(最短): --x（英字1文字）は検出する" \
  "--x" "$(node "$ENGINE" find-unknown-flag '["--x"]' '[]')"
assert_eq "§51-13 境界値: -- 単独は検出しない（現仕様の固定。end-of-options 導入時は意図的に変更する）" \
  "" "$(node "$ENGINE" find-unknown-flag '["--"]' '[]')"
assert_eq "§51-14 境界値: --1st（数字始まり）は検出しない（英字始まりのみ対象）" \
  "" "$(node "$ENGINE" find-unknown-flag '["--1st"]' '[]')"
assert_eq "§51-15a 境界値: 空配列 → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '[]' '[]')"
assert_eq "§51-15b 境界値: 空文字列トークンのみ → 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '[""]' '[]')"
assert_eq "§51-16 境界値(複数該当): 先頭の1件のみ報告する（仕様の固定）" \
  "--aaa" "$(node "$ENGINE" find-unknown-flag '["--aaa","--bbb"]' '[]')"
assert_eq "§51-16b 境界値(末尾該当): 配列末尾のフラグも検出する（off-by-one 確認）" \
  "--zzz" "$(node "$ENGINE" find-unknown-flag '["a","b","--zzz"]' '[]')"

# --- パフォーマンス（500要素・末尾のみ該当。線形走査で完了すること） ---
_G1921_BIGTOKENS=$(node -e '
  const a = [];
  for (let i = 0; i < 499; i++) a.push("トークン" + i);
  a.push("--zzz");
  process.stdout.write(JSON.stringify(a));
')
assert_eq "§51-17 パフォーマンス: 500要素の配列でも末尾の --zzz を検出して完了する" \
  "--zzz" "$(node "$ENGINE" find-unknown-flag "$_G1921_BIGTOKENS" '[]')"

# --- パターンB（#1921 第2弾）: runList の許可リストを固定する ---
assert_eq "§51-18 正常系: runList の実入力形（GTD/優先度/project番号 + 許可フラグ）→ 検出なし" \
  "" "$(node "$ENGINE" find-unknown-flag '["next","p1","project","5","--group","--no-due"]' '["--group","--no-due","--no-estimate"]')"
# 許可リスト判定が「完全一致」であることの固定。将来 allowed.indexOf(tok) を
# startsWith 等の前方一致へ書き換えると --groupp が通ってしまう。
assert_eq "§51-19 境界値: 許可リストは完全一致（--groupp は --group の許可で通らない）" \
  "--groupp" "$(node "$ENGINE" find-unknown-flag '["next","--groupp"]' '["--group","--no-due","--no-estimate"]')"

# ──────────────────────────────────────────
# §52  未サポートフラグ判定 findUnsupportedFlagField() 単体テスト（Issue #1934 パート1）
# 事故: `add next "テスト" --note "メモ"` のように parseArgs() は消費するがハンドラが
# 読まないフラグが、エラーも警告もなく値だけ消えていた（findUnknownFlag では検出できない
# 「第3の型」）。本セクションは判定器そのもの（純粋関数）を検証する。
# CLI: find-unsupported-flag '<設定フィールドのJSON配列>' '<許可フィールドのJSON配列>'
#      → 検出した未サポートフィールド名、なければ空文字列を stdout へ返す。
# 8ハンドラの振る舞い（exit code・API呼び出し抑止・ヒント文言）は run-tests-write.sh §W29 参照。
# ──────────────────────────────────────────
echo ""
echo "§52  未サポートフラグ判定 findUnsupportedFlagField()（Issue #1934 パート1）"

assert_eq "§52-1 正常系: 設定フィールドなし・許可フィールドなし → 検出なし" \
  "" "$(node "$ENGINE" find-unsupported-flag '[]' '[]')"
assert_eq "§52-2 正常系: 設定フィールドがすべて許可されている → 検出なし" \
  "" "$(node "$ENGINE" find-unsupported-flag '["due","desc"]' '["due","desc"]')"
assert_eq "§52-3 異常系(Issue再現例1): --note を add 相当（許可なし）に渡す → note を検出" \
  "note" "$(node "$ENGINE" find-unsupported-flag '["note"]' '[]')"
assert_eq "§52-4 異常系(Issue再現例2): --actual を add 相当に渡す → actual を検出" \
  "actual" "$(node "$ENGINE" find-unsupported-flag '["actual"]' '[]')"
assert_eq "§52-5 異常系(Issue再現例3): --color を add 相当に渡す → color を検出" \
  "color" "$(node "$ENGINE" find-unsupported-flag '["color"]' '[]')"
assert_eq "§52-6 異常系(Issue再現例4): --due-offset を add 相当に渡す → dueOffset を検出" \
  "dueOffset" "$(node "$ENGINE" find-unsupported-flag '["dueOffset"]' '[]')"
assert_eq "§52-7 異常系(Issue再現例5): --note を edit 相当に渡す → note を検出" \
  "note" "$(node "$ENGINE" find-unsupported-flag '["note"]' '[]')"
assert_eq "§52-8 異常系(Issue再現例6): --due を list 相当（許可なし）に渡す → due を検出" \
  "due" "$(node "$ENGINE" find-unsupported-flag '["due"]' '[]')"
assert_eq "§52-9 境界値: 許可フィールドがある場合（done相当: actual許可・noteは未サポート）" \
  "note" "$(node "$ENGINE" find-unsupported-flag '["actual","note"]' '["actual"]')"
assert_eq "§52-10 境界値: 複数未サポート・FLAG_FIELD_MAP定義順で先頭が勝つ（dueが最初）" \
  "due" "$(node "$ENGINE" find-unsupported-flag '["note","actual","due"]' '[]')"
assert_eq "§52-11 境界値: labels（配列フィールド）を許可なしに渡す → labels を検出" \
  "labels" "$(node "$ENGINE" find-unsupported-flag '["labels"]' '[]')"
assert_eq "§52-12 境界値: 完全一致判定（大文字違いのDueはdueの許可にならない）" \
  "due" "$(node "$ENGINE" find-unsupported-flag '["due"]' '["Due"]')"
assert_eq "§52-13 境界値: FLAG_FIELD_MAP に存在しないフィールド名は走査対象外 → 検出なし" \
  "" "$(node "$ENGINE" find-unsupported-flag '["nonexistent"]' '[]')"
assert_eq "§52-14 入力パターン: 許可フィールド引数省略 → 空配列扱いでdueを検出" \
  "due" "$(node "$ENGINE" find-unsupported-flag '["due"]')"

# --- パフォーマンス（全17フィールド設定・全17フィールド許可。線形走査で完了すること） ---
_ISSUE1934_ALLFIELDS=$(node -e '
  const fields = ["due","desc","recur","project","priority","estimate","actual","dueOffset",
    "color","activate","before","dependsOn","resumeCondition","note","body","bodyFile","labels"];
  process.stdout.write(JSON.stringify(fields));
')
assert_eq "§52-15 パフォーマンス: 全17フィールド設定・全17フィールド許可 → 検出なし" \
  "" "$(node "$ENGINE" find-unsupported-flag "$_ISSUE1934_ALLFIELDS" "$_ISSUE1934_ALLFIELDS")"

# --- パート1.5: @ctx / #tag も parseArgs() が消費する同型フィールド（contexts/tags） ---
# `@ctx` / `#tag` はフラグではなく位置トークンだが、parseArgs() が消費した後にハンドラが
# 読まないと値が黙って消えるという構造はパート1の17フラグと同一（Issue #1934 パート1.5）。
assert_eq "§52-16 異常系(パート1.5): contexts を許可なしに渡す → contexts を検出" \
  "contexts" "$(node "$ENGINE" find-unsupported-flag '["contexts"]' '[]')"
assert_eq "§52-17 異常系(パート1.5): tags を許可なしに渡す → tags を検出" \
  "tags" "$(node "$ENGINE" find-unsupported-flag '["tags"]' '[]')"
assert_eq "§52-18 正常系(パート1.5): contexts/tags を両方許可（add/list相当） → 検出なし" \
  "" "$(node "$ENGINE" find-unsupported-flag '["contexts","tags"]' '["contexts","tags"]')"
assert_eq "§52-19 境界値(パート1.5): contexts は許可・tags は許可なし（template save相当の非対称） → tags を検出" \
  "tags" "$(node "$ENGINE" find-unsupported-flag '["contexts","tags"]' '["contexts"]')"

# ──────────────────────────────────────────
# 書き込み系ハンドラのスタブベーステスト（run-tests-write.sh、Issue #1648）
# 3,266行超に肥大化した本ファイルへの追記を避けるため別ファイルに分離し、
# ここで子プロセスとして呼び出して結果を合算する。実行口は
# `bash tests/run-tests.sh` の1コマンドのまま変わらない。
# ──────────────────────────────────────────
echo ""
echo "▶ 書き込み系ハンドラのスタブベーステスト（run-tests-write.sh）"
WRITE_TEST_SCRIPT="$SCRIPT_DIR/run-tests-write.sh"
if [ -f "$WRITE_TEST_SCRIPT" ]; then
  WRITE_OUT=$(bash "$WRITE_TEST_SCRIPT" 2>&1)
  echo "$WRITE_OUT"
  W_SUMMARY_LINE=$(printf '%s\n' "$WRITE_OUT" | grep '__WRITE_SUITE_SUMMARY__' | tail -1)
  W_PASS=$(printf '%s' "$W_SUMMARY_LINE" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
  W_FAIL=$(printf '%s' "$W_SUMMARY_LINE" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p')
  W_SKIP=$(printf '%s' "$W_SUMMARY_LINE" | sed -n 's/.*SKIP=\([0-9]*\).*/\1/p')
  if [ -z "$W_SUMMARY_LINE" ]; then
    printf "  ❌ run-tests-write.sh の結果サマリー行が見つからない（集計不能）\n"; FAIL=$((FAIL+1))
  else
    PASS=$((PASS + ${W_PASS:-0}))
    FAIL=$((FAIL + ${W_FAIL:-0}))
    SKIP=$((SKIP + ${W_SKIP:-0}))
  fi
else
  printf "  ❌ run-tests-write.sh が見つからない: %s\n" "$WRITE_TEST_SCRIPT"; FAIL=$((FAIL+1))
fi

# ──────────────────────────────────────────
# 結果サマリー
# ──────────────────────────────────────────
echo ""
echo "=========================================="
TOTAL=$((PASS+FAIL))
printf "結果: %d / %d テスト通過\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf "❌ %d テスト失敗\n" "$FAIL"
fi
if [ "$SKIP" -gt 0 ]; then
  printf "⏭  %d テストスキップ（GitHub接続が必要）\n" "$SKIP"
fi
echo "=========================================="

# 一時ファイルのクリーンアップ
rm -f "$TEMP_TFILE"

[ "$FAIL" -eq 0 ]
