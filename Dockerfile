# syntax=docker/dockerfile:1
# Dev environment container — git + gh + Claude Code + code-server + sshd.
#
# Base: LinuxServer's code-server image. It already ships a working code-server
# with s6-overlay init and PUID/PGID handling, so files created in the mounted
# volume are owned by my own user instead of root. It is Ubuntu-based because
# code-server needs glibc (the Alpine/musl route is impractical). We add the
# GitHub CLI, Node/Claude Code, and an sshd service on top.
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
    git gh openssh-server nodejs ca-certificates
npm install -g @anthropic-ai/claude-code
npm cache clean --force
rm -rf /var/lib/apt/lists/*
PKG

# ---- add an sshd service to the existing s6 stack ---------------------------
RUN <<'SETUP'
set -e
# give the abc login user a home on the /config volume and a real shell for ssh,
# so ssh sessions, the code-server terminal and git all share one persisted HOME
awk -F: 'BEGIN{OFS=":"} $1=="abc"{$6="/config";$7="/bin/bash"} {print}' /etc/passwd > /etc/passwd.tmp \
    && mv /etc/passwd.tmp /etc/passwd
mkdir -p /etc/s6-overlay/s6-rc.d/svc-sshd \
         /etc/s6-overlay/s6-rc.d/user/contents.d \
         /custom-cont-init.d
echo longrun > /etc/s6-overlay/s6-rc.d/svc-sshd/type
# enable the service by adding it to the default "user" bundle
touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-sshd
SETUP

# sshd: runs as root (it drops to the login user on login). The config is
# generated at runtime by 10-dev-init below, because the allowed username and
# the password-auth toggle are both env-driven.
COPY --chmod=755 <<'SSHRUN' /etc/s6-overlay/s6-rc.d/svc-sshd/run
#!/usr/bin/with-contenv bash
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config.dev
SSHRUN

# ---- one-shot init: user rename, ssh config/keys, git identity, ownership ---
COPY --chmod=755 <<'INIT' /custom-cont-init.d/10-dev-init
#!/usr/bin/with-contenv bash
set -e

# ---- optional: rename the login user (default stays "abc") ------------------
# The base image hardcodes "abc" in its own s6 service scripts, so we rename the
# account in place (keeping its uid/gid) and append a compat "abc" entry pointing
# at the same uid/gid. That way `getpwnam abc` still resolves for base-image
# scripts, while the renamed entry stays first so prompts/whoami show the new
# name. Runs before any service starts, so no process is using the account yet.
LOGIN_USER="${DEVCON_USER:-abc}"
if [ "$LOGIN_USER" != "abc" ] && id abc >/dev/null 2>&1 && ! id "$LOGIN_USER" >/dev/null 2>&1; then
    abc_uid=$(id -u abc)
    abc_gid=$(id -g abc)
    usermod -l "$LOGIN_USER" abc
    usermod -d /config -s /bin/bash "$LOGIN_USER"
    grep -q '^abc:' /etc/passwd \
        || echo "abc:x:${abc_uid}:${abc_gid}:devcon compat:/config:/bin/bash" >> /etc/passwd
fi

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
case "${DEVCON_SSH_PASSWORD_AUTH:-false}" in
    [Tt]rue|[Yy]es|[Oo]n|1) pw_auth=yes ;;
    *)                      pw_auth=no  ;;
esac
if [ "$pw_auth" = yes ]; then
    if [ -n "${DEVCON_SSH_PASSWORD:-}" ]; then
        echo "${LOGIN_USER}:${DEVCON_SSH_PASSWORD}" | chpasswd
    else
        echo "[devcon] DEVCON_SSH_PASSWORD_AUTH is on but DEVCON_SSH_PASSWORD is empty; staying key-only" >&2
        pw_auth=no
    fi
fi

# ---- generate sshd config (username + password toggle are runtime-driven) ---
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
EOF

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
