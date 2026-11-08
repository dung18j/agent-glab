# syntax=docker/dockerfile:1
#
# Fedora image (quay.io/podman/stable) with git, glab (GitLab CLI), Claude Code,
# opencode and Podman, for the base image's user "podman" (passwordless sudo).
# Intended for a coding agent (Claude Code or opencode) that clones GitLab repositories, opens or
# reviews merge requests, triages issues, and runs containers (rootless Podman
# inside the container).
#
# The base image is the upstream Podman image, which is set up for running
# Podman inside a container. The container itself runs under rootless Podman on
# the host: rootless inside rootless, no root anywhere.
#
# Build with rootless Podman (run.sh does this for you, see README.md):
#   podman build -t claude-glab .
#
# Run (credentials come from .env, see .env.example). Repositories are cloned
# inside the container and are discarded with it. keep-id maps your host
# account to "podman" (UID 1000 in the image); /dev/fuse and label=disable let
# rootless Podman run inside the container:
#   podman run --rm -it --env-file .env \
#       --userns=keep-id:uid=1000,gid=1000 --device /dev/fuse \
#       --security-opt label=disable \
#       claude-glab
#
# One-shot, non-interactive:
#   podman run --rm --env-file .env \
#       --userns=keep-id:uid=1000,gid=1000 --device /dev/fuse \
#       --security-opt label=disable \
#       claude-glab bash -lc 'glab repo clone group/project && cd project && \
#           claude -p "Review the open merge requests"'

FROM quay.io/podman/stable

ARG USERNAME=podman
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
ENV LANG=C.UTF-8 \
    GIT_TERMINAL_PROMPT=0 \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_AUTOUPDATER=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1

# Podman, crun, fuse-overlayfs, passt and newuidmap/newgidmap (with the file
# capabilities they need in a container) come with the base image. git and glab
# are in the Fedora repositories; jq and ripgrep are handy for triage and code
# review.
RUN dnf -y install --setopt=install_weak_deps=False \
        git \
        glab \
        jq \
        openssh-clients \
        procps-ng \
        ripgrep \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/libdnf5

# The agent runs as the base image's user "podman" (UID/GID 1000), which is set
# up for rootless Podman: subordinate IDs 1-65535 except its own (/etc/subuid,
# /etc/subgid), its own containers.conf, and its nested storage
# (~/.local/share/containers) as a volume.
#
# It gets passwordless sudo, so the agent can install packages or change the
# system when a task needs it. That root exists only inside the container: the
# outer container is rootless, so its root is one of your subordinate IDs on
# the host, not host root, and every change is gone with the container.
RUN install -d -o "${USERNAME}" -g "${USERNAME}" \
        "/home/${USERNAME}/work" \
        "/home/${USERNAME}/.claude" \
        "/home/${USERNAME}/.config/opencode" \
        "/home/${USERNAME}/.local/bin" \
        "/home/${USERNAME}/.local/share/opencode" \
 && printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${USERNAME}" >"/etc/sudoers.d/${USERNAME}" \
 && chmod 0440 "/etc/sudoers.d/${USERNAME}" \
 && visudo -cq

# Agent guidance goes in the system-wide (managed) memory file rather than
# ~/.claude/CLAUDE.md, so it is always loaded and is never hidden or frozen by
# the volume mounted over ~/.claude. Rebuild the image to change it.
COPY claude-config/AGENT.md /etc/claude-code/CLAUDE.md
# opencode does not read /etc/claude-code; entrypoint.sh writes the same guidance
# (plus this session's facts) to ~/.config/opencode/AGENTS.md at start-up.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
 && chmod 0644 /etc/claude-code/CLAUDE.md

# opencode 2 is installed from its GitHub release tarball: the opencode.ai
# install script only installs opencode 1. It goes in /usr/local/bin, so it is
# on every PATH; the auto-updater is disabled, rebuild to upgrade.
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) arch=x64 ;; \
        aarch64) arch=arm64 ;; \
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

# Expose the binary on the default PATH so it also works in login shells,
# which reset PATH.
USER root
RUN ln -sf "/home/${USERNAME}/.local/bin/claude" /usr/local/bin/claude
USER ${USERNAME}

# Accept repositories regardless of owner, so git never rejects a workspace with
# a "dubious ownership" error. The credential helper and git identity are
# configured at run time by /usr/local/bin/entrypoint.sh from the environment.
RUN git config --global --add safe.directory '*'

WORKDIR /home/${USERNAME}/work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
