#!/usr/bin/env bash
set -uo pipefail

CONFIG_DIR="/etc/v2node-mptcp"
CONFIG_FILE="${CONFIG_DIR}/config.json"
INSTALL_DIR="/usr/local/v2node-mptcp"
BINARY_FILE="${INSTALL_DIR}/v2node-mptcp"
SERVICE_NAME="v2node-mptcp"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MANAGER_FILE="/usr/bin/v2node-mptcp"
INSTALL_URL="https://raw.githubusercontent.com/axixw/v2node/refs/heads/mptcp/script/install.sh"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

die() {
    echo -e "${red}错误:${plain} $*" >&2
    exit 1
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 用户运行"
}

require_installed() {
    [[ -x "${BINARY_FILE}" ]] || die "v2node MPTCP 尚未安装"
}

require_config() {
    require_installed
    [[ -f "${CONFIG_FILE}" ]] || die "找不到 ${CONFIG_FILE}"
    jq -e '.Nodes and (.Nodes | type == "array")' "${CONFIG_FILE}" >/dev/null \
        || die "${CONFIG_FILE} 不是有效的 v2node 配置"
}

pause() {
    read -r -p "按回车返回主菜单: " _
}

service_active() {
    systemctl is-active --quiet "${SERVICE_NAME}"
}

restart_service() {
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    if service_active; then
        echo -e "${green}v2node MPTCP 重启成功${plain}"
        return 0
    fi
    systemctl status "${SERVICE_NAME}" --no-pager -l || true
    return 1
}

backup_config() {
    local backup
    backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${CONFIG_FILE}" "${backup}"
    echo "${backup}"
}

write_config() {
    local source_file="$1"
    local backup="$2"
    install -m 0600 "${source_file}" "${CONFIG_FILE}"
    if restart_service; then
        echo -e "配置备份: ${yellow}${backup}${plain}"
        return 0
    fi
    echo -e "${red}新配置启动失败，正在恢复备份${plain}"
    install -m 0600 "${backup}" "${CONFIG_FILE}"
    systemctl restart "${SERVICE_NAME}" || true
    return 1
}

list_nodes() {
    require_config
    local count
    count="$(jq '.Nodes | length' "${CONFIG_FILE}")"
    echo
    echo -e "${green}已配置节点 (${count})${plain}"
    echo "序号  节点ID  MPTCP  面板地址"
    echo "------------------------------------------------------------"
    jq -r '.Nodes | to_entries[] |
        "\(.key + 1)\t\(.value.NodeID)\t\(if .value.EnableMPTCP == true then "开启" else "关闭" end)\t\(.value.ApiHost)"' \
        "${CONFIG_FILE}"
    echo
}

add_node() {
    require_config
    local api_host node_id api_key backup temp_file
    read -r -p "面板 API 地址（例如 https://example.com/）: " api_host
    read -r -p "节点 ID: " node_id
    read -r -s -p "server_token: " api_key
    echo

    [[ -n "${api_host}" && -n "${api_key}" ]] || die "面板地址和 server_token 不能为空"
    [[ "${node_id}" =~ ^[0-9]+$ ]] || die "节点 ID 必须是整数"

    if jq -e --arg host "${api_host}" --argjson id "${node_id}" \
        '.Nodes[] | select(.ApiHost == $host and .NodeID == $id)' \
        "${CONFIG_FILE}" >/dev/null; then
        die "这个面板地址和节点 ID 已经存在"
    fi

    backup="$(backup_config)"
    temp_file="$(mktemp)"
    jq --arg host "${api_host}" --argjson id "${node_id}" --arg key "${api_key}" \
        '.Nodes += [{
            ApiHost: $host,
            NodeID: $id,
            ApiKey: $key,
            Timeout: 15,
            EnableMPTCP: true
        }]' "${CONFIG_FILE}" > "${temp_file}" || {
            rm -f "${temp_file}"
            die "生成配置失败"
        }
    write_config "${temp_file}" "${backup}"
    rm -f "${temp_file}"
}

remove_node() {
    require_config
    local count choice index backup temp_file description
    count="$(jq '.Nodes | length' "${CONFIG_FILE}")"
    (( count > 1 )) || die "当前只有一个节点，不能删除最后一个节点"
    list_nodes
    read -r -p "请输入要删除的序号（输入 0 取消）: " choice
    [[ "${choice}" =~ ^[0-9]+$ ]] || die "请输入正确的数字"
    (( choice == 0 )) && return 0
    (( choice >= 1 && choice <= count )) || die "节点序号超出范围"
    index=$((choice - 1))
    description="$(jq -r --argjson index "${index}" \
        '.Nodes[$index] | "ID=\(.NodeID), \(.ApiHost)"' "${CONFIG_FILE}")"
    read -r -p "确认删除 ${description}？[y/N]: " confirm
    [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || return 0

    backup="$(backup_config)"
    temp_file="$(mktemp)"
    jq --argjson index "${index}" 'del(.Nodes[$index])' "${CONFIG_FILE}" > "${temp_file}" || {
        rm -f "${temp_file}"
        die "生成配置失败"
    }
    write_config "${temp_file}" "${backup}"
    rm -f "${temp_file}"
}

edit_config() {
    require_config
    local editor backup
    backup="$(backup_config)"
    editor="${EDITOR:-vi}"
    "${editor}" "${CONFIG_FILE}"
    jq -e '.Nodes and (.Nodes | type == "array")' "${CONFIG_FILE}" >/dev/null || {
        echo -e "${red}JSON 格式错误，正在恢复备份${plain}"
        install -m 0600 "${backup}" "${CONFIG_FILE}"
        return 1
    }
    jq '(.Nodes[] | .EnableMPTCP) = true' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
    write_config "${CONFIG_FILE}.tmp" "${backup}"
    rm -f "${CONFIG_FILE}.tmp"
}

run_installer() {
    local installer
    installer="$(mktemp)"
    curl -fsSL "${INSTALL_URL}" -o "${installer}" || {
        rm -f "${installer}"
        die "下载安装脚本失败，请检查服务器能否访问 GitHub"
    }
    bash "${installer}"
    local result=$?
    rm -f "${installer}"
    return "${result}"
}

uninstall_v2node() {
    read -r -p "确认卸载 v2node MPTCP？它的配置和证书也会删除，原版不受影响。[y/N]: " confirm
    [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || return 0
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    rm -rf "${CONFIG_DIR}" "${INSTALL_DIR}"
    rm -f /etc/sysctl.d/90-v2node-mptcp.conf
    echo -e "${green}v2node MPTCP 卸载完成，原版 v2node 没有改动。${plain}"
    echo "如需删除本管理命令，请退出后执行：rm -f ${MANAGER_FILE}"
}

show_menu() {
    while true; do
        local status
        if service_active; then
            status="${green}运行中${plain}"
        elif [[ -x "${BINARY_FILE}" ]]; then
            status="${yellow}已停止${plain}"
        else
            status="${red}未安装${plain}"
        fi
        echo -e "
${green}v2node MPTCP 独立版管理菜单${plain}
状态: ${status}
----------------------------------------
  1. 查看节点
  2. 添加节点
  3. 删除节点
  4. 修改完整配置
----------------------------------------
  5. 启动 v2node MPTCP
  6. 停止 v2node MPTCP
  7. 重启 v2node MPTCP
  8. 查看状态
  9. 查看日志
----------------------------------------
 10. 更新 MPTCP 版本
 11. 安装 v2node MPTCP
 12. 卸载 v2node MPTCP
  0. 退出
"
        read -r -p "请输入选择 [0-12]: " choice
        case "${choice}" in
            1) list_nodes; pause ;;
            2) add_node; pause ;;
            3) remove_node; pause ;;
            4) edit_config; pause ;;
            5) require_installed; systemctl start "${SERVICE_NAME}"; pause ;;
            6) require_installed; systemctl stop "${SERVICE_NAME}"; pause ;;
            7) require_installed; restart_service; pause ;;
            8) require_installed; systemctl status "${SERVICE_NAME}" --no-pager -l; pause ;;
            9) require_installed; journalctl -u "${SERVICE_NAME}" -e --no-pager -f ;;
            10) require_installed; run_installer; pause ;;
            11) run_installer; pause ;;
            12) uninstall_v2node; pause ;;
            0) exit 0 ;;
            *) echo -e "${red}请输入 0 到 12 之间的数字${plain}" ;;
        esac
    done
}

show_usage() {
    echo "用法:"
    echo "  v2node-mptcp              显示管理菜单"
    echo "  v2node-mptcp list         查看节点"
    echo "  v2node-mptcp add          添加节点"
    echo "  v2node-mptcp remove       删除节点"
    echo "  v2node-mptcp config       修改完整配置"
    echo "  v2node-mptcp start|stop|restart|status|log"
    echo "  v2node-mptcp update       更新 MPTCP 版本"
}

require_root
case "${1:-menu}" in
    menu) show_menu ;;
    list) list_nodes ;;
    add) add_node ;;
    remove) remove_node ;;
    config) edit_config ;;
    start) require_installed; systemctl start "${SERVICE_NAME}" ;;
    stop) require_installed; systemctl stop "${SERVICE_NAME}" ;;
    restart) require_installed; restart_service ;;
    status) require_installed; systemctl status "${SERVICE_NAME}" --no-pager -l ;;
    log) require_installed; journalctl -u "${SERVICE_NAME}" -e --no-pager -f ;;
    update) require_installed; run_installer ;;
    install) run_installer ;;
    uninstall) uninstall_v2node ;;
    help|-h|--help) show_usage ;;
    *) show_usage; exit 1 ;;
esac
