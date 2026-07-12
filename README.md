# v2node
A v2board backend base on moddified xray-core.
一个基于修改版xray内核的V2board节点服务端。

**注意： 本项目需要搭配[修改版V2board](https://github.com/wyx2685/v2board)**

## 软件安装

### 一键安装

```bash
wget -N https://raw.githubusercontent.com/axixw/v2node/refs/heads/mptcp/script/install.sh \
  && sudo bash install.sh
```

该入口直接下载 GitHub Actions 生成的预编译 MPTCP 二进制，不会在节点服务器上
安装 Go 或现场编译。

安装完成后运行管理菜单：

```bash
v2node
```

菜单可以查看、添加和删除多个节点，也可以启动、停止、查看日志及更新 MPTCP
版本。添加节点会自动写入 `EnableMPTCP: true`，修改配置前会保留时间戳备份。

首次安装可以直接传入面板地址和节点 ID，密钥会在随后出现的隐藏输入提示中填写：

```bash
wget -N https://raw.githubusercontent.com/axixw/v2node/refs/heads/mptcp/script/install.sh \
  && sudo bash install.sh \
    --api-host 'https://panel.example.com/' \
    --node-id 1
```

## 构建
``` bash
GOEXPERIMENT=jsonv2 go build -v -o build_assets/v2node -trimpath -ldflags "-X 'github.com/wyx2685/v2node/cmd.version=$version' -s -w -buildid="
```

## AnyTLS MPTCP 修改版

此工作树增加了一个按节点配置的 `EnableMPTCP` 开关。它只影响 AnyTLS
入站，不会改变其他协议。

节点配置示例：

```json
{
  "Log": {
    "Level": "warning",
    "Output": "",
    "Access": "none"
  },
  "Nodes": [
    {
      "ApiHost": "https://panel.example.com/",
      "NodeID": 1,
      "ApiKey": "your-server-token",
      "Timeout": 15,
      "EnableMPTCP": true
    }
  ]
}
```

在 Ubuntu、Debian、CentOS、Rocky Linux、AlmaLinux 或 Arch Linux 的
systemd 服务器上，可以从当前源码目录运行：

```bash
sudo bash script/install-mptcp.sh
```

首次安装也可以非交互传入面板信息：

```bash
sudo bash script/install-mptcp.sh \
  --api-host 'https://panel.example.com/' \
  --node-id 1 \
  --api-key 'your-server-token'
```

未提供预编译文件、直接运行源码安装脚本时，会执行以下操作：

- 安装并校验构建所需的 Go 1.26.1；
- 从当前工作树编译修改版 v2node；
- 保留并备份现有 `/etc/v2node/config.json`；
- 为现有节点写入 `EnableMPTCP: true`；
- 备份旧二进制，安装并启动修改版；
- 在内核支持时设置 `net.mptcp.enabled=1`；
- 新版本启动失败时恢复旧二进制。

安装后检查：

```bash
systemctl status v2node --no-pager
journalctl -u v2node -n 100 --no-pager
sysctl net.mptcp.enabled
```

一键安装会同时安装本分支的 `v2node` 管理菜单。可以使用菜单中的“更新 MPTCP
版本”或执行 `v2node update`；它只会从 `axixw/v2node` 的 `mptcp` 分支更新，
不会下载上游未修改的二进制。

注意：服务端 MPTCP 与 Mihomo 订阅的 `mptcp: true` 是两项独立配置。客户端
要显示标签并发起 MPTCP 拨号，XiaoV2board 的 AnyTLS 订阅生成器仍需输出该字段。

## 维护自己的仓库并同步上游

先在 GitHub 打开 <https://github.com/wyx2685/v2node>，点击 `Fork` 创建自己的
仓库。随后在本地修改版目录执行以下命令，将 `YOUR_NAME` 替换为自己的 GitHub
用户名：

```bash
git remote rename origin upstream
git remote add origin https://github.com/YOUR_NAME/v2node.git
git switch -c mptcp
git add README.md conf/conf.go core/inbound.go core/node.go \
  node/controller.go script/install-mptcp.sh
git commit -m "feat: enable configurable MPTCP for AnyTLS"
git push -u origin mptcp
```

推荐让自己的 `main` 始终跟随作者，而把修改保留在 `mptcp` 分支。首次推送
自己的 `main`：

```bash
git switch main
git push -u origin main
git switch mptcp
```

作者发布更新后，执行：

```bash
git fetch upstream
git switch main
git merge --ff-only upstream/main
git push origin main

git switch mptcp
git merge main
git push origin mptcp
```

如果 `git merge main` 报冲突，不要强行覆盖。重点检查本修改涉及的文件：

```text
conf/conf.go
core/inbound.go
core/node.go
node/controller.go
script/install-mptcp.sh
```

解决冲突并完成测试后，重新运行：

```bash
wget -N https://raw.githubusercontent.com/axixw/v2node/refs/heads/mptcp/script/install.sh \
  && sudo bash install.sh
```

服务器上建议克隆自己的修改分支：

```bash
git clone --branch mptcp https://github.com/YOUR_NAME/v2node.git /root/v2node-mptcp
cd /root/v2node-mptcp
sudo bash script/install-mptcp.sh
```

上面的源码安装方式会在服务器上编译。生产节点通常应使用前面的预编译一键安装
命令。

后续部署更新：

```bash
cd /root/v2node-mptcp
git pull --ff-only origin mptcp
wget -N https://raw.githubusercontent.com/axixw/v2node/refs/heads/mptcp/script/install.sh \
  && sudo bash install.sh
```

不要在生产节点上直接合并上游或解决冲突。应先在自己的开发副本中完成合并和
验证，再让生产节点从 `origin/mptcp` 拉取已经确认的版本。

## Stars 增长记录

[![Stargazers over time](https://starchart.cc/wyx2685/v2node.svg?variant=adaptive)](https://starchart.cc/wyx2685/v2node)
