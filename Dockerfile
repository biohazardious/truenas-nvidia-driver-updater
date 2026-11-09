FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# The entrypoint builds NVIDIA modules with the SAME GCC major the target kernel
# was compiled with (entrypoint.sh: select_nvidia_build_cc) — a much newer GCC
# breaks NVIDIA's conftest API detection (GCC 14 makes implicit-declaration a
# hard error). Bookworm provides gcc-12, which is what TrueNAS 24.10 to 25.10 use;
# gcc-13 and gcc-14 come from trixie for newer toolchains. The base has to stay
# bookworm: libvulkan1 is copied into the image, and trixie's needs glibc 2.38
# while those TrueNAS releases have 2.36. A kernel built with another GCC major
# gets its compiler installed at build time (entrypoint.sh: install_kernel_gcc),
# from bookworm/trixie or else Debian's rolling testing/unstable suites (pinned
# at 50 as well). That can pull newer runtime libraries (libc, libgcc) into this
# build container, which is thrown away after the build.
RUN printf 'deb http://deb.debian.org/debian trixie main\n' > /etc/apt/sources.list.d/trixie.list \
    && printf 'Package: *\nPin: release n=trixie\nPin-Priority: 50\n' > /etc/apt/preferences.d/trixie

# Install dependencies required for extraction, kernel module compilation,
# and nvidia-container-toolkit installation (gnupg for apt repo key)
RUN apt-get update && apt-get install -y \
    build-essential wget curl squashfs-tools kmod xz-utils \
    bison flex libelf-dev bc rsync patch \
    libssl-dev pkg-config pciutils jq \
    gnupg ca-certificates \
    && apt-get install -y -t trixie gcc-13 gcc-14 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
