# Arch base ships pure-WoW64 wine (since wine 10.8-2, June 2025), so 32-bit
# Windows binaries run inside a 64-bit Wine process and use modern 64-bit Linux
# socket syscalls instead of the i386 socketcall(2) multiplexer. Docker 29.4.2's
# default seccomp profile blocks socketcall(2) entirely (CVE-2026-31431, "Copy
# Fail"), which broke Debian/WineHQ-based builds — this base avoids that path.
FROM archlinux:base

RUN pacman -Syu --noconfirm \
        wine \
        xorg-server-xvfb \
        xorg-xauth \
        python \
        jq \
        wget \
        tar \
        xz \
        unzip \
        findutils \
        procps-ng \
        ca-certificates \
    && pacman -Scc --noconfirm \
    && rm -rf /var/cache/pacman/pkg/*

RUN useradd -m plutainer

RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

ENV WINEDLLOVERRIDES="mscoree,mshtml=" \
    DISPLAY=:99

USER plutainer
WORKDIR /home/plutainer/.plutainer

RUN Xvfb :99 -screen 0 320x240x24 & \
    sleep 1 && \
    wineboot -u && \
    wineserver -w && \
    pkill -f Xvfb || true && \
    rm -f /tmp/.X99-lock

RUN wget https://github.com/mxve/plutonium-updater.rs/releases/latest/download/plutonium-updater-x86_64-unknown-linux-gnu.tar.gz -O plutonium-updater.tar.gz && \
    tar -xzvf plutonium-updater.tar.gz && \
    rm plutonium-updater.tar.gz

RUN IW4X_URL=$(wget -qO- https://api.github.com/repos/iw4x/launcher/releases/latest \
      | jq -r '.assets[] | select(.name | test("^launcher-.*linux-glibc\\.tar\\.xz$")) | .browser_download_url') && \
    wget -O iw4x-launcher.tar.xz "$IW4X_URL" && \
    mkdir -p iw4x-launcher-extract && \
    tar -xJf iw4x-launcher.tar.xz -C iw4x-launcher-extract && \
    BIN=$(find iw4x-launcher-extract -type f \( -name 'iw4x-launcher' -o -name 'launcher' \) | head -n1) && \
    mv "$BIN" iw4x-launcher && \
    rm -rf iw4x-launcher.tar.xz iw4x-launcher-extract && \
    chmod +x iw4x-launcher

# Bundle community config seeds for first-run scaffolding. Entrypoint copies
# these into the bind mount on start with cp -n (never overwrites user files).
# Source repos: xerxes-at/T{4,5,6}ServerConfig*, xerxes-at/IW5ServerConfig,
# Dss0/t7-server-config. Disable per-stack via PLUTO_SKIP_SEED/ALTER_SKIP_SEED.
RUN set -eux; \
    mkdir -p seed-configs/{t4,t5,t6,iw5,t7x}; \
    cd /tmp; \
    wget -q -O t4.zip   https://github.com/xerxes-at/T4ServerConfigs/archive/refs/heads/main.zip   && unzip -q t4.zip; \
    wget -q -O t5.zip   https://github.com/xerxes-at/T5ServerConfig/archive/refs/heads/master.zip && unzip -q t5.zip; \
    wget -q -O t6.zip   https://github.com/xerxes-at/T6ServerConfigs/archive/refs/heads/master.zip && unzip -q t6.zip; \
    wget -q -O iw5.zip  https://github.com/xerxes-at/IW5ServerConfig/archive/refs/heads/master.zip && unzip -q iw5.zip; \
    wget -q -O t7x.zip  https://github.com/Dss0/t7-server-config/archive/refs/heads/main.zip && unzip -q t7x.zip; \
    cp -r T4ServerConfigs-main/main/.                              /home/plutainer/.plutainer/seed-configs/t4/; \
    cp -r T5ServerConfig-master/localappdata/Plutonium/storage/t5/. /home/plutainer/.plutainer/seed-configs/t5/; \
    cp -r T6ServerConfigs-master/localappdata/Plutonium/storage/t6/. /home/plutainer/.plutainer/seed-configs/t6/; \
    cp -r IW5ServerConfig-master/admin/.                            /home/plutainer/.plutainer/seed-configs/iw5/; \
    cp -r t7-server-config-main/zone /home/plutainer/.plutainer/seed-configs/t7x/; \
    cp -r t7-server-config-main/t7x  /home/plutainer/.plutainer/seed-configs/t7x/; \
    rm -rf /tmp/*.zip /tmp/T4ServerConfigs-main /tmp/T5ServerConfig-master /tmp/T6ServerConfigs-master /tmp/IW5ServerConfig-master /tmp/t7-server-config-main; \
    find /home/plutainer/.plutainer/seed-configs -type d -iname '*REFERENCE*' -exec rm -rf {} +; \
    find /home/plutainer/.plutainer/seed-configs -type f \( -iname '*.bat' -o -iname '*.sh' -o -iname 'README*' \) -delete

COPY --chown=plutainer:plutainer scripts/ .
RUN chmod +x entrypoint.sh healthcheck.sh plutoentry.sh iw4xentry.sh alterentry.sh \
              log-watcher.sh rcon-cli game-config.sh migrate-v1-to-v2.sh

USER root
RUN ln -s /home/plutainer/.plutainer/rcon-cli /usr/local/bin/rcon-cli
USER plutainer

STOPSIGNAL SIGKILL

HEALTHCHECK --interval=1m --timeout=10s --start-period=5m --retries=3 \
  CMD ./healthcheck.sh

ENTRYPOINT ["./entrypoint.sh"]
