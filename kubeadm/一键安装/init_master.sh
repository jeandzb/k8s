#!/bin/bash

# =======================================================================
# 脚本名称: init_master.sh
# 功能描述: 生成 Kubeadm 配置, 修改为国内源, 执行初始化, 配置 Kubeconfig
# 适用系统: CentOS 9 / RHEL 9
# =======================================================================

# --- 配置参数 (可根据实际情况修改) ---
# 自动获取本机网卡 IP (默认取第一张网卡的 IP)
MASTER_IP=$(ip route get 1 | awk '{print $7; exit}')
# Kubernetes 版本 (需与之前安装的工具版本一致)
KUBE_VERSION="v1.33.0"
# 容器镜像仓库
IMAGE_REPO="registry.aliyuncs.com/google_containers"
# Pod 网段 (常用: 10.244.0.0/16 for Flannel, 192.168.0.0/16 for Calico)
POD_SUBNET="10.244.0.0/16"
# Service 网段
SERVICE_SUBNET="10.96.0.0/12"
# 配置文件名称
CONFIG_FILE="kubeadm-init.yml"
# 日志文件
LOG_FILE="kubeadm-init.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err()  { echo -e "${RED}[ERROR] $1${NC}"; }

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   log_err "请使用 root 用户运行此脚本"
   exit 1
fi

# 1. 环境检查
check_env() {
    log_info "检查环境..."
    # 检查 kubeadm 是否安装
    if ! command -v kubeadm &> /dev/null; then
        log_err "未找到 kubeadm 命令，请先执行上一步的安装脚本。"
        exit 1
    fi
    # 检查端口占用
    if netstat -tuln | grep -q :6443; then
        log_err "端口 6443 已被占用，集群可能已经初始化过。"
        exit 1
    fi

    # 动态获取版本 (如果未手动指定，则使用 installed version)
    INSTALLED_VERSION=$(kubeadm version -o short)
    log_info "本机 IP: ${CYAN}${MASTER_IP}${NC}"
    log_info "Kubeadm 版本: ${CYAN}${INSTALLED_VERSION}${NC}"
}

# 2. 生成并修改配置文件
generate_config() {
    log_info "正在生成并修改初始化配置文件 ($CONFIG_FILE)..."

    # 生成默认配置
    kubeadm config print init-defaults > ${CONFIG_FILE}

    # --- 使用 sed 修改配置 ---

    # 1. 修改 Advertise Address (API Server 监听地址)
    sed -i "s/advertiseAddress: 1.2.3.4/advertiseAddress: ${MASTER_IP}/" ${CONFIG_FILE}

    # 2. 修改 Node Name (默认为 node) -> 主机名
    sed -i "s/name: node/name: $(hostname)/" ${CONFIG_FILE}

    # 3. 修改 Image Repository (registry.k8s.io -> 阿里云)
    sed -i "s|imageRepository: registry.k8s.io|imageRepository: ${IMAGE_REPO}|" ${CONFIG_FILE}

    # 4. 修改 Kubernetes Version (确保匹配)
    # 注意：init-defaults 生成的版本可能较旧，强制替换为实际安装版本
    sed -i "s/kubernetesVersion: .*/kubernetesVersion: ${INSTALLED_VERSION}/" ${CONFIG_FILE}

    # 5. 添加 Pod Subnet (Networking 部分)
    # 在 serviceSubnet 下一行插入 podSubnet
    sed -i "/serviceSubnet: .*/a \  podSubnet: ${POD_SUBNET}" ${CONFIG_FILE}

    # 6. (可选) 如果使用 Containerd 且 socket 路径不同，需确认 criSocket 字段
    # init-defaults 默认通常是 unix:///var/run/containerd/containerd.sock，一般无需修改

    log_info "配置文件修改完成，关键参数如下："
    grep -E "advertiseAddress|imageRepository|kubernetesVersion|podSubnet" ${CONFIG_FILE}
}

# 3. 执行初始化
run_init() {
    echo "-------------------------------------------------"
    log_info "开始初始化集群 (这可能需要几分钟)..."
    echo "-------------------------------------------------"

    # 执行初始化并记录日志
    # --upload-certs: 自动分发证书
    kubeadm init --config=${CONFIG_FILE} --upload-certs | tee ${LOG_FILE}

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_err "集群初始化失败！请查看上方错误信息或日志文件: ${LOG_FILE}"
        exit 1
    fi
}

# 4. 配置 Kubeconfig (当前用户)
configure_kube() {
    log_info "正在配置 Kubeconfig..."

    mkdir -p $HOME/.kube
    # 强制覆盖 (-f)
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    # 设置环境变量 (追加到 .bash_profile 以持久化)
    if ! grep -q "KUBECONFIG" $HOME/.bash_profile; then
        echo "export KUBECONFIG=$HOME/.kube/config" >> $HOME/.bash_profile
        log_info "环境变量已添加到 ~/.bash_profile"
    fi

    export KUBECONFIG=$HOME/.kube/config
}

# 5. 提取并展示加入命令
display_tokens() {
    echo ""
    echo "=========================================================="
    echo -e "${GREEN}   Kubernetes Control-Plane 初始化成功! ${NC}"
    echo "=========================================================="

    echo -e "${YELLOW}>>> 1. Master 节点加入命令 (Control Plane):${NC}"
    # 提取包含 certificate-key 的部分 (通常 grep 匹配 context 比较复杂，这里简化提取)
    # 查找日志中 "kubeadm join" 且包含 "control-plane" 的行
    grep -A 2 "kubeadm join.*control-plane" ${LOG_FILE} | head -n 3

    echo -e "\n${YELLOW}>>> 2. Worker 节点加入命令:${NC}"
    # 查找日志最后出现的 kubeadm join (Worker join 通常在最后)
    grep -A 1 "kubeadm join" ${LOG_FILE} | tail -n 2

    echo "=========================================================="
    echo -e "${CYAN}下一步建议:${NC}"
    echo "1. 部署 CNI 网络插件 (例如 Calico):"
    echo "   kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml"
    echo "2. 检查节点状态:"
    echo "   kubectl get nodes"
    echo "=========================================================="
}

# === 执行流程 ===
check_env
generate_config
run_init
configure_kube
display_tokens