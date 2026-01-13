所有节点的基础环境配置
在所有节点执行：

关闭防火墙与 SELinux：
`systemctl stop firewalld && systemctl disable firewalld && sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config`

禁用 Swap（K8s 强制要求）：
`swapoff -a`
`sed -i '/ swap / s/^(.\*)$/#\\1/g' /etc/fstab`

加载内核模块：
```shell
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter
```
配置网络参数：
```shell
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
```
配置所有节点时间同步：
```shell
cat >> /etc/chrony.conf << EOF
pool ntp1.aliyun.com iburst
pool ntp2.aliyun.com iburst
pool cn.pool.ntp.org iburst
EOF
```
重启chronyd：
`systemctl restart chronyd`
如果没有此配置文件，需要安装
  ```shell
dnf install chrony -y
systemctl enable --now chronyd && systemctl restart chronyd
  ```
配置ipvs:
- K8S默认使用iptables，IPVS有更高级和丰富的功能，此步骤根据实际需求执行
安装IPVS
`dnf install ipset ipvsadm -y`
添加IPVS参数
```bash
cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
```
手动加载模块
```bash
modprobe overlay
modprobe ip_vs && modprobe ip_vs_rr && modprobe ip_vs_wrr && modprobe ip_vs_sh && modprobe nf_conntrack
```
- 查询是否加载成功，否则还是会使用iptables，显示包含筛选的关键字即表示加载成功
`lsmod | grep -e ip_vs -e nf_conntrack`

## 安装containerd：
如果离线安装，在此路径下载rpm包 ，注意版本
docker：https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/
aliyun：https://mirrors.aliyun.com/docker-ce/linux/centos/9/x86_64/stable/Packages/
这里使用在线安装，配置阿里云 Docker YUM 仓库
```shell
cat <<EOF | tee /etc/yum.repos.d/docker-ce.repo
[docker-ce-stable]
name=Docker CE Stable - Aliyun
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/9/x86_64/stable/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
```
安装依赖工具：
`dnf install -y yum-utils device-mapper-persistent-data lvm2`
安装最新版或指定版本：
`dnf install -y containerd.io`
or
`dnf install -y containerd.io-1.7.13`
添加开机启动并启动containerd服务
`systemctl enable containerd && systemctl start containerd && systemctl status containerd`

配置containerd：
- 修改containerd的配置，因为containerd默认从k8s官网拉取镜像

把containerd配置导出到文件
`containerd config default > /etc/containerd/config.toml`

编辑/etc/containerd/config.toml，==添加或修改==如下2项内容：
```shell
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sed -i "s|registry.k8s.io/pause:3.10.1|registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10|g" /etc/containerd/config.toml
```

systemctl restart containerd && systemctl enable containerd



## 所有节点安装 kubelet, kubeadm, kubectl

添加阿里云的k8s源：
```shell
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.33/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.33/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
```
刷新缓存：
```
dnf clean all && dnf makecache
```

安装kubelet, kubeadm, kubectl：
默认会安装https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.33/rpm/下的最新版本，如果要指定，需要根据此链接下的指定文件名
`dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes`
如果未指定版本号，安装完后，记得看下默认安装的版本号

设置kubectl开机启动
`systemctl enable kubelet`

- 安装完成后，kubelet是无法启动的，需要初始化，初始化过程中会启动kubelet

kubelet配置
查看初始化需要安装的镜像，注意版本和镜像地址
`kubeadm config images list --kubernetes-version=1.33.7 --image-repository=registry.aliyuncs.com/google_containers`
会输出如下内容：
registry.aliyuncs.com/google_containers/kube-apiserver:v1.33.7
registry.aliyuncs.com/google_containers/kube-controller-manager:v1.33.7
registry.aliyuncs.com/google_containers/kube-scheduler:v1.33.7
registry.aliyuncs.com/google_containers/kube-proxy:v1.33.7
registry.aliyuncs.com/google_containers/coredns:v1.12.0
registry.aliyuncs.com/google_containers/pause:3.10
registry.aliyuncs.com/google_containers/etcd:3.5.24-0

- 注意上面箭头中的==pause版本号==，合适是否和上面container配置中的对应版本号一致

配置从指定的仓库拉取镜像到本地，以免初始化集群时拉取不到镜像：
`kubeadm config images pull --kubernetes-version=1.33.7 --image-repository=registry.aliyuncs.com/google_containers`

#命令补全（可选）：  
`yum install -y bash-completion`
`kubeadm completion bash > /etc/bash_completion.d/kubeadm`
`kubectl completion bash > /etc/bash_completion.d/kubectl`
`source /etc/bash_completion.d/kubeadm /etc/bash_completion.d/kubect`
查看版本：
```bash
kubectl version
yum info kubeadm
```



## 初始化集群（master节点执行）：
生成初始化配置文件
`kubeadm config print init-defaults > kubeadm-init.yml`

根据示例中的内容，修改相关配置

执行初始化
`kubeadm init --config=kubeadm-init.yml --upload-certs | tee kubeadm-init.log`

--upload-certs 会把集群证书上传到 kube-system 下的 Secret 中，并在输出中提供一个 certificate-key

初始化成功后如下，其中有环境变量配置和其他节点加入集群命令 
```shell
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

You can now join any number of control-plane nodes running the following command on each as root:

  kubeadm join 192.168.0.233:6443 --token rungqb.5ghilalp7ciwk482 \
        --discovery-token-ca-cert-hash sha256:9ff4d009842407fddabc7800388e2cc8d82176dd0cf3ff8dcf5a1499c0ff3992 \
        --control-plane --certificate-key a22f412723070a183b30785bf0b856c052e4b3509a36ae47c72078733ba0f46e

Please note that the certificate-key gives access to cluster sensitive data, keep it secret!
As a safeguard, uploaded-certs will be deleted in two hours; If necessary, you can use
"kubeadm init phase upload-certs --upload-certs" to reload certs afterward.

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.0.233:6443 --token rungqb.5ghilalp7ciwk482 \
        --discovery-token-ca-cert-hash sha256:9ff4d009842407fddabc7800388e2cc8d82176dd0cf3ff8dcf5a1499c0ff3992
```
检查kubelet服务状态，初始化成功一般kubelet就启动成功了  
`systemctl status kubelet`

根据初始化成功提示的内容，配置环境变量
```
mkdir -p $HOME/.kube  
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config 
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## 安装网络插件
这里选择calico
# 下载并安装 Calico (版本 v3.27 举例)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.1/manifests/calico.yaml
根据开源地址查找最新版本文件
https://github.com/projectcalico/calico


这里不要直接安装，需要修改镜像和calico的网段，默认这部分是被注释掉的。你需要取消注释并将值修改为你配置文件中的 10.244.0.0/16。
# 找到这段配置,定位位置： kind: DaemonSet -> name: calico-node -> en
```yaml
            # 指定网段
            - name: CALICO_IPV4POOL_CIDR
              value: "10.244.0.0/16"
            # 指定物理网卡,防止使用其他虚拟网卡
            - name: IP_AUTODETECTION_METHOD
              value: "interface=ens.*"
```
以及修改3个镜像，以image:开头的5个地方
calico/kube-controllers:v3.31.3
calico/node:v3.31.3
quay.io/calico/cni:v3.31.3
由于无法直接使用，要么替换为国内能使用的镜像仓库，要么在能下载的节点上，下载后上传至k8s的所有节点，或者上传至私有仓库，对指定镜像进行公开访问不鉴权

# 1. 拉取镜像 (确保版本号与 yaml 一致)
docker pull quay.io/calico/cni:v3.31.3
docker pull quay.io/calico/node:v3.31.3
docker pull quay.io/calico/kube-controllers:v3.31.3

# 2. 打包成 tar 文件
docker save -o calico-v3.31.3.tar \
quay.io/calico/cni:v3.31.3 \
quay.io/calico/node:v3.31.3 \
quay.io/calico/kube-controllers:v3.31.3

# -n k8s.io 是关键，不加的话 k8s 无法使用该镜像
ctr -n k8s.io images import calico-v3.31.3.tar
crictl images | grep calico
# 或者
ctr -n k8s.io images list | grep calico


执行安装calico：
`kubectl apply -f calico.yaml`
检查是否安装成功，包含calico的pod即为成功
`kubectl get pod -A`
NAMESPACE     NAME                                      READY   STATUS    RESTARTS   AGE
kube-system   calico-kube-controllers-9b54b4c6c-br47m   1/1     Running   0          55s
kube-system   calico-node-nkbpg                         1/1     Running   0          55s
kube-system   coredns-746c97786-7q9t9                   1/1     Running   0          4h47m
kube-system   coredns-746c97786-h6jfd                   1/1     Running   0          4h47m
kube-system   etcd-k8s-master-01                        1/1     Running   3          4h47m
kube-system   kube-apiserver-k8s-master-01              1/1     Running   3          4h47m
kube-system   kube-controller-manager-k8s-master-01     1/1     Running   3          4h47m
kube-system   kube-proxy-t7xqz                          1/1     Running   0          4h47m
kube-system   kube-scheduler-k8s-master-01              1/1     Running   3          4h47m

检查节点已经就绪
kubectl get node
NAME            STATUS   ROLES           AGE     VERSION
k8s-master-01   Ready    control-plane   4h48m   v1.33.7


## master节点加入集群：
高可用（HA）架构，加入 Master 节点和 Worker 节点的步骤略有不同。

因为 kubeadm init 生成的证书 Key 只有 2 小时有效期，为了确保万无一失，我们重新上传证书并生成新的加入命令。

1. 重新上传证书（获取 Certificate Key）
`kubeadm init phase upload-certs --upload-certs`
得到一行输出，包含 certificate-key（一长串 64 位的十六进制字符），复制下来，下一步要用。
2. 生成完整的 Master 加入命令
将上一步得到的 key 替换到下面命令中的 <粘贴你的KEY> 位置：
`kubeadm token create --print-join-command --certificate-key <粘贴你的KEY>`

得到一条master节点的加入命令：
kubeadm join 192.168.0.233:6443 --token nsvmni.pg7dpzia64vumwev --discovery-token-ca-cert-hash sha256:9ff4d009842407fddabc7800388e2cc8d82176dd0cf3ff8dcf5a1499c0ff3992 --control-plane --certificate-key 562962c935ea24f0a7fe14b84a99b2ea4e2dd3e0a9cfbd4798cde12ef7fb42be

登录其余master节点，执行此条命令
出现如下输出即为成功：
```
This node has joined the cluster and a new control plane instance was created:

* Certificate signing request was sent to apiserver and approval was received.
* The Kubelet was informed of the new secure connection details.
* Control plane label and taint were applied to the new node.
* The Kubernetes control plane instances scaled up.
* A new etcd member was added to the local/stacked etcd cluster.

To start administering your cluster from this node, you need to run the following as a regular user:

        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config

Run 'kubectl get nodes' to see this node join the cluster
```
执行配置kubectl环境变量的命令：
```shell
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```
这时正常情况执行节点检查命令应该能看到其他master也是就绪状态
`kubectl get nodes`

## worker节点加入集群
Worker 节点的加入命令不需要 --control-plane 和 --certificate-key 参数。
直接复用上面的命令，去掉那两个参数即可。
kubeadm join 192.168.0.233:6443 --token nsvmni.pg7dpzia64vumwev --discovery-token-ca-cert-hash sha256:9ff4d009842407fddabc7800388e2cc8d82176dd0cf3ff8dcf5a1499c0ff3992

再次检查集群状态：
kubectl get nodes
NAME            STATUS   ROLES           AGE     VERSION
k8s-master-01   Ready    control-plane   5h4m    v1.33.7
k8s-master-02   Ready    control-plane   5m54s   v1.33.7
k8s-master-03   Ready    control-plane   5m43s   v1.33.7
k8s-worker-01   Ready    <none>          77s     v1.33.7

至此集群的初步安装已经完成
--------------------------------------------

## 安装metrics-server
在github找到最新的安装资源文件：
https://github.com/kubernetes-sigs/metrics-server
通常链接如下：
https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml

需要替换镜像，根据上面的阿里镜像地址和最新的版本号可以组合出来，尝试拉取一下验证是否正确，一般如下：
registry.aliyuncs.com/google_containers/metrics-server:v0.8.0

根据实际情况，一般推荐InternalIP在前面，按前后顺序的优先级
spec.template.spec.args:
--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP

- 如果不使用TLS，在spec.template.spec.args:添加下面配置，跳过kubelet证书验证
--kubelet-insecure-tls

- 如果使用TLS，需要配置Kubelet的服务端证书自动轮转

需要修改集群中 所有节点（包括 Master 和 Worker）的 Kubelet 配置
```shell
echo "serverTLSBootstrap: true" >> /var/lib/kubelet/config.yaml
systemctl restart kubelet
```
批准证书签名请求 (CSR)
当 Kubelet 重启并开启 serverTLSBootstrap 后，它会向 K8s API Server 发起一个 CSR 请求，申请一个正式的服务端证书。这个请求默认处于 Pending 状态，需要管理员手动批准
`kubectl get csr`
批量批准
`kubectl get csr | grep Pending | awk '{print $1}' | xargs kubectl certificate approve`
确认证书已签发 再次查看 CSR，状态应变为 Approved,Issued
`kubectl get csr`

部署metrics-server
`kubectl apply -f components.yaml`
会在kube-system的namespace下创建一个无状态pod：metrics-server-b6d8fb7f7-2rcjl
查询节点状态：
kubectl top node
NAME            CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k8s-master-01   188m         4%       1107Mi          14%
k8s-master-02   168m         4%       876Mi           11%
k8s-master-03   156m         3%       892Mi           11%
k8s-worker-01   69m          0%       608Mi           1%


--------------------------------------------
## 安装nodelocaldns
官方资源：
https://github.com/kubernetes/kubernetes/blob/master/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml
配置参考：
https://kubernetes.io/zh-cn/docs/tasks/administer-cluster/nodelocaldns/

修改下面几个参数值：
__PILLAR__DNS__SERVER__：CoreDNS 的 ClusterIP，NodeLocalDNS 在宿主机上拦截这个 IP 的流量
` kubectl get -n kube-system svc kube-dns`
值：CoreDNS 的 ClusterIP

__PILLAR__LOCAL__DNS__：本地监听 IP，NodeLocalDNS 的虚拟网卡 IP，通常固定为此值：169.254.20.10，需要保持此ip未被使用
固定值：169.254.20.10

__PILLAR__DNS__DOMAIN__：集群域名，除非您修改过 kubelet 配置，否则默认都是这个：cluster.local
固定值：cluster.local

__PILLAR__CLUSTER__DNS__：上游转发 IP (最关键)，千万不能填 CoreDNS IP！ 必须填 kube-dns-upstream 的 IP，否则会死循环。
值：这个需要kube-dns-upstream的service创建完成后才能获取:kube-dns-upstream 的 ClusterIP
`kubectl get svc -n kube-system kube-dns-upstream`

__PILLAR__UPSTREAM__SERVERS__：外部上游 DNS，即填/etc/resolv.conf路径即可
值：/etc/resolv.conf

执行部署：
`kubectl apply -f nodelocaldns.yaml`
查询结果：
`kubectl get pods -n kube-system -l k8s-app=node-local-dns`
NAME                   READY   STATUS    RESTARTS   AGE
node-local-dns-5bwwk   1/1     Running   0          101s
node-local-dns-6n5n6   1/1     Running   0          100s
node-local-dns-lwpbx   1/1     Running   0          101s
node-local-dns-nxs8n   1/1     Running   0          101s

查询kube-dns-upstream的ClusterIP
`kubectl get svc -n kube-system kube-dns-upstream`

修改PILLAR__DNS__DOMAIN的值
删除重建
`kubectl delete pod -n kube-system -l k8s-app=node-local-dns`

有一个名为 nodelocaldns 的虚拟网卡，IP 地址为 169.254.20.10 和 10.96.0.10
`ip addr show nodelocaldns`
10: nodelocaldns: <BROADCAST,NOARP> mtu 1500 qdisc noop state DOWN group default
link/ether 2a:6c:05:64:9f:f8 brd ff:ff:ff:ff:ff:ff
inet 169.254.20.10/32 scope global nodelocaldns
valid_lft forever preferred_lft forever
inet 10.96.0.10/32 scope global nodelocaldns
valid_lft forever preferred_lft forever

在安装完成之后，一定要记得修改集群新的dns地址为169.254.20.10：
`kubectl -n kube-system edit configmap kubelet-config`
```yaml
clusterDNS:
- 169.254.20.10
```
然后新创建的pod才会使用这个地址作为集群地址解析，如果在pod内查询/etc/reslov.conf,nameserver是10.96.0.10，pod无法访问其他集群内其他pod。

--------------------------------------------

## 安装nfs storage class
如果集群使用此存储介质，所有节点都需要安装nfs服务
# 这一步所有节点执行
```shell
yum install -y nfs-utils
systemctl enable nfs-server  && systemctl start nfs-server
```

使用通用配置资源安装：

修改nfs-storage.yaml中的相关配置，主要是nfs的镜像

然后执行安装即可，会创建一个nfs的无状态pod

kubectl get pods -n kube-system -l app=nfs-client-provisioner
NAME                                      READY   STATUS    RESTARTS   AGE
nfs-client-provisioner-748957bd76-hrks5   1/1     Running   0          66s

kubectl get sc
NAME                    PROVISIONER                                   RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
nfs-storage (default)   k8s-sigs.io/nfs-subdir-external-provisioner   Delete          Immediate           false                  76s

完成


