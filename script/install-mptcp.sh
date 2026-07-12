#!/usr/bin/env bash
set -Eeuo pipefail

GO_VERSION="${GO_VERSION:-1.26.1}"
GO_INSTALL_ROOT="/usr/local/lib/v2node-build/go-${GO_VERSION}"
GO_BIN=""
PREFIX="/usr/local/v2node"
CONFIG_DIR="/etc/v2node"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/v2node.service"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
BACKUP_BINARY=""
PREBUILT_BINARY=""

API_HOST=""
NODE_ID=""
API_KEY=""

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log() {
    echo -e "${green}[v2node-mptcp]${plain} $*"
}

warn() {
    echo -e "${yellow}[v2node-mptcp] WARNING:${plain} $*" >&2
}

die() {
    echo -e "${red}[v2node-mptcp] ERROR:${plain} $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  bash script/install-mptcp.sh [options]

Options:
  --api-host URL    XiaoV2board URL, used only when config.json is absent
  --node-id ID      V2Node ID, used only when config.json is absent
  --api-key KEY     XiaoV2board server_token, used only when config.json is absent
  --binary-file PATH Use a prebuilt v2node binary instead of compiling locally
  --help            Show this help

The installer builds the checked-out source, preserves the existing config,
enables EnableMPTCP for all configured nodes, and installs a systemd service.
Only AnyTLS inbounds use the EnableMPTCP option.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-host)
            [[ $# -ge 2 ]] || die "--api-host requires a value"
            API_HOST="$2"
            shift 2
            ;;
        --node-id)
            [[ $# -ge 2 ]] || die "--node-id requires a value"
            NODE_ID="$2"
            shift 2
            ;;
        --api-key)
            [[ $# -ge 2 ]] || die "--api-key requires a value"
            API_KEY="$2"
            shift 2
            ;;
        --binary-file)
            [[ $# -ge 2 ]] || die "--binary-file requires a value"
            PREBUILT_BINARY="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die "run this installer as root"
[[ "$(uname -s)" == "Linux" ]] || die "this installer supports Linux only"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"
[[ -f "${SOURCE_ROOT}/go.mod" ]] || die "run the installer from a v2node source checkout"

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq tar
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl jq tar
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl jq tar
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed ca-certificates curl jq tar
    else
        die "supported package manager not found (apt, dnf, yum, or pacman)"
    fi
}

install_go() {
    local goarch archive url checksum_url checksum

    case "$(uname -m)" in
        x86_64|amd64) goarch="amd64" ;;
        aarch64|arm64) goarch="arm64" ;;
        s390x) goarch="s390x" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac

    if command -v go >/dev/null 2>&1 && [[ "$(go env GOVERSION)" == "go${GO_VERSION}" ]]; then
        GO_BIN="$(command -v go)"
        log "Go ${GO_VERSION} is already installed"
        return
    fi

    if [[ -x "${GO_INSTALL_ROOT}/bin/go" ]] \
        && [[ "$(${GO_INSTALL_ROOT}/bin/go env GOVERSION)" == "go${GO_VERSION}" ]]; then
        GO_BIN="${GO_INSTALL_ROOT}/bin/go"
        log "Using the private Go ${GO_VERSION} toolchain"
        return
    fi

    archive="go${GO_VERSION}.linux-${goarch}.tar.gz"
    url="https://dl.google.com/go/${archive}"
    checksum_url="${url}.sha256"
    log "Downloading Go ${GO_VERSION} for ${goarch}"
    curl -fL "${url}" -o "${WORK_DIR}/${archive}"
    checksum="$(curl -fsSL "${checksum_url}")"
    [[ "${checksum}" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid Go checksum response"
    echo "${checksum}  ${WORK_DIR}/${archive}" | sha256sum -c -

    tar -C "${WORK_DIR}" -xzf "${WORK_DIR}/${archive}"
    install -d -m 0755 "$(dirname "${GO_INSTALL_ROOT}")"
    rm -rf "${GO_INSTALL_ROOT}"
    mv "${WORK_DIR}/go" "${GO_INSTALL_ROOT}"
    GO_BIN="${GO_INSTALL_ROOT}/bin/go"
    [[ "$(${GO_BIN} env GOVERSION)" == "go${GO_VERSION}" ]] || die "Go installation failed"
}

build_binary() {
    local version
    version="mptcp-$(git -C "${SOURCE_ROOT}" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)"
    log "Building v2node ${version}"
    (
        cd "${SOURCE_ROOT}"
        export GOEXPERIMENT=jsonv2
        export CGO_ENABLED=0
        "${GO_BIN}" mod download
        "${GO_BIN}" build -v -o "${WORK_DIR}/v2node" -trimpath \
            -ldflags "-X 'github.com/wyx2685/v2node/cmd.version=${version}' -s -w -buildid="
    )
    [[ -s "${WORK_DIR}/v2node" ]] || die "build did not produce a binary"
}

prepare_binary() {
    if [[ -n "${PREBUILT_BINARY}" ]]; then
        [[ -s "${PREBUILT_BINARY}" ]] || die "prebuilt binary not found: ${PREBUILT_BINARY}"
        install -m 0755 "${PREBUILT_BINARY}" "${WORK_DIR}/v2node"
        log "Using the prebuilt MPTCP binary"
        return
    fi

    warn "No prebuilt binary was supplied; falling back to a local Go build"
    install_go
    build_binary
}

configure_node() {
    install -d -m 0755 "${CONFIG_DIR}"

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        if [[ -z "${API_HOST}" ]]; then
            read -r -p "XiaoV2board API URL: " API_HOST
        fi
        if [[ -z "${NODE_ID}" ]]; then
            read -r -p "V2Node ID: " NODE_ID
        fi
        if [[ -z "${API_KEY}" ]]; then
            read -r -s -p "server_token: " API_KEY
            echo
        fi
        [[ "${NODE_ID}" =~ ^[0-9]+$ ]] || die "node ID must be an integer"
        [[ -n "${API_HOST}" && -n "${API_KEY}" ]] || die "API URL and key are required"

        jq -n \
            --arg host "${API_HOST}" \
            --argjson node_id "${NODE_ID}" \
            --arg key "${API_KEY}" \
            '{
                Log: {Level: "warning", Output: "", Access: "none"},
                Nodes: [{
                    ApiHost: $host,
                    NodeID: $node_id,
                    ApiKey: $key,
                    Timeout: 15,
                    EnableMPTCP: true
                }]
            }' > "${CONFIG_FILE}"
        chmod 0600 "${CONFIG_FILE}"
        log "Created ${CONFIG_FILE}"
        return
    fi

    jq -e '.Nodes and (.Nodes | type == "array")' "${CONFIG_FILE}" >/dev/null \
        || die "${CONFIG_FILE} is not a valid v2node JSON config"
    cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    jq '(.Nodes[] | .EnableMPTCP) = true' "${CONFIG_FILE}" > "${WORK_DIR}/config.json"
    install -m 0600 "${WORK_DIR}/config.json" "${CONFIG_FILE}"
    log "Enabled MPTCP in the existing config; a timestamped backup was kept"
}

enable_kernel_mptcp() {
    if [[ ! -e /proc/sys/net/mptcp/enabled ]]; then
        warn "the running kernel does not expose net.mptcp.enabled; MPTCP may fall back to TCP"
        return
    fi
    echo 'net.mptcp.enabled = 1' > /etc/sysctl.d/90-v2node-mptcp.conf
    sysctl -q -w net.mptcp.enabled=1
    log "Enabled Linux MPTCP"
}

install_data_files() {
    local name
    for name in geoip geosite; do
        if [[ ! -s "${CONFIG_DIR}/${name}.dat" ]]; then
            log "Downloading ${name}.dat"
            curl -fL "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/${name}.dat" \
                -o "${CONFIG_DIR}/${name}.dat"
        fi
    done
}

install_service() {
    install -d -m 0755 "${PREFIX}"
    if [[ -x "${PREFIX}/v2node" ]]; then
        BACKUP_BINARY="${PREFIX}/v2node.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "${PREFIX}/v2node" "${BACKUP_BINARY}"
        log "Backed up the existing binary to ${BACKUP_BINARY}"
    fi

    systemctl stop v2node 2>/dev/null || true
    install -m 0755 "${WORK_DIR}/v2node" "${PREFIX}/v2node"
    install -m 0755 "${SOURCE_ROOT}/script/v2node-mptcp.sh" /usr/bin/v2node

    cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=v2node MPTCP Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
Type=simple
LimitNOFILE=999999
WorkingDirectory=/usr/local/v2node/
ExecStart=/usr/local/v2node/v2node server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable v2node >/dev/null
    if systemctl restart v2node && sleep 2 && systemctl is-active --quiet v2node; then
        log "v2node MPTCP edition is running"
        return
    fi

    systemctl status v2node --no-pager -l || true
    if [[ -n "${BACKUP_BINARY}" && -f "${BACKUP_BINARY}" ]]; then
        warn "startup failed; restoring the previous binary"
        install -m 0755 "${BACKUP_BINARY}" "${PREFIX}/v2node"
        systemctl restart v2node || true
    fi
    die "v2node failed to start; inspect: journalctl -u v2node -n 100 --no-pager"
}

install_packages
prepare_binary
configure_node
enable_kernel_mptcp
install_data_files
install_service

echo
log "Installation complete"
echo "Config: ${CONFIG_FILE}"
echo "Status: systemctl status v2node --no-pager"
echo "Logs:   journalctl -u v2node -n 100 --no-pager"
echo "Menu:   v2node"
echo
log "Use 'v2node' to manage services and multiple nodes."
