#!/bin/bash
set -euo pipefail

[ -f /home/host/.kube/config ] && install -D /home/host/.kube/config /home/vscode/.kube/config
[ -f /home/host/.config/opencode/opencode.json ] && install -D /home/host/.config/opencode/opencode.json /home/vscode/.config/opencode/opencode.json
[ -f /home/host/.claude/settings.json ] && install -D /home/host/.claude/settings.json /home/vscode/.claude/settings.json
[ -f /home/host/.claude.json ] && install -D /home/host/.claude.json /home/vscode/.claude.json
[ -f /home/host/.gitconfig ] && install -D /home/host/.gitconfig /home/vscode/.gitconfig
[ -f /home/host/.codex/config.toml ] && install -D /home/host/.codex/config.toml /home/vscode/.codex/config.toml
