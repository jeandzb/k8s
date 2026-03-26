### pod 创建 (create)

**1. [kubectl] 提交请求**
* `kubectl` 将创建 Deployment 的请求提交到 API Server。

**2. [API Server] 验证请求**
* API Server 收到请求后，验证请求是否合法（如：检查权限、参数、配额等）。

**3. [etcd] 数据持久化与事件触发**
* API Server 验证成功后，将请求的数据以 JSON 格式存储到 `etcd` 中。
* API Server 收到写入成功的响应后，会触发内部的事件机制，将状态变更推送给所有正在 Watch 它的客户端（如 Controller Manager、Scheduler 等）。

**4. [Controller Manager] 资源对象控制**
* **Deployment Controller**：一直在持续监听 (Watch) API Server 的变化，API Server 将变更数据推送给 Controller。Deployment Controller 收到后，会创建一个 **ReplicaSet** 对象，将创建请求提交到 API Server 并存储到 `etcd` 中。
* **ReplicaSet Controller**：监听到了新的 ReplicaSet 创建，发现当前 Pod 数量为 0，不满足副本数要求。于是它负责创建对应数量的 **Pod** 对象，并将请求发给 API Server 并存入 `etcd`。
* *当前状态*：此时 Pod 的状态是 `Pending`，`nodeName` 为空（因为 Pod 还没有被调度到具体的节点上）。

**5. [Scheduler] 节点调度**
* `kube-scheduler` 同样在持续监听 (Watch) API Server 的变化，API Server 将变更数据推送给 Scheduler。
* Scheduler 根据调度策略（如：亲和性、污点、资源负载等），将 Pod 调度到合适的节点上，并将确定的 `nodeName` 发送给 API Server。
* API Server 变更 Pod 记录中的 `nodeName` 字段，并将其写入 `etcd` 中。

**6. [kubelet] 容器创建与状态汇报**
* `kubelet` 在各个节点上持续监听 (Watch) API Server 的变化，API Server 将变更数据推送给 `kubelet`。
* **启动容器**：对应节点的 `kubelet` 发现有 Pod 被调度到自己的 Node 上，便会调用 **CRI**（Container Runtime Interface，底层容器运行时如 containerd 或 Docker），指令其拉取镜像；同时配置网络（调用 **CNI**）、挂载存储卷（调用 **CSI**），最终启动 Pod 内的容器。
* **状态汇报**：容器启动后，`kubelet` 会持续监控容器的运行状态。它将 Pod 的最新状态（如 `Running`、容器 IP 等）汇报给 API Server，API Server 最终将这些状态更新到 `etcd` 中。


### Pod 销毁 (Terminating)

**1. [kubectl / Controller] 发起删除请求**
* 用户通过 `kubectl delete pod` 发起手动删除，或者各个 Controller（如 Deployment 缩容、节点驱逐等）自动发起删除请求。
* 请求被提交给 API Server。

**2. [API Server & etcd] 标记 Terminating 状态**
* API Server 收到请求后，**不会立即从 etcd 中删除该 Pod 的数据**。
* 相反，API Server 会更新该 Pod 的对象记录：为其打上 `deletionTimestamp`（删除时间戳），并设置 `gracePeriodSeconds`（优雅退出宽限期，默认 30 秒）。
* 更新后的数据存入 `etcd`，此时在终端查询，Pod 的状态变为 `Terminating`。API Server 随后将状态变更推送给所有 Watch 的客户端。

**3. [Endpoint Controller & kube-proxy] 网络流量摘除（异步执行）**
* **Endpoint Controller**：监听到 Pod 进入 Terminating 状态后，会立即将该 Pod 的 IP 从所属 Service 的 Endpoints（或 EndpointSlice）列表中移除。
* **kube-proxy**：监听到 Endpoints 变化后，更新各个节点上的负载均衡规则（如 iptables 或 IPVS），确保**新的网络请求不再被路由到该 Pod**。
* *(注意：这一步与底下的 kubelet 销毁容器是**同时异步**发生的。这也是为什么业务需要配置优雅退出的原因，避免流量还没摘除完，容器就先停了。)*

**4. [kubelet] 触发优雅退出 (Graceful Shutdown)**
* 所在节点的 `kubelet` 监听到 Pod 被打上了 `deletionTimestamp`。
* **执行 preStop Hook**：如果 Pod 的生命周期配置中定义了 `preStop` 钩子（如执行一段 shell 脚本或 HTTP 请求来通知注册中心下线），`kubelet` 会优先同步执行它。
* **发送 SIGTERM**：`preStop` 执行完毕（或未配置），`kubelet` 会调用 CRI 向容器内的主进程（PID 1）发送 `SIGTERM` 信号。业务代码接收到此信号后，应当主动停止接收新请求，并处理完当前存量请求后自行退出。

**5. [kubelet] 强制终止 (SIGKILL)**
* `kubelet` 会启动一个倒计时（对应 `gracePeriodSeconds`，默认 30 秒，包含执行 `preStop` 的时间）。
* 如果时间到了，容器内的进程依然没有退出（处于僵死或挂起状态），`kubelet` 会果断发送 `SIGKILL` 信号，由 Linux 内核**强制终止**该容器进程。

**6. [kubelet & API Server] 资源清理与最终删除**
* 进程结束后，`kubelet` 调用 **CNI** 清理网络资源（如删除虚拟网卡、释放 IP）、调用 **CSI** 卸载挂载的存储卷。
* 等所有本地资源彻底清理干净后，`kubelet` 向 API Server 发送最终状态汇报。
* API Server 收到确认后，将该 Pod 的记录从 `etcd` 中彻底抹除。至此，Pod 生命周期彻底结束。