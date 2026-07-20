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

# sshd: runs as root (it drops to abc on login), key-only auth
COPY --chmod=755 <<'SSHRUN' /etc/s6-overlay/s6-rc.d/svc-sshd/run
#!/usr/bin/with-contenv bash
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config.dev
SSHRUN

COPY <<'SSHDCONF' /etc/ssh/sshd_config.dev
Port 22
AddressFamily any
# host keys live on the volume so they survive image rebuilds
HostKey /config/ssh/ssh_host_ed25519_key
HostKey /config/ssh/ssh_host_rsa_key
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /config/.ssh/authorized_keys
AllowUsers abc
UsePAM no
PidFile /config/ssh/sshd.pid
Subsystem sftp /usr/lib/openssh/sftp-server
SSHDCONF

# ---- one-shot init: ssh host keys, git identity, ownership ------------------
COPY --chmod=755 <<'INIT' /custom-cont-init.d/10-dev-init
#!/usr/bin/with-contenv bash
set -e
mkdir -p /config/ssh /config/.ssh
# persistent host keys (generated once, reused after)
[ -f /config/ssh/ssh_host_ed25519_key ] || ssh-keygen -t ed25519 -f /config/ssh/ssh_host_ed25519_key -N ""
[ -f /config/ssh/ssh_host_rsa_key ]     || ssh-keygen -t rsa -b 4096 -f /config/ssh/ssh_host_rsa_key -N ""
touch /config/.ssh/authorized_keys
lsiown -R abc:abc /config/ssh /config/.ssh
chmod 700 /config/.ssh
chmod 600 /config/.ssh/authorized_keys

# git identity (optional, from env) — written to /config/.gitconfig as abc
if [ -n "${GIT_USER_NAME:-}" ]; then
    s6-setuidgid abc env HOME=/config git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    s6-setuidgid abc env HOME=/config git config --global user.email "$GIT_USER_EMAIL"
fi
INIT

# 8443 (code-server) is already exposed by the base image; 22 is for sshd
EXPOSE 8443 22
