#!/bin/bash

# =======================================================================
# 脚本名称: install_k8s_tools.sh
# 功能描述: 配置 K8s 源, 安装 kubelet/kubeadm/kubectl, 预拉取镜像, 配置补全
# 适用系统: CentOS 9 / RHEL 9 (基于 DNF)
# Kubernetes版本: v1.33 (源路径固定为 v1.33)
# =======================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# 1. 配置 Kubernetes YUM 源
config_repo() {
    log_info "正在配置 Kubernetes YUM 源 (Aliyun v1.33)..."

    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo > /dev/null
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.33/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.33/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

    log_info "刷新 DNF 缓存..."
    dnf clean all
    dnf makecache
}

# 2. 安装 Kubelet, Kubeadm, Kubectl
install_tools() {
    log_info "正在安装 kubelet, kubeadm, kubectl..."

    # --disableexcludes=kubernetes 是必须的，因为我们在 repo 文件中写了 exclude
    dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

    if [ $? -eq 0 ]; then
        log_info "组件安装成功"
    else
        log_err "组件安装失败，请检查网络连接"
        exit 1
    fi

    # 设置开机启动
    systemctl enable kubelet
    log_info "已设置 kubelet 开机自启 (注意: kubelet 此时尚未启动，需等待 init)"
}

# 3. 预拉取镜像 (关键步骤)
pull_images() {
    log_info "准备预拉取 K8s 核心镜像..."

    # 自动获取当前安装的 kubeadm 版本 (例如 v1.33.7)
    KUBE_VERSION=$(kubeadm version -o short)
    IMAGE_REPO="registry.aliyuncs.com/google_containers"

    log_info "检测到安装版本: ${CYAN}${KUBE_VERSION}${NC}"
    log_info "镜像仓库地址: ${IMAGE_REPO}"

    # 列出镜像并检查 pause 版本
    log_info "--- 计划拉取的镜像列表 ---"
    kubeadm config images list --kubernetes-version=${KUBE_VERSION} --image-repository=${IMAGE_REPO}

    # 提取 Pause 版本进行提示
    PAUSE_VERSION=$(kubeadm config images list --kubernetes-version=${KUBE_VERSION} --image-repository=${IMAGE_REPO} | grep pause | awk -F':' '{print $2}')

    echo "-------------------------------------------------"
    log_warn "请确认 Pause 镜像版本: [ ${PAUSE_VERSION} ]"
    log_warn "该版本必须与 Containerd 配置文件(/etc/containerd/config.toml) 中的版本一致！"
    echo "-------------------------------------------------"

    # 开始拉取
    log_info "开始拉取镜像 (这可能需要几分钟)..."
    kubeadm config images pull --kubernetes-version=${KUBE_VERSION} --image-repository=${IMAGE_REPO}

    if [ $? -eq 0 ]; then
        log_info "镜像拉取完成"
    else
        log_err "镜像拉取失败"
        exit 1
    fi
}

# 4. 配置命令自动补全
config_completion() {
    log_info "配置 Bash 命令自动补全..."

    # 安装 bash-completion
    dnf install -y bash-completion > /dev/null 2>&1

    # 配置 kubeadm 补全
    kubeadm completion bash > /etc/bash_completion.d/kubeadm

    # 配置 kubectl 补全
    kubectl completion bash > /etc/bash_completion.d/kubectl

    # 尝试在当前 shell 加载 (对子 shell 不一定生效，建议用户重新登录)
    source /etc/bash_completion.d/kubeadm 2>/dev/null
    source /etc/bash_completion.d/kubectl 2>/dev/null

    log_info "命令补全已配置 (下次登录或执行 'bash' 后生效)"
}

# 5. 版本验证
verify_version() {
    echo "================================================="
    log_info "安装版本信息如下:"
    echo "-------------------------------------------------"
    echo -n "Kubeadm: " && kubeadm version -o short
    echo -n "Kubectl: " && kubectl version --client --output=yaml | grep gitVersion | head -n 1
    echo "-------------------------------------------------"
}

# === 主程序 ===
echo "================================================="
echo "   开始安装 K8s 核心组件 (Node 节点)"
echo "================================================="

config_repo
install_tools
pull_images
config_completion
verify_version

echo "================================================="
echo -e "${GREEN}   所有组件安装完毕! ${NC}"
echo -e "${YELLOW}   提示: 如果是主节点，请继续执行 'kubeadm init ...'${NC}"
echo -e "${YELLOW}   提示: 如果是工作节点，请等待主节点初始化完成后执行 'kubeadm join ...'${NC}"
echo "================================================="