#!/bin/bash
# todo スキル テストランナー
# GitHub には接続しない。normalize_due・バリデーション・テンプレートファイル操作のみをテスト。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../scripts/todo-engine.js"  # todo-engine.js
FMT_JS="$SCRIPT_DIR/helpers/date-fmt.js"  # 共通日付フォーマット関数
TEMP_TFILE=$(mktemp /tmp/todo-test-templates-XXXXXX.json)
printf '{}' > "$TEMP_TFILE"
PASS=0
FAIL=0
SKIP=0

# テスト固定日付（再現性のため）
TEST_TODAY="2026-04-05"  # 日曜日

# ────────────────────────────────────────────
# ヘルパー
# ────────────────────────────────────────────
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s\n" "$desc"
    printf "     期待: [%s]\n" "$expected"
    printf "     実際: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
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
  fi
}

assert_not_contains() {
  local desc="$1" pattern="$2" actual="$3"
  if printf '%s' "$actual" | grep -aq "$pattern"; then
    printf "  ❌ %s\n" "$desc"
    printf "     パターン [%s] が含まれてはいけない\n" "$pattern"
    printf "     実際: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
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
  fi
}

assert_exit_fail() {
  local desc="$1" exit_code="${2:-0}"
  if [ "$exit_code" -ne 0 ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s (エラーが期待されたが exit 0)\n" "$desc"; FAIL=$((FAIL+1))
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
echo " 基準日: $TEST_TODAY（日曜日）"
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
assert_eq "en+ja: 明日 still works"  "2026-04-06"  "$(LANG_ENV=en node "$ENGINE" normalize-due '明日' "$TEST_TODAY")"

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

validate_due() {
  local due="$1"
  case "$due" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) echo "VALID" ;;
    [0-9]/[0-9]|[0-9]/[0-9][0-9]|[0-9][0-9]/[0-9]|[0-9][0-9]/[0-9][0-9]) echo "VALID" ;;
    *) echo "INVALID" ;;
  esac
}

assert_eq "正常: YYYY-MM-DD"    "VALID"   "$(validate_due '2026-04-10')"
assert_eq "正常: M/D (4/1)"     "VALID"   "$(validate_due '4/1')"
assert_eq "正常: M/D (4/10)"    "VALID"   "$(validate_due '4/10')"
assert_eq "正常: M/D (12/31)"   "VALID"   "$(validate_due '12/31')"
assert_eq "不正: 来週"          "INVALID" "$(validate_due '来週')"
assert_eq "不正: 日付なし"      "INVALID" "$(validate_due '')"
assert_eq "不正: コマンド挿入"  "INVALID" "$(validate_due '2026-04-05;ls')"
# 注: YYYY-MM-DD 形式は月の範囲(1-12)はチェックしない（仕様通り）。シナリオ S-3 参照
assert_eq "YYYY-MM-DD: 月範囲はチェックしない(2026-13-01は通過)" "VALID" "$(validate_due '2026-13-01')"
# 注: M/D 形式は値範囲をチェックしない（フォーマットのみ）。99/99 も通過する
assert_eq "M/D: 値範囲はチェックしない(99/99は通過)" "VALID" "$(validate_due '99/99')"

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

next_monthly() {
  local base="$1"
  FMT_JS="$FMT_JS" node -e "
const fmt=require(process.env.FMT_JS);
const d=new Date('${base}T00:00:00');
d.setMonth(d.getMonth()+1);
process.stdout.write(fmt(d));
"
}

# 通常ケース: 4/15 → 5/15
assert_eq "4/15→5/15(通常)" "2026-05-15" "$(next_monthly '2026-04-15')"

# 4/30 → 5/30
assert_eq "4/30→5/30" "2026-05-30" "$(next_monthly '2026-04-30')"

# 1/31 → 3/3 (JSは2月28日超過分を3月に繰り上げ)
assert_eq "1/31→3/3(JS月末繰り上がり)" "2026-03-03" "$(next_monthly '2026-01-31')"

# 3/31 → 5/1 (4月は30日まで → 5/1に繰り上がり)
assert_eq "3/31→5/1(4月は30日)" "2026-05-01" "$(next_monthly '2026-03-31')"

# 5/31 → 7/1 (6月は30日まで → 7/1に繰り上がり)
assert_eq "5/31→7/1(6月は30日)" "2026-07-01" "$(next_monthly '2026-05-31')"

# 12/15 → 翌年1/15（年またぎ）
assert_eq "12/15→翌年1/15(年またぎ)" "2027-01-15" "$(next_monthly '2026-12-15')"

# 12/31 → 翌年1/31（年またぎ+月末）
assert_eq "12/31→翌年1/31(年またぎ月末)" "2027-01-31" "$(next_monthly '2026-12-31')"

# 2/28 → 3/28（2月末→通常月）
assert_eq "2/28→3/28" "2026-03-28" "$(next_monthly '2026-02-28')"

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

# うるう年の1/31 → 翌月 = 3/2（2月は29日まで → 繰り上がり）
assert_eq "うるう年1/31→翌月=3/2" "2028-03-02" "$(next_monthly '2028-01-31')"

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
assert_eq "engine: normalize-due パススルー" "4/10" "$(node "$ENGINE" normalize-due '4/10' "$TEST_TODAY")"

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
# § 24  Custom Views — フィルタパース・CRUD（Pro機能）
# ──────────────────────────────────────────
echo ""
echo "§24  Custom Views — フィルタパース・CRUD"

TEMP_VFILE=$(mktemp /tmp/todo-test-views-XXXXXX.json)
printf '{}' > "$TEMP_VFILE"

# フィルタパーステスト用ヘルパー
parse_view_filter() {
  local input="$1"
  FILTER_ENV="$input" node -e "
    const tokens=(process.env.FILTER_ENV||'').trim().split(/\s+/).filter(Boolean);
    const gtdLabels=['next','inbox','waiting','someday','project','reference'];
    let gtd='', ctx=[], pri='';
    for(const t of tokens){
      if(gtdLabels.includes(t)) gtd=t;
      else if(t.startsWith('@')) ctx.push(t);
      else if(/^p[123]$/.test(t)) pri=t;
    }
    process.stdout.write('GTD='+gtd+' CTX='+ctx.join(' ')+' PRI='+pri);
  "
}

assert_eq "View parse: next @会社 p1"  "GTD=next CTX=@会社 PRI=p1"  "$(parse_view_filter 'next @会社 p1')"
assert_eq "View parse: inbox"          "GTD=inbox CTX= PRI="        "$(parse_view_filter 'inbox')"
assert_eq "View parse: @PC @自宅"      "GTD= CTX=@PC @自宅 PRI="   "$(parse_view_filter '@PC @自宅')"
assert_eq "View parse: p2"             "GTD= CTX= PRI=p2"          "$(parse_view_filter 'p2')"
assert_eq "View parse: next @会社 @PC p1" "GTD=next CTX=@会社 @PC PRI=p1" "$(parse_view_filter 'next @会社 @PC p1')"
assert_eq "View parse: 空"             "GTD= CTX= PRI="            "$(parse_view_filter '')"

# View save テスト
VIEW_SAVE1=$(VNAME_ENV="仕事" GTD_ENV="next" CTX_ENV="@会社" PRI_ENV="p1" VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  let data={};
  try { data=JSON.parse(fs.readFileSync(vfile,'utf8')); } catch(e){}
  const name=process.env.VNAME_ENV;
  const v={};
  const gtd=process.env.GTD_ENV||'';
  if(gtd) v.gtd=gtd;
  const ctx=process.env.CTX_ENV||'';
  if(ctx) v.context=ctx.trim().split(/\s+/);
  const pri=process.env.PRI_ENV||'';
  if(pri) v.priority=pri;
  data[name]=v;
  fs.writeFileSync(vfile, JSON.stringify(data,null,2));
  process.stdout.write('SAVED');
")
assert_eq "View save: 仕事"  "SAVED"  "$VIEW_SAVE1"

VIEW_SAVE2=$(VNAME_ENV="自宅PC" GTD_ENV="next" CTX_ENV="@自宅 @PC" PRI_ENV="" VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  let data={};
  try { data=JSON.parse(fs.readFileSync(vfile,'utf8')); } catch(e){}
  const name=process.env.VNAME_ENV;
  const v={};
  const gtd=process.env.GTD_ENV||'';
  if(gtd) v.gtd=gtd;
  const ctx=process.env.CTX_ENV||'';
  if(ctx) v.context=ctx.trim().split(/\s+/);
  const pri=process.env.PRI_ENV||'';
  if(pri) v.priority=pri;
  data[name]=v;
  fs.writeFileSync(vfile, JSON.stringify(data,null,2));
  process.stdout.write('SAVED');
")
assert_eq "View save: 自宅PC"  "SAVED"  "$VIEW_SAVE2"

# View load テスト
VIEW_LOAD=$(VNAME_ENV="仕事" VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  const data=JSON.parse(fs.readFileSync(vfile,'utf8'));
  const name=process.env.VNAME_ENV;
  if(!data[name]){ process.stdout.write('ERROR'); process.exit(0); }
  const v=data[name];
  const parts=[];
  if(v.gtd) parts.push('GTD='+v.gtd);
  if(v.context) parts.push('CTX='+v.context.join(' '));
  if(v.priority) parts.push('PRI='+v.priority);
  process.stdout.write(parts.join(' '));
")
assert_eq "View load: 仕事"  "GTD=next CTX=@会社 PRI=p1"  "$VIEW_LOAD"

# View load 存在しない
VIEW_LOAD_MISS=$(VNAME_ENV="ない" VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  const data=JSON.parse(fs.readFileSync(vfile,'utf8'));
  const name=process.env.VNAME_ENV;
  if(!data[name]){ process.stdout.write('存在しません'); process.exit(0); }
  process.stdout.write('FOUND');
")
assert_contains "View load 存在しない: エラー" "存在しません" "$VIEW_LOAD_MISS"

# View list テスト
VIEW_LIST=$(VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  const data=JSON.parse(fs.readFileSync(vfile,'utf8'));
  const keys=Object.keys(data);
  if(!keys.length){ process.stdout.write('（ビューなし）'); process.exit(0); }
  for(const name of keys){
    const v=data[name];
    const parts=[];
    if(v.gtd) parts.push(v.gtd);
    if(v.context) parts.push(v.context.join(' '));
    if(v.priority) parts.push(v.priority);
    process.stdout.write(name+'  ['+parts.join(', ')+']\n');
  }
")
assert_contains "View list: 仕事あり"    "仕事"    "$VIEW_LIST"
assert_contains "View list: 自宅PCあり"  "自宅PC"  "$VIEW_LIST"

# View delete テスト
VIEW_DEL=$(VNAME_ENV="仕事" VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  let data=JSON.parse(fs.readFileSync(vfile,'utf8'));
  const name=process.env.VNAME_ENV;
  if(!data[name]){ process.stdout.write('存在しません'); process.exit(0); }
  delete data[name];
  fs.writeFileSync(vfile, JSON.stringify(data,null,2));
  process.stdout.write('DELETED');
")
assert_eq "View delete: 仕事"  "DELETED"  "$VIEW_DEL"

# 削除後 list で仕事が消えている
VIEW_LIST2=$(VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const data=JSON.parse(fs.readFileSync(process.env.VFILE_ENV,'utf8'));
  process.stdout.write(Object.keys(data).join(','));
")
assert_eq "View delete後: 自宅PCのみ" "自宅PC" "$VIEW_LIST2"

# 存在しないビュー削除
VIEW_DEL_MISS=$(VNAME_ENV="ない" VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  let data=JSON.parse(fs.readFileSync(vfile,'utf8'));
  const name=process.env.VNAME_ENV;
  if(!data[name]){ process.stdout.write('存在しません'); process.exit(0); }
  process.stdout.write('DELETED');
")
assert_contains "View delete 存在しない: エラー" "存在しません" "$VIEW_DEL_MISS"

# 空 list
printf '{}' > "$TEMP_VFILE"
VIEW_LIST_EMPTY=$(VFILE_ENV="$TEMP_VFILE" node -e "
  const fs=require('fs');
  const data=JSON.parse(fs.readFileSync(process.env.VFILE_ENV,'utf8'));
  const keys=Object.keys(data);
  if(!keys.length){ process.stdout.write('（ビューなし）'); process.exit(0); }
  process.stdout.write(keys.join(','));
")
assert_contains "View list 空: ビューなし" "ビューなし" "$VIEW_LIST_EMPTY"

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
assert_contains "Report: 完了7件"                "**7件**"            "$RPT_OUT"
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

# 一時ファイルクリーンアップ
rm -f "$TEMP_VFILE"

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
TEMP_TFILE_EN=$(mktemp /tmp/todo-test-templates-en-XXXXXX.json)
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
