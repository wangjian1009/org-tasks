// 验证公共弹出菜单的原生行测量、窗口约束、布局和异步生命周期。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-popup-menu.cjs\n验证菜单原生行测量、等宽布局、字号变化、窄窗口换行、迟到请求、焦点与关闭后的操作。');
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
function component(name, boundary, mocks = {}, file = name) {
  const source = fs.readFileSync(`entry/src/main/ets/components/${file}.ets`, 'utf8');
  const prefix = source.split('@Component')[0];
  const body = source.slice(source.indexOf(`struct ${name}`)).split(boundary)[0] + '\n}';
  return load(prefix + body.replace(/^  @(?:Prop|State) /gm, '  ').replace(`struct ${name}`, `export class ${name}`), mocks)[name];
}
const theme = load(fs.readFileSync('entry/src/main/ets/ui/Theme.ets', 'utf8'), {});
const PopupMenu = component('PopupMenu', '\n  build()', { '../ui/Theme': theme });
const PopupMenuRow = component('PopupMenuRow', '\n  build()', { '../ui/Theme': theme }, 'PopupMenu');
function nativeLeaf(naturalWidth, naturalHeight) {
  return {
    measureResult: { width: 0, height: 0 }, position: undefined,
    measure({ minWidth, maxWidth, minHeight }) {
      const width = Math.max(minWidth, Math.min(naturalWidth, maxWidth));
      this.measureResult = { width, height: Math.max(minHeight, Math.ceil(naturalWidth / width) * naturalHeight || 0) };
      return this.measureResult;
    },
    layout(position) { this.position = position; }
  };
}
test('原生文字测量时预留图标和勾选列，换行后保留两列并覆盖整行点击区域', () => {
  const row = new PopupMenuRow(); row.iconColumn = true; row.selectionColumn = true;
  const children = [nativeLeaf(16, 16), nativeLeaf(300, 20), nativeLeaf(16, 16), nativeLeaf(0, 0)];
  const size = row.onMeasureSize({}, children, { minWidth: 120, maxWidth: 120 });
  assert.deepEqual(size, { width: 120, height: 160 });
  row.onPlaceChildren(size, children, {});
  assert.deepEqual(children.map(child => child.position.x), [12, 36, 92, 0]);
  assert.equal(children[1].measureResult.width, 48);
  assert.deepEqual(children[3].measureResult, size);
});
test('短菜单项靠左且勾选列靠右，不随文字长短居中移动', () => {
  for (const textWidth of [32, 48, 80]) {
    const row = new PopupMenuRow(); row.iconColumn = false; row.selectionColumn = true;
    const children = [nativeLeaf(textWidth, 20), nativeLeaf(16, 16), nativeLeaf(0, 0)];
    const size = row.onMeasureSize({}, children, { minWidth: 160, maxWidth: 160 });
    row.onPlaceChildren(size, children, {});
    assert.equal(children[0].position.x, 12);
    assert.equal(children[1].position.x, 132);
    assert.equal(children[2].measureResult.width, 160);
    assert.equal(size.height, 44);
  }
});
function nativeRow(naturalWidth) {
  return {
    measureResult: { width: 0, height: 0 }, position: undefined,
    measure({ minWidth, maxWidth }) {
      const width = Math.max(minWidth, Math.min(naturalWidth, maxWidth));
      this.measureResult = { width, height: Math.max(1, Math.ceil(naturalWidth / width)) * 44 };
      return this.measureResult;
    },
    layout(position) { this.position = position; }
  };
}
function measure(rows, maximumWidth = 328, parentWidth = maximumWidth) {
  const menu = new PopupMenu(); menu.maximumWidth = maximumWidth;
  const result = menu.onMeasureSize({}, rows, { maxWidth: parentWidth });
  menu.onPlaceChildren({}, rows, {});
  return result;
}
test('按真实行宽决定菜单宽度，所有点击区域等宽且连续排列', () => {
  const rows = [nativeRow(72), nativeRow(108.2), nativeRow(96)];
  assert.deepEqual(measure(rows), { width: 109, height: 132 });
  assert.deepEqual(rows.map(row => row.measureResult.width), [109, 109, 109]);
  assert.deepEqual(rows.map(row => row.position), [{ x: 0, y: 0 }, { x: 0, y: 44 }, { x: 0, y: 88 }]);
});
test('字体、字号、勾选与图标造成的原生尺寸变化直接参与下一次布局', () => {
  for (const width of [72, 96, 97.4, 144, 196]) {
    assert.deepEqual(measure([nativeRow(width)]), { width: Math.ceil(width), height: 44 });
  }
});
test('达到窗口上限才换行，缩窄父窗口时重新测量高度并保留所有行', () => {
  for (const [limit, parentWidth, width, height] of [[200, 200, 180, 88], [200, 100, 100, 132]]) {
    const rows = [nativeRow(180), nativeRow(72)];
    assert.deepEqual(measure(rows, limit, parentWidth), { width, height });
    assert.equal(rows[1].position.y, height - 44);
  }
});
function fixture(density = 1, id = 1) {
  let width = 360, gate, windowFailed = false;
  const focus = [], actions = [];
  const PopupMenuButton = component('PopupMenuButton', '\n  @Builder', {
    '../ui/Theme': theme,
    '@kit.ArkUI': {
      display: { getDefaultDisplaySync: () => ({ width: width * density }) },
      window: { async getLastWindow() {
        if (gate) await gate;
        if (windowFailed) throw new Error('窗口暂不可用');
        return { getWindowProperties: () => ({ windowRect: { width: width * density } }) };
      } }
    }
  });
  Object.assign(PopupMenuButton.prototype, { getUniqueId: () => id, getUIContext: () => ({
    px2vp: value => value / density, getHostContext: () => ({}),
    getFocusController: () => ({ requestFocus: value => focus.push(value) })
  }) });
  const menu = new PopupMenuButton(); menu.aboutToAppear();
  menu.items = [{ title: '无标签', checked: false, action() { actions.push(menu.visible); } }];
  return { menu, focus, actions, viewport(value) { width = value; }, failWindow() { windowFailed = true; },
    defer() { let resolve; gate = new Promise(done => { resolve = done; }); return resolve; } };
}
test('不同屏幕密度与窗口回退均保留两侧安全边距，极窄窗口不打开菜单', async () => {
  for (const density of [1, 2, 3.5]) {
    const f = fixture(density); await f.menu.toggle(); assert.equal(f.menu.maximumWidth, 328);
    await f.menu.toggle(); f.failWindow(); f.viewport(110);
    await f.menu.toggle(); assert.equal(f.menu.maximumWidth, 78);
    await f.menu.toggle(); f.viewport(32); await f.menu.toggle(); assert.equal(f.menu.visible, false);
  }
});
test('勾选前后使用同一实际行宽，不因选中标记出现而跳变', async () => {
  const f = fixture(); await f.menu.toggle(); const before = measure([nativeRow(96)]);
  await f.menu.toggle(); f.menu.items[0].checked = true; await f.menu.toggle();
  assert.deepEqual(measure([nativeRow(96)]), before);
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
  assert.deepEqual(f.actions, [false]); f.menu.restoreFocus(); assert.deepEqual(f.focus, ['popup_menu_1']);
  f.menu.aboutToDisappear(); f.menu.restoreFocus(); assert.equal(f.focus.length, 1);
});
test('不同入口分别恢复自己的焦点，禁用时不执行菜单动作', async () => {
  const a = fixture(1, 10), b = fixture(1, 20);
  a.menu.restoreFocus(); b.menu.restoreFocus();
  assert.deepEqual(a.focus, ['popup_menu_10']); assert.deepEqual(b.focus, ['popup_menu_20']);
  a.menu.disabled = true; a.menu.activate(a.menu.items[0]); assert.equal(a.actions.length, 0);
});
