# devcon

A personal, self-contained **dev environment container**, for my own use.

An encapsulated place to work, so anything the tooling does stays inside the
container instead of touching the host.

Bundles:

- **git** + **GitHub CLI** (`gh`)
- **Claude Code** (`claude`)
- **code-server** — VS Code in the browser
- **sshd** — key-only SSH (use a terminal or VS Code Remote-SSH)

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
- **ssh** → `ssh -p 2222 abc@<host>`

### SSH access

Key-only. Drop your public key into the volume before connecting:

```bash
cat ~/.ssh/id_ed25519.pub >> <config>/.ssh/authorized_keys
```

### First-run auth (inside the container)

```bash
gh auth login       # GitHub
claude              # Claude Code — follow the login flow
```

Both persist under the `/config` volume, so they survive rebuilds.

## Configuration

| Env var          | Default     | Purpose                                  |
|------------------|-------------|------------------------------------------|
| `DEVCON_PASSWORD`| —           | code-server web password                 |
| `DEVCON_WEB_PORT`| `8443`      | host port for the code-server UI         |
| `DEVCON_SSH_PORT`| `2222`      | host port for ssh                        |
| `DEVCON_CONFIG`  | `/.config`  | host path for the persisted `/config`    |
| `GIT_USER_NAME`  | —           | `git config --global user.name`          |
| `GIT_USER_EMAIL` | —           | `git config --global user.email`         |
| `PUID` / `PGID`  | `1000`/`100`| user/group that owns files in the volume |

## Notes

- No `privileged`, no Docker socket mounted — the container can't reach the host
  or the Docker daemon. It's host-package isolation, not a security sandbox
  against hostile code.
- To update: `docker compose pull && docker compose up -d`.
