#!/usr/bin/env bash
# Run the claude-glab container with rootless Podman.
#
#   ./run.sh                                   # shell, credentials from .env
#   ./run.sh -e .env.apo                       # shell, credentials from .env.apo
#   ./run.sh -e .env.apo claude                # Claude Code TUI
#   ./run.sh -e .env.apo opencode              # opencode TUI
#   ./run.sh -e .env.apo bash -lc 'glab repo clone group/project && cd project && claude -p "Review the open MRs"'
#
# Options:
#   -e FILE   env file to load (default: .env, relative to this script)
#   -b        build the image before running (also done when it is missing)
#   -p        persist: keep Claude Code and opencode state in named volumes
#             (default: fresh, throwaway session)
#   -n        do not use the host's Claude and opencode logins (log in inside
#             the container)
#
# The container runs under rootless Podman as your normal user, and rootless
# Podman works inside it (the agent can build and run containers): rootless
# inside rootless, no sudo on the host. The agent runs as the base image's user
# "podman" (passwordless sudo, in the container). Your account is mapped to it, so
# it can use your Claude login file; the other IDs in the container are your
# subordinate IDs (/etc/subuid, /etc/subgid), of which you need at least 65536.
#
# By default every run is a fresh session: Claude Code starts with an empty
# ~/.claude (no history, sessions or settings from earlier runs) and nothing the
# container writes is kept, except token refreshes of the shared login below.
# opencode likewise starts with empty state.
#
# By default the host's ~/.claude/.credentials.json is bind-mounted into the
# container, so Claude Code reuses your host subscription login. Container and
# host share that one login file and its token refreshes.
#
# If opencode is installed on the host, its credentials (`opencode auth export`)
# are copied into a temporary file, mounted read-only and imported into the
# container's opencode at start-up; the file is deleted when the container
# exits. This is a copy: logins and token refreshes in the container do not
# reach the host.
#
# Each container gets its own network namespace (Podman's default network), so
# several sessions can run side by side and open the same ports without
# clashing. Outbound traffic (GitLab, Anthropic, VPN routes) goes through the
# host as usual; services on the host are at host.containers.internal.
#
# IMAGE (default claude-glab), VOLUME (default claude-config) and OC_VOLUME
# (default opencode-data; both used with -p) can be overridden from the
# environment, e.g. VOLUME=claude-apo OC_VOLUME=opencode-apo ./run.sh -p
# Images and volumes live in your rootless Podman storage (podman images).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${IMAGE:-claude-glab}"
volume="${VOLUME:-claude-config}"
oc_volume="${OC_VOLUME:-opencode-data}"
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
        h) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

if (( EUID == 0 )); then
    echo "run.sh: run as your normal user, not root (the container is rootless)" >&2
    exit 1
fi
podman=(podman)

if (( build )) || ! "${podman[@]}" image exists "${image}"; then
    "${podman[@]}" build -t "${image}" "${here}"
fi

# Allocate a TTY only when attached to a terminal, so piping and scripting work.
tty_flags=(-i)
[[ -t 0 && -t 1 ]] && tty_flags=(-it)

# keep-id maps your account to "podman" (UID/GID 1000 in the image), so your
# owner-only files are readable by "podman", and your subordinate IDs to the rest
# of the container's IDs, which "podman" uses for its own nested containers.
# Nested storage uses fuse-overlayfs, hence /dev/fuse. SELinux labelling (on
# hosts that use it) would block the nested containers, so it is disabled. The
# container is otherwise not privileged: default capabilities and seccomp
# profile, and the agent is not root.
#
# :U re-owns the volume to "podman". Without -p, ~/.claude is the image's empty
# directory and goes away with --rm, as does the nested container storage.
run_args=(
    --userns=keep-id:uid=1000,gid=1000
    --device /dev/fuse
    --security-opt label=disable
)
if (( persist )); then
    run_args+=(-v "${volume}:/home/podman/.claude:U")
    run_args+=(-v "${oc_volume}:/home/podman/.local/share/opencode:U")
fi

host_cred_file="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.credentials.json"
if (( host_creds )); then
    if [[ -f "${host_cred_file}" ]]; then
        run_args+=(-v "${host_cred_file}:/home/podman/.claude/.credentials.json")
    else
        echo "run.sh: no host Claude login at ${host_cred_file}; log in inside the container" >&2
    fi
fi

# opencode keeps its credentials in a database, not a file, so export them on
# the host and hand the container a copy to import.
oc_auth=""
cleanup() { [[ -n "${oc_auth}" ]] && rm -f "${oc_auth}"; return 0; }
trap cleanup EXIT
if (( host_creds )); then
    host_opencode="$(command -v opencode 2>/dev/null || true)"
    [[ -z "${host_opencode}" && -x "${HOME}/.opencode/bin/opencode" ]] \
        && host_opencode="${HOME}/.opencode/bin/opencode"
    if [[ -n "${host_opencode}" ]]; then
        # Your runtime directory is private to you.
        oc_auth="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/opencode-auth.XXXXXX")" || oc_auth=""
        if [[ -n "${oc_auth}" ]] \
                && "${host_opencode}" auth export >"${oc_auth}" 2>/dev/null \
                && [[ -s "${oc_auth}" ]]; then
            run_args+=(-v "${oc_auth}:/run/secrets/opencode-auth.json:ro")
        else
            echo "run.sh: could not export the host's opencode credentials; log in inside the container" >&2
        fi
    fi
fi

# No --network=host: every session has a private network namespace, so
# concurrent sessions never compete for the same ports.
# Not exec'd, so the exported opencode credentials are deleted afterwards.
status=0
"${podman[@]}" run --rm "${tty_flags[@]}" \
    --env-file "${env_file}" \
    "${run_args[@]}" \
    "${image}" "$@" || status=$?
exit "${status}"
