#!/usr/bin/env bash
# sparkcli installer — symlinks the CLI and sets up user config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Symlink CLI to PATH
sudo ln -sf "${SCRIPT_DIR}/sparkcli.sh" /usr/local/bin/sparkcli
sudo chmod +x "${SCRIPT_DIR}/sparkcli.sh"
echo "Linked: /usr/local/bin/sparkcli → ${SCRIPT_DIR}/sparkcli.sh"

# Copy example config if not already present
mkdir -p "${HOME}/.sparkcli"
if [ ! -f "${HOME}/.sparkcli/config.conf" ]; then
  cp "${SCRIPT_DIR}/config.conf.example" "${HOME}/.sparkcli/config.conf"
  echo "Config written to ~/.sparkcli/config.conf — review and adjust before use."
else
  echo "Config already exists at ~/.sparkcli/config.conf — not overwritten."
fi

echo ""
echo "sparkcli installed. Run 'sparkcli doctor' to verify your setup."
