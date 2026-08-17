# HE IPv6 Manager

一个用于在 Linux VPS 上配置和管理 [Hurricane Electric Tunnel Broker](https://tunnelbroker.net/) 6in4 IPv6 隧道的中文交互式脚本。

它不需要保存 HE 账号密码，只需填写 Tunnel Details 页面提供的 IP 信息。配置完成后可随时回顾 HE IP、查看运行状态、执行诊断、重新应用或完整卸载。

## 功能

- 中文交互菜单，也支持命令行子命令
- 自动识别 VPS 出口使用的本机 IPv4
- 区分 HE Client IPv4 与 NAT 环境下的本机 IPv4
- 创建标准 Linux SIT（6in4 / IP Protocol 41）隧道
- 使用 systemd 持久化，重启 VPS 后自动恢复
- 保存并回顾 Server / Client IPv4、IPv6、Routed /64、Routed /48、MTU
- 检查接口、地址、默认路由、HE 端点及公网 IPv6 连通性
- 检测当前公网 IPv4 是否与 HE Client IPv4 一致
- 配置文件权限固定为 `600`
- 卸载时只清理本机配置，不会删除 HE 网站中的隧道

## 使用前提

1. VPS 具有可用的公网 IPv4；CGNAT 环境通常无法使用 HE 6in4。
2. 上游网络和云防火墙允许 **IP Protocol 41**。它不是 TCP/UDP 端口 41。
3. 已在 [HE Tunnel Broker](https://tunnelbroker.net/) 创建 Regular Tunnel。
4. 当前版本面向使用 systemd 的 Linux VPS，例如 Debian、Ubuntu、Rocky Linux、AlmaLinux。
5. HE 创建隧道时要求 IPv4 端点能够响应 ICMP Echo（Ping）。

> 隧道接口显示为 `UP` 并不能证明隧道真的可用，因为 6in4 本身没有握手或心跳；请以脚本诊断中的 IPv6 Ping 为准。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xinian5216/he-ipv6-manager/main/he-ipv6-manager.sh)
```

也可以先下载再运行：

```bash
curl -fLo he-ipv6-manager.sh \
  https://raw.githubusercontent.com/xinian5216/he-ipv6-manager/main/he-ipv6-manager.sh
chmod +x he-ipv6-manager.sh
sudo ./he-ipv6-manager.sh
```

首次选择“配置”后，脚本会把自身安装到：

```text
/usr/local/sbin/he-ipv6-manager
```

以后直接运行：

```bash
he-ipv6-manager
```

## 从 HE 页面复制哪些信息

打开 Tunnel Details 页面，在 **IPv6 Tunnel Endpoints** 区域复制：

| 脚本字段 | HE 页面字段 |
|---|---|
| `Server IPv4 Address` | Server IPv4 Address |
| `Client IPv4 Address` | Client IPv4 Address |
| `Server IPv6 Address` | Server IPv6 Address |
| `Client IPv6 Address` | Client IPv6 Address |
| `Routed /64` | Routed IPv6 Prefixes → Routed /64 |
| `Routed /48` | Routed IPv6 Prefixes → Routed /48（可选） |

IPv6 地址可直接粘贴带 `/64` 的完整内容，脚本会自动处理。

“VPS 本机用于隧道的 IPv4”通常直接采用脚本检测值：

- VPS 直接绑定公网 IPv4：一般与 HE Client IPv4 相同。
- VPS 位于 NAT 后：可能是内网 IPv4，但上游必须把 IP Protocol 41 正确转发到这台 VPS。

## 命令

```bash
he-ipv6-manager configure   # 配置或重新配置
he-ipv6-manager show        # 回顾 HE IP 信息
he-ipv6-manager status      # 查看接口、路由和 systemd 状态
he-ipv6-manager diagnose    # 连通性诊断
he-ipv6-manager reapply     # 重建隧道
he-ipv6-manager uninstall   # 卸载本机配置
he-ipv6-manager help        # 帮助
```

## 文件位置

| 路径 | 用途 |
|---|---|
| `/usr/local/sbin/he-ipv6-manager` | 安装后的管理脚本 |
| `/etc/he-ipv6-manager/config.conf` | HE IP 配置，权限 `600` |
| `/etc/systemd/system/he-ipv6-manager.service` | systemd 服务 |

## 常见问题

### 接口 UP，但 IPv6 不通

依次检查：

```bash
he-ipv6-manager diagnose
ip -d link show he-ipv6
ip -6 route
```

最常见原因：

- HE 页面填写的 Client IPv4 已变化。
- VPS 商家或云防火墙拦截 IP Protocol 41。
- VPS 位于 NAT / CGNAT 后，回程的 Protocol 41 无法转发。
- Server / Client IPv6 填反。
- 其他 VPN 或网络管理工具覆盖了 IPv6 默认路由。

### UFW 应该放行哪个端口

6in4 使用的是 IPv4 报文头中的 **协议号 41**，不是 TCP 41 或 UDP 41。很多 VPS 的本机 UFW 不会阻断 SIT 隧道，但商家的云防火墙或上游网络仍可能拦截该协议。

### 公网 IPv4 变化了怎么办

先在 HE Tunnel Details 页面更新 Client IPv4，再运行：

```bash
he-ipv6-manager configure
```

如果只是 VPS 本机源地址发生变化，也可以重新配置后执行 `reapply`。

### Routed /64 填了为什么没自动绑到接口

Tunnel Endpoints 中的 Client IPv6 已足够让 VPS 自身访问 IPv6 网络。Routed /64 和 /48 主要用于给容器、虚拟机或下游网络分配地址，直接把整个前缀绑到隧道接口容易造成错误路由，因此本脚本只保存并展示，不擅自分配。

## 安全说明

- 脚本不收集、不上传 HE IP 配置。
- 不要求 HE 用户名、密码或 Update Key。
- 配置文件只允许 root 读取。
- 建议先阅读脚本再以 root 运行。

## 官方资料

- [Hurricane Electric Free IPv6 Tunnel Broker](https://tunnelbroker.he.net/)
- [HE IPv6 FAQ：Tunnel Broker](https://ipv6.he.net/certification/faq.php)

## 许可证

[MIT License](LICENSE)
