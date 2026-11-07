# glab + Claude Code / opencode container

A Debian trixie image with `git`, `glab` (GitLab CLI), Claude Code, opencode and Podman,
built for running a coding agent against GitLab: cloning repositories,
opening and reviewing merge requests, triaging issues, and building and running
containers.

Repositories are cloned **inside** the container and thrown away with it. Only
Claude Code's own state, credentials and settings are persisted, in a named
volume, so nothing from the host is mounted into the sandbox.

Running the agent in the container keeps `GITLAB_TOKEN` inside the sandbox. The
credential helper is scoped to your GitLab host only, so the token is never
offered to other HTTPS remotes. The agent runs as the unprivileged user `dev`,
with no `sudo` (see [Limits on the agent](#limits-on-the-agent)).

## Build

The container runs under **rootful** Podman, so the image goes in root's image
store. `run.sh` builds it on first use (and with `-b`); by hand:

```sh
sudo podman build --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t claude-glab .
```

`UID`/`GID` give `dev` your IDs. With rootful Podman and no user namespace they
are the same IDs on the host, which is what lets `dev` use your mounted Claude
login.

Pin a Claude Code version with `--build-arg CLAUDE_VERSION=<version>` (or
`stable`), and opencode with `--build-arg OPENCODE_VERSION=<version>` (default:
the newest 2.x release on GitHub; the opencode.ai install script only installs
opencode 1). Both auto-updaters are disabled; rebuild to upgrade.

## Configure

```sh
cp .env.example .env
# edit .env: set GITLAB_HOST, GITLAB_TOKEN, git identity, and (optionally) a Claude credential
```

The GitLab token needs the `api`, `read_repository` and `write_repository`
scopes to clone, push, and manage merge requests and issues.

## Run

`run.sh` wraps the `sudo podman run` command below. Run it as your normal
user; it calls `sudo` itself and reads your Claude login from your home:

```sh
./run.sh -e .env.apo                # shell (default env file: .env)
./run.sh -e .env.apo claude         # Claude Code TUI
./run.sh -e .env.apo opencode       # opencode TUI
./run.sh -b -e .env.apo             # rebuild the image first (built anyway if missing)
./run.sh -p -e .env.apo             # keep state between runs (see Persistence)
./run.sh -n -e .env.apo             # don't use the host's Claude / opencode logins
./run.sh -h                         # all options
```

By default `run.sh` bind-mounts your host's `~/.claude/.credentials.json`, so
Claude Code in the container uses the same subscription login as the host. The
host and container share that one file, including token refreshes. This is the
one exception to "nothing from the host is mounted". `dev` has your UID, so it
can read that owner-only file; with `-p` the volume is mounted with `:U` so it
is owned by `dev` too.

If opencode is installed on the host (on `PATH` or in `~/.opencode/bin`),
`run.sh` also exports its credentials with `opencode auth export` into a
temporary file (in `$XDG_RUNTIME_DIR`), mounts it read-only at
`/run/secrets/opencode-auth.json`, and the entrypoint imports it into the
container's opencode. The file is deleted when the container exits. opencode
keeps credentials in a database, so this is a copy rather than a shared file:
logins and token refreshes in the container do not reach the host.

Each container gets its own network namespace (Podman's default network, not
`--network=host`), so several sessions can run at once and open the same ports
without clashing. Outbound traffic, including VPN routes, goes through the host
as usual; services on the host are reachable at `host.containers.internal`.

Every `run.sh` session starts fresh: `~/.claude` is empty (no history,
sessions or settings from earlier runs) and is discarded on exit. Pass `-p` to
use the `claude-config` volume instead (see Persistence).

Interactive shell, by hand:

```sh
sudo podman run --rm -it --env-file .env \
  --security-opt label=disable --security-opt apparmor=unconfined \
  -v claude-config:/home/dev/.claude:U \
  claude-glab
```

The two `--security-opt` flags are what Podman inside the container needs (see
[Containers inside the container](#containers-inside-the-container)).

Inside the shell, clone and work, then start the agent:

```sh
glab repo clone group/project
cd project
claude                    # TUI, or: claude -p "Review the open MRs"
opencode                  # TUI, or: opencode run --auto "Review the open MRs"
```

Non-interactive, one-shot agent run (clone, act, exit):

```sh
sudo podman run --rm --env-file .env \
  --security-opt label=disable --security-opt apparmor=unconfined \
  -v claude-config:/home/dev/.claude:U \
  claude-glab bash -lc \
  'glab repo clone group/project && cd project && \
   claude -p --allowedTools "Bash(glab:*) Bash(git:*) Read Grep Glob" \
     "Review every open merge request and post a summary as a comment"'
```

`claude -p` has nobody to answer permission prompts, so grant the tools it needs
with `--allowedTools`, or, since the container is already the sandbox, skip
prompts entirely with `--dangerously-skip-permissions` (allowed because `dev` is
not root).

Example tasks this image supports:

```sh
glab repo clone group/project            # fetch code from GitLab
glab mr create --fill --yes              # open a merge request from the current branch
glab mr list --review-requested          # review queue
glab issue list --label needs-triage     # triage queue
claude -p "Triage the unlabelled issues in this project"
```

## Persistence

`run.sh` keeps nothing between runs unless you pass `-p`. With `-p` (and in
the manual `podman run` examples) one named volume keeps Claude Code state
across `--rm` runs:

| Volume          | Path        | Holds                                                    |
| --------------- | ----------- | -------------------------------------------------------- |
| `claude-config` | `~/.claude` | login, `.claude.json`, `settings.json`, sessions, history |
| `opencode-data` | `~/.local/share/opencode` | opencode credentials, sessions, history (database) |

The image sets `CLAUDE_CONFIG_DIR=~/.claude`, which moves `.claude.json`
(normally at `~/.claude.json`) inside that directory, so one volume covers
everything. The volumes live in root's Podman storage; `:U` keeps them owned by
`dev`. Rename them with `VOLUME=` / `OC_VOLUME=`, and remove them with
`sudo podman volume rm claude-config opencode-data`.

## How credentials work

At container start, `entrypoint.sh` maps your environment onto git config:

- `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` (and the `GIT_COMMITTER_*` pair) become
  the commit identity.
- The `glab` credential helper is registered for `GITLAB_HOST` **only**. `glab
  auth git-credential` answers with the GitLab token for whichever host it is
  asked about, so registering it globally (the common advice) would hand
  `GITLAB_TOKEN` to any HTTPS remote such as `github.com`. Scoping prevents that.
- `GITLAB_HOST` and `GITLAB_TOKEN` are also written to glab's own config
  (`~/.config/glab-cli/config.yml`). Agent tooling sometimes runs commands in a
  shell that does not inherit the container environment; without this, glab falls
  back to the default `gitlab.com` and finds no token. The environment still wins
  when it is present.

`GITLAB_HOST` defaults to `gitlab.com`; for a self-managed instance set it to
the hostname, for example `gitlab.example.com`.

`GIT_TERMINAL_PROMPT=0` is set so git fails fast instead of hanging when
credentials are missing. Override it in `.env` if you want prompts.

## Claude Code credentials

`run.sh` reuses the host login by default (see Run). Otherwise choose one:

- **Subscription (Pro/Max), interactive:** leave the Claude variables unset,
  run `claude` and use `/login`. The login is saved in the `claude-config`
  volume.
- **Subscription, headless:** run `claude setup-token` on a machine where you
  are logged in and put the token in `.env` as `CLAUDE_CODE_OAUTH_TOKEN`.
- **API key:** set `ANTHROPIC_API_KEY` in `.env`.

Check which one is in use with `/status` inside `claude`.

## opencode credentials

`run.sh` copies the host's opencode credentials by default (see Run). Otherwise
log in inside the container with `opencode auth login`, or set the provider's
API key in `.env` (for example `ANTHROPIC_API_KEY`). Check with
`opencode auth list`.

## Agent guidance

The image installs `claude-config/CLAUDE.md` as the system-wide memory file
`/etc/claude-code/CLAUDE.md`, which Claude Code loads in every session. It tells the agent that `glab` is already authenticated, to read the host with
`glab config get host` instead of assuming `gitlab.com`, which `glab` commands to
use, to pass non-interactive flags, that it has no `sudo`, and how to use
`podman`. Because it lives outside `~/.claude`, the
volume never hides or freezes it. Edit the file and rebuild to change it; use
`~/.claude/CLAUDE.md` (in the volume) for personal additions.

Confirm it is loaded with `/memory` inside `claude`.

opencode does not read `/etc/claude-code`, and stops looking for project rules
at the git root. At start-up `entrypoint.sh` therefore writes
`~/.config/opencode/AGENTS.md`, its global rules file, with the same guidance
followed by this session's facts (below), so opencode gets them in every clone.

At start-up `entrypoint.sh` also writes `~/work/CLAUDE.md` with the values of
this run: the GitLab host, whether a token is set, and the commit identity.
Claude Code loads it when started in `~/work` or a clone below it. Together the two files mean the
agent knows the environment from the first prompt, without looking anything up.

## What's inside

`git`, `glab`, `claude`, `opencode`, `podman` (with `crun`, `conmon`, `uidmap`, `passt`,
`catatonit`), `jq`, `ripgrep`, `openssh-client`, `curl`, `procps`. Claude Code
is installed with the official native installer, opencode from its GitHub
release tarball.

## Limits on the agent

The agent runs as `dev`, which has no `sudo` (the package is not installed) and
a locked password, so it cannot become root in the container: no `apt-get`, no
changes to `/etc`, `/usr` or other users' files. It can write to its home, the
working directory and `/tmp`, and run containers with rootless Podman. Tools
it needs at run time come from container images or as binaries in
`~/.local/bin`.

To do something as root in a running session, open a root shell from the host:

```sh
sudo podman ps                                   # find the container name
sudo podman exec -it -u root <name> bash
```

The outer container is rootful but not privileged: it keeps Podman's default
capabilities and seccomp profile, and has no user namespace, so `dev` is your
UID on the host. It only drops AppArmor confinement and SELinux labelling
(`apparmor=unconfined`, `label=disable`), which would otherwise block the mounts
nested Podman makes. Nothing in the container runs as root (the entrypoint
runs as `dev` too), and `dev` has no way to use root's capabilities.

## Containers inside the container

`dev` runs Podman rootless, inside the outer container:

- `newuidmap`/`newgidmap` carry file capabilities (`cap_setuid`/`cap_setgid`)
  instead of the setuid bit. Setuid root fails to write the nested ID maps when
  the container has no `CAP_SYS_ADMIN`.
- `dev` owns subordinate UIDs/GIDs 1–65535 except its own (`/etc/subuid`,
  `/etc/subgid`), the layout of the upstream `quay.io/podman/stable` image.
- `/etc/containers/containers.conf` (from `containers/containers.conf`)
  disables cgroups (no systemd in here) and shares the outer container's
  network, IPC and UTS namespaces with nested containers. Ports a nested
  container opens are ports of the outer container, so `localhost` reaches them
  without `-p`. `~/.config/containers/containers.conf` bind-mounts `/proc`,
  because the kernel will not mount a fresh `/proc` under the outer container's
  masked one.
- Nested storage (`~/.local/share/containers`) is an anonymous volume, since
  overlay upper dirs cannot sit on the container's own overlay root. `--rm`
  deletes it, so pulled images and built containers are gone after each run.
  It uses native overlay, so no `/dev/fuse` is needed.
