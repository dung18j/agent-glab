#!/usr/bin/env bash
# Installed as /usr/local/bin/claude in front of the real Claude Code binary.
#
# Claude Code asks "Do you trust the files in this folder?" the first time it
# starts in a directory, and run.sh gives every session a fresh ~/.claude, so
# that question would come up on every launch and in every clone. The container
# is the sandbox and only holds what the agent cloned, so mark the current
# directory (and its git root) as trusted before an interactive start.
# Non-interactive runs (claude -p) never ask, so they skip this and leave ~/.claude.json alone.
set -euo pipefail

real="${HOME}/.local/bin/claude-real"

if [ -t 0 ] && command -v jq >/dev/null 2>&1; then
    state="${CLAUDE_CONFIG_DIR:-${HOME}}/.claude.json"
    dirs=("${PWD}")
    if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ "${top}" != "${PWD}" ]; then
        dirs+=("${top}")
    fi
    [ -s "${state}" ] || printf '{}\n' >"${state}" 2>/dev/null || true
    if [ -s "${state}" ]; then
        dirs_json="$(printf '%s\n' "${dirs[@]}" | jq -R . | jq -s .)"
        filter='reduce $dirs[] as $d (.; .projects[$d].hasTrustDialogAccepted = true)'
        # Rewrite the file only when something is missing.
        if ! jq -e --argjson dirs "${dirs_json}" \
                '[.projects[$dirs[]].hasTrustDialogAccepted == true] | all' \
                "${state}" >/dev/null 2>&1; then
            tmp="$(mktemp "${state}.XXXXXX")"
            if jq --argjson dirs "${dirs_json}" "${filter}" "${state}" >"${tmp}"; then
                mv -f "${tmp}" "${state}"
            else
                rm -f "${tmp}"
            fi
        fi
    fi
fi

exec "${real}" "$@"
