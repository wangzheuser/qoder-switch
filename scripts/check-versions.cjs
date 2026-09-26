// 版本一致性核对：scripts/pack-npm.sh 与 scripts/pack-npm.ps1 共用这一份。
//
// 抽成文件的唯一理由：过去这段判断只内联在 .sh 里，多出一条 Windows 打包入口就得多抄一份；
// 抄漏一处就会在发布时发出错版本的包 —— 而"发错版本"正是这道检查要防的东西。
// 相对路径按本文件所在目录的上一级解析，所以从任何 cwd 调用结果都一样。
//
// 扩展名用 .cjs 而不是 .js：本仓库 package.json 声明了 "type": "module"，.js 会被 Node 当
// ES Module 加载，`require` 直接 ReferenceError（真仓库实测）。
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const readJson = (rel) => JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8'));

const expected = readJson('package.json').version;
const checks = [];

const jsonTargets = ['src-tauri/tauri.conf.json', 'npm/package.json'];
if (fs.existsSync(path.join(root, 'npm/platform'))) {
  for (const d of fs.readdirSync(path.join(root, 'npm/platform'))) {
    jsonTargets.push(`npm/platform/${d}/package.json`);
  }
}
for (const rel of jsonTargets) {
  checks.push([rel, () => readJson(rel).version]);
}

// Cargo 那边没有 JSON 可 require，按行取第一个顶层 version 字段。
const cargoFiles = [
  'crates/qs-switch-core/Cargo.toml',
  'crates/qs-switch-server/Cargo.toml',
  'src-tauri/Cargo.toml',
];
for (const rel of cargoFiles) {
  checks.push([
    rel,
    () => {
      const m = fs.readFileSync(path.join(root, rel), 'utf8').match(/^version\s*=\s*"([^"]+)"/m);
      return m ? m[1] : null;
    },
  ]);
}

let bad = 0;
for (const [f, get] of checks) {
  let v;
  try {
    v = get();
  } catch (e) {
    console.error(`版本核对失败: ${f} 读不出来 —— ${e.message}`);
    bad++;
    continue;
  }
  if (v !== expected) {
    console.error(`版本不一致: ${f} 为 ${v}，期望 ${expected}`);
    bad++;
  }
}
if (bad) process.exit(1);

console.log(`所有 ${checks.length} 处版本声明严格一致: ${expected}`);
