---
name: l4d2-rcon-password-pitfall
description: SRCDS 命令行解析器把 RCON 密码中的 + 当作 convar 分隔符，导致密码截断认证失败
metadata:
  node_type: memory
  type: feedback
  tags:
    - l4d2
    - docker
    - rcon
    - password
    - pitfall
  originSessionId: 5e46cc7c-ebb8-43ef-a4bf-3009e5be0841
---

# L4D2 RCON 密码特殊字符坑

## 现象
- `rcon_password` 包含 `+` 号时，RCON 认证失败
- Python RCON 客户端报 `WrongPassword` 或 hang
- 密码看起来正确，但 SRCDS 收到的密码被截断

## 根因
SRCDS 命令行解析器（`CCommandLine::Tokenize`）把 `+` 解释为 **convar 分隔符**。

`docker-compose.yml` 中：
```yaml
command: >
  +hostname "xxx"
  +rcon_password "uVvWzqznb9f9Fj4NzMh+KDbZ"
  ...
```

解析器看到 `+KDbZ` 后，把 `KDbZ` 当作**另一个 `+command` 去执行**，密码实际变成 `uVvWzqznb9f9Fj4NzMh`（截断在 `+` 前）。

其他危险字符：空格、分号、`%`、`"` 等也可能引发问题。

**Why:** Source 引擎用 `+` 前缀区分"带值的 convar"和"无值的 flag"（如 `-game` vs `+map` vs `+hostname`），这个解析逻辑对密码内容不友好。

**How to apply:**
1. **永远用纯字母数字生成 RCON 密码**，不含 `+`、`-`、`=`, 空格等
2. 如果必须用特殊字符，在 `server.cfg` 中设置 `rcon_password`（依赖 valve.rc 存在）
3. 更换密码后同步更新所有引用位置（docker-compose.yml, server.cfg, 备份密码本）

## 关联
- [[l4d2-cfg-mount-pitfall]] — valve.rc 缺失导致 server.cfg 不执行，RCON 密码不生效
- [[l4d2-deployment-rules]] — 部署 checklist
- [[l4d2-rcon-hotreload-workflow]] — 完整热加载方案
