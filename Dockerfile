FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# TrueNAS 25/26 kernels may be built with GCC 14 and use module build flags
# that GCC 12 from bookworm does not understand (for example
# -fmin-function-alignment=16). Keep the base image on bookworm, but pull only
# gcc-14 from trixie for module compilation compatibility.
RUN printf 'deb http://deb.debian.org/debian trixie main\n' > /etc/apt/sources.list.d/trixie.list \
    && printf 'Package: *\nPin: release n=trixie\nPin-Priority: 50\n' > /etc/apt/preferences.d/trixie

# Install dependencies required for extraction, kernel module compilation,
# and nvidia-container-toolkit installation (gnupg for apt repo key)
RUN apt-get update && apt-get install -y \
    build-essential wget curl squashfs-tools kmod xz-utils \
    bison flex libelf-dev bc rsync \
    libssl-dev pkg-config pciutils \
    gnupg ca-certificates \
    && apt-get install -y -t trixie gcc-14 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
