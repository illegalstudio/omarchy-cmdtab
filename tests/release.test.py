#!/usr/bin/env python3
"""Exercise release publication against disposable local Git repositories."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.storage = tempfile.TemporaryDirectory(prefix=".cmdtab-release-", dir=ROOT)

    @classmethod
    def tearDownClass(cls):
        cls.storage.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix="case-", dir=self.storage.name))
        self.addCleanup(shutil.rmtree, self.case)
        self.work = self.case / "work"
        self.remote = self.case / "origin.git"
        self.work.mkdir()
        commands = self.case / "bin"
        commands.mkdir()
        omarchy = commands / "omarchy"
        omarchy.write_text("#!/bin/sh\nexit 0\n")
        omarchy.chmod(0o755)
        self.check_log = self.case / "checks.log"
        self.env = {
            **os.environ,
            "PATH": str(commands) + os.pathsep + os.environ["PATH"],
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "RELEASE_TEST_CHECK_LOG": str(self.check_log),
        }
        self.git("init", "--initial-branch=main")
        for key, value in {
            "user.name": "Release test",
            "user.email": "release@example.invalid",
            "commit.gpgsign": "false",
            "tag.gpgsign": "false",
        }.items():
            self.git("config", key, value)
        self.git("init", "--bare", str(self.remote))
        (self.work / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/release.sh", self.work / "scripts/release.sh")
        (self.work / "manifest.json").write_text('{"version": "0.1.0"}\n')
        (self.work / "Makefile").write_text(
            "check:\n"
            '\t@printf "checked\\n" >> "$(RELEASE_TEST_CHECK_LOG)"\n'
            '\t@test "$(RELEASE_TEST_FAIL_CHECK)" != "1"\n'
        )
        self.git("add", ".")
        self.git("commit", "-m", "Initial fixture")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "--set-upstream", "origin", "main")
        self.initial = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *arguments, check=True):
        return subprocess.run(
            ["git", *arguments], cwd=self.work, env=self.env,
            text=True, capture_output=True, check=check, timeout=15,
        )

    def origin(self, *arguments, check=True):
        return self.git("--git-dir=" + str(self.remote), *arguments, check=check)

    def release(self, answer, **environment):
        return subprocess.run(
            ["bash", "scripts/release.sh"], cwd=self.work,
            env={**self.env, **environment}, input=answer,
            text=True, capture_output=True, timeout=20,
        )

    def assert_no_publication(self):
        self.assertEqual(self.origin("rev-parse", "refs/heads/main").stdout.strip(), self.initial)
        self.assertEqual(self.origin("tag", "--list").stdout, "")

    def test_first_release_tags_current_manifest_without_an_extra_commit(self):
        result = self.release("\ny\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("project:          Omarchy Cmdtab", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial)
        self.assertEqual(self.origin("cat-file", "-t", "refs/tags/v0.1.0").stdout.strip(), "tag")
        self.assertTrue(self.check_log.exists())
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_next_patch_uses_the_highest_local_or_remote_semantic_tag(self):
        self.git("tag", "v0.1.8")
        self.origin("tag", "v0.1.9", self.initial)
        self.origin("tag", "v99.0.0-beta", self.initial)
        result = self.release("\ny\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Proposed release: v0.1.10", result.stdout)
        self.assertEqual(json.loads((self.work / "manifest.json").read_text())["version"], "0.1.10")
        self.assertEqual(self.git("log", "-1", "--format=%s").stdout.strip(), "release: v0.1.10")
        self.assertEqual(self.origin("rev-parse", "v0.1.10^{}").stdout, self.git("rev-parse", "HEAD").stdout)

    def test_cancel_or_eof_does_not_modify_or_publish_anything(self):
        for answer in ["\nn\n", ""]:
            result = self.release(answer)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Aborted.", result.stdout)
            self.assertEqual(self.git("status", "--porcelain").stdout, "")
            self.assertFalse(self.check_log.exists())
            self.assert_no_publication()

    def test_dirty_or_unsynchronized_checkout_is_rejected(self):
        (self.work / "untracked").write_text("pending change")
        result = self.release("\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("working tree is not clean", result.stderr)
        self.git("add", "untracked")
        self.git("commit", "-m", "Local change")
        result = self.release("\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must match", result.stderr)
        self.assertFalse(self.check_log.exists())
        self.assert_no_publication()

    def test_invalid_or_older_version_is_rejected(self):
        self.origin("tag", "v0.1.0", self.initial)
        for answer in ["01.2.3\ny\n", "0.1.0\ny\n"]:
            result = self.release(answer)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.git("status", "--porcelain").stdout, "")
            self.assertFalse(self.check_log.exists())

    def test_failed_checks_do_not_create_a_commit_or_tag(self):
        result = self.release("0.2.0\ny\n", RELEASE_TEST_FAIL_CHECK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.check_log.exists())
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial)
        self.assertEqual(self.git("tag", "--list").stdout, "")
        self.assert_no_publication()

    def test_release_pushes_to_the_tracked_remote_branch(self):
        self.git("branch", "-m", "local-name")
        result = self.release("0.2.0\ny\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.origin("rev-parse", "refs/heads/main").stdout, self.git("rev-parse", "HEAD").stdout)
        self.assertNotEqual(self.origin("show-ref", "--verify", "refs/heads/local-name", check=False).returncode, 0)

    def test_failed_atomic_push_preserves_local_work_and_remote_refs(self):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        result = self.release("0.2.0\ny\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local commit and tag were kept", result.stderr)
        self.assertEqual(self.git("log", "-1", "--format=%s").stdout.strip(), "release: v0.2.0")
        self.assertEqual(self.git("tag", "--list").stdout.strip(), "v0.2.0")
        self.assert_no_publication()


if __name__ == "__main__":
    unittest.main(verbosity=2)
