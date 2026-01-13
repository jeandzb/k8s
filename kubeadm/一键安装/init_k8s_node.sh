#!/bin/bash

# =======================================================================
# 脚本名称: init_k8s_node.sh
# 功能描述: Kubernetes 节点环境初始化 (防火墙, Swap, 内核模块, 时间同步, IPVS)
# 适用系统: CentOS 7/8, Rocky, Alma, Anolis, Alibaba Cloud Linux (使用 DNF/YUM)
# =======================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 打印日志函数
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}
log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}
log_err() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
   log_err "此脚本必须以 root 用户运行"
   exit 1
fi

# 1. 关闭防火墙与 SELinux
configure_security() {
    log_info "正在配置系统安全设置 (Firewall & SELinux)..."

    # 关闭防火墙
    if systemctl list-unit-files | grep -q firewalld; then
        systemctl stop firewalld
        systemctl disable firewalld
        log_info "Firewalld 已关闭"
    else
        log_warn "未找到 Firewalld 服务，跳过停止操作"
    fi

    # 关闭 SELinux
    setenforce 0 2>/dev/null
    sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
    log_info "SELINUX 已禁用 (需重启生效)"
}

# 2. 禁用 Swap
disable_swap() {
    log_info "正在禁用 Swap..."
    swapoff -a
    # 注释掉 fstab 中的 swap 行 (使用更通用的匹配方式)
    sed -ri 's/.*swap.*/#&/' /etc/fstab

    # 二次检查
    if [ $(free -m | grep -i swap | awk '{print $2}') -eq 0 ]; then
        log_info "Swap 已成功禁用"
    else
        log_warn "Swap 禁用可能未完全生效，请检查 /etc/fstab"
    fi
}

# 3. 加载 K8s 基础内核模块
load_k8s_modules() {
    log_info "正在加载 K8s 基础内核模块..."
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    lsmod | grep br_netfilter > /dev/null && log_info "模块 br_netfilter 加载成功" || log_err "模块 br_netfilter 加载失败"
}

# 4. 配置网络参数 (Sysctl)
configure_sysctl() {
    log_info "正在配置 Sysctl 网络参数..."
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system > /dev/null 2>&1
    log_info "Sysctl 参数已刷新"
}

# 5. 配置时间同步 (Chrony)
configure_time_sync() {
    log_info "正在配置时间同步 (Chrony)..."

    # 安装 chrony 如果不存在
    if ! command -v chronyd &> /dev/null; then
        log_info "未检测到 chrony，正在安装..."
        dnf install chrony -y > /dev/null
    fi

    # 备份原有配置
    if [ ! -f /etc/chrony.conf.bak ]; then
        cp /etc/chrony.conf /etc/chrony.conf.bak
    fi

    # 写入阿里云 NTP 源 (覆盖写入以避免重复追加)
    cat > /etc/chrony.conf << EOF
# 使用阿里云 NTP 服务器
pool ntp1.aliyun.com iburst
pool ntp2.aliyun.com iburst
pool cn.pool.ntp.org iburst

# 默认配置保留
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

    systemctl enable --now chronyd
    systemctl restart chronyd
    log_info "Chronyd 服务已重启并设置开机自启"

    # 稍微等待服务启动
    sleep 2
    chronyc sources
}

# 6. 配置 IPVS (可选但推荐)
configure_ipvs() {
    log_info "正在配置 IPVS 模式..."

    # 安装 ipset 和 ipvsadm
    dnf install ipset ipvsadm -y > /dev/null 2>&1
    log_info "已安装 ipset 和 ipvsadm"

    # 添加模块配置
    cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

    # 手动加载模块 (处理旧版内核模块名称差异)
    modprobe overlay
    modprobe ip_vs
    modprobe ip_vs_rr
    modprobe ip_vs_wrr
    modprobe ip_vs_sh

    if modprobe nf_conntrack 2>/dev/null; then
        log_info "已加载 nf_conntrack"
    else
        log_warn "尝试加载 nf_conntrack 失败，尝试旧版 nf_conntrack_ipv4..."
        modprobe nf_conntrack_ipv4 2>/dev/null
    fi

    log_info "IPVS 模块检查结果:"
    lsmod | grep -e ip_vs -e nf_conntrack
}

# === 主程序执行 ===
echo "================================================="
echo "   开始执行 Kubernetes 节点初始化脚本"
echo "================================================="

configure_security
disable_swap
load_k8s_modules
configure_sysctl
configure_time_sync
configure_ipvs

echo "================================================="
echo -e "${GREEN}   所有初始化步骤执行完毕! ${NC}"
echo -e "${YELLOW}   提示: 建议您重启服务器以确保所有配置(特别是 SELinux)彻底生效。${NC}"
echo "================================================="