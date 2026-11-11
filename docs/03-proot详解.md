# 03 — proot 详解

`proot` 是在**没有特权**的情况下模拟 `chroot` 的工具。这是玩转 Jupyter 沙盒的核心武器。

---

## 为什么需要 proot

沙盒里 `uid=0` 但 `CapEff=0`：

```bash
$ id
uid=0(root) gid=0(root)

$ chroot /tmp /bin/true
chroot: cannot change root directory to '/tmp': Operation not permitted
```

**看起来是 root，实际什么特权都没有。**

`chroot` 需要 `CAP_SYS_CHROOT`，`mount` 需要 `CAP_SYS_ADMIN` —— 沙盒里一个都没有。

---

## proot 原理

### 核心机制：ptrace

proot **不真的调用 `chroot`**。它用 `ptrace`（调试器接口）拦截目标进程的每一个系统调用：

```
你的程序                proot                  内核
   |                     |                      |
   |-- open("/etc/passwd") -->                   |
   |                     | 拦截，改写成          |
   |                     | open("/rootfs/etc/passwd")
   |                     |--------------------->|
   |<--------------------|<---------------------|
```

### 具体拦截什么

| syscall | proot 的处理 |
|---|---|
| `open` / `openat` | 路径加上 rootfs 前缀 |
| `chdir` | 同上 |
| `stat` / `lstat` | 同上 |
| `execve` | 同上 + 重定向 |
| `getuid` / `geteuid` | **返回伪造的 uid（`-0` 时返回 0）** |
| `chroot` | **假装成功**（不真做） |
| `mount` | 假装成功 |

### 代价

| 代价 | 说明 |
|---|---|
| **性能损失** | 每个 syscall 两次上下文切换，系统调用密集的程序慢 10-50% |
| **内核态开销高** | `top` 里 `sy` 会很高（实测 44% sy） |
| **不隔离** | 你的进程和宿主在同一个命名空间 |
| **不提供 PID 隔离** | `/proc` 是宿主的 |

实测：Ghidra 分析时 `sy` 占 44%、`us` 占 39% —— **内核态开销几乎等于用户态**，这就是 proot 的代价。

---

## 安装 proot

### 首选：Foxytoux freeroot

[github.com/foxytouxxx/freeroot](https://github.com/foxytouxxx/freeroot) —— 最常见的自助 proot 方案，很多在线 Jupyter 环境用它。

```bash
git clone https://github.com/foxytouxxx/freeroot.git
cd freeroot
bash root.sh
```

脚本会：
1. 按架构（`x86_64`/`aarch64`）下载对应的静态 proot 到 `usr/local/bin/proot`
2. 下载 **Ubuntu 20.04 base rootfs** 并解到**仓库目录自身**
3. 写 `/etc/resolv.conf`（1.1.1.1 / 1.0.0.1）
4. 打 `.installed` 标记（以后重跑跳过安装，直接进环境）

**最终目录结构**（rootfs 和 proot 同处一目录，这是它的特点）：

```
freeroot/
├── root.sh                    ← 安装 + 启动
├── proot-x86_64               ← 1.9 MB 静态链接
├── proot-aarch64              ← ARM64 版
├── bin/  etc/  usr/  lib/     ← Ubuntu 20.04 rootfs 内容
├── root/                      ← -w /root 的工作目录
└── .installed                 ← 安装完成标记
```

**启动命令**（`root.sh` 最后一行，可单独拷出来用）：

```bash
./usr/local/bin/proot \
  --rootfs="$(pwd)" \
  -0 -w /root \
  -b /dev -b /sys -b /proc -b /etc/resolv.conf \
  --kill-on-exit
```

> **注意 `--rootfs=$(pwd)`** 指向的是 **`freeroot/` 目录自身**，不是它的子目录。
> 所以别把 `freeroot/` 当成普通目录随便删改，它就是 guest 的 `/`。

**为什么这个方案好**：rootfs 放在一个目录里，整个能打包、能备份、能搬到别的机器。如果这个目录在宿主持久盘上，**容器重建也不会丢**。

**已验证环境**：Ubuntu 20.04 rootfs 在 Ubuntu 20.04 / 内核 6.14 (GCP) 的 Jupyter
容器里，4 核 22 GB，跑 Ghidra 逆向 52 MB 二进制正常。

### 方式 2：官方静态二进制

```bash
curl -L -o /tmp/proot https://proot.gitlab.io/proot/bin/proot
chmod +x /tmp/proot
/tmp/proot --version
```

### 方式 3：从源码编译

```bash
git clone https://github.com/proot-me/proot.git
cd proot/src
make
# 产物：src/proot
```

### 方式 4：apt

```bash
apt-get install -y proot
```

> 注：部分发行版的 `proot` 包版本较旧，可能缺 `-b` 等参数。

---

## 参数详解

### 完整命令行（实测案例）

```bash
proot \
  --rootfs=/path/to/rootfs \
  -0 \
  -w /root \
  -b /dev \
  -b /sys \
  -b /proc \
  -b /etc/resolv.conf \
  --kill-on-exit \
  /bin/bash
```

### 逐个参数

| 参数 | 全称 | 作用 | 必需性 |
|---|---|---|---|
| `--rootfs=PATH` | — | 指定根目录 | **必需** |
| `-0` | `--root-id` | 伪装 uid/gid 为 0 | 强烈推荐 |
| `-w PATH` | `--cwd` | 初始工作目录 | 推荐 |
| `-b PATH` | `--bind` | 绑定宿主目录到 guest | **基本必需** |
| `--kill-on-exit` | — | 退出时杀掉所有子进程 | 推荐 |
| `-r PATH` | `--rootfs`（旧写法） | 同 `--rootfs` | — |
| `-v N` | `--verbose` | 调试输出级别 | 排查时用 |
| `-q CMD` | `--qemu` | 跨架构模拟（ARM 等） | 跨架构时需要 |
| `-i UID:GID` | `--change-id` | 映射到指定 uid | — |
| `-R PATH` | — | 自动绑定常用目录 | 简便但不够可控 |

### 最重要的：`-b` 绑定

**不做绑定的话，guest 里没有 `/proc`，很多程序会崩。**

| 绑定 | 为什么必需 |
|---|---|
| `-b /dev` | `/dev/null`、`/dev/urandom`、`/dev/tty` |
| `-b /sys` | 部分程序读硬件信息 |
| `-b /proc` | `ps`、`free`、`/proc/self/*` 全靠它 |
| `-b /etc/resolv.conf` | DNS 解析 |
| `-b /etc/hosts` | 主机名解析（可选） |

### `-R` 简写

```bash
proot -R /path/to/rootfs /bin/bash
```

`-R` 会自动绑定 `/etc/host.conf`、`/etc/hosts`、`/etc/nsswitch.conf`、`/etc/resolv.conf`、`/dev`、`/sys`、`/proc`、`/tmp`、`/run` 等。

**方便但绑定了 `/tmp` 有风险** —— guest 和宿主共享 `/tmp`，容易冲突。生产用还是显式 `-b` 好。

---

## Foxytoux freeroot 的实际做法

这是最常用的自助 proot 方案。读它的源码能学到很多。

### root.sh 完整逻辑

```sh
ROOTFS_DIR=$(pwd)          # ★ 关键：rootfs = 当前目录
ARCH=$(uname -m)            # x86_64 / aarch64

# 1. 选架构后缀
[ "$ARCH" = "x86_64" ]  && ARCH_ALT=amd64
[ "$ARCH" = "aarch64" ] && ARCH_ALT=arm64

# 2. 首次安装：下 rootfs 并解到当前目录
if [ ! -e $ROOTFS_DIR/.installed ]; then
  wget -O /tmp/rootfs.tar.gz \
    "http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.4-base-${ARCH_ALT}.tar.gz"
  tar -xf /tmp/rootfs.tar.gz -C $ROOTFS_DIR
fi

# 3. 下静态 proot 到 usr/local/bin/proot
wget -O $ROOTFS_DIR/usr/local/bin/proot \
  "https://raw.githubusercontent.com/foxytouxxx/freeroot/main/proot-${ARCH}"
chmod 755 $ROOTFS_DIR/usr/local/bin/proot

# 4. 写 DNS（很关键，否则 apt 报域名解析失败）
printf "nameserver 1.1.1.1\nnameserver 1.0.0.1" > ${ROOTFS_DIR}/etc/resolv.conf

# 5. 打标记（以后重跑直接进环境）
touch $ROOTFS_DIR/.installed

# 6. 启动
exec $ROOTFS_DIR/usr/local/bin/proot \
  --rootfs="${ROOTFS_DIR}" \
  -0 -w "/root" \
  -b /dev -b /sys -b /proc -b /etc/resolv.conf \
  --kill-on-exit
```

### 三个设计点值得学

**① `--rootfs=$(pwd)` —— rootfs 就是仓库目录**

```
freeroot/
├── root.sh
├── proot-x86_64
├── usr/local/bin/proot
├── bin/ etc/ usr/ lib/ var/    ← 这些就是 guest 的 /
└── .installed
```

好处：**整个目录能打包带走**。放到持久盘上就永久保留。

**② `.installed` 标记**

重跑 `root.sh` 不会重新下载，直接进环境。幂等设计。

**③ 写死 DNS 到 guest 内**

```sh
printf "nameserver 1.1.1.1\nnameserver 1.0.0.1" > ${ROOTFS_DIR}/etc/resolv.conf
```

因为 `-b /etc/resolv.conf` 绑定的是**宿主的**，但宿主如果在容器里可能是空的。写一份兜底。

### 它没做的事情

| 缺失 | 影响 | 补法 |
|---|---|---|
| 不装 `policy-rc.d` | `apt` 装包时会试图启动服务→卡住 | 建一个 `exit 101` 的脚本 |
| 不换 apt 源 | 用默认 `archive.ubuntu.com`，可能很慢 | 改成国内镜像或 official |
| 不装常用工具 | 连 `curl`/`git`/`vim` 都没有 | `apt-get install` |
| 无自愈机制 | 容器重启后服务全死 | 自写 boot-agent |

The `scripts/bootstrap.sh` 把这些都补上了。

### 与 scripts/bootstrap.sh 的对比

| 项 | freeroot | bootstrap.sh |
|---|---|---|
| rootfs 位置 | 仓库目录自身 | `~/proot-rootfs`（可配） |
| 架构支持 | x86_64 / aarch64 | 同上 |
| 发行版 | 只 Ubuntu 20.04 | ubuntu / debian / alpine |
| `policy-rc.d` | ✗ | ✓ |
| apt 源配置 | ✗ | ✓ |
| 装常用工具 | ✗ | ✓（可选） |
| 启动器 | 重跑 root.sh | 生成独立 `enter-proot.sh` |

**建议**：第一次先用 freeroot（最少意外），熟了再用 `bootstrap.sh` 定制。

---

## rootfs 从哪来

### Ubuntu（推荐，兼容性好）

```bash
curl -L -o ubuntu-base.tar.gz \
  https://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.5-base-amd64.tar.gz
mkdir -p ~/rootfs
tar xzf ubuntu-base.tar.gz -C ~/rootfs
```

### Debian

```bash
curl -L -o debian.tar.gz \
  https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-amd64/bookworm/rootfs.tar.xz
tar xJf debian.tar.gz -C ~/rootfs
```

### Alpine（最小，但 musl libc 兼容性差）

```bash
curl -L -o alpine.tar.gz \
  https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz
tar xzf alpine.tar.gz -C ~/rootfs
```

### 用 Docker 镜像导出（最灵活）

如果你有 Docker（或有能跑 Docker 的机器）：

```bash
docker export $(docker create ubuntu:20.04) | tar -C ~/rootfs -xf -
```

### 用 debootstrap（能 chroot 时）

```bash
debootstrap --arch=amd64 focal ~/rootfs http://archive.ubuntu.com/ubuntu
```

---

## proot 里能做什么 / 不能做什么

### ✅ 能做

| 能力 | 说明 |
|---|---|
| `apt-get install` | 完全正常 |
| 编译（gcc/clang/rust/go） | 正常，但慢一些 |
| 运行任意 Linux 程序 | 正常 |
| 自定义 `/etc/*` | 正常（guest 内的） |
| 多用户 config | 靠 `-0` 伪装 |
| 端口监听 | 正常 |
| 出网 | 正常 |

### ❌ 不能做

| 能力 | 原因 |
|---|---|
| `mount` | 需要 `CAP_SYS_ADMIN`，proot 只是假装成功 |
| 真正的 `chroot` | 同上，`CapEff=0` |
| `sysctl -w` | `/proc/sys` 只读 |
| `systemd` / `service` | 没有 PID 1，不能真启动服务 |
| `iptables` | 需要 `CAP_NET_ADMIN` |
| `docker` | 需要特权 |
| 内核模块 | 需要特权 |
| setuid 程序 | proot 拦不住，但宿主不允许 setuid |

### ⚠️ 半能做的事

| 能力 | 状态 | 说明 |
|---|---|---|
| 后台服务 | 脚本可跑，但没有 systemd 管理 | 用 `nohup`/`supervisord` 自己做 |
| SSH 服务端 | **可以**（用 dropbear） | 见下方专题 |
| 多进程 | 可以 | 但 `/proc` 是宿主的 |

---

## 实战专题：在 proot 里跑 SSH 服务端

这是很常见的需求（远程接入沙盒）。

### ❌ 为什么 OpenSSH 不行

```
OpenSSH sshd
  → 启动时 fork privsep 子进程
  → privsep 子进程要 chroot 到 /var/empty
  → chroot 失败（无 CAP_SYS_CHROOT）
  → KEX 阶段直接 reset
```

**报错特征**：客户端 `ssh` 连上后立刻 `Connection reset by peer`，服务端日志显示 `chroot` 失败。

### ✅ 用 dropbear 替代

dropbear 是轻量级 SSH 服务端，**不做 privsep chroot**：

```bash
# 1. 编译（源码 2MB，很轻）
cd /tmp
curl -L -o dropbear.tar.bz2 https://matt.ucc.asn.au/dropbear/releases/dropbear-2022.83.tar.bz2
tar xjf dropbear.tar.bz2
cd dropbear-2022.83

./configure --prefix=/opt/dropbear \
  --disable-zlib --disable-wtmp --disable-lastlog --disable-utmpx
make -j4
make install

# 2. 生成 host key
/opt/dropbear/bin/dropbearkey -t ed25519 \
  -f /etc/dropbear/dropbear_ed25519_host_key
/opt/dropbear/bin/dropbearkey -t rsa -s 2048 \
  -f /etc/dropbear/dropbear_rsa_host_key

# 3. 启动（监听 22，或用别的端口）
mkdir -p /var/run
/opt/dropbear/sbin/dropbear -p 22 -r /etc/dropbear/dropbear_ed25519_host_key

# 4. 设置 root 密码
passwd root
```

### ⚠️ dropbear 没有 sftp-server

`scp` / `sftp` 不可用。传文件的替代方案：

```bash
# 从 A 传到 B（cat 管道）
cat file.tar.gz | ssh user@host 'cat > /path/file.tar.gz'

# 校验
md5sum file.tar.gz
ssh user@host 'md5sum /path/file.tar.gz'
```

**缺点**：无进度、无断点续传、占用终端。大文件慎用。

### 在 Jupyter 沙盒里的完整方案

```bash
# 1. 沙盒里跑 dropbear，监听本地 22
/opt/dropbear/sbin/dropbear -p 22

# 2. 用 frp/ngrok/cloudflared 把 22 暴露出去
#    或在你的跳板机上建反向隧道
ssh -R 10022:localhost:22 jump@jump-host

# 3. 从你的机器连
ssh -p 10022 root@jump-host
```

---

## 性能调优

### 减少 syscall 次数

proot 对每个 syscall 都拦截。减少 syscall = 提速：

| 手段 | 效果 |
|---|---|
| 用静态编译的程序 | 少 open（`ldd` 加载查表） |
| 避免大量小文件 I/O | 每次 open 都拦截 |
| `-b` 绑定热点目录 | 路径解析更快 |
| 关闭 verbose | `-v 0` |

### 实测数据

| 场景 | 原生 | proot | 倍率 |
|---|---|---|---|
| 编译（gcc） | 1.0x | 1.3-1.6x | 慢 30-60% |
| Ghidra 分析 | 1.0x | ~1.4x（估） | — |
| 纯计算（无 I/O） | 1.0x | 1.05x | 几乎无感 |

**关键结论**：**纯 CPU 计算几乎无损失，I/O 密集型明显变慢。**

---

## 排查问题

### proot 启动就崩

```bash
proot -v 9 --rootfs=... /bin/bash 2>&1 | head -50
```
`-v 9` 打印所有拦截的 syscall，能看出卡在哪。

### guest 里 `ls /proc` 为空

忘了 `-b /proc`。

### `apt-get update` 报 DNS 错

```bash
# guest 内
echo "nameserver 8.8.8.8" > /etc/resolv.conf
# 或者启动时 -b /etc/resolv.conf
```

### 某些程序段错误

常见原因：
1. 缺 `/dev/*` 绑定
2. 缺 `/sys` 绑定
3. 程序需要 setuid（proot 做不到）

### 进程杀不死 / 僵尸

`--kill-on-exit` 能让 proot 退出时清理，但**proot 自己被杀时就清理不了**。手动：

```bash
pkill -9 -f your_program
```

---

## 小结

| 项 | 结论 |
|---|---|
| 本质 | ptrace 拦截 syscall，模拟 chroot |
| 成本 | I/O 慢 30-60%，CPU 计算几乎无感 |
| 能力 | 像 root 一样用（apt、编译、跑服务） |
| 边界 | mount/sysctl/systemd/docker 都不行 |
| 关键参数 | `--rootfs -0 -b /proc -b /dev -b /sys` |

下一步 → [04-资源利用.md](04-资源利用.md)
