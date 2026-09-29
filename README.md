# H5000M Network Priority

[![CI](https://github.com/woshinibabao1/luci-app-h5000m-netmode/actions/workflows/ci.yml/badge.svg)](https://github.com/woshinibabao1/luci-app-h5000m-netmode/actions/workflows/ci.yml)
[![Build Release](https://github.com/woshinibabao1/luci-app-h5000m-netmode/actions/workflows/release.yml/badge.svg)](https://github.com/woshinibabao1/luci-app-h5000m-netmode/actions/workflows/release.yml)

面向 Hiveton H5000M 的 OpenWrt 出口优先级管理器。用户可直接点击有线 WAN 和
5G 两张出口卡片决定启用范围及优先顺序，服务会据此维护接口状态和默认路由。

版本采用标准的 `主版本.次版本.修订版本-r打包修订` 格式，源码树当前为 `1.3.3-r1`。
GitHub Release 使用语义版本标签（`vX.Y.Z`），发布工作流会校验标签与 Makefile 的
`PKG_VERSION` 一致。

## 功能

- 有线 WAN 优先、5G 优先、仅有线和仅 5G 四种策略
- 卡片式直接选择，当前出口和链路状态即时反馈
- 接口 Hotplug 自动重算，链路恢复后无需人工干预
- 默认出口变化时自动触发已安装代理服务的重载，无需手工重新应用
- 自动约束 IPv6 出口，避免 IPv4 走 WAN、IPv6 意外走 5G
- 只读状态查询与策略写入分权，普通监控账号不能改写出口策略
- 升级时保留 `/etc/config/h5000m_netmode`
- UCI 持久化配置和简体中文 LuCI 界面
- 不依赖云服务，不收集或上传网络数据

## 编译

```sh
git clone https://github.com/woshinibabao1/luci-app-h5000m-netmode.git \
  package/luci-app-h5000m-netmode
make menuconfig
# LuCI -> Applications -> luci-app-h5000m-netmode
make package/luci-app-h5000m-netmode/compile V=s
```

GitHub Releases 中的软件包由 GitHub Actions 使用官方 OpenWrt SNAPSHOT
`mediatek/filogic` SDK 在线构建，附带中文包、SDK 构建公钥和 SHA256 校验文件。
软件包应安装到 ABI 匹配的近期 SNAPSHOT 固件。

配置文件为 `/etc/config/h5000m_netmode`，后端命令为
`/usr/sbin/h5000m-netmode`，LuCI 页面位于“移动网络 → 出口优先级”。

## 测试

```sh
for t in tests/test-netmode-*.sh; do sh "$t"; done
```

测试跑在**离线沙箱**里：用假的 `uci` / `ubus` / `ip` / `jsonfilter` / `ifup` / `ifdown` /
`logger` / `pgrep` 替换外部命令，再让真实的控制器与 hotplug 钩子跑一遍 ——
不需要真机，也不会碰真实网络。

| 用例 | 判据 |
|---|---|
| `test-netmode-events.sh` | 会改变默认出口的接口，其 ifup/ifdown 必须触发重算；无关接口必须跳过 |
| `test-netmode-policy.sh` | 四种模式的最终配置组合、非法配置值的处理、重复应用不得改写网络配置、多路径路由的出口判定 |
| `test-netmode-lock.sh` | 并发互斥、僵尸锁的回收、只释放自己的锁 |
| `test-netmode-cost.sh` | 一次调用只探测一次链路状态；没有变化时不得写任何配置 |
| `test-netmode-harness.sh` | 测试装置自身：进出不改调用方的 shell 选项、退出码如实报回 |
| `test-netmode-acl.sh` | ACL 只授予视图真正用到的东西 |
| `test-netmode-i18n.sh` | 翻译与源码双向一一对应 |

沙箱要在 CI（非 root）里跑，所以控制器与钩子读取外部绝对路径时支持环境变量覆盖。
**默认值即为生产值，正常使用无需设置任何一个**：

| 变量 | 默认值 |
|---|---|
| `H5000M_NETMODE_LOCK_DIR` | `/var/lock/h5000m-netmode.lock` |
| `H5000M_NETMODE_DAED_EXIT_STATE` | `/var/run/h5000m-netmode.daed-exit` |
| `H5000M_NETMODE_NETWORK_INIT` | `/etc/init.d/network` |
| `H5000M_NETMODE_DAED_INIT` | `/etc/init.d/daed` |
| `H5000M_NETMODE_MANAGER` | `/usr/sbin/mt5700m-manager` |
| `H5000M_NETMODE_USB_SH` | `/usr/share/mt5700m/usb.sh` |
| `H5000M_NETMODE_BIN` | `/usr/sbin/h5000m-netmode`（hotplug 钩子用） |

本项目采用 [Apache License 2.0](LICENSE)。
