---
name: l4d2-git-single-repo
description: Git 仓库唯一性定论（2026-08-16 用户拍板）：唯一仓库 = data/addons/sourcemod ↔ suli-l4d2-server-toolkit；外层 /opt/gameservers/l4d2 的孤儿 3 提交仓库已删除；compiled 路径归一
metadata:
  node_type: memory
  type: project
  originSessionId: git-mess-cleanup-20260816
  modified: 2026-08-16T02:50:00.000Z
---

# L4D2 Git 仓库唯一性（2026-08-16 定论，勿再纠结）

## 定论

**本项目唯一 git 仓库 = `/opt/gameservers/l4d2/data/addons/sourcemod`（.git 在该目录内）**，
远端 `https://github.com/math89423-star/suli-l4d2-server-toolkit/`，默认分支 `master`。

## 背景（两个仓库的来历）

- **插件仓库**（addons/sourcemod）：144+ 提交、有远端 suli-l4d2-server-toolkit，
  SourceMod 插件全套（scripting/plugins/translations/cfg）。这是唯一真实在用的仓库。
- **外层孤儿仓库**（/opt/gameservers/l4d2/.git）：2026-08-15 创建的 3 提交无远端仓库，
  意图管理部署配置（docker-compose/data/cfg 等），曾想把 addons 当 submodule 但从未
  真正添加 → 形成嵌套仓库（nested repo），git 无法在外层跟踪内层内容，是漂移根源。
- **处理**：2026-08-16 用户拍板删除外层仓库（`rm -rf /opt/gameservers/l4d2/.git`），
  外层文件（docker-compose.yml/data/cfg 等）保留在磁盘但不做版本管理（暂不管）。

## compiled 路径归一（2026-08-16）

- 唯一编译产物目录 = `scripting/compiled/`（spcomp 输出）
- 仓库根 `compiled` 是指向 `scripting/compiled/` 的**符号链接** → 两条路径归一
- `.gitignore` 规则 `compiled/` → `compiled`（无斜杠，同时覆盖目录与符号链接，
  避免 `?? compiled` 污染 git status）
- SourceMod 只加载 `plugins/*.smx`，根 compiled 软链不会被动加载

## 相关

- [[l4d2-pressure-system-removed]] — 同期清理（备份全删，git 已同步）
- [[l4d2-deployment-rules]] — 部署惯例