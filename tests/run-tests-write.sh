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
# 設計書: workspaces/skill-dev/todo/designs/2026-08-03_octokit-injection-seam.md

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

W0_LOG=$(mktemp /tmp/todo-test-stub-w0-XXXXXX.jsonl)
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
W1_LOG=$(mktemp /tmp/todo-test-w1-XXXXXX.jsonl)
W1_RESP='{"issues.get":[{"data":{"number":301,"id":9301,"title":"Weekly Report","body":"due: 2026-03-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}],"issues.create":[{"data":{"number":9999}}]}'
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
W1B_LOG=$(mktemp /tmp/todo-test-w1b-XXXXXX.jsonl)
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
W2_LOG=$(mktemp /tmp/todo-test-w2-XXXXXX.jsonl)
W2_RESP='{"issues.get":[{"data":{"number":401,"id":9401,"title":"Simple Task","body":"","labels":[{"name":"📥 inbox"}]}},{"data":{"number":402,"id":9402,"title":"Weekly Task 2","body":"due: 2026-04-01\nrecur: weekly\n","labels":[{"name":"🎯 next"}]}}],"issues.update":[{},{}],"issues.create":[{"data":{"number":8888}}]}'
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
W2B_LOG=$(mktemp /tmp/todo-test-w2b-XXXXXX.jsonl)
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
VUSE_LOG=$(mktemp /tmp/todo-test-w3-use-XXXXXX.jsonl)
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
VUSE_MISS_LOG=$(mktemp /tmp/todo-test-w3-missuse-XXXXXX.jsonl)
: > "$VUSE_MISS_LOG"
VUSE_MISS_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$VUSE_MISS_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run view use nosuchview 2>&1); VUSE_MISS_EC=$?
assert_exit_fail "runView use 異常系: 存在しないビュー → exit 1" "$VUSE_MISS_EC"
assert_contains "runView use 異常系: エラーメッセージ" 'ビュー「nosuchview」は存在しません' "$VUSE_MISS_OUT"
assert_eq "runView use 異常系: API呼び出しゼロ（存在チェックがfetchAllOpenより先行）" "0" "$(wc -l < "$VUSE_MISS_LOG" | tr -d ' ')"
rm -f "$VUSE_MISS_LOG"

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
W4_LOG=$(mktemp /tmp/todo-test-w4-XXXXXX.jsonl)
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
W4B_LOG=$(mktemp /tmp/todo-test-w4b-XXXXXX.jsonl)
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
W5_LOG=$(mktemp /tmp/todo-test-w5-XXXXXX.jsonl)
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
W5B_LOG=$(mktemp /tmp/todo-test-w5b-XXXXXX.jsonl)
W5B_RESP='{"issues.get":[{"data":{"number":602,"id":9602,"title":"No due task","body":"","labels":[{"name":"📥 inbox"}]}}]}'
W5B_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W5B_RESP" OCTOKIT_STUB_LOG_ENV="$W5B_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run edit 602 --before 2d 2>&1); W5B_EC=$?
assert_exit_fail "runEdit 異常系: dueなしで--before → exit 1" "$W5B_EC"
assert_contains "runEdit 異常系: エラーメッセージ" "before を使うには --due が必要です" "$W5B_OUT"
assert_eq "runEdit 異常系: issues.get のみ実行（1回）" "1" "$(log_count "$W5B_LOG" issues.get)"
assert_eq "runEdit 異常系: issues.update は呼ばれない（副作用なし）" "0" "$(log_count "$W5B_LOG" issues.update)"
rm -f "$W5B_LOG"

# W5-3 characterization（COO決定事項: runEdit の validate-before-mutate 順序バグは修正せず、
# 現状挙動を記録するテストとして残す。修正は別Issue）:
# --priority に不正値を指定すると、旧priorityラベルの削除（removeLabel）は実行されるが、
# validatePriority() がその後にexit(1)するため、新ラベル追加(addLabels)も本体の
# issues.update（body更新）も一切呼ばれない。
W5C_LOG=$(mktemp /tmp/todo-test-w5c-XXXXXX.jsonl)
W5C_RESP='{"issues.get":[{"data":{"number":603,"id":9603,"title":"Task","body":"due: 2026-04-01\n","labels":[{"name":"🎯 next"},{"name":"p1"}]}}],"issues.removeLabel":[{}]}'
W5C_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W5C_RESP" OCTOKIT_STUB_LOG_ENV="$W5C_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-04-05 \
  node "$ENGINE" run edit 603 --priority p9 2>&1); W5C_EC=$?
assert_exit_fail "runEdit characterization(順序バグ): 不正priority → exit 1" "$W5C_EC"
assert_contains "runEdit characterization: エラーメッセージ" "priority は p1/p2/p3 のみ有効です" "$W5C_OUT"
assert_eq "runEdit characterization: 旧priorityラベル削除は実行される（バグの一部）" "1" "$(log_count "$W5C_LOG" issues.removeLabel)"
assert_eq "runEdit characterization: 新ラベル追加(addLabels)は呼ばれない" "0" "$(log_count "$W5C_LOG" issues.addLabels)"
assert_eq "runEdit characterization: 本体のbody更新(issues.update)も呼ばれない（未修正の順序バグの全体像）" "0" "$(log_count "$W5C_LOG" issues.update)"
rm -f "$W5C_LOG"

# ──────────────────────────────────────────
# §W6  runPriority — スタブベース振る舞いテスト（Phase 1）
# ──────────────────────────────────────────
echo ""
echo "§W6  runPriority — スタブベース振る舞いテスト"

# W6-1 正常系
W6_LOG=$(mktemp /tmp/todo-test-w6-XXXXXX.jsonl)
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

# W6-2 異常系 characterization（COO決定事項・design §Phase1 優先順位6）:
# 旧ラベル削除→validateの順序バグを修正せず、現状挙動として記録する。
# 不正値指定時、removeLabel(旧priority) は実行されるが addLabels(新priority) は呼ばれない。
W6C_LOG=$(mktemp /tmp/todo-test-w6c-XXXXXX.jsonl)
W6C_RESP='{"issues.get":[{"data":{"number":702,"id":9702,"title":"Task2","body":"","labels":[{"name":"🎯 next"},{"name":"p1"}]}}],"issues.removeLabel":[{}]}'
W6C_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W6C_RESP" OCTOKIT_STUB_LOG_ENV="$W6C_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run priority 702 p9 2>&1); W6C_EC=$?
assert_exit_fail "runPriority characterization(順序バグ): 不正priority → exit 1" "$W6C_EC"
assert_contains "runPriority characterization: エラーメッセージ" "priority は p1/p2/p3 のみ有効です" "$W6C_OUT"
assert_eq "runPriority characterization: 旧priorityラベル削除は実行される（バグの一部）" "1" "$(log_count "$W6C_LOG" issues.removeLabel)"
assert_eq "runPriority characterization: 新ラベル追加(addLabels)は呼ばれない" "0" "$(log_count "$W6C_LOG" issues.addLabels)"
rm -f "$W6C_LOG"

# ──────────────────────────────────────────
# §W7  runTag rename — スタブベース振る舞いテスト（Phase 2: TAG_RENAME_DELEGATES 置換）
# ──────────────────────────────────────────
echo ""
echo "§W7  runTag rename — スタブベース振る舞いテスト（renameCtxLabel 委譲の実効検証）"

# 旧 TAG_RENAME_DELEGATES はソースgrep（「renameCtxLabel という文字列が runTag 本文に
# 含まれるか」のみ確認）だった。置換後は実際に ensureLabel→fetchAllOpen→(addLabels→
# removeLabel)→deleteLabel という呼び出し列が発生することをログで確認する。
W7_LOG=$(mktemp /tmp/todo-test-w7-XXXXXX.jsonl)
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
