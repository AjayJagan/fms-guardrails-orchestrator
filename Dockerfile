ARG UBI_MINIMAL_BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal
ARG UBI_BASE_IMAGE_TAG=latest
ARG PROTOC_VERSION=29.3
ARG CONFIG_FILE=config/config.yaml
ARG TARGETARCH

## Rust builder ################################################################
# Specific debian version so that compatible glibc version is used
FROM rust:1.87.0 AS rust-builder
ARG PROTOC_VERSION
ARG TARGETARCH

ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

# Install protoc, no longer included in prost crate
RUN cd /tmp && \
    case "$TARGETARCH" in \
        s390x) \
            apt update && apt install -y cmake clang libclang-dev curl unzip && \
            curl -L -O https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-s390_64.zip ;; \
        arm64|aarch64) \
            apt update && apt install -y cmake clang libclang-dev curl unzip && \
            curl -L -O https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-aarch_64.zip ;; \
        ppc64le) \
            apt update && apt install -y cmake clang libclang-dev curl unzip && \
            curl -L -O https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-ppcle_64.zip ;; \
        *) \
            curl -L -O https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip ;; \
    esac && \
    unzip protoc-*.zip -d /usr/local && \
    rm protoc-*.zip

# Set LIBCLANG_PATH dynamically based on available paths
RUN for path in "/usr/lib/llvm-14/lib" "/usr/lib/llvm-13/lib" "/usr/lib/x86_64-linux-gnu" "/usr/lib/aarch64-linux-gnu"; do \
        if [ -d "$path" ]; then \
            echo "export LIBCLANG_PATH=$path" >> /etc/environment; \
            break; \
        fi; \
    done

ENV LIBCLANG_PATH=${LIBCLANG_PATH:-/usr/lib/llvm-14/lib/}

WORKDIR /app

COPY rust-toolchain.toml rust-toolchain.toml

RUN rustup component add rustfmt

## Orchestrator builder #########################################################
FROM rust-builder AS fms-guardrails-orchestr8-builder
ARG CONFIG_FILE=config/config.yaml

COPY build.rs *.toml LICENSE /app/
COPY ${CONFIG_FILE} /app/config/config.yaml
COPY protos/ /app/protos/
COPY src/ /app/src/

WORKDIR /app

# TODO: Make releases via cargo-release
RUN cargo install --root /app/ --path .

## Tests stage ##################################################################
FROM fms-guardrails-orchestr8-builder AS tests
RUN cargo test

## Lint stage ###################################################################
FROM fms-guardrails-orchestr8-builder AS lint
RUN cargo clippy --all-targets --all-features -- -D warnings

## Formatting check stage #######################################################
FROM fms-guardrails-orchestr8-builder AS format
RUN cargo +nightly fmt --check

## Release Image ################################################################

FROM ${UBI_MINIMAL_BASE_IMAGE}:${UBI_BASE_IMAGE_TAG} AS fms-guardrails-orchestr8-release
ARG CONFIG_FILE=config/config.yaml
ARG TARGETARCH

COPY --from=fms-guardrails-orchestr8-builder /app/bin/ /app/bin/
COPY ${CONFIG_FILE} /app/config/config.yaml

# Install packages based on target architecture
RUN microdnf install -y --disableplugin=subscription-manager shadow-utils && \
    if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "x86_64" ]; then \
        microdnf install -y --disableplugin=subscription-manager compat-openssl11 || \
        microdnf install -y --disableplugin=subscription-manager openssl; \
    else \
        microdnf install -y --disableplugin=subscription-manager openssl; \
    fi && \
    microdnf clean all --disableplugin=subscription-manager

RUN groupadd --system orchestr8 --gid 1001 && \
    adduser --system --uid 1001 --gid 0 --groups orchestr8 \
    --create-home --home-dir /app --shell /sbin/nologin \
    --comment "FMS Orchestrator User" orchestr8

USER orchestr8

HEALTHCHECK NONE

ENV ORCHESTRATOR_CONFIG=/app/config/config.yaml

CMD ["/app/bin/fms-guardrails-orchestr8"]
