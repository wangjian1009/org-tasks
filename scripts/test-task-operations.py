#!/usr/bin/env python3
"""通过真实 CLI 执行按测试目的组织的任务操作黑盒用例。"""
import argparse
from datetime import datetime, timedelta
import difflib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
CASES = ROOT / 'core/tests/task_operations_cases'


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'target/debug/org-tasks', help='已构建的 Core CLI')
    parser.add_argument('--group', action='append', default=[], help='只执行指定测试组，可重复')
    parser.add_argument('--case', action='append', default=[], help='只执行 group/case，可重复')
    parser.add_argument('--list', action='store_true', help='列出选中的测试用例')
    parser.add_argument('--keep-failed', action='store_true', help='保留失败用例的临时目录')
    return parser.parse_args()


def files_under(root, control=False):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob('*')
            if p.is_file() and p.name != '.transaction.lock'
            and (control or '.sync' not in p.relative_to(root).parts)}


def bind(value, ids):
    if isinstance(value, dict):
        return {k: (ids.get(v, v) if k == 'repoId' and isinstance(v, str) else
                    [ids.get(x, x) for x in v] if k == 'queueRepoIds' else bind(v, ids))
                for k, v in value.items()}
    if isinstance(value, list):
        return [bind(item, ids) for item in value]
    return value


def assert_file_matches(name, expected, actual, started, ended):
    tokens = list(re.finditer(rb'\{\{(TIMESTAMP|DATE\+([0-9]+)d)\}\}', expected))
    if tokens:
        parts, cursor = [], 0
        for token in tokens:
            parts.append(re.escape(expected[cursor:token.start()]))
            parts.append(rb'(\[\d{4}-\d{2}-\d{2} [A-Za-z]{3} \d{2}:\d{2}\])'
                         if token[1] == b'TIMESTAMP' else rb'(\d{4}-\d{2}-\d{2} [A-Za-z]{3})')
            cursor = token.end()
        parts.append(re.escape(expected[cursor:]))
        match = re.fullmatch(b''.join(parts), actual)
        assert match, f'{name} 自动日期、时间戳或其他字节与预期不符: {actual!r}'
        for token, captured in zip(tokens, match.groups()):
            if token[1] == b'TIMESTAMP':
                value = datetime.strptime(captured.decode(), '[%Y-%m-%d %a %H:%M]')
                assert started <= value <= ended, f'{name} 时间戳不是本次操作时间: {captured!r}'
            else:
                value = datetime.strptime(captured.decode(), '%Y-%m-%d %a')
                shift = timedelta(days=int(token[2]))
                assert captured.decode() == value.strftime('%Y-%m-%d %a'), f'{name} 日期与星期不一致: {captured!r}'
                assert started.date() + shift <= value.date() <= ended.date() + shift, f'{name} 日期不是本次操作日期加指定天数: {captured!r}'
        return
    if expected != actual:
        diff = ''.join(difflib.unified_diff(expected.decode().splitlines(True), actual.decode().splitlines(True), fromfile='expected/' + name, tofile='actual/' + name))
        raise AssertionError(f'{name} 字节不一致\n{diff or repr((expected, actual))}')


def run_case(binary, case, keep_failed):
    started = datetime.now().replace(second=0, microsecond=0)
    temp = Path(tempfile.mkdtemp(prefix='org-task-case-'))
    failed = True
    try:
        spec = json.loads((case / 'case.json').read_text())
        work = temp / 'work'
        shutil.copytree(case / 'input', work)
        repos = sorted(p for p in work.iterdir() if p.is_dir())
        assert repos, 'input 中必须至少包含一个仓库目录'
        ids = {repo.name: str(uuid.uuid5(uuid.NAMESPACE_URL, 'org-tasks-tests/' + repo.name)) for repo in repos}
        # 初始化是测试准备；之后以全部磁盘字节为失败基准。
        for repo in repos:
            (repo / '.sync/history').mkdir(parents=True, exist_ok=True)
            (repo / '.sync/id').write_text(ids[repo.name] + '\n')
            initialized = subprocess.run([str(binary), '--repo-dir', str(repo), 'task', 'paths'],
                                         text=True, capture_output=True, timeout=30)
            assert initialized.returncode == 0, initialized.stderr
        before = files_under(work, control=True)
        operation_files = sorted((case / 'operations').glob('*.json'))
        assert operation_files, 'operations 中必须至少定义一个操作组'
        versions = {}
        for operation_file in operation_files:
            group = bind(json.loads(operation_file.read_text()), ids)
            request = temp / operation_file.name
            request.write_text(json.dumps(group, ensure_ascii=False))
            command = [str(binary), '--repo-dir', str(repos[0]), 'task', 'apply', '--operations', str(request)]
            for repo in repos[1:]:
                command += ['--repository', str(repo)]
            completed = subprocess.run(command, text=True, capture_output=True, timeout=30)
            if spec.get('error'):
                assert completed.returncode != 0, '预期失败却执行成功'
                assert spec['error'] in completed.stderr, completed.stderr
                assert files_under(work, control=True) == before, '失败操作修改了磁盘或留下临时文件/意图'
            else:
                assert completed.returncode == 0, completed.stderr
                output = json.loads(completed.stdout)
                assert len(output['history']['entries']) == 1, '成功操作没有登记一次回退历史'
                fallback = output['history']['entries'][0]['fallbackGroup']
                for snapshot in fallback['files']:
                    name = next(k for k, v in ids.items() if v == snapshot['repoId'])
                    relative = name + '/' + snapshot['file']
                    assert (snapshot['before'].encode() if snapshot['before'] is not None else None) == before.get(relative), '回退快照与原始输入字节不符'
                    assert snapshot['after'].encode() == (work / relative).read_bytes(), '成功快照与实际文件不符'
                versions = {(node['fullPath']['repoId'], node['fullPath']['file']): node['fileVersion']
                            for node in output['nodes'] if node['kind'] == 'file'}
                before = files_under(work, control=True)
        expected = files_under(case / 'output')
        actual = files_under(work)
        assert expected.keys() == actual.keys(), f'文件清单不同：expected={sorted(expected)}, actual={sorted(actual)}'
        ended = datetime.now().replace(second=0, microsecond=0)
        for name in expected:
            assert_file_matches(name, expected[name], actual[name], started, ended)
        for repo in repos:
            count = len(list((repo / '.sync/outbox').glob('*.json')))
            assert count == spec.get('outbox', {}).get(repo.name, 0), f'{repo.name} 上传意图数量不符: {count}'
            for intent_file in (repo / '.sync/outbox').glob('*.json'):
                intent = json.loads(intent_file.read_text())
                assert set(intent) == {'relative_path', 'content_hash'}, '意图包含未约定字段'
                assert intent['content_hash'] == versions[(ids[repo.name], intent['relative_path'])], '意图不是文件的最终版本'

        if spec.get('inspect'):
            before_inspect = files_under(work, control=True)
            completed = subprocess.run([str(binary), '--repo-dir', str(repos[0]), 'task', 'paths'], text=True, capture_output=True, timeout=30)
            assert completed.returncode == 0, completed.stderr
            nodes = json.loads(completed.stdout)
            for expected_node in spec['inspect']:
                candidates = [n for n in nodes if n['fullPath']['titles'] == expected_node['titles']
                              and n['fullPath']['occurrence'] == expected_node.get('occurrence', 1)]
                assert len(candidates) == 1, f'路径匹配数量错误: {expected_node}'
                node = candidates[0]
                assert (node['taskId'] is not None) == expected_node['task'], f'taskId 可空性错误: {node}'
                if node['taskId'] is not None:
                    identity = json.loads(node['taskId'])
                    assert identity[2] == expected_node.get('identityTitles', expected_node['titles']), f'身份祖先错误: {identity}'
            assert files_under(work, control=True) == before_inspect, '重新读取生成了日志或修改了文件及控制数据'
        assert not any(p.name.endswith(('.tmp', '.rollback')) for p in work.rglob('*')), '留下提交临时文件'
        failed = False
    finally:
        if failed and keep_failed:
            print(f'  保留失败现场: {temp}', file=sys.stderr)
        else:
            shutil.rmtree(temp)


def main():
    args = arguments()
    cases = sorted(p.parent for p in CASES.glob('*/*/case.json'))
    cases = [p for p in cases if (not args.group or p.parent.name in args.group)
             and (not args.case or p.relative_to(CASES).as_posix() in args.case)]
    if not cases:
        raise SystemExit('未找到匹配用例')
    if args.list:
        for case in cases:
            print(case.relative_to(CASES).as_posix(), json.loads((case / 'case.json').read_text())['purpose'])
        return
    if not args.binary.is_file():
        raise SystemExit(f'CLI 不存在: {args.binary}，请先构建 org-tasks')
    failures = 0
    for case in cases:
        name = case.relative_to(CASES).as_posix()
        try:
            run_case(args.binary.resolve(), case, args.keep_failed)
            print(f'PASS {name}')
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures += 1
            print(f'FAIL {name}: {error}', file=sys.stderr)
    print(f'{len(cases) - failures}/{len(cases)} 用例通过')
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
