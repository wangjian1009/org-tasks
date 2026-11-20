// 使用真实 N-API Task 回调验证 ArkUI 深拷贝后的快照行为。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { test, after } = require('node:test');

if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node --expose-gc scripts/test-task-native-snapshot.cjs\n使用本机 C++ 编译器与 Node N-API 头文件，验证任务深拷贝、快照隔离及生命周期。\nNODE_INCLUDE 可指定 Node 头文件目录。');
  process.exit(0);
}

const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/cpp/napi_init.cpp'), 'utf8');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'orgtasks-native-snapshot-'));
after(() => fs.rmSync(directory, { recursive: true, force: true }));
const cpp = path.join(directory, 'snapshot.cpp');
const addon = path.join(directory, 'snapshot.node');
// 直接编译生产回调，保留 napi_wrap 与引用管理，避免用普通 JS 对象掩盖原生绑定丢失。
const callbacks = source.slice(source.indexOf('void FinalizeTask('), source.indexOf('struct MetadataStates'));
const metadataCallbacks = source.slice(source.indexOf('struct MetadataStates'), source.indexOf('napi_value CreateTaskObject('));
const metadataProjection = source.slice(source.indexOf('bool ProjectFileResult('), source.indexOf('bool ProjectQueryResults('));
const creation = source.slice(source.indexOf('napi_value CreateTaskObject('), source.indexOf('bool ProjectTaskResult('));
const registration = source.slice(source.indexOf('    napi_property_descriptor task_descriptors[]'), source.indexOf('    napi_property_descriptor file_descriptors[]'));
const eventProjection = source.slice(source.indexOf('bool ProjectQueryDataEvent('), source.indexOf('void DrainQueryWatch(napi_env env, struct DataChangeWatch* watch);'));
const parseJson = source.slice(source.indexOf('bool ParseJson('), source.indexOf('bool EncodeJson('));
const watch = source.match(/struct DataChangeWatch \{[\s\S]*?\n\};/)[0];
const drain = source.slice(source.indexOf('void DrainQueryWatch(napi_env env, DataChangeWatch* watch) {'), source.indexOf('extern "C" void org_tasks_harmony_data_change_update'));

fs.writeFileSync(cpp, `
#include <node_api.h>
#include <string>
#include <initializer_list>
#include <deque>
#include <mutex>
static napi_ref task_constructor;
${source.match(/struct TaskWrap \{[\s\S]*?\n\};/)[0]}
bool ReadString(napi_env env, napi_value value, std::string* result) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
    result->resize(length + 1);
    if (napi_get_value_string_utf8(env, value, result->data(), result->size(), &length) != napi_ok) return false;
    result->resize(length);
    return true;
}
${callbacks}
${creation}
${metadataCallbacks}
${metadataProjection}
${parseJson}
${eventProjection}
${watch}
${drain}
napi_value DeliverEvents(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2], event; std::string json;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!ReadString(env, args[0], &json)) return nullptr;
    DataChangeWatch watch;
    napi_create_reference(env, args[1], 1, &watch.callback);
    watch.pending.push_back(json);
    DrainQueryWatch(env, &watch);
    DrainQueryWatch(env, &watch);
    napi_delete_reference(env, watch.callback);
    napi_deferred deferred; napi_value promise;
    napi_create_promise(env, &deferred, &promise);
    napi_get_undefined(env, &event);
    napi_resolve_deferred(env, deferred, event);
    return promise;
}
napi_value Create(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value data;
    napi_get_cb_info(env, info, &argc, &data, nullptr, nullptr);
    return CreateTaskObject(env, data);
}
napi_value CreateMetadata(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value data, files;
    napi_get_cb_info(env, info, &argc, &data, nullptr, nullptr);
    napi_create_array_with_length(env, 1, &files);
    napi_set_element(env, files, 0, data);
    return ProjectFileResult(env, files) ? data : nullptr;
}
napi_value Init(napi_env env, napi_value exports) {
${registration}
    napi_value create;
    napi_create_function(env, "create", NAPI_AUTO_LENGTH, Create, nullptr, &create);
    napi_set_named_property(env, exports, "create", create);
    napi_value metadata;
    napi_create_function(env, "metadata", NAPI_AUTO_LENGTH, CreateMetadata, nullptr, &metadata);
    napi_set_named_property(env, exports, "metadata", metadata);
    napi_value deliver;
    napi_create_function(env, "deliver", NAPI_AUTO_LENGTH, DeliverEvents, nullptr, &deliver);
    napi_set_named_property(env, exports, "deliver", deliver);
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
`);
execFileSync('c++', ['-std=c++17', '-shared', '-undefined', 'dynamic_lookup',
  '-I', process.env.NODE_INCLUDE || '/opt/homebrew/include/node', cpp, '-o', addon]);
const native = require(addon);

function snapshot(name = 'DONE', done = false, reminderAt = null) {
  return native.create({ reminderAt, id: 'task', heading: '项目任务', hasAttach: true, appLinks: [{uri:'app:中国工商银行',label:'打开银行'}], properties: { VISIBILITY: 'folded', EMPTY: '' }, projectName: '项目甲', isDone: done, createdAt: 1700000000000, closedAt: done ? 1700003600000 : null,
    headingParts: [{ text: '参考', href: 'https://example.com/', isLink: true, count: null,
      link: { start: 0, end: 31, source: '[[https://example.com/][参考]]', title: '参考', url: 'https://example.com/' } }],
    editContent: { ownTags: [], notes: 'https://example.com/', notesHtml: '<main><p><a class="link" href="https://example.com/">https://example.com/</a></p></main>',
      checklist: [], scheduledRepeat: null, deadlineRepeat: null },
    logs: [{ type: 'taskStateChange', from: 'TODO', to: name, timestamp: '2026-11-13 09:00', noteHtml: '<p>附注</p>' }],
    defaultPriority: { name: 'C', category: 'Low' },
    priority: { name: 'B', category: 'Hight' }, priorityOptions: [{ name: 'B', category: 'Hight' }, { name: 'C', category: 'Low' }],
    taskPriorityOptions: { Hight: { name: 'B', category: 'Hight' }, Middle: null, Low: { name: 'C', category: 'Low' } },
    state: { name: 'TODO', category: 'Todo' }, taskStateOptions: {
      Todo: { name: 'TODO', category: 'Todo' }, Doing: null, Wait: null,
      Done: { name, category: 'Done' }, Cancel: null
    } });
}
function copy(value) {
  if (value === null || typeof value !== 'object') return value;
  const result = Array.isArray(value) ? [] : Object.create(Object.getPrototypeOf(value));
  for (const key of Object.keys(value)) result[key] = copy(value[key]);
  return result;
}

test('唯一提醒时间通过真实 N-API、深拷贝及序列化保留可空毫秒时间戳', () => {
  const original = snapshot('DONE', false, 1795136400000);
  assert.equal(original.reminderAt, 1795136400000);
  assert.equal(Object.getOwnPropertyDescriptor(original, 'reminderAt').writable, false);
  const cloned = copy(original); cloned.reminderAt = null;
  assert.equal(original.reminderAt, 1795136400000);
  assert.equal(JSON.parse(JSON.stringify(original)).reminderAt, 1795136400000);
  assert.equal(snapshot().reminderAt, null);
});

test('结构化日志穿过 N-API 与 ArkUI 深拷贝后保留类型和附注，快照互不影响', () => {
  const original = snapshot();
  const cloned = copy(original);
  assert.deepEqual(cloned.logs, original.logs);
  assert.ok(Object.keys(original).includes('logs'));
  assert.equal(Object.getOwnPropertyDescriptor(original, 'logs').writable, false);
  cloned.logs[0].to = 'WAIT';
  cloned.logs[0].noteHtml = '<p>新附注</p>';
  assert.equal(original.logs[0].to, 'DONE');
  assert.equal(original.logs[0].noteHtml, '<p>附注</p>');
  assert.equal(JSON.parse(JSON.stringify(original)).logs[0].type, 'taskStateChange');
  assert.equal(cloned.editContent.notesHtml, original.editContent.notesHtml);
  cloned.editContent.notesHtml = '<p>新备注</p>';
  assert.match(original.editContent.notesHtml, /href="https:\/\/example.com\/"/);
  assert.equal(JSON.parse(JSON.stringify(original)).editContent.notesHtml, original.editContent.notesHtml);
  assert.deepEqual(cloned.headingParts[0].link, original.headingParts[0].link);
  cloned.headingParts[0].link.source = '修改后的草稿';
  assert.equal(original.headingParts[0].link.source, '[[https://example.com/][参考]]');
});

test('仅复制字段和原型会丢失原生绑定，复现启动异常', () => {
  const task = snapshot();
  const unbound = Object.create(Object.getPrototypeOf(task));
  for (const [key, value] of Object.entries(task)) if (typeof value !== 'function') unbound[key] = value;
  assert.throws(() => unbound.taskStateOf('Done'), /Task.taskStateOf 参数无效|Illegal invocation/);
});

test('多层分组与重复深拷贝保留任务行为，序列化只包含数据', () => {
  const original = snapshot();
  const sections = copy(copy([{ groups: [{ items: [{ task: original }] }] }]));
  const task = sections[0].groups[0].items[0].task;
  assert.notEqual(task, original);
  assert.equal(task.isDone(), false);
  assert.equal(task.project(), '项目甲');
  assert.deepEqual(task.taskStateOf('Done'), { name: 'DONE', category: 'Done' });
  assert.equal(task.taskStateOf('Wait'), null);
  assert.equal(JSON.stringify(task), JSON.stringify(original));
  assert.equal(Object.hasOwn(JSON.parse(JSON.stringify(task)), 'taskStateOf'), false);
  const state = task.taskStateOf('Done');
  state.name = '修改副本';
  assert.equal(task.taskStateOf('Done').name, 'DONE');
  assert.throws(() => task.taskStateOf('Unknown'), /状态分类无效/);
});

test('旧快照不受新查询影响，复制方法持有原快照直至释放', () => {
  let original = snapshot();
  const task = copy(original);
  original = null;
  if (global.gc) global.gc();
  const newer = copy(snapshot('FINISHED', true));
  assert.equal(task.taskStateOf('Done').name, 'DONE');
  assert.equal(task.isDone(), false);
  assert.equal(newer.taskStateOf('Done').name, 'FINISHED');
  assert.equal(newer.isDone(), true);
  assert.equal(task.closedAt, null);
  assert.equal(newer.closedAt, 1700003600000);
  assert.equal(newer.createdAt, 1700000000000);
  assert.ok(Object.keys(newer).includes('closedAt'));
});


test('优先级查找在 ArkUI 深拷贝后仍使用 Core 的原始快照', () => {
  const original = snapshot();
  const task = copy(original);
  assert.deepEqual(task.priority, { name: 'B', category: 'Hight' });
  assert.deepEqual(task.defaultPriority, { name: 'C', category: 'Low' });
  assert.equal(JSON.parse(JSON.stringify(task)).defaultPriority.name, 'C');
  assert.deepEqual(task.taskPriorityOf('Hight'), { name: 'B', category: 'Hight' });
  assert.equal(task.taskPriorityOf('Middle'), null);
  const priority = task.taskPriorityOf('Hight');
  priority.name = 'A';
  task.priorityOptions[0].name = 'Z';
  assert.equal(task.taskPriorityOf('Hight').name, 'B');
  assert.equal(original.priorityOptions[0].name, 'B');
  assert.throws(() => task.taskPriorityOf('High'), /优先级分类无效/);
  assert.equal(Object.hasOwn(JSON.parse(JSON.stringify(task)), 'taskPriorityOf'), false);
});


test('文件元信息按分类返回独立优先级对象，不暴露私有查找快照',()=>{
  const data={projectName:null,category:'个人',taskStateCounts:[{state:'FINISHED',category:'Done',count:2},{state:'CUSTOM',category:null,count:1}],priorityOptions:[{name:'D',category:'Hight'}],
    taskStateOptions:{Todo:null,Doing:null,Wait:null,Done:null,Cancel:null},
    taskPriorityOptions:{Hight:{name:'D',category:'Hight'},Middle:null,Low:null}};
  const metadata=native.metadata(data);
  assert.deepEqual(metadata.taskStateCounts,data.taskStateCounts);
  assert.equal(metadata.category,'个人');
  assert.deepEqual(metadata.taskPriorityOf('Hight'),{name:'D',category:'Hight'});
  assert.equal(metadata.taskPriorityOf('Middle'),null);
  metadata.taskPriorityOf('Hight').name='A';
  assert.equal(metadata.taskPriorityOf('Hight').name,'D');
  assert.throws(()=>metadata.taskPriorityOf('High'),/优先级分类无效/);
  assert.equal(Object.hasOwn(metadata,'taskPriorityOptions'),false);
  assert.equal(Object.hasOwn(metadata,'taskStateOptions'),false);
  assert.equal(Object.hasOwn(JSON.parse(JSON.stringify(metadata)),'taskPriorityOf'),false);
});

test('通用属性读取随快照穿过 N-API 和 ArkUI 拷贝，保留空值和缺失差异', () => {
  const original = snapshot(), cloned = copy(original);
  for (const value of [original, cloned]) {
    assert.equal(value.property('visibility'), 'folded');
    assert.equal(value.property('EMPTY'), '');
    assert.equal(value.property('missing'), null);
    assert.equal(JSON.parse(JSON.stringify(value)).properties.VISIBILITY, 'folded');
  }
  assert.throws(() => original.property(10), /参数无效/);
});

test('附件标记作为只读可枚举快照穿过 N-API，深拷贝与序列化保留判断结果', () => {
  const original = snapshot();
  assert.equal(original.hasAttach, true);
  assert.equal(Object.getOwnPropertyDescriptor(original, 'hasAttach').writable, false);
  assert.ok(Object.keys(original).includes('hasAttach'));
  assert.equal(copy(original).hasAttach, true);
  assert.equal(JSON.parse(JSON.stringify(original)).hasAttach, true);
});


test('查询事件使用真实任务和文件方法，队列只交付一次且先于修改完成 Promise', async () => {
  const view = JSON.parse(JSON.stringify(snapshot()));
  view.isDone = true;
  view.taskStateOptions = { Todo: { name: 'TODO', category: 'Todo' }, Doing: null, Wait: null, Done: { name: 'DONE', category: 'Done' }, Cancel: null };
  view.taskPriorityOptions = { Hight: { name: 'A', category: 'Hight' }, Middle: null, Low: null };
  const file = { repoId: 'repo', path: 'a.org', projectName: null, category: 'Work', taskStateCounts: [], taskStateOptions: view.taskStateOptions, taskPriorityOptions: view.taskPriorityOptions };
  const order = [];
  const event = { type: 'notificationEvent', repoId: 'repo', operationId: 'dataset/page/2/update',
    changes: [{ kind: 'created', before: null, after: { task: { id: 'task' }, position: { parent: { repoId: 'repo', file: 'a.org', titles: [] } }, view } }],
    files: [{ before: null, after: { repoId: 'repo', path: 'a.org' }, afterView: file }] };
  let received;
  await native.deliver(JSON.stringify(event), value => { received = value;order.push('event'); }).then(() => order.push('complete'));
  assert.deepEqual(order, ['event', 'complete']);
  assert.equal(received.operationId, 'dataset/page/2/update');
  assert.equal(received.changes[0].after.view.isDone(), true);
  assert.equal(copy(received.changes[0].after.view).taskStateOf('Done').name, 'DONE');
  assert.equal(received.files[0].afterView.taskPriorityOf('Hight').name, 'A');
  assert.deepEqual(received.changes[0].after.task, { id: 'task' });
});


test('应用链接作为可枚举属性透传，复制与序列化不丢失',()=>{
 const task=snapshot();const links=[{uri:'app:中国工商银行',label:'打开银行'}];
 assert.deepEqual(task.appLinks,links);assert.deepEqual(copy(task).appLinks,links);
 assert.deepEqual(JSON.parse(JSON.stringify(task)).appLinks,links);
});
