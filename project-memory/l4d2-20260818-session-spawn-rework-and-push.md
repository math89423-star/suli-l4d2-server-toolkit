---
name: l4d2-20260818-session-spawn-rework-and-push
description: 2026-08-18 会话归档——SS v6.0.3 刷点重构部署 + 四轮实测修复 + admin 权限修复 + Git 推送记录
metadata:
  node_type: memory
  type: project
  modified: 2026-08-18
---

# 2026-08-18 会话：specialspawner v6.x 上线、逐轮修 bug、git 推送

> 主线任务书：`project-memory/l4d2-si-spawn-research-plan.md`；架构落地文档：
> `project-memory/l4d2-si-spawn-hardgate-softscore-v6.md`。本文件是"当天发生了什么"
> 的操作归档（部署/修复/推送流水）。

## 一、部署链（live 服务器）

- live 在 `/home/administrator/l4d2-server`（detached srcds，systemd l4d2 已死，手动进程，
  stdin=/dev/null → **命令全部走 Source RCON**：Python `Source RCON` TCP 127.0.0.1:27015，
  rcon 密码见 `left4dead2/cfg/server.cfg`）
- 部署流程：`scripting/compiled/*.smx` → `plugins/`；`server-cfg/sourcemod/*.cfg` →
  `left4dead2/cfg/sourcemod/`；RCON `sm plugins reload <名>`
- 编译：`/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/spcomp <f>.sp -o<f>.smx -i include`

## 二、specialspawner 版本演进（全部 live reload 验证，0 error）

| 版本 | 内容 | 实测驱动 |
|---|---|---|
| 6.0.0 | Hard Gate + Soft Score；删"任意最近点"兜底与 invis A/B；出生目标注入 CommandABot；行动进展看门狗(7/14/25s)；欠账 catch-up，失败不耗预算 | 云端调研交付 |
| 6.0.1 | 目标 round-robin 分散；relocate 换自家安全 teleport（弃引擎 WarpToValidPositionIfStuck→悬崖）；同波聚集惩罚 | 首波 7 只全挤同一坐标 + 2 只坠落 |
| 6.0.2 | 打分重平衡（AttackLOS +450/500、隐蔽 -150→-60、>600u 远点重罚）；`ss_wave_stall_advance 6.0` 波次泄气推进 | 首发平均 800u 全隐蔽 = 看不到 |
| 6.0.3 | Hard Gate 拒 `trigger_hurt`（陷阱秒死）；Soft Score 拒屋檐/悬崖落脚(±70u 落差>110u)；`g_iBatchGuardTrap` 观测 | 波6 三只死于 陷阱2.2s/2.7s + 坠落36.8s ≈ 30% 压力白给 |

**配套修复**
- `si_composition_manager.AdjustSpawnSize` 下限修复：≤4 人恒保底 cfg 基线 10（原 `spawn<4→4`，
  3 人算出 round(7.5)=8）
- `configs/core.cfg` `SteamAuthstringValidation` yes→**no**：服务器 Steam 出口抖动（当日 82 次
  `Connection to Steam servers lost`）→ `STEAMAUTH: Client 粟藜 received failure code 1` →
  管理员=root 全部失效（投票/命令全没）。关校验 + `sm_reloadadmins` 立即恢复 root。

## 三、live 部署现状（2026-08-18 14:2x）

- specialspawner **6.0.3** running；si_composition_manager 2.7.0 running；粟藜 admin=root
- 新 cvar 已随 cfg 生效：samples 16 / target_inject 1 / time 1.5 / recover 7 / relocate 14 /
  stall_advance 6 / nav_path 5000 等；250/350 两档保留未动

## 四、Git 提交与推送

- 仓库：`https://github.com/math89423-star/suli-l4d2-server-toolkit.git` 分支 master
- 本会话先配置 repo-local git 身份（`suli <math89423@users.noreply.github.com>`，沿用上条提交）
- 两次提交：
  - `f090ad6` feat(ss)：SS v6.0.3 重构 + si_comp 下限 + core.cfg SteamAuth + cfg + 文档（6 文件 +1390/−152）
  - `5d25a59` wip(ai)：AI_HardSI BT 微调 + tank_wave_mutator v2.7.0 + l4d2_stats_logger（6 文件 +553/−26）
- 推送：HTTPS 需认证，用户提供一次性 PAT `ghp_…`（**已提醒吊销**）；push URL 直连不落 remote 配置，
  push 后本地 `origin/master` 需 `git fetch` 刷新追踪指针
- `.smx` 编译产物被 gitignore，不入库（仓库=源码归档）

## 五、回滚速查

- `plugins/specialspawner.smx.bak.20260818-132514`（v5.33.0）＝回滚点
- `cfg/sourcemod/specialspawner.cfg.bak.20260818-132514`
- `configs/core.cfg.bak.20260818-141416`（SteamAuth=yes 原值）

相关：[[l4d2-si-spawn-hardgate-softscore-v6]] [[l4d2-si-spawn-research-plan]] [[l4d2-specialspawner-config]] [[l4d2-si-spawn-fixes]]
