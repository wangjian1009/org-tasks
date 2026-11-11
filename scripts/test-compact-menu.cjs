// 验证菜单在字号变化、窄窗口与异步关闭时使用实际内容边界。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-compact-menu.cjs\n验证菜单内容测量、窗口约束、选中标记、迟到请求与关闭后的操作。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(source, mocks) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInThisContext('(function(require,module,exports,$r){' + code + '\n})')(name => mocks[name] ?? {}, module, module.exports, name => name);
  return module.exports;
}
function fixture() {
  let width = 360, scale = 1, gate;
  const focus = [], actions = [], measured = [];
  const theme = load(fs.readFileSync('entry/src/main/ets/ui/Theme.ets', 'utf8'), {});
  const source = fs.readFileSync('entry/src/main/ets/components/CompactMenuButton.ets', 'utf8').split('\n  @Builder')[0] + '\n}';
  const { CompactMenuButton } = load(source.replace(/^@Component\n/gm, '').replace(/^  @(?:Prop|State) /gm, '  ').replace('export struct', 'export class'), {
    '../ui/Theme': theme,
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 360 }) }, window: { async getLastWindow() {
      if (gate) await gate;
      return { getWindowProperties: () => ({ windowRect: { width } }) };
    } } }
  });
  Object.assign(CompactMenuButton.prototype, { getUniqueId: () => 1, getUIContext: () => ({
    px2vp: v => v, getHostContext: () => ({}),
    getMeasureUtils: () => ({ measureTextSize(options) { measured.push(options); return { width: 48 * scale }; } }),
    getFocusController: () => ({ requestFocus: id => focus.push(id) })
  }) });
  const menu = new CompactMenuButton(); menu.aboutToAppear();
  menu.items = [{ title: '重复…', icon: 'repeat', action() { actions.push(menu.visible); } }];
  return { menu, focus, actions, measured, viewport(v) { width = v; }, scale(v) { scale = v; },
    defer() { let resolve; gate = new Promise(done => { resolve = done; }); return resolve; } };
}
test('字号增大按重新测量的文字自然增宽，窄窗口限制在安全边界内', async () => {
  const f = fixture(); await f.menu.toggle(); assert.equal(f.menu.menuWidth, 96);
  await f.menu.toggle(); f.scale(2); await f.menu.toggle(); assert.equal(f.menu.menuWidth, 144);
  await f.menu.toggle(); f.viewport(110); await f.menu.toggle(); assert.equal(f.menu.menuWidth, 78);
  assert.ok(f.measured.every(v => v.fontSize === '16fp'));
});
test('可选标记保留宽度，选中与取消不会让同一菜单忽宽忽窄', async () => {
  const f = fixture(); f.menu.items = [{ title: '无标签', checked: false, action() {} }];
  await f.menu.toggle(); const width = f.menu.menuWidth;
  await f.menu.toggle(); f.menu.items[0].checked = true; await f.menu.toggle();
  assert.equal(f.menu.menuWidth, width); assert.equal(width, 96);
});
test('路由移除或等待期间禁用，不显示迟到的菜单', async () => {
  for (const disable of [false, true]) {
    const f = fixture(), resolve = f.defer(), pending = f.menu.toggle();
    if (disable) f.menu.disabled = true; else f.menu.aboutToDisappear();
    resolve(); await pending; assert.equal(f.menu.visible, false);
  }
});
test('选择先关闭菜单再运行原动作；卸载后不恢复过期焦点', async () => {
  const f = fixture(); await f.menu.toggle(); f.menu.activate(f.menu.items[0]);
  assert.deepEqual(f.actions, [false]); f.menu.restoreFocus(); assert.equal(f.focus.length, 1);
  f.menu.aboutToDisappear(); f.menu.restoreFocus(); assert.equal(f.focus.length, 1);
});
