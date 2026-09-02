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
const FORBIDDEN_CHARS = ';$`()\"\'' + String.fromCharCode(92) + '|&><{}';
const MAX_OPEN_ISSUES_LIMIT = 200; // GitHub API ページネーション上限。これを超える場合は警告を出力
const MAX_SUB_ISSUES_LIMIT = 500; // sub-issue 一覧のページネーション上限（#1881: 無限ループ防止の安全弁。GitHub の現行上限は親1つにつき100件なので通常は到達しない）
const PRI_COLORS = { p1: 'B60205', p2: 'FBCA04', p3: '0075CA' };
// recur の曜日固定サフィックス（weekly:sat 等）で使う曜日名→Date.getDay()数値の対応表。
// キーの集合が「有効な曜日サフィックス一覧」を兼ねる（Issue #1676）
const RECUR_WEEKDAY_TO_DOW = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 };
// 未知フラグ判定（Issue #1919 で runComment に導入した判定を #1921 で共通化）。
// フラグの字面（`--` + 英字始まり + 英数字/ハイフンのみで構成される1語）のみを対象とする。
// 空白を含むトークン・`--` の直後がハイフン（Markdown水平線 `---` 等）・非ASCII 始まりは
// 「フラグではない自由記述」として通す（#1919 の追補で実測により確定した線引き。
// 一律 `startsWith('--')` にすると `--- 区切り線 ---` のような正当な入力まで弾いてしまう）。
//
// 【この定数をここ（ファイル冒頭の定数ブロック）から動かさないこと】
// 利用者の findUnknownFlag() は関数宣言なので巻き上げられるが、`const` は巻き上げられても
// 初期化されない（TDZ）。本ファイルはメインの switch ディスパッチャを**モジュール評価の
// 途中（parseArgs の定義より前）**で実行するため、診断サブコマンド find-unknown-flag から
// findUnknownFlag() を呼ぶと "Cannot access 'UNKNOWN_FLAG_RE' before initialization" で
// 落ちる。実装時に実測（2026-09-01）。
const UNKNOWN_FLAG_RE = /^--[A-Za-z][A-Za-z0-9-]*$/;

// ─── i18n ───
const LANG = process.env.LANG_ENV || 'ja';

// ─── 実行時間計測（Issue #455） ───
// TODO_TIMING=1 のときのみ有効化する。厳密文字列一致は本ファイル既存の
// FILTER_GROUP_ENV 等の慣習に合わせる（'0'/'true'/空文字はすべて無効）。
const TIMING_ENABLED = process.env.TODO_TIMING === '1';
// 各 Octokit 呼び出しの [開始ns, 終了ns]（BigInt）を記録する。TIMING_ENABLED
// が false のときは initOctokit() が Octokit をラップしないため、常に空のまま。
let timingIntervals = [];

const MESSAGES = {
  ja: {
    // エラー系
    'error.ctx_invalid': 'エラー: コンテキスト名に不正文字が含まれています',
    'error.tag_invalid': 'エラー: タグ名に不正文字が含まれています',
    'error.tag_num_only': 'エラー: タグ名が数字のみです（Issue番号と混同されます）',
    'error.ctx_symbol_only': 'エラー: コンテキスト名に文字・数字が含まれていません（記号のみの名前は使えません）',
    'error.tag_symbol_only': 'エラー: タグ名に文字・数字が含まれていません（記号のみの名前は使えません）',
    'error.option_like_token': 'エラー: "{token}" はオプション指定に見えます。ラベルとして扱えません（@ctx / #tag の形式で指定してください）',
    'label.created': '🆕 新規ラベル {name} を作成しました',
    'error.positive_int': 'エラー: 正の整数が必要です',
    'error.date_format': 'エラー: 不正な日付形式です',
    'error.recur_invalid': 'エラー: recur は daily/weekly/monthly/weekdays、または weekly:<曜日>（mon〜sun）/ monthly:<日>（1〜31）のみ有効です',
    'error.recur_suffix_not_allowed': 'エラー: daily/weekdays にコロン付きサフィックスは指定できません',
    'error.recur_weekday_invalid': 'エラー: weekly の曜日サフィックスは mon/tue/wed/thu/fri/sat/sun（小文字英字3文字）のみ有効です',
    'error.recur_monthday_invalid': 'エラー: monthly の日付サフィックスは 1〜31 の数字のみ有効です（例: monthly:15）',
    'error.color_invalid': 'エラー: カラーは6桁の16進数のみ有効です（例: FBCA04）',
    'error.priority_invalid': 'エラー: --priority は p1/p2/p3 のみ有効です',
    'error.name_empty': 'エラー: 名前が空です',
    'error.name_invalid': 'エラー: 名前に不正文字が含まれています（; $ ` ( ) " \' \\\\ | & > < { } 不可）',
    'error.time_format': 'エラー: 時間は 30m / 1h / 1h30m 形式で指定してください',
    'error.file_corrupt': 'エラー: ファイルが破損しています',
    'error.desc_required': 'エラー: 説明テキストが必要です',
    'error.view_ctx_multiple': 'エラー: view save では @ctx は1つのみ指定できます',
    'error.resume_condition_newline': 'エラー: resume_condition に改行を含めることはできません（1行のみ）',
    'error.title_control_char': 'エラー: タイトルに制御文字（改行等）を含めることはできません',
    // 警告
    'warn.month_rollover': '⚠️ 注意: {day}日は翌月に存在しないため、{date} に繰り上がりました',
    'warn.month_day_clamped': '⚠️ 注意: {month}月に{day}日は存在しないため、{date} にクランプされました',
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
    'list.excluded_someday_projects': '（休止中（someday）のプロジェクト {n}件を除外）',
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
    'help.section_project': '### プロジェクト管理',
    'help.section_other': '### その他',
    'help.section_migrated': '### 統合済みコマンド',
    'help.add': '/todo [GTD] <タイトル> [--body "本文"] [--body-file <path>]  タスク追加（GTD省略時: inbox。未知の -- フラグはエラー。タイトルに含めるならクォートする）',
    'help.add_explicit': '/todo add <タイトル>             英字で始まるタイトルは add の明示が必須（例: /todo add My Task。add なしだとコマンド名と混同されエラー）',
    'help.list': '/todo list [フィルタ] [--json]   タスク一覧',
    'help.done': '/todo done <#> [--actual 時間] [--note "テキスト"]  タスク完了',
    'help.move': '/todo move <#> <GTD> [--note "テキスト"]  カテゴリ変更',
    'help.edit': '/todo edit <#> [--due/desc/...] 複数フィールド一括編集',
    'help.rename': '/todo rename <#> <新タイトル>    タイトル変更',
    'help.due': '/todo due <#> <日付|clear>       期日設定 / clear で削除',
    'help.desc': '/todo desc <#> <テキスト>       説明に追記（上書きは edit --desc）',
    'help.recur': '/todo recur <#> <パターン|clear>  繰り返し設定（daily/weekly/monthly/weekdays。weekly:<曜日> 例: weekly:sat、monthly:<日> 例: monthly:15 の固定サフィックスも可）/ clear で解除',
    'help.priority': '/todo priority <#> <p1-p3>      優先度設定',
    'help.search': '/todo search <キーワード> [--json] キーワード検索',
    'help.tag': '/todo tag <#> @ctx/#tag ...      コンテキスト・タグ追加',
    'help.untag': '/todo untag <#> @ctx/#tag ...    コンテキスト・タグ削除',
    'help.label': '/todo label list/add/delete     ラベル管理',
    'help.bulk': '/todo bulk <done|move|tag|untag|priority> <#>...',
    'help.today': '/todo today                     今日のタスク（期限超過＋今日期限）',
    'help.dashboard': '/todo dashboard                 ダッシュボード',
    'help.review_someday': '/todo review-someday <#>        somedayタスクの見直し日(reviewed_at)を更新',
    'help.stats': '/todo stats                     統計情報',
    'help.report': '/todo report <weekly|monthly|Nd> レポート出力',
    'help.template': '/todo template <list|show|save|use|delete>',
    'help.view': '/todo view <save|use|list|delete>',
    'help.archive': '/todo archive [list|search|reopen] 完了済みタスク',
    'help.link': '/todo link <#> <project#>       プロジェクト紐付け',
    'help.promote_project': '/todo promote-project <#> [--outcome "タイトル"]  既存Issueをプロジェクトに昇格',
    'help.unlink': '/todo unlink <#> [--force]      子Issueのプロジェクト紐付けを解除',
    'help.migrate': '/todo migrate sub-issue [--dry-run]  project紐付けをGitHub sub-issueへ一括登録',
    'help.weekly_project_audit': '/todo weekly-project-audit      全プロジェクトを棚卸し（next欠落・停滞を検出）',
    'help.show': '/todo show <#> [--json]          個別タスク詳細表示',
    'help.schema': '/todo schema                    --json 出力のフィールド定義を表示',
    'help.comment': '/todo comment <#> <テキスト> [--body "本文"] [--body-file <path>]  Issueにコメントを追加',
    'help.api': '/todo api <subcommand> [args...] JSON API（list-comments 等。詳細は todo.md 参照）',
    'help.help': '/todo help                      このヘルプを表示',
    'help.review_migrated': '💡 review は /todo のサブコマンドではなくなりました。使い方は todo.md の「対話コマンド」節を参照してください。',
    'help.daily_migrated': '💡 daily-review は /todo のサブコマンドではなくなりました。使い方は todo.md の「対話コマンド」節を参照してください。',
    'help.weekly_migrated': '💡 weekly-review は /todo のサブコマンドではなくなりました。使い方は todo.md の「対話コマンド」節を参照してください。',
    // today
    'today.header': '# 🎯 今日のタスク — {date}',
    'today.overdue': '## ⚠️ 期限超過（{n}）',
    'today.due_today': '## 🎯 今日が期限（{n}）',
    'today.routine': '## 🔁 今日のルーティン（{n}）',
    'today.routine_overdue': '## 🔁 ルーティン未実施（{n}）',
    'today.routine_stale': '## 🕰 要確認（推定サイクル遅延・{n}）',
    'today.cycles_suffix': '（推定{n}周遅延）',
    'today.stale_no_recur': '（30日以上更新なし）',
    'today.no_tasks': '今日のタスクはありません。期限超過もなし。',
    'today.summary': '📊 合計: {total}',
    'today.est': '⏱見積: {time}',
    'today.done': '✅ 今日 {n}完了',
    // dashboard
    'dash.routine': '## 🔁 今日のルーティン（{n}）',
    // help
    'help.routine_hint': '🔁 routine ラベルは繰り返しタスク専用です。--recur オプションと組み合わせて使用してください。',
    'help.desc_note': '※ desc/edit のテキストに due:/activate: 等を含めると body で重複表示されます',
    // promote / activate
    'error.before_needs_due': 'エラー: --before を使うには --due が必要です',
    'error.before_format': 'エラー: --before は 14d / 2w 形式で指定してください（例: 14d, 2w）',
    'error.activate_after_due': '⚠️ 警告: activate日（{activate}）が due日（{due}）より後です',
    'promote.header': '## チクラーファイル昇格',
    'promote.promoted': '✅ #{num} 「{title}」を next に昇格しました（activate: {activate}）',
    'promote.no_targets': '昇格対象なし（activate日到来タスク: 0件）',
    'promote.summary': '✅ {n}件を next に昇格しました',
    'promote.pending_review': '⏸ #{num} 「{title}」activate日到来ですが再開条件の確認が必要です: {condition}',
    'promote.pending_summary': '⏸ {n}件が再開条件の確認待ちです（次回の週次レビューで確認してください）',
    'help.promote': '/todo promote                   activate日到来タスクをNEXTに昇格',
    'help.activate_cmd': '/todo activate <#> <日付>       edit <#> --activate <日付> の簡略記法',
    'help.activate': '  --activate <日付>             指定日にNEXTへ自動昇格（例: 2026-05-01）',
    'help.before': '  --before <期間>               dueのN日前にNEXTへ自動昇格（例: 14d, 2w）',
    'help.depends_on': '  --depends-on <#N>            指定タスク完了時にNEXTへ自動昇格',
    'help.resume_condition': '  --resume-condition <テキスト>       再開条件を記述（promoteが自動昇格せず確認を促す）',
    'promote.promoted_depends': '✅ #{num} 「{title}」を next に昇格しました（#{dep} 完了トリガー）',
    'done.promote_hint_header': '💡 プロジェクト #{proj}「{title}」に昇格候補があります:',
    'done.promote_hint_item':   '  {i}. #{num}「{title}」({gtd})',
    'done.promote_hint_footer': '番号を入力するか /todo move <#> next で昇格できます。',
    // eisenhower
    'eisenhower.header': '# 🧭 アイゼンハワーマトリクス — {date}',
    'eisenhower.q1': '## 🔴 Q1 今すぐやる（緊急×重要）',
    'eisenhower.q2': '## 🟡 Q2 計画する（重要だが緊急でない）',
    'eisenhower.q3': '## 🔵 Q3 緊急タスク（重要度低）',
    'eisenhower.q4': '## ⬛ Q4 その他',
    'eisenhower.summary': '📊 Q1: {q1} / Q2: {q2} / Q3: {q3} / Q4: {q4}  合計 next: {total}',
    'eisenhower.unset': '## ⚠ 優先度未設定（{count}件）',
    'help.eisenhower': '/todo eisenhower                アイゼンハワーマトリクス（重要×緊急 4象限）',
    // Web環境サポート（Issue #1695）
    'error.repo_not_configured': 'エラー: TODO_REPO_OWNER / TODO_REPO_NAME が未設定です。\n  .env に以下を設定してください（例）:\n    TODO_REPO_OWNER=your-github-username\n    TODO_REPO_NAME=your-task-repo\n  .env が使えない環境（Webセッション等）では、環境変数として直接設定してください。',
    'error.gh_auth_rejected': 'エラー: GitHub API 認証が拒否されました（401）。\n  この環境の GH_TOKEN は REST API の直接呼び出しに使えない可能性があります\n  （例: GitHubアクセスが MCP 経由のみに制限されているWebセッション等）。\n  gh auth token で取得したトークンを再設定するか、下記の代替手段を検討してください。',
    'error.mcp_fallback_guidance': '  この環境で /todo が使えない場合、GitHub MCPツール（利用可能な場合）で\n  以下の仕様に厳密に合わせて手動でIssueを作成できます:\n    - ラベル: GTDカテゴリ（🎯 next / 🔁 routine / 📥 inbox / ⏳ waiting / 🌈 someday / 📁 project / 📎 reference のいずれか1つ）+ 優先度（p1/p2/p3）\n    - body: due: / activate: / resume_condition: / before: / depends_on: / recur: / project: / estimate: / actual: / reviewed_at: の順（該当するもののみ）+ 空行 + 本文\n  この手段は「GitHub Issue操作は /todo 経由」原則の例外的フォールバックです。\n  実行前にユーザーへの事前承認を得てください。',
    // i18n拡張（Issue #1653: CLI出力の日英対応漏れ解消）
    'warn.recur_catchup_limit': '⚠️ リカレンス周期スキップの反復上限({limit})に達しました。due: {date}',
    'group.overdue': '── ⚠️ 期限超過 ──',
    'group.today': '── 📅 今日（{date}）──',
    'group.tomorrow': '── 📅 明日（{date}）──',
    'group.this_week': '── 📅 今週（〜{date}）──',
    'group.later': '── 📅 来週以降 ──',
    'group.no_due': '── 📅 期限なし ──',
    'project.badge_no_next': '⚠️ next欠落: {n}',
    'project.badge_stale': '停滞30日以上: {n}',
    'project.header_count': '## 📁 Projects（{n}{badges}）',
    'project.child_next': 'next:{n}',
    'project.child_waiting': 'waiting:{n}',
    'project.last_reviewed': '  （最終レビュー: {days}日前）',
    'help.activate_section_header': '### activate / before / resume_condition オプション',
    'error.comment_too_long': 'エラー: コメント本文が最大文字数（65536字）を超えています（現在: {n}字）',
    'error.comment_empty': 'エラー: コメント本文が空です',
    'error.move_to_project_forbidden': 'エラー: project への移動はできません。\nプロジェクト昇格には /todo promote-project <N> を使ってください。',
    'error.gtd_label_required': 'エラー: GTDラベルは {labels} のいずれかです。',
    'error.gtd_label_missing': 'エラー: GTDラベルを指定してください。',
    'error.title_empty': 'エラー: タイトルが空です。',
    'error.unknown_flag': 'エラー: 不明なフラグです: {flag}',
    'error.unknown_flag_hint': 'ヒント: この語をタイトルに含めたい場合は、タイトル全体を1つの引数としてクォートしてください（例: /todo add next "--dry-run を追加する"）。タイトルがこの語1語だけの場合は、前後に語を足してください（例: 「--dry-run」の扱いを決める）。',
    'hint.project_outcome': '💡 ヒント: プロジェクト名は「〜している状態」「〜が完了している」のような\n   成果物（outcome）の形で書くと Next Action を導出しやすくなります。',
    'label.desc_context': 'コンテキスト',
    'label.desc_tag': 'タグ',
    'label.desc_priority': '優先度',
    'error.body_file_not_found': 'エラー: --body-file のパスが見つかりません: {path}',
    'error.body_file_read_failed': 'エラー: --body-file の読み込みに失敗しました: {msg}',
    'add.created_header': '✅ #{num} を作成しました。',
    'add.title_line': '  タイトル: {title}',
    'add.labels_line': '  ラベル: {labels}',
    'add.due_line': '  期日: {due}',
    'add.activate_line': '  昇格予定: {activate}',
    'add.url_line': '  URL: {url}',
    'warn.project_fetch_failed': '⚠️ プロジェクト #{num} の取得に失敗しました: {msg}',
    'error.not_a_project': 'エラー: #{num} はプロジェクトではありません。先に /todo project <タイトル> で作成してください',
    'warn.not_a_project': '⚠️ #{num} はプロジェクトではありません。先に /todo project <タイトル> で作成してください',
    'warn.parent_fetch_failed': '⚠️ 親 #{num} の取得失敗: {msg}',
    'warn.parent_no_project_label': '⚠️ #{parent} は 📁 project ラベルなし → スキップ (#{num})',
    'error.project_fetch_failed': 'エラー: プロジェクト #{num} の取得に失敗しました: {msg}',
    'done.recur_created': '繰り返しタスク #{num} を {date} で作成しました。',
    'done.recur_activate_note': '（activate: {activate}）',
    'done.recur_skip_note': '⏭ 期限超過のため過去の周期をスキップしました（due基準: {base} → 再作成: {date}）',
    'done.completed': '✅ #{num} を完了しました。',
    'comment.added': '💬 #{num} にコメントを追加しました。',
    'move.done': '✅ #{num} を {label} に移動しました。',
    'edit.clear': 'クリア',
    'edit.field_activate_recalc': 'activate 再計算',
    'edit.updated': '✅ #{num} を更新しました: {changed}',
    'due.cleared': '✅ #{num} の期日をクリアしました。',
    'due.set': '✅ #{num} の期日を {due} に設定しました。',
    'desc.appended': '✅ #{num} の説明を追記しました。',
    'recur.set': '✅ #{num} の繰り返しを {recur} に設定しました。',
    'recur.cleared': '✅ #{num} の繰り返しをクリアしました。',
    'link.linked': '✅ #{num} をプロジェクト #{proj} に紐付けました。',
    'rename.done': '✅ #{num} のタイトルを「{title}」に変更しました。',
    'priority.cleared': '✅ #{num} の優先度をクリアしました。',
    'priority.set': '✅ #{num} の優先度を {level} に設定しました。',
    'label.renamed': '✅ {old} を {new} にリネームしました。{n}のIssueを更新しました。',
    'tag.added': '✅ #{num} に {labels} を追加しました。',
    'tag.removed': '✅ #{num} から {labels} を削除しました。',
    'label.list_empty': '（コンテキストラベルなし）',
    'label.created_named': '✅ ラベル {name} を作成しました。',
    'label.deleted_named': '✅ ラベル {name} を削除しました。',
    'search.no_results': '検索結果: 0件（キーワード: {keyword}）',
    'search.results_count': '検索結果: {n}件',
    'archive.no_completed': '（完了タスクなし）',
    'archive.count': '{n}件',
    'archive.reopened': '✅ #{num} を inbox に戻しました。',
    'template.issue_created': '✅ テンプレート「{name}」から Issue #{num} を作成しました。',
    'schema.description': '--json フラグ付きコマンドの出力スキーマ',
    'schema.cmd.show': '単一オブジェクト',
    'schema.cmd.list': 'オブジェクトの配列',
    'schema.cmd.search': 'オブジェクトの配列',
    'schema.field.number': 'Issue番号',
    'schema.field.title': 'タイトル',
    'schema.field.state': 'Issue の状態: open / closed（show のみ）',
    'schema.field.closedAt': 'クローズ日時 (ISO8601)。open の場合は null（show のみ）',
    'schema.field.gtd': 'GTDカテゴリ: next / inbox / waiting / someday / routine / reference / project',
    'schema.field.priority': '優先度: p1 / p2 / p3',
    'schema.field.due': '期日 (YYYY-MM-DD)',
    'schema.field.estimate': '見積もり（分単位の文字列）',
    'schema.field.estimateFormatted': '見積もり表示形式 (例: 2h, 30m, 1h30m)',
    'schema.field.context': 'コンテキストラベル (@home 等、@claude は除く)',
    'schema.field.claude': '@claude ラベルの有無',
    'schema.field.tags': 'その他タグ (#blog 等)',
    'schema.field.recur': '繰り返し設定: daily / weekly / monthly / weekdays（weekly:<曜日> 例: weekly:sat、monthly:<日> 例: monthly:15 の固定サフィックスも可）',
    'schema.field.project': '親プロジェクトの Issue 番号',
    'schema.field.activate': 'NEXT 自動昇格日 (YYYY-MM-DD)',
    'schema.field.dependsOn': '依存先の Issue 番号',
    'schema.field.resumeCondition': '再開条件（フリーテキスト）。promoteが自動昇格をスキップし確認を促す条件',
    'schema.field.desc': '説明テキスト（body のメタフィールド除いた部分）',
    'schema.field.labels': '全ラベル（GTD絵文字なし正規化済み）',
    'error.issue_not_found': 'エラー: Issue #{num} が見つかりません。',
    'error.issue_fetch_failed': 'エラー: Issue の取得に失敗しました（{msg}）',
    'show.unclassified': '（未分類）',
    'show.estimate_invalid': '{raw}（形式不正）',
    'show.yes': 'あり',
    'show.no': 'なし',
    'show.status_done': '- 状態: ✅ 完了{suffix}',
    'show.closed_date_suffix': '（{date}）',
    'show.line_gtd': '- GTDカテゴリ: {value}',
    'show.line_priority': '- 優先度: {value}',
    'show.line_due': '- 期日: {value}',
    'show.line_estimate': '- 見積もり: {value}',
    'show.line_context': '- コンテキスト: {value}',
    'show.line_claude': '- @claude: {value}',
    'show.line_recur': '- 繰り返し: {value}',
    'show.line_project': '- プロジェクト: #{value}',
    'show.line_other_labels': '- その他ラベル: {value}',
    'show.desc_header': '### 説明',
    'view.viewing': '## 👁 ビュー: {name} [{parts}]',
    'error.no_issue_numbers': 'エラー: Issue番号が指定されていません。',
    'bulk.item_error': '  #{num} エラー: {msg}',
    'bulk.done_count': '✅ {n}件完了',
    'bulk.done_recur_suffix': '（うち繰り返し再作成: {n}件）',
    'bulk.err_suffix': '（エラー: {n}件）',
    'bulk.moved_count': '✅ {n}件を {label} に移動',
    'bulk.tag_added_count': '✅ {n}件に {labels} を追加',
    'bulk.tag_removed_count': '✅ {n}件から {labels} を削除',
    'bulk.priority_set_count': '✅ {n}件の優先度を {level} に設定',
    'error.not_someday': 'エラー: #{num} はsomedayタスクではありません。',
    'someday.reviewed': '✅ #{num} の reviewed_at を {date} に更新しました。',
    'error.already_project': 'エラー: #{num} は既にプロジェクトです。',
    'project.promoted': '✅ #{num} 「{title}」をプロジェクトに昇格しました。',
    'project.promoted_hint': '💡 最初の Next Action を追加するには: /todo next <タイトル> --project {num}',
    'error.no_project_link': 'エラー: #{num} にプロジェクト紐付けがありません。',
    'link.unlinked': '✅ #{num} のプロジェクト紐付けを解除しました。',
    'error.unlink_mismatch': 'エラー: #{num} の body は project: #{parent} を指していますが、GitHub 上その親には sub-issue として登録されていません。body のみ解除する場合は /todo unlink {num} --force を実行してください。',
    'error.unlink_failed': 'エラー: #{num} の sub-issue 解除に失敗したため、body は更新していません。',
    'error.unlink_list_failed': 'エラー: #{num} の sub-issue 一覧取得（親 #{parent}）に失敗したため、body は更新していません。時間をおいて再実行してください。',
    'link.unlinked_mismatch': '⚠️ #{num} のプロジェクト紐付け（body）のみ解除しました（GitHub 上の sub-issue 関係は元々ありませんでした）。',
    'audit.no_projects': '## 📁 プロジェクト棚卸し（0件）\n\nプロジェクトがありません。',
    'audit.header': '## 📁 プロジェクト棚卸し（全{n}件）',
    'audit.paused_excluded': '（休止中（someday）のプロジェクト {n}件を除外）',
    'audit.verdict_stale_no_next': '⚠️ nextなし / 30日更新なし（停滞）',
    'audit.suggestion': '  → 対応候補: /todo next <タイトル> --project {n} / /todo move {n} someday / /todo close {n}',
    'audit.verdict_no_next': '⚠️ next欠落',
    'audit.verdict_ok': '✅ 問題なし',
    'audit.days_ago': '{n}日前',
    'audit.unknown': '不明',
    'audit.child_summary': '  子タスク: next={next}件 waiting={waiting}件 someday={someday}件',
    'audit.recent_update': '  直近更新: {value}',
    'audit.verdict_line': '  判定: {value}',
    'warn.reviewed_at_write_failed': '⚠️ #{num} の reviewed_at 書き込み失敗: {msg}',
    'audit.completed_summary': '---\n棚卸し完了: {total}件確認 / reviewed_at 記録: {reviewed}件',
    'migrate.no_targets': '移行対象の Issue が見つかりませんでした。',
    'migrate.dry_run_header': '## migrate sub-issue --dry-run（{n}件対象）',
    'migrate.dry_run_item': '  #{num} 「{title}」 → 親 #{parent}',
    'migrate.dry_run_footer': '\n--dry-run モード: 実際の登録は行いません。',
    'migrate.summary': '✅ migrate sub-issue 完了: {registered}件登録 / {skipped}件スキップ / {errors}件エラー',
    'error.reserved_command_word': 'エラー: 「{word}」はコマンド名です。',
    'error.reserved_command_hint1': '  （コマンドと混同を避けるため、一覧表示の意図なら /todo list {cmd} を使ってください）',
    'error.reserved_command_hint2': '  タスク追加の意図で明示的に追加したい場合: /todo add {cmd} {word}',
    'error.command_list_hint': '  コマンド一覧: /todo help',
    'error.unknown_command': 'エラー: 未知のコマンド「{cmd}」です。',
    'error.unknown_command_hint1': '  （コマンドと混同を避けるため、英字タイトルは /todo add <タイトル> で明示的に追加してください）',
    'error.unknown_command_hint2': '  明示的に inbox へ追加したい場合: /todo add {args}',
    'error.close_failed_after_recur': 'エラー: #{num} のクローズに失敗しました（新しい繰り返しIssue #{newNum} は作成済みです）: {msg}\n  同じタスクのオープンなIssueが2件（元 #{num} と新規 #{newNum}）残っている可能性があります。手動で確認してください。',
    'warn.sub_issue_skip': '⚠️ sub-issue 登録スキップ: #{parent} に既に登録済み（冪等）',
    'warn.sub_issue_register_failed': '⚠️ sub-issue 登録失敗（Issue は作成済み）: {msg}',
    'warn.sub_issue_register_failed_422': '⚠️ sub-issue 登録失敗（#{parent} には未登録と判定）: {msg}',
    'warn.sub_issue_list_failed': '⚠️ sub-issue 一覧取得失敗: {msg}',
    'warn.sub_issue_unlink_failed': '⚠️ sub-issue 解除失敗: {msg}',
    'list.project_children_header': '## 📁 プロジェクト #{parent} の子タスク（{n}件）',
    'list.no_children': '  （子タスクなし）',
    'warn.open_issue_limit': '⚠️ オープン Issue が {limit} 件の上限に達しました。古いタスクのクローズを推奨します。',
    'warn.sub_issue_list_limit': '⚠️ #{parent} の sub-issue が {limit} 件の上限に達しました。一部が一覧から欠落している可能性があります。',
  },
  en: {
    'error.ctx_invalid': 'Error: Context name contains invalid characters',
    'error.tag_invalid': 'Error: Tag name contains invalid characters',
    'error.tag_num_only': 'Error: Tag name must not be digits only (conflicts with Issue number)',
    'error.ctx_symbol_only': 'Error: Context name must contain at least one letter or digit (symbol-only names are not allowed)',
    'error.tag_symbol_only': 'Error: Tag name must contain at least one letter or digit (symbol-only names are not allowed)',
    'error.option_like_token': 'Error: "{token}" looks like an option, not a label (use @ctx / #tag format)',
    'label.created': '🆕 Created new label {name}',
    'error.positive_int': 'Error: A positive integer is required',
    'error.date_format': 'Error: Invalid date format',
    'error.recur_invalid': 'Error: recur must be daily/weekly/monthly/weekdays, or weekly:<day> (mon-sun) / monthly:<day> (1-31)',
    'error.recur_suffix_not_allowed': 'Error: daily/weekdays cannot have a colon suffix',
    'error.recur_weekday_invalid': 'Error: weekly day suffix must be one of mon/tue/wed/thu/fri/sat/sun (lowercase 3-letter)',
    'error.recur_monthday_invalid': 'Error: monthly day suffix must be a number between 1 and 31 (e.g. monthly:15)',
    'error.color_invalid': 'Error: Color must be a 6-digit hex code (e.g. FBCA04)',
    'error.priority_invalid': 'Error: --priority must be p1/p2/p3',
    'error.name_empty': 'Error: Name is empty',
    'error.name_invalid': 'Error: Name contains invalid characters (; $ ` ( ) " \' \\\\ | & > < { } not allowed)',
    'error.time_format': 'Error: Time must be in 30m / 1h / 1h30m format',
    'error.file_corrupt': 'Error: File is corrupted',
    'error.desc_required': 'Error: Description text is required',
    'error.view_ctx_multiple': 'Error: view save allows only one @ctx',
    'error.resume_condition_newline': 'Error: resume_condition must not contain line breaks (single line only)',
    'error.title_control_char': 'Error: Title must not contain control characters (e.g. line breaks)',
    'warn.month_rollover': '⚠️ Note: Day {day} does not exist in the next month, rolled to {date}',
    'warn.month_day_clamped': '⚠️ Note: Day {day} does not exist in month {month}, clamped to {date}',
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
    'list.excluded_someday_projects': '(Excluded {n} paused (someday) project(s))',
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
    'help.section_project': '### Project Management',
    'help.section_other': '### Other',
    'help.section_migrated': '### Merged Commands',
    'help.add': '/todo [GTD] <title> [--body "text"] [--body-file <path>]  Add task (default: inbox; unknown -- flags error out, quote the title to keep them)',
    'help.add_explicit': '/todo add <title>                Required for titles starting with a letter (e.g., /todo add My Task; without add it is misread as a command name and errors)',
    'help.list': '/todo list [filter] [--json]     List tasks',
    'help.done': '/todo done <#> [--actual time] [--note "text"]  Mark done',
    'help.move': '/todo move <#> <GTD> [--note "text"]  Change category',
    'help.edit': '/todo edit <#> [--due/desc/...] Edit multiple fields',
    'help.rename': '/todo rename <#> <new-title>    Rename',
    'help.due': '/todo due <#> <date|clear>       Set due date / clear to remove',
    'help.desc': '/todo desc <#> <text>           Append to description (use edit --desc to overwrite)',
    'help.recur': '/todo recur <#> <pattern|clear>  Set recurrence (daily/weekly/monthly/weekdays. Fixed-day suffixes also work: weekly:<day> e.g. weekly:sat, monthly:<day> e.g. monthly:15) / clear to remove',
    'help.priority': '/todo priority <#> <p1-p3>      Set priority',
    'help.search': '/todo search <keyword> [--json]  Search tasks',
    'help.tag': '/todo tag <#> @ctx/#tag ...      Add context/tag',
    'help.untag': '/todo untag <#> @ctx/#tag ...    Remove context/tag',
    'help.label': '/todo label list/add/delete     Manage labels',
    'help.bulk': '/todo bulk <done|move|tag|untag|priority> <#>...',
    'help.today': '/todo today                     Today\'s tasks (overdue + due today)',
    'help.dashboard': '/todo dashboard                 Dashboard',
    'help.review_someday': '/todo review-someday <#>        Update review date (reviewed_at) for a someday task',
    'help.stats': '/todo stats                     Statistics',
    'help.report': '/todo report <weekly|monthly|Nd> Report',
    'help.template': '/todo template <list|show|save|use|delete>',
    'help.view': '/todo view <save|use|list|delete>',
    'help.archive': '/todo archive [list|search|reopen] Closed tasks',
    'help.link': '/todo link <#> <project#>       Link to project',
    'help.promote_project': '/todo promote-project <#> [--outcome "title"]  Promote an existing issue to a project',
    'help.unlink': '/todo unlink <#> [--force]      Unlink a child issue from its project',
    'help.migrate': '/todo migrate sub-issue [--dry-run]  Bulk-register project links as GitHub sub-issues',
    'help.weekly_project_audit': '/todo weekly-project-audit      Audit all projects (detect missing next / stale)',
    'help.show': '/todo show <#> [--json]          Show task detail',
    'help.schema': '/todo schema                    Show JSON field schema for --json output',
    'help.comment': '/todo comment <#> <text> [--body "text"] [--body-file <path>]  Add a comment to an issue',
    'help.api': '/todo api <subcommand> [args...] JSON API (list-comments, etc. See todo.md for details)',
    'help.help': '/todo help                      Show this help',
    'help.review_migrated': '💡 review is no longer a /todo subcommand. See the "Interactive Commands" section in todo.md for how to use it.',
    'help.daily_migrated': '💡 daily-review is no longer a /todo subcommand. See the "Interactive Commands" section in todo.md for how to use it.',
    'help.weekly_migrated': '💡 weekly-review is no longer a /todo subcommand. See the "Interactive Commands" section in todo.md for how to use it.',
    // today
    'today.header': '# 🎯 Today\'s Tasks — {date}',
    'today.overdue': '## ⚠️ Overdue ({n})',
    'today.due_today': '## 🎯 Due Today ({n})',
    'today.routine': '## 🔁 Today\'s Routines ({n})',
    'today.routine_overdue': '## 🔁 Routines Pending ({n})',
    'today.routine_stale': '## 🕰 Needs Review (Est. Cycle Delay, {n})',
    'today.cycles_suffix': '(est. {n} cycles overdue)',
    'today.stale_no_recur': '(no update in 30+ days)',
    'today.no_tasks': 'No tasks for today. No overdue items either.',
    'today.summary': '📊 Total: {total}',
    'today.est': '⏱Estimate: {time}',
    'today.done': '✅ {n} completed today',
    // dashboard
    'dash.routine': '## 🔁 Today\'s Routines ({n})',
    // help
    'help.routine_hint': '🔁 routine label is for recurring tasks. Recommended to use with --recur option.',
    'help.desc_note': 'Note: including due:/activate: in desc/edit text causes duplicate display in body',
    // promote / activate
    'error.before_needs_due': 'Error: --before requires --due',
    'error.before_format': 'Error: --before must be in 14d / 2w format (e.g. 14d, 2w)',
    'error.activate_after_due': '⚠️ Warning: activate date ({activate}) is after due date ({due})',
    'promote.header': '## Tickler File Promotion',
    'promote.promoted': '✅ #{num} "{title}" promoted to next (activate: {activate})',
    'promote.no_targets': 'No targets to promote (activate date arrived: 0)',
    'promote.summary': '✅ {n} tasks promoted to next',
    'promote.pending_review': '⏸ #{num} "{title}" activate date arrived but resume condition needs review: {condition}',
    'promote.pending_summary': '⏸ {n} task(s) awaiting resume condition review (check at your next weekly review)',
    'help.promote': '/todo promote                   Promote tasks whose activate date has arrived',
    'help.activate_cmd': '/todo activate <#> <date>       Shorthand for edit <#> --activate <date>',
    'help.activate': '  --activate <date>             Auto-promote to NEXT on specified date',
    'help.before': '  --before <duration>           Auto-promote N days before due (e.g. 14d, 2w)',
    'help.depends_on': '  --depends-on <#N>            Auto-promote to NEXT when specified task is completed',
    'help.resume_condition': '  --resume-condition <text>          Describe resume condition (promote will skip and request review)',
    'promote.promoted_depends': '✅ #{num} "{title}" promoted to next (#{dep} completion trigger)',
    'done.promote_hint_header': '💡 Project #{proj} "{title}" has promotion candidates:',
    'done.promote_hint_item':   '  {i}. #{num} "{title}" ({gtd})',
    'done.promote_hint_footer': 'Enter a number or use /todo move <#> next to promote.',
    // eisenhower
    'eisenhower.header': '# 🧭 Eisenhower Matrix — {date}',
    'eisenhower.q1': '## 🔴 Q1 Do Now (Urgent × Important)',
    'eisenhower.q2': '## 🟡 Q2 Schedule (Important, Not Urgent)',
    'eisenhower.q3': '## 🔵 Q3 Urgent (Low Importance)',
    'eisenhower.q4': '## ⬛ Q4 Others',
    'eisenhower.summary': '📊 Q1: {q1} / Q2: {q2} / Q3: {q3} / Q4: {q4}  Total next: {total}',
    'eisenhower.unset': '## ⚠ Priority Not Set ({count})',
    'help.eisenhower': '/todo eisenhower                Eisenhower Matrix (4 quadrants: urgent × important)',
    // Web environment support (Issue #1695)
    'error.repo_not_configured': 'Error: TODO_REPO_OWNER / TODO_REPO_NAME is not set.\n  Set the following in .env (example):\n    TODO_REPO_OWNER=your-github-username\n    TODO_REPO_NAME=your-task-repo\n  In environments where .env is unavailable (e.g. Web sessions), set them directly as environment variables.',
    'error.gh_auth_rejected': 'Error: GitHub API authentication was rejected (401).\n  The GH_TOKEN in this environment may not be usable for direct REST API calls\n  (e.g. a Web session where GitHub access is restricted to MCP only).\n  Re-set the token obtained via `gh auth token`, or consider the fallback below.',
    'error.mcp_fallback_guidance': '  If /todo cannot be used in this environment, you can manually create an Issue\n  with a GitHub MCP tool (if available), strictly following this spec:\n    - Labels: GTD category (one of 🎯 next / 🔁 routine / 📥 inbox / ⏳ waiting / 🌈 someday / 📁 project / 📎 reference) + priority (p1/p2/p3)\n    - Body order: due: / activate: / resume_condition: / before: / depends_on: / recur: / project: / estimate: / actual: / reviewed_at: (only applicable fields) + blank line + description\n  This is an exceptional fallback to the "GitHub Issue operations go through /todo" principle.\n  Get explicit user approval before doing this.',
    // i18n extension (Issue #1653: fix missing EN/JA parity in CLI output)
    'warn.recur_catchup_limit': '⚠️ Reached the recurrence cycle skip iteration limit ({limit}). due: {date}',
    'group.overdue': '── ⚠️ Overdue ──',
    'group.today': '── 📅 Today ({date}) ──',
    'group.tomorrow': '── 📅 Tomorrow ({date}) ──',
    'group.this_week': '── 📅 This Week (~{date}) ──',
    'group.later': '── 📅 Later ──',
    'group.no_due': '── 📅 No Due Date ──',
    'project.badge_no_next': '⚠️ Missing next: {n}',
    'project.badge_stale': 'Stale 30+ days: {n}',
    'project.header_count': '## 📁 Projects ({n}{badges})',
    'project.child_next': 'next:{n}',
    'project.child_waiting': 'waiting:{n}',
    'project.last_reviewed': '  (Last reviewed: {days} days ago)',
    'help.activate_section_header': '### activate / before / resume_condition options',
    'error.comment_too_long': 'Error: Comment body exceeds the maximum length (65536 characters) (current: {n} characters)',
    'error.comment_empty': 'Error: Comment body is empty',
    'error.move_to_project_forbidden': 'Error: Cannot move to project.\nUse /todo promote-project <N> to promote to a project.',
    'error.gtd_label_required': 'Error: GTD label must be one of {labels}.',
    'error.gtd_label_missing': 'Error: Please specify a GTD label.',
    'error.title_empty': 'Error: Title is empty.',
    'error.unknown_flag': 'Error: unknown flag: {flag}',
    'error.unknown_flag_hint': 'Hint: to keep this word in the title, quote the whole title as a single argument (e.g. /todo add next "add --dry-run"). If the title is only this word, add words around it (e.g. "decide how to handle --dry-run").',
    'hint.project_outcome': '💡 Hint: Project titles are easier to derive Next Actions from when written\n   as an outcome (e.g. "X is done", "X has been completed").',
    'label.desc_context': 'Context',
    'label.desc_tag': 'Tag',
    'label.desc_priority': 'Priority',
    'error.body_file_not_found': 'Error: --body-file path not found: {path}',
    'error.body_file_read_failed': 'Error: Failed to read --body-file: {msg}',
    'add.created_header': '✅ #{num} created.',
    'add.title_line': '  Title: {title}',
    'add.labels_line': '  Labels: {labels}',
    'add.due_line': '  Due: {due}',
    'add.activate_line': '  Activate: {activate}',
    'add.url_line': '  URL: {url}',
    'warn.project_fetch_failed': '⚠️ Failed to fetch project #{num}: {msg}',
    'error.not_a_project': 'Error: #{num} is not a project. Create it first with /todo project <title>',
    'warn.not_a_project': '⚠️ #{num} is not a project. Create it first with /todo project <title>',
    'warn.parent_fetch_failed': '⚠️ Failed to fetch parent #{num}: {msg}',
    'warn.parent_no_project_label': '⚠️ #{parent} does not have the 📁 project label → skipped (#{num})',
    'error.project_fetch_failed': 'Error: Failed to fetch project #{num}: {msg}',
    'done.recur_created': 'Recurring task #{num} created for {date}.',
    'done.recur_activate_note': ' (activate: {activate})',
    'done.recur_skip_note': '⏭ Skipped past cycles due to overdue schedule (based on due: {base} → recreated: {date})',
    'done.completed': '✅ #{num} completed.',
    'comment.added': '💬 #{num} comment added.',
    'move.done': '✅ #{num} moved to {label}.',
    'edit.clear': 'cleared',
    'edit.field_activate_recalc': 'activate recalculated',
    'edit.updated': '✅ #{num} updated: {changed}',
    'due.cleared': '✅ #{num} due date cleared.',
    'due.set': '✅ #{num} due date set to {due}.',
    'desc.appended': '✅ #{num} description appended.',
    'recur.set': '✅ #{num} recurrence set to {recur}.',
    'recur.cleared': '✅ #{num} recurrence cleared.',
    'link.linked': '✅ #{num} linked to project #{proj}.',
    'rename.done': '✅ #{num} renamed to "{title}".',
    'priority.cleared': '✅ #{num} priority cleared.',
    'priority.set': '✅ #{num} priority set to {level}.',
    'label.renamed': '✅ Renamed {old} to {new}. Updated {n} issue(s).',
    'tag.added': '✅ Added {labels} to #{num}.',
    'tag.removed': '✅ Removed {labels} from #{num}.',
    'label.list_empty': '(No context labels)',
    'label.created_named': '✅ Label {name} created.',
    'label.deleted_named': '✅ Label {name} deleted.',
    'search.no_results': 'Search results: 0 (keyword: {keyword})',
    'search.results_count': 'Search results: {n}',
    'archive.no_completed': '(No completed tasks)',
    'archive.count': '{n}',
    'archive.reopened': '✅ #{num} returned to inbox.',
    'template.issue_created': '✅ Created Issue #{num} from template "{name}".',
    'schema.description': 'Output schema for --json flagged commands',
    'schema.cmd.show': 'single object',
    'schema.cmd.list': 'array of objects',
    'schema.cmd.search': 'array of objects',
    'schema.field.number': 'Issue number',
    'schema.field.title': 'Title',
    'schema.field.state': 'Issue state: open / closed (show only)',
    'schema.field.closedAt': 'Closed timestamp (ISO8601). null when open (show only)',
    'schema.field.gtd': 'GTD category: next / inbox / waiting / someday / routine / reference / project',
    'schema.field.priority': 'Priority: p1 / p2 / p3',
    'schema.field.due': 'Due date (YYYY-MM-DD)',
    'schema.field.estimate': 'Estimate (string, in minutes)',
    'schema.field.estimateFormatted': 'Estimate display format (e.g. 2h, 30m, 1h30m)',
    'schema.field.context': 'Context labels (e.g. @home; excludes @claude)',
    'schema.field.claude': 'Whether the @claude label is present',
    'schema.field.tags': 'Other tags (e.g. #blog)',
    'schema.field.recur': 'Recurrence: daily / weekly / monthly / weekdays (fixed-day suffixes also work: weekly:<day> e.g. weekly:sat, monthly:<day> e.g. monthly:15)',
    'schema.field.project': 'Parent project issue number',
    'schema.field.activate': 'NEXT auto-promotion date (YYYY-MM-DD)',
    'schema.field.dependsOn': 'Dependency issue number',
    'schema.field.resumeCondition': 'Resume condition (free text). Condition under which promote skips auto-promotion and requests review',
    'schema.field.desc': 'Description text (body excluding meta fields)',
    'schema.field.labels': 'All labels (GTD emoji normalized)',
    'error.issue_not_found': 'Error: Issue #{num} not found.',
    'error.issue_fetch_failed': 'Error: Failed to fetch issue ({msg})',
    'show.unclassified': '(uncategorized)',
    'show.estimate_invalid': '{raw} (invalid format)',
    'show.yes': 'yes',
    'show.no': 'no',
    'show.status_done': '- Status: ✅ Done{suffix}',
    'show.closed_date_suffix': ' ({date})',
    'show.line_gtd': '- GTD Category: {value}',
    'show.line_priority': '- Priority: {value}',
    'show.line_due': '- Due: {value}',
    'show.line_estimate': '- Estimate: {value}',
    'show.line_context': '- Context: {value}',
    'show.line_claude': '- @claude: {value}',
    'show.line_recur': '- Recur: {value}',
    'show.line_project': '- Project: #{value}',
    'show.line_other_labels': '- Other Labels: {value}',
    'show.desc_header': '### Description',
    'view.viewing': '## 👁 View: {name} [{parts}]',
    'error.no_issue_numbers': 'Error: No issue numbers specified.',
    'bulk.item_error': '  #{num} error: {msg}',
    'bulk.done_count': '✅ {n} completed',
    'bulk.done_recur_suffix': ' (recurring recreated: {n})',
    'bulk.err_suffix': ' (errors: {n})',
    'bulk.moved_count': '✅ Moved {n} to {label}',
    'bulk.tag_added_count': '✅ Added {labels} to {n}',
    'bulk.tag_removed_count': '✅ Removed {labels} from {n}',
    'bulk.priority_set_count': '✅ Set priority to {level} for {n}',
    'error.not_someday': 'Error: #{num} is not a someday task.',
    'someday.reviewed': '✅ #{num} reviewed_at updated to {date}.',
    'error.already_project': 'Error: #{num} is already a project.',
    'project.promoted': '✅ #{num} "{title}" promoted to project.',
    'project.promoted_hint': '💡 To add the first Next Action: /todo next <title> --project {num}',
    'error.no_project_link': 'Error: #{num} has no project link.',
    'link.unlinked': '✅ #{num} project link removed.',
    'error.unlink_mismatch': 'Error: #{num} body points to project: #{parent}, but it is not registered as a sub-issue of that parent on GitHub. To remove the body link only, run /todo unlink {num} --force.',
    'error.unlink_failed': 'Error: Failed to unlink sub-issue for #{num}; body was not updated.',
    'error.unlink_list_failed': 'Error: Failed to fetch sub-issue list (parent #{parent}) for #{num}; body was not updated. Please retry later.',
    'link.unlinked_mismatch': '⚠️ #{num} project link (body) removed only (there was no matching sub-issue relation on GitHub).',
    'audit.no_projects': '## 📁 Project Inventory (0)\n\nNo projects.',
    'audit.header': '## 📁 Project Inventory ({n} total)',
    'audit.paused_excluded': '(Excluded {n} paused (someday) project(s))',
    'audit.verdict_stale_no_next': '⚠️ No next / no update in 30 days (stale)',
    'audit.suggestion': '  → Suggested actions: /todo next <title> --project {n} / /todo move {n} someday / /todo close {n}',
    'audit.verdict_no_next': '⚠️ Missing next',
    'audit.verdict_ok': '✅ No issues',
    'audit.days_ago': '{n} days ago',
    'audit.unknown': 'unknown',
    'audit.child_summary': '  Subtasks: next={next} waiting={waiting} someday={someday}',
    'audit.recent_update': '  Last updated: {value}',
    'audit.verdict_line': '  Verdict: {value}',
    'warn.reviewed_at_write_failed': '⚠️ #{num} failed to write reviewed_at: {msg}',
    'audit.completed_summary': '---\nInventory complete: {total} checked / reviewed_at recorded: {reviewed}',
    'migrate.no_targets': 'No issues found to migrate.',
    'migrate.dry_run_header': '## migrate sub-issue --dry-run ({n} target(s))',
    'migrate.dry_run_item': '  #{num} "{title}" → parent #{parent}',
    'migrate.dry_run_footer': '\n--dry-run mode: no actual registration performed.',
    'migrate.summary': '✅ migrate sub-issue complete: {registered} registered / {skipped} skipped / {errors} errors',
    'error.reserved_command_word': 'Error: "{word}" is a command name.',
    'error.reserved_command_hint1': '  (To avoid confusion with a command, use /todo list {cmd} if you meant to view a list)',
    'error.reserved_command_hint2': '  To explicitly add it as a task: /todo add {cmd} {word}',
    'error.command_list_hint': '  Command list: /todo help',
    'error.unknown_command': 'Error: Unknown command "{cmd}".',
    'error.unknown_command_hint1': '  (To avoid confusion with a command, use /todo add <title> to explicitly add an English title)',
    'error.unknown_command_hint2': '  To explicitly add it to inbox: /todo add {args}',
    'error.close_failed_after_recur': 'Error: Failed to close #{num} (a new recurring issue #{newNum} was already created): {msg}\n  There may now be two open issues for the same task (original #{num} and new #{newNum}). Please check manually.',
    'warn.sub_issue_skip': '⚠️ sub-issue registration skipped: #{parent} already registered (idempotent)',
    'warn.sub_issue_register_failed': '⚠️ sub-issue registration failed (issue was already created): {msg}',
    'warn.sub_issue_register_failed_422': '⚠️ sub-issue registration failed (not registered to #{parent}): {msg}',
    'warn.sub_issue_list_failed': '⚠️ Failed to fetch sub-issue list: {msg}',
    'warn.sub_issue_unlink_failed': '⚠️ Failed to unlink sub-issue: {msg}',
    'list.project_children_header': '## 📁 Project #{parent} subtasks ({n})',
    'list.no_children': '  (No subtasks)',
    'warn.open_issue_limit': '⚠️ Open issues reached the limit of {limit}. Consider closing older tasks.',
    'warn.sub_issue_list_limit': '⚠️ Sub-issues for #{parent} reached the limit of {limit}. Some may be missing from the list.',
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

// 与えられた y/mo(1-12)/da が実在するカレンダー上の日付かを判定する。
// Date コンストラクタは不正な日付（2/30等）を自動繰り上げてしまうため、
// 生成した Date を構成要素へ逆変換し、入力値と一致するかで実在性を確認する（Issue #1650）。
//
// Date コンストラクタ（および Date.UTC）には「年 0〜99 は 1900+年 とみなす」という
// 歴史的仕様があり、西暦0000〜0099年の日付が誤って1900〜1999年扱いされ判定を誤る
// （例: new Date(99, 4, 1) は 1999-05-01 になる）。setFullYear() にはこの2桁年吸収が
// 発生しないため（MDN: setFullYear は4桁年を要求し特別扱いをしない）、いったん任意の
// Date を生成してから setFullYear で年月日を明示設定することで回避する（Issue #1804）。
function isValidCalendarDate(y, mo, da) {
  const dt = new Date(0);
  dt.setFullYear(y, mo - 1, da);
  return dt.getFullYear() === y && dt.getMonth() === mo - 1 && dt.getDate() === da;
}

function isLeapYear(y) {
  return isValidCalendarDate(y, 2, 29);
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
    // M/D 形式 → YYYY-MM-DD（validateDue は M/D を許容するが、正規化後は常に YYYY-MM-DD で統一）
    // 今年の月日として変換した結果が today より過去になる場合は翌年に繰り上げる
    // （Issue #1650。過去日付を意図した M/D 指定は使えなくなるため、過去日を明示したい
    // 場合は YYYY-MM-DD 形式を使う）。2/29 のような閏日指定は、繰り上げ先の年が
    // 閏年でない限りさらに繰り上げ、存在しない日付（例: 2027-02-29）を返さないようにする。
    else if ((m=raw.match(/^(\d{1,2})\/(\d{1,2})$/))) {
      const mm = parseInt(m[1], 10), dd = parseInt(m[2], 10);
      const mmStr = String(mm).padStart(2, '0'), ddStr = String(dd).padStart(2, '0');
      let year = parseInt(today.slice(0, 4), 10);
      let candidate = year + '-' + mmStr + '-' + ddStr;
      while (candidate < today || (mm === 2 && dd === 29 && !isLeapYear(year))) {
        year += 1;
        candidate = year + '-' + mmStr + '-' + ddStr;
      }
      result = candidate;
    }
  }
  return result !== null ? result : raw;
}

// body を解析してオブジェクトで返す（parseBody の内部実装。全フィールドを一元管理）
function parseBodyObj(body) {
  const lines = (body || '').split('\n');
  let due = '', recur = '', project = '', estimate = '', actual = '', activate = '', before = '', reviewedAt = '', dependsOn = '', resumeCondition = '', descLines = [];
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
    else if (line.startsWith('resume_condition: ')) resumeCondition = line.slice(18);
    else descLines.push(line);
  }
  while (descLines.length && descLines[0].trim() === '') descLines.shift();
  return { due, recur, project, estimate, actual, activate, before, reviewedAt, dependsOn, resumeCondition, desc: descLines.join('\n') };
}

// parseBody: shell スクリプト向け外部 API（parse-body / extract-issue-fields サブコマンド）
// parseBodyObj のラッパー。フィールド追加時は parseBodyObj のみ更新すればよい。
// 出力フォーマット（KEY=VALUE\n...）は後方互換のため不変に保つ（既存キーの並び順・値は変更しない。
// 新フィールドは末尾に追加する）。
function parseBody(body) {
  const o = parseBodyObj(body);
  const descB64 = Buffer.from(o.desc, 'utf8').toString('base64');
  return 'DUE='+o.due+'\nRECUR='+o.recur+'\nPROJECT='+o.project+'\nESTIMATE='+o.estimate+'\nACTUAL='+o.actual+'\nACTIVATE='+o.activate+'\nBEFORE='+o.before+'\nREVIEWED_AT='+o.reviewedAt+'\nDESC_B64='+descB64+'\nRESUME_CONDITION='+o.resumeCondition;
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

// buildBody: Issue body 文字列を組み立てる
// 引数はオブジェクト形式（parseBodyObj の戻り値と対称）。
// 全フィールド省略可。指定されたフィールドのみ対応する行を出力する。
// 使用例:
//   buildBody({ due: '2026-01-01', desc: 'メモ' })
//   buildBody({ ...issue, desc: newDesc })          // 差分更新
//   buildBody({ ...parseBodyObj(body), reviewedAt: today })
function buildBody(fields) {
  const {
    due = '', recur = '', project = '', estimate = '', actual = '',
    desc = '', activate = '', before = '', reviewedAt = '', dependsOn = '', resumeCondition = ''
  } = fields || {};
  let body = '';
  const NL = '\n';
  if (due) body += 'due: '+due+NL;
  if (activate) body += 'activate: '+activate+NL;
  if (resumeCondition) body += 'resume_condition: '+resumeCondition+NL;
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

// body 文字列から「<fieldName>: <値>」形式の時間フィールド（estimate / actual）を抽出し、
// 分単位の数値へ変換する。
// 戻り値: { raw: string|null, minutes: number|null }
//   - raw === null            : フィールド自体が存在しない
//   - raw !== null かつ minutes === null : フィールドはあるが parseTime() が解釈できない不正な形式
// #1854: 従来は呼び出し側ごとに正規表現 `/^estimate: (\d+)/m` で先頭の数字だけを切り出した上で
// parseInt() を通していたため、"2h" のような単位付き値が数字部分「2」だけに切り詰められて抽出され
// （末尾の "h" は \d+ にマッチしないため単に無視される）、"⏱2m" のように 60〜120 倍誤った値が
// 表示されていた。抽出を \S+（値全体）に広げ、変換を parseTime() に一本化することで、
// 「数値のみ」「Nh」「Nm」「NhMm」のいずれの保存形式でも正しく分へ変換されるようにする。
function extractTimeField(body, fieldName) {
  const re = new RegExp('^' + fieldName + ': (\\S+)', 'm');
  const m = (body || '').match(re);
  if (!m) return { raw: null, minutes: null };
  return { raw: m[1], minutes: parseTime(m[1]) };
}
function estimateMinutesFromBody(body) { return extractTimeField(body, 'estimate'); }
function actualMinutesFromBody(body) { return extractTimeField(body, 'actual'); }

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

// recur パターン文字列を base（daily/weekly/monthly/weekdays）と
// suffix（曜日・日付固定サフィックス。コロンなしなら null）に分割する。
// 最初の ':' のみで分割するため、weekly:sat:mon のような多重コロンは
// suffix='sat:mon' となり、呼び出し側のホワイトリスト照合で自然に拒否される。
function splitRecurPattern(value) {
  const idx = value.indexOf(':');
  if (idx === -1) return { base: value, suffix: null };
  return { base: value.slice(0, idx), suffix: value.slice(idx + 1) };
}

// weekly:<曜日> の次回due計算（厳密加算方式。Issue #1676、2026-08-08ユーザー承認済み仕様）。
// 「必ず最低1周期分（7日）の間隔を空けてから、指定の曜日に合わせる」。
// 基準日と同じ曜日が指定されていても、+7日した時点でその曜日と一致するため
// 結果的にちょうど7日後になる（=既存の weekly と同じ間隔に収束する）。
function nextDueWeeklyOnDow(baseDate, targetDow) {
  const plus7 = addDays(baseDate, 7);
  const dow = new Date(plus7+'T00:00:00').getDay(); // +7日は常に同じ曜日を保つ
  const diff = (targetDow - dow + 7) % 7;
  return diff === 0 ? plus7 : addDays(plus7, diff);
}

// monthly:<日> の次回due計算（厳密加算方式。weeklyと同じ「最低1周期空ける」論理を
// 一貫適用する。Issue #1676、2026-08-08ユーザー承認済み仕様）。
// 「基準日 + 1ヶ月」した日以降（その日を含む）で最初に対象日と一致する日を返す。
// 対象日がその月に存在しない場合（2/30等）はその月の末日にクランプする
// （指定日そのものは保持し続けるため、翌月以降は再び対象日を狙いズレは蓄積しない）。
function nextDueMonthlyOnDay(baseDate, targetDay) {
  const dt = new Date(baseDate+'T00:00:00');
  const y = dt.getFullYear(), m = dt.getMonth(), baseDay = dt.getDate();

  // アンカー（基準日+1ヶ月）。内部比較専用で、そのまま結果として返さないため
  // クランプしても warn は出さない（addMonth()のような外部向け丸め表示ではない）
  const anchorDaysInMonth = new Date(y, m+2, 0).getDate();
  const anchorDate = new Date(y, m+1, Math.min(baseDay, anchorDaysInMonth));

  // アンカー月内での対象日候補
  const candidateDay = Math.min(targetDay, anchorDaysInMonth);
  const candidate = new Date(y, m+1, candidateDay);

  if (candidate >= anchorDate) {
    if (candidateDay !== targetDay) {
      process.stderr.write(tpl('warn.month_day_clamped', { day: targetDay, month: candidate.getMonth()+1, date: fmt(candidate) })+'\n');
    }
    return fmt(candidate);
  }

  // アンカー月の対象日はすでにアンカーより前 → 翌月へ
  const nextDaysInMonth = new Date(y, m+3, 0).getDate();
  const nextCandidateDay = Math.min(targetDay, nextDaysInMonth);
  const nextCandidate = new Date(y, m+2, nextCandidateDay);
  if (nextCandidateDay !== targetDay) {
    process.stderr.write(tpl('warn.month_day_clamped', { day: targetDay, month: nextCandidate.getMonth()+1, date: fmt(nextCandidate) })+'\n');
  }
  return fmt(nextCandidate);
}

function nextDue(pattern, baseDate) {
  const { base, suffix } = splitRecurPattern(pattern);
  switch (base) {
    case 'daily':    return addDays(baseDate, 1);
    case 'weekly':
      if (suffix === null) return addDays(baseDate, 7);
      return nextDueWeeklyOnDow(baseDate, RECUR_WEEKDAY_TO_DOW[suffix]);
    case 'monthly':
      // サフィックスなしの monthly は「前回due」しか情報を持たないため、対象日として
      // 前回dueの日を渡す。翌月にその日が存在しない場合は月末にクランプし（警告あり）、
      // 以降はクランプ後の日（例: 28日）を基準に進むため、月末クランプ後にドリフトが
      // 蓄積しない（1/31→2/28→3/28→...、3/31には戻らない）。3/31へ戻したい場合は
      // monthly:31 サフィックス（Issue #1676）を使う。Issue #1650
      if (suffix === null) return nextDueMonthlyOnDay(baseDate, new Date(baseDate+'T00:00:00').getDate());
      return nextDueMonthlyOnDay(baseDate, parseInt(suffix, 10));
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

// 最大反復回数（無限ループ防止の安全装置）。daily換算で約10年分に相当する上限。
const MAX_RECUR_CATCHUP_ITERATIONS = 3660;

// リカレンス完了時の次due計算（cadence保持スキップ方式）
// base（元のdue）が期限超過で過去の日付の場合、nextDue()を1周期進めるだけでは
// 結果が今日以前のままになることがある（例: weeklyタスクが数週間放置された場合）。
// 曜日・周期を保持したまま「今日より後」になるまでnextDue()を繰り返し適用する。
// 戻り値: { nextDate: string, skipped: boolean }
//   skipped=true の場合、1回目の適用結果が今日以前だったため追加スキップが発生したことを示す
function nextDueCatchUp(pattern, base, today) {
  let date = nextDue(pattern, base);
  let skipped = false;
  let iterations = 0;
  while (date <= today && iterations < MAX_RECUR_CATCHUP_ITERATIONS) {
    date = nextDue(pattern, date);
    skipped = true;
    iterations++;
  }
  if (skipped && date <= today) {
    process.stderr.write(tpl('warn.recur_catchup_limit', { limit: MAX_RECUR_CATCHUP_ITERATIONS, date })+'\n');
  }
  return { nextDate: date, skipped };
}

// GTDルーティンの「後始末漏れ」検知閾値（Issue #1776）。
// cycles_overdue が この値以上のルーティンを「要確認」として routineOverdue と別枠に分離する。
// 1周期分の遅延（=1）は通常運用の範囲として従来どおり routineOverdue のまま扱う。
// 実データ未検証の暫定値。運用開始後に調整余地あり。
const STALE_CYCLE_THRESHOLD = 2;

// due から today まで、recurPattern で何周期分「進めずに」経過したかを計算する
// （読み取り専用のプレビュー関数。Issue #1776）。
// nextDueCatchUp()（done コマンドの書き込みパスで使用）と同一の反復・上限・警告出力
// ロジックを流用するが、書き込みパスには一切影響を与えない独立実装として追加する。
// nextDueCatchUp() 自体はこの関数追加により変更しない。
// 戻り値: number（0以上。due >= today なら 0）
function computeCyclesOverdue(recurPattern, due, today) {
  if (due >= today) return 0;
  let date = due;
  let iterations = 0;
  while (date < today && iterations < MAX_RECUR_CATCHUP_ITERATIONS) {
    date = nextDue(recurPattern, date);
    iterations++;
  }
  if (date < today) {
    process.stderr.write(tpl('warn.recur_catchup_limit', { limit: MAX_RECUR_CATCHUP_ITERATIONS, date })+'\n');
  }
  return iterations;
}

// ─── バリデーション関数 ───

// 記号のみ・空文字のラベル名を弾くための判定（Issue #1686）
// FORBIDDEN_CHARS はシェル的に危険な文字しか列挙していないため、'-' のように
// 危険ではないが意味のない記号だけで構成された名前（'@--' 等）が検証を通り、
// GitHub 上に不正ラベルとして新規作成されていた。
const HAS_LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;

function validateCtx(value) {
  if (!HAS_LETTER_OR_DIGIT.test(value)) {
    process.stderr.write(t('error.ctx_symbol_only')+'\n');
    process.exit(1);
  }
  for (const c of value) {
    if (FORBIDDEN_CHARS.indexOf(c) >= 0 || c === ' ') {
      process.stderr.write(t('error.ctx_invalid')+'\n');
      process.exit(1);
    }
  }
}

// #tag バリデーション: 不正文字チェック + 数字のみ禁止（Issue番号と被る）
function validateTag(value) {
  // value は '#' プレフィックスを除いた部分
  if (/^\d+$/.test(value)) {
    process.stderr.write(t('error.tag_num_only')+'\n');
    process.exit(1);
  }
  if (!HAS_LETTER_OR_DIGIT.test(value)) {
    process.stderr.write(t('error.tag_symbol_only')+'\n');
    process.exit(1);
  }
  for (const c of value) {
    if (FORBIDDEN_CHARS.indexOf(c) >= 0 || c === ' ') {
      process.stderr.write(t('error.tag_invalid')+'\n');
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

// M/D 形式の妥当性判定に使う基準年（存在しない年は判定できないため、うるう年を採用し
// 2/29 を許容する。西暦は判定結果に影響しない：2/30 等の非存在日は年に関わらず常に無効）
const MD_VALIDATION_LEAP_YEAR = 2000;

function validateDue(value) {
  if (value === 'clear' || value === '') return; // clear / 空文字は期日削除として許可
  let m;
  if ((m = value.match(/^(\d{4})-(\d{2})-(\d{2})$/))) {
    const y = parseInt(m[1], 10), mo = parseInt(m[2], 10), da = parseInt(m[3], 10);
    if (isValidCalendarDate(y, mo, da)) return;
  } else if ((m = value.match(/^(\d{1,2})\/(\d{1,2})$/))) {
    const mo = parseInt(m[1], 10), da = parseInt(m[2], 10);
    if (isValidCalendarDate(MD_VALIDATION_LEAP_YEAR, mo, da)) return;
  }
  process.stderr.write(t('error.date_format')+'\n');
  process.exit(1);
}

// activate バリデーション（normalizeDue 済みの文字列を受け取る）。
// normalizeDue は正規化のみを行い実在性は判定しないため、YYYY-MM-DD 形式チェックに加えて
// isValidCalendarDate でカレンダー上に実在する日付かを検証する。不正なら validateDue と
// 同じ error.date_format メッセージ（ユーザー入力の原文付き）を出力して exit(1) する。
// validateDue をそのまま使わず専用関数にしているのは、活性化系呼び出し元の既存エラー体系
// （メッセージ末尾に元の入力文字列 `parsed.activate` を付与する形式）を変えずに保つため
// （Issue #1803）。
function validateActivateFormat(activateRaw, originalRaw) {
  const m = activateRaw && activateRaw.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (m) {
    const y = parseInt(m[1], 10), mo = parseInt(m[2], 10), da = parseInt(m[3], 10);
    if (isValidCalendarDate(y, mo, da)) return;
  }
  process.stderr.write(t('error.date_format') + ': ' + originalRaw + '\n');
  process.exit(1);
}

// recur バリデーション（Issue #1676: weekly:<曜日> / monthly:<日> の固定サフィックスに対応）。
// 先頭の ':' のみで base/suffix に分割し、base のホワイトリスト判定 → suffix の
// 許可可否・形式検証という順で分岐する。base 自体が不正なら常に error.recur_invalid。
function validateRecur(value) {
  const { base, suffix } = splitRecurPattern(value);

  if (!['daily','weekly','monthly','weekdays'].includes(base)) {
    process.stderr.write(t('error.recur_invalid')+'\n');
    process.exit(1);
  }

  if (base === 'daily' || base === 'weekdays') {
    if (suffix !== null) {
      process.stderr.write(t('error.recur_suffix_not_allowed')+'\n');
      process.exit(1);
    }
    return;
  }

  if (base === 'weekly') {
    if (suffix === null) return; // 後方互換: サフィックスなしは既存挙動のまま
    if (!Object.prototype.hasOwnProperty.call(RECUR_WEEKDAY_TO_DOW, suffix)) {
      process.stderr.write(t('error.recur_weekday_invalid')+'\n');
      process.exit(1);
    }
    return;
  }

  // base === 'monthly'
  if (suffix === null) return; // 後方互換: サフィックスなしは既存挙動のまま
  if (!/^\d{1,2}$/.test(suffix)) {
    process.stderr.write(t('error.recur_monthday_invalid')+'\n');
    process.exit(1);
  }
  const day = parseInt(suffix, 10);
  if (day < 1 || day > 31) {
    process.stderr.write(t('error.recur_monthday_invalid')+'\n');
    process.exit(1);
  }
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

// resume_condition バリデーション: 改行混入のみ禁止（行プレフィックス解析の破損防止）。
// 文字種は制限しない（desc同様の自由記述のため）。
function validateResumeCondition(value) {
  if (/[\r\n]/.test(value)) {
    process.stderr.write(t('error.resume_condition_newline')+'\n');
    process.exit(1);
  }
}

// Issue タイトル用バリデーション（#1825 案A）。
// タイトルは Octokit 経由の HTTP API にのみ渡り、シェル展開を経由しないため
// FORBIDDEN_CHARS（; $ ` ( ) " ' \ | & > < { }）による禁止は過剰。
// 唯一の実害経路は todo.sh の --remind（AppleScript ヒアドキュメント）だが、
// そちらは todo.sh 側でエスケープして対処する（本バリデーションでは扱わない）。
// ここでは、行プレフィックス解析・表示崩れの原因になる制御文字（改行・タブ等、
// Unicode Cc カテゴリ）のみを禁止し、丸括弧を含むそれ以外の記号は全て許可する。
function validateTitle(value) {
  if (!value) {
    process.stderr.write(t('error.name_empty')+'\n');
    process.exit(1);
  }
  if (/\p{Cc}/u.test(value)) {
    process.stderr.write(t('error.title_control_char')+'\n');
    process.exit(1);
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
// #tag ラベル: '#' で始まり、後続が数字のみでないもの（Issue番号 #42 は除外）
function getTags(lnames) { return lnames.filter(l => l.startsWith('#') && !/^#\d+$/.test(l)); }

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
  const tags = getTags(lnames);
  const due = getDue(issue);
  // \w+ はコロンにマッチしないため、weekly:sat のようなサフィックス付き値が
  // weekly に切り詰められて表示されるバグがあった（Issue #1676 対応時に発見・修正）。
  // recur の値は行末までの1トークン（空白を含まない）なので \S+ で全体を拾う。
  const recur = (issue.body||'').match(/^recur: (\S+)/m);
  const proj = (issue.body||'').match(/^project: #(\d+)/m);
  const est = estimateMinutesFromBody(issue.body||'');
  let line = '  '+priIcon(getPri(lnames))+'#'+issue.number+'  '+issue.title;
  if (ctx.length) line += '  ['+ctx.join(' ')+']';
  if (tags.length) line += '  ['+tags.join(' ')+']';
  if (due) line += '  📅 '+due;
  // #1854: parseTime() が解釈できない不正な estimate 値は "⏱0m" のように黙って握りつぶさず、
  // ⚠️ 付きで生値を表示して気づけるようにする（無視すると「静かな期待値乖離」になるため）。
  if (est.raw !== null) line += est.minutes !== null ? '  ⏱'+formatTime(est.minutes) : '  ⏱⚠️'+est.raw;
  if (proj) line += '  [project:#'+proj[1]+']';
  if (recur) line += '  🔄'+recur[1];
  // someday かつ長期未見直しの場合にマーカーを付ける
  if (today && (lnames.includes('someday') || lnames.includes('🌈 someday'))) {
    const reviewedAt = (issue.body||'').match(/^reviewed_at: (\d{4}-\d{2}-\d{2})/m)?.[1] || '';
    if (!reviewedAt || daysBetween(reviewedAt, today) >= 30) {
      line = '  ⚠️' + line.slice(2);
    }
  }
  // routine かつ due がある場合にマーカーを付ける
  // （renderToday の routineStale と同一の計算・閾値を再利用。Issue #1776）
  if (today && lnames.includes('routine') && due) {
    if (recur) {
      const cycles = computeCyclesOverdue(recur[1], due, today);
      if (cycles >= STALE_CYCLE_THRESHOLD) {
        line = '  🕰' + line.slice(2);
      }
    } else if (due < today) {
      // recur フィールドが欠落した routine（想定外だが存在しうる）は cycles_overdue 計算を
      // スキップし、renderToday() の routineStale フォールバックと同一の updated_at
      // staleness（既存 project staleness badge と同一閾値・判定式）にフォールバックする。
      // 両者の挙動を対称に保つための対応。Issue #1776。
      const updatedAt = issue.updated_at || '';
      if (updatedAt && daysBetween(toJstDateStr(updatedAt), today) >= 30) {
        line = '  🕰' + line.slice(2);
      }
    }
  }
  // next/waiting かつ updated_at が30日以上前の場合にマーカーを付ける
  // （project staleness badge と同一閾値・判定式の横展開。Issue #1776）
  if (today && (lnames.includes('next') || lnames.includes('waiting'))) {
    const updatedAt = issue.updated_at || '';
    if (updatedAt && daysBetween(toJstDateStr(updatedAt), today) >= 30) {
      line = '  🕰' + line.slice(2);
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
    w(t('group.overdue')+'\n');
    for (const i of groups.overdue) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.today_.length) {
    w(tpl('group.today', {date: mmdd(today)})+'\n');
    for (const i of groups.today_) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.tomorrow_.length) {
    w(tpl('group.tomorrow', {date: mmdd(tomorrowStr)})+'\n');
    for (const i of groups.tomorrow_) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.thisWeek.length) {
    w(tpl('group.this_week', {date: mmdd(d7str)})+'\n');
    for (const i of groups.thisWeek) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.later.length) {
    w(t('group.later')+'\n');
    for (const i of groups.later) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
  if (groups.noDue.length) {
    w(t('group.no_due')+'\n');
    for (const i of groups.noDue) w(renderIssueList(i, today)+'\n');
    w('\n');
  }
}

function listAll() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const filterGtd = process.env.FILTER_GTD_ENV || '';
  const filterCtx = process.env.FILTER_CTX_ENV || '';
  const filterTag = process.env.FILTER_TAG_ENV || '';
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
  if (filterTag) filtered = filtered.filter(i => getLnames(i).includes(filterTag));
  if (filterPri) filtered = filtered.filter(i => getLnames(i).includes(filterPri));
  if (filterProj) {
    const projTag = 'project: #'+filterProj;
    filtered = filtered.filter(i => (i.body||'').includes(projTag));
  }

  // 「/todo list project」（filterGtd === 'project'）は 🌈 someday を併せ持つ project を
  // 「休止中」として除外する（#1846: move <n> someday しても project ラベルは残る設計のため、
  //  消費側であるここで除外する。除外件数は黙って減らさず利用者に明示する）
  let excludedSomedayProjectCount = 0;
  if (filterGtd === PROJECT_LABEL) {
    const before = filtered.length;
    filtered = filtered.filter(i => !getLnames(i).includes('someday'));
    excludedSomedayProjectCount = before - filtered.length;
  }
  const writeExcludedNote = () => {
    if (excludedSomedayProjectCount > 0) {
      w(tpl('list.excluded_someday_projects', { n: excludedSomedayProjectCount })+'\n');
    }
  };

  // --no-due → 期限未設定のタスクだけフラットリストで返す（--group より優先）
  if (noDue) {
    filtered = filtered.filter(i => !/(^|\n)due: \d{4}-\d{2}-\d{2}/.test(i.body||''));
    filtered.sort(sortByPriDue);
    writeExcludedNote();
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    for (const issue of filtered) { w(renderIssueList(issue, today)+'\n'); }
    return;
  }

  // --no-estimate → 見積もり未設定のタスクだけフラットリストで返す（--no-due と同パターン）
  if (noEstimate) {
    filtered = filtered.filter(i => !/(^|\n)estimate: \S+/.test(i.body||''));
    filtered.sort(sortByPriDue);
    writeExcludedNote();
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    for (const issue of filtered) { w(renderIssueList(issue, today)+'\n'); }
    return;
  }

  // フィルタ指定あり かつ --group → 期限別グルーピング
  if ((filterGtd || filterCtx || filterTag || filterPri || filterProj) && groupByDue) {
    writeExcludedNote();
    if (!filtered.length) { w(t('list.no_match')+'\n'); return; }
    listGroupedByDue(filtered, today);
    return;
  }

  // フィルタ指定あり → フラットリスト
  if (filterGtd || filterCtx || filterTag || filterPri || filterProj) {
    if (filterGtd === 'someday') {
      filtered.sort((a, b) => sortByReviewedAtThenPri(a, b, today));
    } else {
      filtered.sort(sortByPriDue);
    }
    writeExcludedNote();
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
  // 🌈 someday を併せ持つ project は「休止中」として除外する（#1846: list project /
  // weekly-project-audit と同じ扱いに揃える。除外件数は黙って減らさず明示する）
  const allProjItems = grouped[PROJECT_LABEL];
  const projItems = allProjItems.filter(i => !getLnames(i).includes('someday'));
  const pausedProjCount = allProjItems.length - projItems.length;
  let noNextCount = 0, staleCount = 0;
  const projStats = projItems.map(issue => {
    const projTag = 'project: #'+issue.number;
    // body メタ検索と sub-issue の両方は非同期不可のため body メタのみでカウント
    const childIssues = issues.filter(i => (i.body||'').includes(projTag));
    const nextCount = childIssues.filter(i => getLnames(i).includes('next')).length;
    const waitingCount = childIssues.filter(i => getLnames(i).includes('waiting')).length;
    const hasNext = nextCount > 0;
    const updatedAt = issue.updated_at || '';
    const isStale = updatedAt ? daysBetween(toJstDateStr(updatedAt), today) >= 30 : false;
    if (!hasNext) noNextCount++;
    if (isStale) staleCount++;
    return { issue, nextCount, waitingCount, hasNext, isStale };
  });

  // ヘッダ行
  let projHeader = t('section.project');
  if (projItems.length > 0) {
    const badges = [];
    if (noNextCount > 0) badges.push(tpl('project.badge_no_next', { n: cnt(noNextCount) }));
    if (staleCount > 0) badges.push(tpl('project.badge_stale', { n: cnt(staleCount) }));
    projHeader = tpl('project.header_count', { n: cnt(projItems.length), badges: badges.length ? '  ' + badges.join(' / ') : '' });
  }
  w(projHeader+'\n');
  if (pausedProjCount > 0) w(tpl('list.excluded_someday_projects', { n: pausedProjCount })+'\n');
  if (!projItems.length) {
    w('  '+t('list.none')+'\n');
  } else {
    for (const { issue, nextCount, waitingCount, hasNext, isStale } of projStats) {
      const childSummary = [];
      if (nextCount > 0) childSummary.push(tpl('project.child_next', { n: cnt(nextCount) }));
      if (waitingCount > 0) childSummary.push(tpl('project.child_waiting', { n: cnt(waitingCount) }));
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
      const reviewStr = reviewedAt ? tpl('project.last_reviewed', { days: daysBetween(reviewedAt, today) }) : '';
      // 停滞+next欠落の行頭に ⚠️ マーカー
      const linePrefix = (!hasNext && isStale) ? '  ⚠️ ' : '  ';
      w(`${linePrefix}#${issue.number}  ${issue.title}${statusStr}${reviewStr}\n`);
    }
  }
  w('\n');

  // サマリー
  // project件数は上のプロジェクトセクション表示（休止中除外後）と一致させる
  const counts = {};
  GTD_LABELS.forEach(l => counts[l] = grouped[l].length);
  counts[PROJECT_LABEL] = projItems.length;
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
      const est = estimateMinutesFromBody(issue.body||'');
      if (est.minutes !== null) { nextEstTotal += est.minutes; nextEstCount++; }
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
  // 'add_explicit' は 'add' の直後に配置（Issue #1884/#1906: 再測定で判明した真正の欠落。
  // help.add の汎用行「/todo [GTD] <タイトル>」は GTD ラベル同梱ケースをカバーするが、
  // GTDラベルを伴わない英字タイトルで add を明示する用法は別途明記が必要）。
  for (const k of ['add','add_explicit','list','done','move','edit','rename','due','desc','recur','priority','search']) {
    w(t('help.'+k)+'\n');
  }
  w('```\n');
  w('\n');
  // routine ラベル（GTD_LABELS の一種。add/move で使用）と recur コマンドの併用を促すヒント（Issue #1906）。
  // このセクションに add/move/recur が並んでいるため、直下の脚注として配置する（desc_note と同じ脚注パターン）。
  w(t('help.routine_hint')+'\n');
  w('\n');

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
  for (const k of ['today','eisenhower','dashboard','review_someday','stats','report']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w(t('help.section_template')+'\n');
  w('```\n');
  for (const k of ['template','view']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w(t('help.section_project')+'\n');
  w('```\n');
  for (const k of ['promote_project','unlink','migrate','weekly_project_audit']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w(t('help.section_other')+'\n');
  w('```\n');
  for (const k of ['show','schema','archive','link','promote','comment','api','help']) { w(t('help.'+k)+'\n'); }
  w('```\n\n');

  w(t('help.activate_section_header')+'\n');
  w('```\n');
  // activate <#> <日付> は edit <#> --activate <日付> の簡略記法（Issue #1906）。
  // dispatcher の case 'activate'（run + edit --activate 委譲）に対応するコマンド行が
  // これまで欠落していた。todo.md の該当テーブル行と文言を揃える。
  w(t('help.activate_cmd')+'\n');
  w(t('help.activate')+'\n');
  w(t('help.before')+'\n');
  w(t('help.depends_on')+'\n');
  w(t('help.resume_condition')+'\n');
  w('```\n');
  w('\n');
  w(t('help.desc_note')+'\n');
  w('\n');

  w(t('help.section_migrated')+'\n');
  w(t('help.review_migrated')+'\n');
  w(t('help.daily_migrated')+'\n');
  w(t('help.weekly_migrated')+'\n');
}

function renderToday() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const todayStr = process.env.TODAY_ENV;
  const closed = JSON.parse(process.env.CLOSED_ENV || '[]');
  const w = s => process.stdout.write(s);

  const overdue = [], dueToday = [], routineToday = [], routineOverdue = [];
  // routineStale: cycles_overdue >= STALE_CYCLE_THRESHOLD の「要確認」ルーティン（Issue #1776）。
  // { issue, cycles } の配列。cycles は recur 欠落時の updated_at フォールバック時 null になる。
  const routineStale = [];
  for (const issue of issues) {
    const lnames = getLnames(issue);
    const due = getDue(issue);
    if (lnames.includes('routine')) {
      if (due && due < todayStr) {
        const recurMatch = (issue.body||'').match(/^recur: (\S+)/m);
        if (recurMatch) {
          const cycles = computeCyclesOverdue(recurMatch[1], due, todayStr);
          if (cycles >= STALE_CYCLE_THRESHOLD) routineStale.push({ issue, cycles });
          else routineOverdue.push(issue);
        } else {
          // recur フィールドが欠落した routine（想定外だが存在しうる）は
          // cycles_overdue 計算をスキップし、既存の updated_at staleness にフォールバックする
          const updatedAt = issue.updated_at || '';
          const isStaleByUpdatedAt = updatedAt ? daysBetween(toJstDateStr(updatedAt), todayStr) >= 30 : false;
          if (isStaleByUpdatedAt) routineStale.push({ issue, cycles: null });
          else routineOverdue.push(issue);
        }
      } else if (due && due === todayStr) {
        routineToday.push(issue);
      }
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
  routineStale.sort((a, b) => sortByPriDue(a.issue, b.issue));

  w(tpl('today.header', {date: todayStr})+'\n\n');

  if (overdue.length === 0 && dueToday.length === 0 && routineToday.length === 0 && routineOverdue.length === 0 && routineStale.length === 0) {
    w(t('today.no_tasks')+'\n');
    return;
  }

  const renderIssue = (i, showDue, suffix) => {
    const lnames = getLnames(i);
    const ctx = getCtx(lnames);
    w('  '+priIcon(getPri(lnames))+'#'+i.number+'  '+i.title);
    if (ctx.length) w('  ['+ctx.join(' ')+']');
    if (showDue) { const due = getDue(i); if (due) w('  📅 '+due); }
    const est = estimateMinutesFromBody(i.body||'');
    if (est.raw !== null) w(est.minutes !== null ? '  ⏱'+formatTime(est.minutes) : '  ⏱⚠️'+est.raw);
    if (suffix) w('  '+suffix);
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
  if (routineStale.length) {
    w(tpl('today.routine_stale', {n: cnt(routineStale.length)})+'\n');
    routineStale.forEach(({ issue: i, cycles }) => {
      const suffix = cycles !== null
        ? tpl('today.cycles_suffix', { n: cycles })
        : t('today.stale_no_recur');
      renderIssue(i, true, suffix);
    });
    w('\n');
  }

  // サマリー（routineStale は「今すぐやるタスク」ではなく「確認が必要な記録」のため含めない）
  const allTasks = [...overdue, ...dueToday, ...routineToday, ...routineOverdue];
  let estTotal = 0;
  for (const i of allTasks) {
    const est = estimateMinutesFromBody(i.body||'');
    if (est.minutes !== null) estTotal += est.minutes;
  }
  const todayClosed = closed.filter(i => i.closedAt && toJstDateStr(i.closedAt) === todayStr).length;

  w('---\n');
  const parts = [tpl('today.summary', {total: cnt(allTasks.length)})];
  if (estTotal > 0) parts.push(tpl('today.est', {time: formatTime(estTotal)}));
  if (todayClosed > 0) parts.push(tpl('today.done', {n: cnt(todayClosed)}));
  w(parts.join('  ')+'\n');
}

function eisenhower() {
  const issues = JSON.parse(process.env.OPEN_ENV || '[]');
  const todayStr = process.env.TODAY_ENV;
  const w = s => process.stdout.write(s);

  // next ラベルのタスクのみ抽出
  const nextIssues = issues.filter(issue => getLnames(issue).includes('next'));

  // p9 タスク（優先度未設定）と分類対象タスクを分離
  const unset = [];
  const q1 = [], q2 = [], q3 = [], q4 = [];

  for (const issue of nextIssues) {
    const lnames = getLnames(issue);
    const pri = getPri(lnames);
    const due = getDue(issue);

    if (pri === 'p9') {
      unset.push(issue);
      continue;
    }

    const isImportant = (pri === 'p1' || pri === 'p2');
    const isUrgent = due !== null && due <= todayStr;

    if (isImportant && isUrgent) {
      q1.push(issue);
    } else if (isImportant && !isUrgent) {
      q2.push(issue);
    } else if (!isImportant && isUrgent) {
      q3.push(issue);
    } else {
      q4.push(issue);
    }
  }

  // ソート
  q1.sort(sortByPriDue);
  q2.sort(sortByPriDue);
  q3.sort(sortByPriDue);
  q4.sort(sortByPriDue);

  // ヘッダ
  w(tpl('eisenhower.header', {date: todayStr})+'\n\n');

  // 優先度未設定タスク（1件以上の場合のみ表示）
  if (unset.length > 0) {
    w(tpl('eisenhower.unset', {count: unset.length})+'\n\n');
  }

  // Q1
  w(t('eisenhower.q1')+' （'+cnt(q1.length)+'）\n');
  if (!q1.length) { w('  '+t('list.none')+'\n'); }
  else { for (const issue of q1) { w(renderIssueList(issue, todayStr)+'\n'); } }
  w('\n');

  // Q2
  w(t('eisenhower.q2')+' （'+cnt(q2.length)+'）\n');
  if (!q2.length) { w('  '+t('list.none')+'\n'); }
  else { for (const issue of q2) { w(renderIssueList(issue, todayStr)+'\n'); } }
  w('\n');

  // Q3
  w(t('eisenhower.q3')+' （'+cnt(q3.length)+'）\n');
  if (!q3.length) { w('  '+t('list.none')+'\n'); }
  else { for (const issue of q3) { w(renderIssueList(issue, todayStr)+'\n'); } }
  w('\n');

  // Q4
  w(t('eisenhower.q4')+' （'+cnt(q4.length)+'）\n');
  if (!q4.length) { w('  '+t('list.none')+'\n'); }
  else { for (const issue of q4) { w(renderIssueList(issue, todayStr)+'\n'); } }
  w('\n');

  // フッター（{total} は next ラベル全タスク数、p9 含む）
  w('---\n');
  w(tpl('eisenhower.summary', {
    q1: cnt(q1.length),
    q2: cnt(q2.length),
    q3: cnt(q3.length),
    q4: cnt(q4.length),
    total: cnt(nextIssues.length)
  })+'\n');
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
  const todayClosed = closed.filter(i => i.closedAt && toJstDateStr(i.closedAt) === today).length;
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
    const est = estimateMinutesFromBody(i.body||'');
    if (est.minutes !== null) { estTotal += est.minutes; estCount++; }
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
    const d = toJstDateStr(i.closedAt);
    return d >= startStr && d <= today;
  });

  const dailyCounts = {};
  for (let i = 0; i < days; i++) {
    const d = new Date(today);
    d.setDate(d.getDate()-i);
    dailyCounts[d.toISOString().slice(0,10)] = 0;
  }
  for (const issue of periodClosed) {
    const d = toJstDateStr(issue.closedAt);
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
    const est = estimateMinutesFromBody(issue.body||'');
    const act = actualMinutesFromBody(issue.body||'');
    if (est.minutes !== null) estSum += est.minutes;
    if (act.minutes !== null) actSum += act.minutes;
    if (est.minutes !== null && act.minutes !== null) estActCount++;
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
    for (const i of recent) { w('  ✅ #'+i.number+'  '+i.title+'  ('+toJstDateStr(i.closedAt)+')\n'); }
  } else { w('  '+t('report.no_completed')+'\n'); }
  w('\n');
}

function doneCount() {
  const closed = JSON.parse(process.env.CLOSED_ENV || '[]');
  const today = process.env.TODAY_ENV;
  const cnt = closed.filter(i => i.closedAt && toJstDateStr(i.closedAt) === today).length;
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

// Octokit カスタムロガー
// @octokit/plugin-request-log は 4xx を含む全 API エラーを console.error に出力する。
// 期待される 4xx (404: リソース未存在, 422: バリデーション) は操作ロジック内でハンドリング済みのため
// ここで抑止し、予期しない 5xx や接続エラーのみ stderr に出力する。(Issue #1328)
const OCTOKIT_LOGGER = {
  debug: () => {},
  info:  () => {},
  warn:  console.warn,
  error: (msg) => {
    const s = String(msg);
    if (s.includes('404') || s.includes('422')) return; // 期待される 4xx は黙らせる
    console.error(msg);
  }
};

async function apiMain(subArgs) {
  if (!REPO_OWNER || !REPO_NAME) {
    throw apiErr('TODO_REPO_OWNER and TODO_REPO_NAME must be set in .env or environment variables.');
  }
  const subCmd = subArgs[0];
  if (!subCmd) { throw apiErr('Usage: todo-engine.js api <subcommand> [args...]'); }

  // トークン取得・Octokit構築は initOctokit() に委譲（Issue #1648: 重複コード削除 + テストシーム統合）。
  // トークン取得優先順位（1. GH_TOKEN/GITHUB_TOKEN 2. ~/.claude/github-token 3. エラー）と
  // エラーメッセージ文言は initOctokit() 側で完全に同一のものを踏襲している。
  const octokit = await initOctokit();
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
        while (allIssues.length < (limitIdx >= 0 ? parseInt(subArgs[limitIdx+1])||MAX_OPEN_ISSUES_LIMIT : MAX_OPEN_ISSUES_LIMIT)) {
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
          closedAt: i.closed_at || null,
          updatedAt: i.updated_at || null
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

      case 'view-issue-detail': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api view-issue-detail <number>'); }
        const { data: i } = await octokit.issues.get({ owner, repo, issue_number: num });
        const result = {
          number: i.number,
          title: i.title,
          body: i.body || '',
          labels: i.labels.map(l => ({ name: l.name })),
          assignees: i.assignees ? i.assignees.map(a => a.login) : [],
          createdAt: i.created_at || null,
          updatedAt: i.updated_at || null,
        };
        process.stdout.write(JSON.stringify(result));
        break;
      }

      case 'list-comments': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api list-comments <number>'); }
        const { data } = await octokit.issues.listComments({ owner, repo, issue_number: num, per_page: 100 });
        const result = data.map(c => ({
          id: c.id,
          author: c.user ? c.user.login : '',
          body: c.body || '',
          createdAt: c.created_at || null,
        }));
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

      // Issue #1669: close-issue は close するだけで createRecurIssue（recur再作成）/
      // postDoneProcessing（depends_on昇格）を一切呼ばないため、Web版の done() 経由では
      // 繰り返しタスクの周期チェーンが無言で途切れていた。CLIの `run done`（runDone）と
      // 同じ後処理を api 層からも呼べるようにする専用サブコマンド。
      case 'done-issue': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api done-issue <number>'); }
        const issue = await fetchAndParseIssue(octokit, owner, repo, num);
        // #1652: create-before-close — 次周期Issueの作成をcloseより先に行う（詳細はcreateRecurIssue定義部のコメント参照）
        const { recurLine, newIssueNumber } = await createRecurIssue(octokit, owner, repo, issue);
        try {
          await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });
        } catch (e) {
          if (newIssueNumber) {
            throw apiErr('Error: Failed to close issue #'+num+' (a new recurring issue #'+newIssueNumber+' was already created): '+e.message+'. There may now be two open issues for the same task (original #'+num+' and new #'+newIssueNumber+'). Please check manually.');
          }
          throw e;
        }
        const { otherLines } = await postDoneProcessing(octokit, owner, repo, num, issue);
        process.stdout.write(JSON.stringify({
          ok: true,
          recurLine: recurLine || null,
          otherLines: otherLines || [],
          newIssueNumber: newIssueNumber || null,
        }));
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
        await execRemoveLabels(octokit, owner, repo, num, labels);
        process.stdout.write('ok');
        break;
      }

      case 'move-gtd': {
        const num = parseInt(subArgs[1]);
        const target = subArgs[2];
        if (!num || !target) { throw apiErr('Usage: api move-gtd <number> <gtd_key>'); }
        await execMoveGtd(octokit, owner, repo, num, target);
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

      case 'create-comment': {
        const num = parseInt(subArgs[1]);
        if (!num) { throw apiErr('Usage: api create-comment <number>'); }
        // コメント本文は環境変数経由（セキュリティルール準拠）
        let body = process.env.COMMENT_BODY_ENV || '';
        if (!body) { throw apiErr('Error: COMMENT_BODY_ENV is not set'); }
        // \r\n → \n, 残存 \r → \n に正規化（Windows環境での既知問題対策）
        body = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
        // NULL バイト・制御文字（\x00-\x1F、\n 除く）を除去
        body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
        // 最大文字数チェック（GitHub API 制限）
        if (body.length > 65536) {
          throw apiErr('Error: Comment body exceeds the maximum length (65536 characters) (current: '+body.length+' characters)');
        }
        if (!body.trim()) { throw apiErr('Error: Comment body is empty'); }
        const { data: comment } = await octokit.issues.createComment({ owner, repo, issue_number: num, body });
        process.stdout.write(JSON.stringify({ id: comment.id, url: comment.html_url }));
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
  case 'build-body':      process.stdout.write(buildBody({
    due:        args[1] || '',
    recur:      args[2] || '',
    project:    args[3] || '',
    estimate:   args[4] || '',
    actual:     args[5] || '',
    desc:       args[6] || '',
    activate:   args[7] || '',
    before:     args[8] || '',
    reviewedAt: args[9] || '',
    dependsOn:  args[10] || '',
  })); break;
  case 'parse-time': {
    const v = parseTime(args[1]);
    process.stdout.write(v !== null ? String(v) : 'null');
    break;
  }
  case 'format-time':     process.stdout.write(formatTime(args[1])); break;
  case 'priority-color':  process.stdout.write(priorityColor(args[1])); break;
  case 'next-due':        process.stdout.write(nextDue(args[1], args[2])); break;
  case 'next-due-catchup': process.stdout.write(JSON.stringify(nextDueCatchUp(args[1], args[2], args[3]))); break;
  case 'cycles-overdue':  process.stdout.write(String(computeCyclesOverdue(args[1], args[2], args[3]))); break;
  case 'find-unknown-flag': {
    // 未知フラグ判定の単体テスト用（Issue #1921）。入力は JSON 配列の文字列
    // （例: '["設計書を書く","--boddy-file"]' と許可リスト '["--group"]'）。
    // 検出したフラグ文字列を、なければ空文字列を stdout へ返す。
    // Octokit スタブも GitHub 接続も不要な純粋関数なので、入力文字パターン・境界値を
    // 大量に回して検証できる（tests/run-tests.sh §51）。
    const toks = JSON.parse(args[1] || '[]');
    const allowed = JSON.parse(args[2] || '[]');
    process.stdout.write(findUnknownFlag(toks, allowed) || '');
    break;
  }
  case 'compute-github-ms': {
    // 区間統合アルゴリズム単体テスト用（Issue #455）。入力はms単位の [start, end] 配列
    // （例: '[[0,100],[50,150],[200,250]]'）。内部でns相当に換算してcomputeGithubMs()を
    // 通し、結果をms単位の整数文字列で返す。Octokitスタブなしで区間統合の挙動を検証できる。
    const intervalsMs = JSON.parse(args[1] || '[]');
    const intervalsNs = intervalsMs.map(([s, e]) => [BigInt(s) * 1000000n, BigInt(e) * 1000000n]);
    process.stdout.write(String(computeGithubMs(intervalsNs)));
    break;
  }
  case 'check-octokit-wrap-props': {
    // wrapOctokitTiming() が Octokit の関数プロパティ（.endpoint/.defaults）を保持する
    // ことを検証するテスト専用コマンド（Issue #455）。initOctokit() と同じ分岐
    // （OCTOKIT_STUB_ENV が設定されていればスタブ、なければ実 @octokit/rest）を使う。
    // どちらの経路もネットワーク接続不要（インスタンスを構築してプロパティを
    // 調べるだけ、HTTP呼び出しは行わない）。実 @octokit/rest 経路の GH_TOKEN は
    // 実在不要（構築時に検証されないダミー値で足りる）。
    (async () => {
      const stubModulePath = process.env.OCTOKIT_STUB_ENV;
      let raw;
      if (stubModulePath) {
        const createStubOctokit = require(path.resolve(stubModulePath));
        raw = createStubOctokit({ logPath: null, responsesSpec: null });
      } else {
        const { pathToFileURL } = require('url');
        const octokitPath = path.join(process.env.HOME || os.homedir(), '.claude', 'node_modules', '@octokit', 'rest', 'dist-src', 'index.js');
        const mod = await import(pathToFileURL(octokitPath).href);
        raw = new mod.Octokit({ auth: 'dummy-token-for-property-check' });
      }
      const wrapped = wrapOctokitTiming(raw);
      process.stdout.write(JSON.stringify({
        requestHasEndpoint: typeof wrapped.request.endpoint === 'function',
        requestHasDefaults: typeof wrapped.request.defaults === 'function',
        issuesGetHasEndpoint: !!(wrapped.issues && wrapped.issues.get && typeof wrapped.issues.get.endpoint === 'function'),
        issuesGetHasDefaults: !!(wrapped.issues && wrapped.issues.get && typeof wrapped.issues.get.defaults === 'function'),
      }));
    })().catch(e => {
      process.stderr.write('Error: '+(e.message||String(e))+'\n');
      process.exitCode = 1;
    });
    break;
  }
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
      case 'title':     validateTitle(args[2]); break;
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
  case 'today':           renderToday(); break;
  case 'eisenhower':      eisenhower(); break;
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
  case 'api': {
    // 実行時間計測（Issue #455）。多くのハンドラはバリデーションエラー時に
    // throw ではなく process.exit(1) を直接呼ぶ（本ファイル全体の既存流儀）。
    // process.exit() は同期的に即座にプロセスを終了させるため、Promise チェーンの
    // .finally() は「スケジュールはされるが実行される前にプロセスが終了する」形で
    // 到達しないことを実装時に実機確認した（run done 番号なし 等で再現）。
    // 確実にあらゆる終了経路（正常終了・.catch()経由のエラー・process.exit()直接呼び出し）
    // で1回だけ出力するため、Promise ではなく process.on('exit', ...) を使う。
    // 'exit' ハンドラ内は同期処理のみ許容されるが、printTiming() は
    // hrtime.bigint()/配列演算/process.stderr.write() のみで完結し要件を満たす。
    const _timingStart = process.hrtime.bigint();
    if (TIMING_ENABLED) process.on('exit', () => printTiming(_timingStart));
    apiMain(args.slice(1)).catch(e => {
      // GitHub REST APIの401（認証拒否）はWeb環境等でGH_TOKENが使えないケースを示唆する（Issue #1695）
      if (e.status === 401) {
        process.stderr.write(t('error.gh_auth_rejected') + '\n' + t('error.mcp_fallback_guidance') + '\n');
      } else {
        process.stderr.write('Error: '+(e.message||String(e))+'\n');
      }
      process.exitCode = 1;
    });
    break;
  }

  // run サブコマンド（高レベルディスパッチャー）
  case 'run': {
    // 実行時間計測（Issue #455）。上記 'api' と同じ方針・同じ理由で process.on('exit') を使う。
    const _timingStart = process.hrtime.bigint();
    if (TIMING_ENABLED) process.on('exit', () => printTiming(_timingStart));
    runMain(args.slice(1)).catch(e => {
      // GitHub REST APIの401（認証拒否）はWeb環境等でGH_TOKENが使えないケースを示唆する（Issue #1695）
      if (e.status === 401) {
        process.stderr.write(t('error.gh_auth_rejected') + '\n' + t('error.mcp_fallback_guidance') + '\n');
      } else if (!e._msgWritten) {
        process.stderr.write('Error: '+(e.message||String(e))+'\n');
      }
      process.exitCode = 1;
    });
    break;
  }

  default:
    process.stderr.write('Unknown command: '+cmd+'\n');
    process.stderr.write('Usage: todo-engine.js <command> [args...]\n');
    process.exit(1);
}

// ─── run サブコマンド実装 ───────────────────────────────────────────────────

// ─── 実行時間計測（Issue #455） ───────────────────────────────────────────

// Octokit インスタンスの issues/search/request をラップし、各呼び出しの
// [開始ns, 終了ns] を timingIntervals へ記録する。TIMING_ENABLED が true の
// ときのみ initOctokit() から呼ばれる（false のときは octokit を素通しする
// ため、既存694件超のテストはこのコードパスに一切触れない）。
//
// 実装は Proxy の apply トラップを使う（素朴な `obj[key] = async (...a) => orig(...a)`
// による再代入ではない）。理由: 実 @octokit/rest の各メソッド（octokit.request だけで
// なく octokit.issues.get 等も同様）は .endpoint / .defaults という関数プロパティを
// own property として持ち、ライブラリ内部がこれらを参照する（実測: 2026-08-29）。
// 素朴な再代入では通常の関数オブジェクトに置き換わり .endpoint/.defaults が失われる
// ため、TODO_TIMING=1 で実 GitHub API を呼ぶと
// "octokit.request.defaults is not a function" 等で丸ごと機能停止した（実機で発覚・
// 修正。詳細は DEVELOPMENT.md 参照）。Proxy は元の関数オブジェクトそのものを
// ラップし apply（呼び出し）だけをフックするため、.endpoint/.defaults を含む
// 全プロパティが透過的に保持される。thisArg も Reflect.apply でそのまま転送する。
function wrapOctokitTiming(octokit) {
  function wrapMethod(obj, key) {
    const orig = obj[key];
    if (typeof orig !== 'function') return;
    obj[key] = new Proxy(orig, {
      apply(target, thisArg, argArray) {
        const start = process.hrtime.bigint();
        const result = Reflect.apply(target, thisArg, argArray);
        // orig は常に Promise を返す（Octokit のメソッドは全て async）。
        // .finally() は解決/拒否のいずれの結果もそのまま透過するため、
        // 呼び出し元から見た挙動（成功時の戻り値・失敗時の例外）は変化しない。
        return Promise.resolve(result).finally(() => {
          timingIntervals.push([start, process.hrtime.bigint()]);
        });
      },
    });
  }
  if (octokit.issues) {
    for (const key of Object.keys(octokit.issues)) wrapMethod(octokit.issues, key);
  }
  if (octokit.search) {
    for (const key of Object.keys(octokit.search)) wrapMethod(octokit.search, key);
  }
  wrapMethod(octokit, 'request');
  return octokit;
}

// 区間統合（interval merge）で GitHub 呼び出しの壁時計時間を算出する。
// 並行呼び出し（Promise.all）は重複区間を1回分に畳むため、常に
// total（case 'run'/'api' の計測区間）以下になる（parse が負値にならない
// ことの数学的保証）。intervals は [BigInt開始ns, BigInt終了ns] の配列。
function computeGithubMs(intervals) {
  if (!intervals.length) return 0;
  const sorted = intervals.slice().sort((a, b) => (a[0] < b[0] ? -1 : (a[0] > b[0] ? 1 : 0)));
  let mergedNs = 0n;
  let curStart = sorted[0][0], curEnd = sorted[0][1];
  for (let i = 1; i < sorted.length; i++) {
    const [s, e] = sorted[i];
    if (s <= curEnd) { if (e > curEnd) curEnd = e; }       // 重複 → 統合
    else { mergedNs += curEnd - curStart; curStart = s; curEnd = e; } // 非重複 → 確定して次へ
  }
  mergedNs += curEnd - curStart;
  return Number(mergedNs / 1000000n);
}

// [timing] 診断行をstderrへ出力する。t()/tpl() は通さず固定英語とする
// （DEVELOPMENT.md §翻訳方針の api/Usage: と同じ扱い。診断出力であり
// 一般ユーザー向け操作結果メッセージとは性質が異なるため）。
function printTiming(startNs) {
  const totalMs = Number((process.hrtime.bigint() - startNs) / 1000000n);
  const githubMs = computeGithubMs(timingIntervals);
  const parseMs = Math.max(0, totalMs - githubMs);
  process.stderr.write(`[timing] total ${totalMs}ms (github ${githubMs}ms / parse ${parseMs}ms)\n`);
}

// Octokit 初期化（apiMain から共通化）
async function initOctokit() {
  // ── テスト用シーム（Issue #1648）: OCTOKIT_STUB_ENV が設定されていればスタブ
  // Octokit ファクトリを読み込んで返す。トークン取得・実 @octokit/rest ロードより
  // 前に判定することで、テストがトークン不要で完結する。未設定時は以下の
  // 既存ロジックへそのまま進む（後方互換）。 ──
  const stubModulePath = process.env.OCTOKIT_STUB_ENV;
  if (stubModulePath) {
    const createStubOctokit = require(path.resolve(stubModulePath));
    const stubOctokit = createStubOctokit({
      logPath: process.env.OCTOKIT_STUB_LOG_ENV || null,
      responsesSpec: process.env.OCTOKIT_STUB_RESPONSES_ENV || null,
    });
    return TIMING_ENABLED ? wrapOctokitTiming(stubOctokit) : stubOctokit;
  }

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
  const realOctokit = new OctokitClass({ auth: token, log: OCTOKIT_LOGGER });
  return TIMING_ENABLED ? wrapOctokitTiming(realOctokit) : realOctokit;
}

// tokens のうち、allowedFlags に載っていないフラグ字面のトークンを先頭から探す。
// 判定に使う UNKNOWN_FLAG_RE はファイル冒頭の定数ブロックで定義している（TDZ 回避。理由は同所のコメント参照）。
// 見つかればそのトークン文字列、なければ null を返す（副作用なしの純粋関数）。
// allowedFlags: そのハンドラが parseArgs の後で自前に解釈するフラグの許可リスト。
//   runAdd（#1921 パターンA）は自前解釈するフラグを持たないため空配列を渡す。
//   runList のように extra から `--group` 等を自分で読むハンドラは、それらを許可リストに
//   載せて渡すこと（許可リストは parseArgs 内ではなく呼び出し側に置くのが正しい。
//   ハンドラごとに「extra に正当に残るフラグ」が異なるため）。
function findUnknownFlag(tokens, allowedFlags) {
  const allowed = allowedFlags || [];
  for (const tok of tokens) {
    if (UNKNOWN_FLAG_RE.test(tok) && allowed.indexOf(tok) < 0) return tok;
  }
  return null;
}

// /todo add の Usage 行（未知フラグ検出時に stderr へ出す）。
// DEVELOPMENT.md §翻訳方針「Usage: 文字列は常時英語で統一」に従い t() を通さない。
// 掲載範囲: runAdd が実際に参照するフラグのみを載せる。parseArgs は --actual / --note /
// --due-offset / --color も消費するが、runAdd はこの4つを一度も参照しない（値は黙って
// 捨てられる。#1921 第2弾の論点）。効かないフラグを Usage に載せると「効く」と誤解させる
// ため意図的に除外している。
const ADD_USAGE = 'Usage: /todo add [GTD] <title> [@ctx...] [#tag...] [--due <date>] [--desc <text>] '
                + '[--body "text"] [--body-file <path>] [--recur <pattern>] [--project <#>] '
                + '[--priority p1|p2|p3] [--p1|--p2|--p3] [--estimate <time>] [--label <name>] [--activate <date>] '
                + '[--before <duration>] [--depends-on <#>] [--resume-condition <text>]  (see: /todo help)';

// 汎用引数パーサー
// tokens: string[]
// 戻り値: { gtd, title, contexts, due, desc, recur, project, priority, estimate, actual, dueOffset, color, activate, before, dependsOn, note, extra }
function parseArgs(tokens) {
  const result = {
    gtd: null, title: null, contexts: [], tags: [], due: null, desc: null,
    recur: null, project: null, priority: null, estimate: null, actual: null,
    dueOffset: null, color: null, activate: null, before: null, dependsOn: null,
    resumeCondition: null, note: null,
    body: null, bodyFile: null,
    labels: [], extra: []
  };
  const remaining = [...tokens];

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
    } else if (/^--p[123]$/.test(tok)) {
      // --p1 / --p2 / --p3 ショートハンド（--priority p1 の省略形）
      result.priority = tok.slice(2); remaining.splice(i, 1); continue;
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
    } else if (tok === '--resume-condition' && i+1 < remaining.length) {
      result.resumeCondition = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--note' && i+1 < remaining.length) {
      result.note = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--body' && i+1 < remaining.length) {
      result.body = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--body-file' && i+1 < remaining.length) {
      result.bodyFile = remaining[i+1]; remaining.splice(i, 2); continue;
    } else if (tok === '--label' && i+1 < remaining.length) {
      result.labels.push(remaining[i+1]); remaining.splice(i, 2); continue;
    } else if (tok.startsWith('@')) {
      result.contexts.push(tok); remaining.splice(i, 1); continue;
    } else if (tok.startsWith('#') && !tok.includes(' ') && !/^#\d+$/.test(tok)) {
      // #tag: '#' + 文字を含む単語（空白を含まない） → 普通のタグ（#42 のような Issue番号は除外）
      // #1660: 空白を含む制約がないと、タイトル全体が1トークンで渡され「#」始まりの場合
      // （例: "#1299 depends-on強化について"）丸ごとタグ扱いされ、タイトルが空になってしまう
      result.tags.push(tok); remaining.splice(i, 1); continue;
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

// GitHub API が返す UTC ISO8601 タイムスタンプ（closedAt/updated_at 等、末尾 'Z'）を
// ローカルタイム基準の日付文字列（YYYY-MM-DD）に変換する。
// getToday() と同様、実行環境のローカルタイムが JST であることを前提とする
// （global-rules.md「日付・時刻はJST基準」運用、doneCount() の既存実装と同じ変換方式）。
// `.slice(0,10)` で直接日付化すると UTC 基準になり、JST 0〜9時台に完了したタスクが
// 前日扱いになる（Issue #1748）。表示・集計で closedAt/updatedAt を日付化する箇所は
// 必ずこのヘルパーを経由すること。
function toJstDateStr(isoString) {
  if (!isoString) return '';
  const d = new Date(isoString);
  if (isNaN(d.getTime())) return '';
  return [d.getFullYear(), String(d.getMonth()+1).padStart(2,'0'), String(d.getDate()).padStart(2,'0')].join('-');
}

// ラベルが存在しなければ作成する（Issue #1326: existence check で 422 ノイズを抑止）
// GET で存在確認 → 404 のときだけ createLabel を呼ぶ。
// 422 をキャッチする方式は @octokit/plugin-request-log が先に console.error を出力するため採用しない。
// TOCTOU 対策: GET と createLabel の間に別プロセスが作成した場合も 422 をサイレント化。
// 戻り値: 新規作成したとき true / 既存だったとき false（Issue #1686: 呼び出し側で通知を出すため）
async function ensureLabel(octokit, owner, repo, name, color, description) {
  try {
    await octokit.request('GET /repos/{owner}/{repo}/labels/{name}', { owner, repo, name });
    // 200: ラベル既存 → 何もしない
    return false;
  } catch(e) {
    if (e.status !== 404) throw e; // 404 以外（401/403/500 等）は真のエラーとして伝播
    // 404: 存在しない → 作成（TOCTOU 競合時の 422 はサイレント化）
    try {
      await octokit.issues.createLabel({ owner, repo, name, color: color||'FBCA04', description: description||'' });
      return true;
    } catch(ce) {
      if (ce.status !== 422) throw ce;
      return false; // 競合で別プロセスが作成済み → 新規作成の通知は出さない
    }
  }
}

// Issue を取得してフィールドを解析する
async function fetchAndParseIssue(octokit, owner, repo, num) {
  const { data: i } = await octokit.issues.get({ owner, repo, issue_number: num });
  const lnames = i.labels.map(l => l.name);
  const parsed = parseBodyObj(i.body || '');
  return {
    number: i.number, id: i.id, title: i.title, body: i.body || '',
    labels: lnames, state: i.state, closedAt: i.closed_at || null, ...parsed
  };
}

// ─── sub-issue ヘルパ（Phase 1 互換レイヤ） ───

// 親 Issue に子を sub-issue として登録
// 冪等: 422 を返した場合、GitHub のメッセージ文言は仕様として保証されないため
// e.message の部分一致では判定しない（#1879）。親の sub-issue 一覧を取得し直し、
// 子が実際に登録済みかで「既登録（冪等スキップ）」と「それ以外のエラー
// （別の親に登録済み・sub_issue_id 不正 等）」を区別する。
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
      const existing = await listSubIssues(octokit, owner, repo, parentNumber);
      const alreadyRegistered = existing.some(s => s.id === childInternalId);
      if (alreadyRegistered) {
        process.stderr.write(tpl('warn.sub_issue_skip', { parent: parentNumber })+'\n');
        return 'skipped';
      }
      process.stderr.write(tpl('warn.sub_issue_register_failed_422', { parent: parentNumber, msg: e.message })+'\n');
      return 'error';
    }
    process.stderr.write(tpl('warn.sub_issue_register_failed', { msg: e.message })+'\n');
    return 'error';
  }
}

// 親 Issue の sub-issue 一覧取得（ページング対応、#1881）。
// GitHub の現行仕様では sub-issue は「親1つにつき最大100件」（公式ドキュメント
// "Adding sub-issues" に明記。2026-08-23 確認）。したがって per_page:100 の
// 1ページで必ず全件取得でき、現時点でページングは実際には発火しない。
// それでもページングを実装しているのは、この上限が GitHub 側の仕様変更で
// 引き上げられたときに、黙って欠落しないようにするため（防御的実装）。
// この結果は addSubIssue の422判別・list project・weekly-project-audit・
// unlink の事前確認の4箇所が使うため、欠落するとどれも静かに誤動作する。
// fetchAllOpen（MAX_OPEN_ISSUES_LIMIT）と同型の構造にしてある。
//
// 取得失敗時のデフォルト挙動は既存仕様（[]を返す）を維持する。addSubIssue の
// 422判別・runList・runWeeklyProjectAudit の3箇所は「失敗時は空扱い」で実害が
// ない設計のためシグネチャは変更しない。runUnlink だけは「取得失敗」と
// 「本当に子0件」を区別する必要がある（#1885: 区別できないと --force 指定時に
// body だけ削除され、親子関係が残ったままになるデータ喪失経路が開く）。
// 呼び出し側で区別したい場合は { throwOnError: true } を渡すと、catch で
// []を返す代わりに例外を再送出する。
async function listSubIssues(octokit, owner, repo, parentNumber, opts = {}) {
  const { throwOnError = false } = opts;
  const all = [];
  let page = 1;
  try {
    while (all.length < MAX_SUB_ISSUES_LIMIT) {
      const { data } = await octokit.request('GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues', {
        owner, repo,
        issue_number: parentNumber,
        per_page: 100,
        page,
        headers: { 'X-GitHub-Api-Version': '2022-11-28' },
      });
      if (!data.length) break;
      all.push(...data);
      if (data.length < 100) break;
      page++;
    }
    if (all.length === MAX_SUB_ISSUES_LIMIT) {
      process.stderr.write(tpl('warn.sub_issue_list_limit', { parent: parentNumber, limit: MAX_SUB_ISSUES_LIMIT })+'\n');
    }
    return all;
  } catch (e) {
    // ページ2以降で失敗した場合、既に取得済みのページ分も含めて[]を返す
    // （部分結果を返すと呼び出し側が「全件取得できた」と誤認しうるため）。
    process.stderr.write(tpl('warn.sub_issue_list_failed', { msg: e.message })+'\n');
    if (throwOnError) throw e;
    return [];
  }
}

// sub-issue の関連を解除する（/todo unlink で使用）。
// addSubIssue と対称に、呼び出し側が成否を判定できるよう文字列ステータスを返す
// （#1880: 戻り値がなく呼び出し側が失敗を検知できず、body だけ消えるデータ喪失事故があった）。
async function removeSubIssue(octokit, owner, repo, parentNumber, childInternalId) {
  try {
    await octokit.request('DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue', {
      owner, repo,
      issue_number: parentNumber,
      data: { sub_issue_id: childInternalId },
      headers: { 'X-GitHub-Api-Version': '2022-11-28' },
    });
    return 'removed';
  } catch (e) {
    process.stderr.write(tpl('warn.sub_issue_unlink_failed', { msg: e.message })+'\n');
    return 'error';
  }
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

  // Issue #1921 パターンA: parseArgs が解釈できなかった `--` 始まりのトークンを
  // 黙ってタイトルへ連結しない（元の症状: `add next "設計書を書く" --boddy-file /tmp/x` が
  // タイトル「設計書を書く --boddy-file /tmp/x」の Issue を exit 0 で作っていた）。
  // 値が欠落した既知フラグ（末尾の `--due` 等。parseArgs の `i+1 < remaining.length`
  // 条件を満たさず extra に残る）もここで捕まる。
  // 検査位置の制約: (1) title_empty より前（原因に直結するメッセージを優先する）、
  // (2) ensureLabel（コンテキストラベル作成）より前＝バリデーションを API 副作用より前に置く。
  const unknownFlag = findUnknownFlag(parsed.extra, []);
  if (unknownFlag) {
    process.stderr.write(`${ADD_USAGE}\n`);
    process.stderr.write(tpl('error.unknown_flag', { flag: unknownFlag })+'\n');
    process.stderr.write(t('error.unknown_flag_hint')+'\n');
    process.exit(1);
  }

  // タイトル: 残りトークンを連結
  const titleTokens = parsed.extra.filter(s => s.trim());
  if (!titleTokens.length) {
    process.stderr.write(t('error.title_empty')+'\n'); process.exit(1);
  }
  const title = titleTokens.join(' ');
  validateTitle(title);

  // Outcome 警告（project タスクの場合）。日本語の「outcome」語尾パターンに加え、
  // 英語タイトル向けの outcome 表現パターンも判定する（Issue #1761 C2）。
  // English patterns (always checked regardless of LANG_ENV)。既存の英語パターン方針
  // （raw date 解析の「English patterns (always checked regardless of LANG_ENV)」）に倣う。
  if (gtd === PROJECT_LABEL) {
    const outcomePattern = /（している|できている|完了|終了|リリース|公開|決まった|した状態）$|している$|できている$|完了$|終了$|リリース$|公開$|決まった$|した状態$/;
    const outcomePatternEn = /\(?(has been completed|is completed|is done|is released|is published|is finished|is live|is in place)\)?$/i;
    if (!outcomePattern.test(title) && !outcomePatternEn.test(title)) {
      process.stderr.write(t('hint.project_outcome')+'\n');
    }
  }

  // due 正規化（normalizeDue が M/D → YYYY-MM-DD も処理する）
  let due = parsed.due ? normalizeDue(parsed.due, today) : '';
  if (due) validateDue(due);

  if (parsed.recur) validateRecur(parsed.recur);
  if (parsed.project) validateNumber(parsed.project);
  for (const ctx of parsed.contexts) validateCtx(ctx.slice(1));
  for (const tag of parsed.tags) validateTag(tag.slice(1));
  const priority = parsed.priority || 'p3';
  validatePriority(priority);
  let estimateMin = null;
  if (parsed.estimate) {
    estimateMin = parseTime(parsed.estimate);
    if (estimateMin === null) { process.stderr.write(t('error.time_format')+'\n'); process.exit(1); }
  }
  // resume_condition バリデーション（改行混入のみ禁止）。ラベル作成等の副作用より前に検証する。
  if (parsed.resumeCondition) validateResumeCondition(parsed.resumeCondition);

  const labels = [GTD_DISPLAY[gtd]];
  // コンテキストラベル作成
  for (const ctx of parsed.contexts) {
    await ensureLabel(octokit, owner, repo, ctx, 'FBCA04', t('label.desc_context'));
    labels.push(ctx);
  }
  // タグラベル作成（#tag: 色 0075CA でコンテキストと区別）
  for (const tag of parsed.tags) {
    await ensureLabel(octokit, owner, repo, tag, '0075CA', t('label.desc_tag'));
    labels.push(tag);
  }
  // 優先度ラベル作成
  const pcolor = priorityColor(priority);
  await ensureLabel(octokit, owner, repo, priority, pcolor, t('label.desc_priority'));
  labels.push(priority);
  // --label オプションで指定された追加ラベル
  for (const lbl of parsed.labels) {
    await ensureLabel(octokit, owner, repo, lbl, 'EDEDED', '');
    labels.push(lbl);
  }

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
      // normalizeDue が M/D → YYYY-MM-DD も処理する
      activateRaw = normalizeDue(activateRaw, today);
      if (!activateRaw) {
        process.stderr.write(t('error.date_format') + ': ' + parsed.activate + '\n');
        process.exit(1);
      }
      // 形式チェックに加え、実在するカレンダー日付かを検証する（Issue #1803）
      validateActivateFormat(activateRaw, parsed.activate);
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

  // --body / --body-file: ユーザー提供の本文（--body-file 優先）
  let userBody = '';
  if (parsed.bodyFile) {
    const resolvedPath = path.resolve(parsed.bodyFile);
    if (!fs.existsSync(resolvedPath)) {
      process.stderr.write(tpl('error.body_file_not_found', { path: resolvedPath })+'\n');
      process.exit(1);
    }
    try {
      userBody = fs.readFileSync(resolvedPath, 'utf8');
    } catch (e) {
      process.stderr.write(tpl('error.body_file_read_failed', { msg: e.message })+'\n');
      process.exit(1);
    }
  } else if (parsed.body !== null) {
    userBody = parsed.body;
  }

  const metaBody = buildBody({
    due,
    recur:     parsed.recur     || '',
    project:   parsed.project   || '',
    estimate:  estimateMin !== null ? String(estimateMin) : '',
    desc:      parsed.desc      || '',
    activate,
    before:    beforeStr,
    dependsOn: parsed.dependsOn || '',
    resumeCondition: parsed.resumeCondition || '',
  });
  // メタデータ本文とユーザー本文を結合（両方ある場合は空行で区切る）
  const body = metaBody && userBody ? metaBody + '\n' + userBody
             : metaBody || userBody;

  const { data } = await octokit.issues.create({ owner, repo, title, body, labels });
  const labelStr = labels.join(', ');
  let createdMsg = tpl('add.created_header', { num: data.number })
    + '\n' + tpl('add.title_line', { title })
    + '\n' + tpl('add.labels_line', { labels: labelStr });
  if (due) createdMsg += '\n' + tpl('add.due_line', { due });
  if (activate) createdMsg += '\n' + tpl('add.activate_line', { activate });
  createdMsg += '\n' + tpl('add.url_line', { url: data.html_url });
  runOut(createdMsg);

  // sub-issue 登録（--project N 指定時）
  if (parsed.project) {
    const parentNum = parseInt(parsed.project);
    let parentIssue;
    try {
      parentIssue = await fetchAndParseIssue(octokit, owner, repo, parentNum);
    } catch (e) {
      process.stderr.write(tpl('warn.project_fetch_failed', { num: parentNum, msg: e.message })+'\n');
      return;
    }
    const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
    if (!isProject) {
      process.stderr.write(tpl('error.not_a_project', { num: parentNum })+'\n');
      process.exit(1);
    }
    await addSubIssue(octokit, owner, repo, parentNum, data.id);
  }
}

async function runList(octokit, owner, repo, tokens) {
  const jsonMode = tokens.includes('--json');
  const tokens2 = tokens.filter(t => t !== '--json');

  const today = getToday();
  const parsed = parseArgs(tokens2);
  const extra = parsed.extra;

  // フィルタ判定
  let filterGtd = '', filterCtx = '', filterTag = '', filterPri = '', filterProj = '';
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
    else if (tok.startsWith('#') && !/^#\d+$/.test(tok)) {
      // #tag フィルタ（#42 のような Issue番号は除外）
      validateTag(tok.slice(1)); filterTag = tok;
    }
    else if (tok === PROJECT_LABEL) {
      // /todo list project N → sub-issue API 経由で子一覧表示
      const n = extra[i+1];
      if (n && /^\d+$/.test(n)) { validateNumber(n); listProjectNum = n; i++; }
      else { filterGtd = PROJECT_LABEL; }
    }
  }
  for (const ctx of parsed.contexts) { validateCtx(ctx.slice(1)); filterCtx = ctx; }
  for (const tag of parsed.tags) { validateTag(tag.slice(1)); filterTag = tag; }

  // /todo list project N → sub-issue API + body メタ OR で子一覧表示（--json 非対応）
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
    w(tpl('list.project_children_header', { parent: parentNum, n: children.length })+'\n');
    if (!children.length) {
      w(t('list.no_children')+'\n');
    } else {
      for (const issue of children) { w(renderIssueList(issue, today)+'\n'); }
    }
    return;
  }

  // API取得
  const allIssues = await fetchAllOpen(octokit, owner, repo);

  // --json モード: フィルタ後に JSON 配列を出力
  // #1846: 人間向けの list project は「休止中」（🌈 someday 併記）の project を除外するが、
  // --json はあえて除外しない。JSON は他プログラムが消費する機械可読インターフェースであり、
  // どの Issue を「表示しないか」は UI の関心事（人間の注意を節約する）であって、
  // データそのものを間引く理由にはならない。各要素の `labels` フィールドに既に
  // 'project' と 'someday' の両方が含まれるため、休止中判定は
  // `labels.includes('someday')` で消費側が自分で行える（新規フィールド追加は不要）。
  // 関連リポジトリを検索した限り `list project --json` の
  // 既存消費者は見つからなかった（後方互換の実害なし）。
  if (jsonMode) {
    let filtered = allIssues;
    if (filterGtd) filtered = filtered.filter(i => i.labels.map(l => normLabel(l.name)).includes(filterGtd));
    if (filterCtx) filtered = filtered.filter(i => i.labels.map(l => l.name).includes(filterCtx));
    if (filterTag) filtered = filtered.filter(i => i.labels.map(l => l.name).includes(filterTag));
    if (filterPri) filtered = filtered.filter(i => i.labels.map(l => normLabel(l.name)).includes(filterPri));
    filtered.sort(sortByPriDue);
    runOut(JSON.stringify(filtered.map(issueToJsonObj), null, 2));
    return;
  }

  const env = { OPEN_ENV: JSON.stringify(allIssues), TODAY_ENV: today };
  if (filterGtd) env.FILTER_GTD_ENV = filterGtd;
  if (filterCtx) env.FILTER_CTX_ENV = filterCtx;
  if (filterTag) env.FILTER_TAG_ENV = filterTag;
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
  while (allIssues.length < MAX_OPEN_ISSUES_LIMIT) {
    const { data } = await octokit.issues.listForRepo({ owner, repo, state: 'open', per_page: 100, page });
    const issues = data.filter(i => !i.pull_request);
    if (!issues.length) break;
    // #1879: id（database ID）を含める。sub-issue 登録（addSubIssue）が
    // childInternalId として使うため必須。issueToJsonObj() は明示ホワイトリストで
    // フィールドを組み立てるため、ここに id を足しても list --json 等の出力には漏れない。
    allIssues.push(...issues.map(i => ({ number: i.number, id: i.id, title: i.title, body: i.body||'', labels: i.labels.map(l => ({name:l.name})), closedAt: null, updated_at: i.updated_at || '' })));
    if (data.length < 100) break;
    page++;
  }
  if (allIssues.length === MAX_OPEN_ISSUES_LIMIT) {
    process.stderr.write(tpl('warn.open_issue_limit', { limit: MAX_OPEN_ISSUES_LIMIT })+'\n');
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

// close 後の共通後処理（recur再作成 + depends_on昇格 + プロジェクト昇格候補ヒント）
// runDone（単体完了）と runBulk の done 分岐（一括完了）の両方から呼ばれる。
// #1642: bulk done がこの後処理をスキップしていたため、リカレンス付きIssueを
// bulk done に含めると周期チェーンが無言で途切れるデータ損失バグがあった。
// #1652: create-before-close — リカレンス次周期Issueの作成は必ずcloseより「前」に呼ぶこと。
// close→create の順（旧実装）だとcreate失敗時に次周期Issueが永久に失われるため、
// 呼び出し順をcreate→closeへ入れ替えた（postDoneProcessingから本関数として分離）。
// 分離時の設計判断: 本関数はrecur再作成のみを担う。postDoneProcessing側に残した
// depends_on昇格・project昇格ヒントはfetchAllOpen（オープンIssue一覧取得）に依存しており、
// closeより前に呼ぶと完了中のIssue自身がまだopenのため一覧に混入し、
// 「自分自身を次タスク候補として提示する」誤動作を起こす。そのため分離を「recur再作成のみ
// close前に前倒し」に留め、depends_on昇格・project昇格ヒントは従来どおりclose後のまま維持した。
async function createRecurIssue(octokit, owner, repo, issue) {
  const today = getToday();
  let recurLine = null;
  let newIssueNumber = null;

  if (issue.recur) {
    validateRecur(issue.recur);
    const base = issue.due || today;
    const { nextDate, skipped } = nextDueCatchUp(issue.recur, base, today);
    // beforeがあればactivateを再計算
    let nextActivate = '';
    const nextBefore = issue.before || '';
    if (nextBefore) {
      const days = parseBeforeDuration(nextBefore);
      if (days !== null) nextActivate = addDays(nextDate, -days);
    }
    // 繰り返しタスク再作成時はreviewed_atを空に（新サイクル開始）
    //
    // depends_on / resume_condition も意図的に引き継がない（Issue #1890 で検証・確定、2026-08-24）。
    // - depends_on: 依存先タスクは完了済みのはず（depends_on 昇格ロジックがそれを前提にしている）。
    //   次周期へ引き継ぐと「既にクローズされた Issue への依存」になり不整合を生む。
    // - resume_condition: `/todo promote` の自動昇格を抑止するためのフィールド（Issue #1299 由来）。
    //   「条件が満たされるまで再開しない」という保留の意味を持つため、周期が来たら必ず実行する
    //   recur とは意味論が相容れない。
    // 実データでも裏付け済み: Issue 400件を走査して recur との併用は0件だった
    //   （recur 32件 / depends_on 4件 / resume_condition 5件、重複なし）。
    const body = buildBody({
      due:      nextDate,
      recur:    issue.recur,
      project:  issue.project,
      estimate: issue.estimate,
      desc:     issue.desc,
      activate: nextActivate,
      before:   nextBefore,
    });
    const { data: newIssue } = await octokit.issues.create({
      owner, repo, title: issue.title,
      body, labels: issue.labels
    });
    newIssueNumber = newIssue.number;
    recurLine = tpl('done.recur_created', { num: newIssue.number, date: nextDate });
    if (nextActivate) recurLine += tpl('done.recur_activate_note', { activate: nextActivate });
    if (skipped) recurLine += '\n' + tpl('done.recur_skip_note', { base, date: nextDate });
  }

  return { recurLine, newIssueNumber };
}

// depends_on 昇格チェックおよびプロジェクト昇格候補ヒント。
// #1652: 必ずclose「後」に呼ぶこと。fetchAllOpenで完了直後のIssue自身が
// まだopenのまま候補に混入するのを避けるため（createRecurIssue側のコメント参照）。
async function postDoneProcessing(octokit, owner, repo, num, issue) {
  const otherLines = [];

  // #1660: depends_on 昇格は「完了した Issue を他のオープン Issue が依存先にしているか」を
  // 判定する処理であり、完了した Issue 自身の project/dependsOn フィールドとは論理的に無関係。
  // そのためガードなしで常に fetchAllOpen を実行し、依存関係を確認する
  // （#1299 が #1275 完了後に昇格しなかった不具合の修正）。
  {
    const allOpenIssues = await fetchAllOpen(octokit, owner, repo);

    // depends_on: #N 昇格トリガー — 完了した Issue を依存先とするオープン Issue を next に昇格
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
          await removeLabelIfPresent(octokit, owner, repo, raw.number, gtdLabel);
        }
        await octokit.issues.addLabels({ owner, repo, issue_number: raw.number, labels: [nextLabel] });
        otherLines.push(tpl('promote.promoted_depends', { num: raw.number, title: raw.title, dep: num }));
        promoted++;
      }
      if (promoted > 0) otherLines.push(tpl('promote.summary', { n: promoted }));
    }

    // プロジェクト次タスク昇格候補ヒント — 完了タスクのプロジェクトに紐づくオープンタスクのうち昇格候補を表示
    // issue.project がない場合はスキップ（depends_on のみで入ったケースを除外）
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
        otherLines.push(tpl('done.promote_hint_header', { proj: projNum, title: projTitle }));
        candidates.forEach((c, idx) => {
          const gtdDisplay = GTD_DISPLAY[c.gtd] || c.gtd;
          otherLines.push(tpl('done.promote_hint_item', { i: idx + 1, num: c.num, title: c.title, gtd: gtdDisplay }));
        });
        otherLines.push(t('done.promote_hint_footer'));
      }
    } // end if (issue.project)
  }

  return { otherLines };
}

async function runDone(octokit, owner, repo, tokens) {
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
    const body = buildBody({ ...issue, actual });
    await octokit.issues.update({ owner, repo, issue_number: num, body });
  }

  // #1652: create-before-close — 次周期Issueの作成をcloseより先に行う（詳細はcreateRecurIssue定義部のコメント参照）
  const { recurLine, newIssueNumber } = await createRecurIssue(octokit, owner, repo, issue);
  try {
    await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });
  } catch (e) {
    if (newIssueNumber) {
      throw apiErr(tpl('error.close_failed_after_recur', { num, newNum: newIssueNumber, msg: e.message }));
    }
    throw e;
  }

  const { otherLines } = await postDoneProcessing(octokit, owner, repo, num, issue);
  if (recurLine) {
    runOut(tpl('done.completed', { num }) + recurLine);
  } else {
    runOut(tpl('done.completed', { num }));
  }
  otherLines.forEach(line => runOut(line));

  // --note が指定されていれば close 後にコメントを追加（直列処理）
  if (parsed.note) {
    await createCommentSanitized(octokit, owner, repo, num, parsed.note);
    runOut(tpl('comment.added', { num }));
  }
}

async function execMoveGtd(octokit, owner, repo, num, target) {
  if (target === PROJECT_LABEL) {
    throw apiErr(t('error.move_to_project_forbidden'));
  }
  if (!GTD_LABELS.includes(target)) {
    throw apiErr(tpl('error.gtd_label_required', { labels: GTD_LABELS.join('/') }));
  }
  const { data: issue } = await octokit.issues.get({ owner, repo, issue_number: num });
  const labelNames = issue.labels.map(l => l.name);
  const oldGtdLabel = labelNames.find(l => GTD_LABELS.includes(normLabel(l)));
  const newLabel = GTD_DISPLAY[target];
  if (oldGtdLabel && oldGtdLabel !== newLabel) {
    await removeLabelIfPresent(octokit, owner, repo, num, oldGtdLabel);
  }
  await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [newLabel] });
  return newLabel;
}

// 単一ラベルを冪等に削除する（404: ラベル未付与は正常とみなし無視）
async function removeLabelIfPresent(octokit, owner, repo, issue_number, name) {
  try {
    await octokit.issues.removeLabel({ owner, repo, issue_number, name });
  } catch (e) {
    if (e.status !== 404) throw e;
  }
}

async function execRemoveLabels(octokit, owner, repo, num, labels) {
  for (const label of labels) {
    await removeLabelIfPresent(octokit, owner, repo, num, label);
  }
}

async function runMove(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const target = tokens[1];
  if (!num || !target) { process.stderr.write('Usage: run move <number> <GTD>\n'); process.exit(1); }
  validateNumber(String(num));
  // --note オプションを取り出す（残りのトークンから解析）
  const parsed = parseArgs(tokens.slice(2));
  const noteText = parsed.note || null;
  const newLabel = await execMoveGtd(octokit, owner, repo, num, target);
  runOut(tpl('move.done', { num, label: newLabel }));
  // --note が指定されていればコメントを追加（GTDラベル変更後）
  if (noteText) {
    await createCommentSanitized(octokit, owner, repo, num, noteText);
    runOut(tpl('comment.added', { num }));
  }
}

// コメント本文をサニタイズして投稿する（runComment / runDone / runMove 共通）
async function createCommentSanitized(octokit, owner, repo, num, rawText) {
  // \r\n → \n, 残存 \r → \n に正規化（Windows環境での既知問題対策）
  let body = rawText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  // NULL バイト・制御文字（\x00-\x1F、\n 除く）を除去
  body = body.replace(/[\x00-\x09\x0B-\x1F]/g, '');
  if (body.length > 65536) {
    process.stderr.write(tpl('error.comment_too_long', { n: body.length })+'\n');
    process.exit(1);
  }
  if (!body.trim()) {
    process.stderr.write(t('error.comment_empty')+'\n');
    process.exit(1);
  }
  await octokit.issues.createComment({ owner, repo, issue_number: num, body });
}

// comment コマンド: 任意タイミングの独立コメント追加
//
// #1919: 以前は tokens[1] だけを本文として読み、tokens[2] 以降を無条件に捨てていた。
// このため `comment <#> --body-file <path>` を渡すと「--body-file」という文字列
// そのものが本文として投稿され、<path> は黙って失われた（エラーなし・exit 0）。
// 本実装は --body / --body-file（runAdd と同じ --body-file 優先）に対応しつつ、
// 未知の `--` フラグ（値欠落を含む）は黙って本文へ混入させずエラー終了する。
//
// #1919 追補（実測 2026-08-29）: 当初 `tok.startsWith('--')` を丸ごとエラー扱いに
// していたところ、Markdown水平線（`--- 区切り線 ---`）や「--body を説明する文章」のような
// 正当な本文まで弾いてしまう副作用が発覚した。フラグの字面（1語・英字始まり）だけを
// 未知フラグとして扱うよう UNKNOWN_FLAG_RE で判定を絞り込んだ。
async function runComment(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));

  const rest = tokens.slice(1);
  const usage = 'Usage: /todo comment <#> <text> | --body "text" | --body-file <path>';
  // 未知フラグ候補の判定はモジュールスコープの UNKNOWN_FLAG_RE（ファイル冒頭の定数ブロックで定義）を使う。
  // フラグの字面（`--` + 英字始まり + 英数字/ハイフンのみの1語）のみを対象とし、
  // 空白・全角文字・"--" の直後がハイフン等（Markdown水平線 "---" 等）は本文として扱う。
  // （#1921 で runAdd と共通化した。判定内容・出力は #1919 当時のローカル定数版と同一）

  // --body / --body-file を走査しつつ、未知の `--` フラグを検出する。
  // 単一ハイフン始まりの本文（例: "- 箇条書き"）はここでは対象外（`--` 判定のみ）。
  let bodyOpt = null, bodyFileOpt = null;
  for (let i = 0; i < rest.length; i++) {
    const tok = rest[i];
    if (tok === '--body' && i + 1 < rest.length) {
      bodyOpt = rest[i + 1]; i++;
    } else if (tok === '--body-file' && i + 1 < rest.length) {
      bodyFileOpt = rest[i + 1]; i++;
    } else if (UNKNOWN_FLAG_RE.test(tok)) {
      // 未知のフラグ、または値が欠落した既知フラグ（末尾の --body-file 等）。
      // ここで本文へ連結せず即エラー終了する（#1919 の再発防止の核）。
      process.stderr.write(`${usage}\nError: unknown flag: ${tok}\n`);
      process.exit(1);
    }
  }

  let text;
  if (bodyFileOpt !== null) {
    // --body-file 優先（runAdd と同じ挙動・同じエラーメッセージを再利用）
    const resolvedPath = path.resolve(bodyFileOpt);
    if (!fs.existsSync(resolvedPath)) {
      process.stderr.write(tpl('error.body_file_not_found', { path: resolvedPath })+'\n');
      process.exit(1);
    }
    try {
      text = fs.readFileSync(resolvedPath, 'utf8');
    } catch (e) {
      process.stderr.write(tpl('error.body_file_read_failed', { msg: e.message })+'\n');
      process.exit(1);
    }
  } else if (bodyOpt !== null) {
    text = bodyOpt;
  } else {
    // 従来形式: 位置引数（Claudeが単一トークンとして渡す。#1919 以前と同じ挙動を維持）
    text = rest[0] || '';
  }

  if (!text.trim()) {
    process.stderr.write(`${usage}\n`);
    process.exit(1);
  }
  await createCommentSanitized(octokit, owner, repo, num, text);
  runOut(tpl('comment.added', { num }));
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
  let resumeCondition = issue.resumeCondition || '';
  let dueChanged = false;

  if (parsed.due !== null) {
    if (parsed.due === 'clear' || parsed.due === '') {
      // clear または空文字 → 期日削除
      due = ''; changed.push('due → '+t('edit.clear')); dueChanged = true;
    } else {
      // normalizeDue が M/D → YYYY-MM-DD も処理する
      due = normalizeDue(parsed.due, today);
      validateDue(due); changed.push('due → '+due); dueChanged = true;
    }
  }
  if (parsed.recur !== null) {
    if (parsed.recur === 'clear') { recur = ''; changed.push('recur → '+t('edit.clear')); }
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
      beforeStr = ''; activate = ''; changed.push('before → '+t('edit.clear'));
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
      activate = ''; beforeStr = ''; changed.push('activate → '+t('edit.clear'));
    } else {
      // normalizeDue が M/D → YYYY-MM-DD も処理する
      let activateRaw = normalizeDue(parsed.activate, today);
      if (!activateRaw) {
        process.stderr.write(t('error.date_format') + ': ' + parsed.activate + '\n');
        process.exit(1);
      }
      // 形式チェックに加え、実在するカレンダー日付かを検証する（Issue #1803）
      validateActivateFormat(activateRaw, parsed.activate);
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
      changed.push(t('edit.field_activate_recalc')+' → '+activate);
    }
  }

  // depends_on 編集
  if (parsed.dependsOn !== null) {
    if (parsed.dependsOn === 'clear') {
      dependsOn = ''; changed.push('depends_on → '+t('edit.clear'));
    } else {
      validateNumber(parsed.dependsOn);
      dependsOn = parsed.dependsOn; changed.push('depends_on → #'+dependsOn);
    }
  }

  // resume_condition 編集
  if (parsed.resumeCondition !== null) {
    if (parsed.resumeCondition === 'clear') {
      resumeCondition = ''; changed.push('resume_condition → '+t('edit.clear'));
    } else {
      validateResumeCondition(parsed.resumeCondition);
      resumeCondition = parsed.resumeCondition; changed.push('resume_condition → '+resumeCondition);
    }
  }

  const body = buildBody({
    ...issue,
    due, recur, project, estimate, desc, activate,
    before: beforeStr,
    dependsOn,
    resumeCondition,
  });
  const updateParams = { owner, repo, issue_number: num, body };

  // priority 変更
  if (parsed.priority !== null) {
    // #1652: validate-before-mutate — 旧priorityラベルを削除する前にparsed.priorityを検証する。
    // 逆順だとtypo時に旧ラベルだけ削除された中途半端な状態でエラー終了してしまう。
    if (parsed.priority !== 'clear') validatePriority(parsed.priority);
    const oldPri = issue.labels.find(l => /^p[123]$/.test(l));
    if (oldPri) {
      await removeLabelIfPresent(octokit, owner, repo, num, oldPri);
    }
    if (parsed.priority === 'clear') {
      changed.push('priority → '+t('edit.clear'));
    } else {
      const pcolor = priorityColor(parsed.priority);
      await ensureLabel(octokit, owner, repo, parsed.priority, pcolor, t('label.desc_priority'));
      await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [parsed.priority] });
      changed.push('priority → '+parsed.priority);
    }
  }

  await octokit.issues.update(updateParams);
  runOut(tpl('edit.updated', { num, changed: changed.join(', ') }));
}

async function runDue(octokit, owner, repo, tokens) {
  const today = getToday();
  const num = parseInt(tokens[0]);
  const rawDue = tokens[1];
  if (!num || rawDue === undefined) { process.stderr.write('Usage: run due <number> <date|clear>\n'); process.exit(1); }
  validateNumber(String(num));

  // clear または空文字 → 期日削除
  if (rawDue === 'clear' || rawDue === '') {
    const issue = await fetchAndParseIssue(octokit, owner, repo, num);
    const body = buildBody({ ...issue, due: '' });
    await octokit.issues.update({ owner, repo, issue_number: num, body });
    runOut(tpl('due.cleared', { num }));
    return;
  }

  // normalizeDue が M/D → YYYY-MM-DD も処理する
  const due = normalizeDue(rawDue, today);
  validateDue(due);

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const body = buildBody({ ...issue, due });
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(tpl('due.set', { num, due }));
}

async function runDesc(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));

  const newText = tokens.slice(1).join(' ');
  if (!newText.trim()) {
    process.stderr.write(t('error.desc_required')+'\n');
    process.exit(1);
  }

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const desc = issue.desc ? `${issue.desc}\n${newText}` : newText;
  const body = buildBody({ ...issue, desc });
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(tpl('desc.appended', { num }));
}

async function runRecur(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const pattern = tokens[1];
  if (!num || !pattern) { process.stderr.write('Usage: run recur <number> <pattern|clear>\n'); process.exit(1); }
  validateNumber(String(num));
  let recur = '';
  if (pattern !== 'clear') { validateRecur(pattern); recur = pattern; }

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const body = buildBody({ ...issue, recur });
  await octokit.issues.update({ owner, repo, issue_number: num, body });
  runOut(recur ? tpl('recur.set', { num, recur }) : tpl('recur.cleared', { num }));
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
    process.stderr.write(tpl('error.project_fetch_failed', { num: proj, msg: e.message })+'\n');
    process.exit(1);
  }
  const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
  if (!isProject) {
    process.stderr.write(tpl('error.not_a_project', { num: proj })+'\n');
    process.exit(1);
  }

  // body の project: #N メタ行を更新（従来処理）
  const body = buildBody({ ...issue, project: String(proj) });
  await octokit.issues.update({ owner, repo, issue_number: num, body });

  // sub-issue も登録（Phase 1 互換レイヤ）
  await addSubIssue(octokit, owner, repo, proj, issue.id);

  runOut(tpl('link.linked', { num, proj }));
}

async function runRename(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const newTitle = tokens.slice(1).join(' ');
  if (!num || !newTitle) { process.stderr.write('Usage: run rename <number> <new-title>\n'); process.exit(1); }
  validateNumber(String(num)); validateTitle(newTitle);
  await octokit.issues.update({ owner, repo, issue_number: num, title: newTitle });
  runOut(tpl('rename.done', { num, title: newTitle }));
}

async function runPriority(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  const level = tokens[1];
  if (!num || !level) { process.stderr.write('Usage: run priority <number> <p1|p2|p3|clear>\n'); process.exit(1); }
  validateNumber(String(num));
  // #1652: validate-before-mutate — 旧priorityラベルを削除する前にlevelを検証する。
  // 逆順だとtypo時に旧ラベルだけ削除された中途半端な状態でエラー終了してしまう。
  if (level !== 'clear') validatePriority(level);

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);
  const oldPri = issue.labels.find(l => /^p[123]$/.test(l));
  if (oldPri) {
    await removeLabelIfPresent(octokit, owner, repo, num, oldPri);
  }
  if (level === 'clear') {
    runOut(tpl('priority.cleared', { num }));
  } else {
    const pcolor = priorityColor(level);
    await ensureLabel(octokit, owner, repo, level, pcolor, t('label.desc_priority'));
    await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [level] });
    runOut(tpl('priority.set', { num, level }));
  }
}

// @ctx / #tag トークンを正規化してラベルリストを作る
// - '@' で始まる → コンテキスト（プレフィックスなしの場合は '@' を付与）
// - '#' で始まる → タグ（プレフィックスなしかつ数字のみでない場合は '#' を付与）
function normalizeTagTokens(rawTokens) {
  return rawTokens.map(s => {
    if (s.startsWith('@')) return s;
    if (s.startsWith('#')) return s;
    // '-' 始まりはオプション指定の渡し間違い（'--' 区切り等）とみなして拒否する。
    // 以前はコンテキストとして '@--' に正規化され、不正ラベルが新規作成されていた（Issue #1686）
    if (s.startsWith('-')) {
      process.stderr.write(tpl('error.option_like_token', { token: s })+'\n');
      process.exit(1);
    }
    // '@' も '#' もない → コンテキストとして扱う（後方互換）
    return '@'+s;
  });
}

// @ctx ラベルを全タスク横断でリネームする（label rename / tag rename で共用。Issue #1644）
async function renameCtxLabel(octokit, owner, repo, raw1, raw2, usage) {
  if (!raw1 || !raw2) { process.stderr.write(`Usage: ${usage}\n`); process.exit(1); }
  const oldName = raw1.startsWith('@') ? raw1 : '@'+raw1;
  const newName = raw2.startsWith('@') ? raw2 : '@'+raw2;
  validateCtx(oldName.slice(1)); validateCtx(newName.slice(1));
  await ensureLabel(octokit, owner, repo, newName, 'FBCA04', t('label.desc_context'));
  const allIssues = await fetchAllOpen(octokit, owner, repo);
  const targets = allIssues.filter(i => i.labels.some(l => l.name === oldName));
  for (const i of targets) {
    await octokit.issues.addLabels({ owner, repo, issue_number: i.number, labels: [newName] });
    await removeLabelIfPresent(octokit, owner, repo, i.number, oldName);
  }
  try { await octokit.issues.deleteLabel({ owner, repo, name: oldName }); } catch(e) { if (e.status !== 404) throw e; }
  runOut(tpl('label.renamed', { old: oldName, new: newName, n: cnt(targets.length) }));
}

async function runTag(octokit, owner, repo, tokens) {
  if (tokens[0] === 'rename') {
    return await renameCtxLabel(octokit, owner, repo, tokens[1], tokens[2], '/todo tag rename <old> <new>');
  }
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));
  const labelList = normalizeTagTokens(tokens.slice(1));
  if (!labelList.length) { process.stderr.write('Usage: run tag <number> @ctx/#tag ...\n'); process.exit(1); }
  for (const lbl of labelList) {
    let created;
    if (lbl.startsWith('#')) {
      validateTag(lbl.slice(1));
      created = await ensureLabel(octokit, owner, repo, lbl, '0075CA', t('label.desc_tag'));
    } else {
      validateCtx(lbl.slice(1));
      created = await ensureLabel(octokit, owner, repo, lbl, 'FBCA04', t('label.desc_context'));
    }
    // 既存ラベルに無い名前は打ち間違いの可能性があるため明示する（Issue #1686）
    if (created) runOut(tpl('label.created', { name: lbl }));
  }
  await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: labelList });
  runOut(tpl('tag.added', { num, labels: labelList.join(' ') }));
}

async function runUntag(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write(t('error.positive_int')+'\n'); process.exit(1); }
  validateNumber(String(num));
  const labelList = normalizeTagTokens(tokens.slice(1));
  if (!labelList.length) { process.stderr.write('Usage: run untag <number> @ctx/#tag ...\n'); process.exit(1); }
  for (const lbl of labelList) {
    if (lbl.startsWith('#')) { validateTag(lbl.slice(1)); }
    else { validateCtx(lbl.slice(1)); }
  }
  await execRemoveLabels(octokit, owner, repo, num, labelList);
  runOut(tpl('tag.removed', { num, labels: labelList.join(' ') }));
}

async function runLabel(octokit, owner, repo, tokens) {
  const sub = tokens[0];
  if (sub === 'list') {
    const { data } = await octokit.issues.listLabelsForRepo({ owner, repo, per_page: 100 });
    const ctxLabels = data.filter(l => l.name.startsWith('@'));
    if (!ctxLabels.length) { runOut(t('label.list_empty')); return; }
    for (const l of ctxLabels) runOut(`  ${l.name}  #${l.color}  ${l.description||''}`);
  } else if (sub === 'add') {
    const raw1 = tokens[1];
    if (!raw1) { process.stderr.write('Usage: /todo label add <name> [--color hex]\n'); process.exit(1); }
    const name = raw1.startsWith('@') ? raw1 : '@'+raw1;
    const parsed = parseArgs(tokens.slice(2));
    validateCtx(name.slice(1));
    const color = parsed.color || 'FBCA04';
    if (parsed.color) validateColor(parsed.color);
    await ensureLabel(octokit, owner, repo, name, color, t('label.desc_context'));
    runOut(tpl('label.created_named', { name }));
  } else if (sub === 'delete') {
    const raw1 = tokens[1];
    if (!raw1) { process.stderr.write('Usage: /todo label delete <name>\n'); process.exit(1); }
    const name = raw1.startsWith('@') ? raw1 : '@'+raw1;
    validateCtx(name.slice(1));
    try { await octokit.issues.deleteLabel({ owner, repo, name }); } catch(e) { if (e.status !== 404) throw e; }
    runOut(tpl('label.deleted_named', { name }));
  } else if (sub === 'rename') {
    return await renameCtxLabel(octokit, owner, repo, tokens[1], tokens[2], '/todo label rename <old> <new>');
  } else {
    process.stderr.write('Usage: run label list|add|delete|rename\n'); process.exit(1);
  }
}

async function runSearch(octokit, owner, repo, tokens) {
  const jsonMode = tokens.includes('--json');
  const filteredTokens = tokens.filter(t => t !== '--json');
  const keyword = filteredTokens.join(' ');
  if (!keyword) { process.stderr.write('Usage: run search <keyword>\n'); process.exit(1); }
  const q = `${keyword} repo:${owner}/${repo} is:issue is:open`;
  const { data } = await octokit.search.issuesAndPullRequests({ q, per_page: 50 });

  if (jsonMode) {
    runOut(JSON.stringify(data.items.map(issueToJsonObj), null, 2));
    return;
  }

  if (!data.items.length) { runOut(tpl('search.no_results', { keyword })); return; }
  for (const i of data.items) {
    runOut(`  #${i.number}  ${i.title}  [${i.labels.map(l=>l.name).join(',')}]`);
  }
  runOut(tpl('search.results_count', { n: data.items.length }));
}

async function runArchive(octokit, owner, repo, tokens) {
  const sub = tokens[0] || 'list';
  if (sub === 'list') {
    const filter = tokens[1] || '';
    const closed = await fetchRecentClosed(octokit, owner, repo, 30, null);
    let items = closed;
    if (filter && (GTD_LABELS.includes(filter) || filter === PROJECT_LABEL)) {
      items = closed.filter(i => i.labels && i.labels.some(l => normLabel(l.name) === filter));
    } else if (filter && filter.startsWith('@')) {
      validateCtx(filter.slice(1));
      items = closed.filter(i => i.labels && i.labels.some(l => l.name === filter));
    }
    if (!items.length) { runOut(t('archive.no_completed')); return; }
    for (const i of items) runOut(`  #${i.number}  ${i.title||''}  ✅${toJstDateStr(i.closedAt)}`);
    runOut(tpl('archive.count', { n: items.length }));
  } else if (sub === 'search') {
    const keyword = tokens.slice(1).join(' ');
    if (!keyword) { process.stderr.write('Usage: run archive search <keyword>\n'); process.exit(1); }
    const q = `${keyword} in:title repo:${owner}/${repo} is:issue is:closed`;
    const { data } = await octokit.search.issuesAndPullRequests({ q, per_page: 30 });
    for (const i of data.items) runOut(`  #${i.number}  ${i.title}  ✅${toJstDateStr(i.closed_at)}`);
    runOut(tpl('search.results_count', { n: data.items.length }));
  } else if (sub === 'reopen') {
    const num = parseInt(tokens[1]);
    if (!num) { process.stderr.write('Usage: run archive reopen <number>\n'); process.exit(1); }
    validateNumber(String(num));
    await octokit.issues.update({ owner, repo, issue_number: num, state: 'open' });
    await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: ['📥 inbox'] });
    runOut(tpl('archive.reopened', { num }));
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
  renderToday();
}

async function runEisenhower(octokit, owner, repo) {
  // eisenhower() は完了実績を表示しないため CLOSED_ENV は設定しない（runToday と異なる点）
  const today = getToday();
  const open = await fetchAllOpen(octokit, owner, repo);
  process.env.OPEN_ENV = JSON.stringify(open);
  process.env.TODAY_ENV = today;
  eisenhower();
}

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
      await ensureLabel(octokit, owner, repo, ctx, 'FBCA04', t('label.desc_context'));
      labels.push(ctx);
    }
    const pcolor = priorityColor(priority);
    await ensureLabel(octokit, owner, repo, priority, pcolor, t('label.desc_priority'));
    labels.push(priority);

    const estMin = tmpl.estimate ? parseTime(String(tmpl.estimate)) : null;
    const body = buildBody({
      due,
      recur,
      project:  proj,
      estimate: estMin !== null ? String(estMin) : '',
      desc,
    });
    const { data: newIssue } = await octokit.issues.create({ owner, repo, title, body, labels });
    let createdMsg = tpl('template.issue_created', { name, num: newIssue.number })
      + '\n' + tpl('add.title_line', { title })
      + '\n' + tpl('add.labels_line', { labels: labels.join(', ') });
    if (due) createdMsg += '\n' + tpl('add.due_line', { due });
    runOut(createdMsg);

    // sub-issue 登録（テンプレートに project が含まれる場合）
    if (proj) {
      const parentNum = parseInt(proj);
      let parentIssue;
      try {
        parentIssue = await fetchAndParseIssue(octokit, owner, repo, parentNum);
      } catch (e) {
        process.stderr.write(tpl('warn.project_fetch_failed', { num: parentNum, msg: e.message })+'\n');
        return;
      }
      const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
      if (!isProject) {
        process.stderr.write(tpl('warn.not_a_project', { num: parentNum })+'\n');
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

function issueToJsonObj(rawIssue) {
  const lnames = rawIssue.labels.map(l => normLabel(l.name || l));
  const parsed = parseBodyObj(rawIssue.body || '');

  const gtdLabel = GTD_LABELS.find(l => lnames.includes(l))
    || (lnames.includes(PROJECT_LABEL) ? 'project' : null);
  const priLabel = lnames.find(l => /^p[123]$/.test(l)) || null;
  const ctxLabels = lnames.filter(l => l.startsWith('@') && l !== '@claude');
  const isClaudeTask = lnames.includes('@claude');
  const systemLabels = new Set([
    ...GTD_LABELS, PROJECT_LABEL, ...ctxLabels, '@claude',
    ...(priLabel ? [priLabel] : []),
  ]);
  const tags = lnames.filter(l => !systemLabels.has(l));
  // #1854: parsed.estimate は parseBodyObj() が値全体（"2h" 等）を抽出済みなので、
  // formatTime(parseInt(...)) ではなく parseTime() で単位付き文字列を正しく分へ変換する。
  // parseTime() が解釈できない不正な形式は estimateFormatted を null にする
  // （formatTime(NaN) の "0m" を返すと不正値が気づけないまま表示されてしまうため）。
  const estMinutes = parsed.estimate ? parseTime(parsed.estimate) : null;

  return {
    number: rawIssue.number,
    title: rawIssue.title,
    gtd: gtdLabel || null,
    priority: priLabel || null,
    due: parsed.due || null,
    estimate: parsed.estimate || null,
    estimateFormatted: estMinutes !== null ? formatTime(estMinutes) : null,
    context: ctxLabels,
    claude: isClaudeTask,
    tags,
    recur: parsed.recur || null,
    project: parsed.project ? parseInt(parsed.project) : null,
    activate: parsed.activate || null,
    dependsOn: parsed.dependsOn ? parseInt(parsed.dependsOn) : null,
    resumeCondition: parsed.resumeCondition || null,
    desc: parsed.desc && parsed.desc.trim() ? parsed.desc.trim() : null,
    labels: lnames,
  };
}

function runSchema() {
  const schema = {
    description: t('schema.description'),
    commands: {
      "show --json": t('schema.cmd.show'),
      "list --json": t('schema.cmd.list'),
      "search --json": t('schema.cmd.search')
    },
    fields: {
      number:           { type: "integer",        description: t('schema.field.number') },
      title:            { type: "string",          description: t('schema.field.title') },
      state:            { type: "string",          description: t('schema.field.state') },
      closedAt:         { type: "string | null",   description: t('schema.field.closedAt') },
      gtd:              { type: "string | null",   description: t('schema.field.gtd') },
      priority:         { type: "string | null",   description: t('schema.field.priority') },
      due:              { type: "string | null",   description: t('schema.field.due') },
      estimate:         { type: "string | null",   description: t('schema.field.estimate') },
      estimateFormatted:{ type: "string | null",   description: t('schema.field.estimateFormatted') },
      context:          { type: "string[]",        description: t('schema.field.context') },
      claude:           { type: "boolean",         description: t('schema.field.claude') },
      tags:             { type: "string[]",        description: t('schema.field.tags') },
      recur:            { type: "string | null",   description: t('schema.field.recur') },
      project:          { type: "integer | null",  description: t('schema.field.project') },
      activate:         { type: "string | null",   description: t('schema.field.activate') },
      dependsOn:        { type: "integer | null",  description: t('schema.field.dependsOn') },
      resumeCondition:  { type: "string | null",   description: t('schema.field.resumeCondition') },
      desc:             { type: "string | null",   description: t('schema.field.desc') },
      labels:           { type: "string[]",        description: t('schema.field.labels') }
    }
  };
  runOut(JSON.stringify(schema, null, 2));
}

async function runShow(octokit, owner, repo, tokens) {
  // --json フラグを検出し、残りのトークンから除外
  const jsonMode = tokens.includes('--json');
  const filteredTokens = tokens.filter(t => t !== '--json');
  const numStr = (filteredTokens[0] || '').replace(/^#/, '');
  if (!numStr || !/^\d+$/.test(numStr)) {
    process.stderr.write('Usage: /todo show <issue-number> [--json]\n');
    process.exit(1);
  }
  const num = parseInt(numStr, 10);

  let issue;
  try {
    issue = await fetchAndParseIssue(octokit, owner, repo, num);
  } catch (e) {
    if (e.status === 404) {
      process.stderr.write(tpl('error.issue_not_found', { num })+'\n');
    } else {
      process.stderr.write(tpl('error.issue_fetch_failed', { msg: e.message })+'\n');
    }
    process.exit(1);
  }

  // GTDカテゴリを判定
  const gtdLabel = GTD_LABELS.find(l => issue.labels.includes(GTD_DISPLAY[l]))
    || (issue.labels.includes(GTD_DISPLAY[PROJECT_LABEL]) ? 'project' : '');
  const gtdDisplay = gtdLabel ? (GTD_DISPLAY[gtdLabel] || gtdLabel) : t('show.unclassified');

  // コンテキストを抽出（@で始まるラベル、@claude は除く）
  const ctxLabels = issue.labels.filter(l => l.startsWith('@') && l !== '@claude');
  const ctxDisplay = ctxLabels.length ? ctxLabels.join(', ') : t('list.none');

  // @claude ラベルの有無
  const isClaudeTask = issue.labels.includes('@claude');

  // 優先度を抽出
  const priLabel = issue.labels.find(l => /^p[123]$/.test(l)) || '';
  const priDisplay = priLabel || t('list.none');

  // 見積もりを分 → 表示形式に変換
  // #1854: issue.estimate は fetchAndParseIssue() 経由で値全体（"2h" 等）を保持しているため
  // parseTime() で単位付き文字列を正しく分へ変換する。parseTime() が解釈できない不正な形式は
  // 「（形式不正）」を添えて表示し、0m と黙って表示しないようにする。
  const estMinutes = issue.estimate ? parseTime(issue.estimate) : null;
  const estDisplay = !issue.estimate ? t('list.none')
    : (estMinutes !== null ? formatTime(estMinutes) : tpl('show.estimate_invalid', { raw: issue.estimate }));

  // タグ（GTD・コンテキスト・@claude・優先度以外のラベル）
  const systemLabels = new Set([
    ...GTD_LABELS.map(l => GTD_DISPLAY[l]),
    GTD_DISPLAY[PROJECT_LABEL],
    ...ctxLabels,
    '@claude',
    ...(priLabel ? [priLabel] : []),
  ]);
  const tags = issue.labels.filter(l => !systemLabels.has(l));

  // --json モード: 構造化 JSON を出力して終了
  if (jsonMode) {
    const obj = {
      number: issue.number,
      title: issue.title,
      state: issue.state || 'open',
      closedAt: issue.closedAt || null,
      gtd: gtdLabel || null,
      priority: priLabel || null,
      due: issue.due || null,
      estimate: issue.estimate || null,
      estimateFormatted: estMinutes !== null ? formatTime(estMinutes) : null,
      context: ctxLabels.length ? ctxLabels : [],
      claude: isClaudeTask,
      tags: tags.length ? tags : [],
      recur: issue.recur || null,
      project: issue.project || null,
      activate: issue.activate || null,
      dependsOn: issue.dependsOn || null,
      resumeCondition: issue.resumeCondition || null,
      desc: (issue.desc && issue.desc.trim()) ? issue.desc.trim() : null,
      labels: issue.labels,
    };
    runOut(JSON.stringify(obj, null, 2));
    return;
  }

  // 各フィールドを整形して出力
  const lines = [
    `## #${issue.number} ${issue.title}`,
    '',
  ];
  if (issue.state === 'closed') {
    const closedDate = toJstDateStr(issue.closedAt);
    lines.push(tpl('show.status_done', { suffix: closedDate ? tpl('show.closed_date_suffix', { date: closedDate }) : '' }));
  }
  lines.push(
    tpl('show.line_gtd', { value: gtdDisplay }),
    tpl('show.line_priority', { value: priDisplay }),
    tpl('show.line_due', { value: issue.due || t('list.none') }),
    tpl('show.line_estimate', { value: estDisplay }),
    tpl('show.line_context', { value: ctxDisplay }),
    tpl('show.line_claude', { value: isClaudeTask ? t('show.yes') : t('show.no') }),
  );

  if (issue.recur) lines.push(tpl('show.line_recur', { value: issue.recur }));
  if (issue.project) lines.push(tpl('show.line_project', { value: issue.project }));
  if (issue.activate) lines.push(`- activate: ${issue.activate}`);
  if (issue.dependsOn) lines.push(`- depends_on: #${issue.dependsOn}`);
  if (issue.resumeCondition) lines.push(`- resume_condition: ${issue.resumeCondition}`);
  if (tags.length) lines.push(tpl('show.line_other_labels', { value: tags.join(', ') }));

  if (issue.desc && issue.desc.trim()) {
    lines.push('');
    lines.push(t('show.desc_header'));
    lines.push(issue.desc.trim());
  }

  runOut(lines.join('\n'));
}

async function runView(octokit, owner, repo, tokens) {
  const sub = tokens[0];
  if (!sub) {
    process.stderr.write('Usage: /todo view list|save|use|delete\n');
    process.exit(1);
  }
  if (sub === 'list') {
    viewList();
  } else if (sub === 'save') {
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run view save <name> [filters...]\n'); process.exit(1); }
    validateName(name);
    const rest = tokens.slice(2);
    let gtd = '', ctx = '', pri = '';
    const ctxTokens = rest.filter(tok => tok.startsWith('@'));
    if (ctxTokens.length > 1) {
      process.stderr.write(t('error.view_ctx_multiple')+'\n');
      process.exit(1);
    }
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
  } else if (sub === 'delete') {
    // 予約サブコマンドは「名前扱いフォールバック」より前に判定する
    // （でないと view delete <name> が「delete」という名前のビュー扱いになり到達不能になる。Issue #1643）
    const name = tokens[1];
    if (!name) { process.stderr.write('Usage: run view delete <name>\n'); process.exit(1); }
    validateName(name);
    process.env.VNAME_ENV = name;
    viewDelete();
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
    runOut(tpl('view.viewing', { name, parts: parts.join(', ') })+'\n');
    listAll();
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
  if (!nums.length) { process.stderr.write(t('error.no_issue_numbers')+'\n'); process.exit(1); }
  for (const n of nums) validateNumber(String(n));

  let doneCount = 0, errCount = 0;
  if (sub === 'done') {
    let recurCreated = 0;
    for (const num of nums) {
      try {
        const parsed = parseArgs(rest);
        const issue = await fetchAndParseIssue(octokit, owner, repo, num);
        let actual = issue.actual;
        if (parsed.actual) { const a = parseTime(parsed.actual); if (a !== null) actual = String(a); }
        if (actual !== issue.actual) {
          const body = buildBody({ ...issue, actual });
          await octokit.issues.update({ owner, repo, issue_number: num, body });
        }

        // #1652: create-before-close — 次周期Issueの作成をcloseより先に行う（詳細はcreateRecurIssue定義部のコメント参照）
        const { recurLine, newIssueNumber } = await createRecurIssue(octokit, owner, repo, issue);
        try {
          await octokit.issues.update({ owner, repo, issue_number: num, state: 'closed' });
        } catch (e) {
          if (newIssueNumber) {
            throw new Error(tpl('error.close_failed_after_recur', { num, newNum: newIssueNumber, msg: e.message }));
          }
          throw e;
        }

        // #1642: depends_on昇格を runDone と共通の後処理で実施
        const { otherLines } = await postDoneProcessing(octokit, owner, repo, num, issue);
        if (recurLine) {
          recurCreated++;
          runOut(`  #${num}: ${recurLine}`);
        }
        otherLines.forEach(line => runOut(`  ${line}`));

        doneCount++;
      } catch(e) { runOut(tpl('bulk.item_error', { num, msg: e.message })); errCount++; }
    }
    {
      let summary = tpl('bulk.done_count', { n: doneCount });
      if (recurCreated) summary += tpl('bulk.done_recur_suffix', { n: recurCreated });
      if (errCount) summary += tpl('bulk.err_suffix', { n: errCount });
      runOut(summary);
    }
  } else if (sub === 'move') {
    const target = rest[0];
    if (!target || !GTD_LABELS.includes(target)) {
      if (target === PROJECT_LABEL) {
        process.stderr.write(t('error.move_to_project_forbidden')+'\n');
      } else {
        process.stderr.write(t('error.gtd_label_missing')+'\n');
      }
      process.exit(1);
    }
    const newLabel = GTD_DISPLAY[target];
    for (const num of nums) {
      try {
        const issue = await fetchAndParseIssue(octokit, owner, repo, num);
        const oldGtd = issue.labels.find(l => GTD_LABELS.includes(normLabel(l)));
        if (oldGtd && oldGtd !== newLabel) {
          await removeLabelIfPresent(octokit, owner, repo, num, oldGtd);
        }
        await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [newLabel] });
        doneCount++;
      } catch(e) { runOut(tpl('bulk.item_error', { num, msg: e.message })); errCount++; }
    }
    runOut(tpl('bulk.moved_count', { n: doneCount, label: newLabel }) + (errCount ? tpl('bulk.err_suffix', { n: errCount }) : ''));
  } else if (sub === 'tag') {
    const labelList = normalizeTagTokens(rest);
    if (!labelList.length) { process.stderr.write('Usage: run bulk tag <nums...> @ctx/#tag ...\n'); process.exit(1); }
    for (const lbl of labelList) {
      let created;
      if (lbl.startsWith('#')) { validateTag(lbl.slice(1)); created = await ensureLabel(octokit, owner, repo, lbl, '0075CA', t('label.desc_tag')); }
      else { validateCtx(lbl.slice(1)); created = await ensureLabel(octokit, owner, repo, lbl, 'FBCA04', t('label.desc_context')); }
      // 既存ラベルに無い名前は打ち間違いの可能性があるため明示する（Issue #1686）
      if (created) runOut(tpl('label.created', { name: lbl }));
    }
    for (const num of nums) {
      try { await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: labelList }); doneCount++; }
      catch(e) { runOut(tpl('bulk.item_error', { num, msg: e.message })); errCount++; }
    }
    runOut(tpl('bulk.tag_added_count', { n: doneCount, labels: labelList.join(' ') }) + (errCount ? tpl('bulk.err_suffix', { n: errCount }) : ''));
  } else if (sub === 'untag') {
    const labelList = normalizeTagTokens(rest);
    if (!labelList.length) { process.stderr.write('Usage: run bulk untag <nums...> @ctx/#tag ...\n'); process.exit(1); }
    for (const lbl of labelList) {
      if (lbl.startsWith('#')) { validateTag(lbl.slice(1)); }
      else { validateCtx(lbl.slice(1)); }
    }
    for (const num of nums) {
      try {
        await execRemoveLabels(octokit, owner, repo, num, labelList);
        doneCount++;
      } catch(e) { runOut(tpl('bulk.item_error', { num, msg: e.message })); errCount++; }
    }
    runOut(tpl('bulk.tag_removed_count', { n: doneCount, labels: labelList.join(' ') }) + (errCount ? tpl('bulk.err_suffix', { n: errCount }) : ''));
  } else if (sub === 'priority') {
    const level = rest[0];
    if (!level) { process.stderr.write('Usage: run bulk priority <nums...> <p1|p2|p3|clear>\n'); process.exit(1); }
    if (level !== 'clear') validatePriority(level);
    if (level !== 'clear') { const pcolor = priorityColor(level); await ensureLabel(octokit, owner, repo, level, pcolor, t('label.desc_priority')); }
    for (const num of nums) {
      try {
        const issue = await fetchAndParseIssue(octokit, owner, repo, num);
        const oldPri = issue.labels.find(l => /^p[123]$/.test(l));
        if (oldPri) { await removeLabelIfPresent(octokit, owner, repo, num, oldPri); }
        if (level !== 'clear') await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [level] });
        doneCount++;
      } catch(e) { runOut(tpl('bulk.item_error', { num, msg: e.message })); errCount++; }
    }
    runOut(tpl('bulk.priority_set_count', { n: doneCount, level }) + (errCount ? tpl('bulk.err_suffix', { n: errCount }) : ''));
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
    process.stderr.write(tpl('error.not_someday', { num })+'\n');
    process.exit(1);
  }

  const body = buildBody({ ...issue, reviewedAt: today });
  await updateIssueBody(octokit, owner, repo, num, { body });
  runOut(tpl('someday.reviewed', { num, date: today }));
}

async function runPromote(octokit, owner, repo) {
  const today = getToday();
  const allIssues = await fetchAllOpen(octokit, owner, repo);
  const nextLabel = GTD_DISPLAY['next'];
  let promoted = 0;
  let pendingReview = 0;

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

    // resume_condition あり → 機械的自動昇格をスキップし、確認要求のみ出力する
    // （Issue #1299由来の欠陥修正: activate到来のみで実質的な再開条件を無視して昇格していた）
    if (parsed.resumeCondition) {
      runOut(tpl('promote.pending_review', { num: raw.number, title: raw.title, condition: parsed.resumeCondition }));
      pendingReview++;
      continue;
    }

    // GTDラベルをnextに切り替え
    if (gtdLabel) {
      await removeLabelIfPresent(octokit, owner, repo, raw.number, gtdLabel);
    }
    await octokit.issues.addLabels({ owner, repo, issue_number: raw.number, labels: [nextLabel] });
    runOut(tpl('promote.promoted', { num: raw.number, title: raw.title, activate: parsed.activate }));
    promoted++;
  }

  if (promoted === 0 && pendingReview === 0) {
    runOut(t('promote.no_targets'));
  } else {
    if (promoted > 0) runOut(tpl('promote.summary', { n: promoted }));
    if (pendingReview > 0) runOut(tpl('promote.pending_summary', { n: pendingReview }));
  }
}

// /todo promote-project <N> [--outcome "〜"] — 既存 Issue をプロジェクトに昇格
async function runPromoteProject(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write('Usage: /todo promote-project <N> [--outcome "title"]\n'); process.exit(1); }
  validateNumber(String(num));

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);

  // 既に project ラベルを持つ場合はエラー
  if (issue.labels.some(l => normLabel(l) === PROJECT_LABEL)) {
    process.stderr.write(tpl('error.already_project', { num })+'\n');
    process.exit(1);
  }

  // GTD ラベルを外す
  const oldGtd = issue.labels.find(l => GTD_LABELS.includes(normLabel(l)));
  if (oldGtd) {
    await removeLabelIfPresent(octokit, owner, repo, num, oldGtd);
  }

  // 📁 project ラベルを付与
  await ensureLabel(octokit, owner, repo, GTD_DISPLAY[PROJECT_LABEL], '0052CC', 'GTD: project');
  await octokit.issues.addLabels({ owner, repo, issue_number: num, labels: [GTD_DISPLAY[PROJECT_LABEL]] });

  // --outcome 指定時はタイトルを書き換え
  let newTitle = issue.title;
  const outcomeIdx = tokens.indexOf('--outcome');
  if (outcomeIdx !== -1 && tokens[outcomeIdx+1]) {
    newTitle = tokens[outcomeIdx+1];
    validateTitle(newTitle);
    await octokit.issues.update({ owner, repo, issue_number: num, title: newTitle });
  }

  runOut(tpl('project.promoted', { num, title: newTitle }));
  runOut(tpl('project.promoted_hint', { num }));
}

// /todo unlink <N> [--force] — 子 Issue の sub-issue 関連と body project 行を解除
// #1880: 修正前は removeSubIssue の成否を見ず、DELETE が失敗しても body の project 行を
// 無条件に削除していた（実事故: #454 で GitHub 上の親子関係は残ったまま body だけ消えた）。
// 以下2点をガードする。
//   1. DELETE が失敗した場合、body は更新しない（エラー終了）
//   2. body の project: #N が指す親と、GitHub 上で実際に登録されている親が食い違う場合、
//      --force なしでは body も消さない（食い違いを明示してエラー終了）。--force 指定時は
//      「GitHub 側に解除すべき関係が元々ない」ことを確認した上で body のみ解除する
async function runUnlink(octokit, owner, repo, tokens) {
  const num = parseInt(tokens[0]);
  if (!num) { process.stderr.write('Usage: /todo unlink <N> [--force]\n'); process.exit(1); }
  validateNumber(String(num));
  const force = tokens.includes('--force');

  const issue = await fetchAndParseIssue(octokit, owner, repo, num);

  // body に project: #N がなければエラー
  const projMatch = (issue.body||'').match(/^project: #(\d+)/m);
  if (!projMatch) {
    process.stderr.write(tpl('error.no_project_link', { num })+'\n');
    process.exit(1);
  }
  const parentNum = parseInt(projMatch[1]);

  // body の親が実際に GitHub 上でも親であるかを事前確認する。
  // body の project: #N は「そうあるべき」という記述に過ぎず、実態と食い違うことがある
  // （#1879 由来の登録失敗・プロジェクト付け替え時の body 直書き換え等）。
  //
  // GET が失敗すると []（=未登録扱い）と「本当に子0件」が区別できない。区別を
  // 誤ると --force 指定時に removeSubIssue を呼ばないまま body の project: 行だけ
  // 削除してしまい、実際には残っている親子関係が「解除済み」と誤記される
  // （#1880 が修正したデータ喪失と同じ結果になる）。そのため throwOnError で
  // 例外を再送出させ、GET 失敗時は --force の有無にかかわらず body を一切
  // 更新せずに終了する（#1885）。
  let existing;
  try {
    existing = await listSubIssues(octokit, owner, repo, parentNum, { throwOnError: true });
  } catch (e) {
    process.stderr.write(tpl('error.unlink_list_failed', { num, parent: parentNum })+'\n');
    process.exit(1);
  }
  const isRegistered = existing.some(s => s.id === issue.id);

  if (!isRegistered && !force) {
    process.stderr.write(tpl('error.unlink_mismatch', { num, parent: parentNum })+'\n');
    process.exit(1);
  }

  if (isRegistered) {
    const result = await removeSubIssue(octokit, owner, repo, parentNum, issue.id);
    if (result !== 'removed') {
      // DELETE 失敗: body は更新しない
      process.stderr.write(tpl('error.unlink_failed', { num })+'\n');
      process.exit(1);
    }
  }
  // isRegistered === false かつ force === true の場合はここに到達する。
  // GitHub 側に解除すべき sub-issue 関係が元々ないため removeSubIssue は呼ばない。

  // body から project: #N 行を削除
  const newBody = (issue.body||'').replace(/^project: #\d+\r?\n?/m, '');
  await octokit.issues.update({ owner, repo, issue_number: num, body: newBody });

  if (!isRegistered && force) {
    runOut(tpl('link.unlinked_mismatch', { num }));
  } else {
    runOut(tpl('link.unlinked', { num }));
  }
}

// /todo weekly-project-audit — 全プロジェクトを走査し棚卸しを促す
async function runWeeklyProjectAudit(octokit, owner, repo) {
  const today = getToday();
  const allIssues = await fetchAllOpen(octokit, owner, repo);

  // 📁 project ラベルを持つ Issue を抽出
  const allProjectIssues = allIssues.filter(i => {
    const lnames = (i.labels || []).map(l => l.name || l);
    return lnames.some(l => normLabel(l) === PROJECT_LABEL);
  });

  // 🌈 someday を併せ持つ project は「休止中」として棚卸し対象から除外する
  // （#1846: move <n> someday で project ラベルは剥がれず二重ラベルのまま残る設計のため、
  //  消費側であるここで除外する。move 側の挙動は変更しない）
  const projects = allProjectIssues.filter(i => {
    const lnames = (i.labels || []).map(l => l.name || l);
    return !lnames.some(l => normLabel(l) === 'someday');
  });
  const pausedCount = allProjectIssues.length - projects.length;

  if (!projects.length) {
    runOut(t('audit.no_projects'));
    if (pausedCount > 0) runOut(tpl('audit.paused_excluded', { n: pausedCount }));
    return;
  }

  runOut(tpl('audit.header', { n: projects.length }));
  if (pausedCount > 0) runOut(tpl('audit.paused_excluded', { n: pausedCount }));
  runOut('');

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
    const daysSinceUpdate = updatedAt ? daysBetween(toJstDateStr(updatedAt), today) : 0;
    const isStale = daysSinceUpdate >= 30;
    const hasNext = nextCount > 0;

    // 判定
    let verdict = '';
    let suggestions = '';
    if (!hasNext && isStale) {
      verdict = t('audit.verdict_stale_no_next');
      suggestions = tpl('audit.suggestion', { n: projNum });
    } else if (!hasNext) {
      verdict = t('audit.verdict_no_next');
      suggestions = tpl('audit.suggestion', { n: projNum });
    } else {
      verdict = t('audit.verdict_ok');
    }

    // 直近更新の表示
    const updateStr = updatedAt ? tpl('audit.days_ago', { n: daysSinceUpdate }) : t('audit.unknown');

    const w = s => process.stdout.write(s);
    w(`[${idx+1}/${projects.length}] #${projNum} ${proj.title}\n`);
    w(tpl('audit.child_summary', { next: nextCount, waiting: waitingCount, someday: somedayCount })+'\n');
    w(tpl('audit.recent_update', { value: updateStr })+'\n');
    w(tpl('audit.verdict_line', { value: verdict })+'\n');
    if (suggestions) w(suggestions + '\n');
    w('\n');

    // next 欠落 or 停滞プロジェクトに reviewed_at を書き込む
    if (!hasNext || isStale) {
      const parsed = parseBodyObj(proj.body || '');
      const newBody = buildBody({ ...parsed, reviewedAt: today });
      try {
        await octokit.issues.update({ owner, repo, issue_number: projNum, body: newBody });
        reviewedCount++;
      } catch (e) {
        process.stderr.write(tpl('warn.reviewed_at_write_failed', { num: projNum, msg: e.message })+'\n');
      }
    }
  }

  runOut(tpl('audit.completed_summary', { total: projects.length, reviewed: reviewedCount }));
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
    runOut(t('migrate.no_targets'));
    return;
  }

  if (dryRun) {
    runOut(tpl('migrate.dry_run_header', { n: targets.length })+'\n');
    for (const { issue, parentNum } of targets) {
      runOut(tpl('migrate.dry_run_item', { num: issue.number, title: issue.title, parent: parentNum }));
    }
    runOut(t('migrate.dry_run_footer'));
    return;
  }

  let registered = 0, skipped = 0, errors = 0;

  for (const { issue, parentNum } of targets) {
    // 親が 📁 project ラベルを持つか確認
    let parentIssue;
    try {
      parentIssue = await fetchAndParseIssue(octokit, owner, repo, parentNum);
    } catch (e) {
      process.stderr.write(tpl('warn.parent_fetch_failed', { num: parentNum, msg: e.message })+'\n');
      errors++;
      continue;
    }
    const isProject = parentIssue.labels.some(l => normLabel(l) === PROJECT_LABEL);
    if (!isProject) {
      process.stderr.write(tpl('warn.parent_no_project_label', { parent: parentNum, num: issue.number })+'\n');
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

  runOut(tpl('migrate.summary', { registered, skipped, errors }));
}

// ─── 予約語タイトル誤爆ガード（Issue #1646） ───
// runMain の switch にある実コマンド名一覧。ケースを追加/削除したら必ずここも更新すること。
// tests/run-tests.sh の「1646: dispatcher コマンド名とガード対象の同期」がドリフトを検知する。
// 'project' と 'counts' は switch のケースとしては現れないが誤爆しうるため手動追加している:
//   - 'project': GTDラベルと同格の分岐（cmd === PROJECT_LABEL）で switch より手前に処理される
//   - 'counts' : todo.sh 層のみで処理され、run 経由でもエンジンの switch には到達しない
const RESERVED_TITLE_GUARD_COMMANDS = new Set([
  'add','list','done','close','move','edit','due','desc','recur','link','rename',
  'priority','tag','untag','label','search','archive','dashboard','dash','today',
  'eisenhower','stats','report','help','template','schema','show','view','bulk',
  'promote','promote-project','unlink','review-someday','weekly-project-audit',
  'migrate','activate','comment','api',
  PROJECT_LABEL, 'counts',
]);

// GTDラベル暗黙add経路（例: /todo project list）で、タイトルが単一トークンかつ
// 既知コマンド名と完全一致する場合に誤爆と判定する（大文字小文字は区別しない）。
// `add` を明示した経路（case 'add'）はこの関数を経由しないため対象外。
// 副作用なしの純粋関数（テストで直接呼び出せるようにするため）。
// 戻り値: 誤爆と判定したトークン文字列（元の大文字小文字のまま） or null
function reservedTitleGuardWord(restTokens) {
  const extra = parseArgs(restTokens).extra.filter(s => s.trim());
  if (extra.length !== 1) return null;
  const word = extra[0];
  return RESERVED_TITLE_GUARD_COMMANDS.has(word.toLowerCase()) ? word : null;
}

// runMain: コマンドディスパッチャー
async function runMain(args) {
  const cmd0 = args[0];
  // TODO_REPO_OWNER/TODO_REPO_NAME 未設定ガード（Issue #1695）。
  // help/schema はGitHub APIを使わないため、リポジトリ未設定でも動作させる。
  if (cmd0 !== 'help' && cmd0 !== 'schema' && (!REPO_OWNER || !REPO_NAME)) {
    throw apiErr(t('error.repo_not_configured') + '\n' + t('error.mcp_fallback_guidance'));
  }
  const octokit = await initOctokit();
  const owner = REPO_OWNER, repo = REPO_NAME;

  let cmd = args[0];
  const rest = args.slice(1);

  // GTDキーワードが先頭 → add として扱う（project も同様）
  if (GTD_LABELS.includes(cmd) || cmd === PROJECT_LABEL) {
    // 予約語タイトル誤爆ガード（Issue #1646）: 「/todo project list」のような
    // 一覧表示の意図を、タイトル「list」のゴミIssueとして黙って作成しない
    const guardWord = reservedTitleGuardWord(rest);
    if (guardWord) {
      process.stderr.write(tpl('error.reserved_command_word', { word: guardWord })+'\n');
      process.stderr.write(tpl('error.reserved_command_hint1', { cmd })+'\n');
      process.stderr.write(tpl('error.reserved_command_hint2', { cmd, word: guardWord })+'\n');
      process.stderr.write(t('error.command_list_hint')+'\n');
      process.exit(1);
    }
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
    case 'eisenhower': return await runEisenhower(octokit, owner, repo);
    case 'stats':     return await runStats(octokit, owner, repo);
    case 'report':    return await runReport(octokit, owner, repo, rest);
    case 'help':      return await runHelp();
    case 'template':  return await runTemplate(octokit, owner, repo, rest);
    case 'schema':    return runSchema();
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
        process.stderr.write('Usage: /todo activate <#> <date>\n');
        process.exit(1);
      }
      return await runEdit(octokit, owner, repo, [num, '--activate', date]);
    }
    case 'comment':   return await runComment(octokit, owner, repo, rest);
    case 'api':       return await apiMain(rest); // todo.sh は常に run を前置するため run 経由でも api サブコマンドを使えるようにする（Issue #1644）
    default: {
      // 第1引数が英字コマンド風で既知コマンドにない → 誤入力として即エラー
      // （GTD 原則: 仕分け済みをInboxに戻さない。暗黙の inbox 吸い込みは ghost issue を生む）
      if (/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(cmd)) {
        process.stderr.write(tpl('error.unknown_command', { cmd })+'\n');
        process.stderr.write(t('error.unknown_command_hint1')+'\n');
        process.stderr.write(tpl('error.unknown_command_hint2', { args: args.join(' ') })+'\n');
        process.stderr.write(t('error.command_list_hint')+'\n');
        process.exit(1);
      }
      // 非英字（日本語タイトル等）は従来通り inbox 追加（摩擦ゼロ収集の維持）
      return await runAdd(octokit, owner, repo, args);
    }
  }
}
