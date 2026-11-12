// 验证只读任务快照更新时列表行与点击参数的一致性；不连接 WebDAV 或系统日历。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-task-presentation.cjs\n验证任务刷新后的行内容、点击参数、日期展示、宽度分配、展示层标签筛选、侧边栏批量查询计数、项目区块与来源文字和同步日志展示。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
  process.exit(0);
}
const deveco = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(deveco, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const filename = path.resolve(__dirname, '../entry/src/main/ets/ui/TaskPresentation.ets');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
});
const exported = {};
vm.runInThisContext('(function(exports){' + compiled.outputText + '\n})', { filename })(exported);
const { taskRenderKey } = exported;

// 与 native Task 一样，数据字段只读且可枚举，行为位于原型上。
function task(id, values = {}) {
  const result = Object.create({ taskStateOf(category) { return category === 'Done' ? { name: 'DONE', category } : null; }, isDone() { return this.state?.category === 'Done' || this.state?.category === 'Cancel'; }, project() { return this.projectName ?? null; } });
  for (const [key, value] of Object.entries({ id, repoId: 'repo', heading: '记录', headingParts: [], category: null,
    state: { name: 'TODO', category: 'Todo' }, projectName: null, priority: '', scheduled: '', deadline: '', tags: [],
    filePath: 'inbox.org', fileName: 'inbox.org', level: 1, body: '正文', bodyHtml: '<p>正文</p>', logbookHtml: '',
    hasList: false, hasText: true, isRepeating: false, isHabit: false, progress: -1, ...values })) {
    Object.defineProperty(result, key, { value, enumerable: true });
  }
  return result;
}

// ForEach 对同键条目保留已有行及其点击闭包。
function refresh(previous, tasks, keyFor = taskRenderKey) {
  const rows = new Map();
  for (const value of tasks) {
    const key = keyFor(value);
    rows.set(key, previous.get(key) || { heading: value.heading, body: value.body,
      done: value.isDone(), open: () => value });
  }
  return rows;
}

test('删除前两条记录后，剩余行与点击对象对应最新结果', () => {
  const initial = [task('alpha', { heading: 'Alpha' }), task('bravo', { heading: 'Bravo' }),
    task('charlie', { heading: 'Charlie' }), task('delta', { heading: 'Delta' })];
  const updated = [task('charlie', { heading: 'Charlie', body: '更新正文' }), task('delta', { heading: 'Delta' })];
  const rows = [...refresh(refresh(new Map(), initial), updated).values()];
  assert.deepEqual(rows.map(row => row.heading), ['Charlie', 'Delta']);
  assert.equal(rows[0].body, '更新正文');
  assert.equal(rows[0].open(), updated[0]);
});

test('逻辑 ID 稳定时，状态、进度标题和正文仍更新；仅用 ID 会复现旧行残留', () => {
  const before = task('same-id', { heading: '项目 [0/2]' });
  const after = task('same-id', { heading: '项目 [2/2]', state: { name: 'DONE', category: 'Done' }, body: '新正文' });
  const legacy = refresh(refresh(new Map(), [before], task => task.id), [after], task => task.id);
  assert.equal([...legacy.values()][0].open(), before);
  const rows = refresh(refresh(new Map(), [before]), [after]);
  const row = [...rows.values()][0];
  assert.equal(row.heading, '项目 [2/2]');
  assert.equal(row.body, '新正文');
  assert.equal(row.done, true);
  assert.equal(row.open(), after);
});

test('只修改目标分类设置时，即使当前任务内容不变也更新点击对象', () => {
  const before = task('same-id');
  const after = task('same-id');
  Object.setPrototypeOf(after, { ...Object.getPrototypeOf(after), taskStateOf(category) {
    return category === 'Done' ? { name: 'FINISHED', category } : null;
  } });
  assert.equal(JSON.stringify(before), JSON.stringify(after));
  assert.notEqual(taskRenderKey(before), taskRenderKey(after));
  const rows = refresh(refresh(new Map(), [before]), [after]);
  assert.equal([...rows.values()][0].open(), after);
});

test('计划、标签、链接及详情正文更新都能刷新点击参数，相同快照继续复用', () => {
  const before = task('same-id');
  assert.equal(taskRenderKey(before), taskRenderKey(task('same-id')));
  for (const changes of [{ scheduled: '2026-11-06' }, { deadline: '2026-11-07' }, { priority: 'A' },
    { tags: ['work'] }, { category: '生活' }, { headingParts: [{ text: '链接', href: 'https://example.org', isLink: true }] },
    { state: { name: 'ACTIVE', category: 'Doing' } }, { state: { name: 'STOP', category: 'Cancel' } }, { bodyHtml: '<p>新正文</p>' }, { logbookHtml: '<p>新日志</p>' }]) {
    const after = task('same-id', changes);
    const rows = refresh(refresh(new Map(), [before]), [after]);
    assert.equal([...rows.values()][0].open(), after);
  }
});

const presentationFile = path.resolve(__dirname, '../entry/src/main/ets/ui/TaskListPresentation.ets');
const presentationCode = ts.transpileModule(fs.readFileSync(presentationFile, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
});
const presentation = {};
const localDate = date => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
vm.runInThisContext('(function(exports,require){' + presentationCode.outputText + '\n})', { filename: presentationFile })(
  presentation, name => { assert.equal(name, './Theme'); return { localDate, UiColor: { secondary: '#AEACA9', deadline: '#FF3869' } }; });

const { taskDurationDays, taskDateIsToday, taskDateText, taskRowLayout, taskIndicators, taskTitleText, taskTagColor } = presentation;

test('标签按名称保持配色，不同常用标签可区分，浅色文字保持足够对比度', () => {
  const tags = ['工作', '生活', '阅读', 'work', 'home', '项目_A'];
  const colors = tags.map(taskTagColor);
  assert.equal(new Set(colors).size, tags.length);
  assert.deepEqual([...tags].reverse().map(taskTagColor).reverse(), colors);
  function luminance(color) {
    const channels = color.slice(1).match(/../g).map(value => parseInt(value, 16) / 255)
      .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
  }
  for (let index = 0; index < 1000; index++) {
    const color = taskTagColor(`标签_${index}`);
    assert.match(color, /^#[0-9a-f]{6}$/);
    assert.ok((luminance('#F5F5F5') + 0.05) / (luminance(color) + 0.05) >= 4.5, color);
  }
});

test('持续天数仅使用有效计划日期，无计划、当天与未来不显示', () => {
  const today = new Date(2026, 10, 6, 23, 59);
  for (const [values, expected] of [
    [{ scheduled: '2026-11-03', deadline: '2026-11-01' }, 3],
    [{ scheduled: '2026-11-06', deadline: '2026-11-01' }, 0],
    [{ scheduled: '2026-11-20' }, 0],
    [{ deadline: '2026-11-03' }, 0],
    [{ scheduled: '2026-02-30' }, 0],
    [{ scheduled: '2026-02-30', deadline: '2026-11-03' }, 0],
    [{ scheduled: '无效', deadline: '2026-11-03' }, 0],
    [{}, 0]
  ]) assert.equal(taskDurationDays(task('id', values), today), expected);
});

test('持续天数跨夏令时仍按设备本地自然日计算', () => {
  const previous = process.env.TZ;
  try {
    process.env.TZ = 'America/New_York';
    for (const [scheduled, year, month, day] of [['2026-03-07', 2026, 2, 9], ['2026-10-31', 2026, 10, 2]]) {
      assert.equal(taskDurationDays(task('id', { scheduled }), new Date(year, month, day, 1)), 2);
    }
  } finally { if (previous === undefined) delete process.env.TZ; else process.env.TZ = previous; }
});

test('计划与截止日期展示区分今天、紧凑日期、跨年日期与无效日期', () => {
  const today = new Date(2026, 10, 6);
  assert.equal(taskDateIsToday('2026-11-06', today), true);
  assert.equal(taskDateText('2026-11-06', true, today), '今天');
  assert.equal(taskDateText('2026-11-20', true, today), '11/20');
  assert.equal(taskDateText('2026-11-20', false, today), '11月20日 周五');
  assert.equal(taskDateText('2027-11-20', false, today), '2027年11月20日 周六');
  assert.equal(taskDateText('2026-02-30', false, today), '日期不可用');
});

test('窄屏、多标签与多标志不会占用截止日期预留区，标题保持至少一半剩余宽度', () => {
  for (const width of [180, 240, 280, 320, 350, 500, 800]) {
    for (const tags of [0, 1, 20]) {
      for (const indicators of [0, 1, 3]) {
        for (const duration of [0, 3, 12345678]) {
          for (const deadlineWidth of [0, 44, 50, 56, 80]) {
            const layout = taskRowLayout(width, tags, indicators, duration, deadlineWidth);
            const available = width - 26 - (deadlineWidth > 0 ? deadlineWidth + 8 : 0);
            const sizes = [layout.tagWidth, layout.indicatorWidth, layout.durationWidth].filter(size => size > 0);
            const used = sizes.reduce((sum, size) => sum + size + 6, 0);
            assert.ok(used <= available * 0.45 + 0.001, JSON.stringify({ width, tags, indicators, duration, deadlineWidth, layout }));
            assert.ok(layout.firstTagWidth >= 0);
            if (layout.showMoreTags) assert.ok(layout.firstTagWidth + 26 === layout.tagWidth);
          }
        }
      }
    }
  }
});

test('标志直接采用 Core 投影，完整可读标题与新快照保持一致', () => {
  const value = task('id', { heading: '原始链接标题', headingParts: [{ text: '参考资料', href: 'https://example.org', isLink: true }],
    hasList: true, isRepeating: true });
  assert.deepEqual(taskIndicators(value), ['list', 'body']);
  assert.deepEqual(taskIndicators(task('list-only', { hasList: true, hasText: false, bodyHtml: '<ul><li>列表</li></ul>' })), ['list']);
  assert.deepEqual(taskIndicators(task('no-hints', { hasText: false })), []);
  assert.equal(taskTitleText(value), '参考资料');
  assert.equal(taskTitleText(task('empty-parts', { heading: '普通标题' })), '普通标题');
  const after = task('id', { hasList: false, isRepeating: false });
  assert.notEqual(taskRenderKey(value), taskRenderKey(after));
  const habit = task('id', { hasList: false, isRepeating: false, isHabit: true });
  assert.notEqual(taskRenderKey(after), taskRenderKey(habit));
  assert.equal([...refresh(refresh(new Map(), [after]), [habit]).values()][0].open(), habit);
});

const countsFile = path.resolve(__dirname, '../entry/src/main/ets/ui/TitleCountPresentation.ets');
const countsCode = ts.transpileModule(fs.readFileSync(countsFile, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
});
const countsView = {};
vm.runInThisContext('(function(exports){' + countsCode.outputText + '\n})', { filename: countsFile })(countsView);

test('计数投影区分空值、零总数与有效比例，不从普通标题猜测计数', () => {
  const { titleCounts, titleCountLabel, titleCountValue } = countsView;
  const parts = [{ text: '普通 [1/2]', count: null }, { text: '1/2', count: { completed: 1, total: 2 } }];
  assert.deepEqual(titleCounts(parts), [{ completed: 1, total: 2 }]);
  for (const [count, label, value] of [
    [{ completed: null, total: null }, '—/—', 0],
    [{ completed: 0, total: 0 }, '0/0', 0],
    [{ completed: 0, total: 6 }, '0/6', 0],
    [{ completed: 1, total: 2 }, '1/2', 50],
    [{ completed: 2, total: 2 }, '2/2', 100]
  ]) {
    assert.equal(titleCountLabel(count), label);
    assert.equal(titleCountValue(count), value);
  }
});

test('窄屏与多个长计数退回图标，仍为日期和标题预留空间', () => {
  const { titleCountsWidth } = countsView;
  const parts = Array.from({ length: 3 }, () => ({ count: { completed: 123456, total: 123456 } }));
  assert.equal(titleCountsWidth([], 100), 0);
  assert.equal(titleCountsWidth(parts, 70), 14);
  const short = [{ count: { completed: 1, total: 2 } }];
  assert.ok(titleCountsWidth(short, 100) < 100);
  for (const budget of [14, 70, 140]) {
    const countWidth = titleCountsWidth(parts, budget);
    const layout = taskRowLayout(350, 3, 3, 181, 54, countWidth);
    const used = [layout.tagWidth, layout.indicatorWidth, layout.durationWidth]
      .filter(width => width > 0).reduce((sum, width) => sum + width + 6, 0);
    const available = 350 - 26 - 62 - countWidth - 6;
    assert.ok(used <= available * 0.45 + 0.001);
  }
});


test('折叠日期与计划分组使用有效日期中较早的一天', () => {
  for (const [values, expected] of [
    [{ scheduled: '2026-11-12', deadline: '2026-11-18' }, '2026-11-12'],
    [{ scheduled: '2026-11-18', deadline: '2026-11-12' }, '2026-11-12'],
    [{ scheduled: '2026-02-30', deadline: '2026-11-12' }, '2026-11-12'],
    [{ scheduled: '2026-11-12' }, '2026-11-12'],
    [{ deadline: '2027-01-01' }, '2027-01-01'],
    [{}, '']
  ]) assert.equal(presentation.taskDisplayDate(task('id', values)), expected);
});

test('截止日期的未来、当天、逾期、已完成与无效状态使用一致文案和颜色', () => {
  const today = new Date(2026, 10, 12, 23, 59);
  for (const [values, label, color] of [
    [{ deadline: '2026-11-18' }, '剩下 6 天', '#AEACA9'],
    [{ deadline: '2026-11-12' }, '今天截止', '#FF3869'],
    [{ deadline: '2026-11-06' }, '逾期 6 天', '#FF3869'],
    [{ deadline: '2026-11-06', state: { name: 'DONE', category: 'Done' } }, '11/6', '#AEACA9'],
    [{ deadline: '2026-02-30' }, '日期不可用', '#AEACA9'],
    [{ deadline: '' }, '日期不可用', '#AEACA9']
  ]) {
    const value = task('id', values);
    assert.equal(presentation.taskDeadlineText(value, today), label);
    assert.equal(presentation.taskDeadlineColor(value, today), color);
  }
});

function loadGrouping(name, dependencies) {
  const filename = path.resolve(__dirname, `../entry/src/main/ets/ui/${name}.ets`);
  const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  });
  const result = {};
  class ReferenceDate extends Date {
    constructor(...args) { super(...(args.length ? args : [2026, 10, 7, 12])); }
  }
  vm.runInThisContext('(function(exports,require,Date){' + code.outputText + '\n})', { filename })(
    result, name => { assert.ok(dependencies[name], name); return dependencies[name]; }, ReferenceDate);
  return result;
}

test('今天从只读任务分类分区，跨仓库同名分类合并且保留每一条任务', () => {
  const { todaySections } = loadGrouping('TodayPresentation', {});
  const tasks = [task('a', { category: '生活' }), task('b', { repoId: 'another', category: '生活' }),
    task('c', { category: null }), task('d', { category: '' })];
  const sections = todaySections(tasks);
  assert.deepEqual(sections.map(section => section.category), ['生活', null]);
  assert.deepEqual(sections[0].items.map(item => item.task), tasks.slice(0, 2));
  assert.deepEqual(sections[1].items.map(item => item.task), tasks.slice(2));
});

test('计划按日期组织原任务快照，保留空日期、月分组与分类数据', () => {
  const { plannedGroups } = loadGrouping('PlannedPresentation', {
    './Theme': { localDate }, './TaskListPresentation': presentation
  });
  const tasks = [task('day', { scheduled: '2026-11-08', category: '生活', isRepeating: true }),
    task('range', { scheduled: '2026-11-16', deadline: '2026-11-15', category: '工作' }),
    task('month', { deadline: '2026-12-01', category: '' }),
    task('year', { scheduled: '2027-11-01', category: null })];
  const groups = plannedGroups(tasks);
  assert.equal(groups.filter(group => group.kind === 'day').length, 7);
  assert.equal(groups.find(group => group.key === 'day:2026-11-09').items.length, 0);
  for (const [key, task] of [['day:2026-11-08', tasks[0]], ['range:2026-11', tasks[1]],
    ['month:2026-12', tasks[2]], ['year:2027', tasks[3]]]) {
    assert.equal(groups.find(group => group.key === key).items[0].task, task);
  }
  assert.equal(groups.flatMap(group => group.items).length, tasks.length);
});

const tagFilters = loadGrouping('TaskTagFilterPresentation', {});

test('备忘 TAGS 花括号组互斥切换，跨组匹配交集，未分组标签保留并集', () => {
  const groups = [['iOS', 'Android'], ['BUG', 'FEAT'], ['SDK', 'COOL']];
  const selection = { tags: ['iOS', 'BUG', 'SDK'], includeUntagged: false };
  const changed = tagFilters.toggleTaskTag(selection, 'Android', groups);
  assert.deepEqual(changed, { tags: ['BUG', 'SDK', 'Android'], includeUntagged: false });
  assert.deepEqual(selection.tags, ['iOS', 'BUG', 'SDK']);
  assert.deepEqual(tagFilters.toggleTaskTag(changed, 'Android', groups).tags, ['BUG', 'SDK']);
  const tasks = [task('ios-bug', { tags: ['iOS', 'BUG', 'SDK'] }), task('android-bug', { tags: ['Android', 'BUG', 'SDK'] }),
    task('ios-feat', { tags: ['iOS', 'FEAT', 'SDK'] }), task('ios-bug-cool', { tags: ['iOS', 'BUG', 'COOL'] }), task('none')];
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, selection, groups), [tasks[0]]);
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['iOS', 'BUG'], includeUntagged: true }, groups), [tasks[0], tasks[3], tasks[4]]);
  assert.deepEqual(tagFilters.reconcileTaskTags({ tags: ['iOS', 'Android', 'BUG'], includeUntagged: false },
    ['iOS', 'Android', 'BUG'], groups).tags, ['Android', 'BUG']);
  assert.deepEqual(tagFilters.groupedTaskTags(['Android', 'BUG', 'iOS', '自定义'], groups), [['iOS', 'Android'], ['BUG'], ['自定义']]);
});

test('备忘标签候选合并任务标签与 TAGS 配置，未使用候选保留但不赋给任务', () => {
  const tasks = [task('a', { tags: ['家居'] }), task('b', { tags: ['工作'] }), task('c')];
  const configured = ['家居', 'unused'];
  const options = tagFilters.taskTagOptions(tasks, configured);
  assert.deepEqual(options, ['unused', '家居', '工作'].sort((a, b) => a.localeCompare(b)));
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['unused'], includeUntagged: false }), []);
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['家居'], includeUntagged: false }), [tasks[0]]);
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: [], includeUntagged: true }), [tasks[2]]);
  assert.deepEqual(tagFilters.taskTagOptions([], configured), configured.slice().sort((a, b) => a.localeCompare(b)));
  assert.deepEqual(configured, ['家居', 'unused']);
});

test('标签候选从完整任务快照去重，包含 Core 提供的继承标签且不随当前选择缩减', () => {
  const tasks = [task('a', { tags: ['阅读', '技术'] }), task('b', { tags: ['外出', '阅读'] }), task('c')];
  assert.deepEqual(tagFilters.taskTagOptions(tasks), ['外出', '技术', '阅读'].sort((a, b) => a.localeCompare(b)));
  const selected = tagFilters.filterTasksByTags(tasks, { tags: ['技术'], includeUntagged: false });
  assert.equal(selected.length, 1);
  assert.equal(selected[0], tasks[0]);
  assert.deepEqual(tasks.map(value => value.tags), [['阅读', '技术'], ['外出', '阅读'], []]);
});

test('展示层标签多选按并集匹配，全部恢复原快照，无标签不匹配已有标签的任务', () => {
  const tasks = [task('a', { tags: ['阅读', '技术'] }), task('b', { tags: ['外出'] }),
    task('c'), task('d', { tags: ['等待'] })];
  const all = { tags: [], includeUntagged: false };
  assert.equal(tagFilters.filterTasksByTags(tasks, all), tasks);
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['阅读', '外出'], includeUntagged: false }), tasks.slice(0, 2));
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: [], includeUntagged: true }), [tasks[2]]);
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['外出'], includeUntagged: true }), [tasks[1], tasks[2]]);
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['read'], includeUntagged: false }), []);
});

test('标签选择再次点击取消，不改写输入状态；刷新仅清理失效标签', () => {
  const initial = { tags: ['阅读'], includeUntagged: true };
  const added = tagFilters.toggleTaskTag(initial, '外出');
  assert.deepEqual(added, { tags: ['阅读', '外出'], includeUntagged: true });
  assert.deepEqual(initial, { tags: ['阅读'], includeUntagged: true });
  assert.deepEqual(tagFilters.toggleTaskTag(added, '阅读'), { tags: ['外出'], includeUntagged: true });
  assert.deepEqual(tagFilters.reconcileTaskTags(added, ['阅读']), initial);
  const cleared = tagFilters.reconcileTaskTags({ tags: ['已消失'], includeUntagged: false }, ['阅读']);
  assert.equal(tagFilters.allTaskTagsSelected(cleared), true);
});

test('今天先按标签筛选再按分类分区，隐藏空分类且不影响源任务与标签候选', () => {
  const { todaySections } = loadGrouping('TodayPresentation', {});
  const tasks = [task('a', { category: '工作', tags: ['技术'] }), task('b', { category: '生活', tags: ['外出'] })];
  const visible = tagFilters.filterTasksByTags(tasks, { tags: ['外出'], includeUntagged: false });
  const sections = todaySections(visible);
  assert.deepEqual(sections.map(section => section.category), ['生活']);
  assert.equal(sections[0].items[0].task, tasks[1]);
  assert.equal(tasks.length, 2);
  assert.equal(tagFilters.taskTagOptions(tasks).length, 2);
});


test('扁平标签完整匹配，不按名称前缀或分隔符推断级联关系', () => {
  const tasks = [task('a', { tags: ['阅读'] }), task('b', { tags: ['阅读_技术'] }),
    task('c', { tags: ['阅读', '技术'] })];
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['阅读'], includeUntagged: false }), [tasks[0], tasks[2]]);
  assert.deepEqual(tagFilters.filterTasksByTags(tasks, { tags: ['技术'], includeUntagged: false }), [tasks[2]]);
});

const syncLogs = loadGrouping('SyncLogPresentation', {});
function syncRecord(values = {}) {
  return { id: 'sync', started_at: 1, finished_at: 2, result: 'succeeded', executionResult: 'succeeded',
    files: 2, downloadedFiles: 0, uploadedFiles: 0, errorMessage: null, conflicts: [], transfer: 'unchanged',
    errorCategory: null, ...values };
}

test('无变化筛选保留失败与冲突历史，切换全部时恢复原顺序和快照', () => {
  const records = [syncRecord(), syncRecord({ id: 'failure', executionResult: 'failed' }),
    syncRecord({ id: 'conflict', conflicts: ['a.org', 'b.org'] }), syncRecord({ id: 'transfer', transfer: 'download' })];
  assert.deepEqual(syncLogs.visibleSyncLogs(records, false), records.slice(1));
  assert.equal(syncLogs.visibleSyncLogs(records, true), records);
  assert.equal(records.length, 4);
});

test('历史冲突按固定文件列表计数，重读快照不出现已解决标签', () => {
  const conflict = syncRecord({ result: 'failed', conflicts: ['a.org', 'b.org', 'c.org'] });
  const reread = syncRecord({ ...conflict, conflicts: [...conflict.conflicts] });
  const next = syncRecord({ id: 'next-sync', conflicts: [] });
  assert.equal(syncLogs.syncLogConflictLabel(conflict), '冲突 3');
  assert.equal(syncLogs.syncLogConflictLabel(reread), '冲突 3');
  assert.equal(syncLogs.syncLogConflictLabel(next), '');
  assert.equal(syncLogs.syncLogResultLabel(conflict), '执行成功');
  assert.equal(syncLogs.syncLogErrorLabel(conflict), '');
  assert.equal(syncLogs.syncLogRenderKey(conflict), syncLogs.syncLogRenderKey(reread));
  assert.notEqual(syncLogs.syncLogRenderKey(conflict), syncLogs.syncLogRenderKey(next));
});

test('方向与执行错误分别展示，网络失败不改写已完成的传输方向', () => {
  const failed = syncRecord({ executionResult: 'failed', errorCategory: 'Network', transfer: 'upload', uploadedFiles: 2 });
  assert.equal(syncLogs.syncLogTransferLabel(failed), '上传2个文件');
  assert.equal(syncLogs.syncLogResultLabel(failed), '执行失败');
  assert.equal(syncLogs.syncLogErrorLabel(failed), '网络失败');
  assert.equal(syncLogs.syncLogTransferLabel(syncRecord({ transfer: 'bidirectional', downloadedFiles: 3, uploadedFiles: 2 })), '下载3/上传2');
});


test('单行标题包含两个方向的数量，具体错误优先且缺失数据不猜测', () => {
  assert.equal(syncLogs.syncLogTitle(syncRecord({ transfer: 'download', downloadedFiles: 14 })), '下载14个文件');
  assert.equal(syncLogs.syncLogTitle(syncRecord({ transfer: 'upload', uploadedFiles: 2 })), '上传2个文件');
  assert.equal(syncLogs.syncLogTitle(syncRecord({ transfer: 'bidirectional', downloadedFiles: 3, uploadedFiles: 2 })), '下载3/上传2');
  assert.equal(syncLogs.syncLogTitle(syncRecord({ transfer: 'upload', uploadedFiles: undefined })), '有上传');
  const failure = syncRecord({ executionResult: 'failed', transfer: 'upload', uploadedFiles: 2, errorMessage: '连接被重置\n请重试' });
  assert.equal(syncLogs.syncLogTitle(failure), '连接被重置 请重试 · 上传2个文件');
  assert.equal(syncLogs.syncLogTitle(syncRecord({ executionResult: 'failed' })), '执行失败');
});

test('日期在列表中紧凑显示，详情使用完整日期时间', () => {
  const timestamp = new Date(2026, 10, 8, 9, 4).getTime();
  assert.equal(syncLogs.syncLogTimeLabel(timestamp, true), '11-08 09:04');
  assert.equal(syncLogs.syncLogTimeLabel(timestamp), '2026-11-08 09:04');
});

const memoFile = path.resolve(__dirname, '../entry/src/main/ets/ui/MemoListPresentation.ets');
const memoCode = ts.transpileModule(fs.readFileSync(memoFile, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
});
const memoPresentation = {};
vm.runInThisContext('(function(exports){' + memoCode.outputText + '\n})', { filename: memoFile })(memoPresentation);

test('备忘摘要优先修改日期，回退创建日期，按日期、标签、Core 首行正文拼接', () => {
  const note = task('memo', { modifiedAt: new Date(2026, 10, 9, 12).getTime(),
    createdAt: new Date(2026, 9, 1, 12).getTime(), tags: ['家居', '装修'],
    body: '\n\n正文第一行\n第二行', bodyFirstLine: '正文第一行', scheduled: '2030-01-01' });
  assert.equal(memoPresentation.memoSummaryText(note), '11月9日  #家居 #装修  正文第一行');
  assert.equal(memoPresentation.memoSummaryText(task('memo', { modifiedAt: null,
    createdAt: new Date(2026, 9, 1, 12).getTime(), tags: [], bodyFirstLine: '只有正文' })), '10月1日  只有正文');
  assert.equal(memoPresentation.memoSummaryText(task('memo', { modifiedAt: null, createdAt: null,
    tags: [], bodyFirstLine: null })), '');
});

function navigationFixture(fail = false) {
  const filename = path.resolve(__dirname, '../entry/src/main/ets/components/AppShell.ets');
  const source = fs.readFileSync(filename, 'utf8');
  const method = source.match(/  async loadNavigation\(\) \{[\s\S]*?\n  \}/)[0];
  const code = ts.transpileModule('export class Navigation {' + method + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  const calls = [];
  const config = { repos: [{ id: 'repo' }], todoDefaults: 'defaults' };
  const workspace = { async repos() { return []; } };
  const native = { async workspaceFor() { return workspace; } };
  const pageQuery = { async query(_, queries) {
    calls.push(queries);
    if (fail) throw new Error('文件加载失败');
    return queries.map((request, index) => request.type === 'file' ? {type:'file',result:[{}]}
      : {type:'task', result:{tasks:Array(index<5?index:{inbox:7,someday:8,memo:9}[request.query.expression]).fill({}),categories:[]}});
  } };
  const fileTargets = { prepare(_, __, kind) { return {task:{type:'task',query:{expression:kind}},file:{type:'file',query:{}}}; },
    result(task, file) { return file.result.length ? task.result : undefined; } };
  vm.runInThisContext('(function(module,exports,AppConfigService,FileTargetService,NativeCoreService,PageQueryService,taskResult,overviewTaskQuery,overdueTaskQuery,coreErrorMessage){' + code + '\n})', { filename })(
    module, module.exports, { load: async () => config }, fileTargets, native, pageQuery, value=>value.result,
    view => ({ expression: view }), () => ({ expression: 'overdue' }), error => error.message
  );
  const view = Object.assign(new module.exports.Navigation(), {
    navigationRequest: 0, todayCount: 100, overdueCount: 101, plannedCount: 102, anytimeCount: 103, logbookCount: 104,
    getUIContext: () => ({ getHostContext: () => ({}) })
  });
  return { view, calls };
}

test('侧边栏一次提交所有任务和文件查询，空命中也按原结果下标显示计数', async () => {
  const { view, calls } = navigationFixture();
  await view.loadNavigation();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].filter(query=>query.type==='task').map(query => query.query.expression), ['today', 'overdue', 'planned', 'anytime', 'logbook', 'inbox', 'someday', 'memo']);
  assert.deepEqual([view.todayCount, view.overdueCount, view.plannedCount, view.anytimeCount, view.logbookCount], [0, 1, 2, 3, 4]);
  assert.deepEqual([view.inboxCount, view.somedayCount, view.memoCount], [7, 8, 9]);
});

test('批量查询拒绝时侧边栏保留原计数并显示整体加载错误', async () => {
  const { view, calls } = navigationFixture(true);
  await view.loadNavigation();
  assert.equal(calls.length, 1);
  assert.match(view.navMessage, /文件加载失败/);
  assert.deepEqual([view.todayCount, view.overdueCount, view.plannedCount, view.anytimeCount, view.logbookCount], [100, 101, 102, 103, 104]);
});


test('今天保留分类层级，仅项目任务组成区块，普通任务和项目内顺序均保留', () => {
  const { todaySections } = loadGrouping('TodayPresentation', {});
  const tasks = [task('a', { category: '工作' }), task('b', { category: '工作', projectName: '项目甲' }),
    task('c', { category: '工作' }), task('d', { category: '工作', projectName: '项目乙' }),
    task('e', { category: '工作', projectName: '项目甲' }), task('f', { category: null, projectName: '项目甲' })];
  const sections = todaySections(tasks, true);
  assert.deepEqual(sections.map(section => section.category), ['工作', null]);
  assert.deepEqual(sections[0].items.map(item => item.task), tasks.slice(0, 5));
  assert.deepEqual(sections[0].groups.map(group => [group.project, group.items.map(item => item.task.id)]),
    [[null, ['a']], ['项目甲', ['b', 'e']], [null, ['c']], ['项目乙', ['d']]]);
  assert.deepEqual(sections[1].groups.map(group => group.items.map(item => item.task.id)), [['f']]);
  const all = sections.flatMap(section => section.groups.flatMap(group => group.items.map(item => item.task.id)));
  assert.equal(all.length, tasks.length);
  assert.deepEqual([...all].sort(), tasks.map(value => value.id).sort());
});

test('随时保持原有分类，未命名项目仍是项目，筛选后不残留空项目区块', () => {
  const { todaySections } = loadGrouping('TodayPresentation', {});
  const values = [task('a', { category: '工作', projectName: '', tags: ['技术'] }),
    task('b', { category: '工作', projectName: '其他', tags: ['阅读'] }), task('c', { category: '工作' })];
  assert.ok(todaySections(values, false)[0].groups.every(group => group.project === null && group.items.length === 1));
  const visible = tagFilters.filterTasksByTags(values, { tags: ['技术'], includeUntagged: false });
  const groups = todaySections(visible, true)[0].groups;
  assert.equal(groups.length, 1);
  assert.equal(groups[0].project, '');
  assert.equal(groups[0].items[0].task, values[0]);
});

test('来源文字追加项目名，分类缺失时单独显示项目，非项目保留原文件名回退', () => {
  const { taskSourceText } = presentation;
  assert.equal(taskSourceText(task('a', { category: '工作', projectName: '项目甲' })), '工作 · 项目甲');
  assert.equal(taskSourceText(task('b', { category: null, projectName: '项目甲' })), '项目甲');
  assert.equal(taskSourceText(task('c', { category: '工作', projectName: '' })), '工作 · 未命名项目');
  assert.equal(taskSourceText(task('d', { category: '生活' })), '生活');
  assert.equal(taskSourceText(task('e', { category: null })), '');
  assert.equal(taskSourceText(task('f', { category: null }), true), 'inbox.org');
  assert.notEqual(taskRenderKey(task('same', { projectName: '旧项目' })), taskRenderKey(task('same', { projectName: '新项目' })));
});
