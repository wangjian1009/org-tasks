#!/usr/bin/env python3
"""在隔离模拟器清空页面缓存，指定首屏并采集读取状态与完成状态。"""
import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request

HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'
FILES = '/data/app/el2/100/base/com.example.orgtasks/haps/entry/files'
PAGES = {
    'Inbox': ('收件箱', '正在读取收件箱', 'QA编辑'),
    'Today': ('今天', '正在读取任务', 'QA编辑'),
    'Planned': ('计划', '正在读取任务', 'QA计划'),
    'Waiting': ('等待', '正在读取任务', '没有符合条件的任务'),
    'Anytime': ('随时', '正在读取任务', 'QA随时'),
    'Someday': ('某天', '正在读取任务', 'QA某天'),
    'Memo': ('备忘', '正在读取任务', 'QA备忘'),
    'Logbook': ('日志簿', '正在读取任务', 'QA日志'),
    'Trash': ('废纸篓', '正在读取废纸篓', '废纸篓为空'),
    'Files': ('笔记本', '正在读取笔记本', '普通文件验收'),
}


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='独立模拟器的 HDC 连接地址，仅允许回环 TCP 设备')
    parser.add_argument('--hdc', default=HDC, help='HDC 可执行文件')
    parser.add_argument('--port', type=int, default=21887, help='临时转发的宿主端口')
    parser.add_argument('--page', choices=PAGES, action='append', help='指定待验收页面，可重复；默认全部')
    parser.add_argument('--mode', choices=['natural', 'controlled', 'all'], default='all',
                        help='自然冷启动、测试包持有真实仓库锁的受控等待，或两者均执行')
    parser.add_argument('--output', type=Path, default=Path('output/qa/loading-states'), help='布局、截图与结果目录')
    return parser.parse_args()


class Verification:
    def __init__(self, args):
        self.args = args
        self.args.output.mkdir(parents=True, exist_ok=True)
        self.results = []
        self.remote = '/data/local/tmp/org-tasks-loading-state'

    def hdc(self, *args):
        return subprocess.check_output([self.args.hdc, '-t', self.args.device, *args],
                                       text=True, stderr=subprocess.STDOUT, timeout=25)

    def navigation(self):
        with urllib.request.urlopen(f'http://127.0.0.1:{self.args.port}/api/v1/ui/navigation', timeout=1) as result:
            return json.load(result)

    def layout(self, directory, stage):
        remote = self.remote + '.json'
        self.hdc('shell', 'uitest', 'dumpLayout', '-p', remote)
        target = directory / (stage + '.json')
        self.hdc('file', 'recv', remote, str(target))
        texts = []

        def visit(node):
            if node.get('attributes', {}).get('text'):
                texts.append(node['attributes']['text'])
            for child in node.get('children', []):
                visit(child)
        visit(json.loads(target.read_text()))
        return texts

    def screenshot(self, directory, stage):
        remote = self.remote + '.png'
        self.hdc('shell', 'uitest', 'screenCap', '-p', remote)
        self.hdc('file', 'recv', remote, str(directory / (stage + '.png')))

    def verify(self, page, mode):
        title, loading, expected = PAGES[page]
        directory = self.args.output / f'{mode}-{page}'
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'result.json').unlink(missing_ok=True)
        self.hdc('shell', 'aa', 'force-stop', 'com.example.orgtasks')
        self.hdc('shell', 'rm', '-rf', FILES + '/page-data')
        after_clear = self.hdc('shell', 'ls', '-ld', FILES + '/page-data')
        if 'No such file' not in after_clear:
            raise AssertionError('页面缓存未确认清空：' + after_clear)
        (directory / 'cache-before.txt').write_text(after_clear)
        runner = None
        log = (directory / 'launch.txt').open('w')
        try:
            started = time.monotonic()
            if mode == 'controlled':
                runner = subprocess.Popen([self.args.hdc, '-t', self.args.device, 'shell', 'aa', 'test',
                    '-b', 'com.example.orgtasks', '-m', 'entry_test', '-s', 'unittest', 'OpenHarmonyTestRunner',
                    '-s', 'loadingPage', page, '-w', '20'], stdout=log, stderr=subprocess.STDOUT)
            else:
                log.write(self.hdc('shell', 'aa', 'start', '-b', 'com.example.orgtasks', '-a', 'EntryAbility',
                    '--pb', 'httpApiEnabled', 'true', '--ps', 'httpApiPage', 'pages/' + page))
                log.flush()
            observed = False
            first = self.layout(directory, 'first')
            texts = first
            # 自然加载可能在首个采样前完成；受控等待必须实际采集到目标页面的读取状态。
            deadline = started + (6 if mode == 'controlled' else 15)
            while mode == 'controlled' and not (title in texts and loading in texts):
                if time.monotonic() >= deadline:
                    raise AssertionError(f'{page} 未采集到受控读取状态：{texts}')
                texts = self.layout(directory, 'waiting')
            if title in texts and loading in texts:
                observed = True
                (directory / 'loading-texts.json').write_text(json.dumps(texts, ensure_ascii=False, indent=2))
                self.screenshot(directory, 'loading')
            deadline = time.monotonic() + 15
            while True:
                texts = self.layout(directory, 'ready')
                try:
                    path = self.navigation()
                except (urllib.error.URLError, ConnectionError, TimeoutError):
                    path = None
                if path == {'pages': [{'url': 'pages/' + page}]} and title in texts and loading not in texts and expected in texts:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError(f'{page} 未退出读取状态或首屏错误：{path}, {texts}')
            self.screenshot(directory, 'ready')
            cache = directory / 'app.json'
            deadline = time.monotonic() + 5
            while True:
                cache.unlink(missing_ok=True)
                self.hdc('file', 'recv', FILES + '/page-data/v1/app.json', str(cache))
                if cache.exists():
                    value = json.loads(cache.read_text())
                    versions = {item['name']: item['version'] for item in value['dataSets']}
                    if versions and min(versions.values()) >= 1:
                        break
                if time.monotonic() >= deadline:
                    raise AssertionError('首次查询完成后未保存确认缓存')
                time.sleep(.1)
            result = {'page': page, 'mode': mode, 'cacheCleared': True, 'firstTexts': first,
                      'loadingObserved': observed, 'navigation': path, 'readyTexts': texts,
                      'versions': versions, 'elapsedSeconds': round(time.monotonic() - started, 3)}
            (directory / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
            self.results.append(result)
            print(json.dumps({key: result[key] for key in ['page', 'mode', 'cacheCleared', 'loadingObserved', 'elapsedSeconds']}, ensure_ascii=False), flush=True)
            if runner:
                runner.wait(timeout=12)
                if 'TestFinished-ResultCode: 0' not in (directory / 'launch.txt').read_text():
                    raise AssertionError('模拟器测试运行器未成功结束')
        finally:
            log.close()
            if runner and runner.poll() is None:
                self.hdc('shell', 'aa', 'force-stop', 'com.example.orgtasks')
                runner.wait(timeout=5)

    def run(self):
        if not self.args.device.startswith('127.0.0.1:'):
            raise ValueError('验收只允许独立模拟器，不操作真机')
        if 'notification-data-qa-' not in self.hdc('shell', 'ls', FILES):
            raise ValueError('未找到隔离的模拟器验收仓库')
        forward = self.hdc('fport', f'tcp:{self.args.port}', 'tcp:8787')
        if 'OK' not in forward:
            raise ValueError('无法建立验收端口转发：' + forward)
        try:
            modes = ['natural', 'controlled'] if self.args.mode == 'all' else [self.args.mode]
            for mode in modes:
                for page in self.args.page or PAGES:
                    self.verify(page, mode)
        finally:
            self.hdc('shell', 'aa', 'force-stop', 'com.example.orgtasks')
            self.hdc('fport', 'rm', f'tcp:{self.args.port}', 'tcp:8787')
            (self.args.output / 'results.json').write_text(json.dumps(self.results, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    Verification(arguments()).run()
