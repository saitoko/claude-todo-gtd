#!/usr/bin/env node
// todo-engine.js — /todo スキルの deterministic 処理エンジン
// Claude が毎回コピペしていた Node.js ブロックとバリデーションを集約

'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

// ─── 定数 ───
const GTD_LABELS = ['next','routine','inbox','waiting','someday','reference'];
const PROJECT_LABEL = 'project';
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
    'list.stale': '30日更新なし（停滞）',
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
    'help.recur': '/todo recur <#> <パターン|clear>  繰り返し設定（daily/weekly/monthly/weekdays）/ clear で解除',
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
    // promote / activate
    'error.before_needs_due': 'エラー: --before を使うには --due が必要です',
    'error.before_format': 'エラー: --before は 14d / 2w 形式で指定してください（例: 14d, 2w）',
    'error.activate_after_due': '⚠️ 警告: activate日（{activate}）が due日（{due}）より後です',
    'promote.header': '## チクラーファイル昇格',
    'promote.promoted': '✅ #{num} 「{title}」を next に昇格しました（activate: {activate}）',
    'promote.no_targets': '昇格対象なし（activate日到来タスク: 0件）',
    'promote.summary': '✅ {n}件を next に昇格しました',
    'help.promote': '/todo promote                   activate日到来タスクをNEXTに昇格',
    'help.activate': '  --activate <日付>             指定日にNEXTへ自動昇格（例: 2026-05-01）',
    'help.before': '  --before <期間>               dueのN日前にNEXTへ自動昇格（例: 14d, 2w）',
    'help.depends_on': '  --depends-on <#N>            指定タスク完了時にNEXTへ自動昇格',
    'promote.promoted_depends': '✅ #{num} 「{title}」を next に昇格しました（#{dep} 完了トリガー）',
    'done.promote_hint_header': '💡 プロジェクト #{proj}「{title}」に昇格候補があります:',
    'done.promote_hint_item':   '  {i}. #{num}「{title}」({gtd})',
    'done.promote_hint_footer': '番号を入力するか /todo move <#> next で昇格できます。',
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
    'list.stale': '30 days no update (stale)',
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
    'help.recur': '/todo recur <#> <pattern|clear>  Set recurrence (daily/weekly/monthly/weekdays) / clear to remove',
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
    // promote / activate
    'error.before_needs_due': 'Error: --before requires --due',
    'error.before_format': 'Error: --before must be in 14d / 2w format (e.g. 14d, 2w)',
    'error.activate_after_due': '⚠️ Warning: activate date ({activate}) is after due date ({due})',
    'promote.header': '## Tickler File Promotion',
    'promote.promoted': '✅ #{num} "{title}" promoted to next (activate: {activate})',
    'promote.no_targets': 'No targets to promote (activate date arrived: 0)',
    'promote.summary': '✅ {n} tasks promoted to next',
    'help.promote': '/todo promote                   Promote tasks whose activate date has arrived',
    'help.activate': '  --activate <date>             Auto-promote to NEXT on specified date',
    'help.before': '  --before <duration>           Auto-promote N days before due (e.g. 14d, 2w)',
    'help.depends_on': '  --depends-on <#N>            Auto-promote to NEXT when specified task is completed',
    'promote.promoted_depends': '✅ #{num} "{title}" promoted to next (#{dep} completion trigger)',
    'done.promote_hint_header': '💡 Project #{proj} "{title}" has promotion candidates:',
    'done.promote_hint_item':   '  {i}. #{num} "{title}" ({gtd})',
    'done.promote_hint_footer': 'Enter a number or use /todo move <#> next to promote.',
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

// before指定（"14d", "2w"）を日数に変換。不正形式または0以下はnullを返す
function parseBeforeDuration(raw) {
  if (!raw) return null;
  let m;
  if ((m = raw.match(/^(\d+)d$/i))) { const n = parseInt(m[1]); if (n <= 0) return null; return n; }
  if ((m = raw.match(/^(\d+)w$/i))) { const n = parseInt(m[1]); if (n <= 0) return null; return n * 7; }
  return null;
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
  const DOW_NAMES = ['日','月','火','水','木','金','土'];
  let result = null;
  if      (raw === '今日' || raw === 'きょう')             { result = today; }
  else if (raw === '明日' || raw === 'あした' || raw === 'あす')  { result = fmt(add(d(), 1)); }
  else if (raw === '明後日' || raw === 'あさって')         { result = fmt(add(d(), 2)); }
  else if (raw === '昨日' || raw === 'きのう')             { result = fmt(add(d(), -1)); }
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
    // 来週X曜: 来週月曜日 を起点に指定曜日へ
    else if ((m=raw.match(/^来週([月火水木金土日])曜(?:日)?$/))) {
      const target=DOW_NAMES.indexOf(m[1]);
      const dt=d();
      const toNextMon=((1-dt.getDay()+7)%7)||7;
      dt.setDate(dt.getDate()+toNextMon);
      const offset=target===0?6:target-1;
      dt.setDate(dt.getDate()+offset);
      result=fmt(dt);
    }
    // 今週X曜: 今週のその曜日（今日より前なら今日）
    else if ((m=raw.match(/^今週([月火水木金土日])曜(?:日)?$/))) {
      const target=DOW_NAMES.indexOf(m[1]);
      const dt=d();
      const dow=dt.getDay();
      const diff=target-dow;
      const offset=diff<0?0:diff;
      result=fmt(add(dt,offset));
    }
    // X曜 or X曜日: 次に来るその曜日（今日ならば今日）
    else if ((m=raw.match(/^([月火水木金土日])曜(?:日)?$/))) {
      const target=DOW_NAMES.indexOf(m[1]);
      const dt=d();
      const dow=dt.getDay();
      const diff=(target-dow+7)%7;
      result=fmt(add(dt,diff));
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
  let due = '', recur = '', project = '', estimate = '', actual = '', activate = '', before = '', reviewedAt = '', descLines = [];
  for (const line of lines) {
    if (line.startsWith('due: ')) due = line.slice(5);
    else if (line.startsWith('recur: ')) recur = line.slice(7);
    else if (line.startsWith('project: #')) project = line.slice(10);
    else if (line.startsWith('estimate: ')) estimate = line.slice(10);
    else if (line.startsWith('actual: ')) actual = line.slice(8);
    else if (line.startsWith('activate: ')) activate = line.slice(10);
    else if (line.startsWith('before: ')) before = line.slice(8);
    else if (line.startsWith('reviewed_at: ')) reviewedAt = line.slice(13);
    else descLines.push(line);
  }
  while (descLines.length && descLines[0].trim() === '') descLines.shift();
  const desc = descLines.join('\n');
  const descB64 = Buffer.from(desc, 'utf8').toString('base64');
  return 'DUE='+due+'\nRECUR='+recur+'\nPROJECT='+project+'\nESTIMATE='+estimate+'\nACTUAL='+actual+'\nACTIVATE='+activate+'\nBEFORE='+before+'\nREVIEWED_AT='+reviewedAt+'\nDESC_B64='+descB64;
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

function buildBody(due, recur, project, estimate, actual, desc, activate, before, reviewedAt, dependsOn) {
  let body = '';
  const NL = '\n';
  if (due) body += 'due: '+due+NL;
  if (activate) body += 'activate: '+activate+NL;
  if (before) body += 'before: '+before+NL;
  if (dependsOn) body += 'depends_on: #'+dependsOn+NL;
  if (recur) body += 'recur: '+recur+NL;
  if (project) body += 'project: #'+project+NL;
  if (estimate) body += 'estimate: '+estimate+NL;
  if (actual) body += 'actual: '+actual+NL;
  if (reviewedAt) body += 'reviewed_at: '+reviewedAt+NL;
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
  // project ラベルを先に確認
  if (name === GTD_DISPLAY[PROJECT_LABEL]) return PROJECT_LABEL;
  for (const key of GTD_LABELS) { if (name === GTD_DISPLAY[key]) return key; }
  return name;
}
function getLnames(issue) { return issue.labels.map(l => normLabel(l.name)); }
function getDue(issue) { const m = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m); return m ? m[1] : null; }
function getPri(lnames) { return lnames.find(l => /^p[123]$/.test(l)) || 'p9'; }
function priIcon(p) { return p==='p1' ? '🔴 ' : p==='p2' ? '🟡 ' : ''; }
function getCtx(lnames) { return lnames.filter(l => l.startsWith('@')); }

// 戻り値は負になりうる（dateAがdateBより未来の場合）。呼び出し元で >= 30 判定を使うこと。
function daysBetween(dateA, dateB) {
  const a = new Date(dateA + 'T00:00:00');
  const b = new Date(dateB + 'T00:00:00');
  return Math.floor((b - a) / 86400000);
}

function sortByPriDue(a, b) {
  const pa = getPri(getLnames(a)), pb = getPri(getLnames(b));
  if (pa !== pb) return pa < pb ? -1 : 1;
  const da = getDue(a) || '9999', db = getDue(b) || '9999';
  return da < db ? -1 : da > db ? 1 : 0;
}

function sortByReviewedAtThenPri(a, b, today) {
  const STALE_DAYS = 30;
  const getReviewedAt = (issue) => {
    return (issue.body||'').match(/^reviewed_at: (\d{4}-\d{2}-\d{2})/m)?.[1] || '';
  };
  const isStale = (issue) => {
    const r = getReviewedAt(issue);
    return !r || daysBetween(r, today) >= STALE_DAYS;
  };
  const staleA = isStale(a), staleB = isStale(b);
  if (staleA && !staleB) return -1;
  if (!staleA && staleB) return 1;
  return sortByPriDue(a, b);
}

function renderIssueList(issue, today) {
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
  // someday かつ長期未見直しの場合にマーカーを付ける
  if (today && (lnames.includes('someday') || lnames.includes('🌈 someday'))) {
    const reviewedAt = (issue.body||'').match(/^reviewed_at: (\d{4}-\d{2}-\d{2})/m)?.[1] || '';
    if (!reviewedAt || daysBetween(reviewedAt, today) >= 30) {
      line = '  ⚠️' + line.slice(2);
    }
  }
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

function listGroupedByDue(issues, today) {
  const w = s => process.stdout.write(s);
  const d1 = new Date(today+'T00:00:00');
  const tomorrow = new Date(d1); tomorrow.setDate(d1.getDate()+1);
  const tomorrowStr = fmt(tomorrow);
  const d7 = new Date(d1); d7.setDate(d1.getDate()+7);
  const d7str = fmt(d7);
  const d14 = new Date(d1); d14.setDate(d1.getDate()+14);

  // MM/DD 形式ヘッダー用
  const mmdd = (dateStr) => {
    const [,m,d] = dateStr.split('-');
    return parseInt(m)+'/'+parseInt(d);
  };

  const groups = { overdue:[], today_:[], tomorrow_:[], thisWeek:[], later:[], noDue:[] };
  for (const issue of issues) {
    const due = getDue(issue);
    if (!due) { groups.noDue.push(issue); continue; }
    if (due < today)          { groups.overdue.push(issue); }
    else if (due === today)   { groups.today_.push(issue); }
    else if (due === tomorrowStr) { groups.tomorrow_.push(issue); }
    else if (due <= d7str)    { groups.thisWeek.push(issue); }
    else                       { groups.later.push(issue); }
  }

  for (const key of ['overdue','today_','tomorrow_','thisWeek','later','noDue']) {
    groups[key].sort(sortByPriDue);
  }

  if (groups.overdue.length) {
    w('── ⚠️ 期限超過 ──\n');
    for (const i of groups.overdue) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.today_.length) {
    w('── 📅 今日（'+mmdd(today)+'）──\n');
    for (const i of groups.today_) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.tomorrow_.length) {
    w('── 📅 明日（'+mmdd(tomorrowStr)+'）──\n');
    for (const i of groups.tomorrow_) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.thisWeek.length) {
    w('── 📅 今週（〜'+mmdd(d7str)+'）──\n');
    for (const i of groups.thisWeek) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.later.length) {
    w('── 📅 来週以降 ──\n');
    for (const i of groups.later) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.noDue.length) {
    w('── 📅 期限なし ──\n');
    for (const i of groups.noDue) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
}

function listAll() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const filterGtd = process.env.FILTER_GTD_ENV || '';
  const filterCtx = process.env.FILTER_CTX_ENV || '';
  const filterPri = process.env.FILTER_PRI_ENV || '';
  const filterProj = process.env.FILTER_PROJ_ENV || '';
  const groupByDue = process.env.FILTER_GROUP_ENV === '1';
  const noDue = process.env.FILTER_NO_DUE_ENV === '1';
  const noEstimate = process.env.FILTER_NO_ESTIMATE_ENV === '1';
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

  // --no-due → 期限未設定のタスクだけフラットリストで返す（--group より優先）
  if (noDue) {
    filtered = filtered.filter(i => !/(^|\n)due: \d{4}-\d{2}-\d{2}/.test(i.body||''));
    filtered.sort(sortByPriDue);
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    for (const issue of filtered) { w(renderIssueList(issue, today)+'\n'); }
    return;
  }

  // --no-estimate → 見積もり未設定のタスクだけフラットリストで返す（--no-due と同パターン）
  if (noEstimate) {
    filtered = filtered.filter(i => !/(^|\n)estimate: \S+/.test(i.body||''));
    filtered.sort(sortByPriDue);
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    for (const issue of filtered) { w(renderIssueList(issue, today)+'\n'); }
    return;
  }

  // フィルタ指定あり かつ --group → 期限別グルーピング
  if ((filterGtd || filterCtx || filterPri || filterProj) && groupByDue) {
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    listGroupedByDue(filtered, today);
    return;
  }

  // フィルタ指定あり → フラットリスト
  if (filterGtd || filterCtx || filterPri || filterProj) {
    if (filterGtd === 'someday') {
      filtered.sort((a, b) => sortByReviewedAtThenPri(a, b, today));
    } else {
      filtered.sort(sortByPriDue);
    }
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    for (const issue of filtered) { w(renderIssueList(issue, today)+'\n'); }
    return;
  }

  // フィルタなし かつ --group → 全タスクを期限別グルーピング
  if (groupByDue) {
    if (!issues.length) { w(t('list.no_match')+'\n'); return; }
    listGroupedByDue(issues, today);
    return;
  }

  // フィルタなし → GTDカテゴリ別グルーピング
  const grouped = {};
  GTD_LABELS.forEach(l => grouped[l] = []);
  grouped[PROJECT_LABEL] = [];
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) grouped[gl].push(issue); }
    if (lnames.includes(PROJECT_LABEL)) grouped[PROJECT_LABEL].push(issue);
  }

  // GTDカテゴリ（project 除く）をソートして出力
  const labelsToShow = ['next','routine','inbox','waiting','someday','reference'];
  for (const label of labelsToShow) {
    w(GTD_SECTION_HEADERS[label]+'\n');
    const items = grouped[label];
    if (!items.length) { w('  '+t('list.none')+'\n'); }
    else {
      if (label === 'someday') {
        items.sort((a, b) => sortByReviewedAtThenPri(a, b, today));
      } else {
        items.sort(sortByPriDue);
      }
      for (const issue of items) { w(renderIssueList(issue, today)+'\n'); }
    }
    w('\n');
  }

  // プロジェクトセクション（独立表示）
  const projItems = grouped[PROJECT_LABEL];
  let noNextCount = 0, staleCount = 0;
  const projStats = projItems.map(issue => {
    const projTag = 'project: #'+issue.number;
    // body メタ検索と sub-issue の両方は非同期不可のため body メタのみでカウント
    const childIssues = issues.filter(i => (i.body||'').includes(projTag));
    const nextCount = childIssues.filter(i => getLnames(i).includes('next')).length;
    const waitingCount = childIssues.filter(i => getLnames(i).includes('waiting')).length;
    const hasNext = nextCount > 0;
    const updatedAt = issue.updated_at || '';
    const isStale = updatedAt ? daysBetween(updatedAt.slice(0,10), today) >= 30 : false;
    if (!hasNext) noNextCount++;
    if (isStale) staleCount++;
    return { issue, nextCount, waitingCount, hasNext, isStale };
  });

  // ヘッダ行
  let projHeader = t('section.project');
  if (projItems.length > 0) {
    const badges = [];
    if (noNextCount > 0) badges.push(`⚠️ next欠落: ${noNextCount}件`);
    if (staleCount > 0) badges.push(`停滞30日以上: ${staleCount}件`);
    projHeader = `## 📁 Projects（${projItems.length}件${badges.length ? '  ' + badges.join(' / ') : ''}）`;
  }
  w(projHeader+'\n');
  if (!projItems.length) {
    w('  '+t('list.none')+'\n');
  } else {
    for (const { issue, nextCount, waitingCount, hasNext, isStale } of projStats) {
      const childSummary = [];
      if (nextCount > 0) childSummary.push(`next:${nextCount}件`);
      if (waitingCount > 0) childSummary.push(`waiting:${waitingCount}件`);
      const childStr = childSummary.length ? `  ✅ ${childSummary.join(' ')}` : '';
      let statusStr = '';
      if (!hasNext && isStale) {
        statusStr = `  ${t('list.no_next')} / ${t('list.stale')}`;
      } else if (!hasNext) {
        statusStr = `  ${t('list.no_next')}`;
      } else {
        statusStr = childStr;
      }
      // reviewed_at があれば「最終レビュー: N日前」を付加
      const reviewedAt = parseBodyObj(issue.body || '').reviewedAt;
      const reviewStr = reviewedAt ? `  （最終レビュー: ${daysBetween(reviewedAt, today)}日前）` : '';
      // 停滞+next欠落の行頭に ⚠️ マーカー
      const linePrefix = (!hasNext && isStale) ? '  ⚠️ ' : '  ';
      w(`${linePrefix}#${issue.number}  ${issue.title}${statusStr}${reviewStr}\n`);
    }
  }
  w('\n');

  // サマリー
  const counts = {};
  GTD_LABELS.forEach(l => counts[l] = grouped[l].length);
  counts[PROJECT_LABEL] = grouped[PROJECT_LABEL].length;
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
  const allLabels = [...GTD_LABELS, PROJECT_LABEL];
  const parts = allLabels.filter(l => counts[l] > 0).map(l => l+': '+cnt(counts[l]));
  w('📊 '+(parts.length ? parts.join(' / ') : t('list.no_tasks')));
  if (overdue > 0) w('  ⚠️ '+t('list.overdue')+': '+cnt(overdue));
  if (thisWeek > 0) w('  📅 '+t('list.this_week')+': '+cnt(thisWeek));
  w('\n');
}

function listSummary() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const counts = {};
  [...GTD_LABELS, PROJECT_LABEL].forEach(l => counts[l] = 0);
  let overdue = 0, thisWeek = 0;
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) counts[gl]++; }
    if (lnames.includes(PROJECT_LABEL)) counts[PROJECT_LABEL]++;
    const dueMatch = (issue.body||'').match(/^due: (\d{4}-\d{2}-\d{2})/m);
    if (dueMatch) {
      if (dueMatch[1] < today) overdue++;
      else if (dueMatch[1] <= d7str) thisWeek++;
    }
  }
  const parts = [...GTD_LABELS, PROJECT_LABEL].filter(l => counts[l] > 0).map(l => l+': '+cnt(counts[l]));
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
  [...GTD_LABELS, PROJECT_LABEL].forEach(l => counts[l] = 0);
  let overdue = 0, thisWeek = 0;
  const overdueList = [], thisWeekList = [];
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) counts[gl]++; }
    if (lnames.includes(PROJECT_LABEL)) counts[PROJECT_LABEL]++;
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
  const parts = [...GTD_LABELS, PROJECT_LABEL].filter(l => counts[l] > 0).map(l => '  '+l+': '+cnt(counts[l]));
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
  [...GTD_LABELS, PROJECT_LABEL].forEach(l => gtdCounts[l] = 0);
  const priCounts = {p1:0, p2:0, p3:0, none:0};
  let overdue = 0, thisWeek = 0, total = issues.length;
  const d7 = new Date(today); d7.setDate(d7.getDate()+7);
  const d7str = d7.toISOString().slice(0,10);
  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) gtdCounts[gl]++; }
    if (lnames.includes(PROJECT_LABEL)) gtdCounts[PROJECT_LABEL]++;
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
  [...GTD_LABELS, PROJECT_LABEL].filter(l => gtdCounts[l] > 0).forEach(l => { w('  '+l+': '+cnt(gtdCounts[l])+'\n'); });
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
  for (const k of ['review','archive','link','promote','help']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w('### activate / before オプション\n');
  w('```\n');
  w(t('help.activate')+'\n');
  w(t('help.before')+'\n');
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
  [...GTD_LABELS, PROJECT_LABEL].forEach(l => gtdCounts[l] = 0);

  for (const issue of issues) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) gtdCounts[gl]++; }
    if (lnames.includes(PROJECT_LABEL)) gtdCounts[PROJECT_LABEL]++;
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
  [...GTD_LABELS, PROJECT_LABEL].forEach(l => closedByGtd[l] = 0);
  for (const issue of periodClosed) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) closedByGtd[gl]++; }
    if (lnames.includes(PROJECT_LABEL)) closedByGtd[PROJECT_LABEL]++;
  }

  const closedByPri = {p1:0, p2:0, p3:0, none:0};
  for (const issue of periodClosed) {
    const lnames = getLnames(issue);
    const pri = lnames.find(l => /^p[123]$/.test(l));
    if (pri) closedByPri[pri]++; else closedByPri.none++;
  }

  const openByGtd = {};
  [...GTD_LABELS, PROJECT_LABEL].forEach(l => openByGtd[l] = 0);
  let overdueCount = 0;
  for (const issue of open) {
    const lnames = getLnames(issue);
    for (const gl of GTD_LABELS) { if (lnames.includes(gl)) openByGtd[gl]++; }
    if (lnames.includes(PROJECT_LABEL)) openByGtd[PROJECT_LABEL]++;
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
  const closedGtdParts = [...GTD_LABELS, PROJECT_LABEL].filter(l => closedByGtd[l] > 0);
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
  const openParts = [...GTD_LABELS, PROJECT_LABEL].filter(l => openByGtd[l] > 0);
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
  case 'build-body':      process.stdout.write(buildBody(args[1]||'', args[2]||'', args[3]||'', args[4]||'', args[5]||'', args[6]||'', args[7]||'', args[8]||'', args[9]||'', args[10]||'')); break;
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
// 戻り値: { gtd, title, contexts, due, desc, recur, project, priority, estimate, actual, dueOffset, color, activate, before, dependsOn, extra }
function parseArgs(tokens) {
  const result = {
    gtd: null, title: null, contexts: [], due: null, desc: null,
    recur: null, project: null, priority: null, estimate: null, actual: null,
    dueOffset: null, color: null, activate: null, before: null, dependsOn: null, extra: []
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
    } else if (tok === '--activate' && i+1 < remaining.length) {
      result.activate = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--before' && i+1 < remaining.length) {
      result.before = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--depends-on' && i+1 < remaining.length) {
      result.dependsOn = remaining[i+1].replace(/^#/, ''); remaining.splice(i, 2); continue;
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
    number: i.number, id: i.id, title: i.title, body: i.body || '',
    labels: lnames, ...parsed
  };
}

// ─── sub-issue ヘルパ（Phase 1 互換レイヤ） ───

// 親 Issue に子を sub-issue として登録（冪等: 422 は既登録としてスキップ）
async function addSubIssue(octokit, owner, repo, parentNumber, childInternalId) {
  try {
    await octokit.request('POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues', {
      owner, repo,
      issue_number: parentNumber,
      sub_issue_id: childInternalId,
      headers: { 'X-GitHub-Api-Version': '2022-11-28' },
    });
    return 'registered';
  } catch (e) {
    if (e.status === 422) {
      process.stderr.write(`⚠️ sub-issue 登録スキップ: #${parentNumber} に既に登録済み（冪等）\n`);
      return 'skipped';
    }
    process.stderr.write(`⚠️ sub-issue 登録失敗（Issue は作成済み）: ${e.message}\n`);
    return 'error';
  }
}

// 親 Issue の sub-issue 一覧取得（per_page:100）
async function listSubIssues(octokit, owner, repo, parentNumber) {
  try {
    const { data } = await octokit.request('GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues', {
      owner, repo,
      issue_number: parentNumber,
      per_page: 100,
      headers: { 'X-GitHub-Api-Version': '2022-11-28' },
    });
    return data;
  } catch (e) {
    process.stderr.write(`⚠️ sub-issue 一覧取得失敗: ${e.message}\n`);
    return [];
  }
}

// sub-issue の関連を解除（Phase 2 の /todo unlink で使用予定）
async function removeSubIssue(octokit, owner, repo, parentNumber, childInternalId) {
  try {
    await octokit.request('DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue', {
      owner, repo,
      issue_number: parentNumber,
      data: { sub_issue_id: childInternalId },
      headers: { 'X-GitHub-Api-Version': '2022-11-28' },
    });
  } catch (e) {
    process.stderr.write(`⚠️ sub-issue 解除失敗: ${e.message}\n`);
  }
}

// body を解析してオブジェクトで返す
function parseBodyObj(body) {
  const lines = (body || '').split('\n');
  let due = '', recur = '', project = '', estimate = '', actual = '', activate = '', before = '', reviewedAt = '', dependsOn = '', descLines = [];
  for (const line of lines) {
    if (line.startsWith('due: ')) due = line.slice(5);
    else if (line.startsWith('recur: ')) recur = line.slice(7);
    else if (line.startsWith('project: #')) project = line.slice(10);
    else if (line.startsWith('estimate: ')) estimate = line.slice(10);
    else if (line.startsWith('actual: ')) actual = line.slice(8);
    else if (line.startsWith('activate: ')) activate = line.slice(10);
    else if (line.startsWith('before: ')) before = line.slice(8);
    else if (line.startsWith('reviewed_at: ')) reviewedAt = line.slice(13);
    else if (line.startsWith('depends_on: #')) dependsOn = line.slice(13);
    else descLines.push(line);
  }
  while (descLines.length && descLines[0].trim() === '') descLines.shift();
  return { due, recur, project, estimate, actual, activate, before, reviewedAt, dependsOn, desc: descLines.join('\n') };
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
  // GTDキーワードが先頭なら抽出（project は別分岐）
  let gtd = 'inbox';
  if (tokens[0] === PROJECT_LABEL) {
    gtd = tokens.shift();
  } else if (GTD_LABELS.includes(tokens[0])) {
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

  // Outcome 警告（project タスクの場合）
  if (gtd === PROJECT_LABEL) {
    const outcomePattern = /（している|できている|完了|終了|リリース|公開|決まった|した状態）$|している$|できている$|完了$|終了$|リリース$|公開$|決まった$|した状態$/;
    if (!outcomePattern.test(title)) {
      process.stderr.write('💡 ヒント: プロジェクト名は「〜している状態」「〜が完了している」のような\n   成果物（outcome）の形で書くと Next Action を導出しやすくなります。\n');
    }
  }

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

  // activate / before 処理
  let activate = '';
  let beforeStr = '';
  if (parsed.before) {
    if (!due) { process.stderr.write(t('error.before_needs_due')+'\n'); process.exit(1); }
    const days = parseBeforeDuration(parsed.before);
    if (days === null) { process.stderr.write(t('error.before_format')+'\n'); process.exit(1); }
    beforeStr = parsed.before;
    activate = addDays(due, -days);
  }
  if (parsed.activate) {
    let activateRaw = parsed.activate;
    if (activateRaw !== 'clear') {
      activateRaw = normalizeDue(activateRaw, today);
      if (!activateRaw) {
        process.stderr.write(t('error.date_format') + ': ' + parsed.activate + '\n');
        process.exit(1);
      }
      if (!/^\d{4}-\d{2}-\d{2}$/.test(activateRaw) && !/^\d{1,2}\/\d{1,2}$/.test(activateRaw)) {
        process.stderr.write(t('error.date_format') + ': ' + parsed.activate + '\n');
        process.exit(1);
      }
      if (/^\d{1,2}\/\d{1,2}$/.test(activateRaw)) {
        const [m2, d2] = activateRaw.split('/');
        activateRaw = today.slice(0,4)+'-'+String(m2).padStart(2,'0')+'-'+String(d2).padStart(2,'0');
      }
      // activateとbefore同時指定 → より早い方を採用
      if (activate && activateRaw < activate) {
        activate = activateRaw;
      } else if (!activate) {
        activate = activateRaw;
      }
      if (due && activate > due) {
        process.stderr.write(tpl('error.activate_after_due', { activate, due })+'\n');
      }
    }
  }

  const body = buildBody(due, parsed.recur||'', parsed.project||'', estimateMin !== null ? String(estimateMin) : '', '', parsed.desc||'', activate, beforeStr, '', parsed.dependsOn||'');

  const { data } = await octokit.issues.create({ owner, repo, title, body, labels });
  const labelStr = labels.join(', ');
  runOut(`✅ #${data.number} を作成しました。\n  タイトル: ${title}\n  ラベル: ${labelStr}${due ? '\n  期日: '+due : ''}${activate ? '\n  昇格予定: '+activate : ''}\n  URL: ${data.html_url}`);

  // sub-issue 登録（--project N 指定時）
  if (parsed.project) {
    const parentNum = parseInt(parsed.project);
    let parentIssue;
    try {
      parentIssue = await fetchAndParseIssue(octokit, owner, repo, parentNum);
    } catch (e) {
      process.stderr.write(`⚠️ プロジェクト #${parentNum} の取得に失敗しました: ${e.message}\n`);
      return;
    }
    const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
    if (!isProject) {
      process.stderr.write(`エラー: #${parentNum} はプロジェクトではありません。先に /todo project <タイトル> で作成してください\n`);
      process.exit(1);
    }
    await addSubIssue(octokit, owner, repo, parentNum, data.id);
  }
}

async function runList(octokit, owner, repo, tokens) {
  const today = getToday();
  const parsed = parseArgs(tokens);
  const extra = parsed.extra;

  // フィルタ判定
  let filterGtd = '', filterCtx = '', filterPri = '', filterProj = '';
  let groupByDue = false;
  let noDue = false;
  let noEstimate = false;
  let listProjectNum = '';  // /todo list project N の N
  for (let i = 0; i < extra.length; i++) {
    const tok = extra[i];
    if (tok === '--group') { groupByDue = true; continue; }
    if (tok === '--no-due') { noDue = true; continue; }
    if (tok === '--no-estimate') { noEstimate = true; continue; }
    if (GTD_LABELS.includes(tok)) filterGtd = tok;
    else if (/^p[123]$/.test(tok)) filterPri = tok;
    else if (tok.startsWith('@')) { validateCtx(tok.slice(1)); filterCtx = tok; }
    else if (tok === PROJECT_LABEL) {
      // /todo list project N → sub-issue API 経由で子一覧表示
      const n = extra[i+1];
      if (n && /^\d+$/.test(n)) { validateNumber(n); listProjectNum = n; i++; }
      else { filterGtd = PROJECT_LABEL; }
    }
  }
  for (const ctx of parsed.contexts) { validateCtx(ctx.slice(1)); filterCtx = ctx; }

  // /todo list project N → sub-issue API + body メタ OR で子一覧表示
  if (listProjectNum) {
    const allIssues = await fetchAllOpen(octokit, owner, repo);
    const parentNum = parseInt(listProjectNum);

    // sub-issue API から子番号を取得
    const subIssues = await listSubIssues(octokit, owner, repo, parentNum);
    const subNums = new Set(subIssues.map(s => s.number));

    // body メタ検索（後方互換）
    const projTag = 'project: #'+listProjectNum;
    const bodyChildren = allIssues.filter(i => (i.body||'').includes(projTag));
    for (const bc of bodyChildren) subNums.add(bc.number);

    const children = allIssues.filter(i => subNums.has(i.number));
    children.sort(sortByPriDue);
    const w = s => process.stdout.write(s);
    w(`## 📁 プロジェクト #${parentNum} の子タスク（${children.length}件）\n`);
    if (!children.length) {
      w('  （子タスクなし）\n');
    } else {
      for (const issue of children) { w(renderIssueList(issue, today)+'\n'); }
    }
    return;
  }

  // API取得
  const allIssues = await fetchAllOpen(octokit, owner, repo);
  const env = { OPEN_ENV: JSON.stringify(allIssues), TODAY_ENV: today };
  if (filterGtd) env.FILTER_GTD_ENV = filterGtd;
  if (filterCtx) env.FILTER_CTX_ENV = filterCtx;
  if (filterPri) env.FILTER_PRI_ENV = filterPri;
  if (filterProj) env.FILTER_PROJ_ENV = filterProj;
  if (groupByDue && !noDue) env.FILTER_GROUP_ENV = '1';
  if (noDue) env.FILTER_NO_DUE_ENV = '1';
  if (noEstimate) env.FILTER_NO_ESTIMATE_ENV = '1';
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
    allIssues.push(...issues.map(i => ({ number: i.number, title: i.title, body: i.body||'', labels: i.labels.map(l => ({name:l.name})), closedAt: null, updated_at: i.updated_at || '' })));
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
    const body = buildBody(issue.due, issue.recur, issue.project, issue.estimate, actual, issue.desc, issue.activate, issue.before, issue.reviewedAt || '', issue.dependsOn || '');
    await octokit.issues.update({ owner, repo, issue_number: num, body });
  }
  await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });

  if (issue.recur) {
    validateRecur(issue.recur);
    const base = issue.due || today;
    const nextDate = nextDue(issue.recur, base);
    // beforeがあればactivateを再計算
    let nextActivate = '';
    const nextBefore = issue.before || '';
    if (nextBefore) {
      const days = parseBeforeDuration(nextBefore);
      if (days !== null) nextActivate = addDays(nextDate, -days);
    }
    // 繰り返しタスク再作成時はreviewed_atを空に（新サイクル開始）
    const body = buildBody(nextDate, issue.recur, issue.project, issue.estimate, '', issue.desc, nextActivate, nextBefore, '', '');
    const { data: newIssue } = await octokit.issues.create({
      owner, repo, title: issue.title,
      body, labels: issue.labels
    });
    runOut(`✅ #${num} を完了しました。繰り返しタスク #${newIssue.number} を ${nextDate} で作成しました。${nextActivate ? '（activate: '+nextActivate+'）' : ''}`);
  } else {
    runOut(`✅ #${num} を完了しました。`);
  }

  // depends_on: #N 昇格トリガー — 完了した Issue を依存先とするオープン Issue を next に昇格
  const allOpenIssues = await fetchAllOpen(octokit, owner, repo);
  {
    const nextLabel = GTD_DISPLAY['next'];
    let promoted = 0;
    for (const raw of allOpenIssues) {
      const parsedRaw = parseBodyObj(raw.body || '');
      if (!parsedRaw.dependsOn) continue;
      if (String(parsedRaw.dependsOn) !== String(num)) continue;
      const lnames = (raw.labels || []).map(l => l.name);
      // project ラベルを持つ Issue は昇格対象外
      if (lnames.some(l => normLabel(l) === PROJECT_LABEL)) continue;
      const gtdLabel = lnames.find(l => GTD_LABELS.includes(normLabel(l)));
      // すでに next ならスキップ
      if (gtdLabel && normLabel(gtdLabel) === 'next') continue;
      // GTDラベルを next に切り替え
      if (gtdLabel) {
        try { await octokit.issues.removeLabel({ owner, repo, issue_number: raw.number, name: gtdLabel }); } catch(e) { if (e.status !== 404) throw e; }
      }
      await octokit.issues.addLabels({ owner, repo, issue_number: raw.number, labels: [nextLabel] });
      runOut(tpl('promote.promoted_depends', { num: raw.number, title: raw.title, dep: num }));
      promoted++;
    }
    if (promoted > 0) runOut(tpl('promote.summary', { n: promoted }));
  }

  // プロジェクト次タスク昇格候補ヒント — 完了タスクのプロジェクトに紐づくオープンタスクのうち昇格候補を表示
  if (issue.project) {
    const projNum = String(issue.project).trim();
    // プロジェクト Issue 本体のタイトルを取得
    let projTitle = '#' + projNum;
    try {
      const { data: projIssue } = await octokit.issues.get({ owner, repo, issue_number: parseInt(projNum) });
      projTitle = projIssue.title || projTitle;
    } catch(e) { /* タイトル取得失敗時はデフォルト値を使用 */ }

    // 昇格候補: project フィールドが #projNum と一致し、next でも project でもない Issue
    const candidates = [];
    for (const raw of allOpenIssues) {
      const parsedRaw = parseBodyObj(raw.body || '');
      if (String(parsedRaw.project).trim() !== projNum) continue;
      const lnames = (raw.labels || []).map(l => normLabel(l.name));
      // project ラベルを持つ Issue（プロジェクト本体）は除外
      if (lnames.some(l => l === PROJECT_LABEL)) continue;
      // すでに next の Issue は除外
      const gtdLabel = lnames.find(l => GTD_LABELS.includes(l));
      if (gtdLabel === 'next') continue;
      candidates.push({ num: raw.number, title: raw.title, gtd: gtdLabel || 'inbox' });
    }

    if (candidates.length > 0) {
      runOut(tpl('done.promote_hint_header', { proj: projNum, title: projTitle }));
      candidates.forEach((c, idx) => {
        const gtdDisplay = GTD_DISPLAY[c.gtd] || c.gtd;
        runOut(tpl('done.promote_hint_item', { i: idx + 1, num: c.num, title: c.title, gtd: gtdDisplay }));
      });
      runOut(t('done.promote_hint_footer'));
    }
  }
}

async function runMove(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const target = tokens[1];
  if (!num || !target) { process.stderr.write('Usage: run move <number> <GTD>\n'); process.exit(1); }
  validateNumber(String(num));

  // project への移動を禁止
  if (target === PROJECT_LABEL) {
    process.stderr.write('エラー: project への移動はできません。\nプロジェクト昇格には /todo promote-project <N> を使ってください。\n');
    process.exit(1);
  }

  if (!GTD_LABELS.includes(target)) { process.stderr.write('エラー: GTDラベルは '+GTD_LABELS.join('/')+' のいずれかです。\n'); process.exit(1); }

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  // project ラベルは保持するため GTD_LABELS のみから oldGtd を検出
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
  let activate = issue.activate || '', beforeStr = issue.before || '', dependsOn = issue.dependsOn || '';
  let dueChanged = false;

  if (parsed.due !== null) {
    due = normalizeDue(parsed.due, today);
    if (due && /^\d{1,2}\/\d{1,2}$/.test(due)) {
      const [m, d] = due.split('/');
      due = today.slice(0,4)+'-'+String(m).padStart(2,'0')+'-'+String(d).padStart(2,'0');
    }
    validateDue(due); changed.push('due → '+due); dueChanged = true;
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

  // activate / before 編集
  if (parsed.before !== null) {
    if (parsed.before === 'clear') {
      beforeStr = ''; activate = ''; changed.push('before → クリア');
    } else {
      if (!due) { process.stderr.write(t('error.before_needs_due')+'\n'); process.exit(1); }
      const days = parseBeforeDuration(parsed.before);
      if (days === null) { process.stderr.write(t('error.before_format')+'\n'); process.exit(1); }
      beforeStr = parsed.before;
      activate = addDays(due, -days);
      changed.push('before → '+beforeStr+' (activate: '+activate+')');
    }
  }
  if (parsed.activate !== null) {
    if (parsed.activate === 'clear') {
      activate = ''; beforeStr = ''; changed.push('activate → クリア');
    } else {
      let activateRaw = normalizeDue(parsed.activate, today);
      if (!activateRaw) {
        process.stderr.write(t('error.date_format') + ': ' + parsed.activate + '\n');
        process.exit(1);
      }
      if (!/^\d{4}-\d{2}-\d{2}$/.test(activateRaw) && !/^\d{1,2}\/\d{1,2}$/.test(activateRaw)) {
        process.stderr.write(t('error.date_format') + ': ' + parsed.activate + '\n');
        process.exit(1);
      }
      if (/^\d{1,2}\/\d{1,2}$/.test(activateRaw)) {
        const [m2, d2] = activateRaw.split('/');
        activateRaw = today.slice(0,4)+'-'+String(m2).padStart(2,'0')+'-'+String(d2).padStart(2,'0');
      }
      // activateとbefore同時指定 → より早い方を採用
      if (beforeStr && activate && activateRaw > activate) {
        // beforeで計算済みのactivateの方が早い → 何もしない
      } else {
        activate = activateRaw;
      }
      if (due && activate > due) {
        process.stderr.write(tpl('error.activate_after_due', { activate, due })+'\n');
      }
      changed.push('activate → '+activate);
    }
  }

  // due変更 かつ beforeあり → activate再計算
  if (dueChanged && beforeStr && parsed.activate === null) {
    const days = parseBeforeDuration(beforeStr);
    if (days !== null) {
      activate = addDays(due, -days);
      changed.push('activate 再計算 → '+activate);
    }
  }

  // depends_on 編集
  if (parsed.dependsOn !== null) {
    if (parsed.dependsOn === 'clear') {
      dependsOn = ''; changed.push('depends_on → クリア');
    } else {
      validateNumber(parsed.dependsOn);
      dependsOn = parsed.dependsOn; changed.push('depends_on → #'+dependsOn);
    }
  }

  const body = buildBody(due, recur, project, estimate, issue.actual, desc, activate, beforeStr, issue.reviewedAt || '', dependsOn);
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
  const body = buildBody(due, issue.recur, issue.project, issue.estimate, issue.actual, issue.desc, issue.activate || '', issue.before || '', issue.reviewedAt || '', issue.dependsOn || '');
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(`✅ #${num} の期日を ${due} に設定しました。`);
}

async function runDesc(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const desc = tokens.slice(1).join(' ');
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const body = buildBody(issue.due, issue.recur, issue.project, issue.estimate, issue.actual, desc, issue.activate || '', issue.before || '', issue.reviewedAt || '', issue.dependsOn || '');
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
  const body = buildBody(issue.due, recur, issue.project, issue.estimate, issue.actual, issue.desc, issue.activate || '', issue.before || '', issue.reviewedAt || '', issue.dependsOn || '');
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(recur ? `✅ #${num} の繰り返しを ${recur} に設定しました。` : `✅ #${num} の繰り返しをクリアしました。`);
}

async function runLink(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const proj = parseInt(tokens[1]);
  if (!num || !proj) { process.stderr.write('Usage: run link <number> <project-number>\n'); process.exit(1); }
  validateNumber(String(num)); validateNumber(String(proj));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);

  // 親プロジェクトの存在・ラベル確認
  let parentIssue;
  try {
    parentIssue = await fetchAndParseIssue(octokit, owner, repo, proj);
  } catch (e) {
    process.stderr.write(`エラー: プロジェクト #${proj} の取得に失敗しました: ${e.message}\n`);
    process.exit(1);
  }
  const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
  if (!isProject) {
    process.stderr.write(`エラー: #${proj} はプロジェクトではありません。先に /todo project <タイトル> で作成してください\n`);
    process.exit(1);
  }

  // body の project: #N メタ行を更新（従来処理）
  const body = buildBody(issue.due, issue.recur, String(proj), issue.estimate, issue.actual, issue.desc, issue.activate || '', issue.before || '', issue.reviewedAt || '', issue.dependsOn || '');
  await octokit.issues.update({ owner, repo, issue_number: num, body });

  // sub-issue も登録（Phase 1 互換レイヤ）
  await addSubIssue(octokit, owner, repo, proj, issue.id);

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
    if (filter && (GTD_LABELS.includes(filter) || filter === PROJECT_LABEL)) {
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
      if (rest.length && (GTD_LABELS.includes(rest[0]) || rest[0] === PROJECT_LABEL)) gtd = rest.shift();
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
    const body = buildBody(due, recur, proj, estMin !== null ? String(estMin) : '', '', desc, '', '', '');
    const { data: newIssue } = await octokit.issues.create({ owner, repo, title, body, labels });
    runOut(`✅ テンプレート「${name}」から Issue #${newIssue.number} を作成しました。\n  タイトル: ${title}\n  ラベル: ${labels.join(', ')}${due ? '\n  期日: '+due : ''}`);

    // sub-issue 登録（テンプレートに project が含まれる場合）
    if (proj) {
      const parentNum = parseInt(proj);
      let parentIssue;
      try {
        parentIssue = await fetchAndParseIssue(octokit, owner, repo, parentNum);
      } catch (e) {
        process.stderr.write(`⚠️ プロジェクト #${parentNum} の取得に失敗しました: ${e.message}\n`);
        return;
      }
      const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
      if (!isProject) {
        process.stderr.write(`⚠️ #${parentNum} はプロジェクトではありません。先に /todo project <タイトル> で作成してください\n`);
        return;
      }
      await addSubIssue(octokit, owner, repo, parentNum, newIssue.id);
    }
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

async function runShow(octokit, owner, repo, tokens) {
  const numStr = (tokens[0] || '').replace(/^#/, '');
  if (!numStr || !/^\d+$/.test(numStr)) {
    process.stderr.write('Usage: /todo show <Issue番号>\n');
    process.exit(1);
  }
  const num = parseInt(numStr, 10);

  let issue;
  try {
    issue = await fetchAndParseIssue(octokit, owner, repo, num);
  } catch (e) {
    if (e.status === 404) {
      process.stderr.write(`エラー: Issue #${num} が見つかりません。\n`);
    } else {
      process.stderr.write(`エラー: Issue の取得に失敗しました（${e.message}）\n`);
    }
    process.exit(1);
  }

  // GTDカテゴリを判定
  const gtdLabel = GTD_LABELS.find(l => issue.labels.includes(GTD_DISPLAY[l]))
    || (issue.labels.includes(GTD_DISPLAY[PROJECT_LABEL]) ? 'project' : '');
  const gtdDisplay = gtdLabel ? (GTD_DISPLAY[gtdLabel] || gtdLabel) : '（未分類）';

  // コンテキストを抽出（@で始まるラベル）
  const ctxLabels = issue.labels.filter(l => l.startsWith('@'));
  const ctxDisplay = ctxLabels.length ? ctxLabels.join(', ') : '（なし）';

  // 優先度を抽出
  const priLabel = issue.labels.find(l => /^p[123]$/.test(l)) || '';
  const priDisplay = priLabel || '（なし）';

  // タグ（GTD・コンテキスト・優先度以外のラベル）
  const systemLabels = new Set([
    ...GTD_LABELS.map(l => GTD_DISPLAY[l]),
    GTD_DISPLAY[PROJECT_LABEL],
    ...ctxLabels,
    ...(priLabel ? [priLabel] : []),
  ]);
  const tags = issue.labels.filter(l => !systemLabels.has(l));
  const tagsDisplay = tags.length ? tags.join(', ') : '（なし）';

  // 見積もりを分 → 表示形式に変換
  const estDisplay = issue.estimate ? formatTime(parseInt(issue.estimate)) : '（なし）';

  // 1行サマリー（値がある項目だけ | 区切りで並べる）
  const summaryParts = [];
  if (gtdLabel) summaryParts.push(gtdDisplay);
  if (ctxLabels.length) summaryParts.push(ctxLabels.join(', '));
  if (priLabel) summaryParts.push(priLabel);
  if (issue.due) summaryParts.push(`期限:${issue.due}`);
  if (issue.estimate) summaryParts.push(`見積:${estDisplay}`);
  if (issue.recur) summaryParts.push(`繰り返し:${issue.recur}`);
  if (issue.project) summaryParts.push(`📁#${issue.project}`);
  if (tags.length) summaryParts.push(`タグ:${tags.join(',')}`);
  if (issue.activate) summaryParts.push(`activate:${issue.activate}`);
  if (issue.dependsOn) summaryParts.push(`depends_on:#${issue.dependsOn}`);

  const lines = [
    `## #${issue.number} ${issue.title}`,
    summaryParts.join(' | '),
  ];

  if (issue.desc && issue.desc.trim()) {
    lines.push('');
    lines.push(`詳細: ${issue.desc.trim()}`);
  }

  runOut(lines.join('\n'));
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
      if (GTD_LABELS.includes(tok) || tok === PROJECT_LABEL) gtd = tok;
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
          const body = buildBody(issue.due, issue.recur, issue.project, issue.estimate, actual, issue.desc, issue.activate || '', issue.before || '', issue.reviewedAt || '', issue.dependsOn || '');
          await octokit.issues.update({ owner, repo, issue_number: num, body });
        }
        await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });
        doneCount++;
      } catch(e) { runOut(`  #${num} エラー: ${e.message}`); errCount++; }
    }
    runOut(`✅ ${doneCount}件完了${errCount ? '（エラー: '+errCount+'件）' : ''}`);
  } else if (sub === 'move') {
    const target = rest[0];
    if (!target || !GTD_LABELS.includes(target)) {
      if (target === PROJECT_LABEL) {
        process.stderr.write('エラー: project への移動はできません。\nプロジェクト昇格には /todo promote-project <N> を使ってください。\n');
      } else {
        process.stderr.write('エラー: GTDラベルを指定してください。\n');
      }
      process.exit(1);
    }
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

async function runReviewSomeday(octokit, owner, repo, tokens) {
  const today = getToday();
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write('Usage: run review-someday <number>\n'); process.exit(1); }
  validateNumber(String(num));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);

  // somedayラベルを持つIssueのみ対象
  const gtdLabel = issue.labels.find(l => GTD_LABELS.includes(normLabel(l)));
  if (!gtdLabel || normLabel(gtdLabel) !== 'someday') {
    process.stderr.write(`エラー: #${num} はsomedayタスクではありません。\n`);
    process.exit(1);
  }

  const body = buildBody(issue.due, issue.recur, issue.project, issue.estimate, issue.actual, issue.desc, issue.activate || '', issue.before || '', today, issue.dependsOn || '');
  await updateIssueBody(octokit, owner, repo, num, { body });
  runOut(`✅ #${num} の reviewed_at を ${today} に更新しました。`);
}

async function runPromote(octokit, owner, repo) {
  const today = getToday();
  const allIssues = await fetchAllOpen(octokit, owner, repo);
  const nextLabel = GTD_DISPLAY['next'];
  let promoted = 0;

  for (const raw of allIssues) {
    const parsed = parseBodyObj(raw.body || '');
    if (!parsed.activate) continue;
    if (parsed.activate > today) continue;

    const lnames = (raw.labels || []).map(l => l.name);
    // project ラベルを持つ Issue は activate 対象外
    if (lnames.some(l => normLabel(l) === PROJECT_LABEL)) continue;
    const gtdLabel = lnames.find(l => GTD_LABELS.includes(normLabel(l)));
    // すでに next ならスキップ
    if (gtdLabel && normLabel(gtdLabel) === 'next') continue;

    // GTDラベルをnextに切り替え
    if (gtdLabel) {
      try { await octokit.issues.removeLabel({ owner, repo, issue_number: raw.number, name: gtdLabel }); } catch(e) { if (e.status !== 404) throw e; }
    }
    await octokit.issues.addLabels({ owner, repo, issue_number: raw.number, labels: [nextLabel] });
    runOut(tpl('promote.promoted', { num: raw.number, title: raw.title, activate: parsed.activate }));
    promoted++;
  }

  if (promoted === 0) {
    runOut(t('promote.no_targets'));
  } else {
    runOut(tpl('promote.summary', { n: promoted }));
  }
}

// /todo promote-project <N> [--outcome "〜"] — 既存 Issue をプロジェクトに昇格
async function runPromoteProject(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write('Usage: /todo promote-project <N> [--outcome "タイトル"]\n'); process.exit(1); }
  validateNumber(String(num));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);

  // 既に project ラベルを持つ場合はエラー
  if (issue.labels.some(l => normLabel(l) === PROJECT_LABEL)) {
    process.stderr.write(`エラー: #${num} は既にプロジェクトです。\n`);
    process.exit(1);
  }

  // GTD ラベルを外す
  const oldGtd = issue.labels.find(l => GTD_LABELS.includes(normLabel(l)));
  if (oldGtd) {
    try { await octokit.issues.removeLabel({ owner, repo, issue_number: num, name: oldGtd }); } catch(e) { if (e.status !== 404) throw e; }
  }

  // 📁 project ラベルを付与
  await ensureLabel(octokit, owner, repo, GTD_DISPLAY[PROJECT_LABEL], '0052CC', 'GTD: project');
  await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [GTD_DISPLAY[PROJECT_LABEL]] });

  // --outcome 指定時はタイトルを書き換え
  let newTitle = issue.title;
  const outcomeIdx = tokens.indexOf('--outcome');
  if (outcomeIdx !== -1 && tokens[outcomeIdx+1]) {
    newTitle = tokens[outcomeIdx+1];
    validateName(newTitle);
    await octokit.issues.update({ owner, repo, issue_number: num, title: newTitle });
  }

  runOut(`✅ #${num} 「${newTitle}」をプロジェクトに昇格しました。`);
  runOut(`💡 最初の Next Action を追加するには: /todo next <タイトル> --project ${num}`);
}

// /todo unlink <N> — 子 Issue の sub-issue 関連と body project 行を解除
async function runUnlink(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write('Usage: /todo unlink <N>\n'); process.exit(1); }
  validateNumber(String(num));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);

  // body に project: #N がなければエラー
  const projMatch = (issue.body||'').match(/^project: #(\d+)/m);
  if (!projMatch) {
    process.stderr.write(`エラー: #${num} にプロジェクト紐付けがありません。\n`);
    process.exit(1);
  }
  const parentNum = parseInt(projMatch[1]);

  // removeSubIssue を呼ぶ
  await removeSubIssue(octokit, owner, repo, parentNum, issue.id);

  // body から project: #N 行を削除
  const newBody = (issue.body||'').replace(/^project: #\d+\r?\n?/m, '');
  await octokit.issues.update({ owner, repo, issue_number: num, body: newBody });

  runOut(`✅ #${num} のプロジェクト紐付けを解除しました。`);
}

// /todo weekly-project-audit — 全プロジェクトを走査し棚卸しを促す
async function runWeeklyProjectAudit(octokit, owner, repo) {
  const today = getToday();
  const allIssues = await fetchAllOpen(octokit, owner, repo);

  // 📁 project ラベルを持つ Issue を抽出
  const projects = allIssues.filter(i => {
    const lnames = (i.labels || []).map(l => l.name || l);
    return lnames.some(l => normLabel(l) === PROJECT_LABEL);
  });

  if (!projects.length) {
    runOut('## 📁 プロジェクト棚卸し（0件）\n\nプロジェクトがありません。');
    return;
  }

  runOut(`## 📁 プロジェクト棚卸し（全${projects.length}件）\n`);

  let reviewedCount = 0;
  for (let idx = 0; idx < projects.length; idx++) {
    const proj = projects[idx];
    const projNum = proj.number;

    // sub-issue API + body メタ OR で子タスクを取得
    const subIssues = await listSubIssues(octokit, owner, repo, projNum);
    const subNums = new Set(subIssues.map(s => s.number));
    const projTag = 'project: #' + projNum;
    const bodyChildren = allIssues.filter(i => (i.body||'').includes(projTag));
    for (const bc of bodyChildren) subNums.add(bc.number);
    const children = allIssues.filter(i => subNums.has(i.number));

    // GTD カテゴリ別集計
    const nextCount = children.filter(i => {
      const lnames = (i.labels||[]).map(l => l.name||l);
      return lnames.some(l => normLabel(l) === 'next');
    }).length;
    const waitingCount = children.filter(i => {
      const lnames = (i.labels||[]).map(l => l.name||l);
      return lnames.some(l => normLabel(l) === 'waiting');
    }).length;
    const somedayCount = children.filter(i => {
      const lnames = (i.labels||[]).map(l => l.name||l);
      return lnames.some(l => normLabel(l) === 'someday');
    }).length;

    // 停滞判定（親 Issue の updated_at から今日まで 30 日以上）
    const updatedAt = proj.updated_at || '';
    const daysSinceUpdate = updatedAt ? daysBetween(updatedAt.slice(0, 10), today) : 0;
    const isStale = daysSinceUpdate >= 30;
    const hasNext = nextCount > 0;

    // 判定
    let verdict = '';
    let suggestions = '';
    if (!hasNext && isStale) {
      verdict = '⚠️ nextなし / 30日更新なし（停滞）';
      suggestions = `  → 対応候補: /todo next <タイトル> --project ${projNum} / /todo move ${projNum} someday / /todo close ${projNum}`;
    } else if (!hasNext) {
      verdict = '⚠️ next欠落';
      suggestions = `  → 対応候補: /todo next <タイトル> --project ${projNum} / /todo move ${projNum} someday / /todo close ${projNum}`;
    } else {
      verdict = '✅ 問題なし';
    }

    // 直近更新の表示
    const updateStr = updatedAt ? `${daysSinceUpdate}日前` : '不明';

    const w = s => process.stdout.write(s);
    w(`[${idx+1}/${projects.length}] #${projNum} ${proj.title}\n`);
    w(`  子タスク: next=${nextCount}件 waiting=${waitingCount}件 someday=${somedayCount}件\n`);
    w(`  直近更新: ${updateStr}\n`);
    w(`  判定: ${verdict}\n`);
    if (suggestions) w(suggestions + '\n');
    w('\n');

    // next 欠落 or 停滞プロジェクトに reviewed_at を書き込む
    if (!hasNext || isStale) {
      const parsed = parseBodyObj(proj.body || '');
      const newBody = buildBody(
        parsed.due, parsed.recur, parsed.project,
        parsed.estimate, parsed.actual, parsed.desc,
        parsed.activate || '', parsed.before || '', today, parsed.dependsOn || ''
      );
      try {
        await octokit.issues.update({ owner, repo, issue_number: projNum, body: newBody });
        reviewedCount++;
      } catch (e) {
        process.stderr.write(`⚠️ #${projNum} の reviewed_at 書き込み失敗: ${e.message}\n`);
      }
    }
  }

  runOut(`---\n棚卸し完了: ${projects.length}件確認 / reviewed_at 記録: ${reviewedCount}件`);
}

// /todo migrate sub-issue [--dry-run] — body project: #N メタを持つ Issue を sub-issue に一括登録
async function runMigrateSubIssue(octokit, owner, repo, tokens) {
  const dryRun = tokens.includes('--dry-run');
  const allIssues = await fetchAllOpen(octokit, owner, repo);

  // body に "project: #N" を持つ Issue を抽出
  const targets = [];
  for (const issue of allIssues) {
    const m = (issue.body || '').match(/^project: #(\d+)/m);
    if (!m) continue;
    const parentNum = parseInt(m[1]);
    targets.push({ issue, parentNum });
  }

  if (!targets.length) {
    runOut('移行対象の Issue が見つかりませんでした。');
    return;
  }

  if (dryRun) {
    runOut(`## migrate sub-issue --dry-run（${targets.length}件対象）\n`);
    for (const { issue, parentNum } of targets) {
      runOut(`  #${issue.number} 「${issue.title}」 → 親 #${parentNum}`);
    }
    runOut(`\n--dry-run モード: 実際の登録は行いません。`);
    return;
  }

  let registered = 0, skipped = 0, errors = 0;

  for (const { issue, parentNum } of targets) {
    // 親が 📁 project ラベルを持つか確認
    let parentIssue;
    try {
      parentIssue = await fetchAndParseIssue(octokit, owner, repo, parentNum);
    } catch (e) {
      process.stderr.write(`⚠️ 親 #${parentNum} の取得失敗: ${e.message}\n`);
      errors++;
      continue;
    }
    const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
    if (!isProject) {
      process.stderr.write(`⚠️ #${parentNum} は 📁 project ラベルなし → スキップ (#${issue.number})\n`);
      skipped++;
      continue;
    }

    // addSubIssue は 422（既登録）をスキップして冪等に動作
    const result = await addSubIssue(octokit, owner, repo, parentNum, issue.id);
    if (result === 'skipped') {
      skipped++;
    } else if (result === 'error') {
      errors++;
    } else {
      registered++;
    }
  }

  runOut(`✅ migrate sub-issue 完了: ${registered}件登録 / ${skipped}件スキップ / ${errors}件エラー`);
}

// runMain: コマンドディスパッチャー
async function runMain(args) {
  const octokit = await initOctokit();
  const owner = REPO_OWNER, repo = REPO_NAME;

  let cmd = args[0];
  const rest = args.slice(1);

  // GTDキーワードが先頭 → add として扱う（project も同様）
  if (GTD_LABELS.includes(cmd) || cmd === PROJECT_LABEL) {
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
    case 'show':      return await runShow(octokit, owner, repo, rest);
    case 'view':      return await runView(octokit, owner, repo, rest);
    case 'bulk':      return await runBulk(octokit, owner, repo, rest);
    case 'promote':         return await runPromote(octokit, owner, repo);
    case 'promote-project': return await runPromoteProject(octokit, owner, repo, rest);
    case 'unlink':          return await runUnlink(octokit, owner, repo, rest);
    case 'review-someday':         return await runReviewSomeday(octokit, owner, repo, rest);
    case 'weekly-project-audit':   return await runWeeklyProjectAudit(octokit, owner, repo);
    case 'migrate': {
      // migrate sub-issue [--dry-run]
      const subCmd = rest[0];
      if (subCmd === 'sub-issue') return await runMigrateSubIssue(octokit, owner, repo, rest.slice(1));
      process.stderr.write('Usage: run migrate sub-issue [--dry-run]\n'); process.exit(1);
      break;
    }
    case 'activate': {
      const [num, date] = rest;
      if (!num || !date) {
        process.stderr.write('Usage: /todo activate <#> <日付>\n');
        process.exit(1);
      }
      return await runEdit(octokit, owner, repo, [num, '--activate', date]);
    }
    default: {
      // 第1引数が英字コマンド風で既知コマンドにない → 誤入力として即エラー
      // （GTD 原則: 仕分け済みをInboxに戻さない。暗黙の inbox 吸い込みは ghost issue を生む）
      if (/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(cmd)) {
        process.stderr.write(`エラー: 未知のコマンド「${cmd}」です。\n`);
        process.stderr.write(`  明示的に inbox へ追加したい場合: /todo add ${args.join(' ')}\n`);
        process.stderr.write(`  コマンド一覧: /todo help\n`);
        process.exit(1);
      }
      // 非英字（日本語タイトル等）は従来通り inbox 追加（摩擦ゼロ収集の維持）
      return await runAdd(octokit, owner, repo, args);
    }
  }
}
