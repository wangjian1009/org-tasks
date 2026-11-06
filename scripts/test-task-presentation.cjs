// 验证只读任务快照更新时列表行与点击参数的一致性；不连接 WebDAV 或系统日历。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-task-presentation.cjs\n验证任务刷新后的行内容、点击参数、日期展示与单行宽度分配。\n环境变量 DEVECO_HOME 可指定 DevEco Studio Contents 目录。');
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
  const result = Object.create({ isDone() { return this.todoKind === 'done'; } });
  for (const [key, value] of Object.entries({ id, repoId: 'repo', heading: '记录', headingParts: [],
    todoState: 'TODO', todoKind: 'pending', priority: '', scheduled: '', deadline: '', tags: [],
    filePath: 'inbox.org', fileName: 'inbox.org', level: 1, body: '正文', bodyHtml: '<p>正文</p>', logbookHtml: '', progress: -1, ...values })) {
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
  const after = task('same-id', { heading: '项目 [2/2]', todoState: 'DONE', todoKind: 'done', body: '新正文' });
  const legacy = refresh(refresh(new Map(), [before], task => task.id), [after], task => task.id);
  assert.equal([...legacy.values()][0].open(), before);
  const rows = refresh(refresh(new Map(), [before]), [after]);
  const row = [...rows.values()][0];
  assert.equal(row.heading, '项目 [2/2]');
  assert.equal(row.body, '新正文');
  assert.equal(row.done, true);
  assert.equal(row.open(), after);
});

test('计划、标签、链接及详情正文更新都能刷新点击参数，相同快照继续复用', () => {
  const before = task('same-id');
  assert.equal(taskRenderKey(before), taskRenderKey(task('same-id')));
  for (const changes of [{ scheduled: '2026-11-06' }, { deadline: '2026-11-07' }, { priority: 'A' },
    { tags: ['work'] }, { headingParts: [{ text: '链接', href: 'https://example.org', isLink: true }] },
    { bodyHtml: '<p>新正文</p>' }, { logbookHtml: '<p>新日志</p>' }]) {
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
  presentation, name => { assert.equal(name, './Theme'); return { localDate }; });

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

test('持续天数优先使用计划日期，无计划时回退截止日期；当天与未来不显示', () => {
  const today = new Date(2026, 10, 6, 23, 59);
  for (const [values, expected] of [
    [{ scheduled: '2026-11-03', deadline: '2026-11-01' }, 3],
    [{ scheduled: '2026-11-06', deadline: '2026-11-01' }, 0],
    [{ scheduled: '2026-11-20' }, 0],
    [{ deadline: '2026-11-03' }, 3],
    [{ scheduled: '2026-02-30' }, 0],
    [{ scheduled: '无效', deadline: '2026-11-03' }, 3],
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
  assert.deepEqual(taskIndicators(value), ['body', 'list', 'repeat']);
  assert.equal(taskTitleText(value), '参考资料');
  assert.equal(taskTitleText(task('empty-parts', { heading: '普通标题' })), '普通标题');
  const after = task('id', { hasList: false, isRepeating: false });
  assert.notEqual(taskRenderKey(value), taskRenderKey(after));
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
