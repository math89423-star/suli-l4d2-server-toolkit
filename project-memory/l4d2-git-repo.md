---
name: l4d2-git-repo
description: L4D2 插件 Git 仓库（已迁移到 /opt）
metadata: 
  node_type: memory
  type: project
  originSessionId: 537414b2-4d5d-4a4e-b112-07e8d7055e5c
  modified: 2026-08-03T14:41:36.362Z
---

# L4D2 服务器 Git 仓库

## 仓库信息

- **远程:** https://github.com/math89423-star/suli-l4d2-server-toolkit（origin 已配置，URL 无 token，2026-08-02 push 验证）
- **本地路径:** `/opt/gameservers/l4d2/data/addons/sourcemod/`（2026-07-27 新建，初始提交 `2b511a8`，1200 文件）——**唯一仓库**，找不到仓库时先查这里（曾在 /home/ubuntu 误找）
- **旧路径:** `/home/ubuntu/l4d2-server/`（已删除，不再存在）
- /home/ubuntu/l4d2-server-pack 与 l4d2-package 是标准 SM 部署包非仓库副本，2026-08-02 已清理删除
- **分支:** `master`（GitHub 默认分支已切为 master，2026-08-02 API 操作）
- **远端 `main` = 旧历史**（v4.0 时代 re-init 前的老提交，13a93efc 等）——保留未删，勿在 main 上操作

## 目录结构

```
sourcemod/
├── scripting/            # 插件源码 (.sp) + include/ptg/
├── plugins/              # 已编译插件 (.smx) — gitignored
├── configs/              # 插件配置
├── extensions/           # C++ 扩展 (.so/.dll) — gitignored
├── gamedata/             # Gamedata 签名文件
├── translations/         # 多语言翻译
├── bin/                  # SourceMod 二进制 — gitignored
├── data/                 # 插件运行时数据
├── PLUGINS.md            # 70 个 active 插件分类清单
└── .gitignore
```

## .gitignore 排除项

- `*.smx` / `compiled/` — 编译产物
- `extensions/*.dll` / `extensions/*.so` — 平台二进制
- `bin/*.so` — SourceMod 核心
- `spcomp` / `spcomp64` — 编译器
- `logs/` / `*.log` — 运行时日志
- `test_write` — 临时文件

## 关键区别 vs 旧仓库

1. **无 admin-panel/** — Web 管理面板现在是独立 Docker 容器 (`l4d2-admin`)
2. **Git 直接位于编译路径** — 编辑后无需同步，直接编译即可
3. 旧仓库的 git history 未迁移（re-init from scratch）

**How to apply:** 修改插件后直接在同一目录编译、部署、commit；推送前需 `git remote add origin`

## 备份策略（2026-08-03 定稿）

- **不再手工留 `.bak` 备份**：43 个 .bak（HardSI 13 个 + PTG 5 个等）已全部删除，版本统一由 git 管理（源码历史 v3.2→v4.0.2 完整，任何版本可重编）。`.gitignore` 已有 `*.bak*` 规则。
- **v4.0.2 已 commit**：`b870267`（Boomer 窗口期协同瘫痪修复 + 冲锋距离/站桩/节流）——[[l4d2-hardsi-boomedprop-crash]] 中"待 git commit"已过时。
- **PTG v4.7.4 已 commit**：`e522a96`（2026-08-03，同 commit 还含 .bak 清理 + PLUGINS.md 更新）——[[l4d2-ptg-v47-status]] 中"git commit 挂起"已过时。

## 2026-08-03 晚三连发（已 push origin/master，dddf091..5043a03）

- `208f3f9` fix(shop): v1.6.4 瞄准圈=半径+450 + 倒地禁购（[[l4d2-artillery-strike]]）
- `d639f14` feat(specialspawner): v1.3.8 贴脸修复 + 源码补入仓库（原 v1.3.7 上游缺失，取自 github.com/LaoYutang/l4d2-server-next）（[[l4d2-specialspawner-config]]）
- `5043a03` fix(AI_HardSI): v4.1.2 m_hasBeenBoomed 真修复（[[l4d2-hardsi-boomedprop-crash]]）
- `/tmp` 三个 .bak 已按用户指令删除（不用备份，git 管版本）
- 注意：si_composition_manager.sp v2.3.7、Defib_Fix.sp、gamedata/defib_fix.txt、PLUGINS.md 是用户自己的未提交改动，提交时不要顺手 git add
- **2026-08-04 凌晨四连发后的 `2025161`** fix(specialspawner) v1.3.9（[[l4d2-specialspawner-config]]）——已 push（5043a03..2025161）
- **`0bdc10a`** fix(specialspawner) v1.4.0 守卫 v3 LOS 过滤防处决——已 push（2025161..0bdc10a）

Related: [[l4d2-source-code-location-pitfall]]
