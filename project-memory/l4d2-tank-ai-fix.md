---
name: l4d2-tank-ai-fix
description: Tank AI 近身跳跃修复 — 双层防御 + 配置修复 + 源码 v2.2 重建
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - tank
    - ai
    - bhop
    - sourcemod
    - fix
  originSessionId: c12770ea-bf83-4055-8a29-8611e31b424b
---

# L4D2 Tank AI 近身跳跃修复

## 问题

Tank 贴近幸存者（近身距离）时仍然跳跃，而不是出拳攻击。

## 根因

1. `ai_tank_bhop_min_dist` 被设为 **0**（默认 150），导致"太近不跳"检查完全失效
2. `ai_tank_punch_jump` 启用（=1），Tank 近身会跳起来打人
3. 原版 Tank AI 自己会按跳跃键，插件未在每帧都拦截

## 修复：双层防御

### 第一层（每帧，AI_HardSI.sp:75-80）
在 tick 节流之前，每帧清除 Tank 的 IN_JUMP 和 IN_DUCK。只有智能 bhop 逻辑判断"该跳"时才加回来。

### 第二层（bhop 评估时，AI_Tank.sp:159-177）
近身距离（< min_dist）时显式清除跳跃，即使第一层被绕过也能防御。

## 配置修改

| cvar | 旧值 | 新值 | 说明 |
|------|------|------|------|
| `ai_tank_bhop_min_dist` | 0 | 200 | 200 单位内不 bhop，走过去出拳 |
| `ai_tank_punch_jump` | 1 | 0 | 禁用近身跳拳 combo |

配置文件：`/opt/gameservers/l4d2/data/cfg/sourcemod/AI_HardSI.cfg`

## v2.2 源码重建

原 v2.2 .smx 的源码已丢失。在 v2.0 源码基础上重建了所有 v2.2 特性：

### 新增 ConVar（均在 AI_Tank.sp）
- `ai_tank_bhop_adaptive` — 自适应冷却（速度快 → 冷却短）
- `ai_tank_bhop_momentum` — 连续 bhop 逐渐增强（最高 2x）
- `ai_tank_bhop_evade` — 前方有墙时侧向 bhop 绕开
- `ai_tank_punch_jump` — 近身跳拳 combo（默认关）
- `ai_tank_rage_multiplier` — 着火时冷却加速 + 推力增大
- `ai_tank_punch_instakill` — Tank 拳头秒杀生还者
- `ai_tank_punch_damage` — 拳击伤害值（150 = 秒杀）
- `ai_tank_aggro_bhop` — 激进 bhop（无视生还者朝向）

### 源码位置
```
/home/ubuntu/l4d2-server/sourcemod/scripting/AI_HardSI_optimized/
├── AI_HardSI.sp     # 主插件（含 per-tick 跳跃抑制）
├── AI_Tank.sp        # Tank 模块（v2.2 全特性）
├── hardcoop_util.sp  # 工具库
└── backups/          # 修改前备份
```

### 编译
```bash
/home/ubuntu/l4d2-server/sourcemod/scripting/spcomp \
  /home/ubuntu/l4d2-server/sourcemod/scripting/AI_HardSI_optimized/AI_HardSI.sp \
  -o/home/ubuntu/l4d2-server/sourcemod/scripting/compiled/AI_HardSI.smx
```

## 备份文件

| 文件 | 说明 |
|------|------|
| `plugins/AI_HardSI.smx.bak` | 最旧 v2.0 (Jul 21) |
| `plugins/AI_HardSI.smx.bak.20260725_100612` | 原 v2.2 (21003 bytes) |
| `plugins/AI_HardSI.smx.bak.v22.20260725_102423` | 原 v2.2 热备份 |
| `scripting/AI_HardSI_optimized/backups/` | 源码备份 |

## 回滚

```bash
# 恢复原 v2.2 .smx
cp .../AI_HardSI.smx.bak.v22.* .../plugins/AI_HardSI.smx
# RCON reload
python3 -c "..." # 见 rcon-init.sh 的 rcon 调用方式
```

## Tank 何时还会跳？

修改后，Tank 仅在以下条件**全部满足**时才 bhop（跳跃推进）：
- 在地面、不在梯子上
- 速度 ≥ 190
- 有生还者视线
- 距离在 200–800 单位之间
- 前方无墙壁挡住（或侧向有空间绕开）
- 生还者在逃跑（若 aggro_bhop=1 则跳过此检查）
- bhop 冷却已过（自适应：速度快冷却短，着火再加速）
