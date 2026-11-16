const assert = require('node:assert/strict');
const { test } = require('node:test');
if (process.argv.includes('-h') || process.argv.includes('--help')) {
  console.log('用法: node scripts/test-entry-navigation.cjs\n验证卡片目标路径、分享入口和无效参数拒绝。'); process.exit(0);
}
const {entryNavigation} = require('./helpers/page-navigator.cjs').entryNavigationModule;
const root = { url:'pages/TaskOverview', params:{view:'memo'} };
const parse = path => entryNavigation({parameters:{navigation:JSON.stringify(path)}});
test('卡片完整路径直接表达列表、新建与记录编辑目标', () => {
  assert.equal(parse({pages:[root]}).current.url,'pages/TaskOverview');
  for (const params of [{create:true},{memoId:'m'}]) {
    const path=parse({pages:[root,{url:'pages/MemoEdit',params}]});
    assert.equal(path.depth,2);assert.deepEqual(path.current.params,params);assert.equal(path.parent().current.params.view,'memo');
  }
});
test('备忘入口只接受完整路径，旧卡片参数不再触发导航', () => {
  for (const parameters of [{page:'memo'}, {page:'memo',memoAction:'create'},
    {page:'memo',memoAction:'edit',memoId:'m'}]) {
    assert.equal(entryNavigation({parameters}), undefined);
  }
  assert.equal(entryNavigation({parameters:{page:'inbox'}}).current.url,'pages/Inbox');
});
test('无效外部路径不修改已有界面，未知字段和互斥目标拒绝', () => {
  for(const value of [null,{},[],{pages:[]},{pages:[root,{url:'pages/Capture'}]},
    {pages:[root,{url:'pages/MemoEdit',params:{create:true,memoId:'m'}}]},
    {pages:[root,{url:'pages/MemoEdit',params:{memoId:''}}]},
    {pages:[root,{url:'pages/MemoEdit',params:{task:{id:'m'}}}]},
    {pages:[{url:'pages/TaskOverview',params:{view:'today'}}]},
    {pages:[root],extra:true}]) assert.equal(parse(value),undefined,JSON.stringify(value));
  assert.equal(entryNavigation({parameters:{navigation:'bad'}}),undefined);
});
