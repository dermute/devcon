# syntax=docker/dockerfile:1
# Dev environment container — git + gh + Claude Code + code-server + sshd.
#
# Base: LinuxServer's Alpine image. Its layers are shared with the LinuxServer
# app images (radarr/sonarr/qbittorrent/...), so on a NAS already running those
# the base costs ~0 MB extra. You also inherit s6-overlay init and
# PUID/PGID/UMASK handling, so files created in the mounted volume are owned by
# your NAS user instead of root.
#
# NOTE: requires BuildKit (default on Docker 23+) for the heredoc RUN/COPY below.
FROM ghcr.io/linuxserver/baseimage-alpine:3.24

# ---- toolchain --------------------------------------------------------------
# code-server's standalone release is glibc-only; on musl we install it via npm,
# which needs a compiler toolchain at build time (dropped again afterwards).
RUN apk add --no-cache \
        git \
        github-cli \
        openssh \
        openssh-client \
        curl \
        ca-certificates \
        bash \
        sudo \
        nodejs \
        npm \
        libstdc++ \
 && apk add --no-cache --virtual .build-deps build-base python3 \
 && npm install -g --unsafe-perm \
        code-server \
        @anthropic-ai/claude-code \
 && npm cache clean --force \
 && apk del .build-deps

# ---- s6 service wiring -------------------------------------------------------
RUN <<'SETUP'
set -e
# give the abc login user a real shell for ssh sessions
sed -i 's#^\(abc:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\).*#\1/bin/bash#' /etc/passwd
mkdir -p /etc/s6-overlay/s6-rc.d/svc-code-server \
         /etc/s6-overlay/s6-rc.d/svc-sshd \
         /etc/s6-overlay/s6-rc.d/user/contents.d \
         /custom-cont-init.d
echo longrun > /etc/s6-overlay/s6-rc.d/svc-code-server/type
echo longrun > /etc/s6-overlay/s6-rc.d/svc-sshd/type
# enable both services by adding them to the default "user" bundle
touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-code-server \
      /etc/s6-overlay/s6-rc.d/user/contents.d/svc-sshd
SETUP

# code-server: launch as the abc user, HOME on the persisted volume
COPY --chmod=755 <<'RUNSCRIPT' /etc/s6-overlay/s6-rc.d/svc-code-server/run
#!/usr/bin/with-contenv bash
mkdir -p /config/workspace
# code-server reads $PASSWORD from the environment for --auth password
exec s6-setuidgid abc env HOME=/config \
    code-server \
        --bind-addr 0.0.0.0:8443 \
        --auth password \
        --user-data-dir /config/.local/share/code-server \
        --extensions-dir /config/.local/share/code-server/extensions \
        /config/workspace
RUNSCRIPT

# sshd: runs as root (it drops to abc on login), key-only auth
COPY --chmod=755 <<'SSHRUN' /etc/s6-overlay/s6-rc.d/svc-sshd/run
#!/usr/bin/with-contenv bash
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
Subsystem sftp /usr/lib/ssh/sftp-server
SSHDCONF

# ---- one-shot init: fix ownership + generate/persist ssh host keys ----------
COPY --chmod=755 <<'INIT' /custom-cont-init.d/10-dev-init
#!/usr/bin/with-contenv bash
set -e
mkdir -p /config/ssh /config/.ssh /config/workspace
# persistent host keys (generated once, reused after)
[ -f /config/ssh/ssh_host_ed25519_key ] || ssh-keygen -t ed25519 -f /config/ssh/ssh_host_ed25519_key -N ""
[ -f /config/ssh/ssh_host_rsa_key ]     || ssh-keygen -t rsa -b 4096 -f /config/ssh/ssh_host_rsa_key -N ""
touch /config/.ssh/authorized_keys
lsiown -R abc:abc /config
chmod 700 /config/.ssh
chmod 600 /config/.ssh/authorized_keys
INIT

EXPOSE 8443 22
VOLUME /config
