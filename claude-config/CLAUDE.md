# GitLab environment

This container ships an authenticated GitLab CLI (`glab`) and a `git` that is
already wired to it. Use `glab` for GitLab work instead of the web UI or raw
REST calls.

## Credentials are already configured

- `glab` is authenticated. Do **not** run `glab auth login`.
- The GitLab host is not necessarily `gitlab.com`. `~/work/CLAUDE.md` names the
  host for this session; `glab config get host` reports it too. Never assume
  the default.
- `glab auth status` shows the current authentication.
- `git clone` / `git push` over HTTPS work for that host through glab's
  credential helper, with no extra setup. The token is offered to that host
  only, so other HTTPS remotes need their own credentials.
- Do not change credentials or identity (`git config`, `glab config set`); the
  environment provides them.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `GITLAB_HOST` | GitLab hostname used by `glab` and the git credential helper |
| `GITLAB_TOKEN` | Access token for `glab` and git over HTTPS. Never print or log it |
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | Commit identity, also in `git config` |
| `NO_PROMPT` | `1` makes `glab` fail instead of prompting |
| `NO_COLOR` | Any value turns off ANSI colors in `glab` output |

The host and token are also stored in glab's own config, so `glab` works in
shells that do not inherit the environment. Environment variables win when set.

## Which project glab acts on

- Inside a clone, `glab` uses the project and host of the clone's remote.
- Anywhere else (including `~/work` itself), name the project with
  `-R <group>/<project>`, for example `glab mr list -R group/project`.
- Clone into `~/work` with `glab repo clone <group>/<project>` (HTTPS).
- When a subcommand is missing, use `glab api <endpoint>`; it already knows the
  host and token.

## Common tasks

- Clone: `glab repo clone <group>/<project>`
- Merge requests: `glab mr list`, `glab mr view <id>`, `glab mr diff <id>`,
  `glab mr checkout <id>`, `glab mr create --fill --yes`, `glab mr note <id>`,
  `glab mr approve <id>`
- Issues and triage: `glab issue list`, `glab issue view <id>`,
  `glab issue note <id>`, `glab issue update <id>`
- Pipelines: `glab ci list`, `glab ci status`, `glab ci view`, `glab ci trace <job>`
- Discovery: `glab <group> --help`, for example `glab mr --help`

## Non-interactive expectations

- There is no TTY. Pass explicit flags (`--yes`, `--fill`, `--title`,
  `--description`, `--label`) instead of relying on prompts. Set
  `NO_PROMPT=1` if a command still tries to prompt.
- Repositories cloned inside the container are ephemeral. Re-clone when needed
  and do not expect an earlier clone to still be present. Push branches or post
  comments before finishing; nothing else survives the session.
- The container has its own network namespace. Ports you open do not clash
  with other sessions and are not reachable from the host. Services on the host
  are at `host.containers.internal`.

## You are an unprivileged user

You run as `dev`, with no `sudo` and no root password. You cannot install
system packages (`apt-get`) or write outside your home directory and `/tmp`. Do
not try to work around this; if the task needs a system change, say so.

Already installed: `git`, `glab`, `claude`, `podman`, `jq`, `ripgrep`
(`rg`), `curl`, `less`, `openssh-client`. Prefer these before adding an
alternative. When you need something else:

- Run it in a container (see below), for example
  `podman run --rm -v "$PWD:/src:Z" -w /src docker.io/library/node:22 npm test`.
- Or download a standalone binary into `~/.local/bin` and `chmod +x` it.

Everything you add disappears when the session ends. If a tool is needed on
every run, note that it should be added to the image.

## Containers

`podman` works for `dev` (rootless, inside this container): `podman run`,
`podman build`, `podman ps` and so on, with no `sudo`.

- Use fully qualified image names (`docker.io/library/alpine`), so nothing
  prompts for a registry.
- Nested containers share this container's network: a port a container listens
  on is reachable here at `localhost`, without `-p`.
- Resource limits (`--memory`, `--cpus`) are not available; cgroups are disabled.
- Images and containers are deleted with the session.

## Conventions

- Prefer `glab` over `curl` against the GitLab API; the host and token are handled
  for you.
- When opening a merge request, describe what changed and why, and reference the
  related issue when one exists.
- `jq` and `ripgrep` (`rg`) are installed for JSON and code searching.
