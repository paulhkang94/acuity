"""Exercise Acuity's public-docs integration through the shared checker CLI."""

import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "public_repo_guard.py"


def _environment():
    # A verifier may run inside a Git hook; never redirect fixture Git to it.
    return {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }


def _git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        env=_environment(),
        capture_output=True,
        text=True,
        check=True,
    )


def _fixture_repo(tmp_path, *, tracked_research=False):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    hooks = repo / ".git" / "fixture-hooks"
    hooks.mkdir()
    excludes = repo / ".git" / "fixture-excludes"
    excludes.write_text("")
    _git(repo, "config", "core.hooksPath", str(hooks))
    _git(repo, "config", "core.excludesFile", str(excludes))
    _git(repo, "config", "user.name", "Public Docs Test")
    _git(repo, "config", "user.email", "test@example.invalid")
    (repo / "README.md").write_text("# Public project fixture\n")
    (repo / "docs" / "demo").mkdir(parents=True)
    (repo / "docs" / "GOTCHAS.md").write_text("# Public technical fixture\n")
    (repo / "docs" / "demo" / "example.png").write_bytes(b"public media path fixture")
    if tracked_research:
        research = repo / "docs" / "research" / "unreviewed-fixture.md"
        research.parent.mkdir()
        research.write_text("# Unreviewed fixture\n")
        # Stage before adding ignore rules: reproduces already-tracked data
        # without force-adding any excluded file.
        _git(repo, "add", "docs/research/unreviewed-fixture.md")
    for name in (".public-docs.json", ".gitignore"):
        (repo / name).write_bytes((ROOT / name).read_bytes())
    _git(
        repo,
        "add",
        ".public-docs.json",
        ".gitignore",
        "README.md",
        "docs/GOTCHAS.md",
        "docs/demo/example.png",
    )
    return repo


def _audit(repo, *args):
    return subprocess.run(
        [sys.executable, str(CHECKER), "--docs-only", *args],
        cwd=repo,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=20,
    )


def test_public_project_docs_and_demo_paths_remain_allowed(tmp_path):
    result = _audit(_fixture_repo(tmp_path))
    assert result.returncode == 0, result.stdout + result.stderr


def test_tracked_unreviewed_research_is_rejected_even_when_ignored(tmp_path):
    repo = _fixture_repo(tmp_path, tracked_research=True)
    result = _audit(repo)
    assert result.returncode != 0
    assert "docs/research/unreviewed-fixture.md" in result.stdout + result.stderr


def test_committed_audit_uses_the_committed_policy_and_ignore_file(tmp_path):
    repo = _fixture_repo(tmp_path)
    message = repo / ".git" / "fixture-commit-message"
    message.write_text("Public documentation fixture\n")
    _git(repo, "commit", "-q", "-F", str(message))
    (repo / ".public-docs.json").write_text("invalid working-tree policy\n")
    (repo / ".gitignore").write_text("invalid working-tree ignore block\n")
    committed = _audit(repo, "--ref", "HEAD")
    assert committed.returncode == 0, committed.stdout + committed.stderr
    working = _audit(repo)
    assert working.returncode != 0
