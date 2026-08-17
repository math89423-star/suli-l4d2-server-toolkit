---
name: l4d2-proxy-ip-mismatch
description: HTTP_PROXY 导致 Steam master server 登记错误公网 IP，路人搜到连不上
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - server
    - proxy
    - pitfall
    - networking
  originSessionId: 1383a57b-46aa-480a-9448-19a6e3b3ffba
  modified: 2026-07-28T15:59:24.607Z
---

# L4D2 代理导致 IP 错报

## 症状

服务器运行正常、可直连，但始终没有路人加入。Steam 服务器浏览器搜不到，或搜到后连不上。

## 根因

Docker 容器设置了 `HTTP_PROXY=http://127.0.0.1:7890`（clash 代理），Steam 客户端库（steamclient.so）通过代理连接 Steam master server，master server 看到的是代理出口 IP 而非服务器真实公网 IP。结果：

- 服务器实际 IP：`81.71.101.135`
- Steam master 登记 IP：`82.152.165.153`（代理出口）
- 路人从 Steam 浏览器搜到的是错误 IP → 连不上

通过 `status` 命令可确认：`udp/ip : 0.0.0.0:27015 [ public xxx ]` 中的 public IP 是否正确。

## 为什么不能直接删代理

1. **steamcmd 需要代理**：无代理下载 40MB 耗时 40+ 分钟（国内 Steam CDN 限速）
2. **srcds 启动也需要代理**：无代理时 steamclient.so 直连 Steam API 超时，Localizer 阶段卡死（卡在 166/210）

必须区分对待：steamcmd 走代理，srcds 不走代理。

## 解决方案：自定义 entrypoint wrapper

创建 `/opt/gameservers/l4d2/data/entrypoint-wrapper.sh`：

```bash
#!/bin/bash
# Wrapper: steamcmd uses proxy for fast downloads, srcds runs without proxy for correct IP
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890

cd /home/louis || exit 50
./steamcmd.sh +runscript update.txt

# Unset proxy so srcds reports correct public IP
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy

cd l4d2 || exit 50
exec ./srcds_run "$@"
```

`docker-compose.yml` 中挂载并覆写 entrypoint：

```yaml
entrypoint: ["/bin/bash", "/entrypoint-wrapper.sh"]
volumes:
  - ./data/entrypoint-wrapper.sh:/entrypoint-wrapper.sh:ro
```

**注意：不要设置全局 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量**——它们会在 wrapper 内部按需设置。

## 为什么之前加了代理

加速 steamcmd 下载游戏更新（国内 Steam CDN 慢），本质是临时措施，忘记删除。

## 踩过的坑

- ❌ 直接删代理 → steamcmd 40 分钟下载 + srcds Localizer 卡死
- ❌ `NO_PROXY=api.steampowered.com` → steamclient.so 不识别 NO_PROXY，无效
- ❌ clash `DOMAIN-SUFFIX,api.steampowered.com,DIRECT` → steamclient.so 走 HTTP_PROXY 不经过 clash 路由
- ❌ `+hostip 81.71.101.135` → L4D2 不支持此 cvar
- ✅ entrypoint wrapper 区分 steamcmd/srcds

## 验证方法

1. `docker logs l4d2-server` 确认 steamcmd 下载快（2 分钟内完成）
2. RCON `status` 确认 `public` 字段显示 `81.71.101.135`
3. 等待 1-2 分钟后 Steam 服务器浏览器搜索 hostname 能找到

## 关联记忆

- [[l4d2-deployment-rules]] — 十条铁律
- [[l4d2-docker-migration]] — left4devops 镜像迁移
