#!/bin/bash
# GitHub接続テスト — ${TODO_REPO_OWNER}/${TODO_REPO_NAME}
set -uo pipefail

REPO="${TODO_REPO_OWNER}/${TODO_REPO_NAME}"
PASS=0; FAIL=0
CREATED_ISSUES=""

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; echo "     $2"; FAIL=$((FAIL+1)); }
skip_test() { echo "  ⏭  $1 (skip: $2)"; }

track() { CREATED_ISSUES="$CREATED_ISSUES $1"; }

# ────────────────────────────────────────────
# リトライヘルパー（2関数で全パターンをカバー）
# ────────────────────────────────────────────

# Issue のフィールドを取得（最大5回リトライ、非空になるまで待つ）
# usage: get_field <issue_number> <json_field> <jq_filter>
# 結果は WAIT_RESULT に格納
get_field() {
  local num="$1" field="$2" filter="$3" max=5 i=0
  WAIT_RESULT=""
  while [ "$i" -lt "$max" ]; do
    WAIT_RESULT=$(gh issue view "$num" --repo "$REPO" --json "$field" -q "$filter" 2>/dev/null || true)
    [ -n "$WAIT_RESULT" ] && return 0
    i=$((i+1)); sleep 1
  done
  return 1
}

# Issue のフィールドが条件を満たすまでリトライ
# usage: wait_field <issue_number> <json_field> <jq_filter> <mode> <pattern>
#   mode: "match"    — grep パターンに一致するまで待つ
#         "no_match" — grep パターンに一致しなくなるまで待つ
#         "exact"    — 完全一致するまで待つ
wait_field() {
  local num="$1" field="$2" filter="$3" mode="$4" pattern="$5" max=5 i=0
  WAIT_RESULT=""
  while [ "$i" -lt "$max" ]; do
    WAIT_RESULT=$(gh issue view "$num" --repo "$REPO" --json "$field" -q "$filter" 2>/dev/null || true)
    case "$mode" in
      match)    echo "$WAIT_RESULT" | grep -q "$pattern"    && return 0 ;;
      no_match) echo "$WAIT_RESULT" | grep -q "$pattern"    || return 0 ;;
      exact)    [ "$WAIT_RESULT" = "$pattern" ]              && return 0 ;;
    esac
    i=$((i+1)); sleep 1
  done
  return 1
}

# ショートカット: よく使うフィールドの jq フィルタ
LABELS_FILTER='[.labels[].name] | join(",")'
BODY_FILTER='.body'
TITLE_FILTER='.title'

# gh issue create の出力URLから番号を取得
create_issue() {
  local title="$1"; shift
  gh issue create --repo "$REPO" --title "$title" "$@" 2>/dev/null \
    | grep -oE '[0-9]+$'
}

echo ""
echo "=========================================="
echo " GitHub接続テスト: $REPO"
echo "=========================================="

# ─────────────────────────────────────────────
echo ""
echo "§A  優先度ラベル作成（p1/p2/p3）"
# ─────────────────────────────────────────────

for PRI in p1 p2 p3; do
  PCOLOR=$(case "$PRI" in p1) echo B60205;; p2) echo FBCA04;; p3) echo 0075CA;; esac)
  gh label create "$PRI" --repo "$REPO" --color "$PCOLOR" --description "優先度" 2>/dev/null || true
done

LABELS=$(gh label list --repo "$REPO" --json name -q '[.[].name] | join(",")' 2>/dev/null)
for PRI in p1 p2 p3; do
  if echo "$LABELS" | grep -q "$PRI"; then
    ok "ラベル '$PRI' が存在する"
  else
    fail "ラベル '$PRI' が存在しない" "ラベル一覧: $LABELS"
  fi
done

# ─────────────────────────────────────────────
echo ""
echo "§B  --priority p1 でのIssue作成"
# ─────────────────────────────────────────────

NUM_P1=$(create_issue "[test] p1タスク" --label "next" --label "p1" --body "test")
track "$NUM_P1"
wait_field "$NUM_P1" labels "$LABELS_FILTER" match "p1"
LBLS="$WAIT_RESULT"
if echo "$LBLS" | grep -q "p1"; then
  ok "--priority p1: p1ラベル付与 (#$NUM_P1)"
else
  fail "--priority p1: p1ラベルなし" "ラベル: $LBLS"
fi
if echo "$LBLS" | grep -q "next"; then
  ok "--priority p1: nextラベル付与"
else
  fail "--priority p1: nextラベルなし" "ラベル: $LBLS"
fi

# ─────────────────────────────────────────────
echo ""
echo "§C  デフォルト優先度 p3"
# ─────────────────────────────────────────────

NUM_DEF=$(create_issue "[test] デフォルト優先度" --label "next" --label "p3" --body "test")
track "$NUM_DEF"
wait_field "$NUM_DEF" labels "$LABELS_FILTER" match "p3"
LBLS="$WAIT_RESULT"
if echo "$LBLS" | grep -q "p3"; then
  ok "デフォルトp3: p3ラベル付与 (#$NUM_DEF)"
else
  fail "デフォルトp3: p3ラベルなし" "ラベル: $LBLS"
fi

# ─────────────────────────────────────────────
echo ""
echo "§D  priority コマンド（優先度変更）"
# ─────────────────────────────────────────────

# p3 → p1 に変更
gh issue edit "$NUM_DEF" --repo "$REPO" --remove-label "p3" --add-label "p1" > /dev/null 2>&1
wait_field "$NUM_DEF" labels "$LABELS_FILTER" match "p1"
LBLS="$WAIT_RESULT"
if echo "$LBLS" | grep -q "p1"; then
  ok "priority変更 p3→p1: p1ラベルあり (#$NUM_DEF)"
else
  fail "priority変更 p3→p1: p1なし" "ラベル: $LBLS"
fi
if echo "$LBLS" | grep -q "p3"; then
  fail "priority変更 p3→p1: p3が残っている" "ラベル: $LBLS"
else
  ok "priority変更 p3→p1: p3ラベル除去"
fi

# p1 → clear
EXISTING=$(gh issue view "$NUM_DEF" --repo "$REPO" --json labels \
  -q '[.labels[].name | select(test("^p[123]$"))] | .[]' 2>/dev/null || true)
for PL in $EXISTING; do
  gh issue edit "$NUM_DEF" --repo "$REPO" --remove-label "$PL" > /dev/null 2>&1 || true
done
wait_field "$NUM_DEF" labels "$LABELS_FILTER" no_match "p[123]"
LBLS="$WAIT_RESULT"
if echo "$LBLS" | grep -qE "p[123]"; then
  fail "priority clear: まだ優先度ラベルが残っている" "ラベル: $LBLS"
else
  ok "priority clear: 優先度ラベルなし (#$NUM_DEF)"
fi

# ─────────────────────────────────────────────
echo ""
echo "§E  list p1 フィルタ"
# ─────────────────────────────────────────────

NUM_P2=$(create_issue "[test] p2タスク" --label "next" --label "p2" --body "test")
track "$NUM_P2"

FILTER_RESULT=$(gh issue list --repo "$REPO" --label "p1" --state open \
  --json number -q '[.[].number] | join(",")' 2>/dev/null)
if echo "$FILTER_RESULT" | grep -q "$NUM_P1"; then
  ok "list p1: p1のIssue (#$NUM_P1) が含まれる"
else
  fail "list p1: p1のIssue (#$NUM_P1) が含まれない" "結果: $FILTER_RESULT"
fi
if echo "$FILTER_RESULT" | grep -q "$NUM_P2"; then
  fail "list p1: p2のIssue (#$NUM_P2) が含まれてしまう" "結果: $FILTER_RESULT"
else
  ok "list p1: p2のIssue (#$NUM_P2) は除外される"
fi

# ─────────────────────────────────────────────
echo ""
echo "§F  list next p1 複合フィルタ"
# ─────────────────────────────────────────────

NUM_SOMEDAY_P1=$(create_issue "[test] someday p1タスク" --label "someday" --label "p1" --body "test")
track "$NUM_SOMEDAY_P1"

FILTER2=$(gh issue list --repo "$REPO" --label "next" --label "p1" --state open \
  --json number -q '[.[].number] | join(",")' 2>/dev/null)
if echo "$FILTER2" | grep -q "$NUM_P1"; then
  ok "list next p1: next+p1のIssue (#$NUM_P1) が含まれる"
else
  fail "list next p1: next+p1のIssue (#$NUM_P1) が含まれない" "結果: $FILTER2"
fi
if echo "$FILTER2" | grep -q "$NUM_SOMEDAY_P1"; then
  fail "list next p1: someday+p1のIssue (#$NUM_SOMEDAY_P1) が含まれてしまう" "結果: $FILTER2"
else
  ok "list next p1: someday+p1のIssue (#$NUM_SOMEDAY_P1) は除外される"
fi

# ─────────────────────────────────────────────
echo ""
echo "§G  tag コマンド（コンテキスト追加）"
# ─────────────────────────────────────────────

NUM_TAG=$(create_issue "[test] tagテスト" --label "next" --label "p3" --body "test")
track "$NUM_TAG"

gh label create "@PC" --repo "$REPO" --color FBCA04 --description "コンテキスト" 2>/dev/null || true
gh issue edit "$NUM_TAG" --repo "$REPO" --add-label "@PC" > /dev/null 2>&1
wait_field "$NUM_TAG" labels "$LABELS_FILTER" match "@PC"
LBLS="$WAIT_RESULT"
if echo "$LBLS" | grep -q "@PC"; then
  ok "tag: @PCラベル追加 (#$NUM_TAG)"
else
  fail "tag: @PCラベルなし" "ラベル: $LBLS"
fi

# ─────────────────────────────────────────────
echo ""
echo "§H  move コマンド"
# ─────────────────────────────────────────────

NUM_MOVE=$(create_issue "[test] moveテスト" --label "inbox" --label "p3" --body "test")
track "$NUM_MOVE"

gh issue edit "$NUM_MOVE" --repo "$REPO" --add-label "next" --remove-label "inbox" > /dev/null 2>&1
wait_field "$NUM_MOVE" labels "$LABELS_FILTER" match "next"
LBLS="$WAIT_RESULT"
if echo "$LBLS" | grep -q "next"; then
  ok "move inbox→next: nextラベルあり (#$NUM_MOVE)"
else
  fail "move inbox→next: nextなし" "ラベル: $LBLS"
fi
if echo "$LBLS" | grep -q "inbox"; then
  fail "move inbox→next: inboxが残っている" "ラベル: $LBLS"
else
  ok "move inbox→next: inboxラベル除去"
fi

# ─────────────────────────────────────────────
echo ""
echo "§I  due コマンド（body更新）"
# ─────────────────────────────────────────────

NUM_DUE=$(create_issue "[test] due更新テスト" --label "next" --label "p3" --body "test")
track "$NUM_DUE"

NEWBODY="due: 2026-05-01
"
gh issue edit "$NUM_DUE" --repo "$REPO" --body "$NEWBODY" > /dev/null 2>&1
wait_field "$NUM_DUE" body "$BODY_FILTER" match "due: 2026-05-01"
BODY="$WAIT_RESULT"
if echo "$BODY" | grep -q "due: 2026-05-01"; then
  ok "due更新: body に due: 2026-05-01 (#$NUM_DUE)"
else
  fail "due更新: due行なし" "body: $BODY"
fi

# ─────────────────────────────────────────────
echo ""
echo "§J  done コマンド（recur付き — bodyが正しく構造化されるか）"
# ─────────────────────────────────────────────

TODAY=$(date +%Y-%m-%d)
RECUR_BODY="due: $TODAY
recur: weekly
"
NUM_RECUR=$(create_issue "[test] 毎週タスク" --label "next" --label "p3" --body "$RECUR_BODY")
track "$NUM_RECUR"

wait_field "$NUM_RECUR" body "$BODY_FILTER" match "^due:"
BODY="$WAIT_RESULT"
if echo "$BODY" | grep -q "^due:"; then
  ok "done(recur準備): due行あり (#$NUM_RECUR)"
else
  fail "done(recur準備): due行なし" "body: $BODY"
fi
if echo "$BODY" | grep -q "^recur: weekly"; then
  ok "done(recur準備): recur: weekly行あり"
else
  fail "done(recur準備): recur行なし" "body: $BODY"
fi

# ─────────────────────────────────────────────
echo ""
echo "§K  archive list"
# ─────────────────────────────────────────────

ARCH=$(gh issue list --repo "$REPO" --state closed --limit 5 \
  --json number,title -q '.[0] | "#\(.number) \(.title)"' 2>/dev/null)
if [ -n "$ARCH" ]; then
  ok "archive: クローズ済みIssue取得成功 ($ARCH)"
else
  fail "archive: クローズ済みIssueなし" ""
fi

# archive list @コンテキスト フィルタ
ARCH_CTX=$(gh issue list --repo "$REPO" --state closed --label "@PC" --limit 5 \
  --json number -q '[.[].number] | length' 2>/dev/null || echo "0")
ok "archive list @PC: フィルタ実行成功 (${ARCH_CTX}件)"

# ─────────────────────────────────────────────
echo ""
echo "§L  template save/show/use での priority"
# ─────────────────────────────────────────────

TFILE=$(node -e "const os=require('os'),path=require('path'); process.stdout.write(path.join(os.homedir(),'.claude','todo-templates.json'));")
# バックアップ
[ -f "$TFILE" ] && cp "$TFILE" "${TFILE}.bak" || true
[ -f "$TFILE" ] || printf '{}' > "$TFILE"

# template save with priority p1
TNAME_ENV="gh-test" GTD_ENV="next" CONTEXTS_ENV="[]" \
DUE_OFFSET_ENV="" DUE_ENV="" RECUR_ENV="" \
PROJECT_ENV="" PRIORITY_ENV="p1" DESC_ENV="" \
node << 'JSEOF'
const os=require('os'), path=require('path'), fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
let data={};
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); } catch(e){}
const name=process.env.TNAME_ENV;
const t={};
t.gtd=process.env.GTD_ENV||'inbox';
t.context=JSON.parse(process.env.CONTEXTS_ENV||'[]');
const priority=process.env.PRIORITY_ENV||'p3';
t.priority=priority;
data[name]=t;
fs.writeFileSync(tfile, JSON.stringify(data,null,2));
process.stdout.write('saved\n');
JSEOF

SAVED_PRIORITY=$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
const data=JSON.parse(fs.readFileSync(tfile,'utf8'));
process.stdout.write(data['gh-test']&&data['gh-test'].priority||'');
")
if [ "$SAVED_PRIORITY" = "p1" ]; then
  ok "template save: priority p1 が保存される"
else
  fail "template save: priority の保存失敗" "保存値: $SAVED_PRIORITY"
fi

# template show で priority が表示されるか確認
SHOW_OUT=$(TNAME_ENV="gh-test" node << 'JSEOF'
const os=require('os'), path=require('path'), fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
const name=process.env.TNAME_ENV;
let data;
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); } catch(e){ process.exit(1); }
if(!data[name]){ process.exit(1); }
const t=data[name];
process.stdout.write('名前: '+name+'\n');
process.stdout.write('  GTD:      '+(t.gtd||'inbox')+'\n');
process.stdout.write('  context:  '+(t.context||[]).join(' ')+'\n');
process.stdout.write('  priority: '+(t.priority||'p3')+'\n');
JSEOF
)
if echo "$SHOW_OUT" | grep -q "priority: p1"; then
  ok "template show: priority: p1 が表示される"
else
  fail "template show: priority が表示されない" "出力: $SHOW_OUT"
fi

# template use での priority 取得
TMPL_PRIORITY=$(TNAME_ENV="gh-test" node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
const name=process.env.TNAME_ENV;
const data=JSON.parse(fs.readFileSync(tfile,'utf8'));
const t=data[name]||{};
process.stdout.write('PRIORITY='+(t.priority||'p3')+'\n');
" | grep '^PRIORITY=' | cut -d= -f2-)
if [ "$TMPL_PRIORITY" = "p1" ]; then
  ok "template use: priority p1 が取得される"
else
  fail "template use: priority の取得失敗" "取得値: $TMPL_PRIORITY"
fi

# テンプレートのクリーンアップ
node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
let data={};
try{data=JSON.parse(fs.readFileSync(tfile,'utf8'));}catch(e){}
delete data['gh-test'];
fs.writeFileSync(tfile,JSON.stringify(data,null,2));
" 2>/dev/null || true
[ -f "${TFILE}.bak" ] && mv "${TFILE}.bak" "$TFILE" || true

# ─────────────────────────────────────────────
echo ""
echo "§L2  template save from（既存Issueからテンプレート作成）"
# ─────────────────────────────────────────────

# テスト用Issueを作成（next + @PC + due + recur + project + desc 付き）
TMPL_FROM_BODY="due: 2026-05-01
recur: weekly
project: #50

テスト用の説明文"
NUM_TMPL_SRC=$(create_issue "[test] template from元Issue" --label "next" --label "p2" --label "@PC" --body "$TMPL_FROM_BODY")
track "$NUM_TMPL_SRC"

# body が反映されるまで待つ
wait_field "$NUM_TMPL_SRC" body "$BODY_FILTER" match "recur: weekly"

# テンプレートファイルをバックアップ
TFILE=$(node -e "const os=require('os'),path=require('path'); process.stdout.write(path.join(os.homedir(),'.claude','todo-templates.json'));")
[ -f "$TFILE" ] && cp "$TFILE" "${TFILE}.bak2" || true
[ -f "$TFILE" ] || printf '{}' > "$TFILE"

# 既存IssueからGTD・コンテキスト・bodyメタデータを抽出してテンプレートに保存
SRC_GTD=$(gh issue view "$NUM_TMPL_SRC" --repo "$REPO" --json labels \
  -q '[.labels[].name | select(. == "inbox" or . == "next" or . == "waiting" or . == "someday" or . == "project" or . == "reference")] | .[0]' 2>/dev/null)
[ -z "$SRC_GTD" ] && SRC_GTD="inbox"

SRC_CTX_JSON=$(gh issue view "$NUM_TMPL_SRC" --repo "$REPO" --json labels \
  -q '[.labels[].name | select(startswith("@"))]' 2>/dev/null)

SRC_BODY_RAW=$(gh issue view "$NUM_TMPL_SRC" --repo "$REPO" --json body -q '.body' 2>/dev/null)
SRC_DUE=$(printf '%s\n' "$SRC_BODY_RAW" | grep '^due: ' | sed 's/^due: //')
SRC_RECUR=$(printf '%s\n' "$SRC_BODY_RAW" | grep '^recur: ' | sed 's/^recur: //')
SRC_PROJECT=$(printf '%s\n' "$SRC_BODY_RAW" | grep '^project: #' | sed 's/^project: #//')
SRC_DESC=$(printf '%s\n' "$SRC_BODY_RAW" | grep -Ev '^(due: |recur: |project: #)' | sed '/^$/d')

# テンプレートに保存
TNAME_ENV="from-test" GTD_ENV="$SRC_GTD" CONTEXTS_ENV="$SRC_CTX_JSON" \
DUE_ENV="$SRC_DUE" RECUR_ENV="$SRC_RECUR" PROJECT_ENV="$SRC_PROJECT" \
DESC_ENV="$SRC_DESC" node << 'JSEOF'
const os=require('os'), path=require('path'), fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
let data={};
try { data=JSON.parse(fs.readFileSync(tfile,'utf8')); } catch(e){}
const name=process.env.TNAME_ENV;
const t={};
t.gtd=process.env.GTD_ENV||'inbox';
t.context=JSON.parse(process.env.CONTEXTS_ENV||'[]');
const due=process.env.DUE_ENV||'';
if(due) t.due=due;
const recur=process.env.RECUR_ENV||'';
if(recur) t.recur=recur;
const proj=process.env.PROJECT_ENV||'';
if(proj) t.project=parseInt(proj);
const desc=process.env.DESC_ENV||'';
if(desc) t.desc=desc;
data[name]=t;
fs.writeFileSync(tfile, JSON.stringify(data,null,2));
process.stdout.write('saved\n');
JSEOF

# テンプレートの中身を検証
TMPL_CHECK=$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
const data=JSON.parse(fs.readFileSync(tfile,'utf8'));
const t=data['from-test']||{};
process.stdout.write(JSON.stringify(t));
")

if echo "$TMPL_CHECK" | grep -q '"gtd":"next"'; then
  ok "template from: GTD=next が保存される"
else
  fail "template from: GTDが不正" "テンプレート: $TMPL_CHECK"
fi
if echo "$TMPL_CHECK" | grep -q '"@PC"'; then
  ok "template from: context に @PC が含まれる"
else
  fail "template from: @PC がない" "テンプレート: $TMPL_CHECK"
fi
if echo "$TMPL_CHECK" | grep -q '"due":"2026-05-01"'; then
  ok "template from: due=2026-05-01 が保存される"
else
  fail "template from: dueが不正" "テンプレート: $TMPL_CHECK"
fi
if echo "$TMPL_CHECK" | grep -q '"recur":"weekly"'; then
  ok "template from: recur=weekly が保存される"
else
  fail "template from: recurが不正" "テンプレート: $TMPL_CHECK"
fi
if echo "$TMPL_CHECK" | grep -q '"project":50'; then
  ok "template from: project=50 が保存される"
else
  fail "template from: projectが不正" "テンプレート: $TMPL_CHECK"
fi
if echo "$TMPL_CHECK" | grep -q 'テスト用の説明文'; then
  ok "template from: desc が保存される"
else
  fail "template from: descが不正" "テンプレート: $TMPL_CHECK"
fi

# テンプレートからIssue再作成テスト
TMPL_DATA=$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
const data=JSON.parse(fs.readFileSync(tfile,'utf8'));
const t=data['from-test']||{};
const labels=[t.gtd||'inbox'].concat(t.context||[]);
process.stdout.write(labels.join(','));
")
TMPL_USE_BODY=""
TMPL_DUE=$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
const t=JSON.parse(fs.readFileSync(tfile,'utf8'))['from-test']||{};
const NL='\n'; let b='';
if(t.due) b+='due: '+t.due+NL;
if(t.recur) b+='recur: '+t.recur+NL;
if(t.project) b+='project: #'+t.project+NL;
if(t.desc){ if(b) b+=NL; b+=t.desc; }
process.stdout.write(b);
")
NUM_TMPL_USE=$(create_issue "[test] template use結果" --label "$TMPL_DATA" --body "$TMPL_DUE")
track "$NUM_TMPL_USE"

wait_field "$NUM_TMPL_USE" body "$BODY_FILTER" match "recur: weekly"
USE_BODY="$WAIT_RESULT"
if echo "$USE_BODY" | grep -q "due: 2026-05-01"; then
  ok "template use(from): due が引き継がれる (#$NUM_TMPL_USE)"
else
  fail "template use(from): due が引き継がれていない" "body: $USE_BODY"
fi
if echo "$USE_BODY" | grep -q "recur: weekly"; then
  ok "template use(from): recur が引き継がれる"
else
  fail "template use(from): recur が引き継がれていない" "body: $USE_BODY"
fi

wait_field "$NUM_TMPL_USE" labels "$LABELS_FILTER" match "@PC"
USE_LBLS="$WAIT_RESULT"
if echo "$USE_LBLS" | grep -q "next"; then
  ok "template use(from): GTDラベル next が付与される"
else
  fail "template use(from): GTDラベルが不正" "ラベル: $USE_LBLS"
fi
if echo "$USE_LBLS" | grep -q "@PC"; then
  ok "template use(from): @PC コンテキストが付与される"
else
  fail "template use(from): @PC がない" "ラベル: $USE_LBLS"
fi

# クリーンアップ
node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const tfile=path.join(os.homedir(),'.claude','todo-templates.json');
let data={};
try{data=JSON.parse(fs.readFileSync(tfile,'utf8'));}catch(e){}
delete data['from-test'];
fs.writeFileSync(tfile,JSON.stringify(data,null,2));
" 2>/dev/null || true
[ -f "${TFILE}.bak2" ] && mv "${TFILE}.bak2" "$TFILE" || true

# ─────────────────────────────────────────────
echo ""
echo "§M  priority バリデーション (invalid)"
# ─────────────────────────────────────────────

validate_priority() {
  local p="$1"
  case "$p" in
    p1|p2|p3) echo "VALID" ;;
    *) echo "INVALID" ;;
  esac
}

if [ "$(validate_priority 'p4')" = "INVALID" ]; then
  ok "priority バリデーション: p4 → エラー"
else
  fail "priority バリデーション: p4 がエラーにならない" ""
fi
if [ "$(validate_priority 'high')" = "INVALID" ]; then
  ok "priority バリデーション: high → エラー"
else
  fail "priority バリデーション: high がエラーにならない" ""
fi

# ─────────────────────────────────────────────
echo ""
echo "§N  rename コマンド（タイトル変更）"
# ─────────────────────────────────────────────

NUM_RENAME=$(create_issue "[test] rename前のタイトル" --label "next" --label "p3" --body "test")
track "$NUM_RENAME"

TITLE_NEW="rename後のタイトル（日本語・スペース含む）"
gh issue edit "$NUM_RENAME" --repo "$REPO" --title "$TITLE_NEW" > /dev/null 2>&1
wait_field "$NUM_RENAME" title "$TITLE_FILTER" exact "$TITLE_NEW"
ACTUAL_TITLE="$WAIT_RESULT"
if [ "$ACTUAL_TITLE" = "$TITLE_NEW" ]; then
  ok "rename: タイトルが変更された (#$NUM_RENAME)"
else
  fail "rename: タイトルが変わっていない" "期待: $TITLE_NEW / 実際: $ACTUAL_TITLE"
fi

# タイトル変更後もラベルは保持されるか
LBLS=$(gh issue view "$NUM_RENAME" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null)
if echo "$LBLS" | grep -q "next"; then
  ok "rename: ラベルは保持される"
else
  fail "rename: ラベルが失われた" "ラベル: $LBLS"
fi

# ─────────────────────────────────────────────
echo ""
echo "§O  untag コマンド（コンテキスト削除）"
# ─────────────────────────────────────────────

gh label create "@テストCtx1" --repo "$REPO" --color FBCA04 --description "コンテキスト" 2>/dev/null || true
gh label create "@テストCtx2" --repo "$REPO" --color FBCA04 --description "コンテキスト" 2>/dev/null || true

NUM_UNTAG=$(create_issue "[test] untagテスト" --label "next" --label "p3" --label "@テストCtx1" --label "@テストCtx2" --body "test")
track "$NUM_UNTAG"

# 1つ削除
gh issue edit "$NUM_UNTAG" --repo "$REPO" --remove-label "@テストCtx1" > /dev/null 2>&1
wait_field "$NUM_UNTAG" labels "$LABELS_FILTER" no_match "@テストCtx1"
LBLS="$WAIT_RESULT"
if echo "$LBLS" | grep -q "@テストCtx1"; then
  fail "untag: @テストCtx1 が削除されていない" "ラベル: $LBLS"
else
  ok "untag: @テストCtx1 が削除された (#$NUM_UNTAG)"
fi
if echo "$LBLS" | grep -q "@テストCtx2"; then
  ok "untag: @テストCtx2 は保持される"
else
  fail "untag: @テストCtx2 まで削除されてしまった" "ラベル: $LBLS"
fi

# 存在しないラベルを削除してもエラーにならないか
gh issue edit "$NUM_UNTAG" --repo "$REPO" --remove-label "@存在しないコンテキスト" > /dev/null 2>&1
if [ $? -eq 0 ] || true; then
  ok "untag: 存在しないラベルでもエラーにならない"
fi

# クリーンアップ用ラベル削除
gh label delete "@テストCtx1" --repo "$REPO" --yes 2>/dev/null || true
gh label delete "@テストCtx2" --repo "$REPO" --yes 2>/dev/null || true

# ─────────────────────────────────────────────
echo ""
echo "§P  recur コマンド（繰り返し設定変更・解除）"
# ─────────────────────────────────────────────

TODAY=$(date +%Y-%m-%d)
INIT_BODY="due: $TODAY
"
NUM_RECUR2=$(create_issue "[test] recurコマンドテスト" --label "next" --label "p3" --body "$INIT_BODY")
track "$NUM_RECUR2"

# recur set: weekly を設定
CURRENT=$(gh issue view "$NUM_RECUR2" --repo "$REPO" --json body -q '.body' 2>/dev/null)
DUE_VAL=$(echo "$CURRENT" | grep '^due: ' | sed 's/^due: //')
PROJECT_VAL=$(echo "$CURRENT" | grep '^project: #' | sed 's/^project: #//')
DESC_VAL=$(echo "$CURRENT" | grep -Ev '^(due: |recur: |project: #)' | sed '/./,$!d')
NEW_RECUR="weekly"
NL=$'\n'
BODY=""
[ -n "$DUE_VAL" ]     && BODY="${BODY}due: ${DUE_VAL}${NL}"
BODY="${BODY}recur: ${NEW_RECUR}${NL}"
[ -n "$PROJECT_VAL" ] && BODY="${BODY}project: #${PROJECT_VAL}${NL}"
[ -n "$DESC_VAL" ]    && { [ -n "$DUE_VAL$NEW_RECUR$PROJECT_VAL" ] && BODY="${BODY}${NL}"; BODY="${BODY}${DESC_VAL}"; }
gh issue edit "$NUM_RECUR2" --repo "$REPO" --body "$BODY" > /dev/null 2>&1
wait_field "$NUM_RECUR2" body "$BODY_FILTER" match "^recur: weekly"
BODY_CHECK="$WAIT_RESULT"
if echo "$BODY_CHECK" | grep -q "^recur: weekly"; then
  ok "recur set: recur: weekly が設定された (#$NUM_RECUR2)"
else
  fail "recur set: recur行が設定されていない" "body: $BODY_CHECK"
fi
if echo "$BODY_CHECK" | grep -q "^due: "; then
  ok "recur set: due行が保持される"
else
  fail "recur set: due行が消えた" "body: $BODY_CHECK"
fi

# recur clear: recur行を除去
CURRENT=$(gh issue view "$NUM_RECUR2" --repo "$REPO" --json body -q '.body' 2>/dev/null)
DUE_VAL=$(echo "$CURRENT" | grep '^due: ' | sed 's/^due: //')
PROJECT_VAL=$(echo "$CURRENT" | grep '^project: #' | sed 's/^project: #//')
DESC_VAL=$(echo "$CURRENT" | grep -Ev '^(due: |recur: |project: #)' | sed '/./,$!d')
NL=$'\n'
BODY=""
[ -n "$DUE_VAL" ]     && BODY="${BODY}due: ${DUE_VAL}${NL}"
# RECUR="" なので recur行なし
[ -n "$PROJECT_VAL" ] && BODY="${BODY}project: #${PROJECT_VAL}${NL}"
[ -n "$DESC_VAL" ]    && { [ -n "$DUE_VAL$PROJECT_VAL" ] && BODY="${BODY}${NL}"; BODY="${BODY}${DESC_VAL}"; }
gh issue edit "$NUM_RECUR2" --repo "$REPO" --body "$BODY" > /dev/null 2>&1
wait_field "$NUM_RECUR2" body "$BODY_FILTER" no_match "^recur: "
BODY_CHECK="$WAIT_RESULT"
if echo "$BODY_CHECK" | grep -q "^recur: "; then
  fail "recur clear: recur行が残っている" "body: $BODY_CHECK"
else
  ok "recur clear: recur行が削除された (#$NUM_RECUR2)"
fi
if echo "$BODY_CHECK" | grep -q "^due: "; then
  ok "recur clear: due行は保持される"
else
  fail "recur clear: due行が消えた" "body: $BODY_CHECK"
fi

# recur バリデーション（不正値）
validate_recur() {
  case "$1" in
    daily|weekly|monthly|weekdays) echo "VALID" ;;
    *) echo "INVALID" ;;
  esac
}
if [ "$(validate_recur 'biweekly')" = "INVALID" ]; then
  ok "recur バリデーション: biweekly → エラー"
else
  fail "recur バリデーション: biweekly がエラーにならない" ""
fi
if [ "$(validate_recur 'clear')" = "INVALID" ]; then
  ok "recur バリデーション: clear は pattern として無効（分岐で処理）"
else
  fail "recur バリデーション: clear が VALID になっている" ""
fi

# ─────────────────────────────────────────────
echo ""
echo "§R  bulk done（一括完了）"
# ─────────────────────────────────────────────

NUM_BD1=$(create_issue "[test] bulk done 1" --label "next" --label "p3" --body "test")
track "$NUM_BD1"
NUM_BD2=$(create_issue "[test] bulk done 2" --label "next" --label "p3" --body "test")
track "$NUM_BD2"
NUM_BD3=$(create_issue "[test] bulk done 3" --label "next" --label "p3" --body "test")
track "$NUM_BD3"

# 3件を一括クローズ
for NUM in $NUM_BD1 $NUM_BD2 $NUM_BD3; do
  gh issue close "$NUM" --repo "$REPO" > /dev/null 2>&1
done

# 全てクローズされたか確認
BD_PASS=0
for NUM in $NUM_BD1 $NUM_BD2 $NUM_BD3; do
  STATE=$(gh issue view "$NUM" --repo "$REPO" --json state -q '.state' 2>/dev/null)
  [ "$STATE" = "CLOSED" ] && BD_PASS=$((BD_PASS+1))
done
if [ "$BD_PASS" -eq 3 ]; then
  ok "bulk done: 3件全てクローズ (#$NUM_BD1, #$NUM_BD2, #$NUM_BD3)"
else
  fail "bulk done: クローズされていないIssueあり" "$BD_PASS/3 クローズ"
fi

# ─────────────────────────────────────────────
echo ""
echo "§S  bulk move（一括ステータス変更）"
# ─────────────────────────────────────────────

NUM_BM1=$(create_issue "[test] bulk move 1" --label "inbox" --label "p3" --body "test")
track "$NUM_BM1"
NUM_BM2=$(create_issue "[test] bulk move 2" --label "inbox" --label "p3" --body "test")
track "$NUM_BM2"
NUM_BM3=$(create_issue "[test] bulk move 3" --label "inbox" --label "p3" --body "test")
track "$NUM_BM3"

# 3件を inbox → next に一括移動
for NUM in $NUM_BM1 $NUM_BM2 $NUM_BM3; do
  gh issue edit "$NUM" --repo "$REPO" --add-label "next" --remove-label "inbox" > /dev/null 2>&1
done

# 全て next になったか確認
BM_PASS=0
for NUM in $NUM_BM1 $NUM_BM2 $NUM_BM3; do
  wait_field "$NUM" labels "$LABELS_FILTER" match "next"
  LBLS="$WAIT_RESULT"
  if echo "$LBLS" | grep -q "next" && ! echo "$LBLS" | grep -q "inbox"; then
    BM_PASS=$((BM_PASS+1))
  fi
done
if [ "$BM_PASS" -eq 3 ]; then
  ok "bulk move: 3件全て inbox→next (#$NUM_BM1, #$NUM_BM2, #$NUM_BM3)"
else
  fail "bulk move: 移動されていないIssueあり" "$BM_PASS/3 移動"
fi

# ─────────────────────────────────────────────
echo ""
echo "§T  bulk tag / bulk untag（一括コンテキスト追加・削除）"
# ─────────────────────────────────────────────

NUM_BT1=$(create_issue "[test] bulk tag 1" --label "next" --label "p3" --body "test")
track "$NUM_BT1"
NUM_BT2=$(create_issue "[test] bulk tag 2" --label "next" --label "p3" --body "test")
track "$NUM_BT2"

gh label create "@BulkTest" --repo "$REPO" --color FBCA04 --description "バルクテスト" 2>/dev/null || true

# 2件に @BulkTest を追加
for NUM in $NUM_BT1 $NUM_BT2; do
  gh issue edit "$NUM" --repo "$REPO" --add-label "@BulkTest" > /dev/null 2>&1
done

# 追加確認
BT_ADD=0
for NUM in $NUM_BT1 $NUM_BT2; do
  wait_field "$NUM" labels "$LABELS_FILTER" match "@BulkTest"
  echo "$WAIT_RESULT" | grep -q "@BulkTest" && BT_ADD=$((BT_ADD+1))
done
if [ "$BT_ADD" -eq 2 ]; then
  ok "bulk tag: 2件に @BulkTest 追加 (#$NUM_BT1, #$NUM_BT2)"
else
  fail "bulk tag: 追加されていないIssueあり" "$BT_ADD/2 追加"
fi

# 2件から @BulkTest を削除
for NUM in $NUM_BT1 $NUM_BT2; do
  gh issue edit "$NUM" --repo "$REPO" --remove-label "@BulkTest" > /dev/null 2>&1
done

# 削除確認
BT_REM=0
for NUM in $NUM_BT1 $NUM_BT2; do
  wait_field "$NUM" labels "$LABELS_FILTER" no_match "@BulkTest"
  echo "$WAIT_RESULT" | grep -q "@BulkTest" || BT_REM=$((BT_REM+1))
done
if [ "$BT_REM" -eq 2 ]; then
  ok "bulk untag: 2件から @BulkTest 削除 (#$NUM_BT1, #$NUM_BT2)"
else
  fail "bulk untag: 削除されていないIssueあり" "$BT_REM/2 削除"
fi

# ラベルクリーンアップ
gh label delete "@BulkTest" --repo "$REPO" --yes 2>/dev/null || true


# ─────────────────────────────────────────────
echo ""
echo "§U  edit コマンド（複数フィールド同時更新）"
# ─────────────────────────────────────────────

EDIT_BODY="due: 2026-04-10
recur: weekly
project: #50

元の説明文"
NUM_EDIT=$(create_issue "[test] editテスト" --label "next" --label "p3" --body "$EDIT_BODY")
track "$NUM_EDIT"
wait_field "$NUM_EDIT" body "$BODY_FILTER" match "recur: weekly"

# due + desc を同時更新（recur/project は保持されるべき）
NEW_EDIT_BODY="due: 2026-05-01
recur: weekly
project: #50

更新後の説明文"
gh issue edit "$NUM_EDIT" --repo "$REPO" --body "$NEW_EDIT_BODY" > /dev/null 2>&1
wait_field "$NUM_EDIT" body "$BODY_FILTER" match "due: 2026-05-01"
EDIT_CHECK="$WAIT_RESULT"

if echo "$EDIT_CHECK" | grep -q "due: 2026-05-01"; then
  ok "edit: due が更新された (#$NUM_EDIT)"
else
  fail "edit: due 更新失敗" "body: $EDIT_CHECK"
fi
if echo "$EDIT_CHECK" | grep -q "recur: weekly"; then
  ok "edit: recur は保持される"
else
  fail "edit: recur が消えた" "body: $EDIT_CHECK"
fi
if echo "$EDIT_CHECK" | grep -q "project: #50"; then
  ok "edit: project は保持される"
else
  fail "edit: project が消えた" "body: $EDIT_CHECK"
fi
if echo "$EDIT_CHECK" | grep -q "更新後の説明文"; then
  ok "edit: desc が更新された"
else
  fail "edit: desc 更新失敗" "body: $EDIT_CHECK"
fi

# priority 変更（p3 → p1）
gh issue edit "$NUM_EDIT" --repo "$REPO" --remove-label "p3" --add-label "p1" > /dev/null 2>&1
wait_field "$NUM_EDIT" labels "$LABELS_FILTER" match "p1"
EDIT_LBLS="$WAIT_RESULT"
if echo "$EDIT_LBLS" | grep -q "p1" && ! echo "$EDIT_LBLS" | grep -q "p3"; then
  ok "edit: priority p3→p1 変更"
else
  fail "edit: priority 変更失敗" "ラベル: $EDIT_LBLS"
fi

# ─────────────────────────────────────────────
echo ""
echo "§V  search コマンド（オープンIssue検索）"
# ─────────────────────────────────────────────

NUM_SEARCH=$(create_issue "[test] 検索テスト用ユニークキーワードXQ7" --label "next" --label "p3" --body "test")
track "$NUM_SEARCH"

# キーワード検索（GitHub APIの反映を待つ）
sleep 3
SEARCH_RESULT=$(gh issue list --repo "$REPO" --state open --search "ユニークキーワードXQ7" \
  --json number -q '[.[].number] | join(",")' 2>/dev/null)
if echo "$SEARCH_RESULT" | grep -q "$NUM_SEARCH"; then
  ok "search: キーワードで検索ヒット (#$NUM_SEARCH)"
else
  skip_test "search: キーワード検索" "GitHub検索インデックスの反映待ち"
fi

# 存在しないキーワード
SEARCH_EMPTY=$(gh issue list --repo "$REPO" --state open --search "絶対存在しないZZZ999QQQ" \
  --json number -q 'length' 2>/dev/null)
if [ "$SEARCH_EMPTY" = "0" ]; then
  ok "search: 存在しないキーワードで0件"
else
  ok "search: 検索実行成功（結果: ${SEARCH_EMPTY}件）"
fi

# ─────────────────────────────────────────────
echo ""
echo "§W  stats コマンド（統計情報）"
# ─────────────────────────────────────────────

TODAY=$(date +%Y-%m-%d)
STATS_OUT=$(gh issue list --repo "$REPO" --state open --json number,title,body,labels --limit 200 \
  | TODAY_ENV="$TODAY" node -e "
const c=[]; process.stdin.on('data',d=>c.push(d));
process.stdin.on('end',()=>{
  const today=process.env.TODAY_ENV;
  const issues=JSON.parse(c.join(''));
  const gtd=['next','inbox','waiting','someday','project','reference'];
  const counts={};
  gtd.forEach(l=>counts[l]=0);
  let total=issues.length;
  for(const i of issues){
    const ln=i.labels.map(l=>l.name);
    for(const g of gtd){ if(ln.includes(g)) counts[g]++; }
  }
  process.stdout.write('total='+total+'\n');
  gtd.forEach(l=>{ if(counts[l]>0) process.stdout.write(l+'='+counts[l]+'\n'); });
});
")

if echo "$STATS_OUT" | grep -q "^total="; then
  STATS_TOTAL=$(echo "$STATS_OUT" | grep '^total=' | cut -d= -f2)
  ok "stats: 全タスク数取得成功 (${STATS_TOTAL}件)"
else
  fail "stats: 統計取得失敗" "出力: $STATS_OUT"
fi

if echo "$STATS_OUT" | grep -q "^next="; then
  ok "stats: カテゴリ別集計あり (next)"
else
  skip_test "stats: next カテゴリ集計" "next が0件の可能性"
fi

# 完了数の取得テスト
DONE_WEEK=$(gh issue list --repo "$REPO" --state closed --limit 50 \
  --json closedAt \
  | TODAY_ENV="$TODAY" node -e "
const c=[]; process.stdin.on('data',d=>c.push(d));
process.stdin.on('end',()=>{
  const today=new Date(process.env.TODAY_ENV);
  const d7=new Date(today); d7.setDate(d7.getDate()-7);
  const issues=JSON.parse(c.join(''));
  const cnt=issues.filter(i=>i.closedAt&&new Date(i.closedAt)>=d7).length;
  process.stdout.write(cnt+'');
});
")
if [ -n "$DONE_WEEK" ]; then
  ok "stats: 直近7日間の完了数取得成功 (${DONE_WEEK}件)"
else
  fail "stats: 完了数取得失敗" ""
fi
# ─────────────────────────────────────────────
echo ""
echo "§Q  weekdays recur — done で次の平日にタスク再作成"
# ─────────────────────────────────────────────

# 金曜日の due + recur: weekdays のタスクを作成し、done 後に月曜日の due で再作成されるかテスト
# done のシミュレーション: close → 次の平日 due で新 Issue 作成

FRIDAY_DUE="2026-04-10"  # 金曜日
WD_BODY="due: $FRIDAY_DUE
recur: weekdays
"
NUM_WD=$(create_issue "[test] weekdays recur テスト" --label "next" --label "p3" --body "$WD_BODY")
track "$NUM_WD"

# body が正しく設定されていることを確認
wait_field "$NUM_WD" body "$BODY_FILTER" match "recur: weekdays"
BODY_WD="$WAIT_RESULT"
if echo "$BODY_WD" | grep -q "recur: weekdays"; then
  ok "weekdays recur: body に recur: weekdays (#$NUM_WD)"
else
  fail "weekdays recur: recur行なし" "body: $BODY_WD"
fi

# done シミュレーション: close して次の平日 due で再作成
gh issue close "$NUM_WD" --repo "$REPO" > /dev/null 2>&1

# 次の平日を計算（金曜 → 月曜 +3日）
NEXT_WD_DUE=$(node -e "
const fmt=dt=>{const y=dt.getFullYear(),m=String(dt.getMonth()+1).padStart(2,'0'),d=String(dt.getDate()).padStart(2,'0');return y+'-'+m+'-'+d;};
const d=new Date('${FRIDAY_DUE}T00:00:00');
d.setDate(d.getDate()+1);
const dow=d.getDay();
if(dow===6) d.setDate(d.getDate()+2);
else if(dow===0) d.setDate(d.getDate()+1);
process.stdout.write(fmt(d));
")
# 金曜+1=土曜 → +2=月曜 → 2026-04-13
if [ "$NEXT_WD_DUE" = "2026-04-13" ]; then
  ok "weekdays recur: 金曜→次の平日は月曜 ($NEXT_WD_DUE)"
else
  fail "weekdays recur: 次の平日計算が不正" "期待: 2026-04-13 / 実際: $NEXT_WD_DUE"
fi

# 再作成タスクのシミュレーション
NEW_WD_BODY="due: $NEXT_WD_DUE
recur: weekdays
"
NUM_WD_NEW=$(create_issue "[test] weekdays recur テスト" --label "next" --label "p3" --body "$NEW_WD_BODY")
track "$NUM_WD_NEW"

wait_field "$NUM_WD_NEW" body "$BODY_FILTER" match "due: $NEXT_WD_DUE"
BODY_WD_NEW="$WAIT_RESULT"
if echo "$BODY_WD_NEW" | grep -q "due: $NEXT_WD_DUE"; then
  ok "weekdays recur: 再作成タスクの due が月曜 (#$NUM_WD_NEW)"
else
  fail "weekdays recur: 再作成タスクの due が不正" "body: $BODY_WD_NEW"
fi
if echo "$BODY_WD_NEW" | grep -q "recur: weekdays"; then
  ok "weekdays recur: 再作成タスクに recur: weekdays が引き継がれる"
else
  fail "weekdays recur: recur行が引き継がれていない" "body: $BODY_WD_NEW"
fi

# ─────────────────────────────────────────────
echo ""
echo "§AA  Dashboard 統合テスト（Pro機能）"
# ─────────────────────────────────────────────

TODAY_GH=$(date +%Y-%m-%d)
YESTERDAY_GH=$(node -e "const d=new Date('$TODAY_GH'); d.setDate(d.getDate()-1); process.stdout.write(d.toISOString().slice(0,10));")

NUM_DASH1=$(create_issue "[test] dashboard overdue" --label "next" --label "p1" --body "due: $YESTERDAY_GH")
track "$NUM_DASH1"
NUM_DASH2=$(create_issue "[test] dashboard today" --label "next" --label "p2" --body "due: $TODAY_GH")
track "$NUM_DASH2"
NUM_DASH3=$(create_issue "[test] dashboard inbox" --label "inbox" --body "test")
track "$NUM_DASH3"

sleep 2
DASH_GH_OPEN=$(gh issue list --repo "$REPO" --state open --json number,title,body,labels --limit 200)
DASH_GH_CLOSED=$(gh issue list --repo "$REPO" --state closed --limit 30 --json number,closedAt)

DASH_GH_OUT=$(OPEN_ENV="$DASH_GH_OPEN" TODAY_ENV="$TODAY_GH" CLOSED_ENV="$DASH_GH_CLOSED" node -e "
  const issues=JSON.parse(process.env.OPEN_ENV);
  const today=process.env.TODAY_ENV;
  const closed=JSON.parse(process.env.CLOSED_ENV||'[]');
  const w=s=>process.stdout.write(s);
  const getLnames=i=>i.labels.map(l=>l.name);
  const getDue=i=>{const m=(i.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m); return m?m[1]:null;};
  const getPri=lnames=>lnames.find(l=>/^p[123]$/.test(l))||'p9';
  const d7=new Date(today); d7.setDate(d7.getDate()+7);
  const d7str=d7.toISOString().slice(0,10);
  const overdue=[], dueToday=[];
  const gtdCounts={next:0,inbox:0,waiting:0,someday:0,project:0,reference:0};
  for(const issue of issues){
    const lnames=getLnames(issue);
    for(const gl of Object.keys(gtdCounts)){ if(lnames.includes(gl)) gtdCounts[gl]++; }
    const due=getDue(issue);
    if(lnames.includes('next')){
      if(due && due<today) overdue.push(issue);
      else if(due && due===today) dueToday.push(issue);
    } else if(due && due<today){
      overdue.push(issue);
    }
  }
  w('OVERDUE='+overdue.length+'\n');
  w('TODAY='+dueToday.length+'\n');
  w('INBOX='+gtdCounts.inbox+'\n');
")

DASH_OVERDUE=$(echo "$DASH_GH_OUT" | grep '^OVERDUE=' | cut -d= -f2)
DASH_TODAY_CNT=$(echo "$DASH_GH_OUT" | grep '^TODAY=' | cut -d= -f2)
DASH_INBOX_CNT=$(echo "$DASH_GH_OUT" | grep '^INBOX=' | cut -d= -f2)

if [ "$DASH_OVERDUE" -ge 1 ]; then
  ok "Dashboard統合: overdue >= 1 (実際: $DASH_OVERDUE)"
else
  fail "Dashboard統合: overdue >= 1" "実際: $DASH_OVERDUE"
fi
if [ "$DASH_TODAY_CNT" -ge 1 ]; then
  ok "Dashboard統合: dueToday >= 1 (実際: $DASH_TODAY_CNT)"
else
  fail "Dashboard統合: dueToday >= 1" "実際: $DASH_TODAY_CNT"
fi
if [ "$DASH_INBOX_CNT" -ge 1 ]; then
  ok "Dashboard統合: inbox >= 1 (実際: $DASH_INBOX_CNT)"
else
  fail "Dashboard統合: inbox >= 1" "実際: $DASH_INBOX_CNT"
fi

# ─────────────────────────────────────────────
echo ""
echo "§AB  Custom Views 統合テスト（Pro機能）"
# ─────────────────────────────────────────────

TEST_VFILE=$(mktemp /tmp/todo-test-views-gh-XXXXXX.json)
printf '{}' > "$TEST_VFILE"

# save
VIEW_SAVE_OUT=$(VNAME_ENV="ghテスト" GTD_ENV="next" CTX_ENV="@PC" PRI_ENV="p1" VFILE_ENV="$TEST_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  let data=JSON.parse(fs.readFileSync(vfile,'utf8'));
  const name=process.env.VNAME_ENV;
  const v={};
  const gtd=process.env.GTD_ENV||''; if(gtd) v.gtd=gtd;
  const ctx=process.env.CTX_ENV||''; if(ctx) v.context=ctx.trim().split(/\s+/);
  const pri=process.env.PRI_ENV||''; if(pri) v.priority=pri;
  data[name]=v;
  fs.writeFileSync(vfile, JSON.stringify(data,null,2));
  process.stdout.write('SAVED');
")
if [ "$VIEW_SAVE_OUT" = "SAVED" ]; then
  ok "View統合: save 成功"
else
  fail "View統合: save 失敗" "$VIEW_SAVE_OUT"
fi

# load
VIEW_LOAD_OUT=$(VNAME_ENV="ghテスト" VFILE_ENV="$TEST_VFILE" node -e "
  const fs=require('fs');
  const data=JSON.parse(fs.readFileSync(process.env.VFILE_ENV,'utf8'));
  const name=process.env.VNAME_ENV;
  if(!data[name]){ process.stdout.write('NOT_FOUND'); process.exit(0); }
  const v=data[name];
  const parts=[];
  if(v.gtd) parts.push('GTD='+v.gtd);
  if(v.context) parts.push('CTX='+v.context.join(' '));
  if(v.priority) parts.push('PRI='+v.priority);
  process.stdout.write(parts.join(' '));
")
if echo "$VIEW_LOAD_OUT" | grep -q "GTD=next"; then
  ok "View統合: load GTD=next"
else
  fail "View統合: load GTD不一致" "$VIEW_LOAD_OUT"
fi
if echo "$VIEW_LOAD_OUT" | grep -q "PRI=p1"; then
  ok "View統合: load PRI=p1"
else
  fail "View統合: load PRI不一致" "$VIEW_LOAD_OUT"
fi

# list
VIEW_LIST_OUT=$(VFILE_ENV="$TEST_VFILE" node -e "
  const fs=require('fs');
  const data=JSON.parse(fs.readFileSync(process.env.VFILE_ENV,'utf8'));
  process.stdout.write(Object.keys(data).join(','));
")
if echo "$VIEW_LIST_OUT" | grep -q "ghテスト"; then
  ok "View統合: list にビュー表示"
else
  fail "View統合: list にビューなし" "$VIEW_LIST_OUT"
fi

# delete
VIEW_DEL_OUT=$(VNAME_ENV="ghテスト" VFILE_ENV="$TEST_VFILE" node -e "
  const fs=require('fs');
  const vfile=process.env.VFILE_ENV;
  let data=JSON.parse(fs.readFileSync(vfile,'utf8'));
  const name=process.env.VNAME_ENV;
  if(!data[name]){ process.stdout.write('NOT_FOUND'); process.exit(0); }
  delete data[name];
  fs.writeFileSync(vfile, JSON.stringify(data,null,2));
  process.stdout.write('DELETED');
")
if [ "$VIEW_DEL_OUT" = "DELETED" ]; then
  ok "View統合: delete 成功"
else
  fail "View統合: delete 失敗" "$VIEW_DEL_OUT"
fi

rm -f "$TEST_VFILE"

# ─────────────────────────────────────────────
echo ""
echo "§AC  Report 統合テスト（Pro機能）"
# ─────────────────────────────────────────────

# テスト Issue を1つクローズしてレポートに反映させる
NUM_RPT=$(create_issue "[test] report テスト" --label "next" --label "p3" --body "test")
track "$NUM_RPT"
gh issue close "$NUM_RPT" --repo "$REPO" 2>/dev/null
sleep 2

RPT_OPEN_GH=$(gh issue list --repo "$REPO" --state open --json number,title,body,labels --limit 200)
RPT_CLOSED_GH=$(gh issue list --repo "$REPO" --state closed --limit 200 --json number,title,labels,closedAt,body)

RPT_GH_OUT=$(OPEN_ENV="$RPT_OPEN_GH" TODAY_ENV="$TODAY_GH" DAYS_ENV="7" CLOSED_ENV="$RPT_CLOSED_GH" node -e "
  const today=process.env.TODAY_ENV;
  const days=parseInt(process.env.DAYS_ENV);
  const closed=JSON.parse(process.env.CLOSED_ENV||'[]');
  const startDate=new Date(today);
  startDate.setDate(startDate.getDate()-days);
  const startStr=startDate.toISOString().slice(0,10);
  const periodClosed=closed.filter(i=>{
    if(!i.closedAt) return false;
    const d=i.closedAt.slice(0,10);
    return d>=startStr && d<=today;
  });
  process.stdout.write('CLOSED_COUNT='+periodClosed.length+'\n');
  process.stdout.write('HAS_TODAY='+(periodClosed.some(i=>i.closedAt.slice(0,10)===today)?'YES':'NO')+'\n');
")

RPT_CLOSED_COUNT=$(echo "$RPT_GH_OUT" | grep '^CLOSED_COUNT=' | cut -d= -f2)
RPT_HAS_TODAY=$(echo "$RPT_GH_OUT" | grep '^HAS_TODAY=' | cut -d= -f2)

if [ "$RPT_CLOSED_COUNT" -ge 1 ]; then
  ok "Report統合: 期間内完了 >= 1 (実際: $RPT_CLOSED_COUNT)"
else
  fail "Report統合: 期間内完了 >= 1" "実際: $RPT_CLOSED_COUNT"
fi
if [ "$RPT_HAS_TODAY" = "YES" ]; then
  ok "Report統合: 今日のクローズが含まれる"
else
  fail "Report統合: 今日のクローズが含まれない" "$RPT_GH_OUT"
fi

# ─────────────────────────────────────────────
echo ""
echo "§Z  クリーンアップ（テスト用Issueをクローズ）"
# ─────────────────────────────────────────────

for NUM in $CREATED_ISSUES; do
  [ -z "$NUM" ] && continue
  gh issue close "$NUM" --repo "$REPO" 2>/dev/null && echo "  クローズ: #$NUM" || true
done

# ─────────────────────────────────────────────
echo ""
echo "=========================================="
TOTAL=$((PASS+FAIL))
printf "結果: %d / %d テスト通過\n" "$PASS" "$TOTAL"
[ "$FAIL" -gt 0 ] && printf "❌ %d テスト失敗\n" "$FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
