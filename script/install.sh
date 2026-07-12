#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${V2NODE_REPOSITORY:-axixw/v2node}"
BRANCH="${V2NODE_BRANCH:-mptcp}"
WORK_DIR="$(mktemp -d)"
ARCHIVE="${WORK_DIR}/v2node.tar.gz"
SOURCE_DIR="${WORK_DIR}/source"
RELEASE_TAG="${V2NODE_RELEASE_TAG:-mptcp-latest}"
BINARY_ARCHIVE="${WORK_DIR}/v2node-linux.tar.gz"
BINARY_CHECKSUM="${BINARY_ARCHIVE}.sha256"
BINARY_DIR="${WORK_DIR}/binary"

red='\033[0;31m'
green='\033[0;32m'
plain='\033[0m'

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() {
    echo -e "${red}[v2node-mptcp] ERROR:${plain} $*" >&2
    exit 1
}

[[ ${EUID} -eq 0 ]] || die "run this installer as root"
command -v wget >/dev/null 2>&1 || die "wget is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

case "$(uname -m)" in
    x86_64|x64|amd64) asset_arch="amd64" ;;
    aarch64|arm64) asset_arch="arm64" ;;
    *) die "unsupported architecture for prebuilt releases: $(uname -m)" ;;
esac

release_base="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}"
release_asset="v2node-linux-${asset_arch}.tar.gz"

echo -e "${green}[v2node-mptcp]${plain} Downloading prebuilt ${release_asset}"
wget -q --show-progress "${release_base}/${release_asset}" -O "${BINARY_ARCHIVE}"
wget -q "${release_base}/${release_asset}.sha256" -O "${BINARY_CHECKSUM}"

checksum="$(tr -d '[:space:]' < "${BINARY_CHECKSUM}")"
[[ "${checksum}" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid binary checksum response"
echo "${checksum}  ${BINARY_ARCHIVE}" | sha256sum -c -

mkdir -p "${BINARY_DIR}"
tar -xzf "${BINARY_ARCHIVE}" -C "${BINARY_DIR}"
[[ -s "${BINARY_DIR}/v2node" ]] || die "release archive does not contain v2node"

echo -e "${green}[v2node-mptcp]${plain} Downloading ${REPOSITORY}@${BRANCH}"
wget -q --show-progress \
    "https://github.com/${REPOSITORY}/archive/refs/heads/${BRANCH}.tar.gz" \
    -O "${ARCHIVE}"

mkdir -p "${SOURCE_DIR}"
tar -xzf "${ARCHIVE}" -C "${SOURCE_DIR}" --strip-components=1

[[ -f "${SOURCE_DIR}/go.mod" ]] || die "downloaded archive does not contain go.mod"
[[ -f "${SOURCE_DIR}/script/install-mptcp.sh" ]] \
    || die "downloaded branch does not contain script/install-mptcp.sh"

bash "${SOURCE_DIR}/script/install-mptcp.sh" \
    --binary-file "${BINARY_DIR}/v2node" \
    "$@"
