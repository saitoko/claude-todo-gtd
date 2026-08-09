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
# #1660修正後: fetchAllOpen（issues.listForRepo）がproject/dependsOn有無に関わらず
# 常に呼ばれるようになるため空応答を1件用意する
W1_LOG=$(mktemp /tmp/todo-test-w1-XXXXXX.jsonl)
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
# #1660修正後: 各Issueのpostdone処理でfetchAllOpen（issues.listForRepo）が呼ばれるため、
# 2件（Issueごとに1回）の空応答を用意する
W2_LOG=$(mktemp /tmp/todo-test-w2-XXXXXX.jsonl)
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
W9_1_LOG=$(mktemp /tmp/todo-test-w9-1-XXXXXX.jsonl)
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
W9_2_LOG=$(mktemp /tmp/todo-test-w9-2-XXXXXX.jsonl)
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
W9_3_LOG=$(mktemp /tmp/todo-test-w9-3-XXXXXX.jsonl)
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
W9_4_LOG=$(mktemp /tmp/todo-test-w9-4-XXXXXX.jsonl)
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
W9_5_LOG=$(mktemp /tmp/todo-test-w9-5-XXXXXX.jsonl)
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
W9_6_LOG=$(mktemp /tmp/todo-test-w9-6-XXXXXX.jsonl)
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
W10_1_LOG=$(mktemp /tmp/todo-test-w10-1-XXXXXX.jsonl)
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
W10_2_LOG=$(mktemp /tmp/todo-test-w10-2-XXXXXX.jsonl)
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
W10_3_LOG=$(mktemp /tmp/todo-test-w10-3-XXXXXX.jsonl)
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
W11_1_LOG=$(mktemp /tmp/todo-test-w11-1-XXXXXX.jsonl)
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
W11_2_LOG=$(mktemp /tmp/todo-test-w11-2-XXXXXX.jsonl)
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
W11_3_LOG=$(mktemp /tmp/todo-test-w11-3-XXXXXX.jsonl)
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
W11_4_LOG=$(mktemp /tmp/todo-test-w11-4-XXXXXX.jsonl)
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
W12_1_LOG=$(mktemp /tmp/todo-test-w12-1-XXXXXX.jsonl)
: > "$W12_1_LOG"
W12_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run bulk tag 6101 6102 -- @本業 2>&1); W12_1_EC=$?
assert_exit_fail "W12-1 境界値: bulk tag に '--' を渡す → exit 1" "$W12_1_EC"
assert_contains "W12-1 境界値: オプション誤指定である旨のエラーメッセージ" "オプション指定に見えます" "$W12_1_OUT"
assert_eq "W12-1 境界値: API呼び出しゼロ（ラベル作成・付与ともに発生しない）" "0" "$(wc -l < "$W12_1_LOG" | tr -d ' ')"
rm -f "$W12_1_LOG"

# W12-2 境界値: 記号のみのコンテキスト名（'@--'）が拒否されること
W12_2_LOG=$(mktemp /tmp/todo-test-w12-2-XXXXXX.jsonl)
: > "$W12_2_LOG"
W12_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run tag 6103 '@--' 2>&1); W12_2_EC=$?
assert_exit_fail "W12-2 境界値: 記号のみのコンテキスト名 → exit 1" "$W12_2_EC"
assert_contains "W12-2 境界値: 記号のみを拒否するエラーメッセージ" "記号のみの名前は使えません" "$W12_2_OUT"
assert_eq "W12-2 境界値: API呼び出しゼロ（ensureLabel より前に検証される）" "0" "$(wc -l < "$W12_2_LOG" | tr -d ' ')"
rm -f "$W12_2_LOG"

# W12-3 境界値: 記号のみのタグ名（'#--'）が拒否されること
W12_3_LOG=$(mktemp /tmp/todo-test-w12-3-XXXXXX.jsonl)
: > "$W12_3_LOG"
W12_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run bulk tag 6104 '#--' 2>&1); W12_3_EC=$?
assert_exit_fail "W12-3 境界値: 記号のみのタグ名 → exit 1" "$W12_3_EC"
assert_contains "W12-3 境界値: 記号のみを拒否するエラーメッセージ" "記号のみの名前は使えません" "$W12_3_OUT"
assert_eq "W12-3 境界値: API呼び出しゼロ" "0" "$(wc -l < "$W12_3_LOG" | tr -d ' ')"
rm -f "$W12_3_LOG"

# W12-4 正常系: 既存ラベル（GET 200）を付与したときは新規作成の通知を出さないこと
W12_4_LOG=$(mktemp /tmp/todo-test-w12-4-XXXXXX.jsonl)
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
W12_5_LOG=$(mktemp /tmp/todo-test-w12-5-XXXXXX.jsonl)
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
W13_1_LOG=$(mktemp /tmp/todo-test-w13-1-XXXXXX.jsonl)
W13_1_RESP='{"issues.get":[{"data":{"number":1701,"id":97001,"title":"Weekly Review","body":"due: 2026-08-10\nrecur: weekly:sat\n","labels":[{"name":"🎯 next"}]}}]}'
W13_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_1_RESP" OCTOKIT_STUB_LOG_ENV="$W13_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1701 --json 2>&1); W13_1_EC=$?
assert_exit_ok "W13-1 正常系: run show --json exit 0" "$W13_1_EC"
assert_contains "W13-1 正常系: recur にコロンが保持される（renderIssueList回帰と対の確認）" '"recur": "weekly:sat"' "$W13_1_OUT"
rm -f "$W13_1_LOG"

# W13-2 正常系: run recur <#> weekly:sat が成功しbodyにコロン付きで保存されること
W13_2_LOG=$(mktemp /tmp/todo-test-w13-2-XXXXXX.jsonl)
W13_2_RESP='{"issues.get":[{"data":{"number":1702,"id":97002,"title":"Task","body":"","labels":[{"name":"🎯 next"}]}}],"issues.update":[{}]}'
W13_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W13_2_RESP" OCTOKIT_STUB_LOG_ENV="$W13_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run recur 1702 weekly:sat 2>&1); W13_2_EC=$?
assert_exit_ok "W13-2 正常系: run recur weekly:sat exit 0" "$W13_2_EC"
assert_contains "W13-2 正常系: 成功メッセージ" "✅ #1702 の繰り返しを weekly:sat に設定しました。" "$W13_2_OUT"
assert_contains "W13-2 正常系: issues.update body に recur: weekly:sat が保存される" '"body":"recur: weekly:sat\n"' "$(log_lines_for_method "$W13_2_LOG" issues.update)"
rm -f "$W13_2_LOG"

# W13-3 正常系: run edit <#> --recur monthly:15 が成功しbodyにコロン付きで保存されること
W13_3_LOG=$(mktemp /tmp/todo-test-w13-3-XXXXXX.jsonl)
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
W13_4_LOG=$(mktemp /tmp/todo-test-w13-4-XXXXXX.jsonl)
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
W13_5_LOG=$(mktemp /tmp/todo-test-w13-5-XXXXXX.jsonl)
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
W13_6_LOG=$(mktemp /tmp/todo-test-w13-6-XXXXXX.jsonl)
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
W12_1_LOG=$(mktemp /tmp/todo-test-w12-1-XXXXXX.jsonl)
W12_1_RESP='{"GET /repos/{owner}/{repo}/labels/{name}":[{}],"issues.create":[{"data":{"number":7001,"html_url":"https://github.com/test-owner/test-repo/issues/7001"}}]}'
W12_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_1_RESP" OCTOKIT_STUB_LOG_ENV="$W12_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run add inbox 送客強化タスク --activate 2026-08-10 --resume-condition "検索流入が回復したら" 2>&1); W12_1_EC=$?
assert_exit_ok "W12-1 正常系: runAdd --resume-condition → exit 0" "$W12_1_EC"
assert_contains "W12-1 正常系: issues.create body に resume_condition が反映" '"body":"activate: 2026-08-10\nresume_condition: 検索流入が回復したら\n"' "$(log_lines_for_method "$W12_1_LOG" issues.create)"
rm -f "$W12_1_LOG"

# W12-2 異常系: runAdd --resume-condition に改行を含む値 → validateResumeCondition でエラー終了、issues.createは呼ばれない
W12_2_LOG=$(mktemp /tmp/todo-test-w12-2-XXXXXX.jsonl)
: > "$W12_2_LOG"
W12_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_LOG_ENV="$W12_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run add inbox 改行テスト --resume-condition $'line1\nline2' 2>&1); W12_2_EC=$?
assert_exit_fail "W12-2 異常系: --resume-condition に改行混入 → exit 1" "$W12_2_EC"
assert_contains "W12-2 異常系: エラーメッセージ" "resume_condition に改行を含めることはできません" "$W12_2_OUT"
assert_eq "W12-2 異常系: issues.create は呼ばれない（副作用なし）" "0" "$(log_count "$W12_2_LOG" issues.create)"
rm -f "$W12_2_LOG"

# W12-3 正常系: runEdit --resume-condition で既存Issueに再開条件を後付け
W12_3_LOG=$(mktemp /tmp/todo-test-w12-3-XXXXXX.jsonl)
W12_3_RESP='{"issues.get":[{"data":{"number":1299,"id":91299,"title":"サンプルタスク","body":"activate: 2026-07-15\n","labels":[{"name":"🌈 someday"}]}}],"issues.update":[{}]}'
W12_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_3_RESP" OCTOKIT_STUB_LOG_ENV="$W12_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run edit 1299 --resume-condition "example.comの検索流入が観測できるレベルに育ったとき" 2>&1); W12_3_EC=$?
assert_exit_ok "W12-3 正常系: runEdit --resume-condition → exit 0" "$W12_3_EC"
assert_contains "W12-3 正常系: changedメッセージに resume_condition → が含まれる" "resume_condition → example.comの検索流入が観測できるレベルに育ったとき" "$W12_3_OUT"
assert_contains "W12-3 正常系: issues.update body に resume_condition 行が反映" '"body":"activate: 2026-07-15\nresume_condition: example.comの検索流入が観測できるレベルに育ったとき\n"' "$(log_lines_for_method "$W12_3_LOG" issues.update)"
rm -f "$W12_3_LOG"

# W12-4 正常系: runEdit --resume-condition clear で再開条件を除去（activate等の他フィールドは保持）
W12_4_LOG=$(mktemp /tmp/todo-test-w12-4-XXXXXX.jsonl)
W12_4_RESP='{"issues.get":[{"data":{"number":1299,"id":91299,"title":"サンプルタスク","body":"activate: 2026-07-15\nresume_condition: 検索流入が回復したら\n","labels":[{"name":"🌈 someday"}]}}],"issues.update":[{}]}'
W12_4_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_4_RESP" OCTOKIT_STUB_LOG_ENV="$W12_4_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run edit 1299 --resume-condition clear 2>&1); W12_4_EC=$?
assert_exit_ok "W12-4 正常系: runEdit --resume-condition clear → exit 0" "$W12_4_EC"
assert_contains "W12-4 正常系: changedメッセージ「resume_condition → クリア」" "resume_condition → クリア" "$W12_4_OUT"
assert_contains "W12-4 正常系: issues.update body から resume_condition 行が消え activate は保持" '"body":"activate: 2026-07-15\n"' "$(log_lines_for_method "$W12_4_LOG" issues.update)"
rm -f "$W12_4_LOG"

# W12-5 異常系: runEdit --resume-condition に改行を含む値 → エラー終了、issues.updateは呼ばれない
W12_5_LOG=$(mktemp /tmp/todo-test-w12-5-XXXXXX.jsonl)
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
W12_6_LOG=$(mktemp /tmp/todo-test-w12-6-XXXXXX.jsonl)
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
W12_7_LOG=$(mktemp /tmp/todo-test-w12-7-XXXXXX.jsonl)
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
W12_8_LOG=$(mktemp /tmp/todo-test-w12-8-XXXXXX.jsonl)
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
W12_9_LOG=$(mktemp /tmp/todo-test-w12-9-XXXXXX.jsonl)
W12_9_RESP='{"issues.listForRepo":[{"data":[{"number":1400,"title":"Future Task","body":"activate: 2099-01-01\nresume_condition: 何かの条件\n","labels":[{"name":"📥 inbox"}],"updated_at":""}]}]}'
W12_9_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W12_9_RESP" OCTOKIT_STUB_LOG_ENV="$W12_9_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo TODAY=2026-08-03 \
  node "$ENGINE" run promote 2>&1); W12_9_EC=$?
assert_exit_ok "W12-9 境界値: activate未到来 → exit 0" "$W12_9_EC"
assert_contains "W12-9 境界値: 昇格対象なしメッセージ（未到来のため走査対象外）" '昇格対象なし（activate日到来タスク: 0件）' "$W12_9_OUT"
assert_not_contains "W12-9 境界値: #1400 への言及がない（走査対象外）" '#1400' "$W12_9_OUT"
rm -f "$W12_9_LOG"

# W12-10 正常系: runShow --json に resumeCondition フィールドが含まれる
W12_10_LOG=$(mktemp /tmp/todo-test-w12-10-XXXXXX.jsonl)
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
W14_1_LOG=$(mktemp /tmp/todo-test-w14-1-XXXXXX.jsonl)
W14_1_RESP='{"issues.get":[{"data":{"number":1740,"id":91740,"title":"完了済みタスク","body":"","labels":[{"name":"🎯 next"}],"state":"closed","closed_at":"2026-08-09T09:29:00Z"}}]}'
W14_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W14_1_RESP" OCTOKIT_STUB_LOG_ENV="$W14_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1740 2>&1); W14_1_EC=$?
assert_exit_ok "W14-1 正常系: runShow(closed) → exit 0" "$W14_1_EC"
assert_contains "W14-1 正常系: 状態行に完了・クローズ日が表示される" '- 状態: ✅ 完了（2026-08-09）' "$W14_1_OUT"
rm -f "$W14_1_LOG"

# W14-2 正常系: open Issue を show（人間向け出力）→ 状態行は表示されない（冗長回避）
W14_2_LOG=$(mktemp /tmp/todo-test-w14-2-XXXXXX.jsonl)
W14_2_RESP='{"issues.get":[{"data":{"number":1746,"id":91746,"title":"未完了タスク","body":"","labels":[{"name":"🎯 next"}],"state":"open","closed_at":null}}]}'
W14_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W14_2_RESP" OCTOKIT_STUB_LOG_ENV="$W14_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1746 2>&1); W14_2_EC=$?
assert_exit_ok "W14-2 正常系: runShow(open) → exit 0" "$W14_2_EC"
assert_not_contains "W14-2 正常系: open では状態行が表示されない（冗長回避）" '- 状態:' "$W14_2_OUT"
rm -f "$W14_2_LOG"

# W14-3 正常系: closed Issue を show --json → state:"closed" と closedAt が含まれる
W14_3_LOG=$(mktemp /tmp/todo-test-w14-3-XXXXXX.jsonl)
W14_3_RESP='{"issues.get":[{"data":{"number":1740,"id":91740,"title":"完了済みタスク","body":"","labels":[{"name":"🎯 next"}],"state":"closed","closed_at":"2026-08-09T09:29:00Z"}}]}'
W14_3_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W14_3_RESP" OCTOKIT_STUB_LOG_ENV="$W14_3_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1740 --json 2>&1); W14_3_EC=$?
assert_exit_ok "W14-3 正常系: runShow --json(closed) → exit 0" "$W14_3_EC"
assert_contains "W14-3 正常系: JSON応答に state:closed が含まれる" '"state": "closed"' "$W14_3_OUT"
assert_contains "W14-3 正常系: JSON応答に closedAt が含まれる" '"closedAt": "2026-08-09T09:29:00Z"' "$W14_3_OUT"
rm -f "$W14_3_LOG"

# W14-4 正常系: open Issue を show --json → state:"open"、closedAt は null
W14_4_LOG=$(mktemp /tmp/todo-test-w14-4-XXXXXX.jsonl)
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
# 実証: 2026-08-09 COO実機確認。closed_at=2026-08-08T23:32:23Z（実issue #1739）は
# JSTでは2026-08-09 08:32だが、修正前は `.slice(0,10)` によりUTC日付の
# 「2026-08-08」がそのまま表示されていた。
# ──────────────────────────────────────────

# W15-1: show（人間向け出力）— 実証データそのまま（#1739）
W15_1_LOG=$(mktemp /tmp/todo-test-w15-1-XXXXXX.jsonl)
W15_1_RESP='{"issues.get":[{"data":{"number":1739,"id":91739,"title":"検証用 recur Undo確認 1656","body":"","labels":[{"name":"🎯 next"}],"state":"closed","closed_at":"2026-08-08T23:32:23Z"}}]}'
W15_1_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W15_1_RESP" OCTOKIT_STUB_LOG_ENV="$W15_1_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run show 1739 2>&1); W15_1_EC=$?
assert_exit_ok "W15-1 正常系: runShow(#1739 境界またぎ) → exit 0" "$W15_1_EC"
assert_contains "W15-1 正常系: 完了日がJST変換後（2026-08-09）で表示される" '- 状態: ✅ 完了（2026-08-09）' "$W15_1_OUT"
assert_not_contains "W15-1 正常系: UTC日付（2026-08-08）のままでは表示されない" '- 状態: ✅ 完了（2026-08-08）' "$W15_1_OUT"
rm -f "$W15_1_LOG"

# W15-2: archive list — closedAt の表示日付がJST基準になる
W15_2_LOG=$(mktemp /tmp/todo-test-w15-2-XXXXXX.jsonl)
W15_2_RESP='{"issues.listForRepo":[{"data":[{"number":1739,"title":"境界またぎ","state":"closed","closed_at":"2026-08-08T23:32:23Z","labels":[],"pull_request":null}]}]}'
W15_2_OUT=$(OCTOKIT_STUB_ENV="$STUB" OCTOKIT_STUB_RESPONSES_ENV="$W15_2_RESP" OCTOKIT_STUB_LOG_ENV="$W15_2_LOG" \
  TODO_REPO_OWNER=test-owner TODO_REPO_NAME=test-repo \
  node "$ENGINE" run archive list 2>&1); W15_2_EC=$?
assert_exit_ok "W15-2 正常系: runArchive list(境界またぎ) → exit 0" "$W15_2_EC"
assert_contains "W15-2 正常系: archive list の日付がJST変換後（2026-08-09）" '✅2026-08-09' "$W15_2_OUT"
assert_not_contains "W15-2 正常系: UTC日付（2026-08-08）のままでは表示されない" '✅2026-08-08' "$W15_2_OUT"
rm -f "$W15_2_LOG"

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
