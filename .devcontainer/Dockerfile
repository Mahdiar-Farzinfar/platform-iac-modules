# syntax=docker/dockerfile:1.7

## Enterprise-grade DevContainer for platform-iac-modules
## - Debian bookworm base (stable + secure)
## - Non-root developer user
## - Versions synced from tooling/.tool-versions (SoT)
## - Tool installation delegated to scripts/tools/install-tools-posix.go (DRY)

ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:debian-12@sha256:a0a7a7e9a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY tooling/.tool-versions             /tmp/tooling/.tool-versions
COPY tooling/.terraform-version         /tmp/tooling/.terraform-version
COPY tooling/cross-platform/asdf-tool-versions /tmp/tooling/asdf-tool-versions
COPY go.mod                             /tmp/go.mod
COPY scripts/tools/install-tools-posix.go /tmp/install-tools-posix.go

# -----------------------------
# Build-time arguments (version pinning)
# -----------------------------
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

# OCI / supply-chain metadata args
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG VERSION=dev
ARG SOURCE_URL="https://github.com/Mahdiar-Farzinfar/platform-iac-modules"
ARG LICENSES="Apache-2.0"

ARG TERRAFORM_VERSION=1.15.6
ARG GO_VERSION=1.22.3

# Optional tool installation flags
ARG INSTALL_AWSCLI=false
ARG INSTALL_DOCKER_CLI=true

# -----------------------------
# OCI Labels
# -----------------------------
LABEL org.opencontainers.image.title="platform-iac-modules devcontainer" \
      org.opencontainers.image.description="Enterprise-grade DevContainer for Terraform/AWS IaC module development" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.url="${SOURCE_URL}" \
      org.opencontainers.image.documentation="${SOURCE_URL}/tree/main/docs" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="${LICENSES}" \
      org.opencontainers.image.vendor="Mahdiar-Farzinfar"

ENV DEFAULT_TERRAFORM_VERSION="${TERRAFORM_VERSION}" \
    DEFAULT_GO_VERSION="${GO_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    CGO_ENABLED=0 \
    PYTHON_TOOLS_VENV="/opt/python-tools"

# -----------------------------
# Generate a machine-readable env file from tooling SoT (thin — validation lives in Go script)
# -----------------------------
RUN set -euo pipefail; \
    cat >/usr/local/bin/sync-tool-versions.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
TOOL_VERSIONS_FILE="/tmp/tooling/.tool-versions"
ASDF_FILE="/tmp/tooling/asdf-tool-versions"
TF_VERSION_FILE="/tmp/tooling/.terraform-version"

get_tool_version() {
    awk -v tool="$1" '$1 == tool && $2 !~ /^#/ { print $2; exit }' "${TOOL_VERSIONS_FILE}" 2>/dev/null || true
}

get_asdf_version() {
    awk -v tool="$1" '$1 == tool { print $2; exit }' "${ASDF_FILE}" 2>/dev/null || true
}

TERRAFORM_VERSION=$( [ -s "${TF_VERSION_FILE}" ] && tr -d '[:space:]' <"${TF_VERSION_FILE}" || get_tool_version terraform )
TERRAFORM_VERSION=${TERRAFORM_VERSION:-${DEFAULT_TERRAFORM_VERSION:-}}

GO_VERSION=$(get_asdf_version golang || get_tool_version golang)
GO_VERSION=${GO_VERSION:-${DEFAULT_GO_VERSION:-}}

cat >/usr/local/etc/devcontainer-tool-versions.env <<EOF
TERRAFORM_VERSION=${TERRAFORM_VERSION}
GO_VERSION=${GO_VERSION}
EOF

echo "[sync] Terraform=${TERRAFORM_VERSION} Go=${GO_VERSION}"
SCRIPT
RUN chmod +x /usr/local/bin/sync-tool-versions.sh

# -----------------------------
# Base packages
# -----------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    git \
    gnupg \
    dirmngr \
    lsb-release \
    xz-utils \
    make \
    sudo \
    openssh-client \
    build-essential \
    libssl-dev \
    libffi-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    libxml2-dev \
    libxmlsec1-dev \
    liblzma-dev \
    && apt-get purge -y --auto-remove build-essential libssl-dev libffi-dev \
    zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libncursesw5-dev \
    libxml2-dev libxmlsec1-dev liblzma-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

  # -----------------------------
# Sync versions → call Go installer
# -----------------------------
RUN /usr/local/bin/sync-tool-versions.sh && \
    ARCH="$(dpkg --print-architecture)" && \
    case "${ARCH}" in \
      amd64) GOARCH="amd64" ;; \
      arm64) GOARCH="arm64" ;; \
      *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    GOARCH="${GOARCH}" go build -trimpath -o /tmp/install-tools /tmp/install-tools-posix.go && \
    /tmp/install-tools --tool-versions-file /tmp/tooling/.tool-versions \
                       --asdf-tool-versions-file /tmp/tooling/asdf-tool-versions \
                       --terraform-version-file /tmp/tooling/.terraform-version \
                       --go-mod /tmp/go.mod \
                       --install-aws-cli "${INSTALL_AWSCLI}" \
                       --python-tools-venv ${PYTHON_TOOLS_VENV} \
                       --install-docker-cli && \
    rm -f /tmp/install-tools-posix.go /tmp/go.mod && \
    rm -rf /tmp/tooling

# -----------------------------
# Ensure non-root user exists and has sudo (if base image changed)
# -----------------------------
RUN if ! id -u "${USERNAME}" >/dev/null 2>&1; then \
      groupadd --gid "${USER_GID}" "${USERNAME}" && \
      useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/bash "${USERNAME}"; \
    fi && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-${USERNAME} && \
    chmod 0440 /etc/sudoers.d/90-${USERNAME}

# -----------------------------
# Quality-of-life: completion + cache dirs + ownership
# -----------------------------
RUN mkdir -p /home/${USERNAME}/.cache /home/${USERNAME}/.local/bin /workspaces && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /workspaces

# -----------------------------
# Build-time sanity checks (fail-fast)
# -----------------------------
RUN source /usr/local/etc/devcontainer-tool-versions.env && \
    terraform version && \
    tflint --version && \
    trivy --version && \
    terraform-docs --version && \
    gitleaks version && \
    actionlint --version && \
    task --version && \
    shfmt --version && \
    just --version && \
    go version && \
    node --version && \
    python --version && \
    pre-commit --version && \
    checkov --version && \
    yamllint --version && \
    golangci-lint --version && \
    if [ "${INSTALL_AWSCLI}" = "true" ]; then aws --version; fi && \
    if [ "${INSTALL_DOCKER_CLI}" = "true" ]; then docker --version && docker compose version; fi && \
    echo "[sanity] All tools verified OK"

# -----------------------------
# Runtime defaults
# -----------------------------
ENV GOPATH="/home/${USERNAME}/go"
ENV PATH="${PYTHON_TOOLS_VENV}/bin:/usr/local/go/bin:/home/${USERNAME}/.local/bin:${PATH}" \
    HOME="/home/${USERNAME}"

USER ${USERNAME}
WORKDIR /workspaces

STOPSIGNAL SIGTERM

CMD [ "bash", "-lc", "terraform version && python --version && pre-commit --version && tflint --version && trivy --version && gitleaks version && node --version" ]
