# Project Memory: OSTA_walkthroughs

## Environment: Fedora Linux 43 (WSL2) Python quirks

This machine runs Fedora Linux 43 under WSL2. Fedora splits several things out of
the base Python package that are bundled together on most other distros/platforms.
These have caused repeated `reticulate::virtualenv_create()` failures in
`background_section8.qmd`:

1. **`pip` is a separate package.** A bare `/usr/bin/python3.X` may have `venv`
   and `ensurepip` but no importable `pip` module. reticulate's
   `virtualenv_starter()` suitability check requires a working `pip`, not just
   `venv`. Fix: `sudo dnf install python3-pip` (or
   `python3.X -m ensurepip --upgrade` for a non-sudo, interpreter-local fix).

2. **C headers (`Python.h`) are a separate `-devel` package.** Without it,
   `pip install` fails to compile any package with native extensions (in this
   project's dependency list: `rpy2`, `fiona`). The error is
   `fatal error: Python.h: No such file or directory`. Fix:
   `sudo dnf install python3.X-devel` (e.g. `python3.14-devel`).

3. **reticulate's own error message for a failed `virtualenv_create()` is
   unhelpfully terse** — it just lists every requested package as "failed to
   install," with no indication of the real underlying pip error. To diagnose,
   reproduce directly in a shell: `python3.X -m venv /tmp/testenv && 
   /tmp/testenv/bin/pip install -r requirements_file.txt`, and read pip's actual
   output.

4. **`gensim` is incompatible with Python 3.14.** The latest release on PyPI
   (4.4.0) fails to compile against Python 3.14's C API — its Cython-generated
   C code references CPython internals (`PyLongObject.ob_digit`, an old
   `_PyLong_AsByteArray` signature) that were removed/changed in Python 3.10+.
   This is a genuine upstream incompatibility, not an environment misconfiguration.
   In this project, `gensim` is pulled in only transitively via `karateclub`
   (used by `commot`, for cell-cell communication analysis), which isn't
   otherwise used in `background_section8.qmd`. Resolution: `commot`, `gensim`,
   and `karateclub` are dropped from the `req_current` package list for the
   Python 3.14 environment.

5. Two other packages from the tutorial's original Python 3.8 pins don't belong
   in a modern (Python 3.10+/3.14) environment:
   - `backports.zoneinfo`: only backports stdlib `zoneinfo` for Python <3.9;
     unbuildable/unneeded on modern CPython.
   - `pygeos`: functionality merged into `shapely>=2.0` years ago; the
     standalone package no longer builds against current Python/setuptools.

6. **Positron always injects its own bundled `ipykernel` support libraries
   onto `PYTHONPATH`, ahead of the target venv's own site-packages — even
   when the venv has its own `ipykernel` installed.** Every Python console
   session Positron starts sets `PYTHONPATH` to point at
   `.positron-server/.../extensions/positron-python/python_files/lib/ipykernel/{x64/cpXXX,x64/cp3,py3}`
   (verified via `/proc/<pid>/environ` for the actual running console
   process), and those directories come *before* the venv's own
   `site-packages` on `sys.path` at interpreter startup. The bundled `py3`
   directory ships an older `typing_extensions.py` (4.15.0 here) that is
   missing symbols newer packages need (e.g. `sentinel`, added in a later
   release). This silently shadows the venv's own, newer `typing_extensions`
   install (4.16.0 here) and broke `import scanpy` in `OSTA_current` with
   `ImportError: cannot import name 'sentinel' from 'typing_extensions'`
   (raised from `anndata`). Installing `ipykernel` into the venv itself
   (already done, and listed in `req_current`) does **not** fix this — the
   bundled `PYTHONPATH` injection happens regardless.

   Fix that actually resolves it: added a `sitecustomize.py` to
   `~/.virtualenvs/OSTA_current/lib/python3.14/site-packages/` that
   re-inserts the venv's own site-packages at the front of `sys.path` at
   interpreter startup (`sitecustomize` is auto-imported by Python's `site`
   module before user code runs, so this pre-empts the shadowing before any
   package is imported). Verified by reproducing Positron's exact
   `PYTHONPATH`/`VIRTUAL_ENV` env vars and confirming `import scanpy`
   succeeds and `typing_extensions.__file__` resolves to the venv's copy.

   Both environment setup paths now write this `sitecustomize.py`
   automatically, so recreating either environment from scratch preserves
   the fix without manual intervention:
   - `create_reticulate_env_current` chunk in `background_section8.qmd`
     writes it right after `virtualenv_create()`, resolving the target
     site-packages directory via `virtualenv_python()` +
     `sysconfig.get_path('purelib')`.
   - `setup_osta_env.sh` writes it right after the pip install step,
     resolving the target directory the same way via
     `conda run -n "${ENV_NAME}" python -c "import sysconfig; ..."`.

   The file still lives inside each environment (not tracked in this repo),
   but both setup paths now regenerate it as part of normal (re-)creation.

7. **`req_current` pins must match the Posit Package Manager PyPI snapshot date.**
   The `req_current` list in `background_section8.qmd` contains version pins
   resolved against a specific snapshot date (`2026-07-08` as of this project's
   setup). Packages released after that snapshot date (or updated to newer
   versions in the snapshot) will not be found, causing
   `reticulate::virtualenv_create()` to fail with an unhelpfully terse
   "failed to install X, Y, Z..." message that doesn't distinguish real pip
   errors from resolution failures (see quirk 3 above).
   
   When updating `req_current` for a newer Posit Package Manager snapshot or
   live PyPI index, audit all pins by running:
   ```bash
   pip install --dry-run --no-deps --index-url https://packagemanager.posit.co/pypi/YYYY-MM-DD/simple \
     --trusted-host packagemanager.posit.co -r <requirements_file.txt>
   ```
   This checks each package individually against the target index without
   cross-package dependency cascade failures. Any failing package should be
   downgraded to the latest version present in the snapshot. The snapshot
   date can be found in `~/.Rprofile` (the `repos` option CRAN URL contains it)
   or by running `pip config list` in a shell (the `global.index-url` shows it).

## Key files

- **`background_section8.qmd`**: Quarto doc demonstrating R/Python
  interoperability (reticulate + anndata/scanpy) for the OSTA book walkthrough.
  Contains two `eval: false` virtualenv setup chunks:
  - `original_create_reticulate_env`: Python 3.8.18 with the tutorial's
    original `req` pins (kept for reference, not run — Python 3.8 is
    incompatible with Positron's kernel, which requires Python ≥3.9).
  - `create_reticulate_env_current`: Python 3.14 via
    `reticulate::virtualenv_starter("3.14")`, with `req_current` — an
    unpinned-then-repinned, verified-installable package list (105 packages,
    including `ipykernel` — see quirk 6 above) derived from `req` for
    current Python. Requires `python3-pip` and `python3.X-devel` installed
    system-wide (see above) before running.
- **`setup_osta_env.sh`**: Alternative conda-based environment setup script.
  Creates a conda env named `OSTA` with Python 3.10.21 + an isolated R 4.3.3
  (both prebuilt from conda-forge, avoiding source compilation), with
  R_HOME/LD_LIBRARY_PATH activation hooks so rpy2/anndata2ri bind to the
  isolated R instead of the system R. Drops `backports.zoneinfo` from the
  108-package install (see reason above). Verified working.
- **`requirements.txt`**: Original 109 pinned packages from the OSTA tutorial,
  targeting Python 3.8. Used as the reference list for both `req` (original
  pins, kept in the `.qmd` for provenance) and `req_current` (repinned for
  Python 3.14).
