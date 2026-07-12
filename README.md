# v2node MPTCP

## 软件安装

### 一键安装

```bash
wget -N https://raw.githubusercontent.com/axixw/v2node/refs/heads/mptcp/script/install.sh \
  && sudo bash install.sh
```

该入口直接下载 GitHub Actions 生成的预编译 MPTCP 二进制，不会在节点服务器上
安装 Go 或现场编译。

MPTCP 版使用完全独立的程序、配置、服务和管理命令，不会覆盖同机安装的原版
v2node：

```text
程序目录：/usr/local/v2node-mptcp/
配置目录：/etc/v2node-mptcp/
systemd： v2node-mptcp.service
管理命令：v2node-mptcp
```

原版和 MPTCP 版可以同时运行，但两边对接的节点必须使用不同监听端口。

安装完成后运行管理菜单：

```bash
v2node-mptcp
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
