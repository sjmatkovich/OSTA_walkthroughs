#!/usr/bin/env bash
# Create a conda environment named "OSTA" with Python 3.10.21 and the
# pinned packages listed in requirements.txt (in the current working
# directory). Re-run this script later to recreate the environment
# from the same requirements file.
#
# NOTE: requirements.txt was originally pinned against Python 3.8. Most
# pins (numpy 1.22.4, pandas 1.3.5, scanpy 1.9.6, anndata 0.9.2, etc.) do
# have compatible wheels for Python 3.10, but pip install may still need to
# resolve/rebuild a handful of packages. Failures should be inspected
# individually rather than assumed benign.
#
# NOTE on R/rpy2: this environment includes anndata2ri/rpy2, which embed
# an R interpreter via its C API. That API is not guaranteed stable across
# R versions, so rpy2 must be paired with a compatible R. Rather than rely
# on whatever R happens to be first on PATH (which may be a much newer
# system R and can cause rpy2 to segfault), this script installs an
# isolated, version-pinned R into the conda env itself and configures the
# env to point rpy2 at it via R_HOME / LD_LIBRARY_PATH activation hooks.
set -euo pipefail

ENV_NAME="OSTA"
PY_VERSION="3.10.21"
R_VERSION="4.3"   # known compatible with rpy2==3.5.14 / anndata2ri==1.3.1
REQ_FILE="requirements.txt"

if [[ ! -f "${REQ_FILE}" ]]; then
    echo "Error: ${REQ_FILE} not found in $(pwd)." >&2
    exit 1
fi

# Recreate the environment if it already exists, so this script is idempotent.
if conda env list | awk '{print $1}' | grep -Fxq "${ENV_NAME}"; then
    echo "Removing existing conda environment '${ENV_NAME}'..."
    conda env remove -n "${ENV_NAME}" -y
fi

echo "Creating conda environment '${ENV_NAME}' with Python ${PY_VERSION}..."
conda create -n "${ENV_NAME}" -y "python=${PY_VERSION}" pip

echo "Installing an isolated R ${R_VERSION} (conda-forge) for rpy2/anndata2ri..."
conda install -n "${ENV_NAME}" -c conda-forge -y "r-base=${R_VERSION}"

echo "Installing packages from ${REQ_FILE} into '${ENV_NAME}'..."
conda run -n "${ENV_NAME}" python -m pip install --upgrade pip

# backports.zoneinfo is a Python <3.9 shim for the stdlib zoneinfo module;
# its C extension references CPython internals removed in 3.10, so it
# cannot build on this Python version. It's unneeded here since Python
# 3.10 already provides zoneinfo natively, so skip that one pinned line.
grep -v -i '^backports\.zoneinfo==' "${REQ_FILE}" > /tmp/osta_requirements_py310.txt
conda run -n "${ENV_NAME}" python -m pip install -r /tmp/osta_requirements_py310.txt

# Point rpy2 at the env-local R rather than any system R that may appear
# earlier on PATH. These activation hooks only take effect within this
# conda environment and are reverted automatically on deactivation.
ENV_PREFIX="$(conda info --base)/envs/${ENV_NAME}"
mkdir -p "${ENV_PREFIX}/etc/conda/activate.d" "${ENV_PREFIX}/etc/conda/deactivate.d"

cat > "${ENV_PREFIX}/etc/conda/activate.d/r_home.sh" <<EOF
export OSTA_OLD_R_HOME="\${R_HOME:-}"
export OSTA_OLD_LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:-}"
export R_HOME="${ENV_PREFIX}/lib/R"
export LD_LIBRARY_PATH="${ENV_PREFIX}/lib/R/lib:\${LD_LIBRARY_PATH:-}"
EOF

cat > "${ENV_PREFIX}/etc/conda/deactivate.d/r_home.sh" <<EOF
export R_HOME="\${OSTA_OLD_R_HOME:-}"
export LD_LIBRARY_PATH="\${OSTA_OLD_LD_LIBRARY_PATH:-}"
unset OSTA_OLD_R_HOME
unset OSTA_OLD_LD_LIBRARY_PATH
EOF

# Positron quirk workaround (see AGENTS.md item 6): Positron always injects
# PYTHONPATH entries pointing at its own bundled ipykernel support libraries
# ahead of this env's own site-packages, which can shadow newer packages
# (e.g. an older bundled `typing_extensions.py` missing `sentinel`, breaking
# `import scanpy`/`anndata`) -- this happens regardless of whether ipykernel
# is installed in this env. A `sitecustomize.py` dropped into this env's
# site-packages re-prioritizes the env's own packages at interpreter
# startup, before any user code runs. This lives inside the env (not this
# repo), so it must be (re-)written any time the env is (re-)created --
# hence doing it here, immediately after installing packages.
echo "Writing sitecustomize.py to work around Positron's bundled-ipykernel PYTHONPATH shadowing..."
SITE_PACKAGES="$(conda run -n "${ENV_NAME}" python -c "import sysconfig; print(sysconfig.get_path('purelib'))")"
cat > "${SITE_PACKAGES}/sitecustomize.py" <<'PYEOF'
"""
Workaround for a Positron/reticulate interaction: Positron's Python
extension always injects PYTHONPATH entries pointing at its own bundled
ipykernel support libraries, placed ahead of this environment's own
site-packages on sys.path -- even when this environment has its own
ipykernel installed. Those bundled libraries can ship an older
`typing_extensions.py` missing symbols (e.g. `sentinel`) needed by newer
packages such as `anndata`, silently shadowing this environment's own,
newer `typing_extensions` install and breaking imports like
`import scanpy`.

Fix: move this environment's own site-packages directory to the front of
`sys.path`, so it takes priority over Positron's bundled fallback
libraries. See AGENTS.md in the OSTA_walkthroughs project for the full
quirk write-up. This file is regenerated by `setup_osta_env.sh` every
time the environment is (re-)created.
"""

import sys
import os

_env_site_packages = os.path.dirname(os.path.abspath(__file__))

if _env_site_packages in sys.path:
    sys.path.remove(_env_site_packages)
sys.path.insert(0, _env_site_packages)
PYEOF

echo "Verifying rpy2/anndata2ri import against the env-local R..."
conda run -n "${ENV_NAME}" python -c "
from rpy2.robjects import r
print('R version in use:', r('R.version.string')[0])
import anndata2ri
anndata2ri.activate()
print('anndata2ri OK')
"

echo "Done. Activate the environment with: conda activate ${ENV_NAME}"
