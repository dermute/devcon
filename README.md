# devcon

A personal, self-contained **dev environment container**, for my own use.

An encapsulated place to work, so anything the tooling does stays inside the
container instead of touching the host.

Bundles:

- **git** + **GitHub CLI** (`gh`)
- **Claude Code** (`claude`) + **Codex CLI** (`codex`)
- **network diagnostics** — `ping` and `nslookup`
- **Python tooling** — `python3`, `pip`, and `venv`; compiler support for Python and npm native modules
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
- `docker compose` is upstream **Compose v2** (the distro package, so it tracks the
  base image on each weekly rebuild — no pinned version), driving the Podman socket
  via `DOCKER_HOST`. podman-compose is installed as a fallback provider.
- Images and containers persist under `/config` (the volume), so they survive rebuilds.
- `DOCKER_HOST` points at a rootless Podman API socket, so other tools that speak
  the Docker API — the VS Code Docker extension, testcontainers — work too.
- Set `DEVCON_DOCKER=false` in `.env` to turn the API socket off.

This needs the `security_opt` (`seccomp`/`apparmor`/`label` unconfined) and the
`/dev/fuse` device already set in `docker-compose.yml`. That is **not** `--privileged`
and grants no host or host-daemon access — nested containers run rootless and stay
confined to devcon.

### First-run auth (inside the container)

```bash
gh auth login       # GitHub
claude              # Claude Code — follow the login flow
codex               # Codex CLI — follow the login flow
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
- Passwords are passed as env vars, so `DEVCON_PASSWORD` / `DEVCON_SSH_PASSWORD`
  are visible in `docker inspect` and to any process in the container. Fine for a
  personal box; use compose `secrets` if that ever stops being true.
- `DEVCON_USER` must be a normal lowercase login name — `root` and malformed
  names are rejected at startup and fall back to `abc`.
- To update: `docker compose pull && docker compose up -d`.

## AI attribution

This project was developed with AI assistance.

<div style="display: flex; align-items: center; white-space: nowrap; gap: 0.5rem; padding: 8px;">
  <div style="font-family: IBM Plex Sans; font-weight: 400; font-size: 16px; line-height: 22px; letter-spacing: 0px;">
    <a rel="noopener noreferrer" href="https://aiattribution.github.io/statements/AIA-EAI-Hin-Nr-?model=Opus%204.8-v1.0" data-cy="recommended-attribution-statement-text" target="_blank" style="font-family: IBM Plex Sans; font-weight: 400; font-size: 16px; line-height: 22px; letter-spacing: 0px;">AIA EAI Hin Nr Opus 4.8 v1.0 </a>
  </div>
  <div style="display: flex; gap: 0.5rem;">
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <g clip-path="url(#clip0_50_2)">
        <path d="M12 23.5C18.3513 23.5 23.5 18.3513 23.5 12C23.5 5.64873 18.3513 0.5 12 0.5C5.64873 0.5 0.5 5.64873 0.5 12C0.5 18.3513 5.64873 23.5 12 23.5Z" fill="#4E4E4E" stroke="#161616">
        </path>
        <path d="M13.6471 15.6L13.1471 13.94H10.8171L10.3171 15.6H8.77715L11.0771 8.61998H12.9571L15.2271 15.6H13.6471ZM11.9971 9.99998H11.9471L11.1771 12.65H12.7771L11.9971 9.99998Z" fill="white">
        </path>
      </g>
      <defs>
        <clipPath id="clip0_50_2">
          <rect width="24" height="24" fill="white">
          </rect>
        </clipPath>
      </defs>
    </svg>
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M18 17H16.5V16H18V8H16.5V7H18C18.2651 7.0003 18.5193 7.10576 18.7068 7.29323C18.8942 7.4807 18.9997 7.73488 19 8V16C18.9996 16.2651 18.8942 16.5193 18.7067 16.7067C18.5193 16.8942 18.2651 16.9996 18 17Z" fill="#161616">
      </path>
      <path d="M15.5 13C16.0523 13 16.5 12.5523 16.5 12C16.5 11.4477 16.0523 11 15.5 11C14.9477 11 14.5 11.4477 14.5 12C14.5 12.5523 14.9477 13 15.5 13Z" fill="#161616">
      </path>
      <path d="M12 13C12.5523 13 13 12.5523 13 12C13 11.4477 12.5523 11 12 11C11.4477 11 11 11.4477 11 12C11 12.5523 11.4477 13 12 13Z" fill="#161616">
      </path>
      <path d="M8.5 13C9.05228 13 9.5 12.5523 9.5 12C9.5 11.4477 9.05228 11 8.5 11C7.94772 11 7.5 11.4477 7.5 12C7.5 12.5523 7.94772 13 8.5 13Z" fill="#161616">
      </path>
      <path d="M7.5 17H6C5.73488 16.9997 5.4807 16.8942 5.29323 16.7068C5.10576 16.5193 5.0003 16.2651 5 16V8C5.00026 7.73486 5.10571 7.48066 5.29319 7.29319C5.48066 7.10571 5.73486 7.00026 6 7H7.5V8H6V16H7.5V17Z" fill="#161616">
      </path>
      <circle cx="12" cy="12" r="11.5" stroke="#161616">
      </circle>
      <circle cx="12" cy="12" r="11.5" stroke="#161616">
      </circle>
    </svg>
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="12" cy="12" r="11.5" stroke="#161616">
      </circle>
      <path d="M10 6C10.4945 6 10.9778 6.14662 11.3889 6.42133C11.8 6.69603 12.1205 7.08648 12.3097 7.54329C12.4989 8.00011 12.5484 8.50277 12.452 8.98773C12.3555 9.47268 12.1174 9.91814 11.7678 10.2678C11.4181 10.6174 10.9727 10.8555 10.4877 10.952C10.0028 11.0484 9.50011 10.9989 9.04329 10.8097C8.58648 10.6205 8.19603 10.3 7.92133 9.88893C7.64662 9.4778 7.5 8.99445 7.5 8.5C7.5 7.83696 7.76339 7.20107 8.23223 6.73223C8.70107 6.26339 9.33696 6 10 6ZM10 5C9.30777 5 8.63108 5.20527 8.0555 5.58986C7.47993 5.97444 7.03133 6.52107 6.76642 7.16061C6.50151 7.80015 6.4322 8.50388 6.56725 9.18282C6.7023 9.86175 7.03564 10.4854 7.52513 10.9749C8.01461 11.4644 8.63825 11.7977 9.31718 11.9327C9.99612 12.0678 10.6999 11.9985 11.3394 11.7336C11.9789 11.4687 12.5256 11.0201 12.9101 10.4445C13.2947 9.86892 13.5 9.19223 13.5 8.5C13.5 7.57174 13.1313 6.6815 12.4749 6.02513C11.8185 5.36875 10.9283 5 10 5Z" fill="#161616">
      </path>
      <path d="M15 19H14V16.5C14 15.837 13.7366 15.2011 13.2678 14.7322C12.7989 14.2634 12.163 14 11.5 14H8.5C7.83696 14 7.20107 14.2634 6.73223 14.7322C6.26339 15.2011 6 15.837 6 16.5V19H5V16.5C5 15.5717 5.36875 14.6815 6.02513 14.0251C6.6815 13.3687 7.57174 13 8.5 13H11.5C12.4283 13 13.3185 13.3687 13.9749 14.0251C14.6313 14.6815 15 15.5717 15 16.5V19Z" fill="#161616">
      </path>
      <path d="M19.9592 9.99025L19.3932 9.42432L17.938 10.8796L16.4827 9.42432L15.9167 9.99025L17.372 11.4455L15.9167 12.9008L16.4827 13.4667L17.938 12.0115L19.3932 13.4667L19.9592 12.9008L18.5039 11.4455L19.9592 9.99025Z" fill="#161616">
      </path>
    </svg>
  </div>
</div>
