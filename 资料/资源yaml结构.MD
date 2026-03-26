k8s中绝大多数资源yaml顶级结构都相同

### 顶级字段：
apiVersion：协议版本
kind：资源类型
metadata：身份元数据
spec：期望状态
status(运行中存在)：实际状态

### 字段解析
* apiVersion
根据资源类型不同，apiVersion也不同，组成通常是：组/版本。此处在集群版本不同时，可能会有不同的版本。
* kind
包括k8s默认的资源类型，也包括自定义的资源类型
* metadata
定义资源的身份数据，用于集群内部的检索和关联。包含：name、namespace、labels、annotations
annotations：注解
通常用来存放给外部工具（如 Jenkins, Argo CD, Ingress Controller）看的配置或人类阅读的备注
所有资源都存在的注解：kubectl.kubernetes.io/last-applied-configuration，记录最近一次应用的配置。
1，service中的annotations：关联外部服务，如Ingress Controller
2，storageclass中的annotations：定义存储类的详细配置，如是否为默认存储类、是否支持动态 provisioning 等。
3，Ingress中的annotations：定义Ingress的路由规则，如路径匹配、SSL 配置等。
等更多


特殊资源
* 没有spec：secret、configMap。主要存储数据，不需要状态对齐；
* 没有status：一些纯逻辑定义，比如 StorageClass。定义好的“模板”，本身不运行。