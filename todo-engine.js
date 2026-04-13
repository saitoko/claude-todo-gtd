#!/usr/bin/env node
// todo-engine.js — /todo スキルの deterministic 処理エンジン
// Claude が毎回コピペしていた Node.js ブロックとバリデーションを集約

'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

// ─── 定数 ───
const GTD_LABELS = ['next','routine','inbox','waiting','someday','project','reference'];
const GTD_DISPLAY = {
  next: '🎯 next', routine: '🔁 routine', inbox: '📥 inbox', waiting: '⏳ waiting',
  someday: '🌈 someday', project: '📁 project', reference: '📎 reference'
};
const FORBIDDEN_CHARS = ';$`()\"\'' + String.fromCharCode(92) + '|&><{}[]';
const PRI_COLORS = { p1: 'B60205', p2: 'FBCA04', p3: '0075CA' };

// ─── i18n ───
const LANG = process.env.LANG_ENV || 'ja';
const MESSAGES = {
  ja: {
    // エラー系
    'error.ctx_invalid': 'エラー: コンテキスト名に不正文字が含まれています',
    'error.positive_int': 'エラー: 正の整数が必要です',
    'error.date_format': 'エラー: 不正な日付形式です',
    'error.recur_invalid': 'エラー: recur は daily/weekly/monthly/weekdays のみ有効です',
    'error.color_invalid': 'エラー: カラーは6桁の16進数のみ有効です（例: FBCA04）',
    'error.priority_invalid': 'エラー: --priority は p1/p2/p3 のみ有効です',
    'error.name_empty': 'エラー: 名前が空です',
    'error.name_invalid': 'エラー: 名前に不正文字が含まれています（; $ ` ( ) " \' \\\\ | & > < { } [ ] 不可）',
    'error.time_format': 'エラー: 時間は 30m / 1h / 1h30m 形式で指定してください',
    'error.file_corrupt': 'エラー: ファイルが破損しています',
    // 警告
    'warn.month_rollover': '⚠️ 注意: {day}日は翌月に存在しないため、{date} に繰り上がりました',
    // セクションヘッダー
    'section.next': '## ✅ Next Actions（次のアクション）',
    'section.routine': '## 🔁 Routine（ルーティン）',
    'section.inbox': '## 📥 Inbox（受信トレイ）',
    'section.waiting': '## ⏳ Waiting For（待ち）',
    'section.someday': '## 🌈 Someday/Maybe（いつかやるかも）',
    'section.project': '## 📁 Projects（プロジェクト）',
    'section.reference': '## 📎 Reference（参照情報）',
    // listAll / listSummary
    'list.no_match': '（該当タスクなし）',
    'list.none': '（なし）',
    'list.no_tasks': '（タスクなし）',
    'list.has_next': '✅ Next Action あり',
    'list.no_next': '⚠️ Next Actionなし',
    'list.overdue': '期限超過',
    'list.this_week': '今週期限',
    // weeklySummary
    'weekly.header': '## 📋 週次レビュー サマリー',
    'weekly.current_status': '**現在のタスク状況:**',
    'weekly.no_overdue': '✅ 期限超過なし',
    'weekly.inbox_pending': '📥 Inbox に {n} の未処理タスクがあります。Step 1 で仕分けます。',
    'weekly.start': '---\nレビューを開始します。',
    // stats
    'stats.header': '## 📊 タスク統計',
    'stats.total': '**全タスク: {n}**',
    'stats.by_category': '### カテゴリ別',
    'stats.by_priority': '### 優先度別',
    'stats.no_priority': '優先度なし',
    'stats.by_deadline': '### 期限',
    'stats.completed': '### 完了実績',
    'stats.last7days': '直近7日間: {n}完了',
    'stats.time_section': '### 時間',
    'stats.est_total': '見積合計（next）: {time} ({n})',
    'stats.no_estimate': '見積なし: {n}',
    // dashboard
    'dash.overdue': '## ⚠️ 期限超過（{n}）',
    'dash.today': '## \uD83C\uDFAF 今日やること（{n}）',
    'dash.this_week': '## 📅 今週期限（{n}）',
    'dash.next_actions': '## ✅ Next Actions（{n}）',
    'dash.more': '  ...他 {n}',
    'dash.today_est': '⏱今日の見積: {time}',
    'dash.done_summary': '✅ 今日: {today}完了 / 今週: {week}完了',
    'dash.inbox_hint': '💡 Inbox に {n} の未処��タスクがあります。',
    // report
    'report.header': '# 📊 生産性レポート',
    'report.period': '**期間:** {start} 〜 {end}（{days}日間）',
    'report.completed_summary': '## 完了サマリー',
    'report.metric': '指標',
    'report.value': '値',
    'report.completed_count': '完了タスク数',
    'report.daily_avg': '1日あたり平均',
    'report.current_open': '現在のオープン',
    'report.overdue': '期限超過',
    'report.daily_completed': '## 日別完了数',
    'report.by_category': '## カテゴリ別完了数',
    'report.no_completed': '（完了タスクなし）',
    'report.by_priority': '## 優先度別完了数',
    'report.no_priority': '優先度なし',
    'report.current_status': '## 現在のタスク状況',
    'report.no_open': '（オープンタスクなし）',
    'report.est_vs_actual': '## 見積 vs 実績',
    'report.est_total': '見積合計',
    'report.act_total': '実績合計',
    'report.ratio': '予実比',
    'report.est_act_count': '見積+実績あり',
    'report.recent_list': '## 完了タスク一覧（直近{n}）',
    // テンプレート
    'template.none': '（テンプレートなし）',
    'template.not_found': 'エラー: テンプレート「{name}」は存在しません',
    'template.saved': '✅ テンプレート「{name}」を保存しました。',
    'template.saved_from': '✅ テンプレート「{name}」を #{num} からコピーして保存しました。',
    'template.deleted': '✅ テンプレート「{name}」を削除しました。',
    'template.show_name': '名前: {name}',
    'template.offset_suffix': '日',
    // ビュー
    'view.none': '（ビューなし）',
    'view.not_found': 'エラー: ビュー「{name}」は存在しません',
    'view.saved': '✅ ビュー「{name}」を保存しました。 [{parts}]',
    'view.deleted': '✅ ビュー「{name}」を削除しました。',
    // help
    'help.header': '## 📖 /todo コマンド一覧',
    'help.section_task': '### タスク管理',
    'help.section_context': '### コンテキスト・ラベル',
    'help.section_bulk': '### 一括操作',
    'help.section_review': '### レビュー・分析',
    'help.section_template': '### テンプレート・ビュー',
    'help.section_other': '### その他',
    'help.add': '/todo [GTD] <タイトル>          タスク追加（GTD省略時: inbox）',
    'help.list': '/todo list [フィルタ]           タスク一覧',
    'help.done': '/todo done <#> [--actual 時間]  タスク完了',
    'help.move': '/todo move <#> <GTD>            カテゴリ変更',
    'help.edit': '/todo edit <#> [--due/desc/...] 複数フィールド一括編集',
    'help.rename': '/todo rename <#> <新タイトル>    タイトル変更',
    'help.due': '/todo due <#> <日付>            期日設定',
    'help.desc': '/todo desc <#> <テキスト>       説明追加',
    'help.recur': '/todo recur <#> <パターン>      繰り返し設定（daily/weekly/monthly/weekdays）',
    'help.priority': '/todo priority <#> <p1-p3>      優先度設定',
    'help.search': '/todo search <キーワード>       キーワード検索',
    'help.tag': '/todo tag <#> @ctx ...          コンテキスト追加',
    'help.untag': '/todo untag <#> @ctx ...        コンテキスト削除',
    'help.label': '/todo label list/add/delete     ラベル管理',
    'help.bulk': '/todo bulk <done|move|tag|untag|priority> <#>...',
    'help.today': '/todo today                     今日のタスク（期限超過＋今日期限）',
    'help.dashboard': '/todo dashboard                 ダッシュボード',
    'help.daily': '/todo daily-review [morning|evening] デイリーレビュー',
    'help.weekly': '/todo weekly-review              週次レビュー',
    'help.stats': '/todo stats                     統計情報',
    'help.report': '/todo report <weekly|monthly|Nd> レポート出力',
    'help.template': '/todo template <list|show|save|use|delete>',
    'help.view': '/todo view <save|use|list|delete>',
    'help.review': '/todo review                    Inboxレビュー',
    'help.archive': '/todo archive [list|search|reopen] 完了済みタスク',
    'help.link': '/todo link <#> <project#>       プロジェクト紐付け',
    'help.help': '/todo help                      このヘルプを表示',
    // today
    'today.header': '# 🎯 今日のタスク — {date}',
    'today.overdue': '## ⚠️ 期限超過（{n}）',
    'today.due_today': '## 🎯 今日が期限（{n}）',
    'today.routine': '## 🔁 今日のルーティン（{n}）',
    'today.routine_overdue': '## 🔁 ルーティン未実施（{n}）',
    'today.no_tasks': '今日のタスクはありません。期限超過もなし。',
    'today.summary': '📊 合計: {total}',
    'today.est': '⏱見積: {time}',
    'today.done': '✅ 今日 {n}完了',
    // dashboard
    'dash.routine': '## 🔁 今日のルーティン（{n}）',
    // help
    'help.routine_hint': '🔁 routine ラベルは繰り返しタスク専用です。--recur オプションと組み合わせて使用してください。',
  },
  en: {
    'error.ctx_invalid': 'Error: Context name contains invalid characters',
    'error.positive_int': 'Error: A positive integer is required',
    'error.date_format': 'Error: Invalid date format',
    'error.recur_invalid': 'Error: recur must be daily/weekly/monthly/weekdays',
    'error.color_invalid': 'Error: Color must be a 6-digit hex code (e.g. FBCA04)',
    'error.priority_invalid': 'Error: --priority must be p1/p2/p3',
    'error.name_empty': 'Error: Name is empty',
    'error.name_invalid': 'Error: Name contains invalid characters (; $ ` ( ) " \' \\\\ | & > < { } [ ] not allowed)',
    'error.time_format': 'Error: Time must be in 30m / 1h / 1h30m format',
    'error.file_corrupt': 'Error: File is corrupted',
    'warn.month_rollover': '⚠️ Note: Day {day} does not exist in the next month, rolled to {date}',
    'section.next': '## ✅ Next Actions',
    'section.routine': '## 🔁 Routine',
    'section.inbox': '## 📥 Inbox',
    'section.waiting': '## ⏳ Waiting For',
    'section.someday': '## 🌈 Someday/Maybe',
    'section.project': '## 📁 Projects',
    'section.reference': '## 📎 Reference',
    'list.no_match': '(No matching tasks)',
    'list.none': '(none)',
    'list.no_tasks': '(No tasks)',
    'list.has_next': '✅ Has Next Action',
    'list.no_next': '⚠️ No Next Action',
    'list.overdue': 'Overdue',
    'list.this_week': 'Due this week',
    'weekly.header': '## 📋 Weekly Review Summary',
    'weekly.current_status': '**Current task status:**',
    'weekly.no_overdue': '✅ No overdue tasks',
    'weekly.inbox_pending': '📥 Inbox has {n} unprocessed tasks. Will sort in Step 1.',
    'weekly.start': '---\nStarting review.',
    'stats.header': '## 📊 Task Statistics',
    'stats.total': '**Total tasks: {n}**',
    'stats.by_category': '### By Category',
    'stats.by_priority': '### By Priority',
    'stats.no_priority': 'No priority',
    'stats.by_deadline': '### Deadlines',
    'stats.completed': '### Completed',
    'stats.last7days': 'Last 7 days: {n} completed',
    'stats.time_section': '### Time',
    'stats.est_total': 'Estimate total (next): {time} ({n})',
    'stats.no_estimate': 'No estimate: {n}',
    'dash.overdue': '## ⚠️ Overdue ({n})',
    'dash.today': '## \uD83C\uDFAF Due Today ({n})',
    'dash.this_week': '## 📅 Due This Week ({n})',
    'dash.next_actions': '## ✅ Next Actions ({n})',
    'dash.more': '  ...and {n} more',
    'dash.today_est': '⏱Today\'s estimate: {time}',
    'dash.done_summary': '✅ Today: {today} completed / This week: {week} completed',
    'dash.inbox_hint': '💡 Inbox has {n} unprocessed tasks.',
    'report.header': '# 📊 Productivity Report',
    'report.period': '**Period:** {start} to {end} ({days} days)',
    'report.completed_summary': '## Completed Summary',
    'report.metric': 'Metric',
    'report.value': 'Value',
    'report.completed_count': 'Completed tasks',
    'report.daily_avg': 'Daily average',
    'report.current_open': 'Currently open',
    'report.overdue': 'Overdue',
    'report.daily_completed': '## Daily Completed',
    'report.by_category': '## Completed by Category',
    'report.no_completed': '(No completed tasks)',
    'report.by_priority': '## Completed by Priority',
    'report.no_priority': 'No priority',
    'report.current_status': '## Current Task Status',
    'report.no_open': '(No open tasks)',
    'report.est_vs_actual': '## Estimate vs Actual',
    'report.est_total': 'Estimate total',
    'report.act_total': 'Actual total',
    'report.ratio': 'Ratio',
    'report.est_act_count': 'Has est+actual',
    'report.recent_list': '## Completed Tasks (last {n})',
    'template.none': '(No templates)',
    'template.not_found': 'Error: Template "{name}" not found',
    'template.saved': '✅ Template "{name}" saved.',
    'template.saved_from': '✅ Template "{name}" copied from #{num} and saved.',
    'template.deleted': '✅ Template "{name}" deleted.',
    'template.show_name': 'Name: {name}',
    'template.offset_suffix': ' days',
    'view.none': '(No views)',
    'view.not_found': 'Error: View "{name}" not found',
    'view.saved': '✅ View "{name}" saved. [{parts}]',
    'view.deleted': '✅ View "{name}" deleted.',
    // help
    'help.header': '## 📖 /todo Command Reference',
    'help.section_task': '### Task Management',
    'help.section_context': '### Context & Labels',
    'help.section_bulk': '### Bulk Operations',
    'help.section_review': '### Reviews & Analysis',
    'help.section_template': '### Templates & Views',
    'help.section_other': '### Other',
    'help.add': '/todo [GTD] <title>             Add task (default: inbox)',
    'help.list': '/todo list [filter]             List tasks',
    'help.done': '/todo done <#> [--actual time]  Mark done',
    'help.move': '/todo move <#> <GTD>            Change category',
    'help.edit': '/todo edit <#> [--due/desc/...] Edit multiple fields',
    'help.rename': '/todo rename <#> <new-title>    Rename',
    'help.due': '/todo due <#> <date>            Set due date',
    'help.desc': '/todo desc <#> <text>           Set description',
    'help.recur': '/todo recur <#> <pattern>       Set recurrence (daily/weekly/monthly/weekdays)',
    'help.priority': '/todo priority <#> <p1-p3>      Set priority',
    'help.search': '/todo search <keyword>          Search tasks',
    'help.tag': '/todo tag <#> @ctx ...          Add context',
    'help.untag': '/todo untag <#> @ctx ...        Remove context',
    'help.label': '/todo label list/add/delete     Manage labels',
    'help.bulk': '/todo bulk <done|move|tag|untag|priority> <#>...',
    'help.today': '/todo today                     Today\'s tasks (overdue + due today)',
    'help.dashboard': '/todo dashboard                 Dashboard',
    'help.daily': '/todo daily-review [morning|evening] Daily review',
    'help.weekly': '/todo weekly-review              Weekly review',
    'help.stats': '/todo stats                     Statistics',
    'help.report': '/todo report <weekly|monthly|Nd> Report',
    'help.template': '/todo template <list|show|save|use|delete>',
    'help.view': '/todo view <save|use|list|delete>',
    'help.review': '/todo review                    Inbox review',
    'help.archive': '/todo archive [list|search|reopen] Closed tasks',
    'help.link': '/todo link <#> <project#>       Link to project',
    'help.help': '/todo help                      Show this help',
    // today
    'today.header': '# 🎯 Today\'s Tasks — {date}',
    'today.overdue': '## ⚠️ Overdue ({n})',
    'today.due_today': '## 🎯 Due Today ({n})',
    'today.routine': '## 🔁 Today\'s Routines ({n})',
    'today.routine_overdue': '## 🔁 Routines Pending ({n})',
    'today.no_tasks': 'No tasks for today. No overdue items either.',
    'today.summary': '📊 Total: {total}',
    'today.est': '⏱Estimate: {time}',
    'today.done': '✅ {n} completed today',
    // dashboard
    'dash.routine': '## 🔁 Today\'s Routines ({n})',
    // help
    'help.routine_hint': '🔁 routine label is for recurring tasks. Recommended to use with --recur option.',
  }
};
function t(key) { return (MESSAGES[LANG] || MESSAGES.ja)[key] || MESSAGES.ja[key] || key; }
function tpl(key, vars) {
  let s = t(key);
  for (const [k, v] of Object.entries(vars)) s = s.replace('{' + k + '}', v);
  return s;
}
function cnt(n) { return LANG === 'ja' ? n + '件' : String(n); }

// ─── ユーティリティ関数 ───

function fmt(dt) {
  const y = dt.getFullYear();
  const mo = String(dt.getMonth()+1).padStart(2,'0');
  const da = String(dt.getDate()).padStart(2,'0');
  return y+'-'+mo+'-'+da;
}

function addDays(base, n) {
  const dt = new Date(base+'T00:00:00');
  dt.setDate(dt.getDate()+n);
  return fmt(dt);
}

function addMonth(base) {
  const dt = new Date(base+'T00:00:00');
  const origDay = dt.getDate();
  dt.setMonth(dt.getMonth()+1);
  if (dt.getDate() !== origDay) {
    process.stderr.write(tpl('warn.month_rollover', {day: origDay, date: fmt(dt)})+'\n');
  }
  return fmt(dt);
}

function addMonths(dt, n) {
  const origDay = dt.getDate();
  dt.setMonth(dt.getMonth()+n);
  if (dt.getDate() !== origDay) {
    process.stderr.write(tpl('warn.month_rollover', {day: origDay, date: fmt(dt)})+'\n');
  }
  return dt;
}

function normalizeDue(raw, today) {
  const d = () => new Date(today+'T00:00:00');
  const add = (dt, days) => { dt.setDate(dt.getDate()+days); return dt; };
  let result = null;
  if      (raw === '今日')   { result = today; }
  else if (raw === '明日')   { result = fmt(add(d(), 1)); }
  else if (raw === '明後日') { result = fmt(add(d(), 2)); }
  else if (raw === '来週')   { result = fmt(add(d(), 7)); }
  else if (raw === '来月')   { result = fmt(addMonths(d(), 1)); }
  else if (raw === '今週末') { const dt=d(); const dow=dt.getDay(); result=fmt(add(dt, dow===6?0:6-dow)); }
  else if (raw === '今月末') { const dt=d(); result=fmt(new Date(dt.getFullYear(),dt.getMonth()+1,0)); }
  else if (raw === '来月末') { const dt=d(); result=fmt(new Date(dt.getFullYear(),dt.getMonth()+2,0)); }
  else {
    let m;
    if      ((m=raw.match(/^(\d+)日後$/)))             { result=fmt(add(d(),+m[1])); }
    else if ((m=raw.match(/^(\d+)週(?:間)?後$/)))      { result=fmt(add(d(),+m[1]*7)); }
    else if ((m=raw.match(/^(\d+)[ヶか]月後$/)))       { result=fmt(addMonths(d(),+m[1])); }
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
    // English patterns (always checked regardless of LANG_ENV)
    else if (raw === 'today')                             { result = today; }
    else if (raw === 'tomorrow')                          { result = fmt(add(d(), 1)); }
    else if (raw === 'day after tomorrow')                { result = fmt(add(d(), 2)); }
    else if (/^next\s+week$/i.test(raw))                  { result = fmt(add(d(), 7)); }
    else if (/^next\s+month$/i.test(raw))                 { result = fmt(addMonths(d(), 1)); }
    else if (/^this\s+weekend$/i.test(raw))               { const dt=d(); const dow=dt.getDay(); result=fmt(add(dt, dow===6?0:6-dow)); }
    else if (/^end\s+of\s+this\s+month$/i.test(raw))     { const dt=d(); result=fmt(new Date(dt.getFullYear(),dt.getMonth()+1,0)); }
    else if (/^end\s+of\s+next\s+month$/i.test(raw))     { const dt=d(); result=fmt(new Date(dt.getFullYear(),dt.getMonth()+2,0)); }
    else if ((m=raw.match(/^in\s+(\d+)\s+days?$/i)))      { result=fmt(add(d(),+m[1])); }
    else if ((m=raw.match(/^in\s+(\d+)\s+weeks?$/i)))     { result=fmt(add(d(),+m[1]*7)); }
    else if ((m=raw.match(/^in\s+(\d+)\s+months?$/i)))    { result=fmt(addMonths(d(),+m[1])); }
    else if ((m=raw.match(/^next\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)$/i))) {
      const namesEn=['sunday','monday','tuesday','wednesday','thursday','friday','saturday'];
      const target=namesEn.indexOf(m[1].toLowerCase());
      const dt=d();
      const toNextMon=((1-dt.getDay()+7)%7)||7;
      dt.setDate(dt.getDate()+toNextMon);
      const offset=target===0?6:target-1;
      dt.setDate(dt.getDate()+offset);
      result=fmt(dt);
    }
  }
  return result !== null ? result : raw;
}

function parseBody(body) {
  const lines = (body || '').split('\n');
  let due = '', recur = '', project = '', estimate = '', actual = '', descLines = [];
  for (const line of lines) {
    if (line.startsWith('due: ')) due = line.slice(5);
    else if (line.startsWith('recur: ')) recur = line.slice(7);
    else if (line.startsWith('project: #')) project = line.slice(10);
    else if (line.startsWith('estimate: ')) estimate = line.slice(10);
    else if (line.startsWith('actual: ')) actual = line.slice(8);
    else descLines.push(line);
  }
  while (descLines.length && descLines[0].trim() === '') descLines.shift();
  const desc = descLines.join('\n');
  const descB64 = Buffer.from(desc, 'utf8').toString('base64');
  return 'DUE='+due+'\nRECUR='+recur+'\nPROJECT='+project+'\nESTIMATE='+estimate+'\nACTUAL='+actual+'\nDESC_B64='+descB64;
}

// 1回の gh issue view --json title,labels,body で取得した JSON から
// TITLE / LABELS（カンマ区切り）/ parseBody 結果をまとめて返す
function extractIssueFields() {
  const raw = process.env.ISSUE_JSON_ENV || '{}';
  let obj;
  try { obj = JSON.parse(raw); } catch(e) { process.stderr.write('error: invalid JSON\n'); process.exit(1); }
  const title = obj.title || '';
  const labels = (obj.labels || []).map(l => l.name).join(',');
  const body = obj.body || '';
  const parsed = parseBody(body);
  process.stdout.write('TITLE='+title+'\nLABELS='+labels+'\n'+parsed);
}

function buildBody(due, recur, project, estimate, actual, desc) {
  let body = '';
  const NL = '\n';
  if (due) body += 'due: '+due+NL;
  if (recur) body += 'recur: '+recur+NL;
  if (project) body += 'project: #'+project+NL;
  if (estimate) body += 'estimate: '+estimate+NL;
  if (actual) body += 'actual: '+actual+NL;
  if (desc) {
    if (body) body += NL;
    body += desc;
  }
  return body;
}

function parseTime(input) {
  if (!input) return null;
  const m = input.match(/^(?:(\d+)h)?(?:(\d+)m)?$/);
  if (m && (m[1] || m[2])) return (parseInt(m[1]||0)*60) + parseInt(m[2]||0);
  if (/^\d+$/.test(input)) return parseInt(input);
  return null;
}

function formatTime(minutes) {
  minutes = parseInt(minutes);
  if (isNaN(minutes) || minutes <= 0) return '0m';
  const h = Math.floor(minutes/60), m = minutes%60;
  if (h && m) return h+'h'+m+'m';
  if (h) return h+'h';
  return m+'m';
}

function priorityColor(pri) {
  return PRI_COLORS[pri] || 'UNKNOWN';
}

function nextDue(pattern, baseDate) {
  switch (pattern) {
    case 'daily':    return addDays(baseDate, 1);
    case 'weekly':   return addDays(baseDate, 7);
    case 'monthly':  return addMonth(baseDate);
    case 'weekdays': {
      let next = addDays(baseDate, 1);
      const dow = new Date(next+'T00:00:00').getDay(); // 0=Sun..6=Sat
      if (dow === 6) next = addDays(next, 2); // Sat→Mon
      if (dow === 0) next = addDays(next, 1); // Sun→Mon
      return next;
    }
    default: return baseDate;
  }
}

// ─── バリデーション関数 ───

function validateCtx(value) {
  for (const c of value) {
    if (FORBIDDEN_CHARS.indexOf(c) >= 0 || c === ' ') {
      process.stderr.write(t('error.ctx_invalid')+'\n');
      process.exit(1);
    }
  }
}

function validateNumber(value) {
  if (!value || !/^\d+$/.test(value) || value === '0') {
    process.stderr.write(t('error.positive_int')+'\n');
    process.exit(1);
  }
}

function validateDue(value) {
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return;
  if (/^\d{1,2}\/\d{1,2}$/.test(value)) return;
  process.stderr.write(t('error.date_format')+'\n');
  process.exit(1);
}

function validateRecur(value) {
  if (['daily','weekly','monthly','weekdays'].includes(value)) return;
  process.stderr.write(t('error.recur_invalid')+'\n');
  process.exit(1);
}

function validateColor(value) {
  if (/^[0-9A-Fa-f]{6}$/.test(value)) return;
  process.stderr.write(t('error.color_invalid')+'\n');
  process.exit(1);
}

function validatePriority(value) {
  if (['p1','p2','p3'].includes(value)) return;
  process.stderr.write(t('error.priority_invalid')+'\n');
  process.exit(1);
}

function validateName(value) {
  if (!value) {
    process.stderr.write(t('error.name_empty')+'\n');
    process.exit(1);
  }
  for (const c of value) {
    if (FORBIDDEN_CHARS.indexOf(c) >= 0) {
      process.stderr.write(t('error.name_invalid')+'\n');
      process.exit(1);
    }
  }
}

// ─── 集計・表示関数 ───

// ラベル名から絵文字プレフィックスを剥がして短縮名に正規化
function normLabel(name) {
  for (const key of GTD_LABELS) { if (name === GTD_DISPLAY[key]) return key; }
  return name;
}
function getLnames(issue) { return issue.labels.map(l => normLabel(l.name)); }
function getDue(issue) { const m = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m); return m ? m[1] : null; }
function getPri(lnames) { return lnames.find(l => /^p[123]$/.test(l)) || 'p9'; }
function priIcon(p) { return p==='p1' ? '🔴 ' : p==='p2' ? '🟡 ' : ''; }
function getCtx(lnames) { return lnames.filter(l => l.startsWith('@')); }

function sortByPriDue(a, b) {
  const pa = getPri(getLnames(a)), pb = getPri(getLnames(b));
  if (pa !== pb) return pa < pb ? -1 : 1;
  const da = getDue(a) || '9999', db = getDue(b) || '9999';
  return da < db ? -1 : da > db ? 1 : 0;
}

function renderIssueList(issue) {
  const lnames = getLnames(issue);
  const ctx = getCtx(lnames);
  const due = getDue(issue);
  const recur = (issue.body||'').match(/^recur: (\w+)/m);
  const proj = (issue.body||'').match(/^project: #(\d+)/m);
  const estMatch = (issue.body||'').match(/^estimate: (\d+)/m);
  let line = '  '+priIcon(getPri(lnames))+'#'+issue.number+'  '+issue.title;
  if (ctx.length) line += '  ['+ctx.join(' ')+']';
  if (due) line += '  📅 '+due;
  if (estMatch) line += '  ⏱'+formatTime(parseInt(estMatch[1]));
  if (proj) line += '  [project:#'+proj[1]+']';
  if (recur) line += '  🔄'+recur[1];
  return line;
}

const GTD_SECTION_HEADERS = {
  next: t('section.next'),
  routine: t('section.routine'),
  inbox: t('section.inbox'),
  waiting: t('section.waiting'),
  someday: t('section.someday'),
  project: t('section.project'),
  reference: t('section.reference')
};

function listAll() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const filterGtd = process.env.FILTER_GTD_ENV || '';
  const filterCtx = process.env.FILTER_CTX_ENV || '';
  const filterPri = process.env.FILTER_PRI_ENV || '';
  const filterProj = process.env.FILTER_PROJ_ENV || '';
  const w = s => process.stdout.write(s);

  // フィルタリング
  let filtered = issues;
  if (filterGtd) filtered = filtered.filter(i => getLnames(i).includes(filterGtd));
  if (filterCtx) filtered = filtered.filter(i => getLnames(i).includes(filterCtx));
  if (filterPri) filtered = filtered.filter(i => getLnames(i).includes(filterPri));
  if (filterProj) {
    const projTag = 'project: #'+filterProj;
    filtered = filtered.filter(i => (i.body||'').includes(projTag));
  }

  // フィルタ指定あり → フラットリスト
  if (filterGtd || filterCtx || filterPri || filterProj) {
    filtered.sort(sortByPriDue);
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    for (const issue of filtered) { w(renderIssueList(issue)+'\n'); }
    return;
  }

  // フィルタなし → GTDカテゴリ別グルーピング
  const grouped = {};
  GTD_LABELS.forEach(l => grouped[l] = []);
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) grouped[gl].push(issue); }
  }

  // 各カテゴリをソートして出力
  const labelsToShow = ['next','routine','inbox','waiting','someday','project','reference'];
  for (const label of labelsToShow) {
    w(GTD_SECTION_HEADERS[label]+'\n');
    const items = grouped[label];
    if (!items.length) { w('  '+t('list.none')+'\n'); }
    else {
      // Projects は特殊表示
      if (label === 'project') {
        for (const issue of items) {
          const projTag = 'project: #'+issue.number;
          const hasNext = issues.some(i => getLnames(i).includes('next') && (i.body||'').includes(projTag));
          w('  #'+issue.number+'  '+issue.title+'  '+(hasNext ? t('list.has_next') : t('list.no_next'))+'\n');
        }
      } else {
        items.sort(sortByPriDue);
        for (const issue of items) { w(renderIssueList(issue)+'\n'); }
      }
    }
    w('\n');
  }

  // サマリー
  const counts = {};
  GTD_LABELS.forEach(l => counts[l] = grouped[l].length);
  let overdue = 0, thisWeek = 0;
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);
  for (const issue of issues) {
    const dueMatch = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    if (dueMatch) {
      if (dueMatch[1] < today) overdue++;
      else if (dueMatch[1] <= d7str) thisWeek++;
    }
  }
  w('---\n');
  const parts = GTD_LABELS.filter(l => counts[l] > 0).map(l => l+': '+cnt(counts[l]));
  w('📊 '+(parts.length ? parts.join(' / ') : t('list.no_tasks')));
  if (overdue > 0) w('  ⚠️ '+t('list.overdue')+': '+cnt(overdue));
  if (thisWeek > 0) w('  📅 '+t('list.this_week')+': '+cnt(thisWeek));
  w('\n');
}

function listSummary() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const counts = {};
  GTD_LABELS.forEach(l => counts[l] = 0);
  let overdue = 0, thisWeek = 0;
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) counts[gl]++; }
    const dueMatch = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    if (dueMatch) {
      if (dueMatch[1] < today) overdue++;
      else if (dueMatch[1] <= d7str) thisWeek++;
    }
  }
  const parts = GTD_LABELS.filter(l => counts[l] > 0).map(l => l+': '+cnt(counts[l]));
  const w = s => process.stdout.write(s);
  w('\n---\n');
  w('📊 '+(parts.length ? parts.join(' / ') : t('list.no_tasks')));
  if (overdue > 0) w('  ⚠️ '+t('list.overdue')+': '+cnt(overdue));
  if (thisWeek > 0) w('  📅 '+t('list.this_week')+': '+cnt(thisWeek));
  w('\n');
}

function weeklySummary() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const counts = {};
  GTD_LABELS.forEach(l => counts[l] = 0);
  let overdue = 0, thisWeek = 0;
  const overdueList = [], thisWeekList = [];
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) counts[gl]++; }
    const dueMatch = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    if (dueMatch) {
      const due = dueMatch[1];
      if (due < today) { overdue++; overdueList.push('    #'+issue.number+' '+issue.title+' ('+due+')'); }
      else if (due <= d7str) { thisWeek++; thisWeekList.push('    #'+issue.number+' '+issue.title+' ('+due+')'); }
    }
  }
  const inboxCount = counts['inbox'];
  const w = s => process.stdout.write(s);
  w(t('weekly.header')+'\n\n');
  w(t('weekly.current_status')+'\n');
  const parts = GTD_LABELS.filter(l => counts[l] > 0).map(l => '  '+l+': '+cnt(counts[l]));
  w(parts.join('\n')+'\n\n');
  if (overdue > 0) { w('⚠️ **'+t('list.overdue')+': '+cnt(overdue)+'**\n'); w(overdueList.join('\n')+'\n\n'); }
  else { w(t('weekly.no_overdue')+'\n\n'); }
  if (thisWeek > 0) { w('📅 **'+t('list.this_week')+': '+cnt(thisWeek)+'**\n'); w(thisWeekList.join('\n')+'\n\n'); }
  if (inboxCount > 0) { w(tpl('weekly.inbox_pending', {n: cnt(inboxCount)})+'\n\n'); }
  w(t('weekly.start')+'\n\n');
}

function stats() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const closed = JSON.parse(process.env.CLOSED_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const gtdCounts = {};
  GTD_LABELS.forEach(l => gtdCounts[l] = 0);
  const priCounts = {p1:0, p2:0, p3:0, none:0};
  let overdue = 0, thisWeek = 0, total = issues.length;
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) gtdCounts[gl]++; }
    const pri = lnames.find(l => /^p[123]$/.test(l));
    if (pri) priCounts[pri]++; else priCounts.none++;
    const dueMatch = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    if (dueMatch) {
      if (dueMatch[1] < today) overdue++;
      else if (dueMatch[1] <= d7str) thisWeek++;
    }
  }
  // 完了実績
  const d7ago = new Date(today); d7ago.setDate(d7ago.getDate()-7);
  const weekClosed = closed.filter(i => i.closedAt && new Date(i.closedAt) >= d7ago).length;

  const w = s => process.stdout.write(s);
  w(t('stats.header')+'\n\n');
  w(tpl('stats.total', {n: cnt(total)})+'\n\n');
  w(t('stats.by_category')+'\n');
  GTD_LABELS.filter(l => gtdCounts[l] > 0).forEach(l => { w('  '+l+': '+cnt(gtdCounts[l])+'\n'); });
  w('\n'+t('stats.by_priority')+'\n');
  if (priCounts.p1) w('  🔴 p1: '+cnt(priCounts.p1)+'\n');
  if (priCounts.p2) w('  🟡 p2: '+cnt(priCounts.p2)+'\n');
  if (priCounts.p3) w('  p3: '+cnt(priCounts.p3)+'\n');
  if (priCounts.none) w('  '+t('stats.no_priority')+': '+cnt(priCounts.none)+'\n');
  w('\n'+t('stats.by_deadline')+'\n');
  w('  ⚠️ '+t('list.overdue')+': '+cnt(overdue)+'\n');
  w('  📅 '+t('list.this_week')+': '+cnt(thisWeek)+'\n');
  w('\n'+t('stats.completed')+'\n');
  w('  '+tpl('stats.last7days', {n: cnt(weekClosed)})+'\n');

  // 見積もり情報
  let nextEstTotal = 0, nextEstCount = 0, noEstCount = 0;
  for (const issue of issues) {
    const lnames = getLnames(issue);
    if (lnames.includes('next')) {
      const em = (issue.body||'').match(/^estimate: (\d+)/m);
      if (em) { nextEstTotal += parseInt(em[1]); nextEstCount++; }
      else noEstCount++;
    }
  }
  if (nextEstTotal > 0 || noEstCount > 0) {
    w('\n'+t('stats.time_section')+'\n');
    if (nextEstTotal > 0) w('  '+tpl('stats.est_total', {time: formatTime(nextEstTotal), n: cnt(nextEstCount)})+'\n');
    if (noEstCount > 0) w('  '+tpl('stats.no_estimate', {n: cnt(noEstCount)})+'\n');
  }
}

function help() {
  const w = s => process.stdout.write(s);
  w(t('help.header')+'\n\n');

  w(t('help.section_task')+'\n');
  w('```\n');
  for (const k of ['add','list','done','move','edit','rename','due','desc','recur','priority','search']) {
    w(t('help.'+k)+'\n');
  }
  w('```\n\n');

  w(t('help.section_context')+'\n');
  w('```\n');
  for (const k of ['tag','untag','label']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w(t('help.section_bulk')+'\n');
  w('```\n');
  w(t('help.bulk')+'\n');
  w('```\n\n');

  w(t('help.section_review')+'\n');
  w('```\n');
  for (const k of ['today','dashboard','daily','weekly','stats','report']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w(t('help.section_template')+'\n');
  w('```\n');
  for (const k of ['template','view']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w(t('help.section_other')+'\n');
  w('```\n');
  for (const k of ['review','archive','link','help']) { w(t('help.'+k)+'\n'); }
  w('```\n');
}

function today() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const todayStr = process.env.TODAY_ENV;
  const closed = JSON.parse(process.env.CLOSED_ENV || '[]');
  const w = s => process.stdout.write(s);

  const overdue = [], dueToday = [], routineToday = [], routineOverdue = [];
  for (const issue of issues) {
    const lnames = getLnames(issue);
    const due = getDue(issue);
    if (lnames.includes('routine')) {
      if (due && due < todayStr) routineOverdue.push(issue);
      else if (due && due === todayStr) routineToday.push(issue);
    } else if (due && due < todayStr) {
      overdue.push(issue);
    } else if (due && due === todayStr && lnames.includes('next')) {
      dueToday.push(issue);
    }
  }
  overdue.sort(sortByPriDue);
  dueToday.sort(sortByPriDue);
  routineToday.sort(sortByPriDue);
  routineOverdue.sort(sortByPriDue);

  w(tpl('today.header', {date: todayStr})+'\n\n');

  if (overdue.length === 0 && dueToday.length === 0 && routineToday.length === 0 && routineOverdue.length === 0) {
    w(t('today.no_tasks')+'\n');
    return;
  }

  const renderIssue = (i, showDue) => {
    const lnames = getLnames(i);
    const ctx = getCtx(lnames);
    w('  '+priIcon(getPri(lnames))+'#'+i.number+'  '+i.title);
    if (ctx.length) w('  ['+ctx.join(' ')+']');
    if (showDue) { const due = getDue(i); if (due) w('  📅 '+due); }
    const em = (i.body||'').match(/^estimate: (\d+)/m);
    if (em) w('  ⏱'+formatTime(parseInt(em[1])));
    w('\n');
  };

  if (overdue.length) {
    w(tpl('today.overdue', {n: cnt(overdue.length)})+'\n');
    overdue.forEach(i => renderIssue(i, true));
    w('\n');
  }
  if (dueToday.length) {
    w(tpl('today.due_today', {n: cnt(dueToday.length)})+'\n');
    dueToday.forEach(i => renderIssue(i, false));
    w('\n');
  }
  if (routineToday.length) {
    w(tpl('today.routine', {n: cnt(routineToday.length)})+'\n');
    routineToday.forEach(i => renderIssue(i, false));
    w('\n');
  }
  if (routineOverdue.length) {
    w(tpl('today.routine_overdue', {n: cnt(routineOverdue.length)})+'\n');
    routineOverdue.forEach(i => renderIssue(i, true));
    w('\n');
  }

  // サマリー
  const allTasks = [...overdue, ...dueToday, ...routineToday, ...routineOverdue];
  let estTotal = 0;
  for (const i of allTasks) {
    const em = (i.body||'').match(/^estimate: (\d+)/m);
    if (em) estTotal += parseInt(em[1]);
  }
  const todayClosed = closed.filter(i => i.closedAt && i.closedAt.slice(0,10) === todayStr).length;

  w('---\n');
  const parts = [tpl('today.summary', {total: cnt(allTasks.length)})];
  if (estTotal > 0) parts.push(tpl('today.est', {time: formatTime(estTotal)}));
  if (todayClosed > 0) parts.push(tpl('today.done', {n: cnt(todayClosed)}));
  w(parts.join('  ')+'\n');
}

function dashboard() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const closed = JSON.parse(process.env.CLOSED_ENV || '[]');
  const w = s => process.stdout.write(s);
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);

  const overdue = [], dueToday = [], dueThisWeek = [], nextActions = [], routineToday = [];
  const gtdCounts = {};
  GTD_LABELS.forEach(l => gtdCounts[l] = 0);

  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) gtdCounts[gl]++; }
    const due = getDue(issue);
    if (lnames.includes('routine')) {
      if (due && due <= today) routineToday.push(issue);
    } else if (lnames.includes('next')) {
      if (due && due < today) overdue.push(issue);
      else if (due && due === today) dueToday.push(issue);
      else if (due && due <= d7str) dueThisWeek.push(issue);
      else nextActions.push(issue);
    } else if (due && due < today) {
      overdue.push(issue);
    }
  }
  overdue.sort(sortByPriDue); dueToday.sort(sortByPriDue);
  dueThisWeek.sort(sortByPriDue); nextActions.sort(sortByPriDue); routineToday.sort(sortByPriDue);

  const d7ago = new Date(today); d7ago.setDate(d7ago.getDate()-7);
  const todayClosed = closed.filter(i => i.closedAt && i.closedAt.slice(0,10) === today).length;
  const weekClosed = closed.filter(i => i.closedAt && new Date(i.closedAt) >= d7ago).length;

  w('# 📋 Dashboard — '+today+'\n\n');

  const renderIssue = (i, showDue) => {
    const lnames = getLnames(i);
    const ctx = getCtx(lnames);
    w('  '+priIcon(getPri(lnames))+'#'+i.number+'  '+i.title);
    if (ctx.length) w('  ['+ctx.join(' ')+']');
    if (showDue) { const due = getDue(i); if (due) w('  📅 '+due); }
    w('\n');
  };

  if (overdue.length) {
    w(tpl('dash.overdue', {n: cnt(overdue.length)})+'\n');
    overdue.forEach(i => renderIssue(i, true));
    w('\n');
  }
  if (dueToday.length) {
    w(tpl('dash.today', {n: cnt(dueToday.length)})+'\n');
    dueToday.forEach(i => renderIssue(i, false));
    w('\n');
  }
  if (dueThisWeek.length) {
    w(tpl('dash.this_week', {n: cnt(dueThisWeek.length)})+'\n');
    dueThisWeek.forEach(i => renderIssue(i, true));
    w('\n');
  }
  if (nextActions.length) {
    w(tpl('dash.next_actions', {n: cnt(nextActions.length)})+'\n');
    nextActions.slice(0,10).forEach(i => renderIssue(i, true));
    if (nextActions.length > 10) w(tpl('dash.more', {n: cnt(nextActions.length-10)})+'\n');
    w('\n');
  }
  if (routineToday.length) {
    w(tpl('dash.routine', {n: cnt(routineToday.length)})+'\n');
    routineToday.forEach(i => renderIssue(i, true));
    w('\n');
  }

  // 今日のタスク（overdue + dueToday）の見積もり合計
  const todayTasks = [...overdue, ...dueToday];
  let estTotal = 0, estCount = 0;
  for (const i of todayTasks) {
    const em = (i.body||'').match(/^estimate: (\d+)/m);
    if (em) { estTotal += parseInt(em[1]); estCount++; }
  }

  w('---\n');
  w('📊 ');
  const parts = [];
  for (const gl of ['next','routine','inbox','waiting','someday']) {
    if (gtdCounts[gl]) parts.push(gl+': '+cnt(gtdCounts[gl]));
  }
  w(parts.join(' / '));
  if (estTotal > 0) w('  '+tpl('dash.today_est', {time: formatTime(estTotal)}));
  w('\n');
  w(tpl('dash.done_summary', {today: cnt(todayClosed), week: cnt(weekClosed)})+'\n');
  if (gtdCounts.inbox > 0) {
    w('\n'+tpl('dash.inbox_hint', {n: cnt(gtdCounts.inbox)})+'\n');
  }
}

function report() {
  const today = process.env.TODAY_ENV;
  const days = parseInt(process.env.DAYS_ENV) || 7;
  const open = JSON.parse(process.env.OPEN_ENV || '[]');
  const closed = JSON.parse(process.env.CLOSED_ENV || '[]');
  const w = s => process.stdout.write(s);

  const startDate = new Date(today);
  startDate.setDate(startDate.getDate()-days);
  const startStr = startDate.toISOString().slice(0,10);

  const periodClosed = closed.filter(i => {
    if (!i.closedAt) return false;
    const d = i.closedAt.slice(0,10);
    return d >= startStr && d <= today;
  });

  const dailyCounts = {};
  for (let i = 0; i < days; i++) {
    const d = new Date(today);
    d.setDate(d.getDate()-i);
    dailyCounts[d.toISOString().slice(0,10)] = 0;
  }
  for (const issue of periodClosed) {
    const d = issue.closedAt.slice(0,10);
    if (dailyCounts[d] !== undefined) dailyCounts[d]++;
  }

  const closedByGtd = {};
  GTD_LABELS.forEach(l => closedByGtd[l] = 0);
  for (const issue of periodClosed) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) closedByGtd[gl]++; }
  }

  const closedByPri = {p1:0, p2:0, p3:0, none:0};
  for (const issue of periodClosed) {
    const lnames = getLnames(issue);
    const pri = lnames.find(l => /^p[123]$/.test(l));
    if (pri) closedByPri[pri]++; else closedByPri.none++;
  }

  const openByGtd = {};
  GTD_LABELS.forEach(l => openByGtd[l] = 0);
  let overdueCount = 0;
  for (const issue of open) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) openByGtd[gl]++; }
    const dueMatch = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    if (dueMatch && dueMatch[1] < today) overdueCount++;
  }

  const maxCount = Math.max(...Object.values(dailyCounts), 1);
  const barWidth = 20;

  w(t('report.header')+'\n\n');
  w(tpl('report.period', {start: startStr, end: today, days: String(days)})+'\n\n');
  w('---\n\n');
  w(t('report.completed_summary')+'\n\n');
  w('| '+t('report.metric')+' | '+t('report.value')+' |\n');
  w('|------|----|\n');
  w('| '+t('report.completed_count')+' | **'+cnt(periodClosed.length)+'** |\n');
  const avg = (periodClosed.length/days).toFixed(1);
  w('| '+t('report.daily_avg')+' | '+cnt(avg)+' |\n');
  w('| '+t('report.current_open')+' | '+cnt(open.length)+' |\n');
  w('| '+t('report.overdue')+' | '+cnt(overdueCount)+' |\n');
  w('\n');

  w(t('report.daily_completed')+'\n\n');
  w('```\n');
  const sortedDays = Object.keys(dailyCounts).sort();
  for (const day of sortedDays) {
    const cnt = dailyCounts[day];
    const bar = '█'.repeat(Math.round(cnt/maxCount*barWidth));
    const dayLabel = day.slice(5);
    w(dayLabel+' '+bar+(cnt > 0 ? ' '+cnt : '')+'\n');
  }
  w('```\n\n');

  w(t('report.by_category')+'\n\n');
  const closedGtdParts = GTD_LABELS.filter(l => closedByGtd[l] > 0);
  if (closedGtdParts.length) {
    for (const l of closedGtdParts) { w('  '+l+': '+cnt(closedByGtd[l])+'\n'); }
  } else { w('  '+t('report.no_completed')+'\n'); }
  w('\n');

  w(t('report.by_priority')+'\n\n');
  if (closedByPri.p1) w('  🔴 p1: '+cnt(closedByPri.p1)+'\n');
  if (closedByPri.p2) w('  🟡 p2: '+cnt(closedByPri.p2)+'\n');
  if (closedByPri.p3) w('  p3: '+cnt(closedByPri.p3)+'\n');
  if (closedByPri.none) w('  '+t('report.no_priority')+': '+cnt(closedByPri.none)+'\n');
  w('\n');

  w(t('report.current_status')+'\n\n');
  const openParts = GTD_LABELS.filter(l => openByGtd[l] > 0);
  if (openParts.length) {
    for (const l of openParts) { w('  '+l+': '+cnt(openByGtd[l])+'\n'); }
  } else { w('  '+t('report.no_open')+'\n'); }
  if (overdueCount > 0) w('\n  ⚠️ '+t('list.overdue')+': '+cnt(overdueCount)+'\n');
  w('\n');

  // 見積 vs 実績
  let estSum = 0, actSum = 0, estActCount = 0;
  for (const issue of periodClosed) {
    const em = (issue.body||'').match(/^estimate: (\d+)/m);
    const am = (issue.body||'').match(/^actual: (\d+)/m);
    if (em) estSum += parseInt(em[1]);
    if (am) actSum += parseInt(am[1]);
    if (em && am) estActCount++;
  }
  if (estSum > 0 || actSum > 0) {
    w(t('report.est_vs_actual')+'\n\n');
    w('| '+t('report.metric')+' | '+t('report.value')+' |\n');
    w('|------|----|\n');
    w('| '+t('report.est_total')+' | '+formatTime(estSum)+' |\n');
    w('| '+t('report.act_total')+' | '+formatTime(actSum)+' |\n');
    if (estSum > 0 && actSum > 0) {
      const ratio = Math.round(actSum/estSum*100);
      w('| '+t('report.ratio')+' | '+ratio+'% |\n');
    }
    w('| '+t('report.est_act_count')+' | '+cnt(estActCount)+' / '+cnt(periodClosed.length)+' |\n');
    w('\n');
  }

  w(tpl('report.recent_list', {n: cnt(Math.min(periodClosed.length,10))})+'\n\n');
  const recent = periodClosed.sort((a,b) => b.closedAt.localeCompare(a.closedAt)).slice(0,10);
  if (recent.length) {
    for (const i of recent) { w('  ✅ #'+i.number+'  '+i.title+'  ('+i.closedAt.slice(0,10)+')\n'); }
  } else { w('  '+t('report.no_completed')+'\n'); }
  w('\n');
}

function doneCount() {
  const closed = JSON.parse(process.env.CLOSED_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const cnt = closed.filter(i => {
    if (!i.closedAt) return false;
    const dt = new Date(i.closedAt);
    const s = [dt.getFullYear(), String(dt.getMonth()+1).padStart(2,'0'), String(dt.getDate()).padStart(2,'0')].join('-');
    return s === today;
  }).length;
  process.stdout.write(String(cnt));
}

// ─── テンプレート/ビュー管理（File I/O） ───

function homeDir() { return process.env.HOME || os.homedir(); }
function getTemplatePath() { return path.join(homeDir(), '.claude', 'todo-templates.json'); }
function getViewPath() { return path.join(homeDir(), '.claude', 'todo-views.json'); }

function readJsonFile(fpath) {
  if (!fs.existsSync(fpath)) return {};
  try { return JSON.parse(fs.readFileSync(fpath, 'utf8')); }
  catch(e) {
    if (e instanceof SyntaxError) {
      process.stderr.write(t('error.file_corrupt')+'\n');
      process.exit(1);
    }
    return {};
  }
}

function writeJsonFile(fpath, data) {
  fs.writeFileSync(fpath, JSON.stringify(data, null, 2));
}

function templateList() {
  const data = readJsonFile(getTemplatePath());
  const keys = Object.keys(data);
  if (!keys.length) { process.stdout.write(t('template.none')+'\n'); return; }
  for (const name of keys) {
    const tmpl = data[name];
    const parts = [tmpl.gtd||'inbox'];
    const ctx = (tmpl.context||[]).join(' ');
    if (ctx) parts.push(ctx);
    parts.push(tmpl.priority||'p3');
    if (tmpl.recur) parts.push('recur:'+tmpl.recur);
    if (tmpl['due-offset']) parts.push('offset:+'+tmpl['due-offset']+t('template.offset_suffix'));
    if (tmpl.due) parts.push('due:'+tmpl.due);
    process.stdout.write('  '+name+'  ['+parts.join(', ')+']\n');
  }
}

function templateShow() {
  const name = process.env.TNAME_ENV;
  const data = readJsonFile(getTemplatePath());
  if (!data[name]) { process.stderr.write(tpl('template.not_found', {name: name})+'\n'); process.exit(1); }
  const tmpl = data[name];
  const w = s => process.stdout.write(s);
  w(tpl('template.show_name', {name: name})+'\n');
  w('  GTD:      '+(tmpl.gtd||'inbox')+'\n');
  w('  context:  '+(tmpl.context||[]).join(' ')+'\n');
  w('  priority: '+(tmpl.priority||'p3')+'\n');
  if (tmpl['due-offset']) w('  due-offset: +'+tmpl['due-offset']+t('template.offset_suffix')+'\n');
  if (tmpl.due) w('  due:      '+tmpl.due+'\n');
  if (tmpl.recur) w('  recur:    '+tmpl.recur+'\n');
  if (tmpl.project) w('  project:  #'+tmpl.project+'\n');
  if (tmpl.desc) w('  desc:     '+tmpl.desc+'\n');
}

function templateSave() {
  const name = process.env.TNAME_ENV;
  const data = readJsonFile(getTemplatePath());
  const t = {};
  t.gtd = process.env.GTD_ENV || 'inbox';
  t.context = JSON.parse(process.env.CONTEXTS_ENV || '[]');
  const off = process.env.DUE_OFFSET_ENV || '';
  if (off) t['due-offset'] = parseInt(off);
  const due = process.env.DUE_ENV || '';
  if (due && !off) t.due = due;
  const recur = process.env.RECUR_ENV || '';
  if (recur) t.recur = recur;
  const proj = process.env.PROJECT_ENV || '';
  if (proj) t.project = parseInt(proj);
  t.priority = process.env.PRIORITY_ENV || 'p3';
  const desc = process.env.DESC_ENV || '';
  if (desc) t.desc = desc;
  data[name] = t;
  writeJsonFile(getTemplatePath(), data);
  process.stdout.write(tpl('template.saved', {name: name})+'\n');
}

function templateSaveFrom() {
  const name = process.env.TNAME_ENV;
  const issueNum = process.env.ISSUE_NUM_ENV || '?';
  const data = readJsonFile(getTemplatePath());
  const t = {};
  t.gtd = process.env.GTD_ENV || 'inbox';
  t.context = JSON.parse(process.env.CONTEXTS_ENV || '[]');
  const due = process.env.DUE_ENV || '';
  if (due) t.due = due;
  const recur = process.env.RECUR_ENV || '';
  if (recur) t.recur = recur;
  const proj = process.env.PROJECT_ENV || '';
  if (proj) t.project = parseInt(proj);
  const desc = process.env.DESC_ENV || '';
  if (desc) t.desc = desc;
  data[name] = t;
  writeJsonFile(getTemplatePath(), data);
  process.stdout.write(tpl('template.saved_from', {name: name, num: issueNum})+'\n');
}

function templateUse() {
  const name = process.env.TNAME_ENV;
  const data = readJsonFile(getTemplatePath());
  if (!data[name]) { process.stderr.write(tpl('template.not_found', {name: name})+'\n'); process.exit(1); }
  const t = data[name];
  const w = s => process.stdout.write(s);
  w('GTD='+(t.gtd||'inbox')+'\n');
  w('CONTEXT='+(t.context||[]).join(' ')+'\n');
  w('PRIORITY='+(t.priority||'p3')+'\n');
  w('DUE_OFFSET='+(t['due-offset']||'')+'\n');
  w('DUE='+(t.due||'')+'\n');
  w('RECUR='+(t.recur||'')+'\n');
  w('PROJECT='+(t.project||'')+'\n');
  w('DESC_B64='+Buffer.from(t.desc||'','utf8').toString('base64')+'\n');
}

function templateDelete() {
  const name = process.env.TNAME_ENV;
  const data = readJsonFile(getTemplatePath());
  if (!data[name]) { process.stderr.write(tpl('template.not_found', {name: name})+'\n'); process.exit(1); }
  delete data[name];
  writeJsonFile(getTemplatePath(), data);
  process.stdout.write(tpl('template.deleted', {name: name})+'\n');
}

function viewSave() {
  const name = process.env.VNAME_ENV;
  const fpath = getViewPath();
  const data = readJsonFile(fpath);
  const v = {};
  const gtd = process.env.GTD_ENV || '';
  if (gtd) v.gtd = gtd;
  const ctx = process.env.CTX_ENV || '';
  if (ctx) v.context = ctx.trim().split(/\s+/);
  const pri = process.env.PRI_ENV || '';
  if (pri) v.priority = pri;
  data[name] = v;
  writeJsonFile(fpath, data);
  const parts = [];
  if (v.gtd) parts.push(v.gtd);
  if (v.context) parts.push(v.context.join(' '));
  if (v.priority) parts.push(v.priority);
  process.stdout.write(tpl('view.saved', {name: name, parts: parts.join(', ')})+'\n');
}

function viewUse() {
  const name = process.env.VNAME_ENV;
  const data = readJsonFile(getViewPath());
  if (!data[name]) { process.stderr.write(tpl('view.not_found', {name: name})+'\n'); process.exit(1); }
  const v = data[name];
  const parts = [];
  if (v.gtd) parts.push('GTD='+v.gtd);
  if (v.context) parts.push('CTX='+v.context.join(' '));
  if (v.priority) parts.push('PRI='+v.priority);
  process.stdout.write(parts.join('\n')+'\n');
}

function viewList() {
  const data = readJsonFile(getViewPath());
  const keys = Object.keys(data);
  if (!keys.length) { process.stdout.write(t('view.none')+'\n'); return; }
  for (const name of keys) {
    const v = data[name];
    const parts = [];
    if (v.gtd) parts.push(v.gtd);
    if (v.context) parts.push(v.context.join(' '));
    if (v.priority) parts.push(v.priority);
    process.stdout.write('  '+name+'  ['+parts.join(', ')+']\n');
  }
}

function viewDelete() {
  const name = process.env.VNAME_ENV;
  const fpath = getViewPath();
  const data = readJsonFile(fpath);
  if (!data[name]) { process.stderr.write(tpl('view.not_found', {name: name})+'\n'); process.exit(1); }
  delete data[name];
  writeJsonFile(fpath, data);
  process.stdout.write(tpl('view.deleted', {name: name})+'\n');
}

// ─── Octokit API サブコマンド ───

const REPO_OWNER = process.env.TODO_REPO_OWNER || '';
const REPO_NAME = process.env.TODO_REPO_NAME || '';

// メッセージ表示済みエラー（catch で再表示しないようにフラグを立てる）
function apiErr(msg) { process.stderr.write(msg+'\n'); const e = new Error(msg); e._msgWritten = true; return e; }

async function apiMain(subArgs) {
  if (!REPO_OWNER || !REPO_NAME) {
    throw apiErr('TODO_REPO_OWNER and TODO_REPO_NAME must be set in .env or environment variables.');
  }
  const subCmd = subArgs[0];
  if (!subCmd) { throw apiErr('Usage: todo-engine.js api <subcommand> [args...]'); }

  // トークン取得の優先順位:
  // 1. 環境変数 GH_TOKEN / GITHUB_TOKEN
  // 2. ~/.claude/github-token ファイル
  // 3. エラー
  let token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  if (!token) {
    const tokenPath = path.join(process.env.HOME || os.homedir(), '.claude', 'github-token');
    if (fs.existsSync(tokenPath)) {
      token = fs.readFileSync(tokenPath, 'utf8').trim();
    }
  }
  if (!token) { throw apiErr('Error: GH_TOKEN is not set and ~/.claude/github-token not found'); }

  // Octokit をローカルの node_modules から動的ロード（ESM パッケージのため import() を使用）
  const octokitPath = path.join(process.env.HOME || os.homedir(), '.claude', 'node_modules', '@octokit', 'rest', 'dist-src', 'index.js');
  let OctokitClass;
  try {
    // Windows ではパスを URL に変換してから import する
    const { pathToFileURL } = require('url');
    const mod = await import(pathToFileURL(octokitPath).href);
    OctokitClass = mod.Octokit;
  } catch(e) {
    throw apiErr('Error: @octokit/rest not found. Run: npm install --prefix ~/.claude @octokit/rest\nDetail: '+e.message);
  }

  const octokit = new OctokitClass({ auth: token });
  const owner = REPO_OWNER, repo = REPO_NAME;

  try {
    switch (subCmd) {
      // ── 読み取り系 ──

      case 'list-issues': {
        // gh互換: [{number, title, body, labels:[{name}], closedAt?}]
        const state = (subArgs.includes('--state') ? subArgs[subArgs.indexOf('--state')+1] : null) || 'open';
        const limitIdx = subArgs.indexOf('--limit');
        const perPage = limitIdx >= 0 ? Math.min(parseInt(subArgs[limitIdx+1])||100, 100) : 100;
        const allIssues = [];
        let page = 1;
        while (allIssues.length < (limitIdx >= 0 ? parseInt(subArgs[limitIdx+1])||200 : 200)) {
          const { data } = await octokit.issues.listForRepo({
            owner, repo, state, per_page: perPage, page,
            pulls: false
          });
          // pull requests を除外
          const issues = data.filter(i => !i.pull_request);
          if (!issues.length) break;
          allIssues.push(...issues);
          if (data.length < perPage) break;
          page++;
          if (allIssues.length >= 200) break;
        }
        const result = allIssues.map(i => ({
          number: i.number,
          title: i.title,
          body: i.body || '',
          labels: i.labels.map(l => ({ name: l.name })),
          closedAt: i.closed_at || null
        }));
        process.stdout.write(JSON.stringify(result));
        break;
      }

      case 'list-closed': {
        const limitIdx = subArgs.indexOf('--limit');
        const limit = limitIdx >= 0 ? parseInt(subArgs[limitIdx+1])||50 : 50;
        // fieldsオプション: --fields closedAt のみ or 全フィールド
        const fieldsIdx = subArgs.indexOf('--fields');
        const fields = fieldsIdx >= 0 ? subArgs[fieldsIdx+1].split(',') : null;
        const allIssues = [];
        let page = 1;
        while (allIssues.length < limit) {
          const { data } = await octokit.issues.listForRepo({
            owner, repo, state: 'closed', per_page: Math.min(limit, 100), page
          });
          const issues = data.filter(i => !i.pull_request);
          if (!issues.length) break;
          allIssues.push(...issues);
          if (data.length < 100 || allIssues.length >= limit) break;
          page++;
        }
        const sliced = allIssues.slice(0, limit);
        const result = sliced.map(i => {
          const base = { number: i.number, closedAt: i.closed_at || null };
          if (!fields || fields.includes('title')) base.title = i.title;
          if (!fields || fields.includes('body')) base.body = i.body || '';
          if (!fields || fields.includes('labels')) base.labels = i.labels.map(l => ({ name: l.name }));
          return base;
        });
        process.stdout.write(JSON.stringify(result));
        break;
      }

      case 'view-issue': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api view-issue <number>'); }
        const { data: i } = await octokit.issues.get({ owner, repo, issue_number: num });
        const result = {
          number: i.number,
          title: i.title,
          body: i.body || '',
          labels: i.labels.map(l => ({ name: l.name })),
          closedAt: i.closed_at || null
        };
        process.stdout.write(JSON.stringify(result));
        break;
      }

      case 'search-issues': {
        const keyword = process.env.SEARCH_KEYWORD_ENV || '';
        if (!keyword) { throw apiErr('Error: SEARCH_KEYWORD_ENV is not set'); }
        const q = `${keyword} repo:${owner}/${repo} is:issue is:open`;
        const { data } = await octokit.search.issuesAndPullRequests({ q, per_page: 50 });
        const result = data.items.map(i => ({
          number: i.number,
          title: i.title,
          body: i.body || '',
          labels: i.labels.map(l => ({ name: l.name }))
        }));
        process.stdout.write(JSON.stringify(result));
        break;
      }

      case 'list-labels': {
        const { data } = await octokit.issues.listLabelsForRepo({ owner, repo, per_page: 100 });
        const result = data.map(l => ({ name: l.name, color: l.color, description: l.description || '' }));
        process.stdout.write(JSON.stringify(result));
        break;
      }

      // ── 書き込み系 ──

      case 'create-issue': {
        const input = JSON.parse(process.env.ISSUE_INPUT_ENV || '{}');
        const { data } = await octokit.issues.create({
          owner, repo,
          title: input.title || '',
          body: input.body || '',
          labels: input.labels || []
        });
        process.stdout.write(JSON.stringify({ number: data.number, url: data.html_url }));
        break;
      }

      case 'edit-issue': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api edit-issue <number>'); }
        const input = JSON.parse(process.env.ISSUE_INPUT_ENV || '{}');
        const params = { owner, repo, issue_number: num };
        if (input.title !== undefined) params.title = input.title;
        if (input.body !== undefined) params.body = input.body;
        await octokit.issues.update(params);
        process.stdout.write('ok');
        break;
      }

      case 'close-issue': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api close-issue <number>'); }
        await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });
        process.stdout.write('ok');
        break;
      }

      case 'reopen-issue': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api reopen-issue <number>'); }
        await octokit.issues.update({ owner, repo, issue_number: num, state: 'open' });
        process.stdout.write('ok');
        break;
      }

      case 'add-labels': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api add-labels <number>'); }
        const labels = (process.env.LABELS_ENV || '').split(',').map(s => s.trim()).filter(Boolean);
        if (!labels.length) { throw apiErr('Error: LABELS_ENV is not set'); }
        await octokit.issues.addLabels({ owner, repo, issue_number: num, labels });
        process.stdout.write('ok');
        break;
      }

      case 'remove-labels': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api remove-labels <number>'); }
        const labels = (process.env.LABELS_ENV || '').split(',').map(s => s.trim()).filter(Boolean);
        for (const label of labels) {
          try {
            await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: label });
          } catch(e) {
            if (e.status !== 404) throw e; // ラベルが付いていない場合は無視
          }
        }
        process.stdout.write('ok');
        break;
      }

      case 'create-label': {
        const input = JSON.parse(process.env.LABEL_INPUT_ENV || '{}');
        try {
          await octokit.issues.createLabel({
            owner, repo,
            name: input.name,
            color: input.color || 'FBCA04',
            description: input.description || ''
          });
          process.stdout.write('created');
        } catch(e) {
          if (e.status === 422) {
            process.stdout.write('exists'); // 既存ラベルは無視（gh label create の --force 相当）
          } else {
            throw e;
          }
        }
        break;
      }

      case 'delete-label': {
        const name = process.env.LABEL_NAME_ENV || '';
        if (!name) { throw apiErr('Error: LABEL_NAME_ENV is not set'); }
        try {
          await octokit.issues.deleteLabel({ owner, repo, name });
        } catch(e) {
          if (e.status !== 404) throw e;
        }
        process.stdout.write('ok');
        break;
      }

      default:
        throw apiErr('Unknown api subcommand: '+subCmd);
    }
  } catch(e) {
    // GitHub API エラー（未処理の throw）はここでメッセージを表示してから再スロー
    if (!e._msgWritten) {
      process.stderr.write('GitHub API error: '+(e.message||String(e))+'\n');
    }
    throw e;
  }
}

// ─── メインディスパッチャー ───

const args = process.argv.slice(2);
const cmd = args[0];

switch (cmd) {
  // ユーティリティ
  case 'normalize-due':   process.stdout.write(normalizeDue(args[1], args[2])); break;
  case 'add-days':        process.stdout.write(addDays(args[1], parseInt(args[2]))); break;
  case 'add-month':       process.stdout.write(addMonth(args[1])); break;
  case 'parse-body':           process.stdout.write(parseBody(args[1])); break;
  case 'extract-issue-fields': extractIssueFields(); break;
  case 'build-body':      process.stdout.write(buildBody(args[1]||'', args[2]||'', args[3]||'', args[4]||'', args[5]||'', args[6]||'')); break;
  case 'parse-time': {
    const v = parseTime(args[1]);
    process.stdout.write(v !== null ? String(v) : 'null');
    break;
  }
  case 'format-time':     process.stdout.write(formatTime(args[1])); break;
  case 'priority-color':  process.stdout.write(priorityColor(args[1])); break;
  case 'next-due':        process.stdout.write(nextDue(args[1], args[2])); break;
  case 'decode-b64':      process.stdout.write(Buffer.from(args[1]||'','base64').toString('utf8')); break;
  case 'ctx-to-json': {
    const list = (args[1]||'').trim();
    const arr = list ? list.split(/\s+/) : [];
    process.stdout.write(JSON.stringify(arr));
    break;
  }
  case 'home-path':       process.stdout.write(path.join(homeDir(), '.claude', args[1]||'')); break;
  case 'gtd-label':       process.stdout.write(GTD_DISPLAY[args[1]] || args[1]); break;

  // バリデーション
  case 'validate':
    switch (args[1]) {
      case 'ctx':       validateCtx(args[2]); break;
      case 'number':    validateNumber(args[2]); break;
      case 'due':       validateDue(args[2]); break;
      case 'recur':     validateRecur(args[2]); break;
      case 'color':     validateColor(args[2]); break;
      case 'priority':  validatePriority(args[2]); break;
      case 'name':      validateName(args[2]); break;
      case 'time': {
        const v = parseTime(args[2]);
        if (v === null || v <= 0) { process.stderr.write(t('error.time_format')+'\n'); process.exit(1); }
        break;
      }
      default: process.stderr.write('Unknown validate type: '+args[1]+'\n'); process.exit(1);
    }
    break;

  // 集計・表示（env vars 経由）
  case 'list-all':        listAll(); break;
  case 'list-summary':    listSummary(); break;
  case 'weekly-summary':  weeklySummary(); break;
  case 'stats':           stats(); break;
  case 'help':            help(); break;
  case 'today':           today(); break;
  case 'dashboard':       dashboard(); break;
  case 'report':          report(); break;
  case 'done-count':      doneCount(); break;

  // テンプレート管理
  case 'template':
    switch (args[1]) {
      case 'list':      templateList(); break;
      case 'show':      templateShow(); break;
      case 'save':      templateSave(); break;
      case 'save-from': templateSaveFrom(); break;
      case 'use':       templateUse(); break;
      case 'delete':    templateDelete(); break;
      default: process.stderr.write('Unknown template subcommand: '+args[1]+'\n'); process.exit(1);
    }
    break;

  // ビュー管理
  case 'view':
    switch (args[1]) {
      case 'save':   viewSave(); break;
      case 'use':    viewUse(); break;
      case 'list':   viewList(); break;
      case 'delete': viewDelete(); break;
      default: process.stderr.write('Unknown view subcommand: '+args[1]+'\n'); process.exit(1);
    }
    break;

  // Octokit API
  case 'api':
    apiMain(args.slice(1)).catch(e => {
      process.stderr.write('Error: '+(e.message||String(e))+'\n');
      process.exitCode = 1;
    });
    break;

  // run サブコマンド（高レベルディスパッチャー）
  case 'run':
    runMain(args.slice(1)).catch(e => {
      if (!e._msgWritten) process.stderr.write('Error: '+(e.message||String(e))+'\n');
      process.exitCode = 1;
    });
    break;

  default:
    process.stderr.write('Unknown command: '+cmd+'\n');
    process.stderr.write('Usage: todo-engine.js <command> [args...]\n');
    process.exit(1);
}

// ─── run サブコマンド実装 ───────────────────────────────────────────────────

// Octokit 初期化（apiMain から共通化）
async function initOctokit() {
  let token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  if (!token) {
    const tokenPath = path.join(process.env.HOME || os.homedir(), '.claude', 'github-token');
    if (fs.existsSync(tokenPath)) token = fs.readFileSync(tokenPath, 'utf8').trim();
  }
  if (!token) { throw apiErr('Error: GH_TOKEN is not set and ~/.claude/github-token not found'); }

  const octokitPath = path.join(process.env.HOME || os.homedir(), '.claude', 'node_modules', '@octokit', 'rest', 'dist-src', 'index.js');
  let OctokitClass;
  try {
    const { pathToFileURL } = require('url');
    const mod = await import(pathToFileURL(octokitPath).href);
    OctokitClass = mod.Octokit;
  } catch(e) {
    throw apiErr('Error: @octokit/rest not found. Run: npm install --prefix ~/.claude @octokit/rest\nDetail: '+e.message);
  }
  return new OctokitClass({ auth: token });
}

// 汎用引数パーサー
// tokens: string[]
// 戻り値: { gtd, title, contexts, due, desc, recur, project, priority, estimate, actual, dueOffset, color, extra }
function parseArgs(tokens) {
  const result = {
    gtd: null, title: null, contexts: [], due: null, desc: null,
    recur: null, project: null, priority: null, estimate: null, actual: null,
    dueOffset: null, color: null, extra: []
  };
  const remaining = [...tokens];
  const consume = (i) => remaining.splice(i, 1);

  let i = 0;
  while (i < remaining.length) {
    const tok = remaining[i];
    if (tok === '--due' && i+1 < remaining.length) {
      result.due = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--desc' && i+1 < remaining.length) {
      // クォートで囲まれている場合はまとめて次のトークン
      result.desc = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--recur' && i+1 < remaining.length) {
      result.recur = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--project' && i+1 < remaining.length) {
      result.project = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--priority' && i+1 < remaining.length) {
      result.priority = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--estimate' && i+1 < remaining.length) {
      result.estimate = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--actual' && i+1 < remaining.length) {
      result.actual = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--due-offset' && i+1 < remaining.length) {
      result.dueOffset = remaining[i+1].replace(/^\+/, ''); remaining.splice(i, 2); continue;
    } else if (tok === '--color' && i+1 < remaining.length) {
      result.color = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok.startsWith('@')) {
      result.contexts.push(tok); remaining.splice(i, 1); continue;
    }
    i++;
  }
  result.extra = remaining;
  return result;
}

// 今日の日付を取得（TODAY環境変数 or new Date()）
function getToday() {
  if (process.env.TODAY) return process.env.TODAY;
  const d = new Date();
  return [d.getFullYear(), String(d.getMonth()+1).padStart(2,'0'), String(d.getDate()).padStart(2,'0')].join('-');
}

// ラベルが存在しなければ作成する
async function ensureLabel(octokit, owner, repo, name, color, description) {
  try {
    await octokit.issues.createLabel({ owner, repo, name, color: color||'FBCA04', description: description||'' });
  } catch(e) {
    if (e.status !== 422) throw e; // 422 = already exists
  }
}

// Issue を取得してフィールドを解析する
async function fetchAndParseIssue(octokit, owner, repo, num) {
  const { data: i } = await octokit.issues.get({ owner, repo, issue_number: num });
  const lnames = i.labels.map(l => l.name);
  const parsed = parseBodyObj(i.body || '');
  return {
    number: i.number, title: i.title, body: i.body || '',
    labels: lnames, ...parsed
  };
}

// body を解析してオブジェクトで返す
function parseBodyObj(body) {
  const lines = (body || '').split('\n');
  let due = '', recur = '', project = '', estimate = '', actual = '', descLines = [];
  for (const line of lines) {
    if (line.startsWith('due: ')) due = line.slice(5);
    else if (line.startsWith('recur: ')) recur = line.slice(7);
    else if (line.startsWith('project: #')) project = line.slice(10);
    else if (line.startsWith('estimate: ')) estimate = line.slice(10);
    else if (line.startsWith('actual: ')) actual = line.slice(8);
    else descLines.push(line);
  }
  while (descLines.length && descLines[0].trim() === '') descLines.shift();
  return { due, recur, project, estimate, actual, desc: descLines.join('\n') };
}

// Issue body を更新する
async function updateIssueBody(octokit, owner, repo, num, fields) {
  await octokit.issues.update({ owner, repo, issue_number: num, ...fields });
}

// 確認メッセージを stdout に出力
function runOut(msg) { process.stdout.write(msg+'\n'); }

// --- 各コマンドハンドラ ---

async function runAdd(octokit, owner, repo, tokens) {
  const today = getToday();
  // GTDキーワードが先頭なら抽出
  let gtd = 'inbox';
  if (GTD_LABELS.includes(tokens[0])) {
    gtd = tokens.shift();
  }
  const parsed = parseArgs(tokens);

  // タイトル: 残りトークンを連結
  const titleTokens = parsed.extra.filter(s => s.trim());
  if (!titleTokens.length) {
    process.stderr.write('エラー: タイトルが空です。\n'); process.exit(1);
  }
  const title = titleTokens.join(' ');
  validateName(title);

  // due 正規化
  let due = parsed.due ? normalizeDue(parsed.due, today) : '';
  if (due) validateDue(due);
  // M/D 正規化
  if (due && /^\d{1,2}\/\d{1,2}$/.test(due)) {
    const [m, d] = due.split('/');
    due = today.slice(0,4)+'-'+String(m).padStart(2,'0')+'-'+String(d).padStart(2,'0');
  }

  if (parsed.recur) validateRecur(parsed.recur);
  if (parsed.project) validateNumber(parsed.project);
  for (const ctx of parsed.contexts) validateCtx(ctx.slice(1));
  const priority = parsed.priority || 'p3';
  validatePriority(priority);
  let estimateMin = null;
  if (parsed.estimate) {
    estimateMin = parseTime(parsed.estimate);
    if (estimateMin === null) { process.stderr.write(t('error.time_format')+'\n'); process.exit(1); }
  }

  const labels = [GTD_DISPLAY[gtd]];
  // コンテキストラベル作成
  for (const ctx of parsed.contexts) {
    await ensureLabel(octokit, owner, repo, ctx, 'FBCA04', 'コンテキスト');
    labels.push(ctx);
  }
  // 優先度ラベル作成
  const pcolor = priorityColor(priority);
  await ensureLabel(octokit, owner, repo, priority, pcolor, '優先度');
  labels.push(priority);

  const body = buildBody(due, parsed.recur||'', parsed.project||'', estimateMin !== null ? String(estimateMin) : '', '', parsed.desc||'');

  const { data } = await octokit.issues.create({ owner, repo, title, body, labels });
  const labelStr = labels.join(', ');
  runOut(`✅ #${data.number} を作成しました。\n  タイトル: ${title}\n  ラベル: ${labelStr}${due ? '\n  期日: '+due : ''}\n  URL: ${data.html_url}`);
}

async function runList(octokit, owner, repo, tokens) {
  const today = getToday();
  const parsed = parseArgs(tokens);
  const extra = parsed.extra;

  // フィルタ判定
  let filterGtd = '', filterCtx = '', filterPri = '', filterProj = '';
  for (const tok of extra) {
    if (GTD_LABELS.includes(tok)) filterGtd = tok;
    else if (/^p[123]$/.test(tok)) filterPri = tok;
    else if (tok.startsWith('@')) { validateCtx(tok.slice(1)); filterCtx = tok; }
    else if (tok === 'project' && extra[extra.indexOf(tok)+1]) {
      const n = extra[extra.indexOf(tok)+1]; validateNumber(n); filterProj = n;
    }
  }
  for (const ctx of parsed.contexts) { validateCtx(ctx.slice(1)); filterCtx = ctx; }

  // API取得
  const allIssues = await fetchAllOpen(octokit, owner, repo);
  const env = { OPEN_ENV: JSON.stringify(allIssues), TODAY_ENV: today };
  if (filterGtd) env.FILTER_GTD_ENV = filterGtd;
  if (filterCtx) env.FILTER_CTX_ENV = filterCtx;
  if (filterPri) env.FILTER_PRI_ENV = filterPri;
  if (filterProj) env.FILTER_PROJ_ENV = filterProj;
  Object.assign(process.env, env);
  listAll();
}

async function fetchAllOpen(octokit, owner, repo) {
  const allIssues = [];
  let page = 1;
  while (allIssues.length < 200) {
    const { data } = await octokit.issues.listForRepo({ owner, repo, state: 'open', per_page: 100, page });
    const issues = data.filter(i => !i.pull_request);
    if (!issues.length) break;
    allIssues.push(...issues.map(i => ({ number: i.number, title: i.title, body: i.body||'', labels: i.labels.map(l => ({name:l.name})), closedAt: null })));
    if (data.length < 100) break;
    page++;
  }
  return allIssues;
}

async function fetchRecentClosed(octokit, owner, repo, limit, fields) {
  const allIssues = [];
  let page = 1;
  while (allIssues.length < limit) {
    const { data } = await octokit.issues.listForRepo({ owner, repo, state: 'closed', per_page: Math.min(limit, 100), page });
    const issues = data.filter(i => !i.pull_request);
    if (!issues.length) break;
    allIssues.push(...issues);
    if (data.length < 100 || allIssues.length >= limit) break;
    page++;
  }
  return allIssues.slice(0, limit).map(i => {
    const base = { number: i.number, closedAt: i.closed_at||null };
    if (!fields || fields.includes('title')) base.title = i.title;
    if (!fields || fields.includes('body')) base.body = i.body||'';
    if (!fields || fields.includes('labels')) base.labels = i.labels.map(l => ({name:l.name}));
    return base;
  });
}

async function runDone(octokit, owner, repo, tokens) {
  const today = getToday();
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));
  const parsed = parseArgs(tokens.slice(1));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  let actual = issue.actual;
  if (parsed.actual) {
    const a = parseTime(parsed.actual);
    if (a === null) { process.stderr.write(t('error.time_format')+'\n'); process.exit(1); }
    actual = String(a);
  }
  if (actual !== issue.actual) {
    const body = buildBody(issue.due, issue.recur, issue.project, issue.estimate, actual, issue.desc);
    await octokit.issues.update({ owner, repo, issue_number: num, body });
  }
  await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });

  if (issue.recur) {
    validateRecur(issue.recur);
    const base = issue.due || today;
    const nextDate = nextDue(issue.recur, base);
    const body = buildBody(nextDate, issue.recur, issue.project, issue.estimate, '', issue.desc);
    const { data: newIssue } = await octokit.issues.create({
      owner, repo, title: issue.title,
      body, labels: issue.labels
    });
    runOut(`✅ #${num} を完了しました。繰り返しタスク #${newIssue.number} を ${nextDate} で作成しました。`);
  } else {
    runOut(`✅ #${num} を完了しました。`);
  }
}

async function runMove(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const target = tokens[1];
  if (!num || !target) { process.stderr.write('Usage: run move <number> <GTD>\n'); process.exit(1); }
  validateNumber(String(num));
  if (!GTD_LABELS.includes(target)) { process.stderr.write('エラー: GTDラベルは '+GTD_LABELS.join('/')+' のいずれかです。\n'); process.exit(1); }

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const oldGtd = issue.labels.find(l => GTD_LABELS.includes(normLabel(l)));
  const newLabel = GTD_DISPLAY[target];

  if (oldGtd && oldGtd !== newLabel) {
    try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: oldGtd }); } catch(e) { if (e.status !== 404) throw e; }
  }
  await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [newLabel] });
  runOut(`✅ #${num} を ${newLabel} に移動しました。`);
}

async function runEdit(octokit, owner, repo, tokens) {
  const today = getToday();
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));
  const parsed = parseArgs(tokens.slice(1));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  let changed = [];

  let due = issue.due, recur = issue.recur, project = issue.project, desc = issue.desc, estimate = issue.estimate;

  if (parsed.due !== null) {
    due = normalizeDue(parsed.due, today);
    if (due && /^\d{1,2}\/\d{1,2}$/.test(due)) {
      const [m, d] = due.split('/');
      due = today.slice(0,4)+'-'+String(m).padStart(2,'0')+'-'+String(d).padStart(2,'0');
    }
    validateDue(due); changed.push('due → '+due);
  }
  if (parsed.recur !== null) {
    if (parsed.recur === 'clear') { recur = ''; changed.push('recur → クリア'); }
    else { validateRecur(parsed.recur); recur = parsed.recur; changed.push('recur → '+recur); }
  }
  if (parsed.project !== null) { validateNumber(parsed.project); project = parsed.project; changed.push('project → #'+project); }
  if (parsed.desc !== null) { desc = parsed.desc; changed.push('desc → '+desc); }
  if (parsed.estimate !== null) {
    const em = parseTime(parsed.estimate);
    if (em === null) { process.stderr.write(t('error.time_format')+'\n'); process.exit(1); }
    estimate = String(em); changed.push('estimate → '+formatTime(em));
  }

  const body = buildBody(due, recur, project, estimate, issue.actual, desc);
  const updateParams = { owner, repo, issue_number: num, body };

  // priority 変更
  if (parsed.priority !== null) {
    const oldPri = issue.labels.find(l => /^p[123]$/.test(l));
    if (oldPri) {
      try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: oldPri }); } catch(e) { if (e.status !== 404) throw e; }
    }
    if (parsed.priority === 'clear') {
      changed.push('priority → クリア');
    } else {
      validatePriority(parsed.priority);
      const pcolor = priorityColor(parsed.priority);
      await ensureLabel(octokit, owner, repo, parsed.priority, pcolor, '優先度');
      await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [parsed.priority] });
      changed.push('priority → '+parsed.priority);
    }
  }

  await octokit.issues.update(updateParams);
  runOut(`✅ #${num} を更新しました: ${changed.join(', ')}`);
}

async function runDue(octokit, owner, repo, tokens) {
  const today = getToday();
  const num = parseInt(tokens[0]);
  const rawDue = tokens[1];
  if (!num || !rawDue) { process.stderr.write('Usage: run due <number> <date>\n'); process.exit(1); }
  validateNumber(String(num));
  let due = normalizeDue(rawDue, today);
  if (/^\d{1,2}\/\d{1,2}$/.test(due)) {
    const [m, d] = due.split('/');
    due = today.slice(0,4)+'-'+String(m).padStart(2,'0')+'-'+String(d).padStart(2,'0');
  }
  validateDue(due);

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const body = buildBody(due, issue.recur, issue.project, issue.estimate, issue.actual, issue.desc);
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(`✅ #${num} の期日を ${due} に設定しました。`);
}

async function runDesc(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const desc = tokens.slice(1).join(' ');
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const body = buildBody(issue.due, issue.recur, issue.project, issue.estimate, issue.actual, desc);
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(`✅ #${num} の説明を更新しました。`);
}

async function runRecur(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const pattern = tokens[1];
  if (!num || !pattern) { process.stderr.write('Usage: run recur <number> <pattern|clear>\n'); process.exit(1); }
  validateNumber(String(num));
  let recur = '';
  if (pattern !== 'clear') { validateRecur(pattern); recur = pattern; }

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const body = buildBody(issue.due, recur, issue.project, issue.estimate, issue.actual, issue.desc);
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(recur ? `✅ #${num} の繰り返しを ${recur} に設定しました。` : `✅ #${num} の繰り返しをクリアしました。`);
}

async function runLink(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const proj = parseInt(tokens[1]);
  if (!num || !proj) { process.stderr.write('Usage: run link <number> <project-number>\n'); process.exit(1); }
  validateNumber(String(num)); validateNumber(String(proj));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const body = buildBody(issue.due, issue.recur, String(proj), issue.estimate, issue.actual, issue.desc);
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(`✅ #${num} をプロジェクト #${proj} に紐付けました。`);
}

async function runRename(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const newTitle = tokens.slice(1).join(' ');
  if (!num || !newTitle) { process.stderr.write('Usage: run rename <number> <new-title>\n'); process.exit(1); }
  validateNumber(String(num)); validateName(newTitle);
  await octokit.issues.update({ owner, repo, issue_number: num, title: newTitle });
  runOut(`✅ #${num} のタイトルを「${newTitle}」に変更しました。`);
}

async function runPriority(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const level = tokens[1];
  if (!num || !level) { process.stderr.write('Usage: run priority <number> <p1|p2|p3|clear>\n'); process.exit(1); }
  validateNumber(String(num));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const oldPri = issue.labels.find(l => /^p[123]$/.test(l));
  if (oldPri) {
    try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: oldPri }); } catch(e) { if (e.status !== 404) throw e; }
  }
  if (level === 'clear') {
    runOut(`✅ #${num} の優先度をクリアしました。`);
  } else {
    validatePriority(level);
    const pcolor = priorityColor(level);
    await ensureLabel(octokit, owner, repo, level, pcolor, '優先度');
    await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [level] });
    runOut(`✅ #${num} の優先度を ${level} に設定しました。`);
  }
}

async function runTag(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));
  const ctxList = tokens.slice(1).map(s => s.startsWith('@') ? s : '@'+s);
  if (!ctxList.length) { process.stderr.write('Usage: run tag <number> @ctx...\n'); process.exit(1); }
  for (const ctx of ctxList) { validateCtx(ctx.slice(1)); await ensureLabel(octokit, owner, repo, ctx, 'FBCA04', 'コンテキスト'); }
  await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: ctxList });
  runOut(`✅ #${num} に ${ctxList.join(' ')} を追加しました。`);
}

async function runUntag(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));
  const ctxList = tokens.slice(1).map(s => s.startsWith('@') ? s : '@'+s);
  if (!ctxList.length) { process.stderr.write('Usage: run untag <number> @ctx...\n'); process.exit(1); }
  for (const ctx of ctxList) {
    validateCtx(ctx.slice(1));
    try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: ctx }); } catch(e) { if (e.status !== 404) throw e; }
  }
  runOut(`✅ #${num} から ${ctxList.join(' ')} を削除しました。`);
}

async function runLabel(octokit, owner, repo, tokens) {
  const sub = tokens[0];
  if (sub === 'list') {
    const { data } = await octokit.issues.listLabelsForRepo({ owner, repo, per_page: 100 });
    const ctxLabels = data.filter(l => l.name.startsWith('@'));
    if (!ctxLabels.length) { runOut('（コンテキストラベルなし）'); return; }
    for (const l of ctxLabels) runOut(`  ${l.name}  #${l.color}  ${l.description||''}`);
  } else if (sub === 'add') {
    const name = tokens[1].startsWith('@') ? tokens[1] : '@'+tokens[1];
    const parsed = parseArgs(tokens.slice(2));
    validateCtx(name.slice(1));
    const color = parsed.color || 'FBCA04';
    if (parsed.color) validateColor(parsed.color);
    await ensureLabel(octokit, owner, repo, name, color, 'コンテキスト');
    runOut(`✅ ラベル ${name} を作成しました。`);
  } else if (sub === 'delete') {
    const name = tokens[1].startsWith('@') ? tokens[1] : '@'+tokens[1];
    validateCtx(name.slice(1));
    try { await octokit.issues.deleteLabel({ owner, repo, name }); } catch(e) { if (e.status !== 404) throw e; }
    runOut(`✅ ラベル ${name} を削除しました。`);
  } else if (sub === 'rename') {
    const oldName = tokens[1].startsWith('@') ? tokens[1] : '@'+tokens[1];
    const newName = tokens[2].startsWith('@') ? tokens[2] : '@'+tokens[2];
    validateCtx(oldName.slice(1)); validateCtx(newName.slice(1));
    await ensureLabel(octokit, owner, repo, newName, 'FBCA04', 'コンテキスト');
    const allIssues = await fetchAllOpen(octokit, owner, repo);
    const targets = allIssues.filter(i => i.labels.some(l => l.name === oldName));
    for (const i of targets) {
      await octokit.issues.addLabels({ owner, repo, issue_number: i.number, labels: [newName] });
      try { await octokit.issues.removeLabel({ owner, repo, issue_number: i.number, name: oldName }); } catch(e) { if (e.status !== 404) throw e; }
    }
    try { await octokit.issues.deleteLabel({ owner, repo, name: oldName }); } catch(e) { if (e.status !== 404) throw e; }
    runOut(`✅ ${oldName} を ${newName} にリネームしました。${targets.length}件のIssueを更新しました。`);
  } else {
    process.stderr.write('Usage: run label list|add|delete|rename\n'); process.exit(1);
  }
}

async function runSearch(octokit, owner, repo, tokens) {
  const keyword = tokens.join(' ');
  if (!keyword) { process.stderr.write('Usage: run search <keyword>\n'); process.exit(1); }
  const q = `${keyword} repo:${owner}/${repo} is:issue is:open`;
  const { data } = await octokit.search.issuesAndPullRequests({ q, per_page: 50 });
  if (!data.items.length) { runOut(`検索結果: 0件（キーワード: ${keyword}）`); return; }
  for (const i of data.items) {
    runOut(`  #${i.number}  ${i.title}  [${i.labels.map(l=>l.name).join(',')}]`);
  }
  runOut(`検索結果: ${data.items.length}件`);
}

async function runArchive(octokit, owner, repo, tokens) {
  const sub = tokens[0] || 'list';
  if (sub === 'list' || sub === 'list') {
    const filter = tokens[1] || '';
    const closed = await fetchRecentClosed(octokit, owner, repo, 30, null);
    let items = closed;
    if (filter && GTD_LABELS.includes(filter)) {
      items = closed.filter(i => i.labels && i.labels.some(l => normLabel(l.name) === filter));
    } else if (filter && filter.startsWith('@')) {
      validateCtx(filter.slice(1));
      items = closed.filter(i => i.labels && i.labels.some(l => l.name === filter));
    }
    if (!items.length) { runOut('（完了タスクなし）'); return; }
    for (const i of items) runOut(`  #${i.number}  ${i.title||''}  ✅${i.closedAt ? i.closedAt.slice(0,10) : ''}`);
    runOut(`${items.length}件`);
  } else if (sub === 'search') {
    const keyword = tokens.slice(1).join(' ');
    if (!keyword) { process.stderr.write('Usage: run archive search <keyword>\n'); process.exit(1); }
    const q = `${keyword} in:title repo:${REPO_OWNER}/${REPO_NAME} is:issue is:closed`;
    const { data } = await octokit.search.issuesAndPullRequests({ q, per_page: 30 });
    for (const i of data.items) runOut(`  #${i.number}  ${i.title}  ✅${i.closed_at ? i.closed_at.slice(0,10) : ''}`);
    runOut(`検索結果: ${data.items.length}件`);
  } else if (sub === 'reopen') {
    const num = parseInt(tokens[1]);
    if (!num) { process.stderr.write('Usage: run archive reopen <number>\n'); process.exit(1); }
    validateNumber(String(num));
    await octokit.issues.update({ owner, repo, issue_number: num, state: 'open' });
    await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: ['📥 inbox'] });
    runOut(`✅ #${num} を inbox に戻しました。`);
  } else {
    process.stderr.write('Usage: run archive [list|search|reopen]\n'); process.exit(1);
  }
}

async function runDashboard(octokit, owner, repo) {
  const today = getToday();
  const [open, closed] = await Promise.all([
    fetchAllOpen(octokit, owner, repo),
    fetchRecentClosed(octokit, owner, repo, 30, ['closedAt','number'])
  ]);
  process.env.OPEN_ENV = JSON.stringify(open);
  process.env.CLOSED_ENV = JSON.stringify(closed);
  process.env.TODAY_ENV = today;
  dashboard();
}

async function runToday(octokit, owner, repo) {
  const today = getToday();
  const [open, closed] = await Promise.all([
    fetchAllOpen(octokit, owner, repo),
    fetchRecentClosed(octokit, owner, repo, 30, ['closedAt','number'])
  ]);
  process.env.OPEN_ENV = JSON.stringify(open);
  process.env.CLOSED_ENV = JSON.stringify(closed);
  process.env.TODAY_ENV = today;
  today_fn();
}

// today 関数は既に today() という名前で定義済みなのでラッパーを作る
function today_fn() { today(); }

async function runStats(octokit, owner, repo) {
  const todayStr = getToday();
  const [open, closed] = await Promise.all([
    fetchAllOpen(octokit, owner, repo),
    fetchRecentClosed(octokit, owner, repo, 50, ['closedAt'])
  ]);
  process.env.OPEN_ENV = JSON.stringify(open);
  process.env.CLOSED_ENV = JSON.stringify(closed);
  process.env.TODAY_ENV = todayStr;
  stats();
}

async function runReport(octokit, owner, repo, tokens) {
  const todayStr = getToday();
  let days = 7;
  const sub = tokens[0] || 'weekly';
  if (sub === 'weekly') days = 7;
  else if (sub === 'monthly') days = 30;
  else if (/^(\d+)d$/.test(sub)) {
    days = parseInt(sub);
    validateNumber(String(days));
  }
  const [open, closed] = await Promise.all([
    fetchAllOpen(octokit, owner, repo),
    fetchRecentClosed(octokit, owner, repo, 200, null)
  ]);
  process.env.OPEN_ENV = JSON.stringify(open);
  process.env.CLOSED_ENV = JSON.stringify(closed);
  process.env.TODAY_ENV = todayStr;
  process.env.DAYS_ENV = String(days);
  report();
}

async function runHelp() {
  help();
}

async function runTemplate(octokit, owner, repo, tokens) {
  const sub = tokens[0];
  const today = getToday();

  if (sub === 'list') {
    templateList();
  } else if (sub === 'show') {
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run template show <name>\n'); process.exit(1); }
    validateName(name);
    process.env.TNAME_ENV = name;
    templateShow();
  } else if (sub === 'save') {
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run template save <name> [args...]\n'); process.exit(1); }
    validateName(name);
    const rest = tokens.slice(2);
    // save-from 形式
    if (rest[0] === 'from' && rest[1]) {
      validateNumber(rest[1]);
      const num = parseInt(rest[1]);
      const issue = await fetchAndParseIssue(octokit, owner, repo, num);
      const lnames = issue.labels;
      const gtd = GTD_LABELS.find(l => lnames.some(n => normLabel(n) === l)) || 'inbox';
      const contexts = lnames.filter(l => l.startsWith('@'));
      const priority = lnames.find(l => /^p[123]$/.test(l)) || 'p3';
      process.env.TNAME_ENV = name;
      process.env.GTD_ENV = gtd;
      process.env.CONTEXTS_ENV = JSON.stringify(contexts);
      process.env.DUE_ENV = issue.due || '';
      process.env.RECUR_ENV = issue.recur || '';
      process.env.PROJECT_ENV = issue.project || '';
      process.env.PRIORITY_ENV = priority;
      process.env.DESC_ENV = issue.desc || '';
      process.env.ISSUE_NUM_ENV = String(num);
      templateSaveFrom();
    } else {
      // インライン引数形式
      let gtd = 'inbox';
      if (rest.length && GTD_LABELS.includes(rest[0])) gtd = rest.shift();
      const parsed = parseArgs(rest);
      const contexts = parsed.contexts;
      const priority = parsed.priority || 'p3';
      for (const ctx of contexts) validateCtx(ctx.slice(1));
      validatePriority(priority);
      let dueOffset = '';
      if (parsed.dueOffset) {
        validateNumber(parsed.dueOffset);
        dueOffset = parsed.dueOffset;
      }
      let due = '';
      if (parsed.due && !dueOffset) {
        due = normalizeDue(parsed.due, today); validateDue(due);
      }
      if (parsed.recur) validateRecur(parsed.recur);
      if (parsed.project) validateNumber(parsed.project);
      process.env.TNAME_ENV = name;
      process.env.GTD_ENV = gtd;
      process.env.CONTEXTS_ENV = JSON.stringify(contexts);
      process.env.DUE_OFFSET_ENV = dueOffset;
      process.env.DUE_ENV = due;
      process.env.RECUR_ENV = parsed.recur || '';
      process.env.PROJECT_ENV = parsed.project || '';
      process.env.PRIORITY_ENV = priority;
      process.env.DESC_ENV = parsed.desc || '';
      templateSave();
    }
  } else if (sub === 'use') {
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run template use <name> [title-override]\n'); process.exit(1); }
    validateName(name);
    const overrideTitle = tokens.slice(2).join(' ');
    process.env.TNAME_ENV = name;
    // templateUse は stdout に KEY=VALUE を出力する関数なので、内部で直接読む
    const data = readJsonFile(getTemplatePath());
    if (!data[name]) { process.stderr.write(tpl('template.not_found', {name})+'\n'); process.exit(1); }
    const tmpl = data[name];

    const gtd = tmpl.gtd || 'inbox';
    const contexts = tmpl.context || [];
    const priority = tmpl.priority || 'p3';
    let due = '';
    if (tmpl['due-offset']) due = addDays(today, parseInt(tmpl['due-offset']));
    else if (tmpl.due) due = tmpl.due;
    const recur = tmpl.recur || '';
    const proj = tmpl.project ? String(tmpl.project) : '';
    const desc = tmpl.desc || '';
    const title = overrideTitle || name;

    const labels = [GTD_DISPLAY[gtd]];
    for (const ctx of contexts) {
      await ensureLabel(octokit, owner, repo, ctx, 'FBCA04', 'コンテキスト');
      labels.push(ctx);
    }
    const pcolor = priorityColor(priority);
    await ensureLabel(octokit, owner, repo, priority, pcolor, '優先度');
    labels.push(priority);

    const estMin = tmpl.estimate ? parseTime(String(tmpl.estimate)) : null;
    const body = buildBody(due, recur, proj, estMin !== null ? String(estMin) : '', '', desc);
    const { data: newIssue } = await octokit.issues.create({ owner, repo, title, body, labels });
    runOut(`✅ テンプレート「${name}」から Issue #${newIssue.number} を作成しました。\n  タイトル: ${title}\n  ラベル: ${labels.join(', ')}${due ? '\n  期日: '+due : ''}`);
  } else if (sub === 'delete') {
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run template delete <name>\n'); process.exit(1); }
    validateName(name);
    process.env.TNAME_ENV = name;
    templateDelete();
  } else {
    process.stderr.write('Usage: run template list|show|save|use|delete\n'); process.exit(1);
  }
}

async function runView(octokit, owner, repo, tokens) {
  const sub = tokens[0];
  if (sub === 'list') {
    viewList();
  } else if (sub === 'save') {
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run view save <name> [filters...]\n'); process.exit(1); }
    validateName(name);
    const rest = tokens.slice(2);
    let gtd = '', ctx = '', pri = '';
    for (const tok of rest) {
      if (GTD_LABELS.includes(tok)) gtd = tok;
      else if (/^p[123]$/.test(tok)) pri = tok;
      else if (tok.startsWith('@')) { validateCtx(tok.slice(1)); ctx = tok; }
    }
    process.env.VNAME_ENV = name;
    process.env.GTD_ENV = gtd;
    process.env.CTX_ENV = ctx;
    process.env.PRI_ENV = pri;
    viewSave();
  } else if (sub === 'use' || !sub.startsWith('-')) {
    // view use <name> または view <name>（subがコマンド名でない場合）
    const name = sub === 'use' ? tokens[1] : sub;
    if (!name) { process.stderr.write('Usage: run view use <name>\n'); process.exit(1); }
    validateName(name);
    process.env.VNAME_ENV = name;
    // viewUse の出力を読んで list フィルタに適用
    const vdata = readJsonFile(getViewPath());
    if (!vdata[name]) { process.stderr.write(tpl('view.not_found', {name})+'\n'); process.exit(1); }
    const v = vdata[name];
    const today = getToday();
    const allIssues = await fetchAllOpen(octokit, owner, repo);
    process.env.OPEN_ENV = JSON.stringify(allIssues);
    process.env.TODAY_ENV = today;
    if (v.gtd) process.env.FILTER_GTD_ENV = v.gtd;
    if (v.context && v.context.length) process.env.FILTER_CTX_ENV = v.context[0];
    if (v.priority) process.env.FILTER_PRI_ENV = v.priority;
    const parts = [v.gtd, v.context ? v.context.join(' ') : '', v.priority].filter(Boolean);
    runOut(`## 👁 ビュー: ${name} [${parts.join(', ')}]\n`);
    listAll();
  } else if (sub === 'delete') {
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run view delete <name>\n'); process.exit(1); }
    validateName(name);
    process.env.VNAME_ENV = name;
    viewDelete();
  } else {
    process.stderr.write('Usage: run view list|save|use|delete\n'); process.exit(1);
  }
}

async function runBulk(octokit, owner, repo, tokens) {
  const sub = tokens[0];
  if (!['done','move','tag','untag','priority'].includes(sub)) {
    process.stderr.write('Usage: run bulk <done|move|tag|untag|priority> <numbers...> [options]\n'); process.exit(1);
  }

  // 番号を先頭から収集（数字のみ）
  const nums = [];
  let i = 1;
  while (i < tokens.length && /^\d+$/.test(tokens[i])) { nums.push(parseInt(tokens[i])); i++; }
  const rest = tokens.slice(i);
  if (!nums.length) { process.stderr.write('エラー: Issue番号が指定されていません。\n'); process.exit(1); }
  for (const n of nums) validateNumber(String(n));

  let doneCount = 0, errCount = 0;
  if (sub === 'done') {
    for (const num of nums) {
      try {
        const parsed = parseArgs(rest);
        const issue = await fetchAndParseIssue(octokit, owner, repo, num);
        let actual = issue.actual;
        if (parsed.actual) { const a = parseTime(parsed.actual); if (a !== null) actual = String(a); }
        if (actual !== issue.actual) {
          const body = buildBody(issue.due, issue.recur, issue.project, issue.estimate, actual, issue.desc);
          await octokit.issues.update({ owner, repo, issue_number: num, body });
        }
        await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });
        doneCount++;
      } catch(e) { runOut(`  #${num} エラー: ${e.message}`); errCount++; }
    }
    runOut(`✅ ${doneCount}件完了${errCount ? '（エラー: '+errCount+'件）' : ''}`);
  } else if (sub === 'move') {
    const target = rest[0];
    if (!target || !GTD_LABELS.includes(target)) { process.stderr.write('エラー: GTDラベルを指定してください。\n'); process.exit(1); }
    const newLabel = GTD_DISPLAY[target];
    for (const num of nums) {
      try {
        const issue = await fetchAndParseIssue(octokit, owner, repo, num);
        const oldGtd = issue.labels.find(l => GTD_LABELS.includes(normLabel(l)));
        if (oldGtd && oldGtd !== newLabel) {
          try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: oldGtd }); } catch(e) { if (e.status !== 404) throw e; }
        }
        await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [newLabel] });
        doneCount++;
      } catch(e) { runOut(`  #${num} エラー: ${e.message}`); errCount++; }
    }
    runOut(`✅ ${doneCount}件を ${newLabel} に移動${errCount ? '（エラー: '+errCount+'件）' : ''}`);
  } else if (sub === 'tag') {
    const ctxList = rest.map(s => s.startsWith('@') ? s : '@'+s);
    if (!ctxList.length) { process.stderr.write('Usage: run bulk tag <nums...> @ctx...\n'); process.exit(1); }
    for (const ctx of ctxList) { validateCtx(ctx.slice(1)); await ensureLabel(octokit, owner, repo, ctx, 'FBCA04', 'コンテキスト'); }
    for (const num of nums) {
      try { await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: ctxList }); doneCount++; }
      catch(e) { runOut(`  #${num} エラー: ${e.message}`); errCount++; }
    }
    runOut(`✅ ${doneCount}件に ${ctxList.join(' ')} を追加${errCount ? '（エラー: '+errCount+'件）' : ''}`);
  } else if (sub === 'untag') {
    const ctxList = rest.map(s => s.startsWith('@') ? s : '@'+s);
    if (!ctxList.length) { process.stderr.write('Usage: run bulk untag <nums...> @ctx...\n'); process.exit(1); }
    for (const ctx of ctxList) validateCtx(ctx.slice(1));
    for (const num of nums) {
      try {
        for (const ctx of ctxList) {
          try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: ctx }); } catch(e) { if (e.status !== 404) throw e; }
        }
        doneCount++;
      } catch(e) { runOut(`  #${num} エラー: ${e.message}`); errCount++; }
    }
    runOut(`✅ ${doneCount}件から ${ctxList.join(' ')} を削除${errCount ? '（エラー: '+errCount+'件）' : ''}`);
  } else if (sub === 'priority') {
    const level = rest[0];
    if (!level) { process.stderr.write('Usage: run bulk priority <nums...> <p1|p2|p3|clear>\n'); process.exit(1); }
    if (level !== 'clear') validatePriority(level);
    if (level !== 'clear') { const pcolor = priorityColor(level); await ensureLabel(octokit, owner, repo, level, pcolor, '優先度'); }
    for (const num of nums) {
      try {
        const issue = await fetchAndParseIssue(octokit, owner, repo, num);
        const oldPri = issue.labels.find(l => /^p[123]$/.test(l));
        if (oldPri) { try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: oldPri }); } catch(e) { if (e.status !== 404) throw e; } }
        if (level !== 'clear') await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [level] });
        doneCount++;
      } catch(e) { runOut(`  #${num} エラー: ${e.message}`); errCount++; }
    }
    runOut(`✅ ${doneCount}件の優先度を ${level} に設定${errCount ? '（エラー: '+errCount+'件）' : ''}`);
  }
}

// runMain: コマンドディスパッチャー
async function runMain(args) {
  const octokit = await initOctokit();
  const owner = REPO_OWNER, repo = REPO_NAME;

  let cmd = args[0];
  const rest = args.slice(1);

  // GTDキーワードが先頭 → add として扱う
  if (GTD_LABELS.includes(cmd)) {
    return await runAdd(octokit, owner, repo, args);
  }

  // コマンドなし → list
  if (!cmd) {
    return await runList(octokit, owner, repo, []);
  }

  switch (cmd) {
    case 'add':       return await runAdd(octokit, owner, repo, rest);
    case 'list':      return await runList(octokit, owner, repo, rest);
    case 'done':
    case 'close':     return await runDone(octokit, owner, repo, rest);
    case 'move':      return await runMove(octokit, owner, repo, rest);
    case 'edit':      return await runEdit(octokit, owner, repo, rest);
    case 'due':       return await runDue(octokit, owner, repo, rest);
    case 'desc':      return await runDesc(octokit, owner, repo, rest);
    case 'recur':     return await runRecur(octokit, owner, repo, rest);
    case 'link':      return await runLink(octokit, owner, repo, rest);
    case 'rename':    return await runRename(octokit, owner, repo, rest);
    case 'priority':  return await runPriority(octokit, owner, repo, rest);
    case 'tag':       return await runTag(octokit, owner, repo, rest);
    case 'untag':     return await runUntag(octokit, owner, repo, rest);
    case 'label':     return await runLabel(octokit, owner, repo, rest);
    case 'search':    return await runSearch(octokit, owner, repo, rest);
    case 'archive':   return await runArchive(octokit, owner, repo, rest);
    case 'dashboard':
    case 'dash':      return await runDashboard(octokit, owner, repo);
    case 'today':     return await runToday(octokit, owner, repo);
    case 'stats':     return await runStats(octokit, owner, repo);
    case 'report':    return await runReport(octokit, owner, repo, rest);
    case 'help':      return await runHelp();
    case 'template':  return await runTemplate(octokit, owner, repo, rest);
    case 'view':      return await runView(octokit, owner, repo, rest);
    case 'bulk':      return await runBulk(octokit, owner, repo, rest);
    default:
      // フォールバック: GTDキーワードでなければ add inbox として扱う
      return await runAdd(octokit, owner, repo, args);
  }
}
