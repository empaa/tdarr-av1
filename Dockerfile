# syntax=docker/dockerfile:1

FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    meson \
    nasm \
    yasm \
    autoconf \
    automake \
    libtool \
    pkg-config \
    python3-dev \
    cython3 \
    git \
    wget \
    curl \
    libssl-dev \
    xxd \
    && (ln -sf /usr/bin/cython3 /usr/bin/cython || true) \
    && rm -rf /var/lib/apt/lists/*

# Install Rust stable
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

FROM base AS build-svtav1

RUN git clone --depth 1 --branch v4.1.0 \
        https://gitlab.com/AOMediaCodec/SVT-AV1.git /src/svtav1 && \
    cmake -S /src/svtav1 -B /src/svtav1/build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /src/svtav1/build -j$(nproc) && \
    cmake --install /src/svtav1/build && \
    ldconfig && \
    rm -rf /src

FROM base AS build-libaom

RUN wget -q "https://storage.googleapis.com/aom-releases/libaom-3.13.2.tar.gz" \
        -O /tmp/libaom.tar.gz && \
    mkdir -p /src/aom && \
    tar -xf /tmp/libaom.tar.gz -C /src/aom --strip-components=1 && \
    rm /tmp/libaom.tar.gz && \
    cmake -S /src/aom -B /src/aom_build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /src/aom_build -j$(nproc) && \
    cmake --install /src/aom_build && \
    ldconfig && \
    rm -rf /src/aom /src/aom_build

FROM base AS build-libvmaf

RUN git clone --depth 1 --branch v3.0.0 \
        https://github.com/Netflix/vmaf.git /src/vmaf && \
    meson setup /src/vmaf/libvmaf/build /src/vmaf/libvmaf \
        --buildtype=release \
        -Dbuilt_in_models=true \
        -Dprefix=/usr/local && \
    ninja -C /src/vmaf/libvmaf/build && \
    ninja -C /src/vmaf/libvmaf/build install && \
    mkdir -p /usr/local/share/vmaf && \
    cp -r /src/vmaf/model/. /usr/local/share/vmaf/ && \
    ldconfig && \
    rm -rf /src

FROM base AS build-vapoursynth

# Ubuntu 24.04 ships Python 3.12. VapourSynth R73 requires Cython 3.
# --break-system-packages required on Ubuntu 24.04 (PEP 668).
RUN apt-get update && apt-get install -y python3-pip --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --upgrade "cython>=3" \
    && ln -sf /usr/local/bin/cython /usr/bin/cython3

# Build zimg 3.0.6 first — VapourSynth depends on it
RUN git clone --depth 1 --branch release-3.0.6 \
        https://github.com/sekrit-twc/zimg.git /src/zimg && \
    cd /src/zimg && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# MUST be R73 or later — av1an 0.5.2 uses vapoursynth-rs v0.5.1 which requires
# VSScript API v4. R72 only provides API v3 and will fail to load at runtime.
# Do not upgrade to R74 until it leaves RC.
RUN git clone --depth 1 --branch R73 \
        https://github.com/vapoursynth/vapoursynth.git /src/vapoursynth && \
    cd /src/vapoursynth && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /src

FROM base AS build-ffmpeg

COPY --from=build-svtav1  /usr/local /usr/local
COPY --from=build-libaom  /usr/local /usr/local
COPY --from=build-libvmaf /usr/local /usr/local
RUN ldconfig

RUN wget -q https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz -O /tmp/ffmpeg.tar.xz && \
    tar xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cd /tmp/ffmpeg-8.1 && \
    ./configure \
        --prefix=/usr/local \
        --enable-gpl \
        --enable-shared \
        --disable-static \
        --disable-doc \
        --enable-libsvtav1 \
        --enable-libaom \
        --enable-libvmaf && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /tmp/ffmpeg*

FROM base AS build-lsmash

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

RUN apt-get update && apt-get install -y --no-install-recommends libxxhash-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v2.14.5 https://github.com/l-smash/l-smash.git /src/l-smash && \
    cd /src/l-smash && \
    ./configure --prefix=/usr/local --enable-shared && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /src/l-smash

# Use HomeOfAviSynthPlusEvolution fork — AkarinVS is incompatible with FFmpeg 5+
# (references AVStream.index_entries which was made private in FFmpeg commit cea7c19).
# Pinned to a specific commit for reproducibility; update intentionally when needed.
RUN git clone \
        https://github.com/HomeOfAviSynthPlusEvolution/L-SMASH-Works.git /src/lsmash && \
    git -C /src/lsmash checkout 0079a06ee384061ecdadd0de03df4e0493dd56ab && \
    meson setup /src/lsmash/VapourSynth/build /src/lsmash/VapourSynth \
        --buildtype=release \
        --prefix=/usr/local && \
    ninja -C /src/lsmash/VapourSynth/build && \
    ninja -C /src/lsmash/VapourSynth/build install && \
    ldconfig && \
    rm -rf /src

FROM base AS build-av1an

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

ENV VAPOURSYNTH_LIB_DIR=/usr/local/lib

COPY patches/av1an-vmaf.py /patches/av1an-vmaf.py

RUN git clone --depth 1 --branch v0.5.2 \
        https://github.com/master-of-zen/Av1an.git /src/av1an && \
    cd /src/av1an && \
    python3 /patches/av1an-vmaf.py && \
    cargo build --release && \
    cp target/release/av1an /usr/local/bin/ && \
    rm -rf /src

FROM base AS build-ab-av1

RUN cargo install ab-av1 --version 0.11.2 --root /usr/local

FROM ubuntu:24.04 AS av1-stack

COPY --from=build-svtav1      /usr/local /usr/local
COPY --from=build-libaom      /usr/local /usr/local
COPY --from=build-libvmaf     /usr/local /usr/local
COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
COPY --from=build-lsmash      /usr/local /usr/local
COPY --from=build-av1an       /usr/local /usr/local
COPY --from=build-ab-av1      /usr/local /usr/local

# Ubuntu 24.04 Python uses dist-packages; VapourSynth installs to site-packages.
# Set PYTHONPATH so getVSScriptAPI can import the vapoursynth module at runtime.
ENV PYTHONPATH=/usr/local/lib/python3.12/site-packages

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    mkvtoolnix \
    && rm -rf /var/lib/apt/lists/*

RUN ldconfig && \
    mkdir -p /etc/vapoursynth && \
    echo "SystemPluginDir=/usr/local/lib/vapoursynth" > /etc/vapoursynth/vapoursynth.conf

# av1an defaults to looking for vmaf_v0.6.1.json relative to CWD (/). Symlink
# to the installed model so the default path resolves without --vmaf-path.
RUN ln -sf /usr/local/share/vmaf/vmaf_v0.6.1.json /vmaf_v0.6.1.json \
    && ln -sf /usr/local/share/vmaf/vmaf_4k_v0.6.1.json /vmaf_4k_v0.6.1.json

FROM ghcr.io/haveagitgat/tdarr:latest AS tdarr
COPY --from=av1-stack /usr/local /usr/local
COPY --from=av1-stack /etc/vapoursynth /etc/vapoursynth
ENV PYTHONPATH=/usr/local/lib/python3.12/site-packages
RUN ldconfig && \
    apt-get update && \
    apt-get install -y --no-install-recommends mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*
RUN ln -sf /usr/local/share/vmaf/vmaf_v0.6.1.json /vmaf_v0.6.1.json \
    && ln -sf /usr/local/share/vmaf/vmaf_4k_v0.6.1.json /vmaf_4k_v0.6.1.json

FROM ghcr.io/haveagitgat/tdarr_node:latest AS tdarr_node
COPY --from=av1-stack /usr/local /usr/local
COPY --from=av1-stack /etc/vapoursynth /etc/vapoursynth
ENV PYTHONPATH=/usr/local/lib/python3.12/site-packages
RUN ldconfig && \
    apt-get update && \
    apt-get install -y --no-install-recommends mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*
RUN ln -sf /usr/local/share/vmaf/vmaf_v0.6.1.json /vmaf_v0.6.1.json \
    && ln -sf /usr/local/share/vmaf/vmaf_4k_v0.6.1.json /vmaf_4k_v0.6.1.json
