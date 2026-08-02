# syntax=docker/dockerfile:1.7

## Enterprise-grade DevContainer for platform-iac-modules
## - Debian bookworm base (stable + secure)
## - Non-root developer user
## - Versions synced from tooling/.tool-versions (SoT)
## - Tool installation delegated to scripts/tools/install-tools-posix.go (DRY)

ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:2-debian-13@sha256:2e826a6ae92e5744cc0a471a03b4411e64f6b7cc6af3adaecddad697f0018f10
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# -----------------------------
# Install mise (required by install-tools)
# -----------------------------
RUN curl -fsSL https://mise.run | sh && \
    mv ~/.local/bin/mise /usr/local/bin/mise && \
    mise --version

COPY tooling/.tool-versions             /tmp/tooling/.tool-versions
COPY tooling/.terraform-version         /tmp/tooling/.terraform-version
COPY tooling/cross-platform/asdf-tool-versions /tmp/tooling/asdf-tool-versions
COPY go.mod                             /tmp/go.mod
COPY scripts/tools/install-tools-posix.go /tmp/install-tools-posix.go
COPY .git                               /.git

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
    PYTHON_TOOLS_VENV="/opt/python-tools" \
    MISE_DATA_DIR="/usr/local/share/mise" \
    MISE_CONFIG_DIR="/usr/local/etc/mise" \
    MISE_CACHE_DIR="/var/cache/mise" \
    ASDF_DATA_DIR="/usr/local/share/asdf"

ENV PATH="/usr/local/share/mise/shims:/usr/local/share/asdf/shims:/usr/local/bin:/usr/local/go/bin:${PYTHON_TOOLS_VENV}/bin:/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/share/mise/shims:/home/${USERNAME}/.asdf/shims:${PATH}"

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

cp -r /tmp/tooling /tooling

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
   python3 \
   python3-pip \
   python3-venv \
   pipx \
   nodejs \
   npm \
    && apt-get purge -y --auto-remove build-essential libssl-dev libffi-dev \
    zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libncursesw5-dev \
    libxml2-dev libxmlsec1-dev liblzma-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# -----------------------------
# Install Go
# -----------------------------
RUN set -euo pipefail && \
    /usr/local/bin/sync-tool-versions.sh && \
    source /usr/local/etc/devcontainer-tool-versions.env && \
    GO_VER="${GO_VERSION:-1.22.3}" && \
    echo "[go] Installing Go ${GO_VER}..." && \
    ARCH="$(dpkg --print-architecture)" && \
    case "${ARCH}" in \
      amd64) GOARCH="amd64" ;; \
      arm64) GOARCH="arm64" ;; \
      *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${GOARCH}.tar.gz" | \
    tar -C /usr/local -xzf - && \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go && \
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt && \
    go version && \
    echo "[go] Go ${GO_VER} installed at /usr/local/go"

# -----------------------------
# Sync versions → call Go installer
# -----------------------------
WORKDIR /tmp

RUN set -euo pipefail && \
    mkdir -p "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}" "${MISE_CACHE_DIR}" "${ASDF_DATA_DIR}" \
             /usr/local/share/mise/shims /usr/local/share/asdf/shims && \
    /usr/local/bin/sync-tool-versions.sh && \
    ARCH="$(dpkg --print-architecture)" && \
    case "${ARCH}" in \
      amd64) GOARCH="amd64" ;; \
      arm64) GOARCH="arm64" ;; \
      *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    echo "[build] Building install-tools installer..." && \
    GOARCH="${GOARCH}" go build -trimpath -o /tmp/install-tools /tmp/install-tools-posix.go && \
    ln -sf /tmp/go.mod /go.mod && \
    /tmp/install-tools --tool-versions-file /tmp/tooling/.tool-versions \
                       --asdf-tool-versions-file /tmp/tooling/asdf-tool-versions \
                       --terraform-version-file /tmp/tooling/.terraform-version \
                       --go-mod /go.mod \
                       --install-aws-cli "${INSTALL_AWSCLI}" \
                       --python-tools-venv ${PYTHON_TOOLS_VENV} \
                       --install-docker-cli && \
    if command -v mise >/dev/null 2>&1; then \
      mise reshim || true; \
    fi && \
    for b in terraform tflint trivy terraform-docs gitleaks actionlint task shfmt just \
             golangci-lint pre-commit checkov yamllint; do \
      if ! command -v "${b}" >/dev/null 2>&1; then \
        for d in \
          /usr/local/share/mise/shims \
          /root/.local/share/mise/shims \
          /root/.local/bin \
          /home/${USERNAME}/.local/bin \
          /home/${USERNAME}/.local/share/mise/shims \
          ${PYTHON_TOOLS_VENV}/bin; do \
          if [ -x "${d}/${b}" ]; then \
            ln -sfn "${d}/${b}" "/usr/local/bin/${b}"; \
            break; \
          fi; \
        done; \
      fi; \
    done && \
    if ! command -v terraform >/dev/null 2>&1; then \
      echo "[path-debug] terraform not found after install" >&2; \
      echo "[path-debug] PATH=${PATH}" >&2; \
      echo "[path-debug] candidates:" >&2; \
      ls -la /usr/local/bin /usr/local/share/mise/shims /root/.local/bin /root/.local/share/mise/shims 2>/dev/null || true; \
      find /usr/local /root /home /opt -type f -name 'terraform' 2>/dev/null | head -n 50 || true; \
      exit 127; \
    fi && \
    rm -f /tmp/install-tools-posix.go /tmp/go.mod /go.mod && \
    rm -rf /tmp/tooling

# -----------------------------
# Docker Compose
# -----------------------------
RUN set -euo pipefail && \
    TOOL_VERSIONS_FILE="/tooling/.tool-versions" && \
    DOCKER_COMPOSE_VERSION=$(awk '$1 == "docker-compose" && $2 !~ /^#/ { print $2; exit }' "${TOOL_VERSIONS_FILE}" 2>/dev/null || echo "") && \
    echo "[docker-compose] Installing version ${DOCKER_COMPOSE_VERSION}" && \
    ARCH="$(dpkg --print-architecture)" && \
    case "${ARCH}" in \
      amd64) \
        COMPOSE_ARCH="x86_64" ;; \
      arm64) \
        COMPOSE_ARCH="aarch64" ;; \
      *) \
        echo "[ERROR] Unsupported architecture: ${ARCH}" >&2 && \
        exit 1 ;; \
    esac && \
    COMPOSE_URL="https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" && \
    echo "[docker-compose] Downloading from: ${COMPOSE_URL}" && \
    curl -fsSL "${COMPOSE_URL}" -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose && \
    docker-compose --version && \
    mkdir -p /usr/lib/docker/cli-plugins && \
    cp /usr/local/bin/docker-compose /usr/lib/docker/cli-plugins/docker-compose && \
    chmod +x /usr/lib/docker/cli-plugins/docker-compose && \
    docker compose version && \
    echo "[docker-compose] Installed successfully"

RUN rm -rf /tooling

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
RUN mkdir -p \
      /home/${USERNAME}/.cache \
      /home/${USERNAME}/.local/bin \
      /workspaces \
      "${MISE_DATA_DIR}" \
      "${MISE_CONFIG_DIR}" \
      "${MISE_CACHE_DIR}" \
      "${ASDF_DATA_DIR}" \
      "${PYTHON_TOOLS_VENV}" && \
    chown -R ${USERNAME}:${USERNAME} \
      /home/${USERNAME} \
      /workspaces \
      "${MISE_DATA_DIR}" \
      "${MISE_CONFIG_DIR}" \
      "${MISE_CACHE_DIR}" \
      "${ASDF_DATA_DIR}" \
      "${PYTHON_TOOLS_VENV}" && \
    chmod -R a+rX /usr/local/share/mise /usr/local/share/asdf /usr/local/bin || true

# -----------------------------
# System-wide PATH for login shells
# -----------------------------
RUN set -euo pipefail && \
    CUSTOM_PATH="/usr/local/share/mise/shims:/usr/local/share/asdf/shims:/usr/local/bin:/usr/local/go/bin:${PYTHON_TOOLS_VENV}/bin:/home/${USERNAME}/.local/bin" && \
    mkdir -p /etc/profile.d && \
    printf 'export PATH="%s:$PATH"\n' "${CUSTOM_PATH}" > /etc/profile.d/99-devcontainer-path.sh && \
    chmod 644 /etc/profile.d/99-devcontainer-path.sh && \
    echo "[profile.d] System PATH configured for login shells"

# -----------------------------
# Build-time sanity checks (fail-fast)
# -----------------------------
RUN set -euo pipefail && \
    printf 'export PATH="%s:$PATH"\n' \
      "/usr/local/share/mise/shims:/usr/local/share/asdf/shims:/usr/local/bin:/usr/local/go/bin:${PYTHON_TOOLS_VENV}/bin:/home/${USERNAME}/.local/bin" \
      >> "/home/${USERNAME}/.bashrc" && \
    chown ${USERNAME}:${USERNAME} "/home/${USERNAME}/.bashrc" && \
    echo "[bashrc] PATH appended for user ${USERNAME}"

# -----------------------------
# Build-time sanity checks (root) – existing
# -----------------------------
RUN set -euo pipefail && \
    source /usr/local/etc/devcontainer-tool-versions.env && \
    echo "[sanity] PATH=${PATH}" && \
    command -v terraform && \
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
    markdownlint-cli2 --version && \
    golangci-lint --version && \
    if [ "${INSTALL_AWSCLI}" = "true" ]; then aws --version; fi && \
    if [ "${INSTALL_DOCKER_CLI}" = "true" ]; then \
        docker --version && \
        docker compose version && \
        docker-compose --version; \
    fi && \
    echo "[sanity] All tools verified OK"

# -----------------------------
# Final sanity check as vscode (non-root)
# -----------------------------
USER ${USERNAME}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -euo pipefail && \
    command -v terraform && \
    terraform version && \
    echo "[sanity-vscode] All tools accessible for user ${USERNAME}"

# -----------------------------
# Runtime defaults
# -----------------------------
ENV GOPATH="/home/${USERNAME}/go"
ENV PATH="${PYTHON_TOOLS_VENV}/bin:/usr/local/share/mise/shims:/usr/local/share/asdf/shims:/usr/local/bin:/usr/local/go/bin:/home/${USERNAME}/.local/bin:${PATH}" \
    HOME="/home/${USERNAME}" \
    MISE_DATA_DIR="/usr/local/share/mise" \
    MISE_CONFIG_DIR="/usr/local/etc/mise" \
    MISE_CACHE_DIR="/var/cache/mise" \
    ASDF_DATA_DIR="/usr/local/share/asdf"

USER ${USERNAME}
WORKDIR /workspaces

STOPSIGNAL SIGTERM

CMD [ "bash", "-lc", "terraform version && python --version && pre-commit --version && tflint --version && trivy --version && gitleaks version && node --version" ]
