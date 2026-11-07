# syntax=docker/dockerfile:1
#
# Debian trixie image with git, glab (GitLab CLI), Claude Code, opencode and
# Podman, for the unprivileged user "dev" (no sudo).
# Intended for a coding agent (Claude Code or opencode) that clones GitLab repositories, opens or
# reviews merge requests, triages issues, and runs containers (rootless Podman
# inside the container).
#
# Build with rootful Podman (run.sh does this for you, see README.md):
#   sudo podman build --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t claude-glab .
#
# Run (credentials come from .env, see .env.example). Repositories are cloned
# inside the container and are discarded with it; only Claude Code state
# persists, in a named volume. The security options let rootless Podman run
# inside the container:
#   sudo podman run --rm -it --env-file .env \
#       --security-opt label=disable --security-opt apparmor=unconfined \
#       -v claude-config:/home/dev/.claude:U \
#       claude-glab
#
# One-shot, non-interactive:
#   sudo podman run --rm --env-file .env \
#       --security-opt label=disable --security-opt apparmor=unconfined \
#       -v claude-config:/home/dev/.claude:U \
#       claude-glab bash -lc 'glab repo clone group/project && cd project && \
#           claude -p "Review the open merge requests"'

FROM debian:trixie-slim

# UID/GID of "dev". Under rootful Podman they are the same IDs on the host, so
# match them to your account (run.sh passes them) to share files such as the
# host's Claude login.
ARG UID=1000
ARG GID=1000
ARG USERNAME=dev
# Optional: pin Claude Code, e.g. --build-arg CLAUDE_VERSION=2.0.30, or "stable".
# Defaults to the installer's "latest" channel.
ARG CLAUDE_VERSION
# Optional: pin opencode, e.g. --build-arg OPENCODE_VERSION=2.2.6. Defaults to
# the newest 2.x release on GitHub.
ARG OPENCODE_VERSION

# GIT_TERMINAL_PROMPT=0 makes git fail fast instead of hanging on a prompt when
# credentials are missing or wrong. Set GIT_TERMINAL_PROMPT=1 in .env to allow
# interactive prompts.
#
# CLAUDE_CONFIG_DIR moves ~/.claude.json (login and onboarding state) inside
# ~/.claude, so a single volume persists everything. DISABLE_AUTOUPDATER stops
# Claude Code from updating itself into the throwaway container layer; rebuild
# the image to upgrade instead. OPENCODE_DISABLE_AUTOUPDATE does the same for
# opencode.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    GIT_TERMINAL_PROMPT=0 \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_AUTOUPDATER=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1

# git and glab both ship in the Debian trixie repositories. jq and ripgrep are
# handy for triage and code review. podman, with uidmap (newuidmap and
# newgidmap) and crun, lets "dev" run rootless containers inside this one;
# libcap2-bin gives newuidmap/newgidmap file capabilities, see below.
RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        git \
        glab \
        jq \
        less \
        openssh-client \
        procps \
        ripgrep \
        podman \
        crun \
        conmon \
        uidmap \
        libcap2-bin \
        catatonit \
        passt \
 && rm -rf /var/lib/apt/lists/* \
 && chmod 0755 /usr/bin/newuidmap /usr/bin/newgidmap \
 && setcap cap_setuid=ep /usr/bin/newuidmap \
 && setcap cap_setgid=ep /usr/bin/newgidmap

# Above: Debian ships newuidmap/newgidmap setuid root, and inside a container
# without CAP_SYS_ADMIN they then fail to write the nested user namespace's ID
# map ("write to uid_map failed: Operation not permitted"). With only the one
# file capability each needs (as Fedora and the upstream Podman image ship
# them), they work under the default capability set.

# "dev" gets no sudo and no password: the agent cannot become root, install
# system packages or change anything outside its home and /tmp. For admin work,
# open a root shell from the host with `sudo podman exec -it -u root <name> bash`.
#
# For rootless Podman, "dev" owns every container UID/GID from 1 to 65535 except
# its own as subordinate IDs, the same layout as the upstream Podman image. The
# outer container is rootful without a user namespace, so these are host IDs too;
# files with them only ever live in the nested storage volume below.
RUN groupadd --gid "${GID}" "${USERNAME}" \
 && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash "${USERNAME}" \
 && passwd --lock "${USERNAME}" >/dev/null \
 && printf '%s:1:%d\n%s:%d:%d\n' \
        "${USERNAME}" "$((UID - 1))" "${USERNAME}" "$((UID + 1))" "$((65535 - UID))" >/etc/subuid \
 && printf '%s:1:%d\n%s:%d:%d\n' \
        "${USERNAME}" "$((GID - 1))" "${USERNAME}" "$((GID + 1))" "$((65535 - GID))" >/etc/subgid \
 && install -d \
        "/home/${USERNAME}/work" \
        "/home/${USERNAME}/.claude" \
        "/home/${USERNAME}/.config/containers" \
        "/home/${USERNAME}/.config/opencode" \
        "/home/${USERNAME}/.local/share/opencode" \
        "/home/${USERNAME}/.local/share/containers" \
 && chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

# Podman settings for nested containers (see the comments in the files).
COPY containers/containers.conf /etc/containers/containers.conf
COPY --chown=${UID}:${GID} containers/user-containers.conf /home/${USERNAME}/.config/containers/containers.conf
RUN chmod 0644 /etc/containers/containers.conf

# Nested image and container storage. Its overlay upper dirs cannot sit on the
# container's own overlay filesystem, so it is a volume: an anonymous one that
# `podman run --rm` deletes with the container.
VOLUME /home/${USERNAME}/.local/share/containers

# Agent guidance goes in the system-wide (managed) memory file rather than
# ~/.claude/CLAUDE.md, so it is always loaded and is never hidden or frozen by
# the volume mounted over ~/.claude. Rebuild the image to change it.
COPY claude-config/CLAUDE.md /etc/claude-code/CLAUDE.md
# opencode does not read /etc/claude-code; entrypoint.sh writes the same guidance
# (plus this session's facts) to ~/.config/opencode/AGENTS.md at start-up.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-wrapper.sh /usr/local/bin/claude-wrapper
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/claude-wrapper \
 && chmod 0644 /etc/claude-code/CLAUDE.md

# opencode 2 is installed from its GitHub release tarball: the opencode.ai
# install script only installs opencode 1. It goes in /usr/local/bin, so it is
# on every PATH; the auto-updater is disabled, rebuild to upgrade.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
        amd64) arch=x64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "opencode: unsupported architecture" >&2; exit 1 ;; \
    esac; \
    version="${OPENCODE_VERSION:-}"; version="${version#v}"; \
    if [ -z "${version}" ]; then \
        version="$(curl -fsSL 'https://api.github.com/repos/anomalyco/opencode/releases?per_page=50' \
            | jq -r '[.[] | select(.draft | not) | select(.prerelease | not) | .tag_name | select(test("^v2[.][0-9]+[.][0-9]+$"))][0] // empty')"; \
        version="${version#v}"; \
    fi; \
    [ -n "${version}" ] || { echo "opencode: could not find a 2.x release" >&2; exit 1; }; \
    curl -fsSL "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-${arch}.tar.gz" \
        | tar -xz -C /usr/local/bin opencode; \
    chmod 0755 /usr/local/bin/opencode; \
    /usr/local/bin/opencode --version

USER ${USERNAME}
ENV HOME=/home/${USERNAME}

# Install Claude Code with the official native installer, which picks the
# right binary for the build platform and puts a launcher in ~/.local/bin.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- ${CLAUDE_VERSION}

# Expose the binaries on the default PATH so they also work in login shells,
# which reset PATH. `claude` goes through claude-wrapper, which pre-accepts the
# folder-trust prompt so each fresh session can take a prompt right away. The
# installer's launcher moves to claude-real, so ~/.local/bin/claude (first on
# PATH in login shells) is the wrapper too.
USER root
RUN mv "/home/${USERNAME}/.local/bin/claude" "/home/${USERNAME}/.local/bin/claude-real" \
 && ln -s /usr/local/bin/claude-wrapper "/home/${USERNAME}/.local/bin/claude" \
 && ln -sf /usr/local/bin/claude-wrapper /usr/local/bin/claude
USER ${USERNAME}

# Accept repositories regardless of owner, so git never rejects a workspace with
# a "dubious ownership" error. The credential helper and git identity are
# configured at run time by /usr/local/bin/entrypoint.sh from the environment.
RUN git config --global --add safe.directory '*'

WORKDIR /home/${USERNAME}/work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
