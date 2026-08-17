---
name: l4d2-source-code-location-pitfall
description: 插件源码在 /opt/gameservers/l4d2/data/addons 而非 /home/ubuntu/l4d2-server
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - ptg
    - docker
    - pitfall
    - source
  originSessionId: 9e5d22b4-186e-40be-9764-f729a9121cb7
  modified: 2026-08-15T08:01:59.971Z
---

# 插件源码位置坑

## 根因

Docker 容器 `l4d2-server` 的 `/addons` 目录通过 bind mount 挂载自主机的 `/opt/gameservers/l4d2/data/addons`。

**编译发生在容器内**，使用的是容器内的 `/addons/sourcemod/scripting/` 路径，即主机的 `/opt/gameservers/l4d2/data/addons/sourcemod/scripting/`。

但 `/home/ubuntu/l4d2-server/` 目录下的 `sourcemod/` 文件夹是独立的副本（可能是从 Git 仓库克隆的），**与容器挂载的路径不同步**。

## 两个路径对照

| 用途 | 主机路径 | 容器路径 |
|------|----------|----------|
| **Git 仓库**（编辑用） | `/home/ubuntu/l4d2-server/sourcemod/` | 无 |
| **容器挂载**（编译用） | `/opt/gameservers/l4d2/data/addons/sourcemod/` | `/addons/sourcemod/` |

## 正确的工作流

1. **编辑源码**：直接在 `/opt/gameservers/l4d2/data/addons/sourcemod/scripting/` 下修改（~~不再需要同步步骤~~）
2. **编译**：`cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting && ./spcomp64 l4d_path_to_goal.sp -o /tmp/l4d_path_to_goal.smx -i./include`
3. **部署 SMX**：`cp /tmp/l4d_path_to_goal.smx /opt/gameservers/l4d2/data/addons/sourcemod/plugins/`
4. **提交 Git**：在 `/opt/gameservers/l4d2/data/addons/sourcemod/` 下 commit

## ⚠️⚠️ sourcemod 是独立 Git 子仓库（2026-08-15 实证，两次假成功）

**`data/addons/sourcemod/.git` 存在——它是嵌套的独立 Git 仓库，不是主仓库 `/opt/gameservers/l4d2/.git` 的一部分。**

- **主仓库** `/opt/gameservers/l4d2/`：管 `data/cfg/`、脚本、CLAUDE.md 等。`.gitignore` 里 `data/addons/*.vpk` 只忽略 vpk，**但整个 `data/addons/sourcemod/` 是嵌套仓库，主仓库 `git add data/addons/sourcemod/scripting/x.sp` 会静默跳过**（当作 submodule 处理，什么都没 stage）。
- **子仓库** `data/addons/sourcemod/`：管所有 `.sp` 源码 + `PLUGINS.md`。**插件源码必须 `cd data/addons/sourcemod && git commit`。**

**假成功坑**：在主仓库 `git add <子仓库文件>` 无报错但没 stage，随后 `git commit` 会把**预先 stage 的无关文件**（CLAUDE.md、脚本）连同你的 commit message 一起提交，看起来"成功"了但**真正的源码根本没入库**。commit 497c9de 就是这样——message 写着肾上腺素插件，实际提交的是 CLAUDE.md + 一堆脚本，`.sp` 源码没进去。

**cfg 例外**：`data/cfg/sourcemod/*.cfg` 在**主仓库**里（不在子仓库），所以 si_comp cfg 的 commit 6182e9d 落主仓库是对的。

**铁律**：改 `.sp`/PLUGINS.md → `cd data/addons/sourcemod` 提交；改 `.cfg`/脚本 → 主仓库 `/opt/gameservers/l4d2` 提交。子仓库里常有**别人未提交的改动**（如 l4d2_si_hud.sp），只 `git add` 自己碰过的文件，别 `git add -A`。

## ⚠️ spcomp64 默认输出到 cwd 坑（2026-08-05 二犯，l4d2_shop v1.7.3）

`./spcomp64 x.sp` **不带 -o 时产物写到当前目录（scripting/），不是 .sp 同目录也不是 plugins/**。
reload 后日志显示旧版本号（`loaded v1.7.2` 而非 1.7.3）→ 排查发现 plugins/ 的 smx 还是旧编译产物（时间戳 14:04 vs 实际编译 14:21）。

**坑中坑：SM 1.12 编译的 smx 字符串池是加密的**，`strings`/`grep -a` 搜不到任何源码字符串（ammo_refill、版本号全搜不到）——**不能用字符串搜索判断 smx 新旧**，只能看时间戳/size/md5。

**验证铁律**：编译后 `ls -la plugins/x.smx` 时间戳必须 ≥ 编译时刻，然后 reload 后看日志版本号；怀疑版本不对时先对比 host/container 的 md5sum。

## 容器挂载关系（2026-08-02 实测 docker inspect）

**主机 `/opt/gameservers/l4d2/data/` 下的目录都是容器路径的 bind mount，游戏本体通过 symlink 指向挂载点**：

| 主机路径 | 容器挂载点 | 游戏内路径（symlink） |
|----------|-----------|----------------------|
| `data/addons` | `/addons` | `/home/louis/l4d2/left4dead2/addons -> /addons` |
| `data/cfg` | `/cfg` | `/home/louis/l4d2/left4dead2/cfg -> /cfg` |
| `data/sound` | — | `/home/louis/l4d2/left4dead2/sound` |
| `data/maps` | — | `/home/louis/l4d2/left4dead2/maps` |

- 游戏根目录：`/home/louis/l4d2/left4dead2/`（srcds 进程 cwd，`/proc/<pid>/cwd` 可查）
- **编辑/编译/部署只需动主机 `/opt/gameservers/l4d2/data/`，容器内立即可见**（bind mount + symlink 双层直达，无拷贝步骤）
- 排查"改了文件但游戏不认"时：先 `docker exec l4d2-server ls -la /home/louis/l4d2/left4dead2/addons` 确认 symlink，再 md5sum 对比三处（主机/挂载点/游戏路径）

## 引擎残留 cvar 坑（2026-08-02 si_hud 实测）

**现象**：改 cvar 默认值/上限后 reload 插件，查询 cvar 仍是旧 def/max（值被旧 max 钳住）。
**根因**：某 cfg exec 曾自动创建该 cvar（引擎对未知 cvar 名 exec 时自动创建，见 [[l4d2-bf-kill-hud]] 的已知行为）；插件卸载后 cvar 仍残留（`sm plugins unload` 后查询依旧存在可实锤）；CreateConVar 对已存在 cvar 只返回句柄、**不更新 def/max**。
**修复**：CreateConVar 后补 `cvar.SetBounds(ConVarBound_Upper, true, 2.0)`（本地 include 是旧式签名，无 SetDefault）。重启服务器也会消除残留。

## 教训

> **编辑文件和编译文件是同一份。** ~~修改了 Git 仓库里的 `.inc` 文件后，必须同步到 `/opt/gameservers/` 对应路径再编译~~（已修复：Git 仓库现在直接位于编译路径）

验证方法：比对两个路径下同一文件的 md5sum。
```bash
md5sum /home/ubuntu/l4d2-server/sourcemod/scripting/xxx.sp
md5sum /opt/gameservers/l4d2/data/addons/sourcemod/scripting/xxx.sp
```

Related: [[l4d2-ptg-cvar-declared-but-not-created]] [[l4d2-ptg-funnel-bug]]
