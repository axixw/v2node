#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${V2NODE_REPOSITORY:-axixw/v2node}"
BRANCH="${V2NODE_BRANCH:-mptcp}"
WORK_DIR="$(mktemp -d)"
ARCHIVE="${WORK_DIR}/v2node.tar.gz"
SOURCE_DIR="${WORK_DIR}/source"

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

echo -e "${green}[v2node-mptcp]${plain} Downloading ${REPOSITORY}@${BRANCH}"
wget -q --show-progress \
    "https://github.com/${REPOSITORY}/archive/refs/heads/${BRANCH}.tar.gz" \
    -O "${ARCHIVE}"

mkdir -p "${SOURCE_DIR}"
tar -xzf "${ARCHIVE}" -C "${SOURCE_DIR}" --strip-components=1

[[ -f "${SOURCE_DIR}/go.mod" ]] || die "downloaded archive does not contain go.mod"
[[ -f "${SOURCE_DIR}/script/install-mptcp.sh" ]] \
    || die "downloaded branch does not contain script/install-mptcp.sh"

bash "${SOURCE_DIR}/script/install-mptcp.sh" "$@"
