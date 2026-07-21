# devcon

A personal, self-contained **dev environment container**, for my own use.

An encapsulated place to work, so anything the tooling does stays inside the
container instead of touching the host.

Bundles:

- **git** + **GitHub CLI** (`gh`)
- **Claude Code** (`claude`)
- **code-server** — VS Code in the browser
- **sshd** — key-only SSH (use a terminal or VS Code Remote-SSH)
- **rootless Podman** — `docker`/`docker compose` inside the container (no daemon on the host)

Built on `ghcr.io/linuxserver/code-server` for a maintained code-server with s6
init and `PUID`/`PGID` handling, so files created in the volume are owned by my
own user, not root.

## Image

Built and pushed automatically to `ghcr.io/dermute/devcon:latest` by GitHub
Actions — on every push to `main`, weekly (to pick up base image, Node and
Claude Code updates), and on manual dispatch. Multi-arch: `linux/amd64` +
`linux/arm64`.

## Run

```bash
cp .env.example .env      # set DEVCON_PASSWORD, ports, config path
docker compose up -d
```

Then:

- **code-server** → `http://<host>:8443` (password from `.env`)
- **ssh** → `ssh -p 2222 <DEVCON_USER>@<host>` (`abc` by default)

### SSH access

Key-only by default. Provide a public key one of two ways:

```bash
# via .env — installed into authorized_keys on startup
DEVCON_SSH_PUBKEY="ssh-ed25519 AAAA... you@host"

# or drop it into the volume yourself
cat ~/.ssh/id_ed25519.pub >> <config>/.ssh/authorized_keys
```

To use a password instead, set `DEVCON_SSH_PASSWORD_AUTH=true` and
`DEVCON_SSH_PASSWORD=...` in `.env`. Key auth stays enabled alongside it.

### Docker (rootless Podman)

Docker inside the container is provided by **rootless Podman** — no daemon on the
host, no host Docker socket. The `docker` command, `docker compose`, and a
`DOCKER_HOST` socket all work out of the box:

```bash
docker run --rm hello-world
docker build -t myapp .
docker compose up -d
```

- `docker` is a shim over `podman`; `podman` works directly too.
- Images and containers persist under `/config` (the volume), so they survive rebuilds.
- `DOCKER_HOST` points at a rootless Podman API socket, so tools that speak the
  Docker API (the VS Code Docker extension, testcontainers, `docker compose` v2) work.
- Set `DEVCON_DOCKER=false` in `.env` to turn the API socket off.

This needs the `security_opt` (`seccomp`/`apparmor`/`label` unconfined) and the
`/dev/fuse` device already set in `docker-compose.yml`. That is **not** `--privileged`
and grants no host or host-daemon access — nested containers run rootless and stay
confined to devcon.

### First-run auth (inside the container)

```bash
gh auth login       # GitHub
claude              # Claude Code — follow the login flow
```

Both persist under the `/config` volume, so they survive rebuilds.

## Configuration

| Env var                    | Default     | Purpose                                              |
|----------------------------|-------------|------------------------------------------------------|
| `DEVCON_PASSWORD`          | —           | code-server web password                             |
| `DEVCON_WEB_PORT`          | `8443`      | host port for the code-server UI                     |
| `DEVCON_SSH_PORT`          | `2222`      | host port for ssh                                    |
| `DEVCON_CONFIG`            | `/.config`  | host path for the persisted `/config`                |
| `DEVCON_USER`              | `abc`       | login username inside the container                  |
| `DEVCON_PUID` / `DEVCON_PGID` | `1000`/`100` | user/group id that owns files in the volume       |
| `DEVCON_SSH_PUBKEY`        | —           | public key installed into `authorized_keys`          |
| `DEVCON_SSH_PASSWORD_AUTH` | `false`     | allow ssh password login (else key-only)             |
| `DEVCON_SSH_PASSWORD`      | —           | login user's ssh password (when password auth is on) |
| `DEVCON_DOCKER`            | `true`      | rootless podman API socket + `DOCKER_HOST`           |
| `GIT_USER_NAME`            | —           | `git config --global user.name`                      |
| `GIT_USER_EMAIL`           | —           | `git config --global user.email`                     |

## Notes

- No `privileged` and no host Docker socket mounted — the container can't reach the
  host or the host Docker daemon. Docker inside is rootless Podman, confined to the
  container. It's host-package isolation, not a security sandbox against hostile code.
- Rootless Podman does require the `security_opt` (`seccomp`/`apparmor`/`label`
  unconfined) and `/dev/fuse` device in `docker-compose.yml` — a much smaller
  relaxation than `--privileged`, with no host reach.
- To update: `docker compose pull && docker compose up -d`.
