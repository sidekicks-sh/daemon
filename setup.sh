#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Sidekicks Daemon Installer
# ─────────────────────────────────────────────────────────────────────────────
# Downloads sidekick.sh from GitHub and installs it to ~/.local/bin
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sidekicks-sh/daemon/main/setup.sh | bash
#   OR
#   ./setup.sh
# ─────────────────────────────────────────────────────────────────────────────

REPO_URL="https://raw.githubusercontent.com/sidekicks-sh/daemon/refs/heads/main/sidekick.sh"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/sidekick"

echo "Sidekicks Daemon Installer"
echo "────────────────────────────────────────"

# Create install directory if it doesn't exist
if [[ ! -d "${INSTALL_DIR}" ]]; then
  echo "Creating ${INSTALL_DIR}..."
  mkdir -p "${INSTALL_DIR}"
fi

# Download sidekick.sh
echo "Downloading sidekick.sh..."
if ! curl -fsSL "${REPO_URL}" -o "${INSTALL_PATH}"; then
  echo "Failed to download sidekick.sh"
  exit 1
fi

# Make executable
chmod +x "${INSTALL_PATH}"
echo "Installed to ${INSTALL_PATH}"

# Check if ~/.local/bin is in PATH
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  echo ""
  echo "Warning: ${INSTALL_DIR} is not in your PATH."
  echo ""
  echo "Add it by appending this to your shell config (~/.bashrc, ~/.zshrc, etc.):"
  echo ""
  echo "    export PATH=\"\${HOME}/.local/bin:\${PATH}\""
  echo ""
  echo "Then restart your shell or run: source ~/.bashrc (or ~/.zshrc)"
else
  echo ""
  echo "You can now run: sidekick run"
fi

echo ""
echo "────────────────────────────────────────"
echo "Docs: https://github.com/sidekicks-sh/daemon"
