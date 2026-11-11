# Jupyter 沙盒玩耍指南

> 如何利用在线 Jupyter 服务的计算资源，以及如何用 proot 拿到一个"像 root 一样"的环境。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 这是什么

一份**实战导向**的在线 Jupyter 沙盒使用指南。不是教科书式的 Linux 教程，而是从真实踩坑中总结出来的操作手册。

涵盖：

- 这类沙盒**到底是什么**（无特权 Docker 容器）
- 能拿到什么资源、边界在哪里
- **proot** 原理与用法（绕过 `CapEff=0` 的关键）
- 如何压榨 CPU / 内存 / 磁盘
- 长时间任务怎么不被杀
- 什么东西会丢、如何保住成果
- 硬限制清单和 ToS 风险

---

## 快速开始

### 首选：Foxytoux freeroot（一键装好）

[github.com/foxytouxxx/freeroot](https://github.com/foxytouxxx/freeroot) —— 一个自助脚本，帮你装好 proot + Ubuntu 20.04 rootfs，很多在线 Jupyter 服务默认就用它。

```bash
# 1. 探测你的沙盒
bash scripts/probe.sh

# 2. 一键装 freeroot（CapEff=0 时）
git clone https://github.com/foxytouxxx/freeroot.git
cd freeroot && bash root.sh
```

**原理**：`root.sh` 把 Ubuntu base rootfs 解到**仓库目录自身**，再把静态 proot 放到 `usr/local/bin/proot`，最后用这个 proot 拉自己启动。

```
freeroot/
├── root.sh                 ← 安装 + 启动脚本
├── proot-x86_64            ← 静态二进制（1.9 MB）
├── proot-aarch64           ← ARM 版
├── bin/ etc/ usr/ ...      ← Ubuntu 20.04 rootfs
└── .installed               ← 安装完成的标记
```

> 详细参数解释见 [03-proot详解.md](docs/03-proot详解.md#foxytoux-freeroot-的实际做法)。

### 备选：自己搭

```bash
bash scripts/bootstrap.sh    # 下载 rootfs + proot，生成启动器
```

### 跑长任务

```bash
bash scripts/keepalive.sh run --name mytask -- ./long_running_program
bash scripts/keepalive.sh status mytask
```

---

## 文档

| 文档 | 内容 |
|---|---|
| [01-沙盒概览](docs/01-沙盒概览.md) | 这类服务是什么、能拿到什么、边界在哪 |
| [02-快速上手](docs/02-快速上手.md) | 从零到跑起第一个任务 |
| [03-proot详解](docs/03-proot详解.md) | 原理、参数、能做什么不能做什么 |
| [04-资源利用](docs/04-资源利用.md) | 压榨资源、长任务、防 OOM |
| [05-持久化与迁移](docs/05-持久化与迁移.md) | 什么会丢、如何备份和迁移 |
| [06-限制与风险](docs/06-限制与风险.md) | 硬限制清单、ToS、安全边界 |
| [07-实战案例](docs/07-实战案例.md) | 真实案例：Ghidra 逆向、SSH、解包 |

## 脚本

| 脚本 | 用途 |
|---|---|
| `scripts/probe.sh` | 一键探测资源与限制（含内存上限实测） |
| `scripts/bootstrap.sh` | 初始化 proot 环境 + 常用工具 |
| `scripts/keepalive.sh` | 长任务保活、监控、自愈 |

---

## 核心结论（TL;DR）

### 沙盒的本质

```
一个无特权的 Docker 容器
  uid=0  但  CapEff=0000000000000000
  有 22 GB 内存、4 核、135 GB 磁盘
  但 chroot / mount / sysctl / docker 全部不可用
```

### proot 是关键

```bash
proot --rootfs=/path/to/rootfs -0 -w /root \
  -b /dev -b /sys -b /proc -b /etc/resolv.conf \
  /bin/bash
```

它用 `ptrace` 拦截 syscall 模拟 `chroot`，让你在无特权容器里跑完整发行版。

**代价**：I/O 慢 30-60%，`sy` 内核态开销可达 40%+。

### 最重要的三条

| # | 教训 |
|---|---|
| 1 | **cgroup 的 `memory.max` 会骗人** —— 显示 `max` 可能实际有硬限，必须实测 |
| 2 | **跑满所有核会让 sshd 抢不到 CPU → SSH 失联** —— 留一核 |
| 3 | **只有宿主 bind mount 是持久的** —— 其余路径容器重建即全丢 |

---

## 实测环境

```
OS        Ubuntu 20.04.6 LTS (proot)
内核      6.14.0-1021-gcp（宿主 GCP）
CPU       4 × Intel Xeon @ 2.80GHz
内存      22 GB，无 swap
磁盘      135 GB overlay
权限      uid=0, CapEff=0, Seccomp=2
/dev/shm  64 MB (noexec)
网络      自由出网
```

> 不同服务的配置差异很大。**先跑 `probe.sh` 再动手。**

---

## 适用场景

| 用途 | 可行性 |
|---|---|
| 大内存编译（LLVM/Ghidra/大型项目） | ✅ 极好 |
| 逆向工程（Ghidra/IDA） | ✅ 极好 |
| 数据分析（pandas/Spark local） | ✅ 极好 |
| 长期爬虫 | ⚠️ 注意 ToS |
| 训练小模型 | ✅ CPU only |
| 暴露 Web 服务 | ⚠️ 需隧道 |
| Docker-in-Docker | ❌ 不行 |
| 内核模块 | ❌ 不行 |

---

## ⚠️ 免责声明

> **本项目仅供学习研究和技术交流。**
>
> - 本文档只讲**技术原理**，不构成任何使用许可
> - 使用任何在线服务前，请**自行确认其服务条款（ToS）**
> - 滥用免费资源可能导致**账号封禁**
> - 是否允许长期占用、跑服务、特定用途，**以服务方条款为准**
> - 作者不对因使用本项目导致的任何后果负责

**合理用法**：学习、实验、原型开发、短期批量计算、数据处理分析。

**明确不适合**：把免费额度当免费 VPS 长期挂服务、挖矿、代理、端口扫描、任何商业转售。

---

## 贡献

欢迎提 Issue / PR 补充你自己的踩坑经验。

特别是：
- 不同服务商的特殊限制
- 新的 proot 用法
- 性能调优实测数据

---

## License

[MIT](LICENSE)
