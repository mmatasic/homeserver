#!/bin/bash
# Install git hooks. Run once after every fresh clone of this repo.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
HOOK_SRC="${REPO_ROOT}/scripts/pre-commit.hook"
HOOK_DST="${REPO_ROOT}/.git/hooks/pre-commit"

cp "${HOOK_SRC}" "${HOOK_DST}"
chmod +x "${HOOK_DST}"
echo "Installed pre-commit hook at ${HOOK_DST}"
