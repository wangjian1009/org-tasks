"""验证任务操作用例的日期边界与原文字节判定。"""
from datetime import datetime
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('task_cases', Path(__file__).with_name('test-task-operations.py'))
task_cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(task_cases)


class OutputChecks(unittest.TestCase):
    def check_output(self, expected, actual, started=None, ended=None):
        task_cases.assert_file_matches(
            'tasks.org', expected.encode(), actual.encode(),
            started or datetime(2026, 11, 11, 12, 34),
            ended or datetime(2026, 11, 11, 12, 35))

    def test_relative_date_and_timestamp_match_without_rewriting_old_logs(self):
        expected = 'SCHEDULED: <{{DATE+28d}} .+4w/5w>\n:LAST_REPEAT: {{TIMESTAMP}}\n- State "DONE" [2020-01-01 Wed 09:00]\n'
        actual = 'SCHEDULED: <2026-12-09 Wed .+4w/5w>\n:LAST_REPEAT: [2026-11-11 Wed 12:34]\n- State "DONE" [2020-01-01 Wed 09:00]\n'
        self.check_output(expected, actual)
        with self.assertRaises(AssertionError):
            self.check_output(expected, actual.replace('2020-01-01', '2020-01-02'))

    def test_midnight_accepts_only_dates_from_the_operation_window(self):
        started = datetime(2026, 11, 11, 23, 59)
        ended = datetime(2026, 11, 12, 0, 1)
        for value in ['2026-12-09 Wed', '2026-12-10 Thu']:
            self.check_output('{{DATE+28d}}', value, started, ended)
        with self.assertRaises(AssertionError):
            self.check_output('{{DATE+28d}}', '2026-12-11 Fri', started, ended)

    def test_incorrect_repeat_date_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check_output('{{DATE+28d}}', '2026-12-08 Tue')

    def test_incorrect_weekday_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check_output('{{DATE+28d}}', '2026-12-09 Thu')

    def test_outdated_generated_timestamp_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check_output('{{TIMESTAMP}}', '[2026-11-10 Tue 12:34]')

    def test_extra_log_and_changed_line_endings_are_rejected(self):
        expected = ':LAST_REPEAT: {{TIMESTAMP}}\r\n'
        actual = ':LAST_REPEAT: [2026-11-11 Wed 12:34]\r\n'
        self.check_output(expected, actual)
        with self.assertRaises(AssertionError):
            self.check_output(expected, actual + '- State "DONE"\r\n')
        with self.assertRaises(AssertionError):
            self.check_output(expected, actual.replace('\r\n', '\n'))


if __name__ == '__main__':
    unittest.main()
