# Releasing AtlasIO

AtlasIO.jl (Julia) and the `atlasio` Python package (`python/`) share one version number and are released together
from one git tag, `vX.Y.Z` on `main`. The tag:

- publishes the Python package to [PyPI](https://pypi.org/p/atlasio) automatically
  (`.github/workflows/pypi.yml`);
- is the release you register with the Julia General registry (JuliaRegistrator), as before.

## Every release

1. On a branch, bump the version in **both** `Project.toml` and `python/src/atlasio/__init__.py` (`__version__`).
   A test fails if they differ. Add a `CHANGELOG.md` entry, and move the version pins in the docs
   (`README.md`, `function_calls.md`, `python/README.md`, `PythonReader/AtlasIO.py`, `PythonReader/testAtlas.py`)
   to the new tag.
2. Open a PR, let CI pass, and merge.
3. Optional dry run: on GitHub, **Actions → Publish Python package → Run workflow**, branch `main`, target
   `testpypi`. Then check the result in a fresh environment:

       python -m venv /tmp/try && /tmp/try/bin/pip install -i https://test.pypi.org/simple/ atlasio==X.Y.Z
       /tmp/try/bin/python -c "import atlasio; print(atlasio.__version__)"

   TestPyPI also refuses a version number twice, so a second dry run of the same version fails at the upload.
   That does no harm.
4. Tag `main` and push the tag:

       git checkout main && git pull
       git tag vX.Y.Z && git push origin vX.Y.Z

   The workflow checks that the tag, `atlasio.__version__` and `Project.toml` agree, builds, tests the built wheel,
   and publishes to PyPI. Watch it under **Actions**. If you added an approval rule to the `pypi` environment
   (below), approve the run there.
5. Register the Julia version: comment `@JuliaRegistrator register` on the merge commit (or use the JuliaHub
   web form), as before.

PyPI never accepts the same version twice. If a release is broken, fix it and release the next patch version.
PyPI's "yank" hides a bad version from new installs, but it cannot be replaced.

## One-time setup (before the first PyPI release)

Trusted Publishing means PyPI trusts this repository's workflow directly, so no password or API token is stored
in GitHub. Only the owner of the PyPI account can do these steps.

1. **Create accounts** on [pypi.org](https://pypi.org/account/register/) and
   [test.pypi.org](https://test.pypi.org/account/register/). They are separate sites, so you need two accounts.
   Turn on two-factor authentication on both (PyPI requires it to publish).
2. **Add a pending publisher on PyPI.** This reserves the name before the first upload. Go to *Your account →
   Publishing → Add a new pending publisher → GitHub*, and enter:

   | Field | Value |
   |---|---|
   | PyPI Project Name | `atlasio` |
   | Owner | `jonmjonm` |
   | Repository name | `AtlasIO.jl` |
   | Workflow name | `pypi.yml` |
   | Environment name | `pypi` |

3. **Do the same on TestPyPI**, with Environment name `testpypi`.
4. **Optional, recommended: require approval to publish.** On GitHub, go to *Settings → Environments*. The `pypi`
   environment appears after the workflow first runs, or you can create it there. Under *Required reviewers*, add
   yourself. Every PyPI publish then waits for your click.

The first successful upload turns the pending publisher into the real `atlasio` project, owned by your account.
On the project's PyPI page you can add co-maintainers (*Manage → Collaborators*).
