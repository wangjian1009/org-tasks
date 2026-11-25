// 在 Node 中运行 ArkTS 界面测试时，使用实际的随包资源替代 HarmonyOS 资源管理器。
const { existsSync, readFileSync } = require('node:fs');
const path = require('node:path');

function readResources(locale) {
  const catalog = JSON.parse(readFileSync(
    path.join(__dirname, '../../entry/src/main/resources', locale, 'element/string.json'), 'utf8'));
  return Object.fromEntries(catalog.string.map(({ name, value }) => [name, value]));
}

const chinese = readResources('base');
const tablePath = path.join(__dirname, '../../entry/build/default/intermediates/res/default/ResourceTable.txt');
const stringsById = new Map();
if (existsSync(tablePath)) {
  for (const match of readFileSync(tablePath, 'utf8').matchAll(/^string (\S+) (0x[\da-f]+)$/gmi)) {
    stringsById.set(Number(match[2]), match[1]);
  }
}

function transpileFixture(ts, source, options) {
  if (!source.includes('app.string.') && !source.includes('LocalizedText') && !source.includes('10003') &&
      !/\blocalized(?:Date|Text)\(/.test(source)) {
    return ts.transpileModule(source, options);
  }

  const localized = source
    .replace(/^import \{ [^\n]* \} from '[^'\n]*\/LocalizedText'\r?\n/gm, '')
    .replace(/\$r\('app\.string\.([a-zA-Z0-9_]+)'\)/g, (_, key) => {
      if (!Object.hasOwn(chinese, key)) throw new Error(`缺少字符串资源：${key}`);
      return JSON.stringify(chinese[key]);
    })
    .replace(/\{\s*["']?id["']?:\s*(\d+),\s*["']?type["']?:\s*10003,\s*params:\s*\[\],\s*["']?bundleName["']?:\s*"com\.example\.orgtasks",\s*["']?moduleName["']?:\s*"entry"\s*\}/g, (resource, id) => {
      const key = stringsById.get(Number(id));
      return Object.hasOwn(chinese, key) ? JSON.stringify(chinese[key]) : resource;
    });

  return ts.transpileModule([
    'const localizedText = (value: string, ...args: string[]): string => value.replace(/%(\\d+)\\$s/g, (_, index) => args[Number(index) - 1]);',
    "const displayLocale = (): string => 'zh-CN';",
    "const localizedDate = (date: Date, options: Intl.DateTimeFormatOptions): string => Number.isFinite(date.getTime()) ? new Intl.DateTimeFormat(displayLocale(), options).format(date) : '';",
    localized
  ].join('\n'), options);
}

module.exports = { readResources, transpileFixture };
