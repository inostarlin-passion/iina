"""Ensure failed builds cannot leave a previous successful test log as current evidence."""
import contextlib
import io
import pathlib
import tempfile
import types
import unittest
from unittest.mock import patch

from hosted_driver import run


class HostedDriverTests(unittest.TestCase):
    def test_build_failure_invalidates_previous_execution_log(self):
        with tempfile.TemporaryDirectory(prefix='iina-hosted-driver-') as directory:
            root = pathlib.Path(directory)
            output = root / 'build/fullscreen-regression'
            output.mkdir(parents=True)
            log = output / 'hosted.log'
            log.write_text('OLD SUCCESS: every test passed\n')
            with patch('hosted_driver.subprocess.run', return_value=types.SimpleNamespace(returncode=65)) as build:
                with contextlib.redirect_stdout(io.StringIO()):
                    result = run(root, root / 'result.xcresult')
            self.assertEqual(result, 65)
            self.assertEqual(build.call_count, 1)
            self.assertNotIn('OLD SUCCESS', log.read_text())
            self.assertIn('not reached test execution', log.read_text())


if __name__ == '__main__':
    unittest.main()
