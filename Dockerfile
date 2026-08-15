# Arch base ships pure-WoW64 wine (since wine 10.8-2, June 2025), so 32-bit
# Windows binaries run inside a 64-bit Wine process and use modern 64-bit Linux
# socket syscalls instead of the i386 socketcall(2) multiplexer. Docker 29.4.2's
# default seccomp profile blocks socketcall(2) entirely (CVE-2026-31431, "Copy
# Fail"), which broke Debian/WineHQ-based builds — this base avoids that path.
FROM archlinux:base

# multilib supplies lib32-glibc/lib32-gcc-libs, needed by CoD4x: upstream's
# dedicated server is a native 32-bit x86 Linux ELF, the one family here that
# does not run under Wine.
RUN printf '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf

RUN pacman -Syu --noconfirm \
        wine \
        lib32-glibc \
        lib32-gcc-libs \
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

ENV WINEDLLOVERRIDES="mscoree,mshtml="

USER plutainer
WORKDIR /home/plutainer/.plutainer

# No X server anywhere in the image: every server we run is headless. t7x needs
# `-headless` for that (see alterentry.sh); wineboot only warns about the
# missing display driver and still initialises the prefix.
RUN wineboot -u && wineserver -w

# SteamCMD installs and updates the native 7 Days to Die dedicated server at
# runtime. It is a 32-bit bootstrapper; the multilib libraries above satisfy
# it, while the game server it installs is x86_64.
RUN mkdir -p steamcmd && \
    wget -qO steamcmd/steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz && \
    tar -xzf steamcmd/steamcmd_linux.tar.gz -C steamcmd && \
    rm steamcmd/steamcmd_linux.tar.gz && \
    steamcmd/steamcmd.sh +quit

RUN wget https://github.com/mxve/plutonium-updater.rs/releases/latest/download/plutonium-updater-x86_64-unknown-linux-gnu.tar.gz -O plutonium-updater.tar.gz && \
    tar -xzvf plutonium-updater.tar.gz && \
    rm plutonium-updater.tar.gz

# IW4X_LAUNCHER_REF keys the layer cache on upstream's current release tag.
# The URL is still resolved from releases/latest at build time, but without a
# changing ARG the RUN's command string is constant, so BuildKit reuses this
# layer indefinitely and the image can ship a launcher binary many releases
# out of date. CI passes the resolved tag.
ARG IW4X_LAUNCHER_REF=latest
RUN echo "upstream iw4x/launcher release: ${IW4X_LAUNCHER_REF}" && \
    IW4X_URL=$(wget -qO- https://api.github.com/repos/iw4x/launcher/releases/latest \
      | jq -r '.assets[] | select(.name | test("^launcher-.*linux-glibc\\.tar\\.xz$")) | .browser_download_url') && \
    wget -O iw4x-launcher.tar.xz "$IW4X_URL" && \
    mkdir -p iw4x-launcher-extract && \
    tar -xJf iw4x-launcher.tar.xz -C iw4x-launcher-extract && \
    BIN=$(find iw4x-launcher-extract -type f \( -name 'iw4x-launcher' -o -name 'launcher' \) | head -n1) && \
    mv "$BIN" iw4x-launcher && \
    rm -rf iw4x-launcher.tar.xz iw4x-launcher-extract && \
    chmod +x iw4x-launcher

# CoD4x server binary plus the two assets a stock CoD4 install lacks. The
# server refuses to load any map without cod4x_patchv2.ff, and both it and
# jcod4x_00.iwd ship in the *client* release rather than the server one — the
# server release contains only the binaries and plugin zips. Nothing else from
# the client is used: cod4x_021.dll, launcher.dll, core and mss are all
# client-side. cod4x_ambfix.ff is skipped too; a running server references it
# zero times.
#
# Both refs are pinned rather than tracking "latest": upstream's last server
# release is 21.2 (2022) and the binary self-updates at runtime anyway, so a
# moving target here would buy nothing and cost reproducibility.
ARG COD4X_SERVER_REF=21.2
ARG COD4X_CLIENT_REF=21.3
RUN set -eux; \
    mkdir -p cod4x/zone/english cod4x/main; \
    SERVER_URL="https://github.com/callofduty4x/CoD4x_Server/releases/download/${COD4X_SERVER_REF}"; \
    CLIENT_URL="https://github.com/callofduty4x/CoD4x_Client_pub/releases/download/${COD4X_CLIENT_REF}"; \
    wget -q -O cod4x/cod4x18_dedrun "${SERVER_URL}/cod4x18_dedrun"; \
    chmod +x cod4x/cod4x18_dedrun; \
    wget -q -O cod4x/zone/english/cod4x_patchv2.ff "${CLIENT_URL}/cod4x_patchv2.ff"; \
    wget -q -O cod4x/main/jcod4x_00.iwd "${CLIENT_URL}/jcod4x_00.iwd"

# Community config seeds for first-run scaffolding. Entrypoint copies these
# into the bind mount on start with cp -n (never overwrites user files).
# Disable per-stack via PLUTAINER_SKIP_SEED.
#
# Vendored, not fetched: these used to be six build-time wgets of six
# third-party repos, so any one of them disappearing broke the build for every
# game, and since the RUN string never changed the layer cached forever —
# upstream edits stayed invisible and no image could say which revision it
# shipped. seed-configs/<game>/SOURCE records the exact upstream commit;
# tools/refresh-seeds.sh is the only thing that should rewrite these.
COPY --chown=plutainer:plutainer seed-configs/ seed-configs/

COPY --chown=plutainer:plutainer scripts/ .
RUN chmod +x entrypoint.sh healthcheck.sh plutoentry.sh iw4xentry.sh alterentry.sh \
              cod4xentry.sh 7dtdentry.sh log-watcher.sh rcon-cli game-config.sh migrate-v1-to-v2.sh

USER root
RUN ln -s /home/plutainer/.plutainer/rcon-cli /usr/local/bin/rcon-cli
USER plutainer

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=1m --timeout=10s --start-period=5m --retries=3 \
  CMD ./healthcheck.sh

ENTRYPOINT ["./entrypoint.sh"]
