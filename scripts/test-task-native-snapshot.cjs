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
const creation = source.slice(source.indexOf('napi_value CreateTaskObject('), source.indexOf('bool ProjectTaskResult('));
const registration = source.slice(source.indexOf('    napi_property_descriptor task_descriptors[]'), source.indexOf('    napi_property_descriptor file_descriptors[]'));
fs.writeFileSync(cpp, `
#include <node_api.h>
#include <string>
#include <initializer_list>
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
napi_value Create(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value data;
    napi_get_cb_info(env, info, &argc, &data, nullptr, nullptr);
    return CreateTaskObject(env, data);
}
napi_value Init(napi_env env, napi_value exports) {
${registration}
    napi_value create;
    napi_create_function(env, "create", NAPI_AUTO_LENGTH, Create, nullptr, &create);
    napi_set_named_property(env, exports, "create", create);
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
`);
execFileSync('c++', ['-std=c++17', '-shared', '-undefined', 'dynamic_lookup',
  '-I', process.env.NODE_INCLUDE || '/opt/homebrew/include/node', cpp, '-o', addon]);
const native = require(addon);

function snapshot(name = 'DONE', done = false) {
  return native.create({ id: 'task', heading: '项目任务', projectName: '项目甲', isDone: done,
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
});
