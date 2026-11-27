// 模块级 hvigorfile
import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { resolve } from 'node:path';

const prepareHelp = require('../scripts/prepare-help.cjs');
prepareHelp(resolve(__dirname, '../app-docs'), resolve(__dirname, 'src/main/resources/rawfile/app-docs'),
  resolve(__dirname, '../AppScope/app.json5'));

export default {
  system: hapTasks,
  plugins: []
}
