#!/bin/bash

#================================================================
#
#   项目: sing-box Hysteria 2 一键安装脚本
#   功能: 在主流 Linux 发行版上快速部署 sing-box 并配置 Hysteria 2 服务
#   支持系统: Ubuntu, Debian, CentOS
#
#================================================================

# --- 彩色输出定义 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

# --- 配置参数 ---
PORT=10000
CONFIG_PATH="/usr/local/etc/sing-box"
BINARY_PATH="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"

# --- 函数定义 ---

# 检查是否以 root 用户运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以 root 用户权限运行！${PLAIN}"
        exit 1
    fi
}

# 安装必要的依赖
install_dependencies() {
    echo -e "${BLUE}正在检查并安装必要的依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y curl wget openssl jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget openssl jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget openssl jq
    else
        echo -e "${RED}错误: 未知的包管理器，无法安装依赖。${PLAIN}"
        exit 1
    fi
}

# 下载并安装 sing-box
install_sing_box() {
    echo -e "${BLUE}正在下载最新版本的 sing-box...${PLAIN}"
    
    # 获取系统架构
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            echo -e "${RED}错误: 不支持的系统架构: ${ARCH}${PLAIN}"
            exit 1
            ;;
    esac

    # 从 GitHub API 获取最新版本信息
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}错误: 无法获取 sing-box 的最新版本号。${PLAIN}"
        exit 1
    fi
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"

    wget -O sing-box.tar.gz ${DOWNLOAD_URL}
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: sing-box 下载失败。${PLAIN}"
        exit 1
    fi

    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${ARCH}/sing-box ${BINARY_PATH}
    chmod +x ${BINARY_PATH}
    
    # 清理
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${ARCH}
    echo -e "${GREEN}sing-box v${LATEST_VERSION} 安装成功！${PLAIN}"
}

# 生成配置文件
generate_config() {
    echo -e "${BLUE}正在生成配置文件...${PLAIN}"
    mkdir -p ${CONFIG_PATH}
    
    # 随机生成密码
    PASSWORD=$(openssl rand -base64 16)
    
    # 生成自签名证书
    openssl ecparam -genkey -name prime256v1 -out ${CONFIG_PATH}/private.key
    openssl req -new -x509 -days 3650 -key ${CONFIG_PATH}/private.key -out ${CONFIG_PATH}/certificate.pem -subj "/CN=bing.com"
    
    # 创建 config.json 文件
    cat > ${CONFIG_PATH}/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CONFIG_PATH}/certificate.pem",
        "key_path": "${CONFIG_PATH}/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 设置 systemd 服务
setup_systemd() {
    echo -e "${BLUE}正在设置 systemd 服务...${PLAIN}"
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=${BINARY_PATH} run -c ${CONFIG_PATH}/config.json
Restart=on-failure
RestartSec=10
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 配置防火墙
configure_firewall() {
    echo -e "${BLUE}正在配置防火墙...${PLAIN}"
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --add-port=${PORT}/udp --permanent
        firewall-cmd --reload
        echo -e "${GREEN}firewalld: 已开放端口 ${PORT}/udp${PLAIN}"
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow ${PORT}/udp
        echo -e "${GREEN}ufw: 已开放端口 ${PORT}/udp${PLAIN}"
    else
        echo -e "${YELLOW}警告: 未检测到 firewalld 或 ufw，请手动开放端口 ${PORT}/udp。${PLAIN}"
    fi
}

# 启动服务并显示信息
start_and_display_info() {
    echo -e "${BLUE}正在启动 sing-box 服务...${PLAIN}"
    systemctl enable --now ${SERVICE_NAME}
    
    # 检查服务状态
    sleep 2
    if ! systemctl is-active --quiet ${SERVICE_NAME}; then
        echo -e "${RED}错误: sing-box 服务启动失败！请检查日志。${PLAIN}"
        echo -e "${YELLOW}使用 'journalctl -u ${SERVICE_NAME} -n 50 --no-pager' 查看日志。${PLAIN}"
        exit 1
    fi
    
    PUBLIC_IP=$(curl -s ip.sb)
    SHARE_LINK="hysteria2://${PASSWORD}@${PUBLIC_IP}:${PORT}?insecure=1&sni=bing.com#Hysteria2-$(hostname)"
    
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${GREEN} sing-box (Hysteria 2) 安装成功!                  ${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
    echo -e "${YELLOW} 服务器地址 (Address):  ${PLAIN}${PUBLIC_IP}"
    echo -e "${YELLOW} 端口 (Port):           ${PLAIN}${PORT}"
    echo -e "${YELLOW} 密码 (Password):       ${PLAIN}${PASSWORD}"
    echo -e "${YELLOW} TLS (insecure):      ${PLAIN}true (因为是自签名证书)"
    echo -e "${YELLOW} SNI / 域名伪装:      ${PLAIN}bing.com"
    echo -e ""
    echo -e "${BLUE}--- Hysteria2 分享链接 ---${PLAIN}"
    echo -e "${GREEN}${SHARE_LINK}${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}你可以使用 'systemctl status ${SERVICE_NAME}' 查看服务状态。${PLAIN}"
    echo -e "${YELLOW}配置文件位于: ${CONFIG_PATH}/config.json${PLAIN}"
    echo -e "${GREEN}===================================================${PLAIN}"
}

# --- 主逻辑 ---
main() {
    check_root
    install_dependencies
    install_sing_box
    generate_config
    setup_systemd
    configure_firewall
    start_and_display_info
}

# 执行主函数
main