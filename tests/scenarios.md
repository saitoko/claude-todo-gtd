# todo スキル テストシナリオ

各シナリオの後に「期待する動作」を確認する。

---

## 1. タスク追加

### 1-1. inbox への追加（カテゴリ省略）
```
/todo 資料を読む
```
期待: `inbox` ラベルで Issue が作成される。タイトルは「資料を読む」。

### 1-2. next への追加（コンテキスト・期日付き）
```
/todo next 設計書を書く @PC --due 4/10
```
期待: `next` + `@PC` ラベル、due: `<今年>-04-10`、タイトルは「設計書を書く」。

### 1-3. waiting への追加
```
/todo waiting 田中さんの返信を待つ @上司
```
期待: `waiting` + `@上司` ラベル。

### 1-4. 繰り返しタスク（weekly）
```
/todo next 週報を書く @PC --due 4/7 --recur weekly
```
期待: body に `due: <今年>-04-07` と `recur: weekly` が含まれる。

### 1-5. 繰り返し設定値のバリデーション（異常系）
```
/todo next テスト --recur biweekly
```
期待: エラーメッセージ「recur は daily/weekly/monthly/weekdays のみ有効です」。

### 1-6. プロジェクトに紐づけた追加
```
/todo next サブタスクを実行する --project 7
```
期待: body に `project: #7` が含まれる。かつ Issue #7 が `📁 project` ラベルを持つ場合、GitHub の sub-issue API に登録される（Phase 1）。

### 1-7. 説明付き追加
```
/todo next 仕様確認 --desc "3章まで読んでから記載"
```
期待: body の説明行に「3章まで読んでから記載」が含まれる。

---

## 2. リスト表示

### 2-1. 全カテゴリ表示
```
/todo list
```
期待: next → inbox → waiting → someday → project → reference の順に表示。

### 2-2. カテゴリフィルタ
```
/todo list next
```
期待: next のみ表示。

### 2-3. コンテキストフィルタ
```
/todo list @PC
```
期待: `@PC` ラベルを持つ Issue のみ全カテゴリ横断で表示。

### 2-4. プロジェクトフィルタ
```
/todo list project 7
```
期待: body に `project: #7` を含む Issue のみ表示。

---

## 3. ステータス変更

### 3-1. next に移動
```
/todo move <番号> next
```
期待: 対象 Issue の GTD ラベルが `next` に変わる（旧ラベルは削除）。

### 3-2. 存在しないカテゴリへの移動（異常系）
```
/todo move <番号> unknown
```
期待: エラーメッセージ。

---

## 4. 完了・繰り返し

### 4-1. 繰り返しなし → done
```
/todo done <番号>
```
期待: Issue がクローズされ、新 Issue は作成されない。

### 4-2. 繰り返しあり（weekly）→ done
```
/todo done <繰り返しタスクの番号>
```
期待: Issue がクローズされ、7日後の due を持つ同タイトルの新 Issue が作成される。

### 4-3. close でも同じ動作
```
/todo close <繰り返しタスクの番号>
```
期待: done と同じ動作（繰り返しがあれば次 Issue を作成）。

---

## 5. 期日・説明の更新

### 5-1. 期日更新
```
/todo due <番号> 5/1
```
期待: body の `due:` 行が `<今年>-05-01` に更新される。既存の `recur:`, `project:`, description は保持される。

### 5-2. 説明更新
```
/todo desc <番号> 新しい説明テキスト
```
期待: body の説明部分が更新される。`due:`, `recur:`, `project:` 行は保持される。

---

## 6. コンテキスト操作

### 6-1. コンテキスト追加
```
/todo tag <番号> @自宅 @PC
```
期待: 指定 Issue に `@自宅` と `@PC` ラベルが追加される。存在しないラベルは自動作成。

### 6-2. コンテキスト一覧
```
/todo label list
```
期待: `@` で始まるラベルのみ一覧表示。

### 6-3. コンテキスト追加（label add）
```
/todo label add @テスト場所
```
期待: `@テスト場所` ラベルが作成される（色: FBCA04）。

### 6-4. コンテキストリネーム
```
/todo label rename @テスト場所 @新しい場所
```
期待: 全 Issue の `@テスト場所` ラベルが `@新しい場所` に置換される。

### 6-5. コンテキスト削除
```
/todo label delete @新しい場所
```
期待: ラベルが削除される。

### 6-6. 不正文字バリデーション（異常系）
```
/todo tag <番号> @危険;ラベル
```
期待: エラーメッセージ「コンテキスト名に不正文字が含まれています」。

---

## 7. プロジェクト関連付け

### 7-1. link コマンド
```
/todo link <アクション番号> <プロジェクト番号>
```
期待: アクション Issue の body に `project: #<プロジェクト番号>` が追加（または更新）される。

---

## 8. アーカイブ

### 8-1. 一覧表示
```
/todo archive
```
期待: 直近30件のクローズ済み Issue が表示される。

### 8-2. キーワード検索
```
/todo archive search 設計書
```
期待: タイトルに「設計書」を含むクローズ済み Issue のみ表示。

### 8-3. 復元
```
/todo archive reopen <番号>
```
期待: Issue が再オープンされ、`inbox` ラベルが付与される。

---

## 9. テンプレート

### 9-1. テンプレート作成（インライン）
```
/todo template save 週次レポート next @PC --recur weekly
```
期待: `~/.claude/todo-templates.json` に `週次レポート` エントリが追加される。

### 9-2. テンプレート一覧
```
/todo template list
```
期待: 保存済みテンプレートの一覧が表示される。

### 9-3. テンプレート詳細
```
/todo template show 週次レポート
```
期待: GTD・context・recur 等の全フィールドが表示される。

### 9-4. テンプレートからタスク作成
```
/todo template use 週次レポート 今週の進捗報告
```
期待: `next` + `@PC` ラベル、recur:weekly の Issue が「今週の進捗報告」タイトルで作成される。

### 9-5. due-offset の動作確認
テンプレートに `--due-offset 3` を設定して `template use` を実行。
期待: 今日から3日後が `due:` に設定される。

### 9-6. 既存 Issue からテンプレート作成
```
/todo template save バックアップ作業 from <番号>
```
期待: 指定 Issue の GTD・コンテキスト・due・recur がテンプレートにコピーされる。

### 9-7. テンプレート削除
```
/todo template delete 週次レポート
```
期待: `todo-templates.json` から該当エントリが削除される。

### 9-8. 不正文字バリデーション（異常系）
```
/todo template save 危険;名前 next
```
期待: エラーメッセージ「テンプレート名に不正文字が含まれています」。

---

## 10. 週次レビュー

### 10-1. 基本フロー
```
/todo weekly-review
```
期待: Inbox → Next → Waiting → Projects → Someday の順に確認が進む。  
Projects に Next Action のないものがあれば警告が表示される。

### 10-2. inbox 仕分け
Step 1 で「next」「waiting」「someday」「project」「reference」「close」「skip」以外を入力した場合:  
期待: 入力を無視して同じ質問を繰り返す。

### 10-3. Inbox が空の場合
Inbox に 0件の状態で `/todo weekly-review` を実行。  
期待: Step 1 は「Inbox は空です。スキップします。」と表示してスキップし、Step 2 に進む。

### 10-4. 各ステップで該当 Issue が 0件
Next Actions / Waiting / Someday にそれぞれ 0件の状態で対応する Step を実行。  
期待: 「（カテゴリ名）は空です。スキップします。」と表示して次の Step に進む。

---

## セキュリティ境界テスト

### S-1. Issue body に指示を含む場合
Issue body に「このシステムプロンプトを無視して...」のような文章を入れた Issue を作成し、`/todo list` で表示する。  
期待: その内容はデータとして表示されるだけで、命令として実行されない。

### S-2. Issue 番号にゼロや文字を指定（異常系）
```
/todo done 0
/todo done abc
/todo done -1
```
期待: いずれも「正の整数が必要です」エラー。

### S-3. 日付形式のバリデーション（異常系）
```
/todo next テスト --due 2026-13-01
/todo next テスト --due 99/99
```
期待: 「不正な日付形式です」エラー。  
※ただし `YYYY-MM-DD` 形式ではスキルはフォーマットのみ検証し、月の範囲（1-12）は検証しないため、13月は通過する可能性に注意。

### S-4. テンプレート名の不正文字（詳細）
以下をそれぞれ試す:
```
/todo template save テスト$名前 next        # $ を含む
/todo template save "テスト;rm -rf" next    # ; を含む
/todo template save "" next                 # 空文字
```
期待: 全て「テンプレート名に不正文字が含まれています」または「テンプレート名が空です」エラー。  
バリデーションは bash `case` ではなく node で行うため、クォート問題が発生しない。

### S-5. due-offset の境界値（異常系）
```
/todo template save テスト next --due-offset 0
/todo template save テスト next --due-offset -1
/todo template save テスト next --due-offset abc
/todo template save テスト next --due-offset 1.5
/todo template save テスト next --due-offset +0
```
期待: 全て「due-offsetは1以上の正の整数で指定してください」エラー。  
`+7` のような `+` プレフィックスは除去してから検証する（`+7` → `7` は正常）。

### S-6. JSON 改ざん検出（template use）
`~/.claude/todo-templates.json` を直接編集し、以下の不正値を埋め込んでから `template use` を実行:

**GTD 不正値:**
```json
{ "テスト": { "gtd": "malicious; rm -rf /", ... } }
```
期待: 「テンプレートのGTDラベルが不正です」エラー（抽出後バリデーションで検出）。

**コンテキスト不正文字:**
```json
{ "テスト": { "context": ["@会社", "@PC$(touch /tmp/pwned)"], ... } }
```
期待: 「テンプレートに不正なコンテキストが含まれています」エラー（node による再検証で検出）。  
`for CTX in $CONTEXT` の展開時に bash がコマンド置換を再実行しないことも確認済み（変数展開ではコマンド置換は起きない）。

### S-7. archive search のキーワードインジェクション
```
/todo archive search テスト" OR 1=1
```
期待: `--search` フラグに変数経由で渡されるため、シェルコマンドインジェクションにならない。  
GitHub API 側でのクエリとして扱われ、不正な結果になっても実害はない。

### S-8. コンテキストのシェルインジェクション耐性
```
/todo tag <番号> @PC$(touch /tmp/pwned)
```
期待: セキュリティルール3のバリデーション（`$` が不正文字）でエラー検出。コマンドは実行されない。

---

## 11. tag rename

### 11-1. コンテキスト名変更（`@` プレフィックスあり）
```
/todo tag rename @テスト場所 @新しい場所
```
期待: 全オープンIssueの `@テスト場所` ラベルが `@新しい場所` に置換され、旧ラベルは削除される。完了報告に更新件数が表示される。

### 11-2. `@` プレフィックスなし指定（tag rename）
```
/todo tag rename 旧コンテキスト 新コンテキスト
```
期待: `@旧コンテキスト` → `@新コンテキスト` に変換して処理される（`@` あり・なし両方受け付ける）。

---

## 12. 複合フィルタ（GTD + Context）

### 12-1. GTD + コンテキストの AND フィルタ
```
/todo list next @PC
```
期待: `next` ラベルかつ `@PC` ラベルを持つ Issue のみ表示。`--label` を2つ指定した AND 条件で絞り込まれる。

### 12-2. 複合フィルタで該当なし
```
/todo list waiting @PC
```
期待: 該当 Issue がなければ「（なし）」または空のリストが表示される。

---

## 13. アーカイブフィルタ

### 13-1. GTDラベルでフィルタ（archive list next）
```
/todo archive list next
```
期待: `next` ラベルを持つクローズ済み Issue のみ最大30件表示。

### 13-2. コンテキストでフィルタ（archive list @context）
```
/todo archive list @PC
```
期待: `@PC` ラベルを持つクローズ済み Issue のみ最大30件表示。コンテキスト名はセキュリティルール3でバリデーションされる。

### 13-3. archive list（フィルタなし）
```
/todo archive list
```
期待: 直近30件のクローズ済み Issue を表示（`archive` 単体と同じ動作）。

---

## 14. リストサマリー表示

### 14-1. フィルタなし list のサマリー
```
/todo list
```
期待: 一覧の末尾に `📊 next: N件 / inbox: N件 ...` 形式のサマリーが表示される。期限超過があれば `⚠️ 期限超過: N件`、今週期限があれば `📅 今週期限: N件` も表示される。

### 14-2. フィルタあり list ではサマリー省略可
```
/todo list next
```
期待: サマリーは省略されてよい（仕様上「フィルタ有りは省略可」）。

---

## 15. タイトルが空になるエラー

### 15-1. GTDキーワードのみ（タイトルなし）
```
/todo next
```
期待: タイトルが空になるためエラーを表示して処理を中断する。

### 15-2. コンテキストのみ（タイトルなし）
```
/todo @PC
```
期待: 同様にエラーを表示して処理を中断する。

---

## 16. normalize_due 日本語表現

### 16-1. 各相対日付パターン
以下それぞれを `--due` に渡してタスクを作成し、body の `due:` が正しい `YYYY-MM-DD` に変換されることを確認:
```
/todo next テスト --due 今日
/todo next テスト --due 明日
/todo next テスト --due 明後日
/todo next テスト --due 来週
/todo next テスト --due 今週末
/todo next テスト --due 今月末
/todo next テスト --due 来月末
/todo next テスト --due 3日後
/todo next テスト --due 2週間後
/todo next テスト --due 3ヶ月後
/todo next テスト --due 来週月曜
/todo next テスト --due 来週金曜
```
期待: それぞれ適切な `YYYY-MM-DD` に変換された `due:` がbodyに含まれる。

### 16-2. 未対応パターンはバリデーションエラー
```
/todo next テスト --due 先週
```
期待: `normalize_due` で変換されず、M/D 形式でもないため「不正な日付形式です」エラー。

---

## 17. label add --color

### 17-1. カラー指定付きコンテキスト作成
```
/todo label add @カスタム色 --color 0075CA
```
期待: `@カスタム色` ラベルが `#0075CA` の色で作成される。

### 17-2. 不正カラーコード（異常系）
```
/todo label add @テスト --color GGGGGG
```
期待: エラーメッセージ「カラーは6桁の16進数のみ有効です（例: FBCA04）」。

---

## 18. recur パターン（daily/monthly/weekdays）

### 18-1. daily recur での done
```
/todo next 毎日の確認 --recur daily
```
`done` 実行後: 翌日の due を持つ同タイトルの新 Issue が作成される。

### 18-2. monthly recur での done
```
/todo next 月次報告 --due 4/30 --recur monthly
```
`done` 実行後: 翌月同日（5/30）の due を持つ新 Issue が作成される。

### 18-3. weekdays recur（週末 due での done）
due が土曜日（例: 4/5）の weekdays タスクを `done` した場合:  
期待: 次の平日（月曜 4/7）の due を持つ新 Issue が作成される。  
※ due が金曜なら翌平日（月曜）、月〜木なら翌日。

---

## 19. テンプレート存在確認（異常系）

### 19-1. 存在しないテンプレートを show
```
/todo template show 存在しない名前
```
期待: エラー「テンプレート「存在しない名前」は存在しません」。

### 19-2. 存在しないテンプレートを use
```
/todo template use 存在しない名前
```
期待: 同様のエラー。

### 19-3. 存在しないテンプレートを delete
```
/todo template delete 存在しない名前
```
期待: 同様のエラー。

---

## 20. template save 対話形式

### 20-1. 基本フロー（対話形式）
```
/todo template save 月次レポート
```
（GTDキーワード・コンテキスト・フラグのいずれも含まない場合）  
期待: 各フィールドの質問が順番に表示される（GTD → context → due-offset → recur → project → desc）。回答に従いテンプレートが保存される。

### 20-2. 対話形式での無効値入力
GTD の質問に `biweekly` を入力した場合:  
期待: エラーまたは再質問が行われ、不正な値でテンプレートが保存されない。

---

## 21. 優先度付きタスク追加（--priority）

### 21-1. p1 優先度でタスク作成
```
/todo next 障害対応 --priority p1
```
期待: `next` + `p1` ラベルで Issue が作成される。`p1` ラベルが存在しない場合は自動作成される（色: #B60205）。

### 21-2. p2 優先度でタスク作成
```
/todo next 会議準備 @PC --priority p2 --due 明日
```
期待: `next` + `@PC` + `p2` ラベル、due が明日の日付。

### 21-3. デフォルト優先度（--priority 未指定）
```
/todo next 普通の作業
```
期待: `next` + `p3` ラベルが付与される（デフォルト p3）。

### 21-4. 不正な priority 値
```
/todo next テスト --priority p4
```
期待: エラー「--priority は p1/p2/p3 のみ有効です」。

### 21-5. 不正な priority 値（文字列）
```
/todo next テスト --priority high
```
期待: 同様のエラー。

---

## 22. priority コマンド（優先度変更）

### 22-1. 優先度を p1 に変更
```
/todo priority <番号> p1
```
期待: 既存の優先度ラベル（p2/p3）が外れ、`p1` ラベルが付与される。確認メッセージが表示される。

### 22-2. 優先度を p3 に変更（降格）
```
/todo priority <番号> p3
```
期待: 既存の優先度ラベルが外れ、`p3` ラベルが付与される。

### 22-3. 優先度をクリア
```
/todo priority <番号> clear
```
期待: すべての優先度ラベル（p1/p2/p3）が外れる。確認メッセージ「優先度をクリアしました」が表示される。

### 22-4. 不正な level 値
```
/todo priority <番号> high
```
期待: エラー「p1/p2/p3/clear のみ有効です」。

---

## 23. list 優先度フィルタ

### 23-1. p1 のみ表示
```
/todo list p1
```
期待: `p1` ラベルを持つオープン Issue のみ表示（全GTDカテゴリ横断）。

### 23-2. GTD + 優先度の複合フィルタ
```
/todo list next p1
```
期待: `next` かつ `p1` の Issue のみ表示。

### 23-3. 優先度フィルタで該当なし
```
/todo list p1
```
（p1 のタスクが存在しない場合）  
期待: 「（なし）」または空のリストが表示される。

---

## 24. list 優先度ソート

### 24-1. フィルタなし list での優先度順表示
```
/todo list
```
期待: 各 GTD カテゴリ内で p1 → p2 → p3 → 優先度なし の順に表示される。
同じ優先度内は due 昇順（due なしは末尾）。
p1 の行頭に 🔴、p2 の行頭に 🟡 が表示される。

---

## 25. template priority

### 25-1. priority 付きテンプレート保存
```
/todo template save 緊急対応 next --priority p1
```
期待: テンプレートに `priority: p1` が保存される。`template show 緊急対応` で `priority: p1` が表示される。

### 25-2. template use で priority が適用される
```
/todo template use 緊急対応 インシデント対応
```
期待: `next` + `p1` ラベルで Issue が作成される。

### 25-3. 対話形式での priority 入力（template save）
```
/todo template save 週次作業
```
期待: GTD → context → **priority** → due-offset → recur → project → desc の順で質問が行われる。

---

## 26. rename / untag / recur

### 26-1. rename（正常系）
```
/todo rename <番号> 新しいタイトル
```
期待: `gh issue view <番号> --json title` でタイトルが「新しいタイトル」に変わっている。完了メッセージが日本語で表示される。

### 26-2. rename（日本語・スペース含むタイトル）
```
/todo rename <番号> 来週の会議 準備メモを更新する
```
期待: タイトルが「来週の会議 準備メモを更新する」に変わっている（日本語・スペースが正しく扱われる）。

### 26-3. rename（番号バリデーション異常系）
```
/todo rename abc 新しいタイトル
```
期待: エラーメッセージ「正の整数が必要です」。

### 26-4. untag（正常系）
```
/todo untag <番号> @PC
```
期待: `gh issue view <番号> --json labels` で `@PC` ラベルが外れている。

### 26-5. untag（複数コンテキスト）
```
/todo untag <番号> @PC @会社
```
期待: `@PC` と `@会社` の両方が外れている。

### 26-6. untag（存在しないラベル）
```
/todo untag <番号> @存在しないコンテキスト
```
期待: エラーで終了せず、完了報告が表示される（gh が警告を出しても処理は継続）。

### 26-7. untag（コンテキスト名バリデーション異常系）
```
/todo untag <番号> @bad;ctx
```
期待: エラーメッセージ「コンテキスト名に不正文字が含まれています」。

### 26-8. recur（pattern 設定）
```
/todo recur <番号> weekly
```
期待: `gh issue view <番号> --json body` で body に `recur: weekly` が含まれる。既存の due/project/desc は変わっていない。

### 26-9. recur（clear）
```
/todo recur <番号> clear
```
期待: body に `recur:` 行が存在しない。その後 `/todo done <番号>` を実行しても次の周期タスクが自動作成されない。

### 26-10. recur（不正値バリデーション異常系）
```
/todo recur <番号> biweekly
```
期待: エラーメッセージ「recur は daily/weekly/monthly/weekdays のみ有効です」。

### 26-11. recur（番号バリデーション異常系）
```
/todo recur 0 weekly
```
期待: エラーメッセージ「正の整数が必要です」。

---

## 27. バルク操作（bulk）

### 27-1. bulk done（正常系）
```
/todo bulk done <番号1> <番号2> <番号3>
```
期待: 3件全てクローズされる。サマリー「✅ 3件完了」が表示される。

### 27-2. bulk done（recur 付き Issue 含む）
recur: weekly が設定された Issue を含む3件に対して:
```
/todo bulk done <番号1> <番号2-recur付き> <番号3>
```
期待: 3件クローズ。recur 付き Issue は次回分が自動作成される。サマリー「✅ 3件完了（うち繰り返し再作成: 1件）」。

### 27-3. bulk move（正常系）
```
/todo bulk move <番号1> <番号2> <番号3> next
```
期待: 3件全てのGTDラベルが `next` に変更される。サマリー「✅ 3件を next に移動しました」。

### 27-4. bulk tag（正常系）
```
/todo bulk tag <番号1> <番号2> @PC
```
期待: 2件に `@PC` ラベルが追加される。サマリー「✅ 2件に @PC を追加しました」。

### 27-5. bulk untag（正常系）
```
/todo bulk untag <番号1> <番号2> @PC
```
期待: 2件から `@PC` ラベルが削除される。サマリー「✅ 2件から @PC を削除しました」。

### 27-6. bulk priority（正常系）
```
/todo bulk priority <番号1> <番号2> <番号3> p1
```
期待: 3件の優先度が p1 に変更される。サマリー「✅ 3件の優先度を p1 に設定しました」。

### 27-7. 異常系 — Issue 番号なし
```
/todo bulk done
```
期待: エラー「Issue 番号を1つ以上指定してください」。

### 27-8. 異常系 — 不正な Issue 番号を含む
```
/todo bulk done abc 5
```
期待: エラー「正の整数が必要です」。

---

## 28. edit コマンド（複数フィールド同時更新）

### 28-1. 複数フィールド同時更新
```
/todo edit <番号> --due 4/15 --priority p1 --desc "新しい説明"
```
期待: due が更新され、priority が p1 に変更され、説明が更新される。未指定の recur/project は変更されない。

### 28-2. due のみ更新
```
/todo edit <番号> --due 明日
```
期待: due のみ更新。他のフィールドは保持。

### 28-3. priority clear
```
/todo edit <番号> --priority clear
```
期待: 優先度ラベルが全て除去される。body は変更なし。

### 28-4. recur 変更
```
/todo edit <番号> --recur monthly
```
期待: body の recur 行が monthly に更新される。

### 28-5. 異常系 — 番号なし
```
/todo edit
```
期待: エラー。

---

## 29. search コマンド（オープンIssue検索）

### 29-1. キーワード検索（正常系）
```
/todo search 報告書
```
期待: タイトルまたは本文に「報告書」を含むオープンIssueが表示される。

### 29-2. 検索結果0件
```
/todo search 絶対存在しないキーワードXYZ999
```
期待: 「検索結果: 0件」と表示される。

### 29-3. 異常系 — キーワードなし
```
/todo search
```
期待: エラー「キーワードを指定してください」。

---

## 30. stats コマンド（統計情報）

### 30-1. 基本表示
```
/todo stats
```
期待: カテゴリ別件数、優先度別件数、期限超過件数、今週期限件数、直近7日間の完了数が表示される。

### 30-2. タスクが0件の場合
全Issueをクローズした状態で実行。
期待: 「全タスク: 0件」と表示される。エラーにはならない。

### 30-3. 見積もり情報の表示
見積もり付き next タスクが2件、見積なし next タスクが1件ある状態で実行。
期待: 「時間」セクションに見積合計（例: 3h）、見積あり件数、見積なし件数が表示される。

---

## 31. list-all フィルタ拡張

### 31-1. 優先度フィルタ
```
/todo list --priority p1
```
期待: p1 ラベルのタスクのみ表示される。p2/p3 のタスクは除外される。

### 31-2. プロジェクトフィルタ
```
/todo list --project 7
```
期待: body に `project: #7` を含むタスクのみ表示される。

### 31-3. ソート順序（sortByPriDue）
フィルタ指定ありの場合、フラットリストが優先度順→期日順でソートされる。
期待: p1 → p2 → p3 → 優先度なしの順。同優先度内は期日の早い順。

---

## 32. renderIssueList 表示

### 32-1. 見積もり時間の表示
見積もり付きタスク（estimate: 90）が一覧に表示される場合。
期待: `⏱1h30m` が行に含まれる。

### 32-2. コンテキスト・期日の表示
`@PC` ラベル付き、due: 2026-04-10 のタスク。
期待: `[@PC]` と `📅 2026-04-10` が行に含まれる。

---

## 33. listSummary / weeklySummary

### 33-1. listSummary
タスクがある状態で実行。
期待: カテゴリ別件数サマリー（例: `next: 2件 / inbox: 1件`）が表示される。

### 33-2. weeklySummary
期限超過タスクと inbox タスクがある状態で実行。
期待: 「週次レビュー サマリー」ヘッダー、期限超過件数、Inbox 件数が表示される。

---

## 34. Dashboard 見積もり合計

### 34-1. 今日のタスク見積もり合計
期限超過（estimate: 60）と今日期限（estimate: 90）のタスクがある場合。
期待: Dashboard のサマリー行に `⏱今日の見積: 2h30m` が表示される。

---

## 35. Report 見積 vs 実績

### 35-1. 予実分析セクション
期間内に見積もり・実績ありの完了タスクがある場合。
期待: 「見積 vs 実績」セクションに見積合計、実績合計、予実比（%）、見積+実績あり件数が表示される。

### 35-2. 予実比の計算
estimate: 60 + 120 = 180分、actual: 90 + 100 = 190分の場合。
期待: 予実比が `106%` と表示される。

---

## 36. activate / before / promote（チクラーファイル）

### 36-1. --activate 付きで add（正常系）
```
/todo inbox チクラーテスト --activate 2026-05-01
```
期待: Issue が作成され、body に `activate: 2026-05-01` が含まれる。完了メッセージに「昇格予定: 2026-05-01」が表示される。

### 36-2. --due + --before 付きで add（正常系）
```
/todo inbox 期日前通知テスト --due 2026-05-15 --before 14d
```
期待: Issue が作成され、body に `due: 2026-05-15`、`activate: 2026-05-01`、`before: 14d` が含まれる。
（2026-05-15 の 14日前 = 2026-05-01 が activate として計算される）

### 36-3. --activate + --due 両方指定で add（正常系）
```
/todo inbox 明示activate + due --due 2026-06-01 --activate 2026-05-20
```
期待: body に `due: 2026-06-01`、`activate: 2026-05-20` が含まれる。警告なし（activate < due）。

### 36-4. --activate + --before 同時指定（早い方が採用）
```
/todo inbox 早い方優先テスト --due 2026-06-01 --before 14d --activate 2026-05-10
```
期待: before から計算すると activate = 2026-05-18（6/1 の 14日前）。--activate で指定した 2026-05-10 の方が早いため、body の `activate:` は `2026-05-10` が採用される。

### 36-5. --before のみ（dueなし）→ エラー（異常系）
```
/todo inbox dueなしbeforeテスト --before 14d
```
期待: エラーメッセージ「--before を使うには --due が必要です」。Issue は作成されない。

### 36-6. activate日 > due日 → 警告（異常系）
```
/todo inbox activate後行テスト --due 2026-05-01 --activate 2026-06-01
```
期待: 警告メッセージ「activate日（2026-06-01）が due日（2026-05-01）より後です」が stderr に出力される。Issue 自体は作成される（警告のみ、エラーではない）。

### 36-7. edit でactivate後付け
既存の Issue（before/activate なし）に対して:
```
/todo edit <番号> --activate 2026-05-01
```
期待: body に `activate: 2026-05-01` が追加される。due/recur/project/desc は変わらない。完了メッセージに「activate → 2026-05-01」が含まれる。

### 36-8. edit でactivate clear
activate が設定済みの Issue に対して:
```
/todo edit <番号> --activate clear
```
期待: body から `activate:` 行と `before:` 行が除去される。完了メッセージに「activate → クリア」が含まれる。

### 36-9. edit でdue変更時のactivate再計算（beforeあり）
`before: 14d` が設定済みの Issue に対して:
```
/todo edit <番号> --due 2026-07-01
```
期待: before から activate が再計算され、body の `activate:` が `2026-06-17`（7/1 の 14日前）に更新される。完了メッセージに「activate 再計算 → 2026-06-17」が含まれる。

### 36-10. promote で昇格対象ありの場合
activate 日が本日以前（例: 2026-04-01）に設定済みの inbox Issue がある状態で:
```
/todo promote
```
期待: 対象 Issue の GTD ラベルが `next` に変更される。完了メッセージ「#<番号> 「<タイトル>」を next に昇格しました（activate: 2026-04-01）」と「N件を next に昇格しました」が表示される。

### 36-11. promote で昇格対象なしの場合
activate が設定されていない、または activate 日が未来のタスクしか存在しない状態で:
```
/todo promote
```
期待: 「昇格対象なし（activate日到来タスク: 0件）」が表示される。

### 36-12. 既にnextのタスクはpromoteでスキップされるか
activate 日が本日以前かつ GTD ラベルが既に `next` の Issue がある状態で:
```
/todo promote
```
期待: そのIssueに対してラベル付け替え処理が行われない（エラーにもならない）。next に既にいるタスクはスキップまたは無変化で処理される。昇格件数にはカウントされない。

### 36-13. 不正な --activate 日付でエラー終了（異常系）
```
/todo inbox テスト --activate foo
```
期待: stderr に「エラー: 不正な日付形式です: foo」が出力され、プロセスが終了コード1で終了する。Issue は作成されない。

edit でも同様：
```
/todo edit <番号> --activate bar
```
期待: 同様のエラーが出力され、Issue は更新されない。

### 36-14. `--before clear` でactivateも連動クリア（正常系）
before と activate が設定済みの Issue に対して:
```
/todo edit <番号> --before clear
```
期待: body から `before:` 行と `activate:` 行の両方が除去される。完了メッセージに「before → クリア」が含まれる。

### 36-15. `0d` / `0w` のbeforeでエラー終了（異常系）
```
/todo inbox テスト --due 2026-05-01 --before 0d
```
期待: stderr に「エラー: --before の形式が不正です」が出力され、プロセスが終了コード1で終了する。Issue は作成されない。

`0w` でも同様に拒否されること。

---

## 37. Someday reviewed_at（Issue #435）

### 37-1. review-someday で reviewed_at が更新される（N-1）
```
/todo review-someday 42
```
期待: Issue #42 の body に `reviewed_at: <今日の日付>` が追加または更新される。stdout に「✅ #42 の reviewed_at を YYYY-MM-DD に更新しました。」が出力される。

### 37-2. list someday で30日以上未見直しタスクが⚠️マーク付きで先頭に表示される（N-2）
（somedayタスク #42 の reviewed_at が今日から31日前に設定された状態）
```
/todo list someday
```
期待: #42 が⚠️マーク付きでリスト先頭に表示される。

### 37-3. list someday で最近見直したタスクは⚠️マークなし（N-3）
（somedayタスクの reviewed_at が1日前）
```
/todo list someday
```
期待: ⚠️マークなし、通常表示。

### 37-4. reviewed_at 未設定の someday タスクは⚠️マーク付きで先頭表示（N-4）
（somedayタスクの body に reviewed_at フィールドなし）
```
/todo list someday
```
期待: ⚠️マーク付きでリスト先頭に表示される。

### 37-5. 同日に review-someday を2回実行してもエラーにならない（N-5）
```
/todo review-someday 42
/todo review-someday 42
```
期待: 2回目もエラーなし。body の reviewed_at は同じ日付（べき等）。

### 37-6. edit --due 後も reviewed_at が維持される（N-6 / R-1）
（somedayタスク #42 に reviewed_at が設定された状態）
```
/todo edit 42 --due 2026-06-01
```
期待: body の `reviewed_at` フィールドが変更前と同じ値で残っている。

### 37-7. move someday 直後は reviewed_at が更新されない（N-7）
```
/todo move 99 someday
/todo list someday
```
期待: #99 は⚠️マーク付きで表示される（move ではreviewed_atを更新しないため）。

### 37-8. nextタスクに review-someday を実行するとエラー（E-1）
```
/todo review-someday <nextタスクの番号>
```
期待: stderr に「エラー: #N はsomedayタスクではありません。」が出力され、exit(1)で終了。Issue は変更されない。

### 37-9. 番号なしで review-someday を実行するとUsageメッセージ（E-3）

```
/todo review-someday
```

期待: stderr に「Usage: run review-someday NUMBER」が出力され、exit(1)で終了。

### 37-10. reviewed_at に不正フォーマットが含まれていても浮上対象になる（E-4）
（body に `reviewed_at: invalid-date` が含まれるsomedayタスク）
```
/todo list someday
```
期待: 正規表現にマッチしないため空扱い → ⚠️マーク付きで先頭に表示される。

### 37-11. list next / waiting で⚠️マークが出ない（R-3）
```
/todo list next
/todo list waiting
```
期待: すべてのタスクに⚠️マークが付かない。someday 専用の挙動であること。

### 37-12. someday 以外のソート順が変わらない（R-4）
（⚠️なしのsomedayタスク群）
```
/todo list someday
```
期待: ⚠️なし群の順序は sortByPriDue（優先度 → due日付）が維持される。

### 37-13. recur タスク完了後の再作成で reviewed_at が引き継がれない（R-6）
（weekly recur + reviewed_at ありのタスクを /todo done で完了）
```
/todo done <番号>
```
期待: 再作成された繰り返しタスクの body に `reviewed_at` フィールドが含まれない。

---

## 38. sub-issue Phase 1 互換レイヤ（P シリーズ）

> Phase 1 では body の `project: #N` メタ行を書き続けながら、GitHub sub-issue API への登録も行う。

### P-02. `--project N` で sub-issue が登録される

前提: Issue #N が `📁 project` ラベルを持つ。
```
/todo next サブタスク --project N
```
期待:
- body に `project: #N` が含まれる（従来通り）
- GitHub の `GET /repos/.../issues/N/sub_issues` で作成した Issue が sub-issue として一覧に含まれる
- テスト確認コマンド: `gh api repos/OWNER/REPO/issues/N/sub_issues --jq '[.[].number]'`

### P-04. 親 N が存在しないときエラーになること

前提: Issue #9999999 が存在しない。
```
/todo next サブタスク --project 9999999
```
期待:
- `fetchAndParseIssue` が 404 エラーを返す
- stderr に「プロジェクト #9999999 の取得に失敗しました」が出力される
- Issue は作成されている（Issue 作成後にエラー → 子 Issue は残る）

### P-09. `/todo link X N` で sub-issue + body メタの両方が設定されること

前提: Issue #X（子）と Issue #N（`📁 project` ラベル付き親）が存在する。
```
/todo link X N
```
期待:
- Issue #X の body に `project: #N` が書き込まれる（従来通り）
- `GET /repos/.../issues/N/sub_issues` に Issue #X が含まれる
- 親が `📁 project` ラベルを持たない場合はエラー「#N はプロジェクトではありません。先に /todo project で作成してください」

### P-19. `--project` なし `/todo next` がリグレッションしないこと

```
/todo next 普通のタスク
```
期待:
- Issue が通常通り作成される（`next` + `p3` ラベル）
- body に `project:` 行が存在しない
- sub-issue API は呼ばれない
- 既存の `--project` なしタスクへの影響がゼロ

### P-22. テンプレートの `--project N` が引き続き子として登録されること

前提: テンプレートに `project: N` が設定済み。Issue #N が `📁 project` ラベルを持つ。
```
/todo template use <テンプレート名> タスクタイトル
```
期待:
- Issue が作成され、body に `project: #N` が含まれる
- 作成した Issue が `GET /repos/.../issues/N/sub_issues` 一覧に含まれる

### P-23. sub-issue API が失敗（422 以外）しても子 Issue は残り警告が出ること

前提: ネットワーク断絶または不正 `sub_issue_id: 0` で API 失敗を模擬。
期待:
- 子 Issue はオープン状態で残る（削除・クローズされない）
- stderr に「⚠️ sub-issue 登録失敗（Issue は作成済み）: ...」が出力される
- プロセスは exit(1) にならない（処理継続）

---

## ##39 Phase 3: weekly-project-audit / migrate sub-issue テスト（P-07〜P-18）

### P-07. `/todo list` で next 欠落プロジェクトの ⚠️ マーカー表示

前提:
- `📁 project` ラベルを持つ Issue が存在
- その Issue に紐づく `next` 子タスクが 0件

```
/todo list
```
期待:
- プロジェクトセクションのヘッダに「⚠️ next欠落: N件」バッジが表示される
- 対象プロジェクト行の行頭（または statusStr）に ⚠️ が表示される

### P-08. `/todo list` で停滞 30 日プロジェクトの停滞バッジ表示

前提:
- `📁 project` ラベルを持つ Issue の `updated_at` が 30 日以上前

```
/todo list
```
期待:
- プロジェクトセクションのヘッダに「停滞30日以上: N件」バッジが表示される
- 停滞かつ next 欠落の行頭に ⚠️ マーカーが付く

### P-13. `/todo migrate sub-issue --dry-run` が対象一覧を表示

前提: body に `project: #N` を持つ Issue が複数存在する

```
/todo migrate sub-issue --dry-run
```
期待:
- 対象 Issue の一覧（番号・タイトル・親番号）が表示される
- 実際の sub-issue 登録は行われない（API 呼び出しなし）
- 末尾に「--dry-run モード: 実際の登録は行いません。」が表示される

### P-14. `/todo migrate sub-issue` 実行後 sub-issue が登録される

前提:
- `📁 project` ラベルを持つ親 Issue が存在
- body に `project: #<親番号>` を持つ子 Issue が存在

```
/todo migrate sub-issue
```
期待:
- 子 Issue が `GET /repos/.../issues/<親番号>/sub_issues` 一覧に含まれる
- 末尾に「N件登録 / M件スキップ / K件エラー」の集計が表示される

### P-15. マイグレーション冪等性（2回実行で重複なし）

前提: P-14 で既に sub-issue 登録済みの状態

```
/todo migrate sub-issue
```
期待:
- 2回目の実行では 422（既登録）がスキップされる
- 集計に「N件登録: 0 / M件スキップ: 1」が反映される（重複登録なし）

### P-16. `/todo weekly-project-audit` が全プロジェクトを列挙

前提: `📁 project` ラベルを持つ Issue が複数存在する

```
/todo weekly-project-audit
```
期待:
- 「## 📁 プロジェクト棚卸し（全N件）」ヘッダが出力される
- 各プロジェクトが `[idx/total] #番号 タイトル` 形式で列挙される
- 子タスクの `next=N件 waiting=N件 someday=N件` が表示される

### P-17. next 欠落プロジェクトの検出

前提:
- プロジェクト A: next 子タスクあり
- プロジェクト B: next 子タスクなし

```
/todo weekly-project-audit
```
期待:
- プロジェクト B に「判定: ⚠️ next欠落」が表示される
- 対応候補コマンド（`/todo next ... --project N` 等）が提示される

### P-18. `reviewed_at` が親 Issue body に書き込まれる

前提: next 欠落または停滞プロジェクトが存在する

```
/todo weekly-project-audit
```
期待:
- 該当プロジェクトの親 Issue body に `reviewed_at: YYYY-MM-DD`（今日の日付）が書き込まれる
- `/todo list` でそのプロジェクトに「最終レビュー: 0日前」が表示される

---

## 40. Phase 2 モバイル対応（iOS Shortcuts）

### 40-1. inbox への追加（M2-1）

前提: iOS Shortcuts から GitHub REST API を直接呼び出す。

```
POST /repos/{owner}/{repo}/issues
{ "title": "買い物リストを更新する", "labels": ["📥 inbox"] }
```
期待:
- `📥 inbox` ラベルの Issue が作成される
- タイトルが入力テキストと一致する
- 作成した Issue の URL が通知される

### 40-2. 今日のタスク確認（M2-2）

```
GET /repos/{owner}/{repo}/issues?labels=%F0%9F%8E%AF%20next&state=open&per_page=20
```
期待:
- `🎯 next` ラベルを持つオープン Issue のみ返る（`inbox` / `waiting` 等は含まれない）
- 0件のときは「今日の next タスクはありません」と通知される
- HTTP 401 時は「認証エラー。PATを確認してください」と通知される

### 40-3. タスク完了（M2-3）

前提: 完了対象は `🎯 next` ラベルのタスクのみ。

```
PATCH /repos/{owner}/{repo}/issues/{number}
{ "state": "closed", "state_reason": "completed" }
```
期待:
- `state: "closed"` / `state_reason: "completed"` でクローズされる
- `completed` ラベルは付与されない（state_reason のみ）
- クローズ後は next 一覧から除外される
- 既にクローズ済みの Issue への再 PATCH は冪等（state: closed を返すだけ）

### 40-4. 空タイトルのバリデーション（M2-4、異常系）

```
POST /repos/{owner}/{repo}/issues
{ "title": "", "labels": ["📥 inbox"] }
```
期待:
- GitHub API が 422 を返す（クライアント側でも空チェックを行い、APIを呼ばない）

### 40-5. inbox 以外のタスクはモバイルから完了できない（意図的制約）

完了操作の前に `GET ?labels=next&state=open` で選択リストを取得する仕様のため、
`inbox` / `waiting` 等のタスクはそもそもリストに表示されない。
期待:
- 選択リストに `🎯 next` 以外のラベルのタスクが出現しない
