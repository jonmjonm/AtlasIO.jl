"""Release checks: the Python package and AtlasIO.jl share one version number and one license."""
import filecmp
import os
import re

import pytest

import atlasio

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def test_version_matches_atlasio_jl():
    project = os.path.join(REPO, "Project.toml")
    if not os.path.exists(project):
        pytest.skip("not run from the AtlasIO.jl repository")
    with open(project, encoding="utf-8") as f:
        julia = re.search(r'^version\s*=\s*"([^"]+)"', f.read(), re.M).group(1)
    assert atlasio.__version__ == julia, "bump python/src/atlasio/__init__.py and Project.toml together"


def test_license_copy_matches():
    if not os.path.exists(os.path.join(REPO, "LICENSE")):
        pytest.skip("not run from the AtlasIO.jl repository")
    assert filecmp.cmp(os.path.join(REPO, "LICENSE"), os.path.join(REPO, "python", "LICENSE"), shallow=False), \
        "python/LICENSE (shipped with the PyPI package) must be a copy of the repository's LICENSE"
