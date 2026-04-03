#!/bin/bash
set -euo pipefail

mkdir -p /home/vscode/.kube /home/vscode/.config/opencode /home/vscode/.claude

[ -f /home/host/.kube/config ] && cp /home/host/.kube/config /home/vscode/.kube/config
[ -f /home/host/.config/opencode/opencode.json ] && cp /home/host/.config/opencode/opencode.json /home/vscode/.config/opencode/opencode.json
[ -f /home/host/.claude/settings.json ] && cp /home/host/.claude/settings.json /home/vscode/.claude/settings.json
[ -f /home/host/.claude.json ] && cp /home/host/.claude.json /home/vscode/.claude.json
[ -f /home/host/.gitconfig ] && cp /home/host/.gitconfig /home/vscode/.gitconfig
