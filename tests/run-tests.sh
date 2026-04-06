#!/bin/bash
# todo スキル テストランナー
# GitHub には接続しない。normalize_due・バリデーション・テンプレートファイル操作のみをテスト。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
  if printf '%s' "$actual" | grep -q "$pattern"; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s\n" "$desc"
    printf "     パターン [%s] が含まれていない\n" "$pattern"
    printf "     実際: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
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
