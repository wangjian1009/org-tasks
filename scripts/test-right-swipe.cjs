// 验证真实组件的回弹完成时序，动画由可手动完成的 UIContext 替身驱动。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('用法: node scripts/test-right-swipe.cjs\n验证右滑阈值、回弹后单次回调、取消、禁用、组件离开和回弹期间的重复手势。');
  process.exit(0);
}
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/components/RightSwipe.ets', 'utf8');
// 使用产品中的状态和方法，去除 ArkUI 声明及渲染 DSL。
const fields = source.slice(source.indexOf('  @State'), source.indexOf('  @Builder\n'))
  .replace('@State ', '');
const methods = source.slice(source.indexOf('  aboutToAppear()'), source.indexOf('  build()'));
const code = ts.transpileModule('class Swipe {' + fields + methods + '} globalThis.Swipe = Swipe;', {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText;
const sandbox = { Curve: { EaseOut: 1 } };
vm.runInNewContext(code, sandbox);
function fixture() {
  const swipe = new sandbox.Swipe();
  const animations = [], calls = [];
  swipe.contentWidth = 360;
  swipe.disabled = false;
  swipe.canActivate = () => true;
  swipe.action = () => calls.push(swipe.dragOffset);
  swipe.getUIContext = () => ({ animateTo(options, update) { animations.push(options); update(); } });
  swipe.aboutToAppear();
  return { swipe, animations, calls, finish() { animations.at(-1).onFinish(); } };
}
test('拖动只移动内容，回弹完成后才执行一次回调', () => {
  const f = fixture();
  f.swipe.drag(96); assert.equal(f.swipe.dragOffset, 96); assert.deepEqual(f.calls, []);
  f.swipe.release(96); assert.equal(f.swipe.dragOffset, 0); assert.deepEqual(f.calls, []);
  f.swipe.release(110); assert.equal(f.animations.length, 1);
  f.finish(); f.finish(); assert.deepEqual(f.calls, [0]);
});
test('短滑、左滑、回拖和取消均不触发，内容可正常归位', () => {
  for (const offset of [-80, 0, 25, 48]) {
    const f = fixture(); f.swipe.drag(100); f.swipe.release(offset);
    if (f.animations.length) f.finish();
    assert.equal(f.swipe.dragOffset, 0); assert.deepEqual(f.calls, []);
  }
  const f = fixture(); f.swipe.drag(120); f.swipe.rebound(false); f.finish();
  assert.deepEqual(f.calls, []);
});
test('回弹期间被禁用或离开页面不会执行过期动作', () => {
  const disabled = fixture(); disabled.swipe.release(100); disabled.swipe.disabled = true; disabled.finish();
  assert.deepEqual(disabled.calls, []);
  const removed = fixture(); removed.swipe.release(100); removed.swipe.aboutToDisappear(); removed.finish();
  assert.deepEqual(removed.calls, []);
});
test('回弹期间不接受新位移，完成后下一次手势可再次执行', () => {
  const f = fixture(); f.swipe.release(100); f.swipe.drag(180);
  assert.equal(f.swipe.dragOffset, 0); f.finish();
  f.swipe.drag(80); assert.equal(f.swipe.dragOffset, 80);
  f.swipe.release(80); f.finish(); assert.deepEqual(f.calls, [0, 0]);
  f.swipe.drag(10000); assert.equal(f.swipe.dragOffset, 270);
});

test('回弹完成前编辑器进入输入或保存状态时丢弃动作', () => {
  const f = fixture(); let available = true;
  f.swipe.canActivate = () => available;
  f.swipe.release(100); available = false; f.finish();
  assert.deepEqual(f.calls, []);
  available = true; f.swipe.release(100); f.finish();
  assert.deepEqual(f.calls, [0]);
});
