// octokit-stub.js — 記録型スタブ Octokit ファクトリ（Issue #1648）
//
// todo-engine.js の initOctokit() が OCTOKIT_STUB_ENV を検知したときに読み込む
// CommonJS モジュール。実 @octokit/rest の代わりにこのスタブを返すことで、
// 書き込み系ハンドラ（runAdd/runDone/runEdit/runBulk/runView/runPriority 等）を
// GitHub 接続なし・トークンなしでテストできるようにする。
//
// 責務は2つ:
//   1. 記録（JSONL）: 呼び出しごとに { ts, method, args } を1行のJSONとして
//      logPath に追記する。子プロセス（node todo-engine.js run ...）内の
//      呼び出しを親の bash テストプロセスから事後に読める形で永続化するため、
//      インメモリではなくファイルJSONLにする。
//   2. 応答（レスポンス解決）: responsesSpec をパースし、メソッド名（または
//      request() のルート文字列）をキーとしたキュー（配列）から呼び出し順に
//      1件ずつ返す。キューが尽きた場合・キー自体が存在しない場合は
//      サイレントに {} を返さず、明示的にエラーを throw する
//      （テストシナリオの記述不足を握りつぶさないため。設計書の核）。
//
// 使い方（todo-engine.js の initOctokit() から呼ばれる想定）:
//   const createStubOctokit = require('/path/to/octokit-stub.js');
//   const octokit = createStubOctokit({
//     logPath: process.env.OCTOKIT_STUB_LOG_ENV || null,
//     responsesSpec: process.env.OCTOKIT_STUB_RESPONSES_ENV || null,
//   });
//
// responsesSpec の形式:
//   JSON文字列: '{ "issues.get": [{"data": {...}}], "issues.create": [{"data": {...}}] }'
//   ファイル参照: '@/path/to/fixture.json'（先頭が '@' の場合、そのパスを読み込む）
//   各キューの要素に { "__throw": true, "status": 404, "message": "Not Found" } を
//   指定すると、その回の呼び出しで status プロパティ付きの Error を throw する。

// 各キューの要素に { "__delayMs": 50 } を指定すると、応答を返す（または
//   __throw する）前に指定ms分 setTimeout で人為的に遅延させる（Issue #455の
//   TODO_TIMING テストで、並行呼び出しの区間統合ロジックを検証するために使う。
//   遅延なしのスタブでは並行呼び出しの重なりが実測に現れないため）。

'use strict';
const fs = require('fs');
const path = require('path');

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function parseResponsesSpec(spec) {
  if (!spec) return {};
  let raw = spec;
  if (typeof spec === 'string' && spec.startsWith('@')) {
    const fpath = path.resolve(spec.slice(1));
    raw = fs.readFileSync(fpath, 'utf8');
  }
  if (typeof raw === 'string') {
    return JSON.parse(raw);
  }
  return raw; // 既にオブジェクトの場合はそのまま使う
}

function createStubOctokit({ logPath, responsesSpec } = {}) {
  const responses = parseResponsesSpec(responsesSpec);
  const callCounts = {};

  function recordCall(methodKey, args) {
    if (!logPath) return;
    const line = JSON.stringify({ ts: new Date().toISOString(), method: methodKey, args: args || {} });
    try {
      fs.appendFileSync(logPath, line + '\n');
    } catch (e) {
      // ロギング失敗はテスト実行そのものを止めない（記録は補助情報のため）
    }
  }

  async function nextResponse(methodKey) {
    const queue = responses[methodKey];
    const callNum = (callCounts[methodKey] = (callCounts[methodKey] || 0) + 1);
    if (!Array.isArray(queue) || queue.length === 0) {
      throw new Error(`OCTOKIT_STUB: no response configured for ${methodKey} (call #${callNum})`);
    }
    const item = queue.shift();
    if (item && typeof item === 'object' && typeof item.__delayMs === 'number') {
      await delay(item.__delayMs);
    }
    if (item && typeof item === 'object' && item.__throw) {
      const err = new Error(item.message || `OCTOKIT_STUB: simulated error for ${methodKey}`);
      if (item.status !== undefined) err.status = item.status;
      throw err;
    }
    return item;
  }

  async function resolve(methodKey, args) {
    recordCall(methodKey, args);
    return nextResponse(methodKey);
  }

  // 実 @octokit/rest の各メソッド（issues.* だけでなく request も含む）は
  // .endpoint（さらに .parse を持つ）/ .defaults という関数プロパティを own property
  // として持ち、ライブラリ内部がこれらを参照する（実測: 2026-08-29、Issue #455。
  // TODO_TIMING=1 のラッパーがこれらを引き継がず実 GitHub API 呼び出しが機能停止した
  // 不具合の原因）。スタブの各メソッドにも同形のダミー関数プロパティを生やし、
  // wrapOctokitTiming() のプロパティ保持をスタブ経由でも構造的に検証できるようにする。
  function attachOctokitLikeProps(fn) {
    fn.endpoint = function endpoint() {};
    fn.endpoint.parse = function parse() {};
    fn.defaults = function defaults() {};
    return fn;
  }

  // 使用面（grep実測。todo-engine.js が呼ぶ Octokit メソッド一覧）
  const ISSUES_METHODS = [
    'listForRepo', 'get', 'listComments', 'create', 'update',
    'addLabels', 'removeLabel', 'createLabel', 'deleteLabel',
    'createComment', 'listLabelsForRepo',
  ];
  const issues = {};
  for (const m of ISSUES_METHODS) {
    issues[m] = attachOctokitLikeProps(async (args) => resolve('issues.' + m, args));
  }

  const search = {
    issuesAndPullRequests: attachOctokitLikeProps(async (args) => resolve('search.issuesAndPullRequests', args)),
  };

  // sub-issue 系ヘルパ（addSubIssue/listSubIssues/removeSubIssue）や
  // ensureLabel（GET /repos/{owner}/{repo}/labels/{name}）が使う汎用リクエスト。
  // route 文字列そのものをキーとする（例: 'POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues'）。
  async function request(route, params) {
    return resolve(route, params);
  }
  attachOctokitLikeProps(request);

  return { issues, search, request };
}

module.exports = createStubOctokit;
