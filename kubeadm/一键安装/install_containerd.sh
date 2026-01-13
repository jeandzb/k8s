#!/bin/bash

# =======================================================================
# 脚本名称: install_containerd.sh
# 功能描述: 安装 Containerd, 配置国内源, 开启 SystemdCgroup, 替换沙箱镜像
# 适用系统: CentOS 9 / RHEL 9 / Rocky Linux 9 / AlmaLinux 9
# =======================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}
log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}
log_err() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   log_err "请使用 root 用户运行此脚本"
   exit 1
fi

# 1. 配置 Docker/Containerd YUM 源
config_repo() {
    log_info "正在配置阿里云 Docker YUM 源 (CentOS/RHEL 9)..."

    cat <<EOF | tee /etc/yum.repos.d/docker-ce.repo > /dev/null
[docker-ce-stable]
name=Docker CE Stable - Aliyun
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/9/x86_64/stable/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF

    log_info "YUM 源配置完成"
}

# 2. 安装依赖和 Containerd
install_containerd() {
    log_info "正在安装依赖工具..."
    dnf install -y yum-utils device-mapper-persistent-data lvm2

    log_info "正在安装 containerd.io (最新版)..."
    # 如果需要指定版本，可以使用: dnf install -y containerd.io-1.7.13
    dnf install -y containerd.io

    if [ $? -eq 0 ]; then
        log_info "Containerd 安装成功"
    else
        log_err "Containerd 安装失败，请检查网络或源配置"
        exit 1
    fi

    # 设置开机启动（暂不立即启动，等配置改完再重启）
    systemctl enable containerd
}

# 3. 初始化并修改配置 (关键步骤)
configure_containerd() {
    log_info "正在初始化并修改 containerd 配置文件..."

    mkdir -p /etc/containerd

    # 导出默认配置
    containerd config default > /etc/containerd/config.toml

    if [ ! -f /etc/containerd/config.toml ]; then
        log_err "配置文件生成失败"
        exit 1
    fi

    # --- 修改配置 ---

    # 1. 配置 SystemdCgroup = true (K8s 强制要求)
    # 使用 sed 匹配 SystemdCgroup = false 并改为 true
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    log_info "已开启 SystemdCgroup"

    # 2. 修改 sandbox_image (pause 镜像)
    # 原命令: sed -i "s|registry.k8s.io/pause:3.10.1|...|g"
    # 优化后: 使用正则匹配 "registry.k8s.io/pause:.*"，这样无论默认版本是 3.6, 3.8 还是 3.10 都能成功替换
    # 目标版本: registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10

    sed -i 's|registry.k8s.io/pause:.*"|registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10"|g' /etc/containerd/config.toml

    # 验证一下是否修改成功
    if grep -q "SystemdCgroup = true" /etc/containerd/config.toml && grep -q "aliyuncs.com" /etc/containerd/config.toml; then
        log_info "镜像源已替换为阿里云 (pause:3.10)"
    else
        log_warn "配置文件修改可能未完全成功，请人工检查 /etc/containerd/config.toml"
    fi
}

# 4. 启动服务
start_service() {
    log_info "正在重启 containerd 服务..."
    systemctl restart containerd

    # 检查状态
    if systemctl is-active --quiet containerd; then
        log_info "Containerd 服务运行正常 (Active)"
    else
        log_err "Containerd 服务启动失败，请运行 'systemctl status containerd' 查看详情"
        exit 1
    fi
}

# === 主程序 ===
echo "================================================="
echo "   开始安装与配置 Containerd"
echo "================================================="

config_repo
install_containerd
configure_containerd
start_service

echo "================================================="
echo -e "${GREEN}   Containerd 部署完成! ${NC}"
echo "================================================="