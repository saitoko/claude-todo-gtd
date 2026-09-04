#!/bin/bash
# todo スキル テストランナー（書き込み系ハンドラ・スタブベース）
# Issue #1648: Octokit 注入シームを使い、runAdd/runDone/runEdit/runBulk/runView/
# runPriority 等の書き込み系ハンドラをスタブ Octokit 経由で振る舞いレベル検証する。
# GitHub には接続しない。GH_TOKEN・実 @octokit/rest の実インストールにも依存しない
# （OCTOKIT_STUB_ENV 設定時は initOctokit() がスタブへ短絡するため）。
#
# 実行方法は tests/run-tests.sh から1コマンド（bash tests/run-tests.sh）で
# 呼び出される想定。単体では: bash tests/run-tests-write.sh
#
# 設計背景: Octokit 注入シーム（GH_TOKEN・実 API 非依存でテストを実行する仕組み）の
# 詳細設計は開発時の設計資料を参照（本リポジトリには含まれません）。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/../scripts/todo-engine.js"
[ -f "$ENGINE" ] || ENGINE="$SCRIPT_DIR/../todo-engine.js"  # 公開リポジトリはルート直下レイアウト
STUB="$SCRIPT_DIR/stubs/octokit-stub.js"
PASS=0
FAIL=0
SKIP=0

# ────────────────────────────────────────────
# ヘルパー（run-tests.sh と同一実装。別プロセスのため複製が必要）
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
  # 固定文字列一致（-F）。パターンに [ ] 等の正規表現特殊文字を含むJSON片・
  # フィルタ表示文字列をそのまま渡せるようにするため（run-tests.sh 本体の
  # assert_contains とは異なり、こちらは意図的に -F を使う）。
  local desc="$1" pattern="$2" actual="$3"
  if printf '%s' "$actual" | grep -aFq -- "$pattern"; then
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
  if printf '%s' "$actual" | grep -aFq -- "$pattern"; then
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

# assert_no_japanese: 出力に日本語文字（ひらがな/カタカナ/CJK統合漢字）が
# 1文字も含まれないことを機械的に検証する（Issue #1653）。
# Node の Unicode 正規表現を使う（bash/grep のロケール依存ブラケット展開を避けるため、
# Windows Git Bash・macOS BSD grep でも挙動が変わらない）。
assert_no_japanese() {
  local desc="$1" actual="$2"
  local has_ja
  has_ja=$(TEXT="$actual" node -e "process.stdout.write(/[぀-ヿ㐀-鿿]/.test(process.env.TEXT || '') ? 'yes' : 'no')")
  if [ "$has_ja" = "no" ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s\n" "$desc"
    printf "     日本語文字が含まれている: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
  fi
}

# assert_regex: JS正規表現（文字列で渡す）にactualがマッチすることを検証する（Issue #455）。
# TODO_TIMING の出力フォーマット（[timing] total <N>ms (github <N>ms / parse <N>ms)）のように
# 数値部分が可変な行を固定文字列一致では検証できないため。
assert_regex() {
  local desc="$1" pattern_src="$2" actual="$3"
  local matched
  matched=$(PATTERN="$pattern_src" TEXT="$actual" node -e "
    process.stdout.write(new RegExp(process.env.PATTERN, 'm').test(process.env.TEXT || '') ? 'yes' : 'no')
  ")
  if [ "$matched" = "yes" ]; then
    printf "  ✅ %s\n" "$desc"; PASS=$((PASS+1))
  else
    printf "  ❌ %s\n" "$desc"
    printf "     正規表現 [%s] にマッチしない\n" "$pattern_src"
    printf "     実際: [%s]\n" "$actual"
    FAIL=$((FAIL+1))
  fi
}

# extract_timing_field: stderr中の [timing] 行から total/github/parse のms値（整数）を取り出す
extract_timing_field() {
  local text="$1" field="$2"
  TEXT="$text" FIELD="$field" node -e "
    const m = (process.env.TEXT || '').match(/\[timing\] total (\d+)ms \(github (\d+)ms \/ parse (\d+)ms\)/);
    if (!m) { process.stdout.write(''); process.exit(0); }
    const map = { total: m[1], github: m[2], parse: m[3] };
    process.stdout.write(map[process.env.FIELD] || '');
  "
}

# assert_le: 数値比較（a <= b）
assert_le() {
  local desc="$1" a="$2" b="$3"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -le "$b" ] 2>/dev/null; then
    printf "  ✅ %s (%s <= %s)\n" "$desc" "$a" "$b"; PASS=$((PASS+1))
  else
    printf "  ❌ %s (%s <= %s ではない)\n" "$desc" "$a" "$b"; FAIL=$((FAIL+1))
  fi
}

# assert_lt: 数値比較（a < b）
assert_lt() {
  local desc="$1" a="$2" b="$3"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] 2>/dev/null; then
    printf "  ✅ %s (%s < %s)\n" "$desc" "$a" "$b"; PASS=$((PASS+1))
  else
    printf "  ❌ %s (%s < %s ではない)\n" "$desc" "$a" "$b"; FAIL=$((FAIL+1))
  fi
}

# 指定メソッドの JSONL 呼び出し件数を数える
log_count() {
  local logfile="$1" method="$2"
  LOGFILE="$logfile" METHOD="$method" node -e "
    const fs=require('fs');
    const lines = fs.existsSync(process.env.LOGFILE) ? fs.readFileSync(process.env.LOGFILE,'utf8').trim().split('\n').filter(Boolean) : [];
    const n = lines.filter(l=>{ try{ return JSON.parse(l).method===process.env.METHOD; }catch(e){ return false; } }).length;
    process.stdout.write(String(n));
  "
}

# 指定メソッドの呼び出し行（JSONL、1行=1呼び出し）を呼び出し順に列挙する
# assert_contains 等でメソッド引数の内容を検証するために使う
log_lines_for_method() {
  local logfile="$1" method="$2"
  LOGFILE="$logfile" METHOD="$method" node -e "
    const fs=require('fs');
    const lines = fs.existsSync(process.env.LOGFILE) ? fs.readFileSync(process.env.LOGFILE,'utf8').trim().split('\n').filter(Boolean) : [];
    const out = lines.filter(l=>{ try{ return JSON.parse(l).method===process.env.METHOD; }catch(e){ return false; } });
    process.stdout.write(out.join('\n'));
  "
}

# ──────────────────────────────────────────
# §W0  Octokit スタブ単体スモークテスト（Phase 0）
# ──────────────────────────────────────────
echo "§W0  Octokit スタブ単体スモークテスト"

W0_LOG=$(mktemp /tmp/todo-test-stub-w0-XXXXXX)
: > "$W0_LOG"

W0_OUT=$(STUB_PATH="$STUB" LOG_PATH="$W0_LOG" node -e "
const createStubOctokit = require(process.env.STUB_PATH);
const results = {};

(async () => {
  // 1) 未設定メソッド呼び出し → throw
  const ok1 = createStubOctokit({ logPath: null, responsesSpec: null });
  let threw1 = false, msg1 = '';
  try { await ok1.issues.get({owner:'a',repo:'b',issue_number:1}); }
  catch(e) { threw1 = true; msg1 = e.message; }
  results.unconfigured_throws = threw1 && /no response configured for issues\.get/.test(msg1);

  // 2) 正常応答の解決（JSONL記録も兼ねる）
  const ok2 = createStubOctokit({ logPath: process.env.LOG_PATH, responsesSpec: JSON.stringify({ 'issues.create': [{ data: { number: 42 } }] }) });
  const r2 = await ok2.issues.create({ owner:'a', repo:'b', title:'t' });
  results.response_resolved_ok = !!(r2 && r2.data && r2.data.number === 42);

  // 3) __throw + status
  const ok3 = createStubOctokit({ logPath: null, responsesSpec: JSON.stringify({ 'issues.removeLabel': [{ __throw: true, status: 404, message: 'Not Found' }] }) });
  let threw3 = false, status3 = null, msg3 = '';
  try { await ok3.issues.removeLabel({owner:'a',repo:'b',issue_number:1,name:'x'}); }
  catch(e) { threw3 = true; status3 = e.status; msg3 = e.message; }
  results.throw_status_ok = threw3 && status3 === 404 && msg3 === 'Not Found';

  // 4) キューが尽きた場合も throw（2回目の呼び出し）
  const ok4 = createStubOctokit({ logPath: null, responsesSpec: JSON.stringify({ 'issues.get': [{ data: { number: 1 } }] }) });
  await ok4.issues.get({owner:'a',repo:'b',issue_number:1});
  let threw4 = false;
  try { await ok4.issues.get({owner:'a',repo:'b',issue_number:1}); }
  catch(e) { threw4 = true; }
  results.queue_exhausted_throws = threw4;

  process.stdout.write(JSON.stringify(results));
})();
")

for key in unconfigured_throws response_resolved_ok throw_status_ok queue_exhausted_throws; do
  if printf '%s' "$W0_OUT" | grep -q "\"$key\":true"; then
    printf "  ✅ stub smoke: %s\n" "$key"; PASS=$((PASS+1))
  else
    printf "  ❌ stub smoke: %s (out=%s)\n" "$key" "$W0_OUT"; FAIL=$((FAIL+1))
  fi
done

# JSONL 1行目が method/ts/args を含む正しいJSONであること
W0_LOG_LINE=$(head -n1 "$W0_LOG" 2>/dev/null || true)
W0_LOG_CHECK=$(printf '%s' "$W0_LOG_LINE" | node -e "
  let s='';
  process.stdin.on('data',d=>s+=d);
  process.stdin.on('end',()=>{
    try {
      const o = JSON.parse(s);
      console.log((o.method==='issues.create' && o.ts && o.args) ? 'OK' : 'NG');
    } catch(e) { console.log('NG'); }
  });
")
assert_eq "stub smoke: JSONL 1行目が method/ts/args を含む正しいJSON" "OK" "$W0_LOG_CHECK"
rm -f "$W0_LOG"

# ──────────────────────────────────────────
# §W1  runDone — スタブベース振る舞いテスト（Phase 1）
# ──────────────────────────────────────────
echo ""
echo "§W1  runDone — スタブベース振る舞いテスト"

# W1-1 正常系: recur再作成（期限超過キャッチアップ込み）。#1642回帰の実効テスト化。
# POSTDONE_USES_CATCHUP（旧ソースgrep）の置換: nextDueCatchUp() の計算結果が
# issues.create の body まで実際に伝播していることを確認する。
# #1660修正後: fetchAllOpen（issues.listForRepo）がproject/dependsOn有無に関わらず
# 常に呼ばれるようになるため空応答を1件用意する
W1_LOG=$(mktemp /tmp/todo-test-w1-XXXXXX)
W1_RESP='{"issues.get":[{"data":{"number":301,"id":9301,"title":"Weekly Report","body":"due: 2026-03-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}],"issues.create":[{"data":{"number":9999}}],"issues.listForRepo":[{"data":[]}]}'
W1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1_RESP" OCTOKIT_STUB_LOG_ENV="$W1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run done 301 2>&1); W1_EC=$?
assert_exit_ok "runDone 正常系(recur+catchup): exit 0" "$W1_EC"
assert_contains "runDone 正常系: 完了メッセージ" "✅ #301 を完了しました。" "$W1_OUT"
assert_contains "runDone 正常系: 繰り返しタスク再作成メッセージ（catchup後の日付）" "繰り返しタスク #9999 を 2026-04-12 で作成しました。" "$W1_OUT"
assert_contains "runDone 正常系: 期限超過スキップ表示" "期限超過のため過去の周期をスキップしました" "$W1_OUT"
assert_eq "runDone 正常系: issues.get 呼び出し1回" "1" "$(log_count "$W1_LOG" issues.get)"
assert_eq "runDone 正常系: issues.update 呼び出し1回（close のみ、actual不変のためbody更新なし）" "1" "$(log_count "$W1_LOG" issues.update)"
assert_contains "runDone 正常系: issues.update が state closed" '"state":"closed"' "$(log_lines_for_method "$W1_LOG" issues.update)"
assert_eq "runDone 正常系: issues.create 呼び出し1回（recur再作成）" "1" "$(log_count "$W1_LOG" issues.create)"
assert_contains "runDone 正常系: issues.create body に catchup後のdueが伝播（nextDueCatchUp連携の実効検証）" '"body":"due: 2026-04-12\nrecur: weekly\n"' "$(log_lines_for_method "$W1_LOG" issues.create)"
rm -f "$W1_LOG"

# W1-2 異常系: 番号なし → バリデーションエラー、API呼び出しゼロ（副作用なし確認）
W1B_LOG=$(mktemp /tmp/todo-test-w1b-XXXXXX)
: > "$W1B_LOG"
W1B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W1B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run done 2>&1); W1B_EC=$?
assert_exit_fail "runDone 異常系: 番号なし → exit 1" "$W1B_EC"
assert_contains "runDone 異常系: エラーメッセージ" "正の整数が必要です" "$W1B_OUT"
assert_eq "runDone 異常系: API呼び出しゼロ（バリデーション先行の確認）" "0" "$(wc -l < "$W1B_LOG" | tr -d ' ')"
rm -f "$W1B_LOG"

# ──────────────────────────────────────────
# §W2  runBulk done — スタブベース振る舞いテスト（Phase 1）
# ──────────────────────────────────────────
echo ""
echo "§W2  runBulk done — スタブベース振る舞いテスト"

# W2-1 正常系: 複数Issue一括完了、うち1件がrecur再作成。
# BULK_CALLS_POSTDONE（旧ソースgrep）の置換: bulk done がrecur再作成をスキップしないことを
# 実際のAPI呼び出しログで確認する（#1642回帰の実効テスト化）。
# #1660修正後: 各Issueのpostdone処理でfetchAllOpen（issues.listForRepo）が呼ばれるため、
# 2件（Issueごとに1回）の空応答を用意する
W2_LOG=$(mktemp /tmp/todo-test-w2-XXXXXX)
W2_RESP='{"issues.get":[{"data":{"number":401,"id":9401,"title":"Simple Task","body":"","labels":[{"name":"📥 inbox"}]}},{"data":{"number":402,"id":9402,"title":"Weekly Task 2","body":"due: 2026-04-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{},{}],"issues.create":[{"data":{"number":8888}}],"issues.listForRepo":[{"data":[]},{"data":[]}]}'
W2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W2_RESP" OCTOKIT_STUB_LOG_ENV="$W2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run bulk done 401 402 2>&1); W2_EC=$?
assert_exit_ok "runBulk done 正常系: exit 0" "$W2_EC"
assert_contains "runBulk done 正常系: サマリーに完了件数・再作成件数" "✅ 2件完了（うち繰り返し再作成: 1件）" "$W2_OUT"
assert_contains "runBulk done 正常系: #402のrecur再作成メッセージ" "#402: 繰り返しタスク #8888 を 2026-04-08 で作成しました。" "$W2_OUT"
assert_eq "runBulk done 正常系: issues.get 呼び出し2回（各Issue1回ずつ）" "2" "$(log_count "$W2_LOG" issues.get)"
assert_eq "runBulk done 正常系: issues.update 呼び出し2回（各close）" "2" "$(log_count "$W2_LOG" issues.update)"
assert_eq "runBulk done 正常系: issues.create 呼び出し1回（#402のみrecur再作成、#1642回帰なし）" "1" "$(log_count "$W2_LOG" issues.create)"
rm -f "$W2_LOG"

# W2-2 異常系: Issue番号未指定 → バリデーションエラー、API呼び出しゼロ
W2B_LOG=$(mktemp /tmp/todo-test-w2b-XXXXXX)
: > "$W2B_LOG"
W2B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W2B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run bulk done abc 2>&1); W2B_EC=$?
assert_exit_fail "runBulk done 異常系: 数字以外の番号のみ → exit 1" "$W2B_EC"
assert_contains "runBulk done 異常系: エラーメッセージ" "Issue番号が指定されていません" "$W2B_OUT"
assert_eq "runBulk done 異常系: API呼び出しゼロ" "0" "$(wc -l < "$W2B_LOG" | tr -d ' ')"
rm -f "$W2B_LOG"

# ──────────────────────────────────────────
# §W3  runView — スタブベース振る舞いテスト（Phase 1 + Phase 2: §24 / #1643 置換）
# ──────────────────────────────────────────
echo ""
echo "§W3  runView — スタブベース振る舞いテスト（save/list/use/delete）"

# runView の save/delete/list はファイルI/O（~/.claude/todo-views.json）のため、
# 実HOMEを汚さないよう isolated HOME サンドボックスを使う。
# 旧 Issue #1643 ブロックが行っていた「実HOMEのnode_modulesをシンボリックリンク」は
# 不要（OCTOKIT_STUB_ENV は @octokit/rest の実解決自体を経由しないため）。
W3_REAL_HOME="$HOME"
W3_FAKE_HOME=$(mktemp -d /tmp/todo-test-w3-home-XXXXXX)
mkdir -p "$W3_FAKE_HOME/.claude"
printf '{}' > "$W3_FAKE_HOME/.claude/todo-views.json"
export HOME="$W3_FAKE_HOME"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  W3_REAL_USERPROFILE="${USERPROFILE:-}"
  export USERPROFILE="$W3_FAKE_HOME"
fi

# W3-1 正常系: save → save(2件目) → list → use → delete → delete(再削除エラー)
V1_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view save myview next @PC p1 2>&1); V1_EC=$?
assert_exit_ok "runView save 正常系: exit 0" "$V1_EC"
assert_contains "runView save 正常系: 保存メッセージ" "ビュー「myview」を保存しました。" "$V1_OUT"
assert_contains "runView save 正常系: フィルタ内容 [next, @PC, p1]" "[next, @PC, p1]" "$V1_OUT"

V2_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view save workctx next @office p2 2>&1); V2_EC=$?
assert_exit_ok "runView save(2件目) 正常系: exit 0" "$V2_EC"
assert_contains "runView save(2件目) 正常系: 保存メッセージ" "ビュー「workctx」を保存しました。" "$V2_OUT"

VLIST_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view list 2>&1); VLIST_EC=$?
assert_exit_ok "runView list 正常系: exit 0" "$VLIST_EC"
assert_contains "runView list: myview あり" "myview" "$VLIST_OUT"
assert_contains "runView list: workctx あり" "workctx" "$VLIST_OUT"

VUSE_RESP='{"issues.listForRepo":[{"data":[{"number":701,"title":"Sample","body":"","labels":[{"name":"🎯 next"},{"name":"@PC"},{"name":"p1"}],"updated_at":"2026-04-01T00:00:00Z"}]}]}'
VUSE_LOG=$(mktemp /tmp/todo-test-w3-use-XXXXXX)
VUSE_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$VUSE_RESP" OCTOKIT_STUB_LOG_ENV="$VUSE_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run view use myview 2>&1); VUSE_EC=$?
assert_exit_ok "runView use 正常系: exit 0" "$VUSE_EC"
assert_contains "runView use 正常系: ビュー名・フィルタのヘッダー表示" "👁 ビュー: myview [next, @PC, p1]" "$VUSE_OUT"
assert_contains "runView use 正常系: フィルタ後のIssueが表示される" "Sample" "$VUSE_OUT"
assert_eq "runView use 正常系: issues.listForRepo 呼び出し1回（fetchAllOpen経由）" "1" "$(log_count "$VUSE_LOG" issues.listForRepo)"
rm -f "$VUSE_LOG"

# delete（#1643回帰: 「名前扱いフォールバック」に吸われず delete サブコマンドとして正しく到達すること）
VDEL_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view delete myview 2>&1); VDEL_EC=$?
assert_exit_ok "runView delete 正常系（#1643回帰）: exit 0" "$VDEL_EC"
assert_contains "runView delete 正常系: 削除対象名が正しく認識される" "myview" "$VDEL_OUT"
assert_not_contains "runView delete 正常系: 旧バグ（'delete'という名前のビューを探しに行く挙動）が再発していない" 'ビュー「delete」は存在しません' "$VDEL_OUT"

VDEL2_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view delete myview 2>&1); VDEL2_EC=$?
assert_exit_fail "runView delete 再削除（#1643回帰）: exit 1" "$VDEL2_EC"
assert_contains "runView delete 再削除: エラーに対象名（myview）が出る" "myview" "$VDEL2_OUT"
assert_not_contains "runView delete 再削除: エラーが'delete'という名前を誤って指していない" 'ビュー「delete」は存在しません' "$VDEL2_OUT"

# W3-2 異常系: 存在しないビューを use → API呼び出しなしで即エラー（vdata存在チェックがfetchAllOpenより先）
VUSE_MISS_LOG=$(mktemp /tmp/todo-test-w3-missuse-XXXXXX)
: > "$VUSE_MISS_LOG"
VUSE_MISS_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$VUSE_MISS_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view use nosuchview 2>&1); VUSE_MISS_EC=$?
assert_exit_fail "runView use 異常系: 存在しないビュー → exit 1" "$VUSE_MISS_EC"
assert_contains "runView use 異常系: エラーメッセージ" 'ビュー「nosuchview」は存在しません' "$VUSE_MISS_OUT"
assert_eq "runView use 異常系: API呼び出しゼロ（存在チェックがfetchAllOpenより先行）" "0" "$(wc -l < "$VUSE_MISS_LOG" | tr -d ' ')"
rm -f "$VUSE_MISS_LOG"

# W3-3 異常系（Issue #1675回帰）: view save で複数の @ctx を指定 → 無言で握りつぶさずエラー終了する
VCTX2_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view save multictx next @home @errand p1 2>&1); VCTX2_EC=$?
assert_exit_fail "runView save 異常系（#1675）: 複数@ctx指定 → exit 1" "$VCTX2_EC"
assert_contains "runView save 異常系（#1675）: エラーメッセージ" "エラー: view save では @ctx は1つのみ指定できます" "$VCTX2_OUT"
VCTX2_LIST_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view list 2>&1)
assert_not_contains "runView save 異常系（#1675）: エラー時はビューが保存されない" "multictx" "$VCTX2_LIST_OUT"

# W3-4 正常系（Issue #1675回帰）: @ctx が1つのみなら従来通り保存される
VCTX1_OUT=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view save singlectx next @home p1 2>&1); VCTX1_EC=$?
assert_exit_ok "runView save 正常系（#1675）: 単一@ctxはexit 0" "$VCTX1_EC"
assert_contains "runView save 正常系（#1675）: 保存メッセージ" "ビュー「singlectx」を保存しました。" "$VCTX1_OUT"
assert_contains "runView save 正常系（#1675）: フィルタ内容 [next, @home, p1]" "[next, @home, p1]" "$VCTX1_OUT"

export HOME="$W3_REAL_HOME"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  if [ -n "${W3_REAL_USERPROFILE:-}" ]; then export USERPROFILE="$W3_REAL_USERPROFILE"; else unset USERPROFILE; fi
fi
rm -rf "$W3_FAKE_HOME" 2>/dev/null || true

# ──────────────────────────────────────────
# §W4  runAdd — スタブベース振る舞いテスト（Phase 1）
# ──────────────────────────────────────────
echo ""
echo "§W4  runAdd — スタブベース振る舞いテスト"

# W4-1 正常系: GTDキーワード先頭省略記法 + context/tag/priorityラベル作成順序 + before計算
W4_LOG=$(mktemp /tmp/todo-test-w4-XXXXXX)
W4_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{},{},{}],"issues.create":[{"data":{"number":5001,"html_url":"https://github.com/test-owner/test-repo/issues/5001"}}]}'
W4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W4_RESP" OCTOKIT_STUB_LOG_ENV="$W4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run add next @office '#urgent' --p1 --due 2026-04-10 --before 3d Buy office supplies 2>&1); W4_EC=$?
assert_exit_ok "runAdd 正常系(GTDキーワード省略記法): exit 0" "$W4_EC"
assert_contains "runAdd 正常系: 作成メッセージ" "✅ #5001 を作成しました。" "$W4_OUT"
assert_contains "runAdd 正常系: ラベル作成順序（GTD→context→tag→priority）" "ラベル: 🎯 next, @office, #urgent, p1" "$W4_OUT"
assert_contains "runAdd 正常系: 期日表示" "期日: 2026-04-10" "$W4_OUT"
assert_contains "runAdd 正常系: --before から逆算した昇格予定日" "昇格予定: 2026-04-07" "$W4_OUT"
assert_eq "runAdd 正常系: ラベル存在確認(GET)が3回（context/tag/priority）" "3" "$(log_count "$W4_LOG" 'GET /repos/{owner}/{repo}/labels/{name}')"
assert_eq "runAdd 正常系: issues.create 呼び出し1回" "1" "$(log_count "$W4_LOG" issues.create)"
assert_contains "runAdd 正常系: issues.create body に due/before/activate 反映" '"body":"due: 2026-04-10\nactivate: 2026-04-07\nbefore: 3d\n"' "$(log_lines_for_method "$W4_LOG" issues.create)"
assert_contains "runAdd 正常系: issues.create labels に4件（GTD+context+tag+priority）" '"labels":["🎯 next","@office","#urgent","p1"]' "$(log_lines_for_method "$W4_LOG" issues.create)"
rm -f "$W4_LOG"

# W4-2 異常系: タイトル空 → エラー、ラベル作成（ensureLabel等）は一切呼ばれない（副作用の過不足検証）
W4B_LOG=$(mktemp /tmp/todo-test-w4b-XXXXXX)
: > "$W4B_LOG"
W4B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W4B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next @office 2>&1); W4B_EC=$?
assert_exit_fail "runAdd 異常系: タイトル空 → exit 1" "$W4B_EC"
assert_contains "runAdd 異常系: エラーメッセージ" "タイトルが空です" "$W4B_OUT"
assert_eq "runAdd 異常系: API呼び出しゼロ（contextラベル作成より前にタイトル検証）" "0" "$(wc -l < "$W4B_LOG" | tr -d ' ')"
rm -f "$W4B_LOG"

# ──────────────────────────────────────────
# §W5  runEdit — スタブベース振る舞いテスト（Phase 1）
# ──────────────────────────────────────────
echo ""
echo "§W5  runEdit — スタブベース振る舞いテスト"

# W5-1 正常系: due変更 + before指定によるactivate再計算 + priority変更
W5_LOG=$(mktemp /tmp/todo-test-w5-XXXXXX)
W5_RESP='{"issues.get":[{"data":{"number":601,"id":9601,"title":"Old Title","body":"due: 2026-04-01\n","labels":[{"name":"🎯 next"},{"name":"p3"}]}}],"issues.removeLabel":[{}],"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.addLabels":[{}],"issues.update":[{}]}'
W5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W5_RESP" OCTOKIT_STUB_LOG_ENV="$W5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run edit 601 --due 2026-04-15 --before 2d --priority p2 2>&1); W5_EC=$?
assert_exit_ok "runEdit 正常系(due+before+priority): exit 0" "$W5_EC"
assert_contains "runEdit 正常系: due変更が反映" "due → 2026-04-15" "$W5_OUT"
assert_contains "runEdit 正常系: before指定でactivate再計算" "before → 2d (activate: 2026-04-13)" "$W5_OUT"
assert_contains "runEdit 正常系: priority変更" "priority → p2" "$W5_OUT"
assert_eq "runEdit 正常系: issues.removeLabel 呼び出し1回（旧p3削除）" "1" "$(log_count "$W5_LOG" issues.removeLabel)"
assert_contains "runEdit 正常系: 削除対象がp3" '"name":"p3"' "$(log_lines_for_method "$W5_LOG" issues.removeLabel)"
assert_eq "runEdit 正常系: issues.addLabels 呼び出し1回（新p2追加）" "1" "$(log_count "$W5_LOG" issues.addLabels)"
assert_contains "runEdit 正常系: 追加対象がp2" '"labels":["p2"]' "$(log_lines_for_method "$W5_LOG" issues.addLabels)"
assert_eq "runEdit 正常系: issues.update 呼び出し1回（body更新）" "1" "$(log_count "$W5_LOG" issues.update)"
assert_contains "runEdit 正常系: issues.update body に新dueとactivateが反映" '"due: 2026-04-15\nactivate: 2026-04-13\nbefore: 2d\n"' "$(log_lines_for_method "$W5_LOG" issues.update)"
rm -f "$W5_LOG"

# W5-2 異常系: --before指定だがdueなし → エラー、issues.get のみ実行され更新系は一切呼ばれない
W5B_LOG=$(mktemp /tmp/todo-test-w5b-XXXXXX)
W5B_RESP='{"issues.get":[{"data":{"number":602,"id":9602,"title":"No due task","body":"","labels":[{"name":"📥 inbox"}]}}]}'
W5B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W5B_RESP" OCTOKIT_STUB_LOG_ENV="$W5B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run edit 602 --before 2d 2>&1); W5B_EC=$?
assert_exit_fail "runEdit 異常系: dueなしで--before → exit 1" "$W5B_EC"
assert_contains "runEdit 異常系: エラーメッセージ" "before を使うには --due が必要です" "$W5B_OUT"
assert_eq "runEdit 異常系: issues.get のみ実行（1回）" "1" "$(log_count "$W5B_LOG" issues.get)"
assert_eq "runEdit 異常系: issues.update は呼ばれない（副作用なし）" "0" "$(log_count "$W5B_LOG" issues.update)"
rm -f "$W5B_LOG"

# W5-3（Issue #1652 修正後）: validate-before-mutate。
# --priority に不正値を指定した場合、validatePriority() が旧priorityラベル削除
# （removeLabel）より「前」に呼ばれるようになったため、typo時に旧ラベルだけが
# 破壊された中途半端な状態でエラー終了することがなくなった。
# issues.get（issue本体の取得）はpriority検証より前の共通フローで既に1回呼ばれているため
# 1回のまま、removeLabel/addLabels/issues.update（body更新）は全て0回になる。
W5C_LOG=$(mktemp /tmp/todo-test-w5c-XXXXXX)
W5C_RESP='{"issues.get":[{"data":{"number":603,"id":9603,"title":"Task","body":"due: 2026-04-01\n","labels":[{"name":"🎯 next"},{"name":"p1"}]}}]}'
W5C_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W5C_RESP" OCTOKIT_STUB_LOG_ENV="$W5C_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run edit 603 --priority p9 2>&1); W5C_EC=$?
assert_exit_fail "runEdit(#1652 validate-before-mutate): 不正priority → exit 1" "$W5C_EC"
assert_contains "runEdit(#1652): エラーメッセージ" "priority は p1/p2/p3 のみ有効です" "$W5C_OUT"
assert_eq "runEdit(#1652): issue本体取得(issues.get)は1回（priority検証と無関係の既存フロー）" "1" "$(log_count "$W5C_LOG" issues.get)"
assert_eq "runEdit(#1652): 旧priorityラベル削除(removeLabel)は呼ばれない（修正の核心）" "0" "$(log_count "$W5C_LOG" issues.removeLabel)"
assert_eq "runEdit(#1652): 新ラベル追加(addLabels)は呼ばれない" "0" "$(log_count "$W5C_LOG" issues.addLabels)"
assert_eq "runEdit(#1652): 本体のbody更新(issues.update)も呼ばれない" "0" "$(log_count "$W5C_LOG" issues.update)"
rm -f "$W5C_LOG"

# ──────────────────────────────────────────
# §W6  runPriority — スタブベース振る舞いテスト（Phase 1）
# ──────────────────────────────────────────
echo ""
echo "§W6  runPriority — スタブベース振る舞いテスト"

# W6-1 正常系
W6_LOG=$(mktemp /tmp/todo-test-w6-XXXXXX)
W6_RESP='{"issues.get":[{"data":{"number":701,"id":9701,"title":"Task","body":"","labels":[{"name":"🎯 next"},{"name":"p1"}]}}],"issues.removeLabel":[{}],"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.addLabels":[{}]}'
W6_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W6_RESP" OCTOKIT_STUB_LOG_ENV="$W6_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run priority 701 p2 2>&1); W6_EC=$?
assert_exit_ok "runPriority 正常系: exit 0" "$W6_EC"
assert_contains "runPriority 正常系: メッセージ" "✅ #701 の優先度を p2 に設定しました。" "$W6_OUT"
assert_eq "runPriority 正常系: 旧p1削除" "1" "$(log_count "$W6_LOG" issues.removeLabel)"
assert_contains "runPriority 正常系: 削除対象がp1" '"name":"p1"' "$(log_lines_for_method "$W6_LOG" issues.removeLabel)"
assert_eq "runPriority 正常系: 新p2追加" "1" "$(log_count "$W6_LOG" issues.addLabels)"
assert_contains "runPriority 正常系: 追加対象がp2" '"labels":["p2"]' "$(log_lines_for_method "$W6_LOG" issues.addLabels)"
rm -f "$W6_LOG"

# W6-2（Issue #1652 修正後）: validate-before-mutate。
# runPriority は validatePriority() を issues.get（issue本体取得）より前に呼ぶよう
# 修正したため、不正値指定時はAPI呼び出しが一切発生しない（0回）ことを確認する。
W6C_LOG=$(mktemp /tmp/todo-test-w6c-XXXXXX)
: > "$W6C_LOG"
W6C_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W6C_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run priority 702 p9 2>&1); W6C_EC=$?
assert_exit_fail "runPriority(#1652 validate-before-mutate): 不正priority → exit 1" "$W6C_EC"
assert_contains "runPriority(#1652): エラーメッセージ" "priority は p1/p2/p3 のみ有効です" "$W6C_OUT"
assert_eq "runPriority(#1652): API呼び出しゼロ（issue取得より前にvalidatePriorityで弾かれる）" "0" "$(wc -l < "$W6C_LOG" | tr -d ' ')"
rm -f "$W6C_LOG"

# ──────────────────────────────────────────
# §W7  runTag rename — スタブベース振る舞いテスト（Phase 2: TAG_RENAME_DELEGATES 置換）
# ──────────────────────────────────────────
echo ""
echo "§W7  runTag rename — スタブベース振る舞いテスト（renameCtxLabel 委譲の実効検証）"

# 旧 TAG_RENAME_DELEGATES はソースgrep（「renameCtxLabel という文字列が runTag 本文に
# 含まれるか」のみ確認）だった。置換後は実際に ensureLabel→fetchAllOpen→(addLabels→
# removeLabel)→deleteLabel という呼び出し列が発生することをログで確認する。
W7_LOG=$(mktemp /tmp/todo-test-w7-XXXXXX)
W7_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.listForRepo":[{"data":[{"number":801,"title":"Task A","body":"","labels":[{"name":"@oldctx"}],"updated_at":""}]}],"issues.addLabels":[{}],"issues.removeLabel":[{}],"issues.deleteLabel":[{}]}'
W7_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W7_RESP" OCTOKIT_STUB_LOG_ENV="$W7_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run tag rename oldctx newctx 2>&1); W7_EC=$?
assert_exit_ok "runTag rename 正常系: exit 0" "$W7_EC"
assert_contains "runTag rename 正常系: リネームメッセージ" "✅ @oldctx を @newctx にリネームしました。1件のIssueを更新しました。" "$W7_OUT"
assert_eq "runTag rename: 新ラベル存在確認(GET)1回" "1" "$(log_count "$W7_LOG" 'GET /repos/{owner}/{repo}/labels/{name}')"
assert_eq "runTag rename: fetchAllOpen(issues.listForRepo)1回" "1" "$(log_count "$W7_LOG" issues.listForRepo)"
assert_eq "runTag rename: 対象Issueへの新ラベル追加1回" "1" "$(log_count "$W7_LOG" issues.addLabels)"
assert_contains "runTag rename: 追加対象Issueが#801・ラベルが@newctx" '"issue_number":801,"labels":["@newctx"]' "$(log_lines_for_method "$W7_LOG" issues.addLabels)"
assert_eq "runTag rename: 対象Issueから旧ラベル削除1回" "1" "$(log_count "$W7_LOG" issues.removeLabel)"
assert_contains "runTag rename: 削除対象Issueが#801・ラベルが@oldctx" '"issue_number":801,"name":"@oldctx"' "$(log_lines_for_method "$W7_LOG" issues.removeLabel)"
assert_eq "runTag rename: リポジトリ全体からの旧ラベル定義削除1回" "1" "$(log_count "$W7_LOG" issues.deleteLabel)"
rm -f "$W7_LOG"

# ──────────────────────────────────────────
# §W8  run api 系（Phase 1: apiMain統合の到達確認、Phase 2: GH_TOKEN=dummy 依存の置換）
# ──────────────────────────────────────────
echo ""
echo "§W8  run api ルーティング — スタブ経由（GH_TOKEN不要）"

# apiMain() が initOctokit() に統合された後も、run 経由の api サブコマンドが
# 「未知のコマンド」エラーにならずに apiMain まで到達することを、GH_TOKEN・実
# @octokit/rest 非依存（OCTOKIT_STUB_ENV のみ）で確認する（Issue #1644 回帰の継続確認）。
W8_OUT=$(env -u TODO_REPO_OWNER -u TODO_REPO_NAME OCTOKIT_STUB_ENV="$STUB" \
  node "$ENGINE" run api list-comments 1 2>&1); W8_EC=$?
assert_exit_fail "1644: run api list-comments <N>（スタブ経由）→ exit 1（TODO_REPO_OWNER/NAME未設定エラー）" "$W8_EC"
assert_not_contains "1644: 'run api ...' が『未知のコマンド』エラーにならない（スタブ経由でも再確認）" '未知のコマンド「api」' "$W8_OUT"
assert_contains "1644: run api list-comments が apiMain まで到達している（スタブ経由）" 'TODO_REPO_OWNER' "$W8_OUT"

# ──────────────────────────────────────────
# §W9  api done-issue — スタブベース振る舞いテスト（Issue #1669）
# ──────────────────────────────────────────
echo ""
echo "§W9  api done-issue — スタブベース振る舞いテスト（Web版 done() のrecur再作成バグ修正）"

# 背景: Web版 GitHubIssueRepository.done() は旧実装で `api close-issue` を呼ぶだけだった。
# close-issue は octokit.issues.update({state:'closed'}) のみで、CLIの runDone が呼ぶ
# postDoneProcessing（recur再作成 + depends_on昇格）を一切経由しないため、Web版で
# recurタスクを完了すると繰り返しチェーンが無言で途切れていた。
# 新設した `api done-issue` が runDone と同じ後処理を行い、かつ callEngineJson が
# パースできるJSON（{ok:true, recurLine, otherLines, newIssueNumber}）を返すことを確認する。

# W9-1 正常系: recur設定ありのissueをdone-issueで閉じると次周期のissueが作成される（skipなし）
# #1660修正後: recurのみでproject/dependsOnがなくても depends_on 昇格チェックのため
# fetchAllOpen（issues.listForRepo）が呼ばれるようになるため、空応答を1件用意する。
W9_1_LOG=$(mktemp /tmp/todo-test-w9-1-XXXXXX)
W9_1_RESP='{"issues.get":[{"data":{"number":900,"id":9900,"title":"Weekly Report","body":"due: 2026-04-05\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}],"issues.create":[{"data":{"number":9001}}],"issues.listForRepo":[{"data":[]}]}'
W9_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W9_1_RESP" OCTOKIT_STUB_LOG_ENV="$W9_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" api done-issue 900 2>&1); W9_1_EC=$?
assert_exit_ok "done-issue 正常系(recurあり): exit 0" "$W9_1_EC"
assert_contains "done-issue 正常系: JSON応答に ok:true" '"ok":true' "$W9_1_OUT"
assert_contains "done-issue 正常系: JSON応答に newIssueNumber（recur再作成先）" '"newIssueNumber":9001' "$W9_1_OUT"
assert_contains "done-issue 正常系: recurLine に次周期の日付" '繰り返しタスク #9001 を 2026-04-12 で作成しました。' "$W9_1_OUT"
assert_not_contains "done-issue 正常系: 期限超過スキップ表示が出ない（due=today、期限超過なし）" 'スキップしました' "$W9_1_OUT"
assert_eq "done-issue 正常系: issues.get 呼び出し1回" "1" "$(log_count "$W9_1_LOG" issues.get)"
assert_eq "done-issue 正常系: issues.update 呼び出し1回（close）" "1" "$(log_count "$W9_1_LOG" issues.update)"
assert_contains "done-issue 正常系: issues.update が state closed" '"state":"closed"' "$(log_lines_for_method "$W9_1_LOG" issues.update)"
assert_eq "done-issue 正常系: issues.create 呼び出し1回（recur再作成。#1669の直接検証）" "1" "$(log_count "$W9_1_LOG" issues.create)"
assert_contains "done-issue 正常系: issues.create body に次周期のdue/recurが伝播" '"body":"due: 2026-04-12\nrecur: weekly\n"' "$(log_lines_for_method "$W9_1_LOG" issues.create)"
rm -f "$W9_1_LOG"

# W9-2 正常系: recur設定なしのissueは通常通りcloseのみでrecur再作成が起きない
# #1660修正後: depends_on昇格チェックは完了Issue自身のproject/dependsOn有無にかかわらず
# 常にfetchAllOpen（issues.listForRepo）を実行するようになったため、呼び出し回数は0→1に変わる
# （他のオープンIssueがこの完了Issueに依存していないかを確認するための呼び出し）。
W9_2_LOG=$(mktemp /tmp/todo-test-w9-2-XXXXXX)
W9_2_RESP='{"issues.get":[{"data":{"number":950,"id":9950,"title":"Simple Task","body":"","labels":[{"name":"📥 inbox"}]}}],"issues.update":[{}],"issues.listForRepo":[{"data":[]}]}'
W9_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W9_2_RESP" OCTOKIT_STUB_LOG_ENV="$W9_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" api done-issue 950 2>&1); W9_2_EC=$?
assert_exit_ok "done-issue 正常系(recurなし): exit 0" "$W9_2_EC"
assert_contains "done-issue 正常系(recurなし): recurLine が null" '"recurLine":null' "$W9_2_OUT"
assert_contains "done-issue 正常系(recurなし): newIssueNumber が null" '"newIssueNumber":null' "$W9_2_OUT"
assert_eq "done-issue 正常系(recurなし): issues.update 呼び出し1回（closeのみ）" "1" "$(log_count "$W9_2_LOG" issues.update)"
assert_eq "done-issue 正常系(recurなし): issues.create 呼び出しゼロ（recur再作成が起きない）" "0" "$(log_count "$W9_2_LOG" issues.create)"
assert_eq "done-issue 正常系(recurなし): issues.listForRepo 呼び出し1回（#1660修正後: project/depends_onなしでも依存関係チェックのためfetchAllOpenされる）" "1" "$(log_count "$W9_2_LOG" issues.listForRepo)"
rm -f "$W9_2_LOG"

# W9-3 境界値: 期限超過issueのcatch-up skip挙動（nextDueCatchUpの既存挙動がdone-issue経由でも壊れていないか）
# #1660修正後: fetchAllOpen が project/dependsOn 有無に関わらず呼ばれるため空応答を1件用意する
W9_3_LOG=$(mktemp /tmp/todo-test-w9-3-XXXXXX)
W9_3_RESP='{"issues.get":[{"data":{"number":960,"id":9960,"title":"Overdue Weekly","body":"due: 2026-03-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}],"issues.create":[{"data":{"number":9002}}],"issues.listForRepo":[{"data":[]}]}'
W9_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W9_3_RESP" OCTOKIT_STUB_LOG_ENV="$W9_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" api done-issue 960 2>&1); W9_3_EC=$?
assert_exit_ok "done-issue 境界値(期限超過catchup): exit 0" "$W9_3_EC"
assert_contains "done-issue 境界値: catchup後の日付（2026-04-12）で再作成" '繰り返しタスク #9002 を 2026-04-12 で作成しました。' "$W9_3_OUT"
assert_contains "done-issue 境界値: 期限超過スキップ表示あり（nextDueCatchUp連携が壊れていない）" '期限超過のため過去の周期をスキップしました' "$W9_3_OUT"
assert_eq "done-issue 境界値: issues.create 呼び出し1回" "1" "$(log_count "$W9_3_LOG" issues.create)"
rm -f "$W9_3_LOG"

# W9-4 境界値: depends_on昇格がdone-issue経由でも従来通り動くか（postDoneProcessing共通後処理の実効検証）
W9_4_LOG=$(mktemp /tmp/todo-test-w9-4-XXXXXX)
W9_4_RESP='{"issues.get":[{"data":{"number":500,"id":9500,"title":"Depends Task","body":"depends_on: #10\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}],"issues.listForRepo":[{"data":[{"number":501,"title":"Some other task","body":"depends_on: #500\n","labels":[{"name":"🌈 someday"}],"updated_at":""}]}],"issues.removeLabel":[{}],"issues.addLabels":[{}]}'
W9_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W9_4_RESP" OCTOKIT_STUB_LOG_ENV="$W9_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" api done-issue 500 2>&1); W9_4_EC=$?
assert_exit_ok "done-issue 境界値(depends_on昇格): exit 0" "$W9_4_EC"
assert_contains "done-issue 境界値: #501が next に昇格したメッセージがotherLinesに含まれる" '#501 「Some other task」を next に昇格しました（#500 完了トリガー）' "$W9_4_OUT"
assert_contains "done-issue 境界値: 昇格件数サマリー（1件）" '1件を next に昇格しました' "$W9_4_OUT"
assert_eq "done-issue 境界値: issues.listForRepo 呼び出し1回（fetchAllOpen、project/depends_onどちらかがトリガー）" "1" "$(log_count "$W9_4_LOG" issues.listForRepo)"
assert_eq "done-issue 境界値: issues.removeLabel 呼び出し1回（#501の旧someday除去）" "1" "$(log_count "$W9_4_LOG" issues.removeLabel)"
assert_contains "done-issue 境界値: removeLabel対象が#501のsomeday" '"issue_number":501,"name":"🌈 someday"' "$(log_lines_for_method "$W9_4_LOG" issues.removeLabel)"
assert_eq "done-issue 境界値: issues.addLabels 呼び出し1回（#501にnext付与）" "1" "$(log_count "$W9_4_LOG" issues.addLabels)"
assert_contains "done-issue 境界値: addLabels対象が#501にnext" '"issue_number":501,"labels":["🎯 next"]' "$(log_lines_for_method "$W9_4_LOG" issues.addLabels)"
rm -f "$W9_4_LOG"

# W9-5 異常系: 番号なし → バリデーションエラー、API呼び出しゼロ（副作用なし確認）
W9_5_LOG=$(mktemp /tmp/todo-test-w9-5-XXXXXX)
: > "$W9_5_LOG"
W9_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W9_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" api done-issue 2>&1); W9_5_EC=$?
assert_exit_fail "done-issue 異常系: 番号なし → exit 1" "$W9_5_EC"
assert_contains "done-issue 異常系: エラーメッセージ" "Usage: api done-issue <number>" "$W9_5_OUT"
assert_eq "done-issue 異常系: API呼び出しゼロ（バリデーション先行の確認）" "0" "$(wc -l < "$W9_5_LOG" | tr -d ' ')"
rm -f "$W9_5_LOG"

# W9-6 セキュリティ/異常系: 存在しないIssue番号 → GitHub 404エラーがそのまま伝播し、非0で終了する
# （close-issue 等の既存 api サブコマンドと同じく特別なハンドリングを追加していないことの確認）
W9_6_LOG=$(mktemp /tmp/todo-test-w9-6-XXXXXX)
W9_6_RESP='{"issues.get":[{"__throw":true,"status":404,"message":"Not Found"}]}'
W9_6_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W9_6_RESP" OCTOKIT_STUB_LOG_ENV="$W9_6_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" api done-issue 999999 2>&1); W9_6_EC=$?
assert_exit_fail "done-issue セキュリティ/異常系: 存在しないIssue番号 → exit 1" "$W9_6_EC"
assert_contains "done-issue セキュリティ/異常系: GitHub APIエラーメッセージが伝播する" "Not Found" "$W9_6_OUT"
assert_eq "done-issue セキュリティ/異常系: issues.update（close）は呼ばれない（404で後続処理が実行されない）" "0" "$(log_count "$W9_6_LOG" issues.update)"
rm -f "$W9_6_LOG"

# ──────────────────────────────────────────
# §W10  postDoneProcessing — depends_on昇格ガードの独立修正（Issue #1660 バグ1）
# ──────────────────────────────────────────
echo ""
echo "§W10  postDoneProcessing — depends_on昇格ガードの独立修正（#1299/#1275型の回帰確認）"

# 背景: 旧実装は `if (issue.project || issue.dependsOn)` で depends_on 昇格ブロック全体を
# ガードしていた。しかし depends_on 昇格は「他のオープンIssueがこの完了Issueに依存しているか」
# を調べる処理であり、完了した Issue 自身が project/dependsOn を持つかどうかとは無関係。
# 実例: #1275（project/depends_onどちらも本文になし）が完了しても、#1299
#（depends_on: #1275）が本来 next へ自動昇格するはずが、このガードのせいでスキップされていた。
# 修正後は issue.project/issue.dependsOn によるガードなしで常に fetchAllOpen を実行する。

# W10-1 正常系: 完了Issueがproject/dependsOnどちらも持たなくても、それに依存する
# 他のオープンIssueが正しくnextへ昇格すること（#1299/#1275と同型の回帰テスト）
W10_1_LOG=$(mktemp /tmp/todo-test-w10-1-XXXXXX)
W10_1_RESP='{"issues.get":[{"data":{"number":700,"id":9700,"title":"Root Task (no project/dependsOn)","body":"","labels":[{"name":"📥 inbox"}]}}],"issues.update":[{}],"issues.listForRepo":[{"data":[{"number":701,"title":"Dependent Task","body":"depends_on: #700\n","labels":[{"name":"🌈 someday"}],"updated_at":""}]}],"issues.removeLabel":[{}],"issues.addLabels":[{}]}'
W10_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W10_1_RESP" OCTOKIT_STUB_LOG_ENV="$W10_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" api done-issue 700 2>&1); W10_1_EC=$?
assert_exit_ok "W10-1 正常系: exit 0" "$W10_1_EC"
assert_contains "W10-1 正常系: project/dependsOnなしの完了Issueでも依存Issue(#701)がnextに昇格する" '#701 「Dependent Task」を next に昇格しました（#700 完了トリガー）' "$W10_1_OUT"
assert_contains "W10-1 正常系: 昇格件数サマリー（1件）" '1件を next に昇格しました' "$W10_1_OUT"
assert_eq "W10-1 正常系: issues.listForRepo 呼び出し1回（project/dependsOnなしでもfetchAllOpenされる）" "1" "$(log_count "$W10_1_LOG" issues.listForRepo)"
assert_eq "W10-1 正常系: issues.addLabels 呼び出し1回（#701にnext付与）" "1" "$(log_count "$W10_1_LOG" issues.addLabels)"
assert_contains "W10-1 正常系: addLabels対象が#701にnext" '"issue_number":701,"labels":["🎯 next"]' "$(log_lines_for_method "$W10_1_LOG" issues.addLabels)"
rm -f "$W10_1_LOG"

# W10-2 正常系: 完了Issueがprojectを持つ場合、depends_on昇格とプロジェクト次タスク
# 昇格候補ヒントの両方が引き続き動作すること（既存挙動の回帰確認）
W10_2_LOG=$(mktemp /tmp/todo-test-w10-2-XXXXXX)
W10_2_RESP='{"issues.get":[{"data":{"number":710,"id":9710,"title":"Project Root Task","body":"project: #300\n","labels":[{"name":"🎯 next"}]}},{"data":{"number":300,"title":"Project X"}}],"issues.update":[{}],"issues.listForRepo":[{"data":[{"number":711,"title":"Project Sibling Task","body":"project: #300\n","labels":[{"name":"🌈 someday"}],"updated_at":""},{"number":712,"title":"Depends On Root","body":"depends_on: #710\n","labels":[{"name":"📥 inbox"}],"updated_at":""}]}],"issues.removeLabel":[{}],"issues.addLabels":[{}]}'
W10_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W10_2_RESP" OCTOKIT_STUB_LOG_ENV="$W10_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" api done-issue 710 2>&1); W10_2_EC=$?
assert_exit_ok "W10-2 正常系: exit 0" "$W10_2_EC"
assert_contains "W10-2 正常系: depends_on昇格が引き続き動作する（#712がnextに昇格）" '#712 「Depends On Root」を next に昇格しました（#710 完了トリガー）' "$W10_2_OUT"
assert_contains "W10-2 正常系: プロジェクト次タスク昇格候補ヒントが引き続き表示される（プロジェクト#300言及）" '#300' "$W10_2_OUT"
assert_contains "W10-2 正常系: 昇格候補ヒントに#711（同じproject配下、未昇格）が含まれる" '#711' "$W10_2_OUT"
assert_eq "W10-2 正常系: issues.listForRepo 呼び出し1回（depends_on昇格とプロジェクトヒントで共有）" "1" "$(log_count "$W10_2_LOG" issues.listForRepo)"
rm -f "$W10_2_LOG"

# W10-3 境界値: 依存する側が既にnextの場合は昇格スキップされること（既存ロジックの確認）
W10_3_LOG=$(mktemp /tmp/todo-test-w10-3-XXXXXX)
W10_3_RESP='{"issues.get":[{"data":{"number":720,"id":9720,"title":"Root Task 2","body":"","labels":[{"name":"📥 inbox"}]}}],"issues.update":[{}],"issues.listForRepo":[{"data":[{"number":721,"title":"Already Next Task","body":"depends_on: #720\n","labels":[{"name":"🎯 next"}],"updated_at":""}]}]}'
W10_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W10_3_RESP" OCTOKIT_STUB_LOG_ENV="$W10_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" api done-issue 720 2>&1); W10_3_EC=$?
assert_exit_ok "W10-3 境界値: exit 0" "$W10_3_EC"
assert_not_contains "W10-3 境界値: 既にnextの#721は昇格メッセージが出ない" '#721' "$W10_3_OUT"
assert_not_contains "W10-3 境界値: 昇格件数サマリーが出ない（0件のため）" '件を next に昇格しました' "$W10_3_OUT"
assert_eq "W10-3 境界値: issues.addLabels 呼び出しゼロ（既にnextのためラベル変更なし）" "0" "$(log_count "$W10_3_LOG" issues.addLabels)"
assert_eq "W10-3 境界値: issues.removeLabel 呼び出しゼロ（既にnextのためラベル変更なし）" "0" "$(log_count "$W10_3_LOG" issues.removeLabel)"
rm -f "$W10_3_LOG"

# ──────────────────────────────────────────
# §W11  runAdd — parseArgs タグ判定の空白制約（Issue #1660 バグ2）
# ──────────────────────────────────────────
echo ""
echo "§W11  runAdd — parseArgs タグ判定の空白制約（#タイトルが空になるバグの回帰確認）"

# 背景: 旧実装は `tok.startsWith('#') && !/^#\d+$/.test(tok)` で「#で始まり#数字のみでない」
# トークンを丸ごとタグとみなしていた。空白を含まない制約がないため、タイトル全体が1つの
# シェル引数（スペースを含む1トークン）として渡され、それが「#」で始まる場合
#（例: "#1299 depends-on強化について"）、丸ごとタグ扱いされ削除され、タイトルが空になる
# 「エラー: タイトルが空です」バグが発生していた。

# W11-1 正常系: スペースを含む「#1299 ...」がタイトル全体で1トークンの場合、
# タグ扱いされずタイトルとして正しく保存されること
W11_1_LOG=$(mktemp /tmp/todo-test-w11-1-XXXXXX)
# GET .../labels/{name} は既定優先度(p3)のensureLabel呼び出し分（runAddは優先度未指定時もp3ラベルをensureする）
W11_1_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":6001,"html_url":"https://github.com/test-owner/test-repo/issues/6001"}}]}'
W11_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W11_1_RESP" OCTOKIT_STUB_LOG_ENV="$W11_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run add next "#1299 depends-on強化について" 2>&1); W11_1_EC=$?
assert_exit_ok "W11-1 正常系: exit 0" "$W11_1_EC"
assert_contains "W11-1 正常系: スペースを含む#始まりの文字列がタグ扱いされずタイトルとして保存される" 'タイトル: #1299 depends-on強化について' "$W11_1_OUT"
assert_contains "W11-1 正常系: issues.create titleにタイトル全体がそのまま渡る" '"title":"#1299 depends-on強化について"' "$(log_lines_for_method "$W11_1_LOG" issues.create)"
rm -f "$W11_1_LOG"

# W11-2 正常系: 純粋な「#1299」（スペースなし単体）は従来通りタイトルの一部として扱われること
# （既存動作の回帰確認。#42のようなIssue番号表記はもともと除外対象）
W11_2_LOG=$(mktemp /tmp/todo-test-w11-2-XXXXXX)
# GET .../labels/{name} は既定優先度(p3)のensureLabel呼び出し分
W11_2_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":6002,"html_url":"https://github.com/test-owner/test-repo/issues/6002"}}]}'
W11_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W11_2_RESP" OCTOKIT_STUB_LOG_ENV="$W11_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run add next '#1299' 参照 2>&1); W11_2_EC=$?
assert_exit_ok "W11-2 正常系: exit 0" "$W11_2_EC"
assert_contains "W11-2 正常系: 純粋な#数字トークン単体はタグ扱いされずタイトルに含まれる（既存動作の回帰確認）" 'タイトル: #1299 参照' "$W11_2_OUT"
assert_contains "W11-2 正常系: issues.create titleに#1299が含まれる" '"title":"#1299 参照"' "$(log_lines_for_method "$W11_2_LOG" issues.create)"
rm -f "$W11_2_LOG"

# W11-3 正常系: 「#urgent」（スペースなし単体、genuineな単語タグ）は従来通りタグとして
# 正しく認識されること（既存動作の回帰確認）
W11_3_LOG=$(mktemp /tmp/todo-test-w11-3-XXXXXX)
# GET .../labels/{name} は #urgentタグ + 既定優先度(p3)の2回分のensureLabel呼び出し
W11_3_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{},{}],"issues.create":[{"data":{"number":6003,"html_url":"https://github.com/test-owner/test-repo/issues/6003"}}]}'
W11_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W11_3_RESP" OCTOKIT_STUB_LOG_ENV="$W11_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run add next '#urgent' 重要なタスク 2>&1); W11_3_EC=$?
assert_exit_ok "W11-3 正常系: exit 0" "$W11_3_EC"
assert_contains "W11-3 正常系: #urgent単体はタグとして認識される（既存動作の回帰確認）" 'ラベル: 🎯 next, #urgent' "$W11_3_OUT"
assert_contains "W11-3 正常系: タイトルから#urgentが除去され残りがタイトルになる" 'タイトル: 重要なタスク' "$W11_3_OUT"
assert_contains "W11-3 正常系: issues.create labelsに#urgentが含まれる（既定優先度p3も付与される）" '"labels":["🎯 next","#urgent","p3"]' "$(log_lines_for_method "$W11_3_LOG" issues.create)"
rm -f "$W11_3_LOG"

# W11-4 境界値: タイトル全体がタグ扱いされ得る内容のみの場合、意図通り
# 「タイトルが空です」エラーになること（#urgent単体のみを渡すケース）
W11_4_LOG=$(mktemp /tmp/todo-test-w11-4-XXXXXX)
: > "$W11_4_LOG"
W11_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W11_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next '#urgent' 2>&1); W11_4_EC=$?
assert_exit_fail "W11-4 境界値: タグのみ指定 → exit 1" "$W11_4_EC"
assert_contains "W11-4 境界値: エラーメッセージ「タイトルが空です」" "タイトルが空です" "$W11_4_OUT"
assert_eq "W11-4 境界値: API呼び出しゼロ（タイトル検証がラベル作成より先行）" "0" "$(wc -l < "$W11_4_LOG" | tr -d ' ')"
rm -f "$W11_4_LOG"

# ──────────────────────────────────────────
# §W12  tag/bulk tag — 不正ラベル名の新規作成防止（Issue #1686）
# ──────────────────────────────────────────
echo ""
echo "§W12  tag/bulk tag — 不正ラベル名が検証なく新規作成されるバグの回帰確認"

# 背景: `bulk tag <nums...> -- @本業` のように '--' を渡すと、normalizeTagTokens が
# '@' も '#' も付かないトークンをコンテキスト扱いして '@--' に正規化していた。
# validateCtx は FORBIDDEN_CHARS（シェル的に危険な文字）しか見ないため '-' は通過し、
# ensureLabel が '@--' ラベルを GitHub 上に新規作成して対象Issue全件に付与していた。
# 出力は通常の成功メッセージと区別がつかず、静かに永続的な副作用が残るのが問題だった。

# W12-1 境界値: '--' 区切りを渡すとオプション誤指定として拒否され、API に到達しないこと
W12_1_LOG=$(mktemp /tmp/todo-test-w12-1-XXXXXX)
: > "$W12_1_LOG"
W12_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run bulk tag 6101 6102 -- @本業 2>&1); W12_1_EC=$?
assert_exit_fail "W12-1 境界値: bulk tag に '--' を渡す → exit 1" "$W12_1_EC"
assert_contains "W12-1 境界値: オプション誤指定である旨のエラーメッセージ" "オプション指定に見えます" "$W12_1_OUT"
assert_eq "W12-1 境界値: API呼び出しゼロ（ラベル作成・付与ともに発生しない）" "0" "$(wc -l < "$W12_1_LOG" | tr -d ' ')"
rm -f "$W12_1_LOG"

# W12-2 境界値: 記号のみのコンテキスト名（'@--'）が拒否されること
W12_2_LOG=$(mktemp /tmp/todo-test-w12-2-XXXXXX)
: > "$W12_2_LOG"
W12_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run tag 6103 '@--' 2>&1); W12_2_EC=$?
assert_exit_fail "W12-2 境界値: 記号のみのコンテキスト名 → exit 1" "$W12_2_EC"
assert_contains "W12-2 境界値: 記号のみを拒否するエラーメッセージ" "記号のみの名前は使えません" "$W12_2_OUT"
assert_eq "W12-2 境界値: API呼び出しゼロ（ensureLabel より前に検証される）" "0" "$(wc -l < "$W12_2_LOG" | tr -d ' ')"
rm -f "$W12_2_LOG"

# W12-3 境界値: 記号のみのタグ名（'#--'）が拒否されること
W12_3_LOG=$(mktemp /tmp/todo-test-w12-3-XXXXXX)
: > "$W12_3_LOG"
W12_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run bulk tag 6104 '#--' 2>&1); W12_3_EC=$?
assert_exit_fail "W12-3 境界値: 記号のみのタグ名 → exit 1" "$W12_3_EC"
assert_contains "W12-3 境界値: 記号のみを拒否するエラーメッセージ" "記号のみの名前は使えません" "$W12_3_OUT"
assert_eq "W12-3 境界値: API呼び出しゼロ" "0" "$(wc -l < "$W12_3_LOG" | tr -d ' ')"
rm -f "$W12_3_LOG"

# W12-4 正常系: 既存ラベル（GET 200）を付与したときは新規作成の通知を出さないこと
W12_4_LOG=$(mktemp /tmp/todo-test-w12-4-XXXXXX)
W12_4_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.addLabels":[{}]}'
W12_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_4_RESP" OCTOKIT_STUB_LOG_ENV="$W12_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run tag 6105 '@本業' 2>&1); W12_4_EC=$?
assert_exit_ok "W12-4 正常系: 既存ラベル付与 → exit 0" "$W12_4_EC"
assert_not_contains "W12-4 正常系: 既存ラベルでは新規作成の通知を出さない" "新規ラベル" "$W12_4_OUT"
assert_eq "W12-4 正常系: createLabel 呼び出しゼロ（既存なので作成しない）" "0" "$(log_count "$W12_4_LOG" issues.createLabel)"
rm -f "$W12_4_LOG"

# W12-5 正常系: 未登録ラベル（GET 404）を付与したときは新規作成を明示すること
# 打ち間違いが静かに新ラベル化されるのを、呼び出し側が出力で気づけるようにする
W12_5_LOG=$(mktemp /tmp/todo-test-w12-5-XXXXXX)
W12_5_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{"__throw":true,"status":404,"message":"Not Found"}],"issues.createLabel":[{}],"issues.addLabels":[{}]}'
W12_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_5_RESP" OCTOKIT_STUB_LOG_ENV="$W12_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run tag 6106 '@新設コンテキスト' 2>&1); W12_5_EC=$?
assert_exit_ok "W12-5 正常系: 未登録ラベル付与 → exit 0" "$W12_5_EC"
assert_contains "W12-5 正常系: 新規ラベル作成が出力で明示される" "新規ラベル @新設コンテキスト を作成しました" "$W12_5_OUT"
assert_eq "W12-5 正常系: createLabel が1回呼ばれる" "1" "$(log_count "$W12_5_LOG" issues.createLabel)"
rm -f "$W12_5_LOG"

# ──────────────────────────────────────────
# §W13  recur 曜日・日付固定サフィックス — スタブベース振る舞いテスト（Issue #1676）
# validateRecur/nextDue のユニットテストは run-tests.sh §41 で実施済み。
# ここでは Octokit スタブが必要な経路（show --json / recur / edit --recur /
# done でのpostDoneProcessing再作成 / 破損データに対する防御）のみを検証する。
# ──────────────────────────────────────────
echo ""
echo "§W13  recur 曜日・日付固定サフィックス — スタブベース振る舞いテスト"

# W13-1 正常系: run show --json で recur がコロンごと保持されて出力されること
W13_1_LOG=$(mktemp /tmp/todo-test-w13-1-XXXXXX)
W13_1_RESP='{"issues.get":[{"data":{"number":1701,"id":97001,"title":"Weekly Review","body":"due: 2026-08-10\nrecur: weekly:sat\n","labels":[{"name":"🎯 next"}]}}]}'
W13_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_1_RESP" OCTOKIT_STUB_LOG_ENV="$W13_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1701 --json 2>&1); W13_1_EC=$?
assert_exit_ok "W13-1 正常系: run show --json exit 0" "$W13_1_EC"
assert_contains "W13-1 正常系: recur にコロンが保持される（renderIssueList回帰と対の確認）" '"recur": "weekly:sat"' "$W13_1_OUT"
rm -f "$W13_1_LOG"

# W13-2 正常系: run recur <#> weekly:sat が成功しbodyにコロン付きで保存されること
W13_2_LOG=$(mktemp /tmp/todo-test-w13-2-XXXXXX)
W13_2_RESP='{"issues.get":[{"data":{"number":1702,"id":97002,"title":"Task","body":"","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}]}'
W13_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_2_RESP" OCTOKIT_STUB_LOG_ENV="$W13_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run recur 1702 weekly:sat 2>&1); W13_2_EC=$?
assert_exit_ok "W13-2 正常系: run recur weekly:sat exit 0" "$W13_2_EC"
assert_contains "W13-2 正常系: 成功メッセージ" "✅ #1702 の繰り返しを weekly:sat に設定しました。" "$W13_2_OUT"
assert_contains "W13-2 正常系: issues.update body に recur: weekly:sat が保存される" '"body":"recur: weekly:sat\n"' "$(log_lines_for_method "$W13_2_LOG" issues.update)"
rm -f "$W13_2_LOG"

# W13-3 正常系: run edit <#> --recur monthly:15 が成功しbodyにコロン付きで保存されること
W13_3_LOG=$(mktemp /tmp/todo-test-w13-3-XXXXXX)
W13_3_RESP='{"issues.get":[{"data":{"number":1703,"id":97003,"title":"Task","body":"","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}]}'
W13_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_3_RESP" OCTOKIT_STUB_LOG_ENV="$W13_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run edit 1703 --recur monthly:15 2>&1); W13_3_EC=$?
assert_exit_ok "W13-3 正常系: run edit --recur monthly:15 exit 0" "$W13_3_EC"
assert_contains "W13-3 正常系: 成功メッセージ" "recur → monthly:15" "$W13_3_OUT"
assert_contains "W13-3 正常系: issues.update body に recur: monthly:15 が保存される" '"body":"recur: monthly:15\n"' "$(log_lines_for_method "$W13_3_LOG" issues.update)"
rm -f "$W13_3_LOG"

# W13-4 正常系: recur: weekly:sat の done → postDoneProcessing が厳密加算方式で
# 次回due(2026-08-15)を計算し、recurがコロンごと次Issueに引き継がれること
# （ユーザー承認済み検証例そのもの。期限超過なし=skippedメッセージが出ないことも確認）
W13_4_LOG=$(mktemp /tmp/todo-test-w13-4-XXXXXX)
W13_4_RESP='{"issues.get":[{"data":{"number":1704,"id":97004,"title":"Weekly Review","body":"due: 2026-08-06\nrecur: weekly:sat\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}],"issues.create":[{"data":{"number":9704}}],"issues.listForRepo":[{"data":[]}]}'
W13_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_4_RESP" OCTOKIT_STUB_LOG_ENV="$W13_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-06 \
  node "$ENGINE" run done 1704 2>&1); W13_4_EC=$?
assert_exit_ok "W13-4 正常系(weekly:sat再作成): exit 0" "$W13_4_EC"
assert_contains "W13-4 正常系: 次回due 2026-08-15（厳密加算・9日後）で再作成" "繰り返しタスク #9704 を 2026-08-15 で作成しました。" "$W13_4_OUT"
assert_not_contains "W13-4 正常系: 期限超過ではないためskip表示なし" "期限超過のため過去の周期をスキップしました" "$W13_4_OUT"
assert_contains "W13-4 正常系: issues.create body に recur: weekly:sat がコロンごと引き継がれる" '"body":"due: 2026-08-15\nrecur: weekly:sat\n"' "$(log_lines_for_method "$W13_4_LOG" issues.create)"
rm -f "$W13_4_LOG"

# W13-5 正常系: recur: monthly:31 の done → 1/31完了で対象日(31日)が2月に存在しないため
# 2/28にクランプされ、recurの指定日(31)自体は保持されたまま次Issueに引き継がれること
W13_5_LOG=$(mktemp /tmp/todo-test-w13-5-XXXXXX)
W13_5_RESP='{"issues.get":[{"data":{"number":1705,"id":97005,"title":"Month-end Task","body":"due: 2026-01-31\nrecur: monthly:31\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}],"issues.create":[{"data":{"number":9705}}],"issues.listForRepo":[{"data":[]}]}'
W13_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_5_RESP" OCTOKIT_STUB_LOG_ENV="$W13_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-01-31 \
  node "$ENGINE" run done 1705 2>&1); W13_5_EC=$?
assert_exit_ok "W13-5 正常系(monthly:31再作成・2月クランプ): exit 0" "$W13_5_EC"
assert_contains "W13-5 正常系: 次回due 2026-02-28（31日が2月に存在せずクランプ）で再作成" "繰り返しタスク #9705 を 2026-02-28 で作成しました。" "$W13_5_OUT"
assert_contains "W13-5 正常系: issues.create body に recur: monthly:31（指定日31は保持）がコロンごと引き継がれる" '"body":"due: 2026-02-28\nrecur: monthly:31\n"' "$(log_lines_for_method "$W13_5_LOG" issues.create)"
rm -f "$W13_5_LOG"

# W13-6 セキュリティ回帰: GitHub Issue本文を直接改ざんし、validateRecurを経由しない
# 不正なrecur値（weekly:INVALID）が書き込まれた状態で done を実行した場合、
# postDoneProcessing内のvalidateRecurが検知してexit 1し、周期再作成（issues.create）が
# 行われないこと（既存の防御ラインが新パターンでも機能し続けることの回帰確認）
W13_6_LOG=$(mktemp /tmp/todo-test-w13-6-XXXXXX)
W13_6_RESP='{"issues.get":[{"data":{"number":1706,"id":97006,"title":"Corrupted Recur Task","body":"due: 2026-08-06\nrecur: weekly:INVALID\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}]}'
W13_6_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_6_RESP" OCTOKIT_STUB_LOG_ENV="$W13_6_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-06 \
  node "$ENGINE" run done 1706 2>&1); W13_6_EC=$?
assert_exit_fail "W13-6 セキュリティ回帰: 不正recur(weekly:INVALID) → exit 1" "$W13_6_EC"
assert_contains "W13-6 セキュリティ回帰: エラーメッセージ" "weekly の曜日サフィックス" "$W13_6_OUT"
assert_eq "W13-6 セキュリティ回帰: issues.create 呼び出しゼロ（周期再作成が行われない）" "0" "$(log_count "$W13_6_LOG" issues.create)"
rm -f "$W13_6_LOG"

# ──────────────────────────────────────────
# §W12  resume_condition — add/edit/promote スタブベース振る舞いテスト
# ──────────────────────────────────────────
echo ""
echo "§W12  resume_condition — add/edit/promote スタブベース振る舞いテスト"
echo "  （Issue #1299由来の欠陥修正: activate到来のみで実質的な再開条件を無視して昇格していた）"

# W12-1 正常系: runAdd --resume-condition で新規Issue body に resume_condition が反映される
W12_1_LOG=$(mktemp /tmp/todo-test-w12-1-XXXXXX)
W12_1_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":7001,"html_url":"https://github.com/test-owner/test-repo/issues/7001"}}]}'
W12_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_1_RESP" OCTOKIT_STUB_LOG_ENV="$W12_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run add inbox 送客強化タスク --activate 2026-08-10 --resume-condition "検索流入が回復したら" 2>&1); W12_1_EC=$?
assert_exit_ok "W12-1 正常系: runAdd --resume-condition → exit 0" "$W12_1_EC"
assert_contains "W12-1 正常系: issues.create body に resume_condition が反映" '"body":"activate: 2026-08-10\nresume_condition: 検索流入が回復したら\n"' "$(log_lines_for_method "$W12_1_LOG" issues.create)"
rm -f "$W12_1_LOG"

# W12-2 異常系: runAdd --resume-condition に改行を含む値 → validateResumeCondition でエラー終了、issues.createは呼ばれない
W12_2_LOG=$(mktemp /tmp/todo-test-w12-2-XXXXXX)
: > "$W12_2_LOG"
W12_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run add inbox 改行テスト --resume-condition $'line1\nline2' 2>&1); W12_2_EC=$?
assert_exit_fail "W12-2 異常系: --resume-condition に改行混入 → exit 1" "$W12_2_EC"
assert_contains "W12-2 異常系: エラーメッセージ" "resume_condition に改行を含めることはできません" "$W12_2_OUT"
assert_eq "W12-2 異常系: issues.create は呼ばれない（副作用なし）" "0" "$(log_count "$W12_2_LOG" issues.create)"
rm -f "$W12_2_LOG"

# W12-3 正常系: runEdit --resume-condition で既存Issueに再開条件を後付け
W12_3_LOG=$(mktemp /tmp/todo-test-w12-3-XXXXXX)
W12_3_RESP='{"issues.get":[{"data":{"number":1299,"id":91299,"title":"サンプルタスク","body":"activate: 2026-07-15\n","labels":[{"name":"🌈 someday"}]}}],"issues.update":[{}]}'
W12_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_3_RESP" OCTOKIT_STUB_LOG_ENV="$W12_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run edit 1299 --resume-condition "example.comの検索流入が観測できるレベルに育ったとき" 2>&1); W12_3_EC=$?
assert_exit_ok "W12-3 正常系: runEdit --resume-condition → exit 0" "$W12_3_EC"
assert_contains "W12-3 正常系: changedメッセージに resume_condition → が含まれる" "resume_condition → example.comの検索流入が観測できるレベルに育ったとき" "$W12_3_OUT"
assert_contains "W12-3 正常系: issues.update body に resume_condition 行が反映" '"body":"activate: 2026-07-15\nresume_condition: example.comの検索流入が観測できるレベルに育ったとき\n"' "$(log_lines_for_method "$W12_3_LOG" issues.update)"
rm -f "$W12_3_LOG"

# W12-4 正常系: runEdit --resume-condition clear で再開条件を除去（activate等の他フィールドは保持）
W12_4_LOG=$(mktemp /tmp/todo-test-w12-4-XXXXXX)
W12_4_RESP='{"issues.get":[{"data":{"number":1299,"id":91299,"title":"サンプルタスク","body":"activate: 2026-07-15\nresume_condition: 検索流入が回復したら\n","labels":[{"name":"🌈 someday"}]}}],"issues.update":[{}]}'
W12_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_4_RESP" OCTOKIT_STUB_LOG_ENV="$W12_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run edit 1299 --resume-condition clear 2>&1); W12_4_EC=$?
assert_exit_ok "W12-4 正常系: runEdit --resume-condition clear → exit 0" "$W12_4_EC"
assert_contains "W12-4 正常系: changedメッセージ「resume_condition → クリア」" "resume_condition → クリア" "$W12_4_OUT"
assert_contains "W12-4 正常系: issues.update body から resume_condition 行が消え activate は保持" '"body":"activate: 2026-07-15\n"' "$(log_lines_for_method "$W12_4_LOG" issues.update)"
rm -f "$W12_4_LOG"

# W12-5 異常系: runEdit --resume-condition に改行を含む値 → エラー終了、issues.updateは呼ばれない
W12_5_LOG=$(mktemp /tmp/todo-test-w12-5-XXXXXX)
W12_5_RESP='{"issues.get":[{"data":{"number":1300,"id":91300,"title":"Task","body":"","labels":[{"name":"📥 inbox"}]}}]}'
W12_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_5_RESP" OCTOKIT_STUB_LOG_ENV="$W12_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run edit 1300 --resume-condition $'line1\nline2' 2>&1); W12_5_EC=$?
assert_exit_fail "W12-5 異常系: runEdit --resume-condition に改行混入 → exit 1" "$W12_5_EC"
assert_contains "W12-5 異常系: エラーメッセージ" "resume_condition に改行を含めることはできません" "$W12_5_OUT"
assert_eq "W12-5 異常系: issues.update は呼ばれない（副作用なし）" "0" "$(log_count "$W12_5_LOG" issues.update)"
rm -f "$W12_5_LOG"

# W12-6 正常系（本設計の核）: resume_condition あり + activate到来 → 機械的自動昇格をスキップし
# 確認待ちメッセージのみ出力する。addLabels/removeLabelは一切呼ばれない（Issue #1299の再現・修正確認）
W12_6_LOG=$(mktemp /tmp/todo-test-w12-6-XXXXXX)
W12_6_RESP='{"issues.listForRepo":[{"data":[{"number":1299,"title":"サンプルタスク","body":"activate: 2026-07-15\nresume_condition: example.comの検索流入が観測できるレベルに育ったとき\n","labels":[{"name":"📥 inbox"}],"updated_at":""}]}]}'
W12_6_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_6_RESP" OCTOKIT_STUB_LOG_ENV="$W12_6_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run promote 2>&1); W12_6_EC=$?
assert_exit_ok "W12-6 正常系(核心): runPromote resume_condition あり → exit 0" "$W12_6_EC"
assert_contains "W12-6 正常系: pending_reviewメッセージに#1299・タイトル・条件文が含まれる" '⏸ #1299 「サンプルタスク」activate日到来ですが再開条件の確認が必要です: example.comの検索流入が観測できるレベルに育ったとき' "$W12_6_OUT"
assert_contains "W12-6 正常系: pending_summaryメッセージ（1件）" '⏸ 1件が再開条件の確認待ちです' "$W12_6_OUT"
assert_not_contains "W12-6 正常系: 機械的昇格メッセージ（promote.promoted）は出ない" 'を next に昇格しました' "$W12_6_OUT"
assert_eq "W12-6 正常系: issues.addLabels は一切呼ばれない（自動昇格をスキップした実効検証）" "0" "$(log_count "$W12_6_LOG" issues.addLabels)"
assert_eq "W12-6 正常系: issues.removeLabel は一切呼ばれない（GTDラベルを変更していない実効検証）" "0" "$(log_count "$W12_6_LOG" issues.removeLabel)"
rm -f "$W12_6_LOG"

# W12-7 リグレッション: resume_condition なし + activate到来 → 既存どおり機械的にnextへ昇格する
# （resume_condition機能追加による既存挙動への影響がないことの確認）
W12_7_LOG=$(mktemp /tmp/todo-test-w12-7-XXXXXX)
W12_7_RESP='{"issues.listForRepo":[{"data":[{"number":1301,"title":"通常のチクラータスク","body":"activate: 2026-07-15\n","labels":[{"name":"📥 inbox"}],"updated_at":""}]}],"issues.removeLabel":[{}],"issues.addLabels":[{}]}'
W12_7_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_7_RESP" OCTOKIT_STUB_LOG_ENV="$W12_7_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run promote 2>&1); W12_7_EC=$?
assert_exit_ok "W12-7 リグレッション: runPromote resume_condition なし → exit 0" "$W12_7_EC"
assert_contains "W12-7 リグレッション: 従来通りの昇格メッセージが出る" '#1301 「通常のチクラータスク」を next に昇格しました（activate: 2026-07-15）' "$W12_7_OUT"
assert_contains "W12-7 リグレッション: 昇格件数サマリー（1件）" '✅ 1件を next に昇格しました' "$W12_7_OUT"
assert_eq "W12-7 リグレッション: issues.addLabels 呼び出し1回（従来通りnext付与）" "1" "$(log_count "$W12_7_LOG" issues.addLabels)"
rm -f "$W12_7_LOG"

# W12-8 境界値: resume_condition あり + 昇格(promoted)なしの混在 → サマリーに両方の件数が表示される
W12_8_LOG=$(mktemp /tmp/todo-test-w12-8-XXXXXX)
W12_8_RESP='{"issues.listForRepo":[{"data":[{"number":1299,"title":"Pending Task","body":"activate: 2026-07-15\nresume_condition: 検索流入が回復したら\n","labels":[{"name":"📥 inbox"}],"updated_at":""},{"number":1301,"title":"Normal Task","body":"activate: 2026-07-15\n","labels":[{"name":"📥 inbox"}],"updated_at":""}]}],"issues.removeLabel":[{}],"issues.addLabels":[{}]}'
W12_8_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_8_RESP" OCTOKIT_STUB_LOG_ENV="$W12_8_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run promote 2>&1); W12_8_EC=$?
assert_exit_ok "W12-8 境界値: 混在ケース → exit 0" "$W12_8_EC"
assert_contains "W12-8 境界値: #1299 は確認待ち" '⏸ #1299' "$W12_8_OUT"
assert_contains "W12-8 境界値: #1301 は昇格" '#1301 「Normal Task」を next に昇格しました' "$W12_8_OUT"
assert_contains "W12-8 境界値: 昇格サマリー（1件）" '✅ 1件を next に昇格しました' "$W12_8_OUT"
assert_contains "W12-8 境界値: 確認待ちサマリー（1件）" '⏸ 1件が再開条件の確認待ちです' "$W12_8_OUT"
assert_eq "W12-8 境界値: issues.addLabels 呼び出し1回（#1301のみ、#1299はスキップ）" "1" "$(log_count "$W12_8_LOG" issues.addLabels)"
assert_contains "W12-8 境界値: addLabels対象が#1301のみ" '"issue_number":1301' "$(log_lines_for_method "$W12_8_LOG" issues.addLabels)"
rm -f "$W12_8_LOG"

# W12-9 境界値: resume_condition あり + activate未到来（未来日） → 既存の「activate未到来はpromote対象外」
# 動作がresume_condition追加後も維持されること（新規エラーにしない・pending扱いにもしない）
W12_9_LOG=$(mktemp /tmp/todo-test-w12-9-XXXXXX)
W12_9_RESP='{"issues.listForRepo":[{"data":[{"number":1400,"title":"Future Task","body":"activate: 2099-01-01\nresume_condition: 何かの条件\n","labels":[{"name":"📥 inbox"}],"updated_at":""}]}]}'
W12_9_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_9_RESP" OCTOKIT_STUB_LOG_ENV="$W12_9_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run promote 2>&1); W12_9_EC=$?
assert_exit_ok "W12-9 境界値: activate未到来 → exit 0" "$W12_9_EC"
assert_contains "W12-9 境界値: 昇格対象なしメッセージ（未到来のため走査対象外）" '昇格対象なし（activate日到来タスク: 0件）' "$W12_9_OUT"
assert_not_contains "W12-9 境界値: #1400 への言及がない（走査対象外）" '#1400' "$W12_9_OUT"
rm -f "$W12_9_LOG"

# W12-10 正常系: runShow --json に resumeCondition フィールドが含まれる
W12_10_LOG=$(mktemp /tmp/todo-test-w12-10-XXXXXX)
W12_10_RESP='{"issues.get":[{"data":{"number":1299,"id":91299,"title":"サンプルタスク","body":"activate: 2026-07-15\nresume_condition: example.comの検索流入が観測できるレベルに育ったとき\n","labels":[{"name":"🌈 someday"}]}}]}'
W12_10_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_10_RESP" OCTOKIT_STUB_LOG_ENV="$W12_10_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1299 --json 2>&1); W12_10_EC=$?
assert_exit_ok "W12-10 正常系: runShow --json → exit 0" "$W12_10_EC"
assert_contains "W12-10 正常系: JSON応答に resumeCondition フィールドが含まれる" '"resumeCondition": "example.comの検索流入が観測できるレベルに育ったとき"' "$W12_10_OUT"
rm -f "$W12_10_LOG"

# ──────────────────────────────────────────
# §W14  show の state/closedAt 表示 — スタブベース振る舞いテスト（Issue #1746）
# GTDラベルを保持したまま close する運用のため、ラベルだけでは open/closed を
# 判別できない。show 出力に state（open/closed）と closedAt を追加する。
# ──────────────────────────────────────────
echo ""
echo "§W14  show の state/closedAt 表示 — スタブベース振る舞いテスト（Issue #1746）"

# W14-1 正常系: closed Issue を show（人間向け出力）→ 状態行が表示され完了日が入る
W14_1_LOG=$(mktemp /tmp/todo-test-w14-1-XXXXXX)
W14_1_RESP='{"issues.get":[{"data":{"number":1740,"id":91740,"title":"完了済みタスク","body":"","labels":[{"name":"🎯 next"}],"state":"closed","closed_at":"2026-08-09T09:29:00Z"}}]}'
W14_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W14_1_RESP" OCTOKIT_STUB_LOG_ENV="$W14_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1740 2>&1); W14_1_EC=$?
assert_exit_ok "W14-1 正常系: runShow(closed) → exit 0" "$W14_1_EC"
assert_contains "W14-1 正常系: 状態行に完了・クローズ日が表示される" '- 状態: ✅ 完了（2026-08-09）' "$W14_1_OUT"
rm -f "$W14_1_LOG"

# W14-2 正常系: open Issue を show（人間向け出力）→ 状態行は表示されない（冗長回避）
W14_2_LOG=$(mktemp /tmp/todo-test-w14-2-XXXXXX)
W14_2_RESP='{"issues.get":[{"data":{"number":1746,"id":91746,"title":"未完了タスク","body":"","labels":[{"name":"🎯 next"}],"state":"open","closed_at":null}}]}'
W14_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W14_2_RESP" OCTOKIT_STUB_LOG_ENV="$W14_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1746 2>&1); W14_2_EC=$?
assert_exit_ok "W14-2 正常系: runShow(open) → exit 0" "$W14_2_EC"
assert_not_contains "W14-2 正常系: open では状態行が表示されない（冗長回避）" '- 状態:' "$W14_2_OUT"
rm -f "$W14_2_LOG"

# W14-3 正常系: closed Issue を show --json → state:"closed" と closedAt が含まれる
W14_3_LOG=$(mktemp /tmp/todo-test-w14-3-XXXXXX)
W14_3_RESP='{"issues.get":[{"data":{"number":1740,"id":91740,"title":"完了済みタスク","body":"","labels":[{"name":"🎯 next"}],"state":"closed","closed_at":"2026-08-09T09:29:00Z"}}]}'
W14_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W14_3_RESP" OCTOKIT_STUB_LOG_ENV="$W14_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1740 --json 2>&1); W14_3_EC=$?
assert_exit_ok "W14-3 正常系: runShow --json(closed) → exit 0" "$W14_3_EC"
assert_contains "W14-3 正常系: JSON応答に state:closed が含まれる" '"state": "closed"' "$W14_3_OUT"
assert_contains "W14-3 正常系: JSON応答に closedAt が含まれる" '"closedAt": "2026-08-09T09:29:00Z"' "$W14_3_OUT"
rm -f "$W14_3_LOG"

# W14-4 正常系: open Issue を show --json → state:"open"、closedAt は null
W14_4_LOG=$(mktemp /tmp/todo-test-w14-4-XXXXXX)
W14_4_RESP='{"issues.get":[{"data":{"number":1746,"id":91746,"title":"未完了タスク","body":"","labels":[{"name":"🎯 next"}],"state":"open","closed_at":null}}]}'
W14_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W14_4_RESP" OCTOKIT_STUB_LOG_ENV="$W14_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1746 --json 2>&1); W14_4_EC=$?
assert_exit_ok "W14-4 正常系: runShow --json(open) → exit 0" "$W14_4_EC"
assert_contains "W14-4 正常系: JSON応答に state:open が含まれる" '"state": "open"' "$W14_4_OUT"
assert_contains "W14-4 正常系: JSON応答に closedAt:null が含まれる" '"closedAt": null' "$W14_4_OUT"
rm -f "$W14_4_LOG"

# ──────────────────────────────────────────
# §W15  closedAt のJST日付変換 — show/archive の表示ズレ修正（Issue #1748）
# 実証: 2026-08-09 実環境で確認済み。closed_at=2026-08-08T23:32:23Z（実issue #1739）は
# JSTでは2026-08-09 08:32だが、修正前は `.slice(0,10)` によりUTC日付の
# 「2026-08-08」がそのまま表示されていた。
# ──────────────────────────────────────────

# W15-1: show（人間向け出力）— 実証データそのまま（#1739）
W15_1_LOG=$(mktemp /tmp/todo-test-w15-1-XXXXXX)
W15_1_RESP='{"issues.get":[{"data":{"number":1739,"id":91739,"title":"検証用 recur Undo確認 1656","body":"","labels":[{"name":"🎯 next"}],"state":"closed","closed_at":"2026-08-08T23:32:23Z"}}]}'
W15_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W15_1_RESP" OCTOKIT_STUB_LOG_ENV="$W15_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1739 2>&1); W15_1_EC=$?
assert_exit_ok "W15-1 正常系: runShow(#1739 境界またぎ) → exit 0" "$W15_1_EC"
assert_contains "W15-1 正常系: 完了日がJST変換後（2026-08-09）で表示される" '- 状態: ✅ 完了（2026-08-09）' "$W15_1_OUT"
assert_not_contains "W15-1 正常系: UTC日付（2026-08-08）のままでは表示されない" '- 状態: ✅ 完了（2026-08-08）' "$W15_1_OUT"
rm -f "$W15_1_LOG"

# W15-2: archive list — closedAt の表示日付がJST基準になる
W15_2_LOG=$(mktemp /tmp/todo-test-w15-2-XXXXXX)
W15_2_RESP='{"issues.listForRepo":[{"data":[{"number":1739,"title":"境界またぎ","state":"closed","closed_at":"2026-08-08T23:32:23Z","labels":[],"pull_request":null}]}]}'
W15_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W15_2_RESP" OCTOKIT_STUB_LOG_ENV="$W15_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run archive list 2>&1); W15_2_EC=$?
assert_exit_ok "W15-2 正常系: runArchive list(境界またぎ) → exit 0" "$W15_2_EC"
assert_contains "W15-2 正常系: archive list の日付がJST変換後（2026-08-09）" '✅2026-08-09' "$W15_2_OUT"
assert_not_contains "W15-2 正常系: UTC日付（2026-08-08）のままでは表示されない" '✅2026-08-08' "$W15_2_OUT"
rm -f "$W15_2_LOG"

# ──────────────────────────────────────────
# §W16  LANG_ENV=en 出力の日本語混入チェック（Issue #1653）
# CLI改善: i18n収容。書き込み系ハンドラ（GitHub API を呼ぶ関数）が組み立てる
# 成功メッセージ・エラーメッセージを LANG_ENV=en で実行し、
# 「日本語文字が1文字も含まれないこと」を機械的に検証する（個別文言の逐一確認より
# 書き漏らしの再発防止に効く）。あわせて主要語の英訳が含まれることも確認する。
# ──────────────────────────────────────────
echo ""
echo "§W16  LANG_ENV=en 出力の日本語混入チェック（Issue #1653）"

# 共通ヘルパー: LANG_ENV=en・スタブ応答つきで `run <args...>` を実行し、
# 結果を LAST_OUT / LAST_EC に格納する（グローバル変数、直後にアサートする用途限定）
run_stub_en() {
  local resp="$1"; shift
  LAST_OUT=$(LANG_ENV=en OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$resp" \
    TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
    node "$ENGINE" run "$@" 2>&1); LAST_EC=$?
}

# W16-1: runAdd
run_stub_en '{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":20001,"html_url":"https://example.com/20001"}}]}' \
  add "buy milk"
assert_exit_ok "W16-1 runAdd(en): exit 0" "$LAST_EC"
assert_contains "W16-1 runAdd(en): 英語の作成メッセージ" "created." "$LAST_OUT"
assert_no_japanese "W16-1 runAdd(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-2: runDone（recur再作成込み）
W16_2_ISSUE='{"number":20100,"id":920100,"title":"weekly task","body":"due: 2026-04-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_2_ISSUE}],\"issues.update\":[{}],\"issues.create\":[{\"data\":{\"number\":20101}}],\"issues.listForRepo\":[{\"data\":[]}]}" \
  done 20100
assert_exit_ok "W16-2 runDone(en, recur再作成): exit 0" "$LAST_EC"
assert_contains "W16-2 runDone(en): completed." "completed." "$LAST_OUT"
assert_contains "W16-2 runDone(en): Recurring task 再作成メッセージ" "Recurring task #20101 created for 2026-04-08" "$LAST_OUT"
assert_no_japanese "W16-2 runDone(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-3: runMove
W16_3_ISSUE='{"number":20200,"labels":[{"name":"📥 inbox"}]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_3_ISSUE}],\"issues.removeLabel\":[{}],\"issues.addLabels\":[{}]}" \
  move 20200 next
assert_exit_ok "W16-3 runMove(en): exit 0" "$LAST_EC"
assert_contains "W16-3 runMove(en): moved to" "moved to" "$LAST_OUT"
assert_no_japanese "W16-3 runMove(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-4: runEdit（due/recur を clear）
W16_4_ISSUE='{"number":20300,"body":"due: 2026-04-01\nrecur: weekly\n","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_4_ISSUE}],\"issues.update\":[{}]}" \
  edit 20300 --due clear --recur clear
assert_exit_ok "W16-4 runEdit(en): exit 0" "$LAST_EC"
assert_contains "W16-4 runEdit(en): cleared 表記" "due → cleared, recur → cleared" "$LAST_OUT"
assert_no_japanese "W16-4 runEdit(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-5: runDue（clear / set）
W16_5_ISSUE='{"number":20400,"body":"due: 2026-04-01\n","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_5_ISSUE}],\"issues.update\":[{}]}" \
  due 20400 clear
assert_exit_ok "W16-5a runDue clear(en): exit 0" "$LAST_EC"
assert_contains "W16-5a runDue clear(en): due date cleared" "due date cleared" "$LAST_OUT"
assert_no_japanese "W16-5a runDue clear(en): 出力に日本語が含まれない" "$LAST_OUT"

run_stub_en "{\"issues.get\":[{\"data\":$W16_5_ISSUE}],\"issues.update\":[{}]}" \
  due 20401 2026-05-01
assert_exit_ok "W16-5b runDue set(en): exit 0" "$LAST_EC"
assert_contains "W16-5b runDue set(en): due date set to" "due date set to 2026-05-01" "$LAST_OUT"
assert_no_japanese "W16-5b runDue set(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-6: runDesc
W16_6_ISSUE='{"number":20500,"body":"","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_6_ISSUE}],\"issues.update\":[{}]}" \
  desc 20500 "additional note"
assert_exit_ok "W16-6 runDesc(en): exit 0" "$LAST_EC"
assert_contains "W16-6 runDesc(en): description appended" "description appended" "$LAST_OUT"
assert_no_japanese "W16-6 runDesc(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-7: runRecur（set / clear）
W16_7_ISSUE='{"number":20600,"body":"","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_7_ISSUE}],\"issues.update\":[{}]}" \
  recur 20600 weekly:sat
assert_exit_ok "W16-7a runRecur set(en): exit 0" "$LAST_EC"
assert_contains "W16-7a runRecur set(en): recurrence set to" "recurrence set to weekly:sat" "$LAST_OUT"
assert_no_japanese "W16-7a runRecur set(en): 出力に日本語が含まれない" "$LAST_OUT"

run_stub_en "{\"issues.get\":[{\"data\":$W16_7_ISSUE}],\"issues.update\":[{}]}" \
  recur 20601 clear
assert_contains "W16-7b runRecur clear(en): recurrence cleared" "recurrence cleared" "$LAST_OUT"
assert_no_japanese "W16-7b runRecur clear(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-8: runLink 異常系（親がプロジェクトでない）
W16_8_CHILD='{"number":20700,"body":"","labels":[]}'
W16_8_PARENT='{"number":20701,"body":"","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_8_CHILD},{\"data\":$W16_8_PARENT}]}" \
  link 20700 20701
assert_exit_fail "W16-8 runLink 異常系(en): exit 1" "$LAST_EC"
assert_contains "W16-8 runLink 異常系(en): is not a project" "is not a project" "$LAST_OUT"
assert_no_japanese "W16-8 runLink 異常系(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-9: runRename
run_stub_en '{"issues.update":[{}]}' rename 20800 "New Title"
assert_exit_ok "W16-9 runRename(en): exit 0" "$LAST_EC"
assert_contains "W16-9 runRename(en): renamed to" 'renamed to "New Title"' "$LAST_OUT"
assert_no_japanese "W16-9 runRename(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-10: runPriority
W16_10_ISSUE='{"number":20900,"labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_10_ISSUE}],\"GET /repos/{owner}/{repo}/labels/{name}\":[{}],\"issues.addLabels\":[{}]}" \
  priority 20900 p1
assert_exit_ok "W16-10 runPriority(en): exit 0" "$LAST_EC"
assert_contains "W16-10 runPriority(en): priority set to" "priority set to p1" "$LAST_OUT"
assert_no_japanese "W16-10 runPriority(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-11: tag rename（renameCtxLabel 経由）
W16_11_LIST='[{"number":21000,"title":"t","body":"","labels":[{"name":"@oldctx"}]}]'
run_stub_en "{\"GET /repos/{owner}/{repo}/labels/{name}\":[{}],\"issues.listForRepo\":[{\"data\":$W16_11_LIST}],\"issues.addLabels\":[{}],\"issues.removeLabel\":[{}],\"issues.deleteLabel\":[{}]}" \
  tag rename oldctx newctx
assert_exit_ok "W16-11 tag rename(en): exit 0" "$LAST_EC"
assert_contains "W16-11 tag rename(en): Renamed ... Updated N issue(s)" "Renamed @oldctx to @newctx. Updated 1 issue(s)." "$LAST_OUT"
assert_no_japanese "W16-11 tag rename(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-12: runTag / runUntag
run_stub_en '{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.addLabels":[{}]}' tag 21100 @home
assert_exit_ok "W16-12a runTag(en): exit 0" "$LAST_EC"
assert_contains "W16-12a runTag(en): Added ... to" "Added @home to #21100." "$LAST_OUT"
assert_no_japanese "W16-12a runTag(en): 出力に日本語が含まれない" "$LAST_OUT"

run_stub_en '{"issues.removeLabel":[{}]}' untag 21101 @home
assert_contains "W16-12b runUntag(en): Removed ... from" "Removed @home from #21101." "$LAST_OUT"
assert_no_japanese "W16-12b runUntag(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-13: runLabel add / delete
run_stub_en '{"GET /repos/{owner}/{repo}/labels/{name}":[{}]}' label add newctx
assert_exit_ok "W16-13a runLabel add(en): exit 0" "$LAST_EC"
assert_contains "W16-13a runLabel add(en): Label ... created" "Label @newctx created." "$LAST_OUT"
assert_no_japanese "W16-13a runLabel add(en): 出力に日本語が含まれない" "$LAST_OUT"

run_stub_en '{"issues.deleteLabel":[{}]}' label delete newctx
assert_contains "W16-13b runLabel delete(en): Label ... deleted" "Label @newctx deleted." "$LAST_OUT"
assert_no_japanese "W16-13b runLabel delete(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-14: runSearch（0件 / N件）
run_stub_en '{"search.issuesAndPullRequests":[{"data":{"items":[]}}]}' search zzz-no-hit
assert_contains "W16-14a runSearch 0件(en)" "Search results: 0 (keyword: zzz-no-hit)" "$LAST_OUT"
assert_no_japanese "W16-14a runSearch 0件(en): 出力に日本語が含まれない" "$LAST_OUT"

W16_14B_ITEMS='[{"number":21200,"title":"hit","labels":[]}]'
run_stub_en "{\"search.issuesAndPullRequests\":[{\"data\":{\"items\":$W16_14B_ITEMS}}]}" search hit
assert_contains "W16-14b runSearch 1件(en)" "Search results: 1" "$LAST_OUT"
assert_no_japanese "W16-14b runSearch 1件(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-15: runArchive reopen
run_stub_en '{"issues.update":[{}],"issues.addLabels":[{}]}' archive reopen 21300
assert_contains "W16-15 runArchive reopen(en): returned to inbox" "returned to inbox." "$LAST_OUT"
assert_no_japanese "W16-15 runArchive reopen(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-16: runBulk（done/move/tag/untag/priority）
W16_16_ISSUE='{"number":21400,"body":"","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_16_ISSUE}],\"issues.update\":[{}],\"issues.listForRepo\":[{\"data\":[]}]}" \
  bulk done 21400
assert_contains "W16-16a runBulk done(en): completed" "✅ 1 completed" "$LAST_OUT"
assert_no_japanese "W16-16a runBulk done(en): 出力に日本語が含まれない" "$LAST_OUT"

W16_16B_ISSUE='{"number":21401,"labels":[{"name":"⏳ waiting"}]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_16B_ISSUE}],\"issues.addLabels\":[{}]}" \
  bulk move 21401 waiting
assert_contains "W16-16b runBulk move(en): Moved ... to" "Moved 1 to ⏳ waiting" "$LAST_OUT"
assert_no_japanese "W16-16b runBulk move(en): 出力に日本語が含まれない" "$LAST_OUT"

run_stub_en '{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.addLabels":[{}]}' \
  bulk tag 21402 @office
assert_contains "W16-16c runBulk tag(en): Added ... to" "Added @office to 1" "$LAST_OUT"
assert_no_japanese "W16-16c runBulk tag(en): 出力に日本語が含まれない" "$LAST_OUT"

run_stub_en '{"issues.removeLabel":[{}]}' bulk untag 21403 @office
assert_contains "W16-16d runBulk untag(en): Removed ... from" "Removed @office from 1" "$LAST_OUT"
assert_no_japanese "W16-16d runBulk untag(en): 出力に日本語が含まれない" "$LAST_OUT"

W16_16E_ISSUE='{"number":21404,"labels":[]}'
run_stub_en "{\"GET /repos/{owner}/{repo}/labels/{name}\":[{}],\"issues.get\":[{\"data\":$W16_16E_ISSUE}],\"issues.addLabels\":[{}]}" \
  bulk priority 21404 p2
assert_contains "W16-16e runBulk priority(en): Set priority ... for" "Set priority to p2 for 1" "$LAST_OUT"
assert_no_japanese "W16-16e runBulk priority(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-17: runReviewSomeday
W16_17_ISSUE='{"number":21500,"body":"","labels":[{"name":"🌈 someday"}]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_17_ISSUE}],\"issues.update\":[{}]}" \
  review-someday 21500
assert_contains "W16-17 runReviewSomeday(en): reviewed_at updated to" "reviewed_at updated to" "$LAST_OUT"
assert_no_japanese "W16-17 runReviewSomeday(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-18: runPromoteProject / runUnlink
W16_18_ISSUE='{"number":21600,"title":"some task","body":"","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_18_ISSUE}],\"GET /repos/{owner}/{repo}/labels/{name}\":[{}],\"issues.addLabels\":[{}]}" \
  promote-project 21600
assert_contains "W16-18a runPromoteProject(en): promoted to project" "promoted to project." "$LAST_OUT"
assert_contains "W16-18a runPromoteProject(en): hint" "To add the first Next Action" "$LAST_OUT"
assert_no_japanese "W16-18a runPromoteProject(en): 出力に日本語が含まれない" "$LAST_OUT"

W16_18B_ISSUE='{"number":21700,"id":921700,"body":"project: #21600\n","labels":[]}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_18B_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[{\"id\":921700}]}],\"DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue\":[{}],\"issues.update\":[{}]}" \
  unlink 21700
assert_contains "W16-18b runUnlink(en): project link removed" "project link removed." "$LAST_OUT"
assert_no_japanese "W16-18b runUnlink(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-19: runWeeklyProjectAudit
W16_19_LIST='[{"number":21800,"title":"proj","updated_at":"2026-01-01T00:00:00Z","labels":[{"name":"📁 project"}]}]'
run_stub_en "{\"issues.listForRepo\":[{\"data\":$W16_19_LIST}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[]}],\"issues.update\":[{}]}" \
  weekly-project-audit
assert_exit_ok "W16-19 runWeeklyProjectAudit(en): exit 0" "$LAST_EC"
assert_no_japanese "W16-19 runWeeklyProjectAudit(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-20: runMigrateSubIssue（dry-run / 本実行）
W16_20_LIST='[{"number":21900,"title":"child","body":"project: #21901\n","labels":[]}]'
run_stub_en "{\"issues.listForRepo\":[{\"data\":$W16_20_LIST}]}" migrate sub-issue --dry-run
assert_contains "W16-20a migrate dry-run(en): header" "migrate sub-issue --dry-run" "$LAST_OUT"
assert_no_japanese "W16-20a migrate dry-run(en): 出力に日本語が含まれない" "$LAST_OUT"

W16_20B_PARENT='{"number":21901,"labels":[{"name":"📁 project"}]}'
run_stub_en "{\"issues.listForRepo\":[{\"data\":$W16_20_LIST}],\"issues.get\":[{\"data\":$W16_20B_PARENT}],\"POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{}]}" \
  migrate sub-issue
assert_contains "W16-20b migrate 本実行(en): complete" "migrate sub-issue complete: 1 registered / 0 skipped / 0 errors" "$LAST_OUT"
assert_no_japanese "W16-20b migrate 本実行(en): 出力に日本語が含まれない" "$LAST_OUT"

# ──────────────────────────────────────────
# §W20  runMigrateSubIssue の sub_issue_id 正当性・422判別（Issue #1879）
# 症状: fetchAllOpen が id を返さず sub_issue_id:undefined で POST していた（欠陥1）。
# かつ 422 を無条件に「既登録」と誤判定していた（欠陥2）。
# 以下は「意図的破壊」で有効性を検証済み（完了報告に破壊時の FAIL 結果を記載）。
# ──────────────────────────────────────────
echo ""
echo "§W20  runMigrateSubIssue の sub_issue_id 正当性・422判別（Issue #1879）"

# #1879-1: fetchAllOpen が返す id が POST の sub_issue_id にそのまま伝播すること
#   （fetchAllOpen の map から id を外すとこのテストは FAIL する＝欠陥1の回帰検知）
W1879_1_CHILD='{"number":31900,"id":931900,"title":"child","body":"project: #31901\n","labels":[]}'
W1879_1_PARENT='{"number":31901,"labels":[{"name":"📁 project"}]}'
W1879_1_LOG=$(mktemp /tmp/todo-test-1879-1-XXXXXX)
: > "$W1879_1_LOG"
W1879_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W1879_1_LOG" \
  OCTOKIT_STUB_RESPONSES_ENV="{\"issues.listForRepo\":[{\"data\":[$W1879_1_CHILD]}],\"issues.get\":[{\"data\":$W1879_1_PARENT}],\"POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{}]}" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run migrate sub-issue 2>&1); W1879_1_EC=$?
assert_exit_ok "#1879-1 migrate 本実行: exit 0" "$W1879_1_EC"
assert_contains "#1879-1 migrate: サマリーは1件登録" "✅ migrate sub-issue 完了: 1件登録 / 0件スキップ / 0件エラー" "$W1879_1_OUT"
assert_contains "#1879-1 migrate: POST の sub_issue_id が fetchAllOpen の id(931900)と一致（undefinedでない）" \
  "\"sub_issue_id\":931900" "$(log_lines_for_method "$W1879_1_LOG" 'POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues')"
assert_not_contains "#1879-1 migrate: POST の sub_issue_id が undefined でない" \
  '"sub_issue_id":null' "$(log_lines_for_method "$W1879_1_LOG" 'POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues')"
rm -f "$W1879_1_LOG"

# #1879-2: 422 かつ listSubIssues に本当に登録済み → 冪等スキップ（従来動作の維持確認）
W1879_2_CHILD='{"number":31902,"id":931902,"title":"child2","body":"project: #31903\n","labels":[]}'
W1879_2_PARENT='{"number":31903,"labels":[{"name":"📁 project"}]}'
W1879_2_EXISTING='[{"id":931902,"number":31902}]'
W1879_2_LOG=$(mktemp /tmp/todo-test-1879-2-XXXXXX)
: > "$W1879_2_LOG"
W1879_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W1879_2_LOG" \
  OCTOKIT_STUB_RESPONSES_ENV="{\"issues.listForRepo\":[{\"data\":[$W1879_2_CHILD]}],\"issues.get\":[{\"data\":$W1879_2_PARENT}],\"POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"__throw\":true,\"status\":422,\"message\":\"Validation Failed: sub_issue_id already assigned to a parent\"}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":$W1879_2_EXISTING}]}" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run migrate sub-issue 2>&1); W1879_2_EC=$?
assert_exit_ok "#1879-2 migrate 本実行(422・既登録): exit 0" "$W1879_2_EC"
assert_contains "#1879-2 migrate: 一覧に本当に存在する422はスキップ計上" "✅ migrate sub-issue 完了: 0件登録 / 1件スキップ / 0件エラー" "$W1879_2_OUT"
rm -f "$W1879_2_LOG"

# #1879-3: 422 だが listSubIssues に登録されていない（例: sub_issue_id 不正 / 別の親に登録済み）
#   → 「既登録」と誤判定せず error として計上する
#   （addSubIssue を「422は無条件skip」に戻すとこのテストは FAIL する＝欠陥2の回帰検知）
W1879_3_CHILD='{"number":31904,"id":931904,"title":"child3","body":"project: #31905\n","labels":[]}'
W1879_3_PARENT='{"number":31905,"labels":[{"name":"📁 project"}]}'
W1879_3_LOG=$(mktemp /tmp/todo-test-1879-3-XXXXXX)
: > "$W1879_3_LOG"
W1879_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W1879_3_LOG" \
  OCTOKIT_STUB_RESPONSES_ENV="{\"issues.listForRepo\":[{\"data\":[$W1879_3_CHILD]}],\"issues.get\":[{\"data\":$W1879_3_PARENT}],\"POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"__throw\":true,\"status\":422,\"message\":\"Validation Failed: sub_issue_id already assigned to a different parent\"}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[]}]}" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run migrate sub-issue 2>&1); W1879_3_EC=$?
assert_exit_ok "#1879-3 migrate 本実行(422・未登録): exit 0" "$W1879_3_EC"
assert_contains "#1879-3 migrate: 一覧に存在しない422はエラー計上（誤ってskipしない）" "✅ migrate sub-issue 完了: 0件登録 / 0件スキップ / 1件エラー" "$W1879_3_OUT"
assert_contains "#1879-3 migrate: エラーメッセージに元の e.message がそのまま含まれる" \
  "Validation Failed: sub_issue_id already assigned to a different parent" "$W1879_3_OUT"
rm -f "$W1879_3_LOG"

# ──────────────────────────────────────────
# §W21  状態整合性の順序統一 — validate-before-mutate / create-before-close（Issue #1652）
# ──────────────────────────────────────────
# 起票元: content/reviews/2026-08-03_todo-engine_reviewer.md の2件。
#   課題A: runPriority/runEdit が「旧priorityラベル削除 → validate」の順で、
#          typo時に既存ラベルだけ破壊してエラー終了していた（validate-before-mutateへ統一）。
#          → runEdit/runPriority 側は W5-3 / W6-2 を修正後の挙動に更新済み（本節では重複しない）。
#   課題B: runDone のリカレンスが「close成功 → 新Issue create」の順で、create失敗時に
#          次周期が失われていた（create-before-closeへ統一。recur再作成のみ createRecurIssue
#          として close 前に切り出し、depends_on昇格・project昇格ヒントは postDoneProcessing
#          として close 後のまま維持。理由: fetchAllOpenが完了直後の自分自身を候補に
#          混入させてしまうため）。
# 以下は「意図的破壊」で有効性を検証済み（完了報告に破壊時の FAIL 結果を記載）。
echo ""
echo "§W21  状態整合性の順序統一 — validate-before-mutate / create-before-close（Issue #1652）"

# #1652-B1: runDone — recur再作成(create)は成功するがclose(issues.update)が失敗するケース。
#   旧実装（close→create順）だとこの状況でissues.createは0回のまま次周期が永久に失われるため、
#   「issues.create が1回呼ばれている（次周期Issueが失われていない）」がこのテストの核心。
#   （createRecurIssueの呼び出し順をpostDoneProcessing側=close後に戻すとFAILする＝欠陥の回帰検知）
W1652_B1_LOG=$(mktemp /tmp/todo-test-1652-b1-XXXXXX)
W1652_B1_RESP='{"issues.get":[{"data":{"number":90101,"id":990101,"title":"Recur Task","body":"due: 2026-04-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.create":[{"data":{"number":90111}}],"issues.update":[{"__throw":true,"status":500,"message":"boom"}]}'
W1652_B1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1652_B1_RESP" OCTOKIT_STUB_LOG_ENV="$W1652_B1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run done 90101 2>&1); W1652_B1_EC=$?
assert_exit_fail "#1652-B1 runDone: close失敗 → exit 1" "$W1652_B1_EC"
assert_eq "#1652-B1 runDone: issues.create が1回呼ばれている（次周期Issueが失われていない＝create-before-closeの核心）" \
  "1" "$(log_count "$W1652_B1_LOG" issues.create)"
assert_eq "#1652-B1 runDone: issues.update（close試行）は1回" "1" "$(log_count "$W1652_B1_LOG" issues.update)"
assert_eq "#1652-B1 runDone: postDoneProcessing未到達のためissues.listForRepoは0回" "0" "$(log_count "$W1652_B1_LOG" issues.listForRepo)"
assert_contains "#1652-B1 runDone: エラーメッセージに元Issue番号(#90101)が含まれる" "#90101" "$W1652_B1_OUT"
assert_contains "#1652-B1 runDone: エラーメッセージに作成済み新Issue番号(#90111)が含まれる（副作用の可視化）" "#90111" "$W1652_B1_OUT"
assert_contains "#1652-B1 runDone: エラーメッセージに元のAPIエラー内容(boom)が含まれる" "boom" "$W1652_B1_OUT"
rm -f "$W1652_B1_LOG"

# #1652-B2: runDone — recurなし・close失敗のケース。newIssueNumberが無いので通常のエラーに
#   フォールバックし、close_failed_after_recur系のメッセージにはならないことを確認する
#   （newIssueNumber分岐の判定漏れ回帰検知）。
W1652_B2_LOG=$(mktemp /tmp/todo-test-1652-b2-XXXXXX)
W1652_B2_RESP='{"issues.get":[{"data":{"number":90102,"id":990102,"title":"No Recur Task","body":"","labels":[{"name":"🎯 next"}]}}],"issues.update":[{"__throw":true,"status":500,"message":"boom2"}]}'
W1652_B2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1652_B2_RESP" OCTOKIT_STUB_LOG_ENV="$W1652_B2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run done 90102 2>&1); W1652_B2_EC=$?
assert_exit_fail "#1652-B2 runDone: recurなし・close失敗 → exit 1" "$W1652_B2_EC"
assert_eq "#1652-B2 runDone: issues.create は呼ばれない（recurなし）" "0" "$(log_count "$W1652_B2_LOG" issues.create)"
assert_contains "#1652-B2 runDone: エラーメッセージに元のAPIエラー内容(boom2)が含まれる" "boom2" "$W1652_B2_OUT"
assert_not_contains "#1652-B2 runDone: newIssueNumberが無いので「作成済み」系メッセージは出ない" "は作成済みです" "$W1652_B2_OUT"
rm -f "$W1652_B2_LOG"

# #1652-B3: runBulk done — 複数Issueのうち1件（#90202）だけcloseが失敗するケース。
#   成功した#90201は通常どおり完了・recur再作成され、失敗した#90202は
#   per-item errorとして計上され、newIssueNumberがエラーメッセージに含まれる。
#   他のIssueの処理が巻き込まれて止まらないこと（bulk本来の独立処理保証）も確認する。
W1652_B3_LOG=$(mktemp /tmp/todo-test-1652-b3-XXXXXX)
W1652_B3_RESP='{"issues.get":[{"data":{"number":90201,"id":990201,"title":"Bulk Recur OK","body":"due: 2026-04-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}},{"data":{"number":90202,"id":990202,"title":"Bulk Recur Close Fail","body":"due: 2026-04-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.create":[{"data":{"number":90211}},{"data":{"number":90212}}],"issues.update":[{},{"__throw":true,"status":500,"message":"boom3"}],"issues.listForRepo":[{"data":[]}]}'
W1652_B3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1652_B3_RESP" OCTOKIT_STUB_LOG_ENV="$W1652_B3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run bulk done 90201 90202 2>&1); W1652_B3_EC=$?
assert_exit_ok "#1652-B3 runBulk done: bulk全体はexit 0（per-item errorのため）" "$W1652_B3_EC"
assert_contains "#1652-B3 runBulk done: サマリーが1件完了/1件エラー" "✅ 1件完了" "$W1652_B3_OUT"
assert_contains "#1652-B3 runBulk done: サマリーにエラー件数1件" "（エラー: 1件）" "$W1652_B3_OUT"
assert_contains "#1652-B3 runBulk done: #90201はrecur再作成メッセージが出る" "#90201: 繰り返しタスク #90211" "$W1652_B3_OUT"
assert_contains "#1652-B3 runBulk done: #90202のエラーに新Issue番号(#90212)が含まれる（副作用の可視化）" "#90212" "$W1652_B3_OUT"
assert_eq "#1652-B3 runBulk done: issues.create は2回（両方ともrecur再作成は実行される）" "2" "$(log_count "$W1652_B3_LOG" issues.create)"
assert_eq "#1652-B3 runBulk done: issues.listForRepo は1回（postDoneProcessing到達は#90201のみ）" "1" "$(log_count "$W1652_B3_LOG" issues.listForRepo)"
rm -f "$W1652_B3_LOG"

# #1652-B4: api done-issue — close失敗時、apiMain経由でも新Issue番号を含むエラーになること
#   （Web版done()経路。#1669のdone-issue専用サブコマンドの回帰確認を兼ねる）
W1652_B4_LOG=$(mktemp /tmp/todo-test-1652-b4-XXXXXX)
W1652_B4_RESP='{"issues.get":[{"data":{"number":90301,"id":990301,"title":"API Recur Task","body":"due: 2026-04-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.create":[{"data":{"number":90311}}],"issues.update":[{"__throw":true,"status":500,"message":"boom4"}]}'
W1652_B4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1652_B4_RESP" OCTOKIT_STUB_LOG_ENV="$W1652_B4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run api done-issue 90301 2>&1); W1652_B4_EC=$?
assert_exit_fail "#1652-B4 api done-issue: close失敗 → exit 1" "$W1652_B4_EC"
assert_eq "#1652-B4 api done-issue: issues.create が1回呼ばれている（次周期Issueが失われていない）" \
  "1" "$(log_count "$W1652_B4_LOG" issues.create)"
assert_contains "#1652-B4 api done-issue: エラーメッセージに作成済み新Issue番号(#90311)が含まれる" "#90311" "$W1652_B4_OUT"
rm -f "$W1652_B4_LOG"

# W16-21: runShow（plain出力、recur/project/tags/desc 全フィールド）
W16_21_ISSUE='{"number":22000,"title":"rich task","body":"due: 2026-05-01\nrecur: weekly\nproject: #999\nestimate: 90\nsome free-text description\n","labels":[{"name":"🎯 next"},{"name":"@home"},{"name":"#blog"},{"name":"p1"}],"state":"closed","closed_at":"2026-05-02T00:00:00Z"}'
run_stub_en "{\"issues.get\":[{\"data\":$W16_21_ISSUE}]}" show 22000
assert_exit_ok "W16-21 runShow(en, closed+recur+project+tags+desc): exit 0" "$LAST_EC"
assert_contains "W16-21 runShow(en): Status line" "- Status: ✅ Done" "$LAST_OUT"
assert_contains "W16-21 runShow(en): GTD Category line" "- GTD Category:" "$LAST_OUT"
assert_contains "W16-21 runShow(en): Recur line" "- Recur: weekly" "$LAST_OUT"
assert_contains "W16-21 runShow(en): Project line" "- Project: #999" "$LAST_OUT"
assert_contains "W16-21 runShow(en): Other Labels line" "- Other Labels: #blog" "$LAST_OUT"
assert_contains "W16-21 runShow(en): Description header" "### Description" "$LAST_OUT"
assert_no_japanese "W16-21 runShow(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-22: 未知のコマンド（実機確認 #1653 の再現）— exit 1・英語エラー・日本語混入なし
run_stub_en '{}' done-count
assert_exit_fail "W16-22 未知のコマンド(en): exit 1" "$LAST_EC"
assert_contains "W16-22 未知のコマンド(en): Unknown command" 'Unknown command "done-count"' "$LAST_OUT"
assert_no_japanese "W16-22 未知のコマンド(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-23: 予約語ガード（GTDキーワード + コマンド名のタイトル誤爆）
run_stub_en '{}' next list
assert_exit_fail "W16-23 予約語ガード(en): exit 1" "$LAST_EC"
assert_contains "W16-23 予約語ガード(en): is a command name" '"list" is a command name.' "$LAST_OUT"
assert_no_japanese "W16-23 予約語ガード(en): 出力に日本語が含まれない" "$LAST_OUT"

# W16-24: runSchema（--json 用スキーマ説明文の英語化）
SCHEMA_EN_OUT=$(LANG_ENV=en OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run schema 2>&1)
assert_contains "W16-24 runSchema(en): description が英語化されている" "Output schema for --json flagged commands" "$SCHEMA_EN_OUT"
assert_no_japanese "W16-24 runSchema(en): 出力に日本語が含まれない" "$SCHEMA_EN_OUT"

# ──────────────────────────────────────────
# §W17  activate のカレンダー妥当性チェック（Issue #1803）
# ──────────────────────────────────────────
# normalizeDue は正規化のみを行い実在性は判定しないため、activate 側は #1650 が due 側で
# 解消した「存在しない日付（2026-13-01等）が通ってしまう」欠陥が残っていた。
# runAdd（新規作成、add系）と runEdit（既存Issue編集、edit系）の2箇所の呼び出し経路を
# それぞれ検証する。
echo ""
echo "§W17  activate のカレンダー妥当性チェック（Issue #1803）"

# --- runAdd（add系）: 不正な activate は拒否され、issues.create は呼ばれないこと ---
# 優先度ラベルの ensureLabel（GET /repos/.../labels/{name}）は activate 検証より前に
# 実行される実装のため、GET は1回発生する想定でスタブ応答を用意する。

W17_ADD_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":17001,"html_url":"https://example.com/17001"}}]}'

W17_1_LOG=$(mktemp /tmp/todo-test-w17-1-XXXXXX)
W17_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_ADD_RESP" OCTOKIT_STUB_LOG_ENV="$W17_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run add next --activate 2026-13-01 Sample task title 2>&1); W17_1_EC=$?
assert_exit_fail "W17-1 runAdd 異常系(#1803): --activate 2026-13-01（存在しない月）→ exit 1" "$W17_1_EC"
assert_contains "W17-1 runAdd 異常系: エラーメッセージに元の入力値" "不正な日付形式です: 2026-13-01" "$W17_1_OUT"
assert_eq "W17-1 runAdd 異常系: issues.create は呼ばれない（副作用なし確認）" "0" "$(log_count "$W17_1_LOG" issues.create)"
rm -f "$W17_1_LOG"

W17_2_LOG=$(mktemp /tmp/todo-test-w17-2-XXXXXX)
W17_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_ADD_RESP" OCTOKIT_STUB_LOG_ENV="$W17_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run add next --activate 2026-02-30 Sample task title 2>&1); W17_2_EC=$?
assert_exit_fail "W17-2 runAdd 異常系(#1803): --activate 2026-02-30（2月に30日は存在しない）→ exit 1" "$W17_2_EC"
assert_contains "W17-2 runAdd 異常系: エラーメッセージに元の入力値" "不正な日付形式です: 2026-02-30" "$W17_2_OUT"
assert_eq "W17-2 runAdd 異常系: issues.create は呼ばれない" "0" "$(log_count "$W17_2_LOG" issues.create)"
rm -f "$W17_2_LOG"

W17_3_LOG=$(mktemp /tmp/todo-test-w17-3-XXXXXX)
W17_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_ADD_RESP" OCTOKIT_STUB_LOG_ENV="$W17_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run add next --activate 2026-02-29 Sample task title 2>&1); W17_3_EC=$?
assert_exit_fail "W17-3 runAdd 異常系(#1803): --activate 2026-02-29（非うるう年の2/29）→ exit 1" "$W17_3_EC"
assert_contains "W17-3 runAdd 異常系: エラーメッセージに元の入力値" "不正な日付形式です: 2026-02-29" "$W17_3_OUT"
assert_eq "W17-3 runAdd 異常系: issues.create は呼ばれない" "0" "$(log_count "$W17_3_LOG" issues.create)"
rm -f "$W17_3_LOG"

# W17-4 リグレッション: 正常な activate 指定は従来どおり通ること
W17_4_LOG=$(mktemp /tmp/todo-test-w17-4-XXXXXX)
W17_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_ADD_RESP" OCTOKIT_STUB_LOG_ENV="$W17_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run add next --activate 2026-09-01 Sample task title 2>&1); W17_4_EC=$?
assert_exit_ok "W17-4 runAdd リグレッション(#1803): --activate 2026-09-01（正常値）→ exit 0" "$W17_4_EC"
assert_contains "W17-4 runAdd リグレッション: 昇格予定表示" "昇格予定: 2026-09-01" "$W17_4_OUT"
assert_eq "W17-4 runAdd リグレッション: issues.create 呼び出し1回" "1" "$(log_count "$W17_4_LOG" issues.create)"
rm -f "$W17_4_LOG"

# W17-5 リグレッション: before 指定経由（addDays で計算）は due から導出されるため、
# カレンダー妥当性チェックの対象拡大による影響を受けないこと（#1803 本文の懸念点の確認）。
# 既存の W4-1（run add next @office '#urgent' --p1 --due 2026-04-10 --before 3d ...）で
# 「昇格予定: 2026-04-07」が exit 0 で得られることを既に確認済みだが、本セクションでも
# 月末を跨ぐケースで明示的に再確認する。
W17_5_LOG=$(mktemp /tmp/todo-test-w17-5-XXXXXX)
W17_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_ADD_RESP" OCTOKIT_STUB_LOG_ENV="$W17_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2028-02-20 \
  node "$ENGINE" run add next --due 2028-03-01 --before 5d Sample task title 2>&1); W17_5_EC=$?
assert_exit_ok "W17-5 runAdd リグレッション(#1803): --before 経由の activate は影響を受けない → exit 0" "$W17_5_EC"
assert_contains "W17-5 runAdd リグレッション: before から逆算した昇格予定日" "昇格予定: 2028-02-25" "$W17_5_OUT"
rm -f "$W17_5_LOG"

# --- runEdit（edit系）: 不正な activate は拒否され、issues.update は呼ばれないこと ---
W17_EDIT_ISSUE='{"number":17101,"id":9917101,"title":"Existing task","body":"","labels":[{"name":"🎯 next"}]}'
W17_EDIT_RESP="{\"issues.get\":[{\"data\":$W17_EDIT_ISSUE}]}"

W17_6_LOG=$(mktemp /tmp/todo-test-w17-6-XXXXXX)
W17_6_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_EDIT_RESP" OCTOKIT_STUB_LOG_ENV="$W17_6_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run edit 17101 --activate 2026-13-01 2>&1); W17_6_EC=$?
assert_exit_fail "W17-6 runEdit 異常系(#1803): --activate 2026-13-01（存在しない月）→ exit 1" "$W17_6_EC"
assert_contains "W17-6 runEdit 異常系: エラーメッセージに元の入力値" "不正な日付形式です: 2026-13-01" "$W17_6_OUT"
assert_eq "W17-6 runEdit 異常系: issues.get のみ実行（1回）" "1" "$(log_count "$W17_6_LOG" issues.get)"
assert_eq "W17-6 runEdit 異常系: issues.update は呼ばれない（副作用なし確認）" "0" "$(log_count "$W17_6_LOG" issues.update)"
rm -f "$W17_6_LOG"

W17_7_LOG=$(mktemp /tmp/todo-test-w17-7-XXXXXX)
W17_7_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_EDIT_RESP" OCTOKIT_STUB_LOG_ENV="$W17_7_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run edit 17101 --activate 2026-02-30 2>&1); W17_7_EC=$?
assert_exit_fail "W17-7 runEdit 異常系(#1803): --activate 2026-02-30（2月に30日は存在しない）→ exit 1" "$W17_7_EC"
assert_eq "W17-7 runEdit 異常系: issues.update は呼ばれない" "0" "$(log_count "$W17_7_LOG" issues.update)"
rm -f "$W17_7_LOG"

W17_8_LOG=$(mktemp /tmp/todo-test-w17-8-XXXXXX)
W17_8_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_EDIT_RESP" OCTOKIT_STUB_LOG_ENV="$W17_8_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run edit 17101 --activate 2026-02-29 2>&1); W17_8_EC=$?
assert_exit_fail "W17-8 runEdit 異常系(#1803): --activate 2026-02-29（非うるう年の2/29）→ exit 1" "$W17_8_EC"
assert_eq "W17-8 runEdit 異常系: issues.update は呼ばれない" "0" "$(log_count "$W17_8_LOG" issues.update)"
rm -f "$W17_8_LOG"

# W17-9 リグレッション: runEdit で正常な activate 指定は従来どおり通ること
W17_9_RESP="{\"issues.get\":[{\"data\":$W17_EDIT_ISSUE}],\"issues.update\":[{}]}"
W17_9_LOG=$(mktemp /tmp/todo-test-w17-9-XXXXXX)
W17_9_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W17_9_RESP" OCTOKIT_STUB_LOG_ENV="$W17_9_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-11 \
  node "$ENGINE" run edit 17101 --activate 2026-09-01 2>&1); W17_9_EC=$?
assert_exit_ok "W17-9 runEdit リグレッション(#1803): --activate 2026-09-01（正常値）→ exit 0" "$W17_9_EC"
assert_contains "W17-9 runEdit リグレッション: 変更内容メッセージ" "activate → 2026-09-01" "$W17_9_OUT"
assert_eq "W17-9 runEdit リグレッション: issues.update 呼び出し1回" "1" "$(log_count "$W17_9_LOG" issues.update)"
rm -f "$W17_9_LOG"

# ──────────────────────────────────────────
# §W18  weekly-project-audit / list project が someday 併記の project を
# 「休止中」として除外する（Issue #1846）
#
# 背景: execMoveGtd（GTD_LABELS に project を含まない）は project ラベルを
# 剥がさない設計のため、`move <n> someday` された project は
# 「📁 project, 🌈 someday」の二重ラベルのまま残る。これを weekly-project-audit /
# list project の消費側で「休止中」として除外する（move 側の挙動は変更しない）。
# ──────────────────────────────────────────
echo ""
echo "§W18  weekly-project-audit / list project の someday 併記 project 除外（Issue #1846）"

# 共通データ: project A（休止していないアクティブなプロジェクト、next子タスクあり）
#           + project B（📁 project と 🌈 someday を併せ持つ「休止中」プロジェクト）
W1846_LIST='[
  {"number":30101,"title":"Active Project","updated_at":"2026-04-01T00:00:00Z","body":"","labels":[{"name":"📁 project"}]},
  {"number":30102,"title":"Active Project Next Child","updated_at":"2026-04-01T00:00:00Z","body":"project: #30101\n","labels":[{"name":"🎯 next"}]},
  {"number":30103,"title":"Paused Project","updated_at":"2026-04-01T00:00:00Z","body":"","labels":[{"name":"📁 project"},{"name":"🌈 someday"}]}
]'

# W18-1: weekly-project-audit → 休止中(someday併記)projectは走査対象から除外され、
# 除外件数が利用者に見える形で明示される
W1846_1_LOG=$(mktemp /tmp/todo-test-w1846-1-XXXXXX)
W1846_1_RESP="{\"issues.listForRepo\":[{\"data\":$W1846_LIST}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[]}]}"
W1846_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1846_1_RESP" OCTOKIT_STUB_LOG_ENV="$W1846_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run weekly-project-audit 2>&1); W1846_1_EC=$?
assert_exit_ok "W18-1 weekly-project-audit(#1846): exit 0" "$W1846_1_EC"
assert_contains "W18-1: ヘッダが休止中を除いた件数(全1件)になる" "全1件" "$W1846_1_OUT"
assert_contains "W18-1: 除外件数が明示される（休止中1件を除外）" "休止中（someday）のプロジェクト 1件を除外" "$W1846_1_OUT"
assert_contains "W18-1: アクティブな project #30101 は列挙される" "#30101" "$W1846_1_OUT"
assert_not_contains "W18-1: 休止中の project #30103 は列挙されない" "#30103" "$W1846_1_OUT"
assert_not_contains "W18-1: 休止中の project タイトルは出力に含まれない" "Paused Project" "$W1846_1_OUT"
assert_eq "W18-1: 休止中projectには sub_issues API が呼ばれない（走査対象外の確認）" "1" "$(log_count "$W1846_1_LOG" "GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues")"
rm -f "$W1846_1_LOG"

# W18-2: list project（フィルタのみ、番号なし）→ 休止中projectが除外され、除外件数が明示される
W1846_2_LOG=$(mktemp /tmp/todo-test-w1846-2-XXXXXX)
W1846_2_RESP="{\"issues.listForRepo\":[{\"data\":$W1846_LIST}]}"
W1846_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1846_2_RESP" OCTOKIT_STUB_LOG_ENV="$W1846_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run list project 2>&1); W1846_2_EC=$?
assert_exit_ok "W18-2 list project(#1846): exit 0" "$W1846_2_EC"
assert_contains "W18-2: アクティブな project #30101 は列挙される" "#30101" "$W1846_2_OUT"
assert_not_contains "W18-2: 休止中の project #30103 は列挙されない" "#30103" "$W1846_2_OUT"
assert_not_contains "W18-2: 休止中の project タイトルは出力に含まれない" "Paused Project" "$W1846_2_OUT"
assert_contains "W18-2: 除外件数が明示される（休止中1件を除外）" "休止中（someday）のプロジェクト 1件を除外" "$W1846_2_OUT"
rm -f "$W1846_2_LOG"

# W18-3 リグレッション: list someday（通常のsomeday一覧）は従来どおり
# project併記かどうかに関わらず someday タスクをすべて列挙する（除外対象外の確認）
W1846_3_LOG=$(mktemp /tmp/todo-test-w1846-3-XXXXXX)
W1846_3_RESP="{\"issues.listForRepo\":[{\"data\":$W1846_LIST}]}"
W1846_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1846_3_RESP" OCTOKIT_STUB_LOG_ENV="$W1846_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run list someday 2>&1); W1846_3_EC=$?
assert_exit_ok "W18-3 list someday リグレッション(#1846): exit 0" "$W1846_3_EC"
assert_contains "W18-3: someday併記の project #30103 は list someday には引き続き出る" "#30103" "$W1846_3_OUT"
assert_not_contains "W18-3: list someday には除外メッセージは出ない（project専用の挙動）" "を除外" "$W1846_3_OUT"
rm -f "$W1846_3_LOG"

# W18-4: プレーンな /todo list（フィルタなし全体一覧）の Projects セクションも
# 休止中(someday併記)projectを除外し、件数を明示する（フォローアップ: #1846 スコープ拡張）
# renderIssueList のsomedayマーカー（'  ⚠️'+line.slice(2)）により、Projects セクションの
# 行フォーマット「  #番号  タイトル」（⚠️を挟まない）と someday セクションの行フォーマット
# 「  ⚠️#番号  タイトル」（⚠️を挟む）は区別できるため、not_containsで厳密に判定する。
W1846_4_LOG=$(mktemp /tmp/todo-test-w1846-4-XXXXXX)
W1846_4_RESP="{\"issues.listForRepo\":[{\"data\":$W1846_LIST}]}"
W1846_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1846_4_RESP" OCTOKIT_STUB_LOG_ENV="$W1846_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run list 2>&1); W1846_4_EC=$?
assert_exit_ok "W18-4 プレーンlist(#1846): exit 0" "$W1846_4_EC"
assert_contains "W18-4: Projectsセクションのヘッダが休止中を除いた件数(1件)になる" "📁 Projects（1件）" "$W1846_4_OUT"
assert_contains "W18-4: Projectsセクションに除外件数が明示される" "休止中（someday）のプロジェクト 1件を除外" "$W1846_4_OUT"
assert_contains "W18-4: アクティブな project #30101 はProjectsセクションに列挙される" "#30101  Active Project" "$W1846_4_OUT"
assert_not_contains "W18-4: 休止中の project #30103 はProjectsセクションの行フォーマットでは出ない（⚠️を挟まない形）" "  #30103  Paused Project" "$W1846_4_OUT"
assert_contains "W18-4: 休止中の project #30103 はsomedayセクションには引き続き出る（⚠️を挟む形）" "⚠️#30103  Paused Project" "$W1846_4_OUT"
assert_contains "W18-4: フッターサマリーのproject件数もProjectsセクションと一致する(project: 1件)" "project: 1件" "$W1846_4_OUT"
rm -f "$W1846_4_LOG"

# W18-5: list project --json は除外せず全件返す（設計判断のロックイン）。
# 休止中判定は各要素の labels フィールドに project と someday が両方含まれることで
# 消費側が行える設計のため、新規フィールドは追加しない。既存消費者不在を確認済み
# （関連リポジトリをgrepしても該当なし）。
W1846_5_LOG=$(mktemp /tmp/todo-test-w1846-5-XXXXXX)
W1846_5_LIST='[
  {"number":30101,"title":"Active Project","updated_at":"2026-04-01T00:00:00Z","body":"","labels":[{"name":"📁 project"}]},
  {"number":30103,"title":"Paused Project","updated_at":"2026-04-01T00:00:00Z","body":"","labels":[{"name":"📁 project"},{"name":"🌈 someday"}]}
]'
W1846_5_RESP="{\"issues.listForRepo\":[{\"data\":$W1846_5_LIST}]}"
W1846_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1846_5_RESP" OCTOKIT_STUB_LOG_ENV="$W1846_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run list project --json 2>&1); W1846_5_EC=$?
assert_exit_ok "W18-5 list project --json(#1846): exit 0" "$W1846_5_EC"
assert_contains "W18-5: アクティブなproject #30101 がJSONに含まれる" '"number": 30101' "$W1846_5_OUT"
assert_contains "W18-5: 休止中のproject #30103 も除外されずJSONに含まれる（設計判断: 全件返す）" '"number": 30103' "$W1846_5_OUT"
assert_contains "W18-5: 休止中projectのlabelsにproject/somedayが両方含まれる（消費側が判定できる）" '"project",' "$W1846_5_OUT"
rm -f "$W1846_5_LOG"

# ──────────────────────────────────────────
# §W19 estimate 時間単位表示の --json 出力（Issue #1854）
# 修正前は formatTime(parseInt(estimate)) だったため、"2h" が「2」に切り詰められ
# estimateFormatted が誤った値（"2m"）になっていた。--json は list-all の OPEN_ENV 経路とは別に
# octokit 経由（issueToJsonObj / runShow の jsonMode 分岐）で estimateFormatted を算出するため、
# 別途 octokit スタブでの検証が必要。
# ──────────────────────────────────────────

# W19-1: run list --json（issueToJsonObj 経由）
W1854_1_LOG=$(mktemp /tmp/todo-test-w1854-1-XXXXXX)
W1854_1_LIST='[
  {"number":40101,"title":"est-2h","updated_at":"2026-04-01T00:00:00Z","body":"estimate: 2h","labels":[{"name":"🎯 next"}]},
  {"number":40102,"title":"est-1h30m","updated_at":"2026-04-01T00:00:00Z","body":"estimate: 1h30m","labels":[{"name":"🎯 next"}]},
  {"number":40103,"title":"est-60","updated_at":"2026-04-01T00:00:00Z","body":"estimate: 60","labels":[{"name":"🎯 next"}]},
  {"number":40104,"title":"est-invalid","updated_at":"2026-04-01T00:00:00Z","body":"estimate: abc","labels":[{"name":"🎯 next"}]}
]'
W1854_1_RESP="{\"issues.listForRepo\":[{\"data\":$W1854_1_LIST}]}"
W1854_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1854_1_RESP" OCTOKIT_STUB_LOG_ENV="$W1854_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run list next --json 2>&1); W1854_1_EC=$?
assert_exit_ok "W19-1 list next --json(#1854): exit 0" "$W1854_1_EC"
assert_contains "W19-1: estimate:2h の estimateFormatted は 2h（従来は2mだった）" '"estimateFormatted": "2h"' "$W1854_1_OUT"
assert_contains "W19-1: estimate:1h30m の estimateFormatted は 1h30m" '"estimateFormatted": "1h30m"' "$W1854_1_OUT"
assert_contains "W19-1: estimate:60（数値のみ）の estimateFormatted は 1h" '"estimateFormatted": "1h"' "$W1854_1_OUT"
assert_contains "W19-1: estimate:abc（不正値）の estimate 生値は保持される" '"estimate": "abc"' "$W1854_1_OUT"
assert_contains "W19-1: estimate:abc（不正値）の estimateFormatted は null（0mと黙って出さない）" '"estimateFormatted": null' "$W1854_1_OUT"
rm -f "$W1854_1_LOG"

# W19-2: run show <#> --json（runShow の jsonMode 分岐経由。issueToJsonObj とは別のコードパス）
W1854_2_LOG=$(mktemp /tmp/todo-test-w1854-2-XXXXXX)
W1854_2_RESP='{"issues.get":[{"data":{"number":40201,"id":940201,"title":"est-2h-show","body":"estimate: 2h","labels":[{"name":"🎯 next"}]}}]}'
W1854_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1854_2_RESP" OCTOKIT_STUB_LOG_ENV="$W1854_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run show 40201 --json 2>&1); W1854_2_EC=$?
assert_exit_ok "W19-2 show --json(#1854): exit 0" "$W1854_2_EC"
assert_contains "W19-2: show --json estimate:2h の estimateFormatted は 2h（従来は2mだった）" '"estimateFormatted": "2h"' "$W1854_2_OUT"
rm -f "$W1854_2_LOG"

# W19-3: run show <#>（非json）の見積もり表示。不正値は「（形式不正）」を添えて表示する
W1854_3_LOG=$(mktemp /tmp/todo-test-w1854-3-XXXXXX)
W1854_3_RESP='{"issues.get":[{"data":{"number":40301,"id":940301,"title":"est-invalid-show","body":"estimate: abc","labels":[{"name":"🎯 next"}]}}]}'
W1854_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1854_3_RESP" OCTOKIT_STUB_LOG_ENV="$W1854_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run show 40301 2>&1); W1854_3_EC=$?
assert_exit_ok "W19-3 show（非json）(#1854): exit 0" "$W1854_3_EC"
assert_contains "W19-3: show（非json）estimate:abc（不正値）は「形式不正」表示になる" "abc" "$W1854_3_OUT"
assert_not_contains "W19-3: show（非json）estimate:abc（不正値）は 0m と黙って表示されない" "0m" "$W1854_3_OUT"
rm -f "$W1854_3_LOG"

# ──────────────────────────────────────────
# §W22  runUnlink — sub-issue 解除失敗/食い違い時に body を消さない（Issue #1880）
# 実事故: body が project: #1640 を指す Issue で unlink を実行したところ、実際の
# GitHub 上の親は #1133 で DELETE が Not Found を返したが、body の project 行だけが
# 削除され、GitHub 上の親子関係は残ったまま紐付け情報だけが消えた（復旧済み）。
# 核心アサーションは W22-2（DELETE失敗時に issues.update が呼ばれないこと）。
# ──────────────────────────────────────────
echo ""
echo "§W22  runUnlink — sub-issue 解除失敗/食い違い時に body を消さない（Issue #1880）"

# W22-1 正常系（リグレッション）: body の親と GitHub 上の親が一致 → DELETE成功 → body更新
W1880_1_LOG=$(mktemp /tmp/todo-test-w1880-1-XXXXXX)
W1880_1_ISSUE='{"number":8701,"id":988701,"body":"project: #8700\n","labels":[]}'
W1880_1_RESP="{\"issues.get\":[{\"data\":$W1880_1_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[{\"id\":988701}]}],\"DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue\":[{}],\"issues.update\":[{}]}"
W1880_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1880_1_RESP" OCTOKIT_STUB_LOG_ENV="$W1880_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run unlink 8701 2>&1); W1880_1_EC=$?
assert_exit_ok "W22-1 正常系(リグレッション): exit 0" "$W1880_1_EC"
assert_contains "W22-1: 成功メッセージが出る" "✅ #8701 のプロジェクト紐付けを解除しました。" "$W1880_1_OUT"
assert_eq "W22-1: 事前確認(GET sub_issues)が1回呼ばれる" "1" "$(log_count "$W1880_1_LOG" "GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues")"
assert_eq "W22-1: DELETE sub_issue が1回呼ばれる" "1" "$(log_count "$W1880_1_LOG" "DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue")"
assert_eq "W22-1: issues.update が1回呼ばれる（body更新）" "1" "$(log_count "$W1880_1_LOG" issues.update)"
assert_not_contains "W22-1: issues.update の body に project: 行が残っていない" "project: #8700" "$(log_lines_for_method "$W1880_1_LOG" issues.update)"
rm -f "$W1880_1_LOG"

# W22-2 【核心】DELETE失敗（Not Found、実事故の再現）: body を更新してはいけない
W1880_2_LOG=$(mktemp /tmp/todo-test-w1880-2-XXXXXX)
W1880_2_ISSUE='{"number":8702,"id":988702,"body":"project: #8700\n","labels":[]}'
W1880_2_RESP="{\"issues.get\":[{\"data\":$W1880_2_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[{\"id\":988702}]}],\"DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue\":[{\"__throw\":true,\"status\":404,\"message\":\"Not Found - https://docs.github.com/rest/issues/sub-issues#remove-sub-issue\"}]}"
W1880_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1880_2_RESP" OCTOKIT_STUB_LOG_ENV="$W1880_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run unlink 8702 2>&1); W1880_2_EC=$?
assert_exit_fail "W22-2 DELETE失敗: exit非0" "$W1880_2_EC"
assert_contains "W22-2: sub-issue解除失敗の警告が出る" "sub-issue 解除失敗" "$W1880_2_OUT"
assert_contains "W22-2: bodyを更新していない旨のエラーが出る" "body は更新していません" "$W1880_2_OUT"
assert_not_contains "W22-2: 誤って成功メッセージを出していない" "プロジェクト紐付けを解除しました" "$W1880_2_OUT"
assert_eq "W22-2 【核心】DELETE失敗時に issues.update が呼ばれない（データ喪失防止の本体）" "0" "$(log_count "$W1880_2_LOG" issues.update)"
rm -f "$W1880_2_LOG"

# W22-3 body の親とGitHub上の親が食い違う（--forceなし）: 黙ってbodyを消さずエラー終了する
W1880_3_LOG=$(mktemp /tmp/todo-test-w1880-3-XXXXXX)
W1880_3_ISSUE='{"number":8703,"id":988703,"body":"project: #8700\n","labels":[]}'
W1880_3_RESP="{\"issues.get\":[{\"data\":$W1880_3_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[]}]}"
W1880_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1880_3_RESP" OCTOKIT_STUB_LOG_ENV="$W1880_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run unlink 8703 2>&1); W1880_3_EC=$?
assert_exit_fail "W22-3 親の食い違い(--forceなし): exit非0" "$W1880_3_EC"
assert_contains "W22-3: 食い違いエラーに --force の案内が含まれる" "--force を実行してください" "$W1880_3_OUT"
assert_eq "W22-3: 登録されていない親へのDELETEは試みない" "0" "$(log_count "$W1880_3_LOG" "DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue")"
assert_eq "W22-3: issues.update が呼ばれない（bodyは無傷）" "0" "$(log_count "$W1880_3_LOG" issues.update)"
rm -f "$W1880_3_LOG"

# W22-4 body の親とGitHub上の親が食い違う（--force指定）: body のみ明示的に解除する
W1880_4_LOG=$(mktemp /tmp/todo-test-w1880-4-XXXXXX)
W1880_4_ISSUE='{"number":8704,"id":988704,"body":"project: #8700\n","labels":[]}'
W1880_4_RESP="{\"issues.get\":[{\"data\":$W1880_4_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[]}],\"issues.update\":[{}]}"
W1880_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1880_4_RESP" OCTOKIT_STUB_LOG_ENV="$W1880_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run unlink 8704 --force 2>&1); W1880_4_EC=$?
assert_exit_ok "W22-4 親の食い違い(--force指定): exit 0" "$W1880_4_EC"
assert_contains "W22-4: body のみ解除した旨のメッセージが出る" "プロジェクト紐付け（body）のみ解除しました" "$W1880_4_OUT"
assert_eq "W22-4: 登録されていない親へのDELETEは試みない" "0" "$(log_count "$W1880_4_LOG" "DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue")"
assert_eq "W22-4: issues.update が1回呼ばれる（body のみ更新）" "1" "$(log_count "$W1880_4_LOG" issues.update)"
rm -f "$W1880_4_LOG"

# ──────────────────────────────────────────
# §W23  listSubIssues のページング対応（Issue #1881）
# 前提: GitHub の sub-issue は現行仕様で「親1つにつき最大100件」（公式ドキュメント
# "Adding sub-issues"、2026-08-23 確認）。したがって per_page:100 の単発リクエストでも
# 実際には全件取得できており、本番で欠落は起きていなかった。本節は「上限が将来
# 引き上げられても黙って欠落しない」ことを保証する防御的テストである。
# 仮に欠落した場合、addSubIssueの422判別（本節の核心）に加え、
# list project・weekly-project-audit・unlinkの計4箇所が影響を受ける
# （呼び出し元の一覧はコード側コメント参照）。
# 以下は「意図的破壊」で有効性を検証済み（完了報告に破壊時の FAIL 結果を記載）。
# ──────────────────────────────────────────
echo ""
echo "§W23  listSubIssues のページング対応（Issue #1881）"

# W23-1 【核心】101件超の親: 2ページ目にいる子も addSubIssue の422判別で「既登録」と
# 正しく判定されること（ページング未対応だとpage1にいない子は誤って error 計上される）
W1881_1_CHILD='{"number":41901,"id":941901,"title":"child","body":"project: #41902\n","labels":[]}'
W1881_1_PARENT='{"number":41902,"labels":[{"name":"📁 project"}]}'
# page1: 100件（対象の子は含まない）／page2: 1件（対象の子のみ、<100件で打ち切り）
W1881_1_PAGE1=$(node -e "const a=[]; for(let i=0;i<100;i++) a.push({id:800000+i,number:800000+i}); process.stdout.write(JSON.stringify(a));")
W1881_1_PAGE2='[{"id":941901,"number":41901}]'
W1881_1_LOG=$(mktemp /tmp/todo-test-1881-1-XXXXXX)
: > "$W1881_1_LOG"
W1881_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W1881_1_LOG" \
  OCTOKIT_STUB_RESPONSES_ENV="{\"issues.listForRepo\":[{\"data\":[$W1881_1_CHILD]}],\"issues.get\":[{\"data\":$W1881_1_PARENT}],\"POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"__throw\":true,\"status\":422,\"message\":\"Validation Failed: sub_issue_id already assigned to a parent\"}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":$W1881_1_PAGE1},{\"data\":$W1881_1_PAGE2}]}" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run migrate sub-issue 2>&1); W1881_1_EC=$?
assert_exit_ok "W23-1 migrate 本実行(101件超・2ページ目に既登録): exit 0" "$W1881_1_EC"
assert_contains "W23-1 【核心】2ページ目にいる子を既登録と正しく判定してスキップ計上" \
  "✅ migrate sub-issue 完了: 0件登録 / 1件スキップ / 0件エラー" "$W1881_1_OUT"
assert_eq "W23-1: GET sub_issues が2回呼ばれる（2ページ分取得）" "2" "$(log_count "$W1881_1_LOG" "GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues")"
rm -f "$W1881_1_LOG"

# W23-2 リグレッション: 1ページに収まる既存ケース（子2件）は従来どおりGET1回のみで完結する
W1881_2_CHILD='{"number":41903,"id":941903,"title":"child2","body":"project: #41904\n","labels":[]}'
W1881_2_PARENT='{"number":41904,"labels":[{"name":"📁 project"}]}'
W1881_2_EXISTING='[{"id":941903,"number":41903},{"id":941999,"number":41999}]'
W1881_2_LOG=$(mktemp /tmp/todo-test-1881-2-XXXXXX)
: > "$W1881_2_LOG"
W1881_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W1881_2_LOG" \
  OCTOKIT_STUB_RESPONSES_ENV="{\"issues.listForRepo\":[{\"data\":[$W1881_2_CHILD]}],\"issues.get\":[{\"data\":$W1881_2_PARENT}],\"POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"__throw\":true,\"status\":422,\"message\":\"Validation Failed: sub_issue_id already assigned to a parent\"}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":$W1881_2_EXISTING}]}" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run migrate sub-issue 2>&1); W1881_2_EC=$?
assert_exit_ok "W23-2 リグレッション(1ページ収まる・422既登録): exit 0" "$W1881_2_EC"
assert_contains "W23-2: 従来どおり既登録スキップと判定される" \
  "✅ migrate sub-issue 完了: 0件登録 / 1件スキップ / 0件エラー" "$W1881_2_OUT"
assert_eq "W23-2: GET sub_issues は1回のみ（余分なページ取得をしない）" "1" "$(log_count "$W1881_2_LOG" "GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues")"
rm -f "$W1881_2_LOG"

# W23-3 上限ガード: sub-issue が MAX_SUB_ISSUES_LIMIT（500件）ちょうどに達した場合、
# 一部欠落の可能性がある旨の警告を出す（list project 経由・POST不要で検証）
W1881_3_PAGE=$(node -e "const a=[]; for(let i=0;i<100;i++) a.push({id:900000+i,number:900000+i}); process.stdout.write(JSON.stringify(a));")
W1881_3_LOG=$(mktemp /tmp/todo-test-1881-3-XXXXXX)
: > "$W1881_3_LOG"
W1881_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W1881_3_LOG" \
  OCTOKIT_STUB_RESPONSES_ENV="{\"issues.listForRepo\":[{\"data\":[]}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":$W1881_3_PAGE},{\"data\":$W1881_3_PAGE},{\"data\":$W1881_3_PAGE},{\"data\":$W1881_3_PAGE},{\"data\":$W1881_3_PAGE}]}" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run list project 41905 2>&1); W1881_3_EC=$?
assert_exit_ok "W23-3 上限到達(500件ちょうど): exit 0" "$W1881_3_EC"
assert_contains "W23-3: 上限到達の警告が出る" "sub-issue が 500 件の上限に達しました" "$W1881_3_OUT"
assert_eq "W23-3: GET sub_issues が5回呼ばれる（500件=5ページ分取得して打ち切り）" "5" "$(log_count "$W1881_3_LOG" "GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues")"
rm -f "$W1881_3_LOG"

# ──────────────────────────────────────────
# §W24  runUnlink — sub-issue 一覧の GET 失敗時は --force の有無に関わらず
# body を更新しない（Issue #1885）
# 背景: listSubIssues() は GET 失敗を catch して[]を返す仕様のため、runUnlink が
# 素直に呼ぶと「取得失敗」と「本当に子0件（=未登録）」を区別できない。区別を誤ると
# --force 指定時に removeSubIssue を呼ばないまま body の project: 行だけ削除してしまい、
# 実際には残っている親子関係が「解除済み」と誤記される（#1880 が修正したデータ喪失と
# 同じ結果）。#1885 で listSubIssues に { throwOnError: true } を追加し、runUnlink は
# GET 失敗時に例外を捕捉して body を一切更新せず終了するよう変更した。
# 核心アサーションは W24-1（GET失敗時に issues.update が呼ばれないこと）。
# ──────────────────────────────────────────
echo ""
echo "§W24  runUnlink — sub-issue 一覧のGET失敗時はbodyを更新しない（Issue #1885）"

# W24-1 【核心】GET sub_issues 失敗 + --force指定: 取得失敗と「本当に未登録」を混同せず、
# body を一切更新しない（issues.update が呼ばれない）
W1885_1_LOG=$(mktemp /tmp/todo-test-1885-1-XXXXXX)
W1885_1_ISSUE='{"number":8705,"id":988705,"body":"project: #8700\n","labels":[]}'
W1885_1_RESP="{\"issues.get\":[{\"data\":$W1885_1_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"__throw\":true,\"status\":500,\"message\":\"Internal Server Error\"}]}"
W1885_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1885_1_RESP" OCTOKIT_STUB_LOG_ENV="$W1885_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run unlink 8705 --force 2>&1); W1885_1_EC=$?
assert_exit_fail "W24-1 GET失敗(--force指定): exit非0" "$W1885_1_EC"
assert_contains "W24-1: sub-issue一覧取得失敗の警告が出る" "sub-issue 一覧取得失敗" "$W1885_1_OUT"
assert_contains "W24-1: bodyを更新していない旨のエラーが出る" "body は更新していません" "$W1885_1_OUT"
assert_not_contains "W24-1: 誤って成功メッセージを出していない" "プロジェクト紐付け" "$W1885_1_OUT"
assert_eq "W24-1: DELETE sub_issue は試みない" "0" "$(log_count "$W1885_1_LOG" "DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue")"
assert_eq "W24-1 【核心】GET失敗時に issues.update が呼ばれない（--force指定でもbodyだけ消えるデータ喪失を防止）" "0" "$(log_count "$W1885_1_LOG" issues.update)"
rm -f "$W1885_1_LOG"

# W24-2 GET sub_issues 失敗 + --force なし: 従来どおりエラー終了し body は無傷
# （この経路は#1885以前から「安全側」だったが、GET失敗経路として明示的にリグレッション確認する）
W1885_2_LOG=$(mktemp /tmp/todo-test-1885-2-XXXXXX)
W1885_2_ISSUE='{"number":8706,"id":988706,"body":"project: #8700\n","labels":[]}'
W1885_2_RESP="{\"issues.get\":[{\"data\":$W1885_2_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"__throw\":true,\"status\":500,\"message\":\"Internal Server Error\"}]}"
W1885_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1885_2_RESP" OCTOKIT_STUB_LOG_ENV="$W1885_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run unlink 8706 2>&1); W1885_2_EC=$?
assert_exit_fail "W24-2 GET失敗(--forceなし): exit非0" "$W1885_2_EC"
assert_contains "W24-2: bodyを更新していない旨のエラーが出る" "body は更新していません" "$W1885_2_OUT"
assert_eq "W24-2: issues.update が呼ばれない" "0" "$(log_count "$W1885_2_LOG" issues.update)"
rm -f "$W1885_2_LOG"

# W24-3 リグレッション: W22-4相当（GET成功・子0件・--force指定）は従来どおり
# body のみ解除される（GET失敗との混同がないことの対照ケース）
W1885_3_LOG=$(mktemp /tmp/todo-test-1885-3-XXXXXX)
W1885_3_ISSUE='{"number":8707,"id":988707,"body":"project: #8700\n","labels":[]}'
W1885_3_RESP="{\"issues.get\":[{\"data\":$W1885_3_ISSUE}],\"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues\":[{\"data\":[]}],\"issues.update\":[{}]}"
W1885_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W1885_3_RESP" OCTOKIT_STUB_LOG_ENV="$W1885_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run unlink 8707 --force 2>&1); W1885_3_EC=$?
assert_exit_ok "W24-3 リグレッション: GET成功・子0件・--force指定はexit 0" "$W1885_3_EC"
assert_contains "W24-3: body のみ解除した旨のメッセージが出る" "プロジェクト紐付け（body）のみ解除しました" "$W1885_3_OUT"
assert_eq "W24-3: issues.update が1回呼ばれる（body のみ更新、GET成功時は従来動作を維持）" "1" "$(log_count "$W1885_3_LOG" issues.update)"
rm -f "$W1885_3_LOG"

# ──────────────────────────────────────────
# §W25  /todo コマンド実行時間計測（TODO_TIMING、Issue #455）
# 純粋関数（computeGithubMs）の単体テストは run-tests.sh §50 参照。
# こちらは Octokit スタブ経由の統合的な振る舞いを検証する。
# ──────────────────────────────────────────
echo ""
echo "§W25  TODO_TIMING 実行時間計測 — スタブベース振る舞いテスト（Issue #455）"

TIMING_LINE_RE='\[timing\] total [0-9]+ms \(github [0-9]+ms / parse [0-9]+ms\)'

# W25-1 基本フォーマット確認 + github<=total（逐次1回呼び出し: run list next → fetchAllOpen 1回）
W25_1_ERR=$(mktemp /tmp/todo-test-1455-1-err-XXXXXX)
W25_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV='{"issues.listForRepo":[{"data":[]}]}' \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" run list next 2>"$W25_1_ERR"); W25_1_EC=$?
W25_1_ERRTEXT=$(cat "$W25_1_ERR" 2>/dev/null); rm -f "$W25_1_ERR"
assert_exit_ok "W25-1 run list next + TODO_TIMING=1: exit 0" "$W25_1_EC"
assert_regex "W25-1: stderrに [timing] 行が正しいフォーマットで出力される" "$TIMING_LINE_RE" "$W25_1_ERRTEXT"
W25_1_TOTAL=$(extract_timing_field "$W25_1_ERRTEXT" total)
W25_1_GITHUB=$(extract_timing_field "$W25_1_ERRTEXT" github)
assert_le "W25-1: github <= total（区間統合の不変条件）" "$W25_1_GITHUB" "$W25_1_TOTAL"

# W25-2 並行呼び出し（Promise.all）での区間統合ロジック検証: run today は
# fetchAllOpen/fetchRecentClosed の2回の issues.listForRepo を並行実行する。
# スタブに __delayMs:60 を仕込み、単純合計（約120ms）ではなく実際の壁時計時間
# （並行実行のため約60〜80ms）に近い値になることを確認する（Issue #455 設計書の
# 自己申告リスク「区間統合と単純合計の区別力が低い」への対処: 遅延なしでは
# 検証できないため、本テストでは意図的にスタブへ人工遅延を仕込む）。
W25_2_ERR=$(mktemp /tmp/todo-test-1455-2-err-XXXXXX)
W25_2_RESP='{"issues.listForRepo":[{"__delayMs":60,"data":[]},{"__delayMs":60,"data":[]}]}'
W25_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W25_2_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 TODAY=2026-08-29 \
  node "$ENGINE" run today 2>"$W25_2_ERR"); W25_2_EC=$?
W25_2_ERRTEXT=$(cat "$W25_2_ERR" 2>/dev/null); rm -f "$W25_2_ERR"
assert_exit_ok "W25-2 run today(並行呼び出し) + TODO_TIMING=1: exit 0" "$W25_2_EC"
W25_2_TOTAL=$(extract_timing_field "$W25_2_ERRTEXT" total)
W25_2_GITHUB=$(extract_timing_field "$W25_2_ERRTEXT" github)
assert_le "W25-2: github <= total（並行呼び出しでも不変条件を維持・parseが負値にならない）" "$W25_2_GITHUB" "$W25_2_TOTAL"
# 単純合計なら120ms超になるはずのところ、区間統合により100ms未満に収まることを確認
# （2並行呼び出しの重なりを1回分に畳めていることの直接証拠。CIジッタを見込み閾値は緩め）
assert_lt "W25-2: github が単純合計(約120ms)より十分小さい（区間統合が機能している証拠）" "$W25_2_GITHUB" "100"

# W25-3 apiMain経路（direct api / run api の両方）— stdout(機械可読JSON)は
# TODO_TIMING有無で完全一致、stderrに[timing]行が出ることを確認
API_RESP='{"issues.listForRepo":[{"data":[]}]}'
W25_3A_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$API_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" api list-issues 2>/dev/null)
W25_3A_ERR=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$API_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" api list-issues 2>&1 1>/dev/null)
W25_3A_NOTIMING=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$API_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" api list-issues 2>/dev/null)
assert_regex "W25-3: 直接 api list-issues + TODO_TIMING=1 → stderrに[timing]行" "$TIMING_LINE_RE" "$W25_3A_ERR"
assert_eq "W25-3: 直接 api 経由 — stdout(JSON)はTODO_TIMING有無で完全一致" "$W25_3A_NOTIMING" "$W25_3A_OUT"

W25_3B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$API_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" run api list-issues 2>/dev/null)
W25_3B_ERR=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$API_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" run api list-issues 2>&1 1>/dev/null)
W25_3B_NOTIMING=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$API_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run api list-issues 2>/dev/null)
assert_regex "W25-3: run api list-issues + TODO_TIMING=1 → stderrに[timing]行" "$TIMING_LINE_RE" "$W25_3B_ERR"
assert_eq "W25-3: run api 経由 — stdout(JSON)はTODO_TIMING有無で完全一致" "$W25_3B_NOTIMING" "$W25_3B_OUT"

# W25-4 help/schema（Octokitは生成されるがAPI呼び出しは発生しない経路）→ github は常に0
W25_4A_ERR=$(OCTOKIT_STUB_ENV="$STUB" TODO_TIMING=1 node "$ENGINE" run help 2>&1 1>/dev/null)
assert_regex "W25-4: run help + TODO_TIMING=1 → [timing]行が出る" "$TIMING_LINE_RE" "$W25_4A_ERR"
assert_eq "W25-4: run help はAPI呼び出しなし → github 0ms" "0" "$(extract_timing_field "$W25_4A_ERR" github)"

W25_4B_ERR=$(OCTOKIT_STUB_ENV="$STUB" TODO_TIMING=1 node "$ENGINE" run schema 2>&1 1>/dev/null)
assert_regex "W25-4: run schema + TODO_TIMING=1 → [timing]行が出る" "$TIMING_LINE_RE" "$W25_4B_ERR"
assert_eq "W25-4: run schema はAPI呼び出しなし → github 0ms" "0" "$(extract_timing_field "$W25_4B_ERR" github)"

# W25-5 バリデーションエラーで process.exit(1) を直接呼ぶ経路（例: run done 番号なし）でも
# [timing] 行が出力されること（.finally()では到達しないため process.on('exit') 方式を採用した
# 核心の回帰テスト。修正前コードでは本アサーションがFAILすることを実装時に実機確認済み）
W25_5_ERR=$(OCTOKIT_STUB_ENV="$STUB" TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" run done 2>&1 1>/dev/null); W25_5_EC=$?
assert_exit_fail "W25-5 run done(番号なし・process.exit直接): exit非0" "$W25_5_EC"
assert_regex "W25-5 【核心】process.exit(1)直接呼び出し経路でも[timing]行が出力される" "$TIMING_LINE_RE" "$W25_5_ERR"
assert_eq "W25-5: バリデーション先行でAPI呼び出し前に終了 → github 0ms" "0" "$(extract_timing_field "$W25_5_ERR" github)"

# W25-6 Octokit呼び出し中の例外（__throw）が発生しても [timing] 行が握りつぶされない
W25_6_ISSUE_RESP='{"issues.get":[{"__throw":true,"status":500,"message":"Internal Server Error"}]}'
W25_6_ERR=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W25_6_ISSUE_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" run show 42 2>&1 1>/dev/null); W25_6_EC=$?
assert_exit_fail "W25-6 run show(issues.get例外) : exit非0" "$W25_6_EC"
assert_regex "W25-6: Octokit呼び出し中の例外発生時も[timing]行が出力される（例外に握りつぶされない）" "$TIMING_LINE_RE" "$W25_6_ERR"

# W25-7 【核心】TODO_TIMING未設定時、stdoutが完全にバイト一致（既定出力への非侵襲性の直接証明）
W25_7_RESP='{"issues.listForRepo":[{"data":[]}]}'
W25_7_STDOUT_ON=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W25_7_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=1 \
  node "$ENGINE" run list next 2>/dev/null)
W25_7_STDOUT_OFF=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W25_7_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run list next 2>/dev/null)
assert_eq "W25-7 【核心】TODO_TIMING未設定時とTODO_TIMING=1時でstdoutが完全一致（1バイトも変わらない）" \
  "$W25_7_STDOUT_OFF" "$W25_7_STDOUT_ON"

# W25-8 TODO_TIMING未設定時、stderrに[timing]が一切出現しない
W25_8_ERR=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W25_7_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run list next 2>&1 1>/dev/null)
assert_not_contains "W25-8: TODO_TIMING未設定時はstderrに[timing]が出現しない" "[timing]" "$W25_8_ERR"

# W25-9 TODO_TIMING=0（境界値）は無効 — 厳密文字列一致'1'以外はすべて既定動作
W25_9_ERR=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W25_7_RESP" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODO_TIMING=0 \
  node "$ENGINE" run list next 2>&1 1>/dev/null)
assert_not_contains "W25-9: TODO_TIMING=0（'1'以外）は無効・[timing]行が出ない" "[timing]" "$W25_9_ERR"

# W25-10 【核心・回帰】wrapOctokitTiming() が関数プロパティ（.endpoint/.defaults）を
# 保持することをスタブ経由で構造的に検証する（実トークンでの実測 2026-08-29 で発覚した不具合の
# 回帰テスト）。素朴な `obj[key] = async (...a) => orig(...a)` 方式では実 @octokit/rest の
# 内部実装が参照する .endpoint/.defaults が失われ、TODO_TIMING=1 で実GitHub APIを
# 呼ぶと "octokit.request.defaults is not a function" 等で機能停止していた
# （stdoutが空になり「既定出力を変えない」も破っていた）。本テストはスタブの
# issues.get/request にも同形のダミー関数プロパティを持たせた上で
# wrapOctokitTiming() 適用後もそれらが保持されることを確認する。
# 実 @octokit/rest を使う対照テストは run-tests.sh §50 参照（本テストは
# 環境非依存でネットワーク・実パッケージ不要のため必ず実行される）。
W25_10_OUT=$(OCTOKIT_STUB_ENV="$STUB" node "$ENGINE" check-octokit-wrap-props 2>&1); W25_10_EC=$?
assert_exit_ok "W25-10 check-octokit-wrap-props(スタブ経路): exit 0" "$W25_10_EC"
for key in requestHasEndpoint requestHasDefaults issuesGetHasEndpoint issuesGetHasDefaults; do
  assert_contains "W25-10 【核心】wrapOctokitTiming後も $key が保持されている（スタブ）" "\"$key\":true" "$W25_10_OUT"
done

# ──────────────────────────────────────────
# §W26  runComment — --body/--body-file 対応 + 未知フラグのエラー化（Issue #1919）
# 事故: `comment <#> --body-file <path>` を実行すると「--body-file」という文字列
# そのものが本文として投稿され、<path> の中身は黙って失われていた（エラーなし・exit 0）。
# 旧実装は tokens[1] だけを本文として読み、tokens[2] 以降を無条件に捨てていた
# （フラグ解析自体が一切存在しなかった）。
# ──────────────────────────────────────────
echo ""
echo "§W26  runComment — --body/--body-file 対応 + 未知フラグのエラー化（Issue #1919）"

# W26-1【核心・回帰】--body-file: 実ファイルの中身が本文になる（元事故の直接再現テスト）。
# 修正前のコードに戻すと、body が "--body-file"（リテラル文字列）になり本アサーションはFAILする。
W26_1_LOG=$(mktemp /tmp/todo-test-w26-1-XXXXXX)
W26_1_FILE=$(mktemp /tmp/todo-test-w26-1-body-XXXXXX)
printf '%s' 'ファイルから読み込んだ本文' > "$W26_1_FILE"
W26_1_RESP='{"issues.createComment":[{"data":{"id":1}}]}'
W26_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_1_RESP" OCTOKIT_STUB_LOG_ENV="$W26_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 1915 --body-file "$W26_1_FILE" 2>&1); W26_1_EC=$?
assert_exit_ok "W26-1 --body-file(実ファイル): exit 0" "$W26_1_EC"
assert_contains "W26-1: 完了メッセージ" "💬 #1915 にコメントを追加しました。" "$W26_1_OUT"
assert_eq "W26-1: issues.createComment 呼び出し1回" "1" "$(log_count "$W26_1_LOG" issues.createComment)"
assert_contains "W26-1【核心】body がファイルの中身になっている" \
  '"body":"ファイルから読み込んだ本文"' "$(log_lines_for_method "$W26_1_LOG" issues.createComment)"
assert_not_contains "W26-1【核心・元事故の再現テスト】body が \"--body-file\" というリテラル文字列になっていない" \
  '"body":"--body-file"' "$(log_lines_for_method "$W26_1_LOG" issues.createComment)"
rm -f "$W26_1_LOG" "$W26_1_FILE"

# W26-2 --body "text": 指定文字列がそのまま本文になる
W26_2_LOG=$(mktemp /tmp/todo-test-w26-2-XXXXXX)
W26_2_RESP='{"issues.createComment":[{"data":{"id":2}}]}'
W26_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_2_RESP" OCTOKIT_STUB_LOG_ENV="$W26_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 42 --body "直接指定した本文" 2>&1); W26_2_EC=$?
assert_exit_ok "W26-2 --body(文字列指定): exit 0" "$W26_2_EC"
assert_eq "W26-2: issues.createComment 呼び出し1回" "1" "$(log_count "$W26_2_LOG" issues.createComment)"
assert_contains "W26-2: body が --body の指定文字列" '"body":"直接指定した本文"' "$(log_lines_for_method "$W26_2_LOG" issues.createComment)"
rm -f "$W26_2_LOG"

# W26-3 --body と --body-file 併用: --body-file が優先される（runAdd と同じ挙動）
W26_3_LOG=$(mktemp /tmp/todo-test-w26-3-XXXXXX)
W26_3_FILE=$(mktemp /tmp/todo-test-w26-3-body-XXXXXX)
printf '%s' 'ファイル優先の本文' > "$W26_3_FILE"
W26_3_RESP='{"issues.createComment":[{"data":{"id":3}}]}'
W26_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_3_RESP" OCTOKIT_STUB_LOG_ENV="$W26_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 43 --body "使われないはずのbody文字列" --body-file "$W26_3_FILE" 2>&1); W26_3_EC=$?
assert_exit_ok "W26-3 --body と --body-file 併用: exit 0" "$W26_3_EC"
assert_contains "W26-3【核心】--body-file が --body より優先される" '"body":"ファイル優先の本文"' "$(log_lines_for_method "$W26_3_LOG" issues.createComment)"
assert_not_contains "W26-3: --body の指定文字列は使われない" '"body":"使われないはずのbody文字列"' "$(log_lines_for_method "$W26_3_LOG" issues.createComment)"
rm -f "$W26_3_LOG" "$W26_3_FILE"

# W26-4 --body-file に存在しないパスを指定 → エラー・非0終了、issues.createComment は呼ばれない
W26_4_LOG=$(mktemp /tmp/todo-test-w26-4-XXXXXX)
: > "$W26_4_LOG"
W26_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W26_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 44 --body-file /tmp/todo-test-w26-path-that-does-not-exist 2>&1); W26_4_EC=$?
assert_exit_fail "W26-4 --body-file(存在しないパス): exit非0" "$W26_4_EC"
assert_contains "W26-4: エラーメッセージ（runAdd と共通の body_file_not_found を再利用）" "--body-file のパスが見つかりません" "$W26_4_OUT"
assert_eq "W26-4: issues.createComment は呼ばれない（副作用なし）" "0" "$(log_count "$W26_4_LOG" issues.createComment)"
rm -f "$W26_4_LOG"

# W26-5【核心・直接再現】未知のフラグ（--body-file のタイプミス）は本文へ連結されずエラー終了する。
# これが事故の直接的な再発防止テスト: --body-file 自体は W26-1 で正しく処理されるが、
# 似た別の未知フラグは黙って本文化させない。
W26_5_LOG=$(mktemp /tmp/todo-test-w26-5-XXXXXX)
: > "$W26_5_LOG"
W26_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W26_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 45 --boddy-file /tmp/some-path 2>&1); W26_5_EC=$?
assert_exit_fail "W26-5【核心・直接再現】未知フラグ(--boddy-file)は本文にならずエラー終了" "$W26_5_EC"
# #1921 第2弾で英語ハードコードを i18n（error.unknown_flag）へ寄せたため、日本語モードの
# 期待値を ja 文言へ更新した。部分一致（--boddy-file だけ）に緩めてはいけない: 成功時の
# 出力にもフラグ名の字面が現れうるため、ガードを外しても PASS するアサーションになる。
assert_contains "W26-5: エラー本文が未知フラグのものである（ja 文言。#1921 第2弾で i18n 統一）" "エラー: 不明なフラグです: --boddy-file" "$W26_5_OUT"
assert_eq "W26-5: issues.createComment は呼ばれない（黙って本文として投稿しない）" "0" "$(log_count "$W26_5_LOG" issues.createComment)"
rm -f "$W26_5_LOG"

# W26-5b 値が欠落した既知フラグ（末尾の --body-file）も同様にエラー終了する
W26_5B_LOG=$(mktemp /tmp/todo-test-w26-5b-XXXXXX)
: > "$W26_5B_LOG"
W26_5B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W26_5B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 46 --body-file 2>&1); W26_5B_EC=$?
assert_exit_fail "W26-5b 値欠落の --body-file（末尾）もエラー終了（黙って本文にしない）" "$W26_5B_EC"
assert_eq "W26-5b: issues.createComment は呼ばれない" "0" "$(log_count "$W26_5B_LOG" issues.createComment)"
rm -f "$W26_5B_LOG"

# W26-5c 英語モード（LANG_ENV=en）: 本文は #1919 当時のハードコードと完全一致し、
# ヒント行が1行増える。日本語が1文字も混入しないこと（Issue #1653 の方針）。
W26_5C_LOG=$(mktemp /tmp/todo-test-w26-5c-XXXXXX)
: > "$W26_5C_LOG"
W26_5C_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W26_5C_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo LANG_ENV=en \
  node "$ENGINE" run comment 45 --boddy-file2 /tmp/some-path 2>&1); W26_5C_EC=$?
assert_exit_fail "W26-5c 英語モード(LANG_ENV=en)の未知フラグ: exit非0" "$W26_5C_EC"
assert_contains "W26-5c: 英語のエラー本文（#1919 当時の文言と完全一致）" "Error: unknown flag: --boddy-file2" "$W26_5C_OUT"
assert_contains "W26-5c: 英語のヒント行（本文向け）" "quote the whole body" "$W26_5C_OUT"
assert_no_japanese "W26-5c: 出力に日本語が1文字も含まれない" "$W26_5C_OUT"
assert_eq "W26-5c: issues.createComment は呼ばれない" "0" "$(log_count "$W26_5C_LOG" issues.createComment)"
rm -f "$W26_5C_LOG"

# W26-5d 日本語モード: ヒント行が「本文」向け（error.unknown_flag_hint_body）であること。
# add と同じ「タイトル」向けヒント（error.unknown_flag_hint）が誤配線されていないことも固定する。
W26_5D_LOG=$(mktemp /tmp/todo-test-w26-5d-XXXXXX)
: > "$W26_5D_LOG"
W26_5D_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W26_5D_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 45 --boddy-file /tmp/some-path 2>&1); W26_5D_EC=$?
assert_exit_fail "W26-5d 日本語モードの未知フラグ: exit非0" "$W26_5D_EC"
assert_contains "W26-5d: ヒント行が本文向け（本文全体を1つの引数としてクォート）" "本文全体を1つの引数としてクォート" "$W26_5D_OUT"
assert_not_contains "W26-5d: タイトル向けヒントが誤配線されていない" "タイトル全体を1つの引数" "$W26_5D_OUT"
assert_contains "W26-5d: Usage 行は日本語モードでも英語（翻訳方針）" "Usage: /todo comment <#> <text>" "$W26_5D_OUT"
rm -f "$W26_5D_LOG"

# W26-6 後方互換: 従来の位置引数形式（comment <#> <テキスト>）はそのまま動く
W26_6_LOG=$(mktemp /tmp/todo-test-w26-6-XXXXXX)
W26_6_RESP='{"issues.createComment":[{"data":{"id":6}}]}'
W26_6_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_6_RESP" OCTOKIT_STUB_LOG_ENV="$W26_6_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 47 "従来形式の位置引数コメント" 2>&1); W26_6_EC=$?
assert_exit_ok "W26-6 従来の位置引数形式(comment <#> <テキスト>): exit 0（後方互換）" "$W26_6_EC"
assert_contains "W26-6: body が位置引数のテキストそのもの" '"body":"従来形式の位置引数コメント"' "$(log_lines_for_method "$W26_6_LOG" issues.createComment)"
rm -f "$W26_6_LOG"

# W26-7【境界】単一ハイフンで始まる本文は誤ってフラグ扱いされない（`--` 判定のみ対象のため）
W26_7_LOG=$(mktemp /tmp/todo-test-w26-7-XXXXXX)
W26_7_RESP='{"issues.createComment":[{"data":{"id":7}}]}'
W26_7_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_7_RESP" OCTOKIT_STUB_LOG_ENV="$W26_7_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 48 "- 箇条書きから始まるコメント" 2>&1); W26_7_EC=$?
assert_exit_ok "W26-7【境界】単一ハイフンで始まる本文はフラグ扱いされない: exit 0" "$W26_7_EC"
assert_contains "W26-7: body が単一ハイフン始まりのテキストそのまま" '"body":"- 箇条書きから始まるコメント"' "$(log_lines_for_method "$W26_7_LOG" issues.createComment)"
rm -f "$W26_7_LOG"

# W26-8 テキスト省略（位置引数もフラグもなし）→ エラー・非0終了（既存挙動の回帰確認）
W26_8_LOG=$(mktemp /tmp/todo-test-w26-8-XXXXXX)
: > "$W26_8_LOG"
W26_8_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W26_8_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 49 2>&1); W26_8_EC=$?
assert_exit_fail "W26-8 テキスト省略（位置引数もフラグもなし）: exit非0（既存挙動の回帰確認）" "$W26_8_EC"
assert_eq "W26-8: issues.createComment は呼ばれない" "0" "$(log_count "$W26_8_LOG" issues.createComment)"
rm -f "$W26_8_LOG"

# W26-9【核心・回帰】Markdown水平線「--- 区切り線 ---」は `--` の直後がハイフンで
# フラグの字面（英字始まり）に該当しないため、エラーにならず本文としてそのまま投稿される
# （実測 2026-08-29: `tok.startsWith('--')` 一律エラー版では exit 1 になっていた副作用の回帰テスト）。
W26_9_LOG=$(mktemp /tmp/todo-test-w26-9-XXXXXX)
W26_9_RESP='{"issues.createComment":[{"data":{"id":9}}]}'
W26_9_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_9_RESP" OCTOKIT_STUB_LOG_ENV="$W26_9_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 50 "--- 区切り線 ---" 2>&1); W26_9_EC=$?
assert_exit_ok "W26-9【核心・回帰】Markdown水平線相当の本文(--- 区切り線 ---): exit 0" "$W26_9_EC"
assert_contains "W26-9: body が水平線テキストそのまま投稿される" '"body":"--- 区切り線 ---"' "$(log_lines_for_method "$W26_9_LOG" issues.createComment)"
rm -f "$W26_9_LOG"

# W26-10【核心・回帰】本文が「--body」という文字列で始まっていても、フラグの字面
# （1語・英数字/ハイフンのみ）ではない（空白と日本語を含む）ため本文として扱われる
W26_10_LOG=$(mktemp /tmp/todo-test-w26-10-XXXXXX)
W26_10_RESP='{"issues.createComment":[{"data":{"id":10}}]}'
W26_10_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_10_RESP" OCTOKIT_STUB_LOG_ENV="$W26_10_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 51 "--body を説明する文章" 2>&1); W26_10_EC=$?
assert_exit_ok "W26-10【核心・回帰】「--body」で始まる本文(--body を説明する文章): exit 0" "$W26_10_EC"
assert_contains "W26-10: body が --body で始まるテキストそのまま投稿される" '"body":"--body を説明する文章"' "$(log_lines_for_method "$W26_10_LOG" issues.createComment)"
rm -f "$W26_10_LOG"

# W26-11【仕様固定】位置引数とフラグを同時指定した場合、フラグが優先され位置引数は無視される
# （仕様判断: 現状の「フラグ優先・位置引数は無視」で仕様として確定。偶発挙動ではなく
# 意図した挙動であることをテストでロックインする）
W26_11_LOG=$(mktemp /tmp/todo-test-w26-11-XXXXXX)
W26_11_RESP='{"issues.createComment":[{"data":{"id":11}}]}'
W26_11_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W26_11_RESP" OCTOKIT_STUB_LOG_ENV="$W26_11_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run comment 52 "位置引数のテキスト（無視される）" --body "フラグの本文（採用される）" 2>&1); W26_11_EC=$?
assert_exit_ok "W26-11【仕様固定】位置引数+フラグ同時指定: exit 0" "$W26_11_EC"
assert_contains "W26-11: body はフラグ側の値になる" '"body":"フラグの本文（採用される）"' "$(log_lines_for_method "$W26_11_LOG" issues.createComment)"
assert_not_contains "W26-11: 位置引数側のテキストは使われない（仕様として確定）" '"body":"位置引数のテキスト（無視される）"' "$(log_lines_for_method "$W26_11_LOG" issues.createComment)"
rm -f "$W26_11_LOG"

# ──────────────────────────────────────────
# §W27  runAdd — 未知フラグを黙ってタイトルへ連結しない（Issue #1921 パターンA）
# 事故: `add next "設計書を書く" --boddy-file /tmp/body.txt` を実行すると、parseArgs が
# 解釈できなかった `--boddy-file` と `/tmp/body.txt` がそのままタイトルへ連結され、
# タイトル「設計書を書く --boddy-file /tmp/body.txt」・本文空の Issue が exit 0 で
# 作られていた（#1919 の runComment と同型の「静かな期待値乖離」）。
# 判定器 findUnknownFlag() 自体の単体テストは run-tests.sh §51 を参照。
# 本セクションは runAdd の振る舞い（exit code・issues.create の抑止・検査順序）を検証する。
# ──────────────────────────────────────────
echo ""
echo "§W27  runAdd — 未知フラグを黙ってタイトルへ連結しない（Issue #1921 パターンA）"

# ラベル存在確認(GET)3回分 + issues.create 1回分の既定応答。GTD以外のラベル
# （context/tag/priority）の作成数に応じて GET が呼ばれるため多めに用意する。
W27_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{},{},{},{}],"issues.create":[{"data":{"number":7001,"html_url":"https://github.com/test-owner/test-repo/issues/7001"}}]}'

# ── 正常系（既存挙動が壊れないこと） ──

# W27-1 通常のタイトル
W27_1_LOG=$(mktemp /tmp/todo-test-w27-1-XXXXXX)
W27_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "設計書を書く" 2>&1); W27_1_EC=$?
assert_exit_ok "W27-1 正常系(通常タイトル): exit 0" "$W27_1_EC"
assert_eq "W27-1: issues.create 呼び出し1回" "1" "$(log_count "$W27_1_LOG" issues.create)"
assert_contains "W27-1: title がそのまま" '"title":"設計書を書く"' "$(log_lines_for_method "$W27_1_LOG" issues.create)"
rm -f "$W27_1_LOG"

# W27-2 既知フラグ一式（§W4-1 と同一入力）を誤検知しないこと
W27_2_LOG=$(mktemp /tmp/todo-test-w27-2-XXXXXX)
W27_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run add next @office '#urgent' --p1 --due 2026-04-10 --before 3d Buy office supplies 2>&1); W27_2_EC=$?
assert_exit_ok "W27-2 正常系(既知フラグ一式・§W4-1と同一入力)を誤検知しない: exit 0" "$W27_2_EC"
assert_eq "W27-2: issues.create 呼び出し1回" "1" "$(log_count "$W27_2_LOG" issues.create)"
assert_contains "W27-2: title が位置引数の連結のみ（フラグは混入しない）" '"title":"Buy office supplies"' "$(log_lines_for_method "$W27_2_LOG" issues.create)"
rm -f "$W27_2_LOG"

# W27-3 --body-file（実ファイル）が従来どおり本文になる
W27_3_LOG=$(mktemp /tmp/todo-test-w27-3-XXXXXX)
W27_3_FILE=$(mktemp /tmp/todo-test-w27-3-body-XXXXXX)
printf '%s' 'ファイルから読み込んだ本文' > "$W27_3_FILE"
W27_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "タイトル" --body-file "$W27_3_FILE" 2>&1); W27_3_EC=$?
assert_exit_ok "W27-3 正常系(--body-file 実ファイル): exit 0" "$W27_3_EC"
assert_contains "W27-3: body にファイル内容が反映される" 'ファイルから読み込んだ本文' "$(log_lines_for_method "$W27_3_LOG" issues.create)"
assert_contains "W27-3: title にフラグが混入しない" '"title":"タイトル"' "$(log_lines_for_method "$W27_3_LOG" issues.create)"
rm -f "$W27_3_LOG" "$W27_3_FILE"

# W27-4 暗黙 GTD 経路（/todo next 〜。runMain 5407行相当）
W27_4_LOG=$(mktemp /tmp/todo-test-w27-4-XXXXXX)
W27_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run next "設計書を書く" 2>&1); W27_4_EC=$?
assert_exit_ok "W27-4 正常系(暗黙GTD経路 /todo next <タイトル>): exit 0" "$W27_4_EC"
assert_contains "W27-4: labels に 🎯 next" '"🎯 next"' "$(log_lines_for_method "$W27_4_LOG" issues.create)"
rm -f "$W27_4_LOG"

# W27-5 非英字始まりの default 経路（摩擦ゼロ収集。runMain 5478行相当）
W27_5_LOG=$(mktemp /tmp/todo-test-w27-5-XXXXXX)
W27_5_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_5_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run 日本語だけのタイトル 2>&1); W27_5_EC=$?
assert_exit_ok "W27-5 正常系(非英字始まりの default 経路): exit 0" "$W27_5_EC"
assert_contains "W27-5: labels に 📥 inbox" '"📥 inbox"' "$(log_lines_for_method "$W27_5_LOG" issues.create)"
rm -f "$W27_5_LOG"

# ── 異常系（本修正の核心） ──

# W27-6【核心・直接再現】未知フラグ（--body-file のタイプミス）はタイトルへ連結されずエラー終了する。
# 修正前のコードに戻すと、issues.create が「設計書を書く --boddy-file /tmp/x」という
# 汚染タイトルで呼ばれ、下の assert_not_contains が必ず FAIL する（反証形式・#1919 W26-1 と同じ）。
W27_6_LOG=$(mktemp /tmp/todo-test-w27-6-XXXXXX)
: > "$W27_6_LOG"
W27_6_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_6_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "設計書を書く" --boddy-file /tmp/x 2>&1); W27_6_EC=$?
assert_exit_fail "W27-6【核心・直接再現】未知フラグ(--boddy-file)はタイトルにならずエラー終了" "$W27_6_EC"
assert_contains "W27-6: エラー本文が未知フラグのものである（成功時の出力にも --boddy-file の字面は出るため、メッセージ全文で判定する）" "エラー: 不明なフラグです: --boddy-file" "$W27_6_OUT"
assert_eq "W27-6: issues.create は呼ばれない（ゴミ Issue を作らない）" "0" "$(log_count "$W27_6_LOG" issues.create)"
assert_not_contains "W27-6【核心・元事故の再現テスト】汚染タイトルでの issues.create が発生していない" \
  '"title":"設計書を書く --boddy-file /tmp/x"' "$(log_lines_for_method "$W27_6_LOG" issues.create)"
rm -f "$W27_6_LOG"

# W27-7 値が欠落した既知フラグ（末尾の --due。parseArgs の i+1 条件を満たさず extra に残る）
W27_7_LOG=$(mktemp /tmp/todo-test-w27-7-XXXXXX)
: > "$W27_7_LOG"
W27_7_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_7_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "タイトル" --due 2>&1); W27_7_EC=$?
assert_exit_fail "W27-7 値欠落の既知フラグ（末尾の --due）もエラー終了" "$W27_7_EC"
assert_contains "W27-7: エラー本文が未知フラグのものである" "エラー: 不明なフラグです: --due" "$W27_7_OUT"
assert_eq "W27-7: issues.create は呼ばれない" "0" "$(log_count "$W27_7_LOG" issues.create)"
rm -f "$W27_7_LOG"

# W27-8 add に存在しないフラグ（--json は list 専用）
W27_8_LOG=$(mktemp /tmp/todo-test-w27-8-XXXXXX)
: > "$W27_8_LOG"
W27_8_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_8_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "タイトル" --json 2>&1); W27_8_EC=$?
assert_exit_fail "W27-8 add に存在しないフラグ(--json)はエラー終了" "$W27_8_EC"
assert_contains "W27-8: エラー本文が未知フラグのものである" "エラー: 不明なフラグです: --json" "$W27_8_OUT"
assert_eq "W27-8: issues.create は呼ばれない" "0" "$(log_count "$W27_8_LOG" issues.create)"
rm -f "$W27_8_LOG"

# W27-9【副作用ゼロ・検査順序】@ctx を伴う場合でも、ラベル作成（ensureLabel）へ到達する前に
# 未知フラグ検査で落ちること。バリデーションを API 副作用より前に置く原則の担保
# （#1803 resume_condition 実装時の教訓の再演。§W4-2 と同じ「API呼び出しゼロ」形式）。
W27_9_LOG=$(mktemp /tmp/todo-test-w27-9-XXXXXX)
: > "$W27_9_LOG"
W27_9_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_9_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next @office "タイトル" --boddy-file /tmp/x 2>&1); W27_9_EC=$?
assert_exit_fail "W27-9【副作用ゼロ】@ctx 併用でも未知フラグでエラー終了" "$W27_9_EC"
assert_eq "W27-9【核心】API 呼び出しがゼロ（ラベル作成の GET/POST に到達していない）" "0" "$(wc -l < "$W27_9_LOG" | tr -d ' ')"
assert_eq "W27-9: ラベル存在確認(GET) 0回" "0" "$(log_count "$W27_9_LOG" 'GET /repos/{owner}/{repo}/labels/{name}')"
rm -f "$W27_9_LOG"

# W27-10【メッセージ優先順位】フラグのみでタイトルがない場合、「タイトルが空です」ではなく
# 未知フラグのエラーを出す（原因に直結するメッセージを優先する順序の固定）。
W27_10_LOG=$(mktemp /tmp/todo-test-w27-10-XXXXXX)
: > "$W27_10_LOG"
W27_10_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_10_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next --boddy-file /tmp/x 2>&1); W27_10_EC=$?
assert_exit_fail "W27-10 フラグのみ・タイトルなし: exit非0" "$W27_10_EC"
assert_contains "W27-10: 未知フラグのエラー本文が出る" "エラー: 不明なフラグです: --boddy-file" "$W27_10_OUT"
assert_not_contains "W27-10【メッセージ優先順位】「タイトルが空です」は出さない" "タイトルが空です" "$W27_10_OUT"
rm -f "$W27_10_LOG"

# W27-10b【境界】空白のみのトークンと未知フラグが同時に渡された場合も未知フラグを優先する
# （設計書「自信が持てない箇所2」の実測確認。修正前は title が "--foo" の Issue が作られていた）
W27_10B_LOG=$(mktemp /tmp/todo-test-w27-10b-XXXXXX)
: > "$W27_10B_LOG"
W27_10B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_10B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next " " --foo 2>&1); W27_10B_EC=$?
assert_exit_fail "W27-10b 空白トークン + 未知フラグ: exit非0（未知フラグ優先）" "$W27_10B_EC"
assert_contains "W27-10b: 未知フラグのエラー本文が出る" "エラー: 不明なフラグです: --foo" "$W27_10B_OUT"
assert_eq "W27-10b: issues.create は呼ばれない" "0" "$(log_count "$W27_10B_LOG" issues.create)"
rm -f "$W27_10B_LOG"

# W27-11 英語モード（LANG_ENV=en）: 日本語が1文字も出ないこと
W27_11_LOG=$(mktemp /tmp/todo-test-w27-11-XXXXXX)
: > "$W27_11_LOG"
W27_11_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_11_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo LANG_ENV=en \
  node "$ENGINE" run add next "write the design doc" --boddy-file /tmp/x 2>&1); W27_11_EC=$?
assert_exit_fail "W27-11 英語モード(LANG_ENV=en): exit非0" "$W27_11_EC"
assert_contains "W27-11: 英語のエラーメッセージ" "Error: unknown flag: --boddy-file" "$W27_11_OUT"
assert_contains "W27-11: 英語のヒント行（クォートを促す）" "quote the whole title" "$W27_11_OUT"
assert_contains "W27-11: Usage 行（常時英語）" "Usage: /todo add [GTD] <title>" "$W27_11_OUT"
assert_no_japanese "W27-11: 出力に日本語が1文字も含まれない" "$W27_11_OUT"
rm -f "$W27_11_LOG"

# W27-12 日本語モード（既定）: ja のエラー本文とヒント行が出る
W27_12_LOG=$(mktemp /tmp/todo-test-w27-12-XXXXXX)
: > "$W27_12_LOG"
W27_12_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_12_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "設計書を書く" --boddy-file /tmp/x 2>&1); W27_12_EC=$?
assert_exit_fail "W27-12 日本語モード(既定): exit非0" "$W27_12_EC"
assert_contains "W27-12: 日本語のエラー本文" "エラー: 不明なフラグです: --boddy-file" "$W27_12_OUT"
assert_contains "W27-12: 日本語のヒント行（タイトル全体をクォートする脱出口を案内）" "タイトル全体を1つの引数としてクォート" "$W27_12_OUT"
assert_contains "W27-12: Usage 行は日本語モードでも英語（翻訳方針）" "Usage: /todo add [GTD] <title>" "$W27_12_OUT"
rm -f "$W27_12_LOG"

# ── 入力文字パターン（誤検知しないこと。§51 は判定器単体、ここは runAdd 経由の
#    タイトル組み立てまで含めた end-to-end 確認） ──

# W27-13 Markdown水平線を含むクォート済みタイトル
W27_13_LOG=$(mktemp /tmp/todo-test-w27-13-XXXXXX)
W27_13_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_13_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "--- 区切り線 --- を含むタイトル" 2>&1); W27_13_EC=$?
assert_exit_ok "W27-13 入力文字: Markdown水平線を含むタイトル: exit 0" "$W27_13_EC"
assert_contains "W27-13: title がそのまま" '"title":"--- 区切り線 --- を含むタイトル"' "$(log_lines_for_method "$W27_13_LOG" issues.create)"
rm -f "$W27_13_LOG"

# W27-14 --- が単独トークンとして現れるクォートなしタイトル
W27_14_LOG=$(mktemp /tmp/todo-test-w27-14-XXXXXX)
W27_14_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_14_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next --- 区切り線 2>&1); W27_14_EC=$?
assert_exit_ok "W27-14 入力文字: --- が単独トークン（-- の直後がハイフン）: exit 0" "$W27_14_EC"
assert_contains "W27-14: title が --- 区切り線" '"title":"--- 区切り線"' "$(log_lines_for_method "$W27_14_LOG" issues.create)"
rm -f "$W27_14_LOG"

# W27-15 「--body」で始まるが空白と非ASCII を含むタイトル
W27_15_LOG=$(mktemp /tmp/todo-test-w27-15-XXXXXX)
W27_15_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_15_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "--body を説明するタスク" 2>&1); W27_15_EC=$?
assert_exit_ok "W27-15 入力文字: 「--body を説明するタスク」: exit 0" "$W27_15_EC"
assert_contains "W27-15: title がそのまま" '"title":"--body を説明するタスク"' "$(log_lines_for_method "$W27_15_LOG" issues.create)"
rm -f "$W27_15_LOG"

# W27-16 単一ハイフン始まりのトークン
W27_16_LOG=$(mktemp /tmp/todo-test-w27-16-XXXXXX)
W27_16_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_16_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next - 箇条書きのタスク 2>&1); W27_16_EC=$?
assert_exit_ok "W27-16 入力文字: 単一ハイフン始まりのトークン: exit 0" "$W27_16_EC"
assert_contains "W27-16: title が - 箇条書きのタスク" '"title":"- 箇条書きのタスク"' "$(log_lines_for_method "$W27_16_LOG" issues.create)"
rm -f "$W27_16_LOG"

# W27-17 シェル特殊文字（コマンド置換の形）がリテラルとして保持されること
W27_17_LOG=$(mktemp /tmp/todo-test-w27-17-XXXXXX)
W27_17_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_17_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next '$(whoami) を含むタイトル' 2>&1); W27_17_EC=$?
assert_exit_ok "W27-17 セキュリティ: コマンド置換の形をリテラル保持: exit 0" "$W27_17_EC"
assert_contains "W27-17: title が \$(whoami) のリテラル（展開されていない）" '"title":"$(whoami) を含むタイトル"' "$(log_lines_for_method "$W27_17_LOG" issues.create)"
rm -f "$W27_17_LOG"

# W27-18 マルチバイト・絵文字
W27_18_LOG=$(mktemp /tmp/todo-test-w27-18-XXXXXX)
W27_18_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_18_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "🎯 目標を決める" 2>&1); W27_18_EC=$?
assert_exit_ok "W27-18 入力文字(マルチバイト・絵文字): exit 0" "$W27_18_EC"
assert_contains "W27-18: title が絵文字ごとそのまま" '"title":"🎯 目標を決める"' "$(log_lines_for_method "$W27_18_LOG" issues.create)"
rm -f "$W27_18_LOG"

# W27-19 フォーマット文字列（printf 誤認がないこと）
W27_19_LOG=$(mktemp /tmp/todo-test-w27-19-XXXXXX)
W27_19_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_19_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "進捗 %s を報告する" 2>&1); W27_19_EC=$?
assert_exit_ok "W27-19 入力文字(フォーマット文字列 %s): exit 0" "$W27_19_EC"
assert_contains "W27-19: title がそのまま（printf 誤認なし）" '"title":"進捗 %s を報告する"' "$(log_lines_for_method "$W27_19_LOG" issues.create)"
rm -f "$W27_19_LOG"

# ── 境界値 ──

# W27-20【仕様固定】`--` 単独トークンはタイトルの一部として連結される。
# 将来 end-of-options（`--` 以降は全部位置引数）を導入する場合は、本ケースの
# 期待値を意図的に変更すること（後方非互換の変更であることの目印）。
W27_20_LOG=$(mktemp /tmp/todo-test-w27-20-XXXXXX)
W27_20_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_20_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next -- タイトル 2>&1); W27_20_EC=$?
assert_exit_ok "W27-20【仕様固定】-- 単独トークンはタイトルの一部: exit 0" "$W27_20_EC"
assert_contains "W27-20: title が「-- タイトル」" '"title":"-- タイトル"' "$(log_lines_for_method "$W27_20_LOG" issues.create)"
rm -f "$W27_20_LOG"

# W27-21【境界】--p4 は --p[123] の境界外。parseArgs に消費されず extra に落ちるため
# 未知フラグとしてエラーになる（修正前の実測: exit 0 で title「タイトル --p4」・
# priority は既定の p3 のまま、という静かな乖離だった）。
W27_21_LOG=$(mktemp /tmp/todo-test-w27-21-XXXXXX)
: > "$W27_21_LOG"
W27_21_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_21_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "タイトル" --p4 2>&1); W27_21_EC=$?
assert_exit_fail "W27-21【境界】--p4（--p[123] の境界外）はエラー終了" "$W27_21_EC"
assert_contains "W27-21: エラー本文が未知フラグのものである" "エラー: 不明なフラグです: --p4" "$W27_21_OUT"
assert_not_contains "W27-21: 汚染タイトルでの issues.create が発生していない" \
  '"title":"タイトル --p4"' "$(log_lines_for_method "$W27_21_LOG" issues.create)"
rm -f "$W27_21_LOG"

# W27-22【境界】空トークンは従来どおり除去される
W27_22_LOG=$(mktemp /tmp/todo-test-w27-22-XXXXXX)
W27_22_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_22_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "" タイトル 2>&1); W27_22_EC=$?
assert_exit_ok "W27-22【境界】空トークンは除去される: exit 0" "$W27_22_EC"
assert_contains "W27-22: title が「タイトル」" '"title":"タイトル"' "$(log_lines_for_method "$W27_22_LOG" issues.create)"
rm -f "$W27_22_LOG"

# W27-23【境界】検出はトークン位置に依存しない（先頭 / 末尾）
W27_23A_LOG=$(mktemp /tmp/todo-test-w27-23a-XXXXXX)
: > "$W27_23A_LOG"
W27_23A_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_23A_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next --boddy-file "タイトル" 2>&1); W27_23A_EC=$?
assert_exit_fail "W27-23a【境界】未知フラグが先頭でもエラー終了" "$W27_23A_EC"
assert_eq "W27-23a: issues.create は呼ばれない" "0" "$(log_count "$W27_23A_LOG" issues.create)"
rm -f "$W27_23A_LOG"

W27_23B_LOG=$(mktemp /tmp/todo-test-w27-23b-XXXXXX)
: > "$W27_23B_LOG"
W27_23B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_23B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "タイトル" --boddy-file 2>&1); W27_23B_EC=$?
assert_exit_fail "W27-23b【境界】未知フラグが末尾（値なし）でもエラー終了" "$W27_23B_EC"
assert_eq "W27-23b: issues.create は呼ばれない" "0" "$(log_count "$W27_23B_LOG" issues.create)"
rm -f "$W27_23B_LOG"

# ── セキュリティ ──

# W27-24【セキュリティ・現状挙動の固定】シェル特殊文字を含むトークンはフラグの字面では
# ないため通り、タイトルにリテラルとして含まれる。期待値は修正前コードでの実測
# （2026-09-01: exit 0 / title「タイトル --evil;rm -rf /」）に合わせて固定した。
# validateTitle（制御文字のみ禁止。#1825 でタイトルの記号禁止は解除済み）を通り、
# Octokit の JSON ボディにしか渡らないためシェル展開経路は存在しない。
# 検証用ファイルが残っていることで、テストプロセスの外側でコマンドが実行されて
# いないことを確認する。
W27_24_LOG=$(mktemp /tmp/todo-test-w27-24-XXXXXX)
W27_24_CANARY=$(mktemp /tmp/todo-test-w27-24-canary-XXXXXX)
printf '%s' 'canary' > "$W27_24_CANARY"
W27_24_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_24_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next "タイトル" '--evil;rm -rf /' 2>&1); W27_24_EC=$?
assert_exit_ok "W27-24 セキュリティ: --evil;rm -rf / はフラグ字面でないため通る: exit 0（修正前実測どおり）" "$W27_24_EC"
assert_contains "W27-24: title にリテラルとして含まれる" '"title":"タイトル --evil;rm -rf /"' "$(log_lines_for_method "$W27_24_LOG" issues.create)"
if [ -f "$W27_24_CANARY" ]; then
  printf "  ✅ W27-24: 検証用ファイルが残っている（rm が実行されていない）\n"; PASS=$((PASS+1))
else
  printf "  ❌ W27-24: 検証用ファイルが消えている（コマンドが実行された疑い）\n"; FAIL=$((FAIL+1))
fi
rm -f "$W27_24_LOG" "$W27_24_CANARY"

# ── パフォーマンス ──

# W27-26 200トークンのタイトル（すべて正常語）。走査の追加が線形で済み、
# タイトルが全トークンの連結と一致すること。
W27_26_ARGS=()
W27_26_EXPECTED=""
W27_26_I=1
while [ "$W27_26_I" -le 200 ]; do
  W27_26_ARGS+=("語${W27_26_I}")
  if [ -z "${W27_26_EXPECTED}" ]; then
    W27_26_EXPECTED="語${W27_26_I}"
  else
    W27_26_EXPECTED="${W27_26_EXPECTED} 語${W27_26_I}"
  fi
  W27_26_I=$((W27_26_I+1))
done
W27_26_LOG=$(mktemp /tmp/todo-test-w27-26-XXXXXX)
W27_26_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W27_RESP" OCTOKIT_STUB_LOG_ENV="$W27_26_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run add next ${W27_26_ARGS[@]+"${W27_26_ARGS[@]}"} 2>&1); W27_26_EC=$?
assert_exit_ok "W27-26 パフォーマンス: 200トークンのタイトルでも完了する: exit 0" "$W27_26_EC"
assert_contains "W27-26: title が全200トークンの連結と一致" "\"title\":\"${W27_26_EXPECTED}\"" "$(log_lines_for_method "$W27_26_LOG" issues.create)"
rm -f "$W27_26_LOG"

# ──────────────────────────────────────────
# §W28  パターンB・C — 11ハンドラが未知フラグを黙って捨てないこと（Issue #1921 第2弾）
# 事故の型は §W27（runAdd）と同じ「静かな期待値乖離」。ただし症状は3種類ある。
#   (a) 指定した値が黙って捨てられる（`due 42 2026-09-10 --note "理由"` の --note は効かない）
#   (b) フィルタが黙って無視される（`list next --no-duee` は全件表示される）
#   (c) 自由記述へ混入する（`template use daily --boddy-file /tmp/x` はゴミ Issue、
#       `rename 42 --boddy-file /tmp/x` は既存タイトルを上書きして消す）
# 判定器 findUnknownFlag() 自体の単体テストは run-tests.sh §51 を参照。
# 本セクションは各ハンドラの振る舞い（exit code・API 副作用の抑止・検査順序）を検証する。
#
# 【アサーションの書き方の規約（2つ）】
#  1. エラー判定は必ず**エラーメッセージ全文**（「エラー: 不明なフラグです: <flag>」）で行う。
#     フラグ名の部分一致にすると、成功時の出力にも字面が現れるハンドラ（template use の
#     タイトル行等）でガードを外しても PASS したままになる（§W27 実施時に6件発生した罠）。
#  2. 異常系のスタブ応答は、対になる**正常系で exit 0 になることを確認した応答を使い回す**。
#     応答不足だと「ガードの有無に関わらず」例外で落ちて assert_exit_fail が常に PASS する。
#
# パフォーマンス観点のケースを置いていないのは意図的: 判定器は §51-17（500要素）で
# カバー済みで、ハンドラを変えても走査は同じ線形1パスのため新しい情報が出ない。
# ──────────────────────────────────────────
echo ""
echo "§W28  パターンB・C — 11ハンドラが未知フラグを黙って捨てない（Issue #1921 第2弾）"

# 各ハンドラの正常系スタブ応答（同じものを異常系でも使い回す。上記規約2）
W28_LIST_RESP='{"issues.listForRepo":[{"data":[]}]}'
W28_MOVE_RESP='{"issues.get":[{"data":{"number":42,"id":942,"title":"元のタイトル","body":"","labels":[{"name":"📥 inbox"}]}}],"issues.removeLabel":[{}],"issues.addLabels":[{}],"issues.createComment":[{"data":{"id":1}}]}'
W28_DONE_RESP='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[{"name":"🎯 next"}]}}],"issues.update":[{},{}],"issues.listForRepo":[{"data":[]}],"issues.createComment":[{"data":{"id":1}}]}'
W28_EDIT_RESP='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[{"name":"p3"}]}}],"issues.removeLabel":[{}],"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.addLabels":[{}],"issues.update":[{}]}'
W28_LABEL_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}]}'
W28_LABEL_LIST_RESP='{"issues.listLabelsForRepo":[{"data":[{"name":"@office","color":"FBCA04","description":""}]}]}'
W28_LABEL_DEL_RESP='{"issues.deleteLabel":[{}]}'
# GET が 404（＝そのラベルはまだ存在しない）→ ensureLabel が createLabel まで進む形
W28_LABEL_NEW_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{"__throw":true,"status":404,"message":"Not Found"}],"issues.createLabel":[{}]}'
W28_LABEL_REN_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.listForRepo":[{"data":[]}],"issues.deleteLabel":[{}]}'
# tag rename 用。label rename 用（上）と違い @oldctx を持つ Issue を1件返す。
# こうしないと targets が空になり addLabels が「ガードの有無に関わらず」0回になってしまい、
# 「addLabels が0回」というアサーションが何も検証しない（§論点6 罠2 と同型）。
W28_TAG_REN_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.listForRepo":[{"data":[{"number":42,"id":942,"title":"T","body":"","labels":[{"name":"@oldctx"}]}]}],"issues.addLabels":[{}],"issues.removeLabel":[{}],"issues.deleteLabel":[{}]}'
W28_SIMPLE_RESP='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[]}}],"issues.update":[{}]}'
W28_PRI_RESP='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[{"name":"p3"}]}}],"issues.removeLabel":[{}],"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.addLabels":[{}]}'
W28_LINK_RESP='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[]}},{"data":{"number":100,"id":9100,"title":"P","body":"","labels":[{"name":"📁 project"}]}}],"issues.update":[{}],"POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues":[{}]}'
W28_RENAME_RESP='{"issues.update":[{}]}'
W28_BULKMOVE_RESP='{"issues.get":[{"data":{"number":41,"id":941,"title":"A","body":"","labels":[{"name":"📥 inbox"}]}},{"data":{"number":42,"id":942,"title":"B","body":"","labels":[{"name":"📥 inbox"}]}}],"issues.removeLabel":[{},{}],"issues.addLabels":[{},{}]}'
W28_BULKDONE_RESP='{"issues.get":[{"data":{"number":41,"id":941,"title":"A","body":"","labels":[{"name":"🎯 next"}]}},{"data":{"number":42,"id":942,"title":"B","body":"","labels":[{"name":"🎯 next"}]}}],"issues.update":[{},{}],"issues.listForRepo":[{"data":[]},{"data":[]}]}'
W28_BULKPRI_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.get":[{"data":{"number":41,"id":941,"title":"A","body":"","labels":[]}},{"data":{"number":42,"id":942,"title":"B","body":"","labels":[]}}],"issues.addLabels":[{},{}]}'
W28_TMPLUSE_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{},{},{}],"issues.create":[{"data":{"number":7002,"id":97002}}]}'

# 実行ヘルパー: スタブ + ログを固定の環境変数セットで渡す
# （呼び出し側で W28_LOG に一時ファイルパスを入れてから使う）
w28_run() {
  OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W28_RESP_CUR" OCTOKIT_STUB_LOG_ENV="$W28_LOG" \
    TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-09-02 \
    node "$ENGINE" run "$@" 2>&1
}

# ── C-1 正常系（許可リストが効いていること・guard が既存の正常入力を誤検知しないこと） ──
# 各ハンドラの一般的な正常系は §W1/§W2/§W5/§W6/§W16 が既に持つため、ここでは
# 「本修正で新たに壊れうる入力」だけに絞る。

# W28-1【許可リスト】`list --group` の初の end-to-end テスト。
# 既存の §28/§28b は list-all 診断サブコマンド + FILTER_*_ENV 経由で、
# `run list --group` を実際に叩くテストは本ケースが最初。
W28_LOG=$(mktemp /tmp/todo-test-w28-1-XXXXXX); W28_RESP_CUR="$W28_LIST_RESP"
W28_1_OUT=$(w28_run list next --group); W28_1_EC=$?
assert_exit_ok "W28-1【許可リスト】list next --group: exit 0" "$W28_1_EC"
assert_eq "W28-1: issues.listForRepo が呼ばれる（フィルタが実行された）" "1" "$(log_count "$W28_LOG" issues.listForRepo)"
rm -f "$W28_LOG"

# W28-2【許可リスト】--no-due
W28_LOG=$(mktemp /tmp/todo-test-w28-2-XXXXXX); W28_RESP_CUR="$W28_LIST_RESP"
W28_2_OUT=$(w28_run list next --no-due); W28_2_EC=$?
assert_exit_ok "W28-2【許可リスト】list next --no-due: exit 0" "$W28_2_EC"
rm -f "$W28_LOG"

# W28-3【許可リスト】--no-estimate
W28_LOG=$(mktemp /tmp/todo-test-w28-3-XXXXXX); W28_RESP_CUR="$W28_LIST_RESP"
W28_3_OUT=$(w28_run list next --no-estimate); W28_3_EC=$?
assert_exit_ok "W28-3【許可リスト】list next --no-estimate: exit 0" "$W28_3_EC"
rm -f "$W28_LOG"

# W28-3b/3c/3d【許可リスト・複合形】`--json` は parseArgs より前に除去され、残りの
# --group / --no-due は許可リストで通る。この2系統の除去が同時に働く形をテストで固定する
# （どちらか一方の実装を変えたときに、複合形だけが壊れるのを検知するため）。
# 引数の順序も入れ替えて確認する（--json は tokens のどこにあっても除去される）。
W28_LOG=$(mktemp /tmp/todo-test-w28-3b-XXXXXX); W28_RESP_CUR="$W28_LIST_RESP"
W28_3B_OUT=$(w28_run list next --json --group); W28_3B_EC=$?
assert_exit_ok "W28-3b【複合形】list next --json --group: exit 0" "$W28_3B_EC"
assert_not_contains "W28-3b: 未知フラグ扱いされていない" "不明なフラグ" "$W28_3B_OUT"
assert_eq "W28-3b: issues.listForRepo が呼ばれる" "1" "$(log_count "$W28_LOG" issues.listForRepo)"
rm -f "$W28_LOG"

W28_LOG=$(mktemp /tmp/todo-test-w28-3c-XXXXXX); W28_RESP_CUR="$W28_LIST_RESP"
W28_3C_OUT=$(w28_run list --group --json next); W28_3C_EC=$?
assert_exit_ok "W28-3c【複合形・順序違い】list --group --json next: exit 0" "$W28_3C_EC"
assert_not_contains "W28-3c: 未知フラグ扱いされていない" "不明なフラグ" "$W28_3C_OUT"
rm -f "$W28_LOG"

W28_LOG=$(mktemp /tmp/todo-test-w28-3d-XXXXXX); W28_RESP_CUR="$W28_LIST_RESP"
W28_3D_OUT=$(w28_run list next --no-due --json); W28_3D_EC=$?
assert_exit_ok "W28-3d【複合形】list next --no-due --json: exit 0" "$W28_3D_EC"
assert_not_contains "W28-3d: 未知フラグ扱いされていない" "不明なフラグ" "$W28_3D_OUT"
rm -f "$W28_LOG"

# W28-4【仕様固定】フラグでない位置引数が extra に残る形（runList だけが持つ構造）。
# 判定を「extra が空でなければエラー」にすると本ケースが壊れる。
W28_LOG=$(mktemp /tmp/todo-test-w28-4-XXXXXX)
W28_RESP_CUR='{"issues.listForRepo":[{"data":[]}],"GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues":[{"data":[]}]}'
W28_4_OUT=$(w28_run list next p1 project 5); W28_4_EC=$?
assert_exit_ok "W28-4【仕様固定】位置引数が extra に残る形(list next p1 project 5): exit 0" "$W28_4_EC"
assert_not_contains "W28-4: 位置引数の余剰は未知フラグ扱いしない" "不明なフラグ" "$W28_4_OUT"
rm -f "$W28_LOG"

# W28-4b【誤検知なし】edit にフラグを7種類まとめて渡しても通ること。
# edit は parsed から10フィールドを読む最も複雑なハンドラで、誤検知の影響が最も広い。
W28_LOG=$(mktemp /tmp/todo-test-w28-4b-XXXXXX); W28_RESP_CUR="$W28_EDIT_RESP"
W28_4B_OUT=$(w28_run edit 42 --due 2026-09-10 --priority p1 --estimate 2h --activate 2026-09-05 --before 2d --desc "説明文" --recur weekly); W28_4B_EC=$?
assert_exit_ok "W28-4b【誤検知なし】edit の既知フラグ7種同時指定: exit 0" "$W28_4B_EC"
assert_contains "W28-4b: 7フィールドすべてが更新される" "due → 2026-09-10" "$W28_4B_OUT"
assert_eq "W28-4b: issues.update が呼ばれる（body 更新）" "1" "$(log_count "$W28_LOG" issues.update)"
rm -f "$W28_LOG"

# W28-5【誤検知なし】done の --actual / --note が従来どおり効くこと
W28_LOG=$(mktemp /tmp/todo-test-w28-5-XXXXXX); W28_RESP_CUR="$W28_DONE_RESP"
W28_5_OUT=$(w28_run done 42 --actual 2h --note "振り返り"); W28_5_EC=$?
assert_exit_ok "W28-5【誤検知なし】done 42 --actual 2h --note: exit 0" "$W28_5_EC"
assert_eq "W28-5: --note がコメントとして投稿される" "1" "$(log_count "$W28_LOG" issues.createComment)"
assert_contains "W28-5: コメント本文が --note の値" '"body":"振り返り"' "$(log_lines_for_method "$W28_LOG" issues.createComment)"
rm -f "$W28_LOG"

# W28-6【誤検知なし】move の --note が従来どおり効くこと
W28_LOG=$(mktemp /tmp/todo-test-w28-6-XXXXXX); W28_RESP_CUR="$W28_MOVE_RESP"
W28_6_OUT=$(w28_run move 42 next --note "降格理由"); W28_6_EC=$?
assert_exit_ok "W28-6【誤検知なし】move 42 next --note: exit 0" "$W28_6_EC"
assert_eq "W28-6: ラベル付与1回" "1" "$(log_count "$W28_LOG" issues.addLabels)"
assert_eq "W28-6: --note がコメントとして投稿される" "1" "$(log_count "$W28_LOG" issues.createComment)"
rm -f "$W28_LOG"

# W28-7【誤検知なし】label add の --color が従来どおり効くこと
W28_LOG=$(mktemp /tmp/todo-test-w28-7-XXXXXX); W28_RESP_CUR="$W28_LABEL_RESP"
W28_7_OUT=$(w28_run label add newctx --color FBCA04); W28_7_EC=$?
assert_exit_ok "W28-7【誤検知なし】label add newctx --color FBCA04: exit 0" "$W28_7_EC"
assert_eq "W28-7: ラベル存在確認(GET) が呼ばれる" "1" "$(log_count "$W28_LOG" 'GET /repos/{owner}/{repo}/labels/{name}')"
rm -f "$W28_LOG"

# W28-7b【誤検知なし・推奨箇所】label list に guard を入れても正常系が壊れないこと
W28_LOG=$(mktemp /tmp/todo-test-w28-7b-XXXXXX); W28_RESP_CUR="$W28_LABEL_LIST_RESP"
W28_7B_OUT=$(w28_run label list); W28_7B_EC=$?
assert_exit_ok "W28-7b【誤検知なし】label list: exit 0" "$W28_7B_EC"
assert_contains "W28-7b: ラベル一覧が表示される" "@office" "$W28_7B_OUT"
rm -f "$W28_LOG"

# ── template 系はテンプレート DB（~/.claude/todo-templates.json）を読み書きするため、
#    実 HOME を汚さない隔離 HOME で実行する（§W3 と同じ方式）。 ──
W28_REAL_HOME="$HOME"
W28_FAKE_HOME=$(mktemp -d /tmp/todo-test-w28-home-XXXXXX)
mkdir -p "$W28_FAKE_HOME/.claude"
printf '%s' '{"daily":{"gtd":"next","context":["@office"],"priority":"p1","due-offset":"1","desc":"日次テンプレの説明"}}' > "$W28_FAKE_HOME/.claude/todo-templates.json"
export HOME="$W28_FAKE_HOME"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  W28_REAL_USERPROFILE="${USERPROFILE:-}"
  export USERPROFILE="$W28_FAKE_HOME"
fi

# W28-8【誤検知なし】template save のインライン引数（--due-offset / --priority）が効くこと
W28_LOG=$(mktemp /tmp/todo-test-w28-8-XXXXXX); W28_RESP_CUR='{}'
W28_8_OUT=$(w28_run template save tmpl next @office --due-offset 3 --priority p1); W28_8_EC=$?
assert_exit_ok "W28-8【誤検知なし】template save tmpl next @office --due-offset 3 --priority p1: exit 0" "$W28_8_EC"
assert_contains "W28-8: テンプレートが保存される" '"due-offset": 3' "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-8b【誤検知なし・推奨箇所】template show に guard を入れても正常系が壊れないこと
W28_LOG=$(mktemp /tmp/todo-test-w28-8b-XXXXXX); W28_RESP_CUR='{}'
W28_8B_OUT=$(w28_run template show daily); W28_8B_EC=$?
assert_exit_ok "W28-8b【誤検知なし】template show daily: exit 0" "$W28_8B_EC"
rm -f "$W28_LOG"

# ── C-2 異常系: パターンB（parseArgs を呼ぶハンドラ） ──

# W28-9【核心】move: 未知フラグでラベル変更に到達しない。
# 上の W28-6 と同じスタブ応答を使う（ガードを外せば exit 0 で成功する状態）。
W28_LOG=$(mktemp /tmp/todo-test-w28-9-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_MOVE_RESP"
W28_9_OUT=$(w28_run move 42 next --boddy-file /tmp/x); W28_9_EC=$?
assert_exit_fail "W28-9【核心】move に未知フラグ: exit非0" "$W28_9_EC"
assert_contains "W28-9: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --boddy-file" "$W28_9_OUT"
assert_eq "W28-9【副作用ゼロ】API 呼び出しログが0行（issues.get/removeLabel/addLabels すべて未到達）" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
assert_not_contains "W28-9: GTD ラベル付与が発生していない（反証）" '"labels":["🎯 next"]' "$(log_lines_for_method "$W28_LOG" issues.addLabels)"
rm -f "$W28_LOG"

# W28-10【核心・ゴミ Issue】template use: パターンA とまったく同型の経路（runAdd を
# 経由せず自前に issues.create を呼ぶ）。修正前は title「--boddy-file /tmp/x」の
# Issue が exit 0 で作られていた。反証アサーションの needle は、ガードを外した状態で
# 実際に出力されるログ行から確定してある。
W28_LOG=$(mktemp /tmp/todo-test-w28-10-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_TMPLUSE_RESP"
W28_10_OUT=$(w28_run template use daily --boddy-file /tmp/x); W28_10_EC=$?
assert_exit_fail "W28-10【核心・ゴミIssue】template use に未知フラグ: exit非0" "$W28_10_EC"
assert_contains "W28-10: エラー本文が未知フラグのもの（成功時の出力にも字面が出るため全文で判定）" "エラー: 不明なフラグです: --boddy-file" "$W28_10_OUT"
assert_eq "W28-10【核心】issues.create は呼ばれない" "0" "$(log_count "$W28_LOG" issues.create)"
assert_not_contains "W28-10【核心・反証】汚染タイトルでの issues.create が発生していない" \
  '"title":"--boddy-file /tmp/x"' "$(log_lines_for_method "$W28_LOG" issues.create)"
rm -f "$W28_LOG"

# W28-16 template save: --due-offset のタイポ。テンプレートファイルが更新されないこと。
W28_16_BEFORE=$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")
W28_LOG=$(mktemp /tmp/todo-test-w28-16-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR='{}'
W28_16_OUT=$(w28_run template save tmpl2 next --due-ofset 3); W28_16_EC=$?
assert_exit_fail "W28-16 template save に未知フラグ(--due-ofset): exit非0" "$W28_16_EC"
assert_contains "W28-16: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --due-ofset" "$W28_16_OUT"
assert_eq "W28-16【副作用ゼロ】テンプレートファイルが更新されていない" "$W28_16_BEFORE" "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-16b【推奨箇所】template show の余剰フラグ（読み取り系だが契約を揃える）
W28_LOG=$(mktemp /tmp/todo-test-w28-16b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR='{}'
W28_16B_OUT=$(w28_run template show daily --json); W28_16B_EC=$?
assert_exit_fail "W28-16b【推奨箇所】template show に未知フラグ(--json): exit非0" "$W28_16B_EC"
assert_contains "W28-16b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --json" "$W28_16B_OUT"
rm -f "$W28_LOG"

# ── template の「名前の位置」（tokens[1]）— レビュー指摘での追加分 ──
# validateName('--foo') は通る（FORBIDDEN_CHARS にハイフンが含まれない）ため、名前位置を
# 検査対象から外すと `template save --foo next` がローカルの todo-templates.json へ
# `--foo` エントリを書き込めてしまう（レビュー中に実際に踏んで手動復旧が必要になった経路）。
# 本ブロックは隔離 HOME 内で実行しているので、実 HOME のファイルには一切触れない。

# W28-35【核心・ローカル DB 汚染】template save の名前位置にフラグ字面
W28_35_BEFORE=$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")
W28_LOG=$(mktemp /tmp/todo-test-w28-35-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR='{}'
W28_35_OUT=$(w28_run template save --foo next); W28_35_EC=$?
assert_exit_fail "W28-35【核心】template save の名前位置に未知フラグ: exit非0" "$W28_35_EC"
assert_contains "W28-35: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --foo" "$W28_35_OUT"
assert_eq "W28-35【核心・副作用ゼロ】テンプレートファイルの内容が変化していない" "$W28_35_BEFORE" "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
assert_not_contains "W28-35【反証】--foo エントリが書き込まれていない" '"--foo"' "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-35b template save from <#> 形式でも名前位置が検査されること（guard は分岐より前）
W28_35B_BEFORE=$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")
W28_LOG=$(mktemp /tmp/todo-test-w28-35b-XXXXXX); : > "$W28_LOG"
W28_RESP_CUR='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[{"name":"🎯 next"}]}}]}'
W28_35B_OUT=$(w28_run template save --foo from 42); W28_35B_EC=$?
assert_exit_fail "W28-35b template save from の名前位置に未知フラグ: exit非0" "$W28_35B_EC"
assert_contains "W28-35b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --foo" "$W28_35B_OUT"
assert_eq "W28-35b【副作用ゼロ】Issue 取得(issues.get)にも到達していない" "0" "$(log_count "$W28_LOG" issues.get)"
assert_eq "W28-35b【副作用ゼロ】テンプレートファイルの内容が変化していない" "$W28_35B_BEFORE" "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-35c【未テストだった guard】template save <name> from <#> の余剰トークン
# （設計 §102-117 の表で「必須」に区分されていながらテストがなかった箇所）
W28_35C_BEFORE=$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")
W28_LOG=$(mktemp /tmp/todo-test-w28-35c-XXXXXX); : > "$W28_LOG"
W28_RESP_CUR='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[{"name":"🎯 next"}]}}]}'
W28_35C_OUT=$(w28_run template save tmpl3 from 42 --note "x"); W28_35C_EC=$?
assert_exit_fail "W28-35c template save from の余剰フラグ: exit非0" "$W28_35C_EC"
assert_contains "W28-35c: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --note" "$W28_35C_OUT"
assert_eq "W28-35c【副作用ゼロ】Issue 取得(issues.get)にも到達していない" "0" "$(log_count "$W28_LOG" issues.get)"
assert_eq "W28-35c【副作用ゼロ】テンプレートファイルの内容が変化していない" "$W28_35C_BEFORE" "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-35d【正常系・スタブ応答の妥当性確認】W28-35c と同じ応答でフラグなしなら exit 0
W28_LOG=$(mktemp /tmp/todo-test-w28-35d-XXXXXX); : > "$W28_LOG"
W28_RESP_CUR='{"issues.get":[{"data":{"number":42,"id":942,"title":"T","body":"","labels":[{"name":"🎯 next"}]}}]}'
W28_35D_OUT=$(w28_run template save tmpl3 from 42); W28_35D_EC=$?
assert_exit_ok "W28-35d【スタブ応答の妥当性】template save tmpl3 from 42（フラグなし）: exit 0" "$W28_35D_EC"
assert_contains "W28-35d: テンプレートが保存される" '"tmpl3"' "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-36 template show の名前位置にフラグ字面（読み取り系だが契約を揃える）
W28_LOG=$(mktemp /tmp/todo-test-w28-36-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR='{}'
W28_36_OUT=$(w28_run template show --foo); W28_36_EC=$?
assert_exit_fail "W28-36 template show の名前位置に未知フラグ: exit非0" "$W28_36_EC"
assert_contains "W28-36: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --foo" "$W28_36_OUT"
rm -f "$W28_LOG"

# W28-37 template delete の名前位置にフラグ字面。
# ガードを外すと exit 0 で「削除しました」と表示されるので、エラー全文で判定する。
W28_37_BEFORE=$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")
W28_LOG=$(mktemp /tmp/todo-test-w28-37-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR='{}'
W28_37_OUT=$(w28_run template delete --foo); W28_37_EC=$?
assert_exit_fail "W28-37 template delete の名前位置に未知フラグ: exit非0" "$W28_37_EC"
assert_contains "W28-37: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --foo" "$W28_37_OUT"
assert_eq "W28-37【副作用ゼロ】テンプレートファイルの内容が変化していない" "$W28_37_BEFORE" "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-37b【未テストだった guard】template delete の余剰トークン
W28_37B_BEFORE=$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")
W28_LOG=$(mktemp /tmp/todo-test-w28-37b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR='{}'
W28_37B_OUT=$(w28_run template delete daily --force); W28_37B_EC=$?
assert_exit_fail "W28-37b template delete の余剰フラグ(--force): exit非0" "$W28_37B_EC"
assert_contains "W28-37b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --force" "$W28_37B_OUT"
assert_eq "W28-37b【副作用ゼロ】daily テンプレートが削除されていない" "$W28_37B_BEFORE" "$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")"
rm -f "$W28_LOG"

# W28-38【核心・ゴミ Issue】template use の名前位置にフラグ字面。
# ガードを外したとき「別の理由（テンプレート未登録）」で exit 1 になると検証にならないため
# （§論点6 罠2）、隔離 HOME のテンプレートファイルへ一時的に「--foo」を直接書き込み、
# 「ガードを外せば exit 0 で issues.create に到達する」状態を作ってから実行する。
W28_38_SAVED=$(cat "$W28_FAKE_HOME/.claude/todo-templates.json")
printf '%s' '{"--foo":{"gtd":"next","context":[],"priority":"p3"}}' > "$W28_FAKE_HOME/.claude/todo-templates.json"
W28_LOG=$(mktemp /tmp/todo-test-w28-38-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_TMPLUSE_RESP"
W28_38_OUT=$(w28_run template use --foo); W28_38_EC=$?
assert_exit_fail "W28-38【核心・ゴミIssue】template use の名前位置に未知フラグ: exit非0" "$W28_38_EC"
assert_contains "W28-38: エラー本文が未知フラグのもの（未登録エラーではない）" "エラー: 不明なフラグです: --foo" "$W28_38_OUT"
assert_eq "W28-38【核心】issues.create は呼ばれない" "0" "$(log_count "$W28_LOG" issues.create)"
rm -f "$W28_LOG"

# W28-38b【正常系・スタブ応答の妥当性確認】同じテンプレート・同じ応答で、名前を
# フラグ字面でない形に変えれば exit 0 で Issue が作られること（ガードを外すと W28-38 が
# この状態になる、ということの証明）
printf '%s' '{"foo":{"gtd":"next","context":[],"priority":"p3"}}' > "$W28_FAKE_HOME/.claude/todo-templates.json"
W28_LOG=$(mktemp /tmp/todo-test-w28-38b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_TMPLUSE_RESP"
W28_38B_OUT=$(w28_run template use foo); W28_38B_EC=$?
assert_exit_ok "W28-38b【スタブ応答の妥当性】template use foo（フラグ字面でない名前）: exit 0" "$W28_38B_EC"
assert_eq "W28-38b: issues.create が1回呼ばれる" "1" "$(log_count "$W28_LOG" issues.create)"
rm -f "$W28_LOG"
printf '%s' "$W28_38_SAVED" > "$W28_FAKE_HOME/.claude/todo-templates.json"

# W28-25【入力文字】template use のタイトル上書きで Markdown 水平線を誤検知しないこと
W28_LOG=$(mktemp /tmp/todo-test-w28-25-XXXXXX); W28_RESP_CUR="$W28_TMPLUSE_RESP"
W28_25_OUT=$(w28_run template use daily "--- 区切り線 --- を含むタイトル"); W28_25_EC=$?
assert_exit_ok "W28-25【入力文字】template use のタイトルに Markdown 水平線: exit 0" "$W28_25_EC"
assert_contains "W28-25: title がそのまま" '"title":"--- 区切り線 --- を含むタイトル"' "$(log_lines_for_method "$W28_LOG" issues.create)"
rm -f "$W28_LOG"

# W28-30【セキュリティ】template use のタイトル上書きでコマンド置換が起きないこと
W28_LOG=$(mktemp /tmp/todo-test-w28-30-XXXXXX); W28_RESP_CUR="$W28_TMPLUSE_RESP"
W28_30_OUT=$(w28_run template use daily '$(whoami) を含むタイトル'); W28_30_EC=$?
assert_exit_ok "W28-30【セキュリティ】template use のタイトルにコマンド置換の形: exit 0" "$W28_30_EC"
assert_contains "W28-30: title が \$(whoami) のリテラル（展開されていない）" '"title":"$(whoami) を含むタイトル"' "$(log_lines_for_method "$W28_LOG" issues.create)"
rm -f "$W28_LOG"

# 隔離 HOME を元に戻す
export HOME="$W28_REAL_HOME"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  export USERPROFILE="${W28_REAL_USERPROFILE:-}"
fi
rm -rf "$W28_FAKE_HOME"

# W28-11 done: 未知フラグで Issue 取得にも到達しない
W28_LOG=$(mktemp /tmp/todo-test-w28-11-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_DONE_RESP"
W28_11_OUT=$(w28_run done 42 --boddy-file /tmp/x); W28_11_EC=$?
assert_exit_fail "W28-11 done に未知フラグ: exit非0" "$W28_11_EC"
assert_contains "W28-11: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --boddy-file" "$W28_11_OUT"
assert_eq "W28-11【副作用ゼロ】API 呼び出しログが0行（close に到達していない）" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# ── edit は parsed から10フィールドを読む最も複雑なハンドラなので、失敗の型ごとにケースを持つ。
#    (1) 短いフラグのタイポ (2) ハイフン付き長いフラグのタイポ (3) 値欠落（フラグごとに別トークン列） ──

# W28-12 edit: --due のタイポ
W28_LOG=$(mktemp /tmp/todo-test-w28-12-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_EDIT_RESP"
W28_12_OUT=$(w28_run edit 42 --duee 2026-09-10); W28_12_EC=$?
assert_exit_fail "W28-12 edit に未知フラグ(--duee タイポ): exit非0" "$W28_12_EC"
assert_contains "W28-12: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --duee" "$W28_12_OUT"
assert_eq "W28-12【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-12b edit: --priority のタイポ（優先度ラベルの付け替えという別の副作用経路）
W28_LOG=$(mktemp /tmp/todo-test-w28-12b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_EDIT_RESP"
W28_12B_OUT=$(w28_run edit 42 --priorityy p1); W28_12B_EC=$?
assert_exit_fail "W28-12b edit に未知フラグ(--priorityy タイポ): exit非0" "$W28_12B_EC"
assert_contains "W28-12b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --priorityy" "$W28_12B_OUT"
# API ログ全体で判定する。「addLabels が0回」だけを見ると、ガードを外しても --priorityy は
# parseArgs に消費されず parsed.priority が null のままなので addLabels は元々0回になり、
# 何も検証しないアサーションになる（W28-R6 の実測で発覚し書き換えた）。
assert_eq "W28-12b【副作用ゼロ】API 呼び出しログが0行（Issue 取得にも到達していない）" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-12c edit: ハイフンを含む長いフラグのタイポ（--resume-condition）。
# UNKNOWN_FLAG_RE の [A-Za-z0-9-]* 部分がハイフン付きフラグでも効くことの確認を兼ねる。
W28_LOG=$(mktemp /tmp/todo-test-w28-12c-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_EDIT_RESP"
W28_12C_OUT=$(w28_run edit 42 --resume-conditon "承認が下りたら"); W28_12C_EC=$?
assert_exit_fail "W28-12c edit に未知フラグ(--resume-conditon タイポ): exit非0" "$W28_12C_EC"
assert_contains "W28-12c: エラー本文が未知フラグのもの（ハイフン付きフラグ名も正しく報告される）" "エラー: 不明なフラグです: --resume-conditon" "$W28_12C_OUT"
assert_eq "W28-12c【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-13 edit: 値が欠落した既知フラグ（末尾の --due。parseArgs の i+1 条件を満たさず extra に残る）
W28_LOG=$(mktemp /tmp/todo-test-w28-13-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_EDIT_RESP"
W28_13_OUT=$(w28_run edit 42 --due); W28_13_EC=$?
assert_exit_fail "W28-13 edit の値欠落フラグ(末尾の --due): exit非0" "$W28_13_EC"
assert_contains "W28-13: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --due" "$W28_13_OUT"
assert_eq "W28-13【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-13b edit: 別のフラグでの値欠落（--activate）。他フラグが先に指定されていても検出すること。
W28_LOG=$(mktemp /tmp/todo-test-w28-13b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_EDIT_RESP"
W28_13B_OUT=$(w28_run edit 42 --due 2026-09-10 --activate); W28_13B_EC=$?
assert_exit_fail "W28-13b edit の値欠落フラグ(有効フラグの後に末尾 --activate): exit非0" "$W28_13B_EC"
assert_contains "W28-13b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --activate" "$W28_13B_OUT"
assert_eq "W28-13b【副作用ゼロ】--due だけが適用されて保存される、ということが起きていない" "0" "$(log_count "$W28_LOG" issues.update)"
rm -f "$W28_LOG"

# W28-14 list: 未知フラグでフィルタが黙って無視されない。
# ガードを外すと exit 0 で全件表示されるため、exit code だけでなく API 0回も見る
# （ガードの目的は「検査を副作用より前に置く」ことなので、exit code だけでは順序を検証できない）。
W28_LOG=$(mktemp /tmp/todo-test-w28-14-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LIST_RESP"
W28_14_OUT=$(w28_run list next --no-duee); W28_14_EC=$?
assert_exit_fail "W28-14 list に未知フラグ(--no-duee): exit非0" "$W28_14_EC"
assert_contains "W28-14: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --no-duee" "$W28_14_OUT"
assert_eq "W28-14【副作用ゼロ】issues.listForRepo は呼ばれない（一覧取得より前で落ちる）" "0" "$(log_count "$W28_LOG" issues.listForRepo)"
rm -f "$W28_LOG"

# W28-15 label add: 英国綴りのタイポ（--colour）
W28_LOG=$(mktemp /tmp/todo-test-w28-15-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_RESP"
W28_15_OUT=$(w28_run label add newctx --colour FBCA04); W28_15_EC=$?
assert_exit_fail "W28-15 label add に未知フラグ(--colour 英国綴り): exit非0" "$W28_15_EC"
assert_contains "W28-15: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --colour" "$W28_15_OUT"
assert_eq "W28-15【副作用ゼロ】ラベル作成の GET/POST に到達していない" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-15b【推奨箇所】label list の余剰フラグ（読み取り系だが契約を揃える）
W28_LOG=$(mktemp /tmp/todo-test-w28-15b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_LIST_RESP"
W28_15B_OUT=$(w28_run label list --json); W28_15B_EC=$?
assert_exit_fail "W28-15b【推奨箇所】label list に未知フラグ(--json): exit非0" "$W28_15B_EC"
assert_contains "W28-15b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --json" "$W28_15B_OUT"
assert_eq "W28-15b: issues.listLabelsForRepo は呼ばれない" "0" "$(log_count "$W28_LOG" issues.listLabelsForRepo)"
rm -f "$W28_LOG"

# ── label の「名前の位置」（tokens[1]）— レビュー指摘での追加分 ──
# 設計時は「位置1にフラグ字面が来たら既存バリデータが loud に落とす」と一般化していたが、
# それが確認されていたのは due / recur / link / priority の4件だけだった。
# label / template ではこの一般化が成立しない: FORBIDDEN_CHARS（ファイル冒頭）に
# ハイフンが含まれないため validateCtx('--foo') / validateName('--foo') が通ってしまう。
# label add は GitHub 上に手動削除の要るゴミラベルを残すので、template use のゴミ Issue と
# 同じ「不可逆な副作用」区分に属する。

# W28-31【核心・ゴミラベル】label add の名前位置にフラグ字面。
# スタブは「そのラベルはまだ存在しない」（GET が 404）を返す形にしてある。W28-7 の応答
# （GET が 200 = 既存）を使い回すと、ガードを外しても ensureLabel は GET だけで return し
# createLabel に到達しないため、「createLabel が0回」が何も検証しないアサーションになる
# （§W28-12b と同型の罠。DEVELOPMENT.md の「罠3」を参照）。ここでは実際にゴミラベルが
# 作られる状態を用意したうえで、0回であることを確認する。
W28_LOG=$(mktemp /tmp/todo-test-w28-31-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_NEW_RESP"
W28_31_OUT=$(w28_run label add --boddy-file); W28_31_EC=$?
assert_exit_fail "W28-31【核心・ゴミラベル】label add の名前位置に未知フラグ: exit非0" "$W28_31_EC"
assert_contains "W28-31: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --boddy-file" "$W28_31_OUT"
assert_eq "W28-31【核心】issues.createLabel は呼ばれない（ゴミラベルが作られない）" "0" "$(log_count "$W28_LOG" issues.createLabel)"
assert_eq "W28-31【核心】ラベル存在確認(request/GET labels)にも到達していない" "0" "$(log_count "$W28_LOG" 'GET /repos/{owner}/{repo}/labels/{name}')"
assert_eq "W28-31【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
assert_not_contains "W28-31【反証】@--boddy-file というラベル名が API へ渡っていない" '"name":"@--boddy-file"' "$(cat "$W28_LOG")"
rm -f "$W28_LOG"

# W28-31b【正常系・スタブ応答の妥当性確認】同じ応答（GET が 404）でフラグ字面でない名前なら
# exit 0 で createLabel が実際に1回呼ばれること。これが成り立つので W28-31 の
# 「createLabel が0回」はガードを検証していることになる（§論点6 罠2）。
W28_LOG=$(mktemp /tmp/todo-test-w28-31b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_NEW_RESP"
W28_31B_OUT=$(w28_run label add newctx2); W28_31B_EC=$?
assert_exit_ok "W28-31b【スタブ応答の妥当性】label add newctx2（フラグ字面でない名前）: exit 0" "$W28_31B_EC"
assert_eq "W28-31b: issues.createLabel が1回呼ばれる" "1" "$(log_count "$W28_LOG" issues.createLabel)"
rm -f "$W28_LOG"

# W28-32 label delete の名前位置にフラグ字面（誤って実在ラベルを消す事故は起きないが、
# 契約を label add と揃える。ガードを外すと deleteLabel が実際に呼ばれる）
W28_LOG=$(mktemp /tmp/todo-test-w28-32-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_DEL_RESP"
W28_32_OUT=$(w28_run label delete --foo); W28_32_EC=$?
assert_exit_fail "W28-32 label delete の名前位置に未知フラグ: exit非0" "$W28_32_EC"
assert_contains "W28-32: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --foo" "$W28_32_OUT"
assert_eq "W28-32【副作用ゼロ】issues.deleteLabel は呼ばれない" "0" "$(log_count "$W28_LOG" issues.deleteLabel)"
rm -f "$W28_LOG"

# W28-32b【正常系・スタブ応答の妥当性確認】同じ応答でフラグなしなら exit 0（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-32b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_DEL_RESP"
W28_32B_OUT=$(w28_run label delete oldctx); W28_32B_EC=$?
assert_exit_ok "W28-32b【スタブ応答の妥当性】label delete oldctx（フラグなし）: exit 0" "$W28_32B_EC"
assert_eq "W28-32b: issues.deleteLabel が1回呼ばれる" "1" "$(log_count "$W28_LOG" issues.deleteLabel)"
rm -f "$W28_LOG"

# W28-33【核心・不可逆】label rename の old 位置にフラグ字面。
# rename は「@new を作って @old を消す」操作なので、どちらの位置が汚染されても
# 既存ラベルの削除という不可逆な副作用になる。
W28_LOG=$(mktemp /tmp/todo-test-w28-33-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_REN_RESP"
W28_33_OUT=$(w28_run label rename --foo newctx); W28_33_EC=$?
assert_exit_fail "W28-33【核心】label rename の old 位置に未知フラグ: exit非0" "$W28_33_EC"
assert_contains "W28-33: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --foo" "$W28_33_OUT"
assert_eq "W28-33【核心】ラベル削除に到達していない" "0" "$(log_count "$W28_LOG" issues.deleteLabel)"
assert_eq "W28-33【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-34【核心・不可逆】label rename の new 位置にフラグ字面（@--bar というゴミラベルを
# 作ったうえで実在の @oldctx を削除する、という最も損害の大きい形）
W28_LOG=$(mktemp /tmp/todo-test-w28-34-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_REN_RESP"
W28_34_OUT=$(w28_run label rename oldctx --bar); W28_34_EC=$?
assert_exit_fail "W28-34【核心】label rename の new 位置に未知フラグ: exit非0" "$W28_34_EC"
assert_contains "W28-34: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --bar" "$W28_34_OUT"
assert_eq "W28-34【核心】@oldctx の削除に到達していない" "0" "$(log_count "$W28_LOG" issues.deleteLabel)"
assert_not_contains "W28-34【反証】@--bar というゴミラベルが作られていない" '"name":"@--bar"' "$(cat "$W28_LOG")"
rm -f "$W28_LOG"

# W28-34b【正常系・スタブ応答の妥当性確認】同じ応答でフラグなしなら exit 0（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-34b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LABEL_REN_RESP"
W28_34B_OUT=$(w28_run label rename oldctx newctx); W28_34B_EC=$?
assert_exit_ok "W28-34b【スタブ応答の妥当性】label rename oldctx newctx（フラグなし）: exit 0" "$W28_34B_EC"
assert_eq "W28-34b: 旧ラベルの削除が1回呼ばれる" "1" "$(log_count "$W28_LOG" issues.deleteLabel)"
rm -f "$W28_LOG"

# ── W28-34c/d/e  tag rename（label rename と同じ renameCtxLabel を共用する第2の入口） ──
# runTag の rename 分岐は renameCtxLabel を label rename とまったく同じ引数で呼ぶ。
# W28-33/34 のガードは runLabel 側にあるため tag 経由では素通りし、@--foo というゴミラベルを
# 作ったうえで実在の @oldctx を削除できてしまう（label rename と実害が同一）。
# 対策は runTag ではなく renameCtxLabel の冒頭に guardUnknownFlag を1つ置く形で、
# 両経路を同時に塞いでいる。runLabel rename 側の既存ガードは
# 「余剰トークン」をカバーするため残してある（renameCtxLabel は raw1/raw2 しか見えない）。

# W28-34c【核心・不可逆】tag rename の old 位置にフラグ字面
W28_LOG=$(mktemp /tmp/todo-test-w28-34c-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_TAG_REN_RESP"
W28_34C_OUT=$(w28_run tag rename --foo newctx); W28_34C_EC=$?
assert_exit_fail "W28-34c【核心】tag rename の old 位置に未知フラグ: exit非0" "$W28_34C_EC"
assert_contains "W28-34c: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --foo" "$W28_34C_OUT"
assert_eq "W28-34c【核心】既存ラベルの削除に到達していない（deleteLabel 0回）" "0" "$(log_count "$W28_LOG" issues.deleteLabel)"
assert_eq "W28-34c【核心】ラベル付け替えに到達していない（addLabels 0回）" "0" "$(log_count "$W28_LOG" issues.addLabels)"
assert_eq "W28-34c【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-34d【核心・不可逆】tag rename の new 位置にフラグ字面（@--bar を作ったうえで
# 実在の @oldctx を削除する、最も損害の大きい形）
W28_LOG=$(mktemp /tmp/todo-test-w28-34d-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_TAG_REN_RESP"
W28_34D_OUT=$(w28_run tag rename oldctx --bar); W28_34D_EC=$?
assert_exit_fail "W28-34d【核心】tag rename の new 位置に未知フラグ: exit非0" "$W28_34D_EC"
assert_contains "W28-34d: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --bar" "$W28_34D_OUT"
assert_eq "W28-34d【核心】@oldctx の削除に到達していない（deleteLabel 0回）" "0" "$(log_count "$W28_LOG" issues.deleteLabel)"
assert_eq "W28-34d【核心】ラベル付け替えに到達していない（addLabels 0回）" "0" "$(log_count "$W28_LOG" issues.addLabels)"
assert_not_contains "W28-34d【反証】@--bar というゴミラベルが API へ渡っていない" '"name":"@--bar"' "$(cat "$W28_LOG")"
rm -f "$W28_LOG"

# W28-34e【正常系・スタブ応答の妥当性確認】同じ応答でフラグなしなら exit 0 になり、
# deleteLabel / addLabels が実際に1回ずつ呼ばれる。これが成り立つので W28-34c/d の
# 「0回」はガードを検証していることになる（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-34e-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_TAG_REN_RESP"
W28_34E_OUT=$(w28_run tag rename oldctx newctx); W28_34E_EC=$?
assert_exit_ok "W28-34e【スタブ応答の妥当性】tag rename oldctx newctx（フラグなし）: exit 0" "$W28_34E_EC"
assert_eq "W28-34e: 旧ラベルの削除が1回呼ばれる" "1" "$(log_count "$W28_LOG" issues.deleteLabel)"
assert_eq "W28-34e: 新ラベルの付与が1回呼ばれる" "1" "$(log_count "$W28_LOG" issues.addLabels)"
rm -f "$W28_LOG"

# W28-17【核心】bulk move: 単体 move と違い --note は効かない（rest[0] しか読まない）。
# ガードは per-issue ループの外にあり、1件目の処理にも入らないこと。
# bulk.item_error（per-item エラーとして握りつぶす経路）に落ちていないことも確認する。
W28_LOG=$(mktemp /tmp/todo-test-w28-17-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_BULKMOVE_RESP"
W28_17_OUT=$(w28_run bulk move 41 42 next --note "x"); W28_17_EC=$?
assert_exit_fail "W28-17【核心】bulk move に未知フラグ: exit非0" "$W28_17_EC"
assert_contains "W28-17: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --note" "$W28_17_OUT"
assert_eq "W28-17【副作用ゼロ】API 呼び出しログが0行（1件目の処理にも入っていない）" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
assert_not_contains "W28-17: per-item エラーとして握りつぶされていない（サマリー行が出ない）" "件を" "$W28_17_OUT"
rm -f "$W28_LOG"

# W28-17b【正常系・スタブ応答の妥当性確認】W28-17 と同じ応答でフラグなしなら exit 0（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-17b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_BULKMOVE_RESP"
W28_17B_OUT=$(w28_run bulk move 41 42 next); W28_17B_EC=$?
assert_exit_ok "W28-17b【スタブ応答の妥当性】bulk move 41 42 next（フラグなし）: exit 0" "$W28_17B_EC"
assert_eq "W28-17b: 2件ともラベル付与される" "2" "$(log_count "$W28_LOG" issues.addLabels)"
rm -f "$W28_LOG"

# W28-18 bulk done: parseArgs をループ外へ巻き上げた箇所の検証
W28_LOG=$(mktemp /tmp/todo-test-w28-18-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_BULKDONE_RESP"
W28_18_OUT=$(w28_run bulk done 41 42 --boddy-file /tmp/x); W28_18_EC=$?
assert_exit_fail "W28-18 bulk done に未知フラグ: exit非0" "$W28_18_EC"
assert_contains "W28-18: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --boddy-file" "$W28_18_OUT"
assert_eq "W28-18【副作用ゼロ】API 呼び出しログが0行（1件も close されていない）" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-18c【正常系・スタブ応答の妥当性確認】W28-18 と同じ応答でフラグなしなら exit 0（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-18c-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_BULKDONE_RESP"
W28_18C_OUT=$(w28_run bulk done 41 42); W28_18C_EC=$?
assert_exit_ok "W28-18c【スタブ応答の妥当性】bulk done 41 42（フラグなし）: exit 0" "$W28_18C_EC"
assert_eq "W28-18c: 2件とも close される（issues.update ×2）" "2" "$(log_count "$W28_LOG" issues.update)"
rm -f "$W28_LOG"

# W28-18b bulk priority: rest.slice(1) の余剰フラグ
W28_LOG=$(mktemp /tmp/todo-test-w28-18b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_BULKPRI_RESP"
W28_18B_OUT=$(w28_run bulk priority 41 42 p1 --note "x"); W28_18B_EC=$?
assert_exit_fail "W28-18b bulk priority に未知フラグ: exit非0" "$W28_18B_EC"
assert_contains "W28-18b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --note" "$W28_18B_OUT"
assert_eq "W28-18b【副作用ゼロ】優先度ラベル作成(ensureLabel)に到達していない" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-18d【正常系・スタブ応答の妥当性確認】W28-18b と同じ応答でフラグなしなら exit 0（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-18d-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_BULKPRI_RESP"
W28_18D_OUT=$(w28_run bulk priority 41 42 p1); W28_18D_EC=$?
assert_exit_ok "W28-18d【スタブ応答の妥当性】bulk priority 41 42 p1（フラグなし）: exit 0" "$W28_18D_EC"
assert_eq "W28-18d: 2件とも優先度ラベルが付与される" "2" "$(log_count "$W28_LOG" issues.addLabels)"
rm -f "$W28_LOG"

# ── C-3 異常系: パターンC（parseArgs を通らず固定インデックスで読むハンドラ） ──
# 位置1（tokens[1]）にフラグ字面が来た場合は既存バリデータ（validateDue / validateRecur /
# parseInt / validatePriority）が既に loud に落とすため、新たに塞ぐのは slice(2) 以降だけ。

# W28-19 due: `due 42 2026-09-10 --note "理由"` の --note は従来黙って捨てられていた
W28_LOG=$(mktemp /tmp/todo-test-w28-19-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_SIMPLE_RESP"
W28_19_OUT=$(w28_run due 42 2026-09-10 --note "理由"); W28_19_EC=$?
assert_exit_fail "W28-19 due の余剰フラグ(--note): exit非0" "$W28_19_EC"
assert_contains "W28-19: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --note" "$W28_19_OUT"
assert_eq "W28-19【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-19b【後方互換】位置引数の余剰（`due 42 今週 金曜`）は従来どおり通る。
# 手順書に日本語日付の未クォート運用が実在するため、本Issueでは塞がない（第3弾送り）。
W28_LOG=$(mktemp /tmp/todo-test-w28-19b-XXXXXX); W28_RESP_CUR="$W28_SIMPLE_RESP"
W28_19B_OUT=$(w28_run due 42 2026-09-10 余剰トークン); W28_19B_EC=$?
assert_exit_ok "W28-19b【後方互換・仕様固定】位置引数の余剰は従来どおり通る: exit 0" "$W28_19B_EC"
assert_eq "W28-19b: 期日が設定される" "1" "$(log_count "$W28_LOG" issues.update)"
rm -f "$W28_LOG"

# W28-20 recur
W28_LOG=$(mktemp /tmp/todo-test-w28-20-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_SIMPLE_RESP"
W28_20_OUT=$(w28_run recur 42 weekly --note "x"); W28_20_EC=$?
assert_exit_fail "W28-20 recur の余剰フラグ(--note): exit非0" "$W28_20_EC"
assert_contains "W28-20: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --note" "$W28_20_OUT"
assert_eq "W28-20【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-20b【正常系・スタブ応答の妥当性確認】W28-20 と同じ応答でフラグなしなら exit 0（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-20b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_SIMPLE_RESP"
W28_20B_OUT=$(w28_run recur 42 weekly); W28_20B_EC=$?
assert_exit_ok "W28-20b【スタブ応答の妥当性】recur 42 weekly（フラグなし）: exit 0" "$W28_20B_EC"
assert_eq "W28-20b: recur が保存される（issues.update 1回）" "1" "$(log_count "$W28_LOG" issues.update)"
rm -f "$W28_LOG"

# W28-21 link（ガードを外すと issues.get を2回呼ぶ。スタブ応答は W28_LINK_RESP で
# `link 42 100` が exit 0 になることを確認済みのものを使い回している）
W28_LOG=$(mktemp /tmp/todo-test-w28-21-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_LINK_RESP"
W28_21_OUT=$(w28_run link 42 100 --note "x"); W28_21_EC=$?
assert_exit_fail "W28-21 link の余剰フラグ(--note): exit非0" "$W28_21_EC"
assert_contains "W28-21: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --note" "$W28_21_OUT"
assert_eq "W28-21【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-21b【正常系・スタブ応答の妥当性確認】W28-21 と同じ応答でフラグなしなら exit 0 になること。
# これが exit 0 でないと W28-21 の assert_exit_fail は「ガードを外しても PASS」になる（§論点6 罠2）。
W28_LOG=$(mktemp /tmp/todo-test-w28-21b-XXXXXX); W28_RESP_CUR="$W28_LINK_RESP"
W28_21B_OUT=$(w28_run link 42 100); W28_21B_EC=$?
assert_exit_ok "W28-21b【スタブ応答の妥当性】link 42 100（フラグなし）: exit 0" "$W28_21B_EC"
rm -f "$W28_LOG"

# W28-22 priority
W28_LOG=$(mktemp /tmp/todo-test-w28-22-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_PRI_RESP"
W28_22_OUT=$(w28_run priority 42 p1 --note "x"); W28_22_EC=$?
assert_exit_fail "W28-22 priority の余剰フラグ(--note): exit非0" "$W28_22_EC"
assert_contains "W28-22: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --note" "$W28_22_OUT"
assert_eq "W28-22【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-22a【正常系・スタブ応答の妥当性確認】W28-22 と同じ応答でフラグなしなら exit 0（§論点6 罠2）
W28_LOG=$(mktemp /tmp/todo-test-w28-22a-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_PRI_RESP"
W28_22A_OUT=$(w28_run priority 42 p1); W28_22A_EC=$?
assert_exit_ok "W28-22a【スタブ応答の妥当性】priority 42 p1（フラグなし）: exit 0" "$W28_22A_EC"
assert_eq "W28-22a: 優先度ラベルが付与される" "1" "$(log_count "$W28_LOG" issues.addLabels)"
rm -f "$W28_LOG"

# W28-22b【核心・元タイトル喪失】rename: tokens.slice(1) をそのまま新タイトルにするため、
# 修正前は `rename 42 --boddy-file /tmp/x` が既存タイトルを「--boddy-file /tmp/x」で
# 上書きしていた（exit 0）。add のゴミ Issue と違い元タイトルが復旧できない。
# issues.update が0回であること＝元タイトルが失われていないこと。
W28_LOG=$(mktemp /tmp/todo-test-w28-22b-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_RENAME_RESP"
W28_22B_OUT=$(w28_run rename 42 --boddy-file /tmp/x); W28_22B_EC=$?
assert_exit_fail "W28-22b【核心】rename に未知フラグ: exit非0" "$W28_22B_EC"
assert_contains "W28-22b: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --boddy-file" "$W28_22B_OUT"
assert_eq "W28-22b【核心・元タイトル喪失の防止】issues.update は0回（既存タイトルが上書きされていない）" "0" "$(log_count "$W28_LOG" issues.update)"
assert_not_contains "W28-22b【反証】汚染タイトルでの issues.update が発生していない" \
  '"title":"--boddy-file /tmp/x"' "$(log_lines_for_method "$W28_LOG" issues.update)"
rm -f "$W28_LOG"

# W28-22c【正常系・スタブ応答の妥当性確認】W28-22b と同じ応答でフラグなしなら exit 0 になること
W28_LOG=$(mktemp /tmp/todo-test-w28-22c-XXXXXX); W28_RESP_CUR="$W28_RENAME_RESP"
W28_22C_OUT=$(w28_run rename 42 新しいタイトル); W28_22C_EC=$?
assert_exit_ok "W28-22c【スタブ応答の妥当性】rename 42 <タイトル>（フラグなし）: exit 0" "$W28_22C_EC"
assert_contains "W28-22c: タイトルが更新される" '"title":"新しいタイトル"' "$(log_lines_for_method "$W28_LOG" issues.update)"
rm -f "$W28_LOG"

# W28-22d desc: rename と同型（tokens.slice(1) を連結して desc へ追記する）
W28_LOG=$(mktemp /tmp/todo-test-w28-22d-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_SIMPLE_RESP"
W28_22D_OUT=$(w28_run desc 42 --boddy-file /tmp/x); W28_22D_EC=$?
assert_exit_fail "W28-22d desc に未知フラグ: exit非0" "$W28_22D_EC"
assert_contains "W28-22d: エラー本文が未知フラグのもの" "エラー: 不明なフラグです: --boddy-file" "$W28_22D_OUT"
assert_contains "W28-22d: ヒント行が本文向け（desc の自由記述は本文）" "本文全体を1つの引数としてクォート" "$W28_22D_OUT"
assert_eq "W28-22d【副作用ゼロ】API 呼び出しログが0行" "0" "$(wc -l < "$W28_LOG" | tr -d ' ')"
rm -f "$W28_LOG"

# W28-22e【正常系・スタブ応答の妥当性確認】W28-22d と同じ応答でフラグなしなら exit 0 になること
W28_LOG=$(mktemp /tmp/todo-test-w28-22e-XXXXXX); W28_RESP_CUR="$W28_SIMPLE_RESP"
W28_22E_OUT=$(w28_run desc 42 追記する説明); W28_22E_EC=$?
assert_exit_ok "W28-22e【スタブ応答の妥当性】desc 42 <テキスト>（フラグなし）: exit 0" "$W28_22E_EC"
rm -f "$W28_LOG"

# ── C-4 i18n ──
#
# 【W28-23 / W28-24 の3つの補助アサーションについて（読み手向けの注記）】
# 下記のうち W28-23 の assert_no_japanese と W28-24 の assert_not_contains ×2 は、
# ガードを取り除いた状態でも PASS したままになる（成功時の英語出力にも日本語は含まれず、
# 成功時の出力にもタイトル向け・本文向けのヒント文言は現れないため）。これは意図した設計で、
# この3つが見ているのは「ガードが存在すること」ではなく「**ガードが発火したときの**出力が
# en で日本語混じりでないこと / ヒントキーの配線が正しいこと」という別の性質である。
# ガードの存在自体は、同じケース内の assert_exit_fail と assert_contains（エラー全文）が
# 担保しており、ガード除去実験ではケース全体として FAIL する。1つのアサーションに
# 2つの役割を負わせないための分担なので、回帰検出器として読み替えないこと。

# W28-23 英語モード: 日本語が1文字も出ないこと
W28_LOG=$(mktemp /tmp/todo-test-w28-23-XXXXXX); : > "$W28_LOG"
W28_23_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W28_MOVE_RESP" OCTOKIT_STUB_LOG_ENV="$W28_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo LANG_ENV=en \
  node "$ENGINE" run move 42 next --boddy-file /tmp/x 2>&1); W28_23_EC=$?
assert_exit_fail "W28-23 i18n(en) move の未知フラグ: exit非0" "$W28_23_EC"
assert_contains "W28-23: 英語のエラー本文" "Error: unknown flag: --boddy-file" "$W28_23_OUT"
assert_contains "W28-23: 英語のヒント行（options 版）" "run /todo help to see the options" "$W28_23_OUT"
assert_contains "W28-23: Usage 行（常時英語）" "Usage: /todo move <#> <GTD>" "$W28_23_OUT"
assert_no_japanese "W28-23: 出力に日本語が1文字も含まれない" "$W28_23_OUT"
rm -f "$W28_LOG"

# W28-24 日本語モード: ヒント行が options 版であること（タイトル向け／本文向けの誤配線を排除）
W28_LOG=$(mktemp /tmp/todo-test-w28-24-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR="$W28_MOVE_RESP"
W28_24_OUT=$(w28_run move 42 next --boddy-file /tmp/x); W28_24_EC=$?
assert_exit_fail "W28-24 i18n(ja) move の未知フラグ: exit非0" "$W28_24_EC"
assert_contains "W28-24: ヒント行が options 版" "このコマンドで使えるオプションは /todo help" "$W28_24_OUT"
assert_not_contains "W28-24: タイトル向けヒントが誤配線されていない" "タイトル全体を1つの引数" "$W28_24_OUT"
assert_not_contains "W28-24: 本文向けヒントが誤配線されていない" "本文全体を1つの引数" "$W28_24_OUT"
rm -f "$W28_LOG"

# ── C-5 入力文字パターン（template use のケースは隔離 HOME ブロック内の W28-25/30 を参照） ──

# W28-26【入力文字】--note の値は parseArgs が消費するため guard に到達しない
W28_LOG=$(mktemp /tmp/todo-test-w28-26-XXXXXX); W28_RESP_CUR="$W28_DONE_RESP"
W28_26_OUT=$(w28_run done 42 --note "--- 区切り線 ---"); W28_26_EC=$?
assert_exit_ok "W28-26【入力文字】--note の値が Markdown 水平線でも通る: exit 0" "$W28_26_EC"
assert_contains "W28-26: コメント本文が水平線テキストそのまま" '"body":"--- 区切り線 ---"' "$(log_lines_for_method "$W28_LOG" issues.createComment)"
rm -f "$W28_LOG"

# ── C-6 境界値 ──

# W28-27【設計判断の固定】bulk tag / untag には guard を入れない。
# normalizeTagTokens（#1686）が既に `-` 始まりトークンを loud に落としており、
# guard を足すとメッセージが変わる。従来の「オプション指定に見えます」が出続けること。
W28_LOG=$(mktemp /tmp/todo-test-w28-27-XXXXXX); : > "$W28_LOG"; W28_RESP_CUR='{}'
W28_27_OUT=$(w28_run bulk tag 6101 6102 -- @本業); W28_27_EC=$?
assert_exit_fail "W28-27【設計判断の固定】bulk tag に -- を渡す: exit非0（従来どおり）" "$W28_27_EC"
assert_contains "W28-27: 従来の option_like_token エラーが出る" "オプション指定に見えます" "$W28_27_OUT"
assert_not_contains "W28-27: 未知フラグエラーに置き換わっていない（tag に guard を入れない設計判断）" "不明なフラグ" "$W28_27_OUT"
rm -f "$W28_LOG"

# W28-28【境界】--json は runList が parseArgs より前に除去するため guard に到達しない
# （だから許可リストにも入れていない）
W28_LOG=$(mktemp /tmp/todo-test-w28-28-XXXXXX); W28_RESP_CUR="$W28_LIST_RESP"
W28_28_OUT=$(w28_run list --json); W28_28_EC=$?
assert_exit_ok "W28-28【境界】list --json は guard に到達しない: exit 0" "$W28_28_EC"
assert_not_contains "W28-28: --json が未知フラグ扱いされていない" "不明なフラグ" "$W28_28_OUT"
rm -f "$W28_LOG"

# W28-29【境界】内部生成の引数列（activate → runEdit へ ['42','--activate',<date>] を渡す）が
# guard に引っかからないこと
W28_LOG=$(mktemp /tmp/todo-test-w28-29-XXXXXX); W28_RESP_CUR="$W28_SIMPLE_RESP"
W28_29_OUT=$(w28_run activate 42 2026-09-10); W28_29_EC=$?
assert_exit_ok "W28-29【境界】内部生成の引数列(activate → runEdit): exit 0" "$W28_29_EC"
assert_contains "W28-29: activate が更新される" "activate → 2026-09-10" "$W28_29_OUT"
rm -f "$W28_LOG"

# ──────────────────────────────────────────
# 結果サマリー（run-tests.sh から集計加算するための機械可読な行）
# ──────────────────────────────────────────
echo ""
echo "=========================================="
W_TOTAL=$((PASS+FAIL))
printf "書き込み系テスト結果: %d / %d テスト通過\n" "$PASS" "$W_TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf "❌ %d テスト失敗\n" "$FAIL"
fi
echo "=========================================="
echo "__WRITE_SUITE_SUMMARY__ PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ]
