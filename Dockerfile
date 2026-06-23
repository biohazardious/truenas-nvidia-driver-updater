FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# The entrypoint builds NVIDIA modules with the SAME GCC major the target kernel
# was compiled with (entrypoint.sh: select_nvidia_build_cc) — a much newer GCC
# breaks NVIDIA's conftest API detection (GCC 14 makes implicit-declaration a
# hard error). Bookworm provides gcc-12; pull gcc-13 and gcc-14 from trixie so we
# can match the common TrueNAS toolchains (e.g. 6.1/6.6 → gcc-12/13, 6.12 → gcc-14).
RUN printf 'deb http://deb.debian.org/debian trixie main\n' > /etc/apt/sources.list.d/trixie.list \
    && printf 'Package: *\nPin: release n=trixie\nPin-Priority: 50\n' > /etc/apt/preferences.d/trixie

# Install dependencies required for extraction, kernel module compilation,
# and nvidia-container-toolkit installation (gnupg for apt repo key)
RUN apt-get update && apt-get install -y \
    build-essential wget curl squashfs-tools kmod xz-utils \
    bison flex libelf-dev bc rsync patch \
    libssl-dev pkg-config pciutils \
    gnupg ca-certificates \
    && apt-get install -y -t trixie gcc-13 gcc-14 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
