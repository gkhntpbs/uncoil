from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class VersionTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / '.build-cache' / 'version-tests'
        cache.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        (self.repo / 'scripts').mkdir()
        shutil.copy(ROOT / 'scripts/version.sh', self.repo / 'scripts/version.sh')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Version Tests')
        self.git('config', 'user.email', 'tests@example.invalid')
        self.write_version('0.2.0', '2')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, check=True, capture_output=True, text=True)

    def write_version(self, version, build):
        (self.repo / 'project.yml').write_text(f'  MARKETING_VERSION: "{version}"\n  CURRENT_PROJECT_VERSION: "{build}"\n')

    def tag(self, name, version, build):
        self.write_version(version, build)
        self.git('add', 'project.yml')
        self.git('commit', '-qm', name, '--allow-empty')
        self.git('tag', '-a', name, '-m', name)

    def run_version(self, *args):
        return subprocess.run(['bash', 'scripts/version.sh', *args], cwd=self.repo, capture_output=True, text=True)

    def assert_build(self, expected):
        self.assertIn(f'CURRENT_PROJECT_VERSION: "{expected}"', (self.repo / 'project.yml').read_text())

    def test_initial_build_increments(self):
        self.assertEqual(self.run_version('--bump-build').returncode, 0)
        self.assert_build(3)

    def test_stable_release_after_edge_uses_global_maximum(self):
        self.tag('v0.2.0-edge.12', '0.2.0', '12')
        self.write_version('0.1.0', '1')
        self.assertEqual(self.run_version('--set', '0.2.0').returncode, 0)
        self.assert_build(13)

    def test_build_order_does_not_follow_marketing_version(self):
        self.tag('v0.9.0', '0.9.0', '8')
        self.tag('v0.3.0-edge.19', '0.3.0', '19')
        self.write_version('0.2.0', '2')
        self.assertEqual(self.run_version('--bump-build').returncode, 0)
        self.assert_build(20)

    def test_current_build_ahead_of_tags(self):
        self.tag('v0.1.0', '0.1.0', '1')
        self.write_version('0.2.0', '7')
        self.assertEqual(self.run_version('--bump-build').returncode, 0)
        self.assert_build(8)

    def test_backup_and_unrelated_tags_are_ignored(self):
        self.tag('backup/pre-edge', '0.2.0', '999')
        self.git('tag', 'version-not-a-release')
        self.write_version('0.2.0', '2')
        self.assertEqual(self.run_version('--bump-build').returncode, 0)
        self.assert_build(3)

    def test_invalid_release_build_does_not_mutate_version(self):
        self.tag('v0.2.0-edge.12', '0.2.0', 'invalid')
        self.write_version('0.2.0', '2')
        before = (self.repo / 'project.yml').read_bytes()
        result = self.run_version('--set', '0.3.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid build number', result.stderr)
        self.assertEqual(before, (self.repo / 'project.yml').read_bytes())


if __name__ == '__main__':
    unittest.main()
