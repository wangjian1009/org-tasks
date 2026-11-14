// 验证公共链接控件的系统跳转、地图选择、失败与生命周期隔离。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-links.cjs\n验证链接控件的网页、邮件、电话、地图跳转和失败反馈，以及异步生命周期隔离。');
  process.exit(0);
}
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(sdk, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const filename = 'entry/src/main/ets/components/LinkView.ets';
const source = fs.readFileSync(filename, 'utf8');
const behavior = source.slice(0, source.indexOf('  @Builder\n')) + '}\n' + source.slice(source.indexOf('interface GeoCoordinates'));
const code = ts.transpileModule(behavior.replace(/@Component\n|@State |@Prop |@BuilderParam /g, '')
  .replace('export struct LinkView', 'export class LinkView'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function fixture() {
  const calls = [], messages = [];
  let open = async () => {}, start = async () => {}, search = async () => {};
  const module = { exports: {} };
  const context = {
    async openLink(...args) { calls.push(['web', ...args]); await open(...args); },
    async startAbility(...args) { calls.push(['ability', ...args]); await start(...args); }
  };
  const mocks = {
    '@kit.MapKit': { petalMaps: { async openMapTextSearch(...args) { calls.push(['search', ...args]); await search(...args); } } },
    '../ui/Theme': { UiSize: { taskFont: 16 } }
  };
  vm.runInThisContext('(function(require,module,exports,FontWeight,$r){' + code + '\n})', { filename })(
    name => { assert.ok(name in mocks, name); return mocks[name]; }, module, module.exports,
    { Normal: 400 }, name => ({ name }));
  const view = new module.exports.LinkView();
  view.getUIContext = () => ({ getHostContext: () => context,
    getPromptAction: () => ({ showToast: ({message}) => messages.push(message) }) });
  view.aboutToAppear();
  return { view, calls, messages, context,
    open: value => { open = value; }, start: value => { start = value; }, search: value => { search = value; } };
}

test('标题和 Web 适配共用同一跳转控制器，网页交给系统，内嵌资源不触发跳转', async () => {
  const f = fixture();
  assert.equal(f.view.links.navigate('about:blank', true), false);
  assert.equal(f.view.links.navigate('data:text/html,hello', true), false);
  assert.equal(f.view.links.navigate('#chapter', true), false);
  assert.equal(f.view.links.navigate('https://example.com/frame', false), true);
  assert.deepEqual(f.calls, []);
  assert.equal(f.view.links.navigate('https://example.com/path?x=1', true), true);
  await Promise.resolve();
  assert.deepEqual(f.calls, [['web', 'https://example.com/path?x=1', { appLinkingOnly: false }]]);
});

test('邮件和电话使用 viewData，链接行为不调用标题区域激活操作', async () => {
  const f = fixture();
  f.view.activate = () => { assert.fail('链接点击不应激活标题区域'); };
  for (const href of ['mailto:team@example.com', 'tel:12345']) await f.view.links.open(href);
  assert.deepEqual(f.calls, ['mailto:team@example.com', 'tel:12345'].map(uri =>
    ['ability', { action: 'ohos.want.action.viewData', uri }]));
});

test('文字地址先展示地图选择，不支持项保留面板，花瓣使用文字搜索接口', async () => {
  const f = fixture();
  await f.view.links.open('addr:%E5%8C%97%E4%BA%AC');
  assert.equal(f.view.chooserVisible, true);
  assert.equal(f.view.mapChoices[0].contextLabel, '搜索：北京');
  assert.equal(f.view.mapChoices[0].supported, false);
  await f.view.selectMapApp(f.view.mapChoices[0]);
  assert.equal(f.view.chooserVisible, true);
  assert.match(f.messages.at(-1), /高德地图暂不支持地址搜索/);
  assert.deepEqual(f.calls, []);
  await f.view.selectMapApp(f.view.mapChoices[1]);
  assert.equal(f.view.chooserVisible, false);
  assert.deepEqual(f.calls, [['search', f.context, { destinationName: '北京' }]]);
});

test('坐标地址可选择高德或花瓣，地图 URI 与应用身份正确', async () => {
  const f = fixture();
  for (let index=0; index<2; index++) {
    await f.view.links.open('geo:39.9042,116.4074');
    assert.ok(f.view.mapChoices.every(choice => choice.supported));
    await f.view.selectMapApp(f.view.mapChoices[index]);
  }
  assert.equal(f.calls[0][1].bundleName, 'com.amap.hmapp');
  assert.match(f.calls[0][1].uri, /dlat=39.9042&dlon=116.4074/);
  assert.equal(f.calls[1][1].bundleName, 'com.huawei.hmos.maps.app');
  assert.equal(f.calls[1][1].uri, 'geo:39.9042,116.4074');
});

test('系统打开失败显示反馈，地图选择失败保留面板以便重试', async () => {
  const f = fixture();
  f.open(async () => { throw new Error('系统打开失败'); });
  await f.view.links.open('https://example.com/');
  assert.match(f.messages.at(-1), /无法打开链接/);
  await f.view.links.open('geo:0,0?q=Beijing');
  f.search(async () => { throw new Error('地图未安装'); });
  await f.view.selectMapApp(f.view.mapChoices[1]);
  assert.equal(f.view.chooserVisible, true);
  assert.equal(f.view.launching, false);
  assert.match(f.messages.at(-1), /无法打开地图/);
});

test('无效地址与不支持的协议只提示，不启动应用', async () => {
  const f = fixture();
  for (const href of ['geo:0,0', 'addr:%invalid', 'javascript:alert(1)', 'file:/secret']) await f.view.links.open(href);
  assert.equal(f.messages.length, 4);
  assert.deepEqual(f.calls, []);
});

test('禁用链接与重复点击不启动额外操作，离开后的失败不回写新生命周期', async () => {
  const f = fixture();
  f.view.openLinks = false;
  await f.view.links.open('https://example.com/');assert.deepEqual(f.calls, []);
  f.view.openLinks = true;
  let reject;
  f.open(() => new Promise((_resolve, fail) => { reject = fail; }));
  const pending = f.view.links.open('https://example.com/');
  await f.view.links.open('https://example.com/second');
  assert.equal(f.calls.length, 1);
  f.view.aboutToDisappear();f.view.aboutToAppear();
  reject(new Error('旧页面请求失败'));await pending;
  assert.deepEqual(f.messages, []);assert.equal(f.view.launching, false);
});
