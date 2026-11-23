// 在宿主测试中执行共享确认逻辑，仅替换 ArkUI 上下文与主题颜色。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const filename = path.resolve(__dirname, '../../entry/src/main/ets/components/controls/DangerousConfirmation.ets');
const { outputText } = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
});
vm.runInThisContext('(function(require,exports){' + outputText + '\n})', { filename })(name => {
  if (name === '../../ui/Theme') return { UiColor: { error: 'red' } };
  throw new Error('缺少替身：' + name);
}, module.exports);
