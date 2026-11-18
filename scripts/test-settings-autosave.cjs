const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-settings-autosave.cjs\n验证设置自动保存的输入合并、串行写入、离开刷新、错误恢复及提醒与废纸篓互不覆盖。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function compile(source, mocks = {}, globals = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, console, setTimeout, clearTimeout,
    require(name) { assert.ok(name in mocks, name); return mocks[name]; }, ...globals });
  return module.exports;
}
const file = name => fs.readFileSync(`entry/src/main/ets/services/${name}.ets`, 'utf8');
const { SettingsAutoSave } = compile(file('SettingsAutoSave'));
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }

test('没有待保存修改时 flush 不产生导航阻塞', async () => {
  const save = new SettingsAutoSave(() => assert.fail());
  const work = save.flush(); assert.equal(save.hasPending(), false); await work;
});

test('连续输入只写最终值，离开或失焦 flush 无需保存按钮且不丢其他设置', async () => {
  const writes = [], errors = [], save = new SettingsAutoSave(error => errors.push(error));
  save.schedule('reminder', async () => writes.push(['reminder', 3]), 60000);
  save.schedule('trash', async () => writes.push(['trash', 7]), 60000);
  save.schedule('reminder', async () => writes.push(['reminder', 45]), 60000);
  assert.equal(writes.length, 0); assert.equal(save.hasPending(), true);
  await save.flush(); assert.deepEqual(writes, [['reminder', 45], ['trash', 7]]);
  assert.equal(errors.length, 0); assert.equal(save.hasPending(), false);
});

test('正在保存时继续编辑会串行处理，只保留尚未执行的最新同类值', async () => {
  const gate = deferred(), writes = [], save = new SettingsAutoSave(() => assert.fail());
  save.schedule('reminder', async () => { writes.push('first'); await gate.promise; }, 0);
  save.schedule('trash', async () => writes.push('old-trash'), 60000);
  save.schedule('trash', async () => writes.push('new-trash'), 60000);
  save.schedule('reminder', async () => writes.push('latest-reminder'), 60000);
  const flushed = save.flush(); assert.deepEqual(writes, ['first']);
  gate.resolve(); await flushed;
  assert.deepEqual(writes, ['first', 'new-trash', 'latest-reminder']); assert.equal(save.hasPending(), false);
});

test('写入失败显示错误，后续修改仍能保存，不形成永久阻塞', async () => {
  const errors = [], writes = [], save = new SettingsAutoSave(error => errors.push(error.message));
  save.schedule('trash', async () => { throw new Error('磁盘写入失败'); }, 60000);
  await save.flush(); assert.deepEqual(errors, ['磁盘写入失败']);
  save.schedule('trash', async () => writes.push(30), 0); await save.flush();
  assert.deepEqual(writes, [30]); assert.equal(save.hasPending(), false);
});

function method(source, name) {
  const match = source.match(new RegExp('  (?:private )?(?:async )?' + name + '\\([^\\n]*\\)[^\\n]* \\{'));
  assert.ok(match, name); const start = source.indexOf('{', match.index); let depth = 0;
  for (let i = start; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(match.index, i + 1);
  }
}
function page() {
  const source = fs.readFileSync('entry/src/main/ets/pages/Settings.ets', 'utf8');
  const methods = ['changeReminder', 'changeRetention', 'saveReminders', 'saveRetention'].map(name => method(source, name)).join('\n');
  const writes = []; let fail = false;
  const { Page } = compile('export class Page {' + methods + '}', {}, {
    TaskReminderSettings: { async save(context, value) { if (fail) throw new Error('保存失败'); writes.push(['reminder', value]); } },
    TrashSettingsService: { async saveRetentionDays(context, value) { if (fail) throw new Error('保存失败'); if (value < 1 || value > 3650) throw new Error('越界'); writes.push(['trash', value]); } },
    TaskReminderService: { refresh: async () => {} }
  });
  const errors = [], value = Object.assign(new Page(), { reminderEnabled: false, ringDurationDraft: '30',
    reminderSaved: { enabled: false, ringDuration: 30 }, reminderEditVersion: 0, retentionDraft: '30', savedRetentionDays: 30,
    getUIContext: () => ({ getHostContext: () => ({}) }) });
  value.preferenceSave = new SettingsAutoSave(error => errors.push(error.message));
  return { value, writes, errors, fail(value) { fail = value; } };
}

test('提醒开关即时保存，时长与废纸篓合并输入；失败回退开关且保留数字草稿', async () => {
  const f = page(); f.value.changeReminder(true, '30', true); await f.value.preferenceSave.flush();
  assert.equal(f.writes[0][1].enabled, true);
  f.value.changeReminder(true, '4'); f.value.changeReminder(true, '45'); f.value.changeRetention('7');
  await f.value.preferenceSave.flush();
  assert.equal(f.writes[1][1].ringDuration, 45); assert.deepEqual(f.writes[2], ['trash', 7]);
  assert.equal(f.value.savedRetentionDays, 7);
  f.fail(true); f.value.changeReminder(false, '60', true); await f.value.preferenceSave.flush();
  assert.equal(f.value.reminderEnabled, true); assert.equal(f.value.ringDurationDraft, '60'); assert.deepEqual(f.errors, ['保存失败']);
  f.fail(false); f.value.changeReminder(false, '60', true); await f.value.preferenceSave.flush();
  assert.equal(f.writes.at(-1)[1].enabled, false);
});

test('非法数字草稿不会写入或覆盖上次确认值', async () => {
  const f = page(); f.value.changeRetention(''); await f.value.preferenceSave.flush();
  assert.equal(f.writes.length, 0); assert.equal(f.value.savedRetentionDays, 30); assert.equal(f.value.retentionDraft, '');
});

test('废纸篓存储刷新失败恢复原值，后续自动保存可重试，不覆盖仓库配置', async () => {
  const values = new Map([['repos', '用户配置'], ['trashRetentionDays', 30]]); let fail = true;
  const { TrashSettingsService } = compile(file('TrashSettingsService'), { './PreferencesStore': { PreferencesStore: { async open() {
    return { get: async (key, fallback) => values.get(key) ?? fallback, put: async (key, value) => values.set(key, value),
      flush: async () => { if (fail) { fail = false; throw new Error('写入失败'); } } };
  } } } });
  await assert.rejects(TrashSettingsService.saveRetentionDays({}, 7)); assert.equal(values.get('trashRetentionDays'), 30);
  await TrashSettingsService.saveRetentionDays({}, 14); assert.equal(values.get('trashRetentionDays'), 14);
  assert.equal(values.get('repos'), '用户配置');
});
