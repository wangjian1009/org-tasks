// 验证笔记宿主请求保留逻辑路径、原文件版本和 Core 仓库身份。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-notes.cjs\n验证笔记新增、修改、删除的 Core 请求与失败传播。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function fixture() {
  const requests = [];
  const repository = { id: 'host-id', rootDirectory: '/repo', webdavEnabled: true };
  const config = { repos: [repository], todoDefaults: '#+TODO: NEXT | FINISHED' };
  const file = { fullPath: { repoId: 'core-id', file: 'notes.org', titles: [] }, fileVersion: 'current-file' };
  const repo = { id: 'core-id', rootDirectory: '/repo', async file() { return file; } };
  let failure, missingTarget = false;
  const workspace = { async repos() { return [repo]; }, async executeTaskOperations(group) {
    if (failure) throw failure;
    requests.push(group);
  } };
  const native = { async workspaceFor() { return workspace; }, async executeTaskOperations(repos, group, defaults) {
    assert.equal(repos, config.repos);
    assert.equal(defaults, config.todoDefaults);
    return workspace.executeTaskOperations(group);
  } };
  const mocks = {
    './AppConfigService': { AppConfigService: { async load() { return config; } } },
    './NativeCoreService': { NativeCoreService: native },
    './FileTargetService': { FileTargetService: { async resolve(value, kind) {
      assert.equal(value, config); assert.equal(kind, 'memo');
      return missingTarget ? undefined : { repository, repo, path: 'notes.org' };
    } } }
  };
  const filename = path.resolve('entry/src/main/ets/services/NoteService.ets');
  const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInThisContext('(function(require,module,exports){' + source + '\n})', { filename })(name => {
    assert.ok(Object.hasOwn(mocks, name), '缺少替身: ' + name);
    return mocks[name];
  }, module, module.exports);
  const note = { repoId: repo.id, filePath: 'notes.org', fileVersion: 'original-file',
    fullPath: { repoId: repo.id, file: 'notes.org', titles: ['父标题', '原标题'], occurrence: 2 },
    heading: '原标题', body: '原正文\r\n:LOGBOOK:\r\n日志\r\n:END:\r\n' };
  return { service: module.exports.NoteService, note, requests, repository, repo, file,
    fail(error) { failure = error; }, invalidate() { missingTarget = true; } };
}

test('新增备忘明确创建无状态标题，携带正文与文件版本', async () => {
  const f = fixture();
  await f.service.createMemo({}, '中文 [[https://example.com][链接]]', '正文\r\n- 列表\r\n');
  assert.deepEqual(f.requests, [{ operations: [{ type: 'Creation', data: {
    position: { parent: f.file.fullPath }, title: '中文 [[https://example.com][链接]]', body: '正文\r\n- 列表\r\n',
    state: null
  } }], queueRepoIds: ['core-id'], fileVersions: [{ repoId: 'core-id', file: 'notes.org', version: 'current-file' }] }]);
});

test('改名沿用包含重名序号的原路径，仅提交变更字段，不覆盖原正文和日志', async () => {
  const f = fixture();
  await f.service.update({}, f.note, '新标题', f.note.body);
  assert.deepEqual(f.requests[0], { operations: [{ type: 'Modification', data: {
    path: f.note.fullPath, modifications: [{ field: 'TITLE', value: '新标题' }]
  } }], queueRepoIds: ['core-id'], fileVersions: [{ repoId: 'core-id', file: 'notes.org', version: 'original-file' }] });
});

test('标题与正文原子修改；清空正文传空字符串，未变更不提交', async () => {
  const f = fixture();
  await f.service.update({}, f.note, f.note.heading, f.note.body);
  assert.equal(f.requests.length, 0);
  await f.service.update({}, f.note, '新标题', '');
  assert.deepEqual(f.requests[0].operations[0].data.modifications, [
    { field: 'TITLE', value: '新标题' }, { field: 'BODY', value: '' }
  ]);
});

test('删除使用原快照版本，本地仓库不登记 WebDAV 上传', async () => {
  const f = fixture(); f.repository.webdavEnabled = false;
  await f.service.remove({}, f.note);
  assert.deepEqual(f.requests[0], { operations: [{ type: 'Deletion', data: { path: f.note.fullPath } }],
    queueRepoIds: [], fileVersions: [{ repoId: 'core-id', file: 'notes.org', version: 'original-file' }] });
});

test('空标题、失效目标与已移除仓库拒绝写入，不回退目标', async () => {
  const f = fixture();
  await assert.rejects(f.service.createMemo({}, '  ', ''), /标题不能为空/);
  await assert.rejects(f.service.update({}, f.note, ' ', ''), /标题不能为空/);
  f.invalidate();
  await assert.rejects(f.service.createMemo({}, '标题', ''), /重新选择/);
  f.repo.id = 'another-core-id';
  await assert.rejects(f.service.remove({}, f.note), /目标仓库不可用/);
  assert.equal(f.requests.length, 0);
});

test('Core 版本冲突原样返回给页面，不以新版本自动重试覆盖', async () => {
  const f = fixture();
  const error = Object.assign(new Error('文件版本已变化，请重新读取'), { code: 'invalidState' });
  f.fail(error);
  await assert.rejects(f.service.update({}, f.note, '新标题', '正文'), e => e === error);
  await assert.rejects(f.service.remove({}, f.note), e => e === error);
  assert.equal(f.requests.length, 0);
});

// 仅转译页面的状态与提交方法，ArkUI 布局由实际 HAP 编译检查。
function page(name, service, router, notifications = { async refresh() {} }) {
  const filename = path.resolve('entry/src/main/ets/pages/' + name + '.ets');
  let source = fs.readFileSync(filename, 'utf8');
  source = source.slice(0, source.indexOf('\n  build()')) + '\n}';
  source = source.replace(/^@(Entry|Component)\n/gm, '').replace(/^  @State /gm, '  ')
    .replace(/^  @StorageLink\('[^']+'\) /gm, '  ').replace('struct ' + name, 'export class ' + name);
  const module = { exports: {} };
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInThisContext('(function(require,module,exports){' + compiled + '\n})', { filename })(dependency => {
    if (dependency.endsWith('/NoteService')) return { NoteService: service };
    if (dependency.endsWith('/TaskRepeatDialog')) return { TaskRepeatDialog: class {} };
    if (dependency.endsWith('/AppConfigService')) return { AppConfigService: { async load() { return {repos:[]}; } } };
    if (dependency.endsWith('/PageQueryService')) return { PageQueryService: { async query() { await notifications.refresh(); return []; } } };
    if (dependency.endsWith('/CoreNotificationService')) return { CoreNotificationService: notifications,
      emptyCoreNotificationsState: () => ({ notifications: [], repositories: [], revision: 0 }) };
    if (dependency.endsWith('/NativeCoreService')) return { coreErrorMessage: error => error.message };
    if (dependency.endsWith('/ui/Theme')) return { UiColor: { error: '#FF7592' } };
    throw new Error('缺少页面替身: ' + dependency);
  }, module, module.exports);
  const instance = new module.exports[name]();
  instance.getUIContext = () => ({ getRouter: () => router, getHostContext: () => ({}) });
  return instance;
}

test('备忘编辑刷新通知不重读路由或覆盖正在编辑的标题与正文', async () => {
  let refreshes = 0;
  const memo = page('MemoEdit', {}, { getParams() { assert.fail('通知刷新不重读路由'); } }, {
    async refresh() { refreshes++; }
  });
  memo.heading = '未保存的标题'; memo.body = '未保存的正文\n第二行';
  await memo.refreshNotifications();
  assert.equal(refreshes, 1);
  assert.equal(memo.heading, '未保存的标题');
  assert.equal(memo.body, '未保存的正文\n第二行');
  assert.equal(memo.committed, false);
});

test('备忘通知读取失败保留已有通知、编辑草稿及保存错误', async () => {
  const memo = page('MemoEdit', {}, {}, { async refresh() { throw new Error('通知暂不可用'); } });
  const snapshot = { notifications: [{ type: 'syncConflict' }], repositories: [], revision: 1 };
  memo.notificationState = snapshot;
  memo.heading = '草稿标题'; memo.body = '草稿正文'; memo.message = '文件版本已变化';
  const messages = [];
  memo.getUIContext = () => ({ getHostContext: () => ({}),
    getPromptAction: () => ({ showToast: value => messages.push(value.message) }) });
  await memo.refreshNotifications();
  assert.equal(memo.notificationState, snapshot);
  assert.equal(memo.heading, '草稿标题'); assert.equal(memo.body, '草稿正文');
  assert.equal(memo.message, '文件版本已变化');
  assert.deepEqual(messages, ['读取通知失败：通知暂不可用']);
});

test('新建提交成功而导航失败后，仅重试返回，不重复创建', async () => {
  let creations = 0, navigations = 0;
  const memo = page('MemoEdit', { async createMemo() { creations++; } }, {
    async back() { if (++navigations === 1) throw new Error('导航失败'); }
  });
  memo.creating = true; memo.heading = '新备忘'; memo.body = '正文';
  await memo.saveAndBack();
  assert.equal(memo.committed, true);
  assert.match(memo.message, /备忘已保存/);
  await memo.saveAndBack();
  assert.equal(creations, 1);
  assert.equal(navigations, 2);
});

test('空白新建返回不写入，保存空标题提示修正', async () => {
  let navigations = 0;
  const memo = page('MemoEdit', { async createMemo() { assert.fail('空标题不可提交'); } }, {
    async back() { navigations++; }
  });
  memo.creating = true;
  await memo.saveAndBack();
  assert.equal(memo.message, '标题不能为空');
  assert.equal(navigations, 0);
  await memo.saveAndBack(true);
  assert.equal(navigations, 1);
});

test('任务保存失败保留原快照和编辑草稿，提交期间阻止重复保存', async () => {
  const f = fixture();
  let release, calls = 0, navigations = 0;
  const task = page('TaskEdit', { async update(context, note, heading, body) {
    calls++;
    assert.equal(note, f.note);
    assert.equal(heading, '修改标题'); assert.equal(body, '修改正文');
    await new Promise(resolve => { release = resolve; });
    throw new Error('文件版本已变化');
  } }, { async back() { navigations++; } });
  task.task = f.note; task.editing = true; task.heading = '修改标题'; task.body = '修改正文';
  const saving = task.saveAndBack();
  assert.equal(task.working, true);
  await task.saveAndBack();
  assert.equal(calls, 1);
  release(); await saving;
  assert.equal(task.working, false);
  assert.equal(task.committed, false);
  assert.equal(task.heading, '修改标题'); assert.equal(task.body, '修改正文');
  assert.match(task.message, /文件版本已变化/);
  assert.equal(navigations, 0);
});

test('任务删除完成后导航失败，返回时不提交尚未保存的修改', async () => {
  const f = fixture();
  let removals = 0, navigations = 0;
  const task = page('TaskEdit', { async remove() { removals++; }, async update() { assert.fail('已删除不可再保存'); } }, {
    async back() { if (++navigations === 1) throw new Error('导航失败'); }
  });
  task.task = f.note; task.editing = true; task.heading = '尚未提交';
  await task.deleteNote();
  assert.match(task.message, /记录已删除/);
  await task.saveAndBack();
  assert.equal(removals, 1);
  assert.equal(navigations, 2);
});
