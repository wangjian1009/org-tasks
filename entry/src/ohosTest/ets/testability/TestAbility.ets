import { UIAbility } from '@kit.AbilityKit'
import OpenHarmonyTestRunner from '../testrunner/OpenHarmonyTestRunner'
// 仅测试目标引用运行器，主应用不包含测试入口。
export function createRunner(): OpenHarmonyTestRunner { return new OpenHarmonyTestRunner() }
export default class TestAbility extends UIAbility {}
