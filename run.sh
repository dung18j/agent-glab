#!/usr/bin/env bash
# Run the claude-glab container with rootful Podman (through sudo).
#
#   ./run.sh                                   # shell, credentials from .env
#   ./run.sh -e .env.apo                       # shell, credentials from .env.apo
#   ./run.sh -e .env.apo claude                # Claude Code TUI
#   ./run.sh -e .env.apo bash -lc 'glab repo clone group/project && cd project && claude -p "Review the open MRs"'
#
# Options:
#   -e FILE   env file to load (default: .env, relative to this script)
#   -b        build the image before running (also done when it is missing)
#   -p        persist: keep Claude Code state in the named volume
#             (default: fresh, throwaway session)
#   -n        do not mount the host's Claude login (log in inside the container)
#
# The container runs under rootful Podman, so that rootless Podman works inside
# it (the agent can build and run containers). Run this script as your normal
# user: it calls `sudo podman` itself, and reads your Claude login from your
# home. The agent runs as the unprivileged user "dev", with no sudo,
# whose UID/GID are yours, so it can use that file and nothing of root's.
#
# By default every run is a fresh session: Claude Code starts with an empty
# ~/.claude (no history, sessions or settings from earlier runs) and nothing the
# container writes is kept, except token refreshes of the shared login below.
#
# By default the host's ~/.claude/.credentials.json is bind-mounted into the
# container, so Claude Code reuses your host subscription login. Container and
# host share that one login file and its token refreshes.
#
# Each container gets its own network namespace (Podman's default network), so
# several sessions can run side by side and open the same ports without
# clashing. Outbound traffic (GitLab, Anthropic, VPN routes) goes through the
# host as usual; services on the host are at host.containers.internal.
#
# IMAGE (default claude-glab) and VOLUME (default claude-config, used with -p)
# can be overridden from the environment, e.g. VOLUME=claude-apo ./run.sh -p
# Images and volumes live in root's Podman storage (sudo podman images).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${IMAGE:-claude-glab}"
volume="${VOLUME:-claude-config}"
env_file=".env"
build=0
host_creds=1
persist=0

while getopts ":e:bpnh" opt; do
    case "${opt}" in
        e) env_file="${OPTARG}" ;;
        b) build=1 ;;
        p) persist=1 ;;
        n) host_creds=0 ;;
        h) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        :) echo "run.sh: -${OPTARG} needs an argument" >&2; exit 2 ;;
        *) echo "run.sh: unknown option -${OPTARG} (try -h)" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

# Resolve a relative env file against the script directory, unless it exists
# relative to the current directory.
if [[ "${env_file}" != /* && ! -f "${env_file}" ]]; then
    env_file="${here}/${env_file}"
fi
if [[ ! -f "${env_file}" ]]; then
    echo "run.sh: env file not found: ${env_file}" >&2
    exit 1
fi

# Rootful Podman. When already root (sudo ./run.sh), use the invoking user's
# home and IDs, not root's.
if (( EUID == 0 )); then
    podman=(podman)
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
        HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
        unset CLAUDE_CONFIG_DIR
    fi
    host_uid="${SUDO_UID:-0}"
    host_gid="${SUDO_GID:-0}"
else
    podman=(sudo podman)
    host_uid="$(id -u)"
    host_gid="$(id -g)"
fi
if (( host_uid == 0 )); then
    echo "run.sh: run as your normal user, not root" >&2
    exit 1
fi

# The image is built for your UID/GID, so "dev" owns the same files as you.
if (( build )) || ! "${podman[@]}" image exists "${image}"; then
    "${podman[@]}" build \
        --build-arg UID="${host_uid}" --build-arg GID="${host_gid}" \
        -t "${image}" "${here}"
fi

# Allocate a TTY only when attached to a terminal, so piping and scripting work.
tty_flags=(-i)
[[ -t 0 && -t 1 ]] && tty_flags=(-it)

# Rootless Podman inside the container needs to mount filesystems in its own
# user namespace, which AppArmor's default container profile (and SELinux
# labelling, on hosts that use it) forbids. The container is otherwise not
# privileged: default capabilities and seccomp profile, and the agent is not root.
#
# There is no user namespace: "dev" has your UID, so your owner-only files are
# readable. :U re-owns the volume to "dev". Without -p, ~/.claude is the image's
# empty directory and goes away with --rm, as does the nested container storage.
run_args=(--security-opt label=disable --security-opt apparmor=unconfined)
if (( persist )); then
    run_args+=(-v "${volume}:/home/dev/.claude:U")
fi

host_cred_file="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.credentials.json"
if (( host_creds )); then
    if [[ -f "${host_cred_file}" ]]; then
        run_args+=(-v "${host_cred_file}:/home/dev/.claude/.credentials.json")
    else
        echo "run.sh: no host Claude login at ${host_cred_file}; log in inside the container" >&2
    fi
fi

# No --network=host: every session has a private network namespace, so
# concurrent sessions never compete for the same ports.
exec "${podman[@]}" run --rm "${tty_flags[@]}" \
    --env-file "${env_file}" \
    "${run_args[@]}" \
    "${image}" "$@"
