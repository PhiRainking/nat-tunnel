# NatTunnel - 内网穿透端口映射工具

简单、轻量的内网穿透工具。将内网服务通过公网服务器暴露到互联网，支持 TCP 和 UDP 协议。

## 架构

```
外网访客 → 服务器端口 → 加密隧道 → 客户端 → 本地服务
```

- **服务端**：部署在 Linux 公网服务器，接收外部请求并转发
- **支持系统**：Ubuntu / Debian / CentOS / RHEL / Fedora / Arch / Alpine
- **客户端**：运行在 Windows 内网机器，连接服务器并映射本地端口

## 快速开始

### 1. 部署服务端（Ubuntu）

```bash
curl -sSL https://8.134.147.15:8888/down/UymNPEIDwxve.sh | sudo bash
```

自定义参数：
```bash
PORT=7000 ADMIN_PORT=9000 TOKEN=*** ADMIN_PWD=*** sudo bash install.sh
```

安装完成后浏览器打开 `http://服务器IP:9000` 进入管理面板。

### 2. 安装客户端（Windows）

下载 [NatTunnel-Setup.exe](https://github.com/PhiRainking/nat-tunnel/releases/download/v1.2.0/NatTunnel-Setup.exe) 安装包，按向导完成安装。

打开 NatTunnel，填写：

| 字段 | 值 |
|------|-----|
| 服务器地址 | 你的服务器 IP |
| 端口 | 7000 |
| 认证令牌 | rainking-tunnel-2024 |

点击「连接」，然后添加端口映射即可。

### 3. 使用示例

把本地 `127.0.0.1:3000` 的 Web 服务映射到服务器的 `8080` 端口：

1. 点击「+ 添加」
2. 远程端口：`8080`，协议：`TCP`
3. 本地地址：`127.0.0.1`，本地端口：`3000`
4. 确认后，通过 `http://你的服务器IP:8080` 即可访问

## 功能特性

- 支持 TCP 和 UDP 协议
- 服务端 Web 管理面板（在线修改令牌、密码）
- 客户端极简黑白 UI
- 端口冲突自动检测
- 断线自动重连
- 安装包支持自定义目录和快捷方式

## 项目结构

```
nat-tunnel/
├── server/               # 服务端（部署在 Ubuntu）
│   ├── server.js         # 核心：TCP/UDP 隧道 + 管理面板
│   ├── config.json       # 配置文件
│   └── install.sh        # 一键部署脚本（自包含）
├── client/               # 客户端（Windows 桌面应用）
│   ├── main.js           # Electron 主进程
│   ├── preload.js        # IPC 桥接
│   ├── tunnel.js         # 隧道客户端核心
│   ├── installer.nsi     # NSIS 安装包脚本
│   └── renderer/         # UI 界面
└── guide.html            # 安装指南网页
```

## 协议

本工具基于 TCP 长连接 + 自定义二进制帧协议：

- 控制通道：客户端与服务端保持单条 TCP 连接
- 帧格式：`[1B 类型][4B 长度][负载]`
- 类型：`C` = JSON 控制消息，`D` = TCP 数据转发，`U` = UDP 数据转发
- 每条隧道通过 UUID 标识，支持多路复用

## License

MIT License
