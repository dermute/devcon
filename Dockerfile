# syntax=docker/dockerfile:1
# Dev environment container — git + gh + Claude Code + Codex CLI + code-server + sshd.
#
# Base: LinuxServer's code-server image. It already ships a working code-server
# with s6-overlay init and PUID/PGID handling, so files created in the mounted
# volume are owned by my own user instead of root. It is Ubuntu-based because
# code-server needs glibc (the Alpine/musl route is impractical). We add the
# GitHub CLI, Node-based AI CLIs, and an sshd service on top.
#
# NOTE: requires BuildKit (default on Docker 23+) for the heredoc RUN/COPY below.
FROM ghcr.io/linuxserver/code-server:latest

# ---- toolchain --------------------------------------------------------------
RUN <<'PKG'
set -e
export DEBIAN_FRONTEND=noninteractive
# GitHub CLI apt repo
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
# Node 22 (for Claude Code)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get update
apt-get install -y --no-install-recommends \
    git gh openssh-server nodejs ca-certificates screen vim \
    less tree file zip unzip ripgrep fd-find jq \
    curl wget iproute2 netcat-openbsd traceroute \
    dnsutils iputils-ping \
    procps lsof strace htop \
    bash-completion fzf direnv shellcheck bubblewrap \
    python3 python3-dev python3-pip python3-venv build-essential \
    podman podman-docker uidmap fuse-overlayfs slirp4netns \
    netavark aardvark-dns podman-compose docker-compose-v2
npm install -g @anthropic-ai/claude-code @openai/codex
npm cache clean --force
rm -rf /var/lib/apt/lists/*
PKG

# ---- rootless podman config (the "docker" inside the container) -------------
# Nested containers run rootless as the login user; storage lands on the /config
# volume (a real host fs), so there is no overlay-on-overlay. See docker-compose.yml
# for the seccomp/apparmor/fuse relaxations the outer container needs.
#
# Debian/Ubuntu podman ships no default search registry — without this,
# `podman run hello-world` fails on short-name resolution.
COPY <<'REG' /etc/containers/registries.conf
unqualified-search-registries = ["docker.io"]
REG

# Force fuse-overlayfs for deterministic rootless storage across kernels
# (pairs with the /dev/fuse device mapped in docker-compose.yml).
COPY <<'STORE' /etc/containers/storage.conf
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
STORE

# No systemd/dbus in this image: use the cgroupfs manager and a file event log.
# compose_providers puts upstream Compose v2 ahead of podman-compose. It must be
# the absolute plugin path: the Ubuntu docker-compose-v2 package installs only
# /usr/libexec/..., nothing on PATH, so podman's PATH-based default lookup would
# silently fall through to podman-compose instead.
COPY <<'ENGINE' /etc/containers/containers.conf
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
compose_providers = ["/usr/libexec/docker/cli-plugins/docker-compose", "podman-compose"]
ENGINE

# Silence the podman-docker "emulating docker" banner on every `docker` call.
RUN touch /etc/containers/nodocker

# Ubuntu calls the fd utility "fdfind" to avoid a name collision; expose the
# conventional command name used by most documentation and editor integrations.
RUN ln -s /usr/bin/fdfind /usr/local/bin/fd

# The docker-compose-v2 package installs only the CLI plugin, nothing on PATH.
# Symlink it so `docker-compose ...` works directly as well as `docker compose ...`.
RUN ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

# shared helpers for the init script and the podman service
COPY --chmod=644 <<'LIB' /usr/local/lib/devcon.sh
# permissive boolean parser — "true", "True", "yes", "on" and "1" all count
is_true() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) return 0 ;;
        *)                                        return 1 ;;
    esac
}
LIB

# ---- add an sshd service to the existing s6 stack ---------------------------
RUN <<'SETUP'
set -e
# give the abc login user a home on the /config volume and a real shell for ssh,
# so ssh sessions, the code-server terminal and git all share one persisted HOME
awk -F: 'BEGIN{OFS=":"} $1=="abc"{$6="/config";$7="/bin/bash"} {print}' /etc/passwd > /etc/passwd.tmp \
    && mv /etc/passwd.tmp /etc/passwd
mkdir -p /etc/s6-overlay/s6-rc.d/svc-sshd/dependencies.d \
         /etc/s6-overlay/s6-rc.d/svc-podman/dependencies.d \
         /etc/s6-overlay/s6-rc.d/user/contents.d \
         /custom-cont-init.d
echo longrun > /etc/s6-overlay/s6-rc.d/svc-sshd/type
echo longrun > /etc/s6-overlay/s6-rc.d/svc-podman/type
# Order after the init chain: /custom-cont-init.d/10-dev-init generates the sshd
# config and the podman prerequisites (subuid ranges, /run/user/<uid>). Without
# this both services race init — sshd restart-loops on a missing config, and a
# podman process holding the "abc" account makes the DEVCON_USER rename fail.
touch /etc/s6-overlay/s6-rc.d/svc-sshd/dependencies.d/init-services
touch /etc/s6-overlay/s6-rc.d/svc-podman/dependencies.d/init-services
# enable the services by adding them to the default "user" bundle
touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-sshd
touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-podman
SETUP

# sshd: runs as root (it drops to the login user on login). The config is
# generated at runtime by 10-dev-init below, because the allowed username and
# the password-auth toggle are both env-driven.
COPY --chmod=755 <<'SSHRUN' /etc/s6-overlay/s6-rc.d/svc-sshd/run
#!/usr/bin/with-contenv bash
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config.dev
SSHRUN

# rootless podman API socket → DOCKER_HOST. Runs as the login user; gated by
# DEVCON_DOCKER so it can be turned off without a crash loop. 10-dev-init has
# already created /run/user/<uid> and the subuid/subgid ranges by now.
COPY --chmod=755 <<'PODRUN' /etc/s6-overlay/s6-rc.d/svc-podman/run
#!/usr/bin/with-contenv bash
. /usr/local/lib/devcon.sh
if ! is_true "${DEVCON_DOCKER:-true}"; then
    # idle instead of exiting, so s6 does not treat this as a crash loop
    command -v s6-pause >/dev/null && exec s6-pause
    exec sleep infinity
fi
# 10-dev-init resolved and validated the login user; reuse its answer
login_user="$(cat /run/devcon/login-user)"
uid="$(id -u "$login_user")"
exec s6-setuidgid "$login_user" \
    env HOME=/config XDG_RUNTIME_DIR="/run/user/${uid}" \
    podman system service --time=0 "unix:///run/user/${uid}/podman/podman.sock"
PODRUN

# ---- one-shot init: user rename, ssh config/keys, git identity, ownership ---
COPY --chmod=755 <<'INIT' /custom-cont-init.d/10-dev-init
#!/usr/bin/with-contenv bash
set -e
. /usr/local/lib/devcon.sh

# ---- optional: rename the login user (default stays "abc") ------------------
# The base image hardcodes "abc" in its own s6 service scripts, so we rename the
# account in place (keeping its uid/gid) and append a compat "abc" entry pointing
# at the same uid/gid. That way `getpwnam abc` still resolves for base-image
# scripts, while the renamed entry stays first so prompts/whoami show the new
# name. Runs before any service starts, so no process is using the account yet.
LOGIN_USER="${DEVCON_USER:-abc}"
# reject names that would break the sshd config or lock us out ("root" would end
# up in AllowUsers while PermitRootLogin stays no)
if [ "$LOGIN_USER" = root ] || ! printf '%s' "$LOGIN_USER" | grep -qE '^[a-z_][a-z0-9_-]*$'; then
    echo "[devcon] invalid DEVCON_USER '${LOGIN_USER}'; falling back to abc" >&2
    LOGIN_USER=abc
fi
if [ "$LOGIN_USER" != "abc" ] && id abc >/dev/null 2>&1 && ! id "$LOGIN_USER" >/dev/null 2>&1; then
    abc_uid=$(id -u abc)
    abc_gid=$(id -g abc)
    usermod -l "$LOGIN_USER" abc
    usermod -d /config -s /bin/bash "$LOGIN_USER"
    grep -q '^abc:' /etc/passwd \
        || echo "abc:x:${abc_uid}:${abc_gid}:devcon compat:/config:/bin/bash" >> /etc/passwd
fi
# publish the resolved name/uid so svc-podman uses the same answer (PUID has
# already been applied by the base image's init-adduser at this point)
login_uid="$(id -u "$LOGIN_USER")"
mkdir -p /run/devcon
printf '%s' "$LOGIN_USER" > /run/devcon/login-user

# ---- ssh: host keys + authorized_keys (with optional env pubkey passthrough) -
mkdir -p /config/ssh /config/.ssh
# persistent host keys (generated once, reused after)
[ -f /config/ssh/ssh_host_ed25519_key ] || ssh-keygen -t ed25519 -f /config/ssh/ssh_host_ed25519_key -N ""
[ -f /config/ssh/ssh_host_rsa_key ]     || ssh-keygen -t rsa -b 4096 -f /config/ssh/ssh_host_rsa_key -N ""
touch /config/.ssh/authorized_keys
if [ -n "${DEVCON_SSH_PUBKEY:-}" ]; then
    grep -qxF "$DEVCON_SSH_PUBKEY" /config/.ssh/authorized_keys \
        || echo "$DEVCON_SSH_PUBKEY" >> /config/.ssh/authorized_keys
fi
lsiown -R abc:abc /config/ssh /config/.ssh   # "abc" still resolves to the login uid/gid
chmod 700 /config/.ssh
chmod 600 /config/.ssh/authorized_keys

# ---- ssh password auth (default OFF = key-only) -----------------------------
if is_true "${DEVCON_SSH_PASSWORD_AUTH:-false}"; then pw_auth=yes; else pw_auth=no; fi
if [ "$pw_auth" = yes ]; then
    if [ -n "${DEVCON_SSH_PASSWORD:-}" ]; then
        echo "${LOGIN_USER}:${DEVCON_SSH_PASSWORD}" | chpasswd
    else
        echo "[devcon] DEVCON_SSH_PASSWORD_AUTH is on but DEVCON_SSH_PASSWORD is empty; staying key-only" >&2
        pw_auth=no
    fi
fi

# ---- generate sshd config (username + password toggle are runtime-driven) ---
# SetEnv, so `ssh devcon docker ps` (a non-login, non-interactive shell that
# sources neither /etc/profile nor /etc/bash.bashrc) still finds the socket
if is_true "${DEVCON_DOCKER:-true}"; then
    ssh_setenv="SetEnv XDG_RUNTIME_DIR=/run/user/${login_uid} DOCKER_HOST=unix:///run/user/${login_uid}/podman/podman.sock"
else
    ssh_setenv="SetEnv XDG_RUNTIME_DIR=/run/user/${login_uid}"
fi
cat > /etc/ssh/sshd_config.dev <<EOF
Port 22
AddressFamily any
# host keys live on the volume so they survive image rebuilds
HostKey /config/ssh/ssh_host_ed25519_key
HostKey /config/ssh/ssh_host_rsa_key
PermitRootLogin no
PasswordAuthentication ${pw_auth}
PubkeyAuthentication yes
AuthorizedKeysFile /config/.ssh/authorized_keys
AllowUsers ${LOGIN_USER}
UsePAM no
PidFile /config/ssh/sshd.pid
Subsystem sftp /usr/lib/openssh/sftp-server
${ssh_setenv}
EOF

# ---- rootless podman: subuid/subgid, runtime dir, storage, docker env -------
# subordinate id ranges the login user needs to map nested-container ids
# (rewritten each boot: /etc resets and the user may be renamed via DEVCON_USER)
printf '%s:100000:65536\n' "$LOGIN_USER" > /etc/subuid
printf '%s:100000:65536\n' "$LOGIN_USER" > /etc/subgid
# XDG_RUNTIME_DIR — no pam_systemd here to create /run/user/<uid>
mkdir -p "/run/user/${login_uid}"
lsiown abc:abc "/run/user/${login_uid}"   # "abc" resolves to the login uid/gid
chmod 700 "/run/user/${login_uid}"
# Persist podman image/container storage + config on the /config volume.
# NEVER chown -R the graphroot: rootless layer files carry subuid-mapped
# ownership (a uid 33 file inside an image is stored as 100032 on disk), so
# flattening them to abc corrupts every image that has non-root-owned files.
# It is also an O(files) chown on each boot. Only own dirs we actually create.
for d in /config/.local /config/.local/share /config/.local/share/containers \
         /config/.config /config/.config/containers; do
    [ -d "$d" ] || { mkdir -p "$d"; lsiown abc:abc "$d"; }
done
# export XDG_RUNTIME_DIR (+ DOCKER_HOST when the socket service is on) for shells
if is_true "${DEVCON_DOCKER:-true}"; then
    docker_host="export DOCKER_HOST=unix:///run/user/${login_uid}/podman/podman.sock"
else
    docker_host=""
fi
cat > /etc/profile.d/10-podman.sh <<EOF
export XDG_RUNTIME_DIR=/run/user/${login_uid}
${docker_host}
EOF
# code-server's terminal opens a non-login interactive shell → source it there too
grep -q '10-podman.sh' /etc/bash.bashrc 2>/dev/null \
    || echo '[ -f /etc/profile.d/10-podman.sh ] && . /etc/profile.d/10-podman.sh' >> /etc/bash.bashrc

# git identity (optional, from env) — written to /config/.gitconfig
if [ -n "${GIT_USER_NAME:-}" ]; then
    s6-setuidgid abc env HOME=/config git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    s6-setuidgid abc env HOME=/config git config --global user.email "$GIT_USER_EMAIL"
fi
INIT

# 8443 (code-server) is already exposed by the base image; 22 is for sshd
EXPOSE 8443 22
