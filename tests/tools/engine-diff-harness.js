#!/usr/bin/env node
// engine-diff-harness.js — 旧エンジンと新エンジンの出力を突き合わせる差分ハーネス
//
// 目的
//   todo-engine.js の内部整理（挙動を変えない抽出）を行うとき、「変更の前後で外から見える
//   挙動が1バイトも変わっていないこと」を機械的に確かめる。比較するのは次の5つ:
//     stdout / stderr / 終了コード / スタブの呼び出しログ（method と args。順序も含む）/
//     実行後の HOME/.claude 以下のファイル内容
//   既存のテストは「現在の挙動が何か」を固定するもの、このハーネスは「前後で同じか」を見るもの。
//
// 使い方
//   # 変更前のエンジンを git から書き出して基準（旧）にする
//   git show HEAD:todo-engine.js > /tmp/engine-old.js
//   node tests/tools/engine-diff-harness.js --old /tmp/engine-old.js --new todo-engine.js
//
//   --old <path>            比較の基準にするエンジン（必須）
//   --new <path>            比較対象のエンジン（必須）
//   --stub <path>           スタブ Octokit（既定: このファイルの ../stubs/octokit-stub.js）
//   --only <text>           ケース ID に text を含むものだけ実行する
//   --lang ja|en            片方の言語だけ実行する（既定: 各ケースの langs）
//   --list                  ケース一覧を表示して終了する（何も実行しない）
//   --corpus <file.js>      追加のケース（module.exports = [...]）を読み込む
//   --allow-diff <ids>      差分が「出てよい」ケース ID（カンマ区切り、前方一致）。意図した挙動変更を
//                           入れる変更で使う。許可したケースは差分が出ることを確かめ、
//                           それ以外のケースは一致することを確かめる
//   --coverage-lines A-B[,C-D...]
//                           旧エンジンの行範囲が、いずれかのケースで実行されたことを確かめる
//                           （NODE_V8_COVERAGE を使う。process.exit() で終わる経路も記録される）。
//                           実行されていない行があれば失敗にする
//   --verbose               一致したケースも表示する
//
//   終了コード: 0=全件OK / 1=不一致・到達できなかったケースあり / 2=実行前の検査に失敗（1件も実行していない）
//
// コーパス（ケース）の追加方法
//   このファイル末尾の CORPUS に1件ずつ足す。形は次のとおり。
//     {
//       id:        'a1-done-plain',                // 一意な識別子
//       argv:      ['run', 'done', '301'],         // todo-engine.js に渡す引数。'{HOME}' は隔離 HOME のパスに置換される
//       responses: { 'issues.get': [ ... ] },      // スタブへ渡す応答（OCTOKIT_STUB_RESPONSES_ENV にそのまま渡る）
//                                                  //   失敗させる回は { __throw: true, status: 404, message: '...' }
//       files:     { '.claude/todo-templates.json': {...}, 'body.txt': 'text' },  // 隔離 HOME に置くファイル（省略可）
//                                                  //   キーが '/' で終わるとディレクトリを作る
//       env:       { OPEN_ENV: '[...]' },          // 追加の環境変数（省略可）
//       langs:     ['ja', 'en'],                   // 既定は両方
//       marker:    { ... },                        // 必須。そのケースが狙った分岐を通ったときだけ現れる印（下記）
//     }
//   marker の書き方（指定した条件がすべて成り立つこと。値は文字列、または { ja, en }）
//     { stdout: 'text' }              stdout に含まれる
//     { stderr: 'text' }              stderr に含まれる
//     { out: 'text' }                 stdout か stderr のどちらかに含まれる
//     { log: 'issues.addLabels' }     スタブログのいずれかの行に含まれる（method や args の断片）
//     { logSeq: ['a', 'b'] }          スタブログに、この順で（間に他の行があってもよい）現れる
//     { exit: 1 }                     終了コード
//   旧エンジンで実行して marker が現れないケースは「到達できていない」として失敗にする。
//   届いていない分岐を比較しても、一致は何の保証にもならない。応答の与え方を直してから比較すること。
//
// HOME の隔離とスタブ指定が必須である理由
//   ハーネスは done / move / tag / template save など書き込み系のコマンドを実行する。
//   スタブ（OCTOKIT_STUB_ENV）を外すと実際の GitHub に書き込み、HOME を隔離しないと本物のテンプレート・
//   ビュー定義のファイルを書き換える。そのため
//     - 子プロセスの環境は、このハーネスが明示的に組み立てたものだけを渡す（呼び出し元の環境は引き継がない。
//       GH_TOKEN / GITHUB_TOKEN も渡さない）
//     - HOME は毎回新しい一時ディレクトリにする
//     - 起動時に、スタブと隔離 HOME が実際に効いていることを確かめるカナリア実行を行い、
//       確かめられなければ1件も実行せずに終了する（終了コード 2）
//   ログが読めなかった場合も「呼び出しなし」とは扱わず、そのケースを失敗にする。

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { pathToFileURL } = require('url');

// ─── 定数 ─────────────────────────────────────
const FIXED_ENV = Object.freeze({
  TODO_REPO_OWNER: 'test',
  TODO_REPO_NAME: 'test',
  TODAY: '2026-10-18',
  TZ: 'Asia/Tokyo',
});
const LBL = 'GET /repos/{owner}/{repo}/labels/{name}';
const SUB = 'POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues';
const E404 = { __throw: true, status: 404, message: 'Not Found' };
const E500 = { __throw: true, status: 500, message: 'boom' };

// ─── 小さな道具 ──────────────────────────────────
function die(msg) { process.stderr.write('engine-diff-harness: ' + msg + '\n'); process.exit(2); }

function parseCli(argv) {
  const o = { lang: null, only: null, list: false, verbose: false, corpus: [], allow: [], cov: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) die(a + ' に値がありません'); return argv[++i]; };
    if (a === '--old') o.old = val();
    else if (a === '--new') o.new = val();
    else if (a === '--stub') o.stub = val();
    else if (a === '--only') o.only = val();
    else if (a === '--lang') { o.lang = val(); if (!['ja', 'en'].includes(o.lang)) die('--lang は ja か en'); }
    else if (a === '--list') o.list = true;
    else if (a === '--verbose') o.verbose = true;
    else if (a === '--corpus') o.corpus.push(val());
    else if (a === '--allow-diff') o.allow.push(...val().split(',').map(s => s.trim()).filter(Boolean));
    else if (a === '--coverage-lines') o.cov = parseRanges(val());
    else die('未知のオプション: ' + a);
  }
  return o;
}

function parseRanges(s) {
  return s.split(',').map(p => {
    const m = /^(\d+)-(\d+)$/.exec(p.trim());
    if (!m || +m[1] > +m[2]) die('--coverage-lines の形式は A-B[,C-D]: ' + p);
    return [+m[1], +m[2]];
  });
}

function langText(v, lang) { return (v && typeof v === 'object' && !Array.isArray(v)) ? v[lang] : v; }

// ─── 隔離環境 ────────────────────────────────────
// 子プロセスに渡す環境を組み立て、隔離条件を満たしているか検査する。満たさなければ throw（実行しない）。
function buildEnv({ home, stub, logPath, responses, lang, extra }) {
  const env = {
    PATH: process.env.PATH || '/usr/bin:/bin',
    HOME: home,
    OCTOKIT_STUB_ENV: stub,
    OCTOKIT_STUB_LOG_ENV: logPath,
    OCTOKIT_STUB_RESPONSES_ENV: JSON.stringify(responses || {}),
    ...FIXED_ENV,
    ...(extra || {}),
  };
  if (lang === 'en') env.LANG_ENV = 'en';
  assertSandbox(env);
  return env;
}

function assertSandbox(env) {
  const tmp = fs.realpathSync(os.tmpdir());
  const fail = (m) => { throw new Error('隔離条件を満たしていないため実行しない: ' + m); };
  if (!env.HOME) fail('HOME が未設定');
  let realHome;
  try { realHome = fs.realpathSync(env.HOME); } catch (e) { fail('HOME が存在しない: ' + env.HOME); }
  if (!realHome.startsWith(tmp + path.sep)) fail('HOME が一時ディレクトリ配下ではない: ' + realHome);
  if (process.env.HOME && realHome === fs.realpathSync(process.env.HOME)) fail('HOME が呼び出し元の HOME と同じ');
  if (!env.OCTOKIT_STUB_ENV || !fs.existsSync(env.OCTOKIT_STUB_ENV)) fail('OCTOKIT_STUB_ENV のスタブが存在しない: ' + env.OCTOKIT_STUB_ENV);
  if (!env.OCTOKIT_STUB_LOG_ENV) fail('OCTOKIT_STUB_LOG_ENV が未設定');
  if (env.GH_TOKEN || env.GITHUB_TOKEN) fail('GH_TOKEN / GITHUB_TOKEN が設定されている');
}

function mkHome() { return fs.mkdtempSync(path.join(os.tmpdir(), 'engine-diff-home-')); }
function rmHome(h) { try { fs.rmSync(h, { recursive: true, force: true }); } catch (e) { /* 後始末の失敗は結果に影響しない */ } }

function placeFiles(home, files) {
  for (const [rel, content] of Object.entries(files || {})) {
    if (rel.startsWith('/') || rel.split('/').includes('..')) throw new Error('files のキーは HOME 内の相対パス: ' + rel);
    const p = path.join(home, rel);
    if (rel.endsWith('/')) { fs.mkdirSync(p, { recursive: true }); continue; }
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, typeof content === 'string' ? content : JSON.stringify(content, null, 2));
  }
}

function listFiles(dir, base) {
  const out = {};
  if (!fs.existsSync(dir)) return out;
  for (const name of fs.readdirSync(dir).sort()) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) Object.assign(out, listFiles(p, base));
    else out[path.relative(base, p)] = fs.readFileSync(p, 'utf8');
  }
  return out;
}

// ─── 1回の実行 ───────────────────────────────────
function runOnce(engine, c, lang, stub, opts) {
  const home = mkHome();
  try {
    const logPath = path.join(home, '.stub-log.jsonl');
    fs.writeFileSync(logPath, '');                       // 先に空で作る。実行後に無ければ「読めない」として失敗にする
    placeFiles(home, c.files);
    const env = buildEnv({ home, stub, logPath, responses: c.responses, lang, extra: c.env });
    let covDir = null;
    if (opts && opts.coverage) { covDir = path.join(home, '.v8cov'); env.NODE_V8_COVERAGE = covDir; }
    const argv = (c.argv || []).map(a => String(a).split('{HOME}').join(home));
    const r = spawnSync(process.execPath, [engine, ...argv], { env, cwd: home, encoding: 'utf8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 });
    const res = { status: r.status, signal: r.signal || null, spawnError: r.error ? String(r.error.message) : null, stdout: r.stdout || '', stderr: r.stderr || '', problems: [] };
    if (res.spawnError || res.signal) res.problems.push('実行失敗: ' + (res.spawnError || res.signal));
    // スタブログ
    if (!fs.existsSync(logPath)) { res.log = null; res.problems.push('スタブログが読めない'); }
    else {
      res.log = [];
      for (const line of fs.readFileSync(logPath, 'utf8').split('\n').filter(Boolean)) {
        try { const j = JSON.parse(line); res.log.push(JSON.stringify({ method: j.method, args: j.args })); }
        catch (e) { res.problems.push('スタブログの行を解釈できない: ' + line.slice(0, 80)); }
      }
    }
    // HOME 以下のファイル（スタブログと V8 の出力は除く）
    const files = listFiles(home, home);
    for (const k of Object.keys(files)) if (k === '.stub-log.jsonl' || k.startsWith('.v8cov')) delete files[k];
    res.files = files;
    // HOME のパスは実行ごとに違うので、比較前に固定の文字列へ置き換える
    const homes = [home, fs.realpathSync(home)];
    const norm = (s) => homes.reduce((acc, h) => acc.split(h).join('<HOME>'), s);
    res.stdout = norm(res.stdout); res.stderr = norm(res.stderr);
    if (res.log) res.log = res.log.map(norm);
    for (const k of Object.keys(res.files)) res.files[k] = norm(res.files[k]);
    if (covDir) res.executedLines = collectExecutedLines(covDir, engine);
    return res;
  } finally { rmHome(home); }
}

// ─── marker の判定 ───────────────────────────────
function checkMarker(m, res, lang) {
  const miss = [];
  const has = (s, t) => typeof t === 'string' && t.length > 0 && s.includes(t);
  const need = (label, ok) => { if (!ok) miss.push(label); };
  if ('stdout' in m) need('stdout:' + langText(m.stdout, lang), has(res.stdout, langText(m.stdout, lang)));
  if ('stderr' in m) need('stderr:' + langText(m.stderr, lang), has(res.stderr, langText(m.stderr, lang)));
  if ('out' in m) { const t = langText(m.out, lang); need('out:' + t, has(res.stdout, t) || has(res.stderr, t)); }
  if ('log' in m) { const t = langText(m.log, lang); need('log:' + t, !!res.log && res.log.some(l => has(l, t))); }
  if ('logSeq' in m) {
    let idx = 0;
    const seq = m.logSeq.map(x => langText(x, lang));
    for (const l of (res.log || [])) { if (idx < seq.length && has(l, seq[idx])) idx++; }
    need('logSeq:' + seq.join(' > ') + ' (到達 ' + idx + '/' + seq.length + ')', !!res.log && idx === seq.length);
  }
  if ('exit' in m) need('exit:' + m.exit + ' (実際 ' + res.status + ')', res.status === m.exit);
  return miss;
}

// ─── 比較 ────────────────────────────────────
function diffResults(a, b) {
  const d = [];
  if (a.status !== b.status) d.push(['exit', a.status, b.status]);
  if (a.stdout !== b.stdout) d.push(['stdout', a.stdout, b.stdout]);
  if (a.stderr !== b.stderr) d.push(['stderr', a.stderr, b.stderr]);
  if (JSON.stringify(a.log) !== JSON.stringify(b.log)) d.push(['stub-log', (a.log || []).join('\n'), (b.log || []).join('\n')]);
  if (JSON.stringify(a.files) !== JSON.stringify(b.files)) d.push(['home-files', JSON.stringify(a.files, null, 1), JSON.stringify(b.files, null, 1)]);
  return d;
}

function clip(s, n) { s = String(s); return s.length > n ? s.slice(0, n) + '…(' + s.length + '文字)' : s; }

// ─── 行カバレッジ（NODE_V8_COVERAGE）────────────────
// 各行の先頭の非空白文字の位置を含む最も内側の範囲の count が 0 より大きければ、その行は実行されたとみなす。
function collectExecutedLines(covDir, engine) {
  const set = new Set();
  if (!fs.existsSync(covDir)) return set;
  const url = pathToFileURL(fs.realpathSync(engine)).href;
  const src = fs.readFileSync(engine, 'utf8');
  const starts = [];                                    // 各行の先頭の非空白文字のオフセット（空行・コメント行は -1）
  let off = 0;
  for (const line of src.split('\n')) {
    const m = /\S/.exec(line);
    starts.push(m && !line.slice(m.index).startsWith('//') ? off + m.index : -1);
    off += line.length + 1;
  }
  for (const f of fs.readdirSync(covDir)) {
    let j;
    try { j = JSON.parse(fs.readFileSync(path.join(covDir, f), 'utf8')); } catch (e) { continue; }
    const script = (j.result || []).find(r => r.url === url);
    if (!script) continue;
    const ranges = [];
    for (const fn of script.functions) for (const r of fn.ranges) ranges.push(r);
    starts.forEach((o, i) => {
      if (o < 0) return;
      let best = null;
      for (const r of ranges) if (r.startOffset <= o && o < r.endOffset && (!best || (r.endOffset - r.startOffset) <= (best.endOffset - best.startOffset))) best = r;
      if (best && best.count > 0) set.add(i + 1);
    });
  }
  return set;
}

function codeLines(engine) {
  const src = fs.readFileSync(engine, 'utf8').split('\n');
  const out = new Set();
  src.forEach((line, i) => { const t = line.trim(); if (t && !t.startsWith('//') && !/^[}\])]+[;,]?$/.test(t)) out.add(i + 1); });
  return out;
}

// ─── カナリア（隔離が実際に効いているかの確認）─────────
function canary(engine, stub, label) {
  const issue = { data: { number: 1, id: 1001, title: 'canary', body: '', labels: [{ name: '🎯 next' }], state: 'open' } };
  const c = { argv: ['run', 'show', '1'], responses: { 'issues.get': [issue] }, files: { '.claude/canary.txt': 'x' } };
  let res;
  try { res = runOnce(engine, c, 'ja', stub); } catch (e) { die(label + ' のカナリア実行に失敗: ' + e.message); }
  if (res.problems.length) die(label + ' のカナリア実行に問題: ' + res.problems.join(' / '));
  if (!res.log || !res.log.some(l => l.includes('"method":"issues.get"'))) die(label + ': スタブが効いていない（スタブログに issues.get が無い）。実 GitHub へ到達しうるため1件も実行しない。stderr: ' + clip(res.stderr, 200));
  if (res.status !== 0) die(label + ': カナリア実行が失敗した（exit ' + res.status + '）: ' + clip(res.stderr, 200));
}

// ─── 本体 ────────────────────────────────────
function main() {
  const o = parseCli(process.argv.slice(2));
  const stub = path.resolve(o.stub || path.join(__dirname, '..', 'stubs', 'octokit-stub.js'));
  let corpus = CORPUS.slice();
  for (const f of o.corpus) { const extra = require(path.resolve(f)); if (!Array.isArray(extra)) die('--corpus は配列を export すること: ' + f); corpus = corpus.concat(extra); }

  // コーパスの検査（marker 必須・ID 一意）
  const seen = new Set();
  for (const c of corpus) {
    if (!c.id || seen.has(c.id)) die('ケース ID が空か重複: ' + c.id);
    seen.add(c.id);
    if (!c.marker || typeof c.marker !== 'object' || !Object.keys(c.marker).length) die('marker が無い（到達確認のため必須）: ' + c.id);
    if (!Array.isArray(c.argv)) die('argv が配列ではない: ' + c.id);
  }
  const selected = corpus.filter(c => !o.only || c.id.includes(o.only));
  const jobs = [];
  for (const c of selected) for (const lang of (c.langs || ['ja', 'en'])) if (!o.lang || o.lang === lang) jobs.push({ c, lang });

  if (o.list) { for (const j of jobs) console.log(j.c.id + ' [' + j.lang + ']'); console.log(jobs.length + ' 件'); return 0; }
  if (!o.old || !o.new) die('--old と --new が必要');
  for (const e of [o.old, o.new]) if (!fs.existsSync(e)) die('エンジンが存在しない: ' + e);
  // 子プロセスは隔離 HOME を cwd にして起動するので、エンジンのパスは絶対パスにしておく
  o.old = path.resolve(o.old); o.new = path.resolve(o.new);
  if (!jobs.length) die('実行するケースが0件（--only / --lang の指定を確認）');
  for (const id of o.allow) if (!corpus.some(c => c.id === id || c.id.startsWith(id))) die('--allow-diff に該当するケースが無い: ' + id);

  // 隔離の確認（失敗すれば1件も実行しない）
  canary(o.old, stub, '旧エンジン');
  canary(o.new, stub, '新エンジン');

  let identical = 0, reached = 0, unreached = 0, mismatched = 0, allowedOk = 0, allowedMissing = 0, broken = 0;
  const execLines = new Set();
  const report = [];
  for (const { c, lang } of jobs) {
    const tag = c.id + ' [' + lang + ']';
    const a = runOnce(o.old, c, lang, stub, { coverage: !!o.cov });
    const b = runOnce(o.new, c, lang, stub);
    if (a.executedLines) for (const l of a.executedLines) execLines.add(l);
    if (a.problems.length || b.problems.length) { broken++; report.push('実行に問題 ' + tag + ': ' + a.problems.concat(b.problems).join(' / ')); continue; }
    const miss = checkMarker(c.marker, a, lang);
    if (miss.length) {
      unreached++;
      report.push('到達できていない ' + tag + ': 旧エンジンで marker が現れない → ' + miss.join(' ; ') + '\n    stdout: ' + clip(a.stdout, 300) + '\n    stderr: ' + clip(a.stderr, 300));
      continue;
    }
    reached++;
    const d = diffResults(a, b);
    const allowed = o.allow.some(p => c.id === p || c.id.startsWith(p));
    if (allowed) {
      if (d.length) { allowedOk++; report.push('差分あり（許可済み） ' + tag + ': ' + d.map(x => x[0]).join(', ')); }
      else { allowedMissing++; report.push('許可したのに差分が出ていない ' + tag); }
    } else if (d.length) {
      mismatched++;
      report.push('不一致 ' + tag + ': ' + d.map(x => x[0]).join(', ') + '\n' + d.map(x => '    [' + x[0] + ']\n      旧: ' + clip(x[1], 400).replace(/\n/g, '\n          ') + '\n      新: ' + clip(x[2], 400).replace(/\n/g, '\n          ')).join('\n'));
    } else { identical++; if (o.verbose) report.push('一致 ' + tag); }
  }

  let covBad = 0;
  if (o.cov) {
    const code = codeLines(o.old);
    for (const [s, e] of o.cov) {
      const want = []; for (let l = s; l <= e; l++) if (code.has(l)) want.push(l);
      const missing = want.filter(l => !execLines.has(l));
      report.push('行カバレッジ ' + s + '-' + e + ': 実行された ' + (want.length - missing.length) + ' / ' + want.length + ' 行' + (missing.length ? '  未実行: ' + missing.join(',') : ''));
      if (!want.length) { covBad++; report.push('  範囲内にコード行が無い（指定の誤り）'); }
      covBad += missing.length;
    }
  }

  for (const r of report) console.log(r);
  console.log('');
  console.log('実行 ' + jobs.length + ' 件 / marker 到達 ' + reached + ' / 到達できず ' + unreached + ' / 実行に問題 ' + broken);
  console.log('一致 ' + identical + ' / 不一致 ' + mismatched + (o.allow.length ? ' / 差分あり（許可済み）' + allowedOk + ' / 許可したのに一致 ' + allowedMissing : ''));
  const ok = !unreached && !broken && !mismatched && !allowedMissing && !covBad && reached === jobs.length;
  console.log(ok ? 'RESULT: OK' : 'RESULT: FAIL');
  return ok ? 0 : 1;
}

// ─── コーパス ────────────────────────────────────
// 応答の組み立て用ヘルパ
const iss = (n, o = {}) => ({ data: { number: n, id: n + 9000, title: o.title || 'Issue ' + n, body: o.body || '', labels: (o.labels || ['🎯 next']).map(name => ({ name })), state: o.state || 'open' } });
const openItem = (n, o = {}) => ({ number: n, id: n + 9000, title: o.title || 'Open ' + n, body: o.body || '', labels: (o.labels || ['🎯 next']).map(name => ({ name })), updated_at: '2026-10-01T00:00:00Z' });
const list = (...items) => ({ data: items });
const NEXT = '🎯 next', INBOX = '📥 inbox', SOMEDAY = '🌈 someday', PROJ = '📁 project';
const RECUR_BODY = 'due: 2026-10-10\nrecur: weekly\n';

const K_MARKERS = {
  'list-all': 'dup due', 'list-summary': '📊 next', 'weekly-summary': 'dup due', 'stats': { ja: '全タスク: 8件', en: 'Total tasks: 8' },
  'today': 'dup due', 'dashboard': 'dup due', 'eisenhower': 'dup due', 'report': { ja: '期間', en: 'Period' },
};

const CORPUS = [
  // ── (a) 完了フロー ──
  { id: 'a01-done-plain', argv: ['run', 'done', '301'],
    responses: { 'issues.get': [iss(301)], 'issues.update': [{}], 'issues.listForRepo': [list()] },
    marker: { logSeq: ['issues.get', 'issues.update', 'issues.listForRepo'], exit: 0 } },
  { id: 'a02-done-recur', argv: ['run', 'done', '302'],
    responses: { 'issues.get': [iss(302, { body: RECUR_BODY })], 'issues.create': [{ data: { number: 9302 } }], 'issues.update': [{}], 'issues.listForRepo': [list()] },
    marker: { logSeq: ['issues.get', 'issues.create', 'issues.update', 'issues.listForRepo'], exit: 0 } },
  { id: 'a03-done-recur-close-fails', argv: ['run', 'done', '303'],
    responses: { 'issues.get': [iss(303, { body: RECUR_BODY })], 'issues.create': [{ data: { number: 9303 } }], 'issues.update': [E500] },
    marker: { stderr: { ja: 'のクローズに失敗しました（新しい繰り返しIssue #9303', en: 'Failed to close #303 (a new recurring issue #9303' }, exit: 1 } },
  { id: 'a04-done-norecur-close-fails', argv: ['run', 'done', '304'],
    responses: { 'issues.get': [iss(304)], 'issues.update': [E500] },
    marker: { logSeq: ['issues.get', 'issues.update'], stderr: 'boom', exit: 1 } },
  { id: 'a05-done-actual', argv: ['run', 'done', '305', '--actual', '1h'],
    responses: { 'issues.get': [iss(305)], 'issues.update': [{}, {}], 'issues.listForRepo': [list()] },
    marker: { logSeq: ['actual: 60', '"state":"closed"'], exit: 0 } },
  { id: 'a06-done-actual-invalid', argv: ['run', 'done', '306', '--actual', 'xyz'],
    responses: { 'issues.get': [iss(306)] },
    marker: { stderr: { ja: '時間は 30m', en: 'Time must be in' }, exit: 1 } },
  { id: 'a07-done-note', argv: ['run', 'done', '307', '--note', 'memo'],
    responses: { 'issues.get': [iss(307)], 'issues.update': [{}], 'issues.listForRepo': [list()], 'issues.createComment': [{ data: { html_url: 'x' } }] },
    marker: { logSeq: ['"state":"closed"', 'issues.createComment'], exit: 0 } },
  { id: 'a08-done-project-hint', argv: ['run', 'done', '308'],
    responses: { 'issues.get': [iss(308, { body: 'project: #500\n' }), iss(500, { title: 'Parent', labels: [PROJ] })], 'issues.update': [{}],
      'issues.listForRepo': [list(openItem(310, { body: 'project: #500\n', labels: [SOMEDAY] }))] },
    marker: { logSeq: ['issues.listForRepo', '"issue_number":500'], stdout: { ja: '昇格', en: 'omot' }, exit: 0 } },
  { id: 'a09-done-depends-promote', argv: ['run', 'done', '309'],
    responses: { 'issues.get': [iss(309)], 'issues.update': [{}],
      'issues.listForRepo': [list(openItem(311, { body: 'depends_on: #309\n', labels: [SOMEDAY] }))], 'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.listForRepo', 'issues.removeLabel', 'issues.addLabels'], exit: 0 } },
  { id: 'a10-close-alias', argv: ['run', 'close', '312'],
    responses: { 'issues.get': [iss(312)], 'issues.update': [{}], 'issues.listForRepo': [list()] },
    marker: { logSeq: ['issues.get', 'issues.update'], exit: 0 } },
  { id: 'a11-bulk-done-one-close-fails', argv: ['run', 'bulk', 'done', '321', '322'],
    responses: { 'issues.get': [iss(321), iss(322, { body: RECUR_BODY })], 'issues.create': [{ data: { number: 9322 } }], 'issues.update': [{}, E500], 'issues.listForRepo': [list()] },
    marker: { stdout: { ja: '  #322 エラー: エラー: #322 のクローズに失敗しました', en: '  #322 error: Error: Failed to close #322' }, exit: 0 } },
  { id: 'a12-bulk-done-actual-invalid', argv: ['run', 'bulk', 'done', '323', '324', '--actual', 'xyz'],
    responses: { 'issues.get': [iss(323), iss(324)], 'issues.update': [{}, {}], 'issues.listForRepo': [list(), list()] },
    marker: { logSeq: ['issues.get', 'issues.update', 'issues.listForRepo', 'issues.get', 'issues.update', 'issues.listForRepo'], exit: 0 } },
  { id: 'a13-bulk-done-actual-valid', argv: ['run', 'bulk', 'done', '325', '--actual', '30m'],
    responses: { 'issues.get': [iss(325)], 'issues.update': [{}, {}], 'issues.listForRepo': [list()] },
    marker: { logSeq: ['actual: 30', '"state":"closed"'], exit: 0 } },
  { id: 'a14-api-done-issue', argv: ['api', 'done-issue', '331'], langs: ['en'],
    responses: { 'issues.get': [iss(331, { body: RECUR_BODY })], 'issues.create': [{ data: { number: 9331 } }], 'issues.update': [{}], 'issues.listForRepo': [list()] },
    marker: { stdout: '"newIssueNumber":9331', exit: 0 } },
  { id: 'a15-api-done-issue-close-fails', argv: ['api', 'done-issue', '332'], langs: ['en'],
    responses: { 'issues.get': [iss(332, { body: RECUR_BODY })], 'issues.create': [{ data: { number: 9332 } }], 'issues.update': [E500] },
    marker: { stderr: 'Failed to close issue #332', exit: 1 } },
  { id: 'a16-api-done-issue-norecur-close-fails', argv: ['api', 'done-issue', '333'], langs: ['en'],
    responses: { 'issues.get': [iss(333)], 'issues.update': [E500] },
    marker: { logSeq: ['issues.get', 'issues.update'], exit: 1 } },

  { id: 'a17-bulk-done-norecur-close-fails', argv: ['run', 'bulk', 'done', '326', '327'],
    responses: { 'issues.get': [iss(326), iss(327)], 'issues.update': [E500, {}], 'issues.listForRepo': [list()] },
    marker: { stdout: { ja: '  #326 エラー: boom', en: '  #326 error: boom' }, exit: 0 } },
  { id: 'a18-bulk-done-recur-ok', argv: ['run', 'bulk', 'done', '328'],
    responses: { 'issues.get': [iss(328, { body: RECUR_BODY })], 'issues.create': [{ data: { number: 9328 } }], 'issues.update': [{}], 'issues.listForRepo': [list()] },
    marker: { stdout: '#9328', logSeq: ['issues.create', 'issues.update', 'issues.listForRepo'], exit: 0 } },

  // ── (b) GTD ラベルの付け替え ──
  { id: 'b01-move-inbox-to-next', argv: ['run', 'move', '401', 'next'],
    responses: { 'issues.get': [iss(401, { labels: [INBOX] })], 'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.get', 'issues.removeLabel', 'issues.addLabels'], exit: 0 } },
  { id: 'b02-move-plain-next-label', argv: ['run', 'move', '402', 'next'],
    responses: { 'issues.get': [iss(402, { labels: ['next'] })], 'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['"name":"next"', 'issues.addLabels'], log: 'issues.removeLabel', exit: 0 } },
  { id: 'b03-move-same-label', argv: ['run', 'move', '403', 'next'],
    responses: { 'issues.get': [iss(403, { labels: [NEXT] })], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.get', 'issues.addLabels'], exit: 0 } },
  { id: 'b04-move-routine-without-recur', argv: ['run', 'move', '404', 'routine'],
    responses: { 'issues.get': [iss(404)] },
    marker: { stderr: { ja: 'routine への移動には recur が必須', en: 'moving to routine requires recur' }, exit: 1 } },
  { id: 'b05-move-to-project-forbidden', argv: ['run', 'move', '405', 'project'],
    responses: {},
    marker: { stderr: { ja: 'project への移動はできません', en: 'Cannot move to project' }, exit: 1 } },
  { id: 'b06-bulk-move-routine-one-fails', argv: ['run', 'bulk', 'move', '406', '407', 'routine'],
    responses: { 'issues.get': [iss(406), iss(407, { body: 'recur: weekly\n', labels: [NEXT] })], 'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { stdout: { ja: '  #406 エラー:', en: '  #406 error:' }, logSeq: ['issues.removeLabel', 'issues.addLabels'], exit: 0 } },
  { id: 'b07-promote-pending-review', argv: ['run', 'promote'],
    responses: { 'issues.listForRepo': [list(openItem(410, { body: 'activate: 2026-10-01\nresume_condition: wait for x\n', labels: [SOMEDAY] }))] },
    marker: { stdout: { ja: '再開条件の確認が必要です', en: 'resume condition needs review' }, exit: 0 } },
  { id: 'b08-promote-promotes', argv: ['run', 'promote'],
    responses: { 'issues.listForRepo': [list(openItem(411, { body: 'activate: 2026-10-01\n', labels: [SOMEDAY] }))], 'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.listForRepo', 'issues.removeLabel', 'issues.addLabels'], exit: 0 } },
  { id: 'b09-promote-skips-plain-next', argv: ['run', 'promote'],
    responses: { 'issues.listForRepo': [list(openItem(412, { body: 'activate: 2026-10-01\n', labels: ['next'] }))] },
    marker: { logSeq: ['issues.listForRepo'], stdout: { ja: '対象', en: 'No' }, exit: 0 } },
  { id: 'b10-promote-plain-someday-label', argv: ['run', 'promote'],
    responses: { 'issues.listForRepo': [list(openItem(413, { body: 'activate: 2026-10-01\n', labels: ['someday'] }))], 'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['"name":"someday"', 'issues.addLabels'], exit: 0 } },
  { id: 'b11-promote-project-existing-label', argv: ['run', 'promote-project', '420'],
    responses: { 'issues.get': [iss(420, { labels: [INBOX] })], 'issues.removeLabel': [{}], [LBL]: [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.get', 'issues.removeLabel', LBL, 'issues.addLabels'], exit: 0 } },
  { id: 'b12-promote-project-creates-label', argv: ['run', 'promote-project', '421'],
    responses: { 'issues.get': [iss(421, { labels: [NEXT] })], 'issues.removeLabel': [{}], [LBL]: [E404], 'issues.createLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.removeLabel', LBL, '"color":"0052CC"', 'issues.addLabels'], exit: 0 } },
  { id: 'b13-promote-project-no-gtd-label', argv: ['run', 'promote-project', '422'],
    responses: { 'issues.get': [iss(422, { labels: ['p2'] })], [LBL]: [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.get', LBL, 'issues.addLabels'], exit: 0 } },
  { id: 'b14-promote-project-label-lookup-fails', argv: ['run', 'promote-project', '423'],
    responses: { 'issues.get': [iss(423, { labels: [NEXT] })], 'issues.removeLabel': [{}], [LBL]: [E500] },
    marker: { logSeq: ['issues.removeLabel', LBL], exit: 1 } },
  { id: 'b15-done-depends-promote-plain-label', argv: ['run', 'done', '430'],
    responses: { 'issues.get': [iss(430)], 'issues.update': [{}],
      'issues.listForRepo': [list(openItem(431, { body: 'depends_on: #430\n', labels: ['someday'] }), openItem(432, { body: 'depends_on: #430\n', labels: ['next'] }))],
      'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['"name":"someday"', 'issues.addLabels'], exit: 0 } },
  { id: 'b16-api-move-gtd', argv: ['api', 'move-gtd', '440', 'someday'], langs: ['en'],
    responses: { 'issues.get': [iss(440)], 'issues.removeLabel': [{}], 'issues.addLabels': [{}] },
    marker: { stdout: 'ok', logSeq: ['issues.removeLabel', 'issues.addLabels'], exit: 0 } },

  // ── (c) 優先度ラベルの付け替え ──
  { id: 'c01-priority-p1-from-p3', argv: ['run', 'priority', '501', 'p1'],
    responses: { 'issues.get': [iss(501, { labels: [NEXT, 'p3'] })], 'issues.removeLabel': [{}], [LBL]: [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['issues.get', 'issues.removeLabel', LBL, 'issues.addLabels'], exit: 0 } },
  { id: 'c02-priority-clear', argv: ['run', 'priority', '502', 'clear'],
    responses: { 'issues.get': [iss(502, { labels: [NEXT, 'p2'] })], 'issues.removeLabel': [{}] },
    marker: { logSeq: ['issues.get', 'issues.removeLabel'], exit: 0 } },
  { id: 'c03-priority-same-level', argv: ['run', 'priority', '503', 'p2'],
    responses: { 'issues.get': [iss(503, { labels: [NEXT, 'p2'] })], 'issues.removeLabel': [{}], [LBL]: [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['"name":"p2"', LBL, 'issues.addLabels'], exit: 0 } },
  { id: 'c04-priority-creates-label', argv: ['run', 'priority', '504', 'p1'],
    responses: { 'issues.get': [iss(504)], [LBL]: [E404], 'issues.createLabel': [{}], 'issues.addLabels': [{}] },
    marker: { logSeq: [LBL, 'issues.createLabel', 'issues.addLabels'], exit: 0 } },
  { id: 'c05-priority-label-lookup-fails', argv: ['run', 'priority', '505', 'p1'],
    responses: { 'issues.get': [iss(505, { labels: [NEXT, 'p3'] })], 'issues.removeLabel': [{}], [LBL]: [E500] },
    marker: { logSeq: ['issues.removeLabel', LBL], exit: 1 } },
  { id: 'c06-edit-priority', argv: ['run', 'edit', '506', '--priority', 'p2'],
    responses: { 'issues.get': [iss(506, { labels: [NEXT, 'p3'] })], 'issues.removeLabel': [{}], [LBL]: [{}], 'issues.addLabels': [{}], 'issues.update': [{}] },
    marker: { logSeq: ['issues.removeLabel', LBL, 'issues.addLabels', 'issues.update'], exit: 0 } },
  { id: 'c07-edit-priority-clear', argv: ['run', 'edit', '507', '--priority', 'clear'],
    responses: { 'issues.get': [iss(507, { labels: [NEXT, 'p1'] })], 'issues.removeLabel': [{}], 'issues.update': [{}] },
    marker: { logSeq: ['issues.removeLabel', 'issues.update'], exit: 0 } },
  { id: 'c08-edit-priority-label-lookup-fails', argv: ['run', 'edit', '508', '--priority', 'p1'],
    responses: { 'issues.get': [iss(508, { labels: [NEXT, 'p3'] })], 'issues.removeLabel': [{}], [LBL]: [E500] },
    marker: { logSeq: ['issues.removeLabel', LBL], exit: 1 } },
  { id: 'c09-bulk-priority', argv: ['run', 'bulk', 'priority', '509', '510', 'p2'],
    responses: { [LBL]: [{}], 'issues.get': [iss(509, { labels: [NEXT, 'p3'] }), iss(510)], 'issues.removeLabel': [{}], 'issues.addLabels': [{}, {}] },
    marker: { logSeq: [LBL, 'issues.get', 'issues.removeLabel', 'issues.addLabels', 'issues.get', 'issues.addLabels'], exit: 0 } },
  { id: 'c10-bulk-priority-clear', argv: ['run', 'bulk', 'priority', '511', '512', 'clear'],
    responses: { 'issues.get': [iss(511, { labels: [NEXT, 'p1'] }), iss(512)], 'issues.removeLabel': [{}] },
    marker: { logSeq: ['issues.get', 'issues.removeLabel', 'issues.get'], exit: 0 } },
  { id: 'c11-bulk-priority-label-lookup-fails', argv: ['run', 'bulk', 'priority', '513', 'p1'],
    responses: { [LBL]: [E500] },
    marker: { logSeq: [LBL], exit: 1 } },

  // ── (d) ctx / tag ラベルの作成と色 ──
  { id: 'd01-add-ctx-and-tag', argv: ['run', 'add', 'next', 'task-d1', '@ctxd', '#tagd'],
    responses: { [LBL]: [E404, E404, {}], 'issues.createLabel': [{}, {}], 'issues.create': [{ data: { number: 601, id: 9601, html_url: 'x' } }] },
    marker: { logSeq: ['"color":"FBCA04"', '"color":"0075CA"', 'issues.create'], exit: 0 } },
  { id: 'd02-template-use-ctx-tag', argv: ['run', 'template', 'use', 'tplD'],
    files: { '.claude/todo-templates.json': { tplD: { gtd: 'next', context: ['@ctxt', '#hashinctx'], tags: ['#tagt'], priority: 'p2' } } },
    responses: { [LBL]: [E404, E404, E404, {}], 'issues.createLabel': [{}, {}, {}], 'issues.create': [{ data: { number: 602, id: 9602, html_url: 'x' } }] },
    marker: { logSeq: ['"name":"@ctxt"', '"color":"FBCA04"', '"name":"#hashinctx"', '"color":"FBCA04"', '"name":"#tagt"', '"color":"0075CA"', 'issues.create'], exit: 0 } },
  { id: 'd03-tag-ctx-and-tag', argv: ['run', 'tag', '603', '#tagx', '@ctxx'],
    responses: { [LBL]: [E404, E404], 'issues.createLabel': [{}, {}], 'issues.addLabels': [{}] },
    marker: { logSeq: ['"name":"#tagx"', '"color":"0075CA"', '"name":"@ctxx"', '"color":"FBCA04"', 'issues.addLabels'], stdout: { ja: '新規ラベル', en: 'Created new label' }, exit: 0 } },
  { id: 'd04-bulk-tag', argv: ['run', 'bulk', 'tag', '604', '605', '@ctxb', '#tagb'],
    responses: { [LBL]: [E404, E404], 'issues.createLabel': [{}, {}], 'issues.addLabels': [{}, {}] },
    marker: { logSeq: ['"name":"@ctxb"', '"color":"FBCA04"', '"name":"#tagb"', '"color":"0075CA"', 'issues.addLabels', 'issues.addLabels'], exit: 0 } },
  { id: 'd05-label-add-default-color', argv: ['run', 'label', 'add', '@ctxl'],
    responses: { [LBL]: [E404], 'issues.createLabel': [{}] },
    marker: { logSeq: [LBL, '"color":"FBCA04"'], exit: 0 } },
  { id: 'd06-label-add-color-option', argv: ['run', 'label', 'add', '@ctxm', '--color', 'ABCDEF'],
    responses: { [LBL]: [E404], 'issues.createLabel': [{}] },
    marker: { logSeq: [LBL, '"color":"ABCDEF"'], exit: 0 } },
  { id: 'd07-add-extra-label', argv: ['run', 'add', 'next', 'task-d7', '--label', 'extra-d7'],
    responses: { [LBL]: [{}, E404], 'issues.createLabel': [{}], 'issues.create': [{ data: { number: 607, id: 9607, html_url: 'x' } }] },
    marker: { logSeq: ['"name":"extra-d7"', '"color":"EDEDED"', 'issues.create'], exit: 0 } },

  // ── (e) 親 project の確認 ──
  { id: 'e01-add-parent-ok', argv: ['run', 'add', 'next', 'child-e1', '--project', '700'],
    responses: { 'issues.get': [iss(700, { labels: [PROJ] })], [LBL]: [{}], 'issues.create': [{ data: { number: 701, id: 9701, html_url: 'x' } }], [SUB]: [{ data: {} }] },
    marker: { logSeq: ['issues.get', 'issues.create', SUB], exit: 0 } },
  { id: 'e02-add-parent-not-project', argv: ['run', 'add', 'next', 'child-e2', '--project', '702'],
    responses: { 'issues.get': [iss(702)] },
    marker: { stderr: { ja: 'はプロジェクトではありません', en: 'is not a project' }, exit: 1 } },
  { id: 'e03-add-parent-fetch-fails', argv: ['run', 'add', 'next', 'child-e3', '--project', '703'],
    responses: { 'issues.get': [E500], [LBL]: [{}], 'issues.create': [{ data: { number: 704, id: 9704, html_url: 'x' } }] },
    marker: { stderr: { ja: 'の取得に失敗しました', en: 'Failed to fetch project' }, log: 'issues.create', exit: 0 } },
  { id: 'e04-template-use-parent-ok', argv: ['run', 'template', 'use', 'tplE'],
    files: { '.claude/todo-templates.json': { tplE: { gtd: 'next', project: 710 } } },
    responses: { [LBL]: [{}], 'issues.create': [{ data: { number: 711, id: 9711, html_url: 'x' } }], 'issues.get': [iss(710, { labels: [PROJ] })], [SUB]: [{ data: {} }] },
    marker: { logSeq: ['issues.create', 'issues.get', SUB], exit: 0 } },
  { id: 'e05-template-use-parent-not-project', argv: ['run', 'template', 'use', 'tplE'],
    files: { '.claude/todo-templates.json': { tplE: { gtd: 'next', project: 712 } } },
    responses: { [LBL]: [{}], 'issues.create': [{ data: { number: 713, id: 9713, html_url: 'x' } }], 'issues.get': [iss(712)] },
    marker: { stderr: { ja: 'はプロジェクトではありません', en: 'is not a project' }, log: 'issues.create', exit: 0 } },
  { id: 'e06-template-use-parent-fetch-fails', argv: ['run', 'template', 'use', 'tplE'],
    files: { '.claude/todo-templates.json': { tplE: { gtd: 'next', project: 714 } } },
    responses: { [LBL]: [{}], 'issues.create': [{ data: { number: 715, id: 9715, html_url: 'x' } }], 'issues.get': [E500] },
    marker: { stderr: { ja: 'の取得に失敗しました', en: 'Failed to fetch project' }, log: 'issues.create', exit: 0 } },
  { id: 'e07-link-parent-ok', argv: ['run', 'link', '720', '721'],
    responses: { 'issues.get': [iss(720), iss(721, { labels: [PROJ] })], 'issues.update': [{}], [SUB]: [{ data: {} }] },
    marker: { logSeq: ['issues.get', 'issues.get', 'issues.update', SUB], exit: 0 } },
  { id: 'e08-link-parent-not-project', argv: ['run', 'link', '722', '723'],
    responses: { 'issues.get': [iss(722), iss(723)] },
    marker: { stderr: { ja: 'はプロジェクトではありません', en: 'is not a project' }, exit: 1 } },
  { id: 'e09-link-parent-fetch-fails', argv: ['run', 'link', '724', '725'],
    responses: { 'issues.get': [iss(724), E500] },
    marker: { stderr: { ja: 'エラー: プロジェクト #725 の取得に失敗しました', en: 'Error: Failed to fetch project #725' }, exit: 1 } },
  { id: 'e10-migrate-mixed', argv: ['run', 'migrate', 'sub-issue'],
    responses: { 'issues.listForRepo': [list(openItem(731, { body: 'project: #740\n' }), openItem(732, { body: 'project: #741\n' }), openItem(733, { body: 'project: #742\n' }))],
      'issues.get': [iss(740, { labels: [PROJ] }), iss(741), E500], [SUB]: [{ data: {} }] },
    marker: { stdout: { ja: '1件登録 / 1件スキップ / 1件エラー', en: '1 registered / 1 skipped / 1 errors' }, stderr: { ja: '親 #742 の取得失敗', en: 'Failed to fetch parent #742' }, exit: 0 } },
  { id: 'e12-migrate-register-results', argv: ['run', 'migrate', 'sub-issue'],
    responses: { 'issues.listForRepo': [list(openItem(735, { body: 'project: #744\n' }), openItem(736, { body: 'project: #744\n' }), openItem(737, { body: 'project: #744\n' }))],
      'issues.get': [iss(744, { labels: [PROJ] }), iss(744, { labels: [PROJ] }), iss(744, { labels: [PROJ] })],
      [SUB]: [{ __throw: true, status: 422, message: 'dup' }, { __throw: true, status: 500, message: 'boom' }, { data: {} }],
      'GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues': [{ data: [{ id: 9735 }] }] },
    marker: { stdout: { ja: '1件登録 / 1件スキップ / 1件エラー', en: '1 registered / 1 skipped / 1 errors' }, exit: 0 } },
  { id: 'e11-migrate-dry-run', argv: ['run', 'migrate', 'sub-issue', '--dry-run'],
    responses: { 'issues.listForRepo': [list(openItem(734, { body: 'project: #743\n' }))] },
    marker: { stdout: '#734', exit: 0 } },

  // ── (f) --body-file ──
  { id: 'f01-add-body-file', argv: ['run', 'add', 'next', 'task-f1', '--body-file', '{HOME}/body.txt'],
    files: { 'body.txt': 'file body text' },
    responses: { [LBL]: [{}], 'issues.create': [{ data: { number: 801, id: 9801, html_url: 'x' } }] },
    marker: { log: 'file body text', exit: 0 } },
  { id: 'f02-add-body-file-missing', argv: ['run', 'add', 'next', 'task-f2', '--body-file', '{HOME}/none.txt'],
    responses: { [LBL]: [{}] },
    marker: { stderr: { ja: '--body-file のパスが見つかりません: <HOME>/none.txt', en: '--body-file path not found: <HOME>/none.txt' }, exit: 1 } },
  { id: 'f03-add-body-file-is-directory', argv: ['run', 'add', 'next', 'task-f3', '--body-file', '{HOME}/adir'],
    files: { 'adir/': '' },
    responses: { [LBL]: [{}] },
    marker: { stderr: { ja: '--body-file の読み込みに失敗しました', en: 'Failed to read --body-file' }, exit: 1 } },
  { id: 'f04-comment-body-file', argv: ['run', 'comment', '811', '--body-file', '{HOME}/body.txt'],
    files: { 'body.txt': 'comment from file' },
    responses: { 'issues.createComment': [{ data: { html_url: 'x' } }] },
    marker: { log: 'comment from file', exit: 0 } },
  { id: 'f05-comment-body-file-missing', argv: ['run', 'comment', '812', '--body-file', '{HOME}/none.txt'],
    responses: {},
    marker: { stderr: { ja: '--body-file のパスが見つかりません: <HOME>/none.txt', en: '--body-file path not found: <HOME>/none.txt' }, exit: 1 } },
  { id: 'f06-comment-body-file-is-directory', argv: ['run', 'comment', '813', '--body-file', '{HOME}/adir'],
    files: { 'adir/': '' },
    responses: {},
    marker: { stderr: { ja: '--body-file の読み込みに失敗しました', en: 'Failed to read --body-file' }, exit: 1 } },

  // ── (k) body の読み取り（直接サブコマンドに境界の body を渡す。API は呼ばない）──
  ...['list-all', 'list-summary', 'weekly-summary', 'stats', 'today', 'dashboard', 'eisenhower', 'report'].map(sub => ({
    id: 'k-direct-' + sub, argv: [sub],
    env: {
      TODAY_ENV: '2026-10-18', DAYS_ENV: '7', CLOSED_ENV: '[]',
      OPEN_ENV: JSON.stringify([
        openItem(901, { title: 'crlf due', body: 'due: 2026-10-17\r\nrecur: weekly\r\n', labels: [NEXT, 'p1'] }),
        openItem(902, { title: 'bad due', body: 'due: tomorrow\n', labels: [NEXT] }),
        openItem(903, { title: 'dup due', body: 'due: 2026-10-10\ndue: 2026-10-30\n', labels: [NEXT, 'p2'] }),
        openItem(904, { title: 'someday no review', body: '', labels: [SOMEDAY] }),
        openItem(905, { title: 'someday reviewed', body: 'reviewed_at: 2026-09-01\n', labels: [SOMEDAY] }),
        openItem(906, { title: 'child of 12', body: 'project: #12\n', labels: [NEXT] }),
        openItem(907, { title: 'child of 123', body: 'project: #123\n', labels: [NEXT] }),
        openItem(908, { title: 'project 12', body: '', labels: [PROJ] }),
      ]),
    },
    responses: {},
    marker: { stdout: K_MARKERS[sub], exit: 0 } })),
];

if (require.main === module) process.exit(main());
module.exports = { CORPUS, checkMarker, diffResults, assertSandbox, buildEnv };
