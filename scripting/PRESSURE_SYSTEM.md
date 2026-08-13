# L4D2 动态压力难度系统

## 概述

基于团队表现的实时难度调整系统，通过 4 个插件协同工作，实现从休闲到地狱的 5 段位无缝过渡。

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    pressure_tracker.sp                      │
│                         (核心引擎)                           │
│  • 追踪波次表现 (倒地/死亡/伤害/清剿速度)                    │
│  • 计算全局压力值 (20-100)                                  │
│  • 段位判定 + 稳定机制 (T1-T5)                              │
│  • 暴露 3 个 cvar                                           │
└────────────┬────────────────────────────────────────────────┘
             │
             ├─→ sm_pressure_tier (1-5)
             ├─→ sm_pressure_value (20-100)
             └─→ sm_pressure_aggression (0.7-1.3)
                       │
       ┌───────────────┼───────────────┬──────────────────┐
       ↓               ↓               ↓                  ↓
┌─────────────┐ ┌─────────────┐ ┌──────────────┐ ┌─────────────┐
│specialspawner│ │si_comp_mgr  │ │  AI_HardSI   │ │  (未来扩展) │
│             │ │             │ │              │ │             │
│波次参数调制 │ │战术过滤     │ │攻击性调制    │ │压力可视化   │
└─────────────┘ └─────────────┘ └──────────────┘ └─────────────┘
```

## 段位系统

| 段位 | 压力值 | 攻击性 | 描述 | 体验 |
|------|--------|--------|------|------|
| **T1 Casual** | 20-35 | 0.7 | 休闲模式 | 特感保守，波次间隔长，简单战术 |
| **T2 Standard** | 35-50 | 0.85 | 标准难度 | 默认起始段位，平衡体验 |
| **T3 Challenge** | 50-65 | 1.0 | 挑战模式 | 压力平衡点，所有战术可用 |
| **T4 Hard** | 65-80 | 1.15 | 困难模式 | 特感激进，复杂战术，高频刷新 |
| **T5 Hell** | 80-100 | 1.3 | 地狱模式 | 极限压迫，最强配置 |

### 段位稳定机制

防止压力值在边界附近抖动导致频繁切换：
- **T1 ↔ T2**: 需要连续 3 波在新段位范围
- **T2 ↔ T3**: 需要连续 3 波
- **T3 ↔ T4**: 需要连续 4 波
- **T4 ↔ T5**: 需要连续 5 波（最难升档）

## 压力积累规则

### 正向积累（团队表现优秀）
- **完美波次** (+5): 无倒地无死亡
- **完美连击** (+8): 连续 5 波完美（叠加在第 5 波）
- **快速清剿** (+3): 25 秒内清完一波

### 负向释放（团队表现不佳）
- **倒地惩罚** (-4/人): 每次倒地
- **死亡惩罚** (-8/人): 每次死亡
- **伤害惩罚** (-2): 单波承受伤害 >400
- **慢速清剿** (-2): 60 秒以上才清完
- **自然衰减** (-1): 每波固定衰减

### 特殊情况
- **团灭重置**: 压力值重置到 30 (T2 低位)
- **压力钳制**: 最低 20，最高 100

## 各系统响应

### 1. specialspawner — 波次参数调制

| 参数 | T1 Casual | T5 Hell | 倍率 |
|------|-----------|---------|------|
| 冷静期 | 18-24s | 6-10s | 3x ↑ |
| 分批数 | 3 批 | 1 批 | 集中度 3x ↑ |
| 倒地补偿 | 100% | 40% | 惩罚 2.5x ↑ |
| 自杀时间 | 35s | 12s | 2.9x ↑ |

**影响**: 波次频率、集中度、容错率

### 2. si_composition_manager — 战术过滤

#### 战术复杂度分级
- **SIMPLE** (简单): 钢铁洪流 (纯近战 C+H+J)
- **MODERATE** (中等): 暗影锁链、生化危机、均衡演武
- **COMPLEX** (复杂): 地空协同、猎手集群

#### 段位过滤规则
- **T1**: SIMPLE 强权重 5, MODERATE 稀有 1
- **T2**: SIMPLE 权重 3, MODERATE 权重 2
- **T3**: 所有战术同权重
- **T4**: MODERATE 权重 2, COMPLEX 优先 3
- **T5**: COMPLEX 强权重 5, MODERATE 稀有 1

**影响**: 战术多样性、配合复杂度

### 3. AI_HardSI — 攻击性调制

#### 缩放公式
```
攻击距离 = 基础距离 / (攻击性 × 敏感度)
```

#### per-SI 敏感度
- **Smoker/Spitter**: 1.2x (远程特感，压力敏感)
- **Boomer**: 0.8x (近战爆破，保守)
- **其他**: 1.0x (标准响应)

#### 实际效果 (Smoker 850u 为例)
| 段位 | 攻击性 | 敏感度 | 有效攻击性 | 触发距离 | 变化 |
|------|--------|--------|------------|----------|------|
| T1 | 0.7 | 1.2 | 0.76 | 1118u | +31% (保守) |
| T3 | 1.0 | 1.2 | 1.0 | 850u | 基准 |
| T5 | 1.3 | 1.2 | 1.36 | 625u | -26% (激进) |

**影响**: 攻击触发距离、压迫感

## 使用指南

### 服务器管理员

#### 基础配置
```
// cfg/sourcemod/pressure_tracker.cfg
sm_pressure_enable "1"
sm_pressure_announce "1"  // 段位切换播报
```

#### 调参建议

**想要更激进的难度曲线**:
```
sm_pressure_perfect_wave "6"      // 增加奖励
sm_pressure_decay_per_wave "0"    // 移除自然衰减
sm_pressure_tier_stable_t4_t5 "3" // 更容易升到 T5
```

**想要更平滑的体验**:
```
sm_pressure_incap_penalty "2"     // 减少倒地惩罚
sm_pressure_tier_stable_t1_t2 "5" // 增加稳定波数
```

**想要保持高压力**:
```
sm_pressure_wipe_reset "50"       // 团灭不会降太多
sm_pressure_death_penalty "5"     // 减少死亡惩罚
```

#### 监控命令
```
sm_cvar sm_pressure_value    // 查看当前压力值
sm_cvar sm_pressure_tier     // 查看当前段位
sm_cvar sm_pressure_aggression // 查看 AI 攻击性
```

### 开发者

#### 集成新系统

1. **读取段位**:
```sp
ConVar g_cvPressureTier;

public void OnPluginStart() {
    g_cvPressureTier = FindConVar("sm_pressure_tier");
    if (g_cvPressureTier != null) {
        HookConVarChange(g_cvPressureTier, OnTierChanged);
    }
}

public void OnTierChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    int tier = convar.IntValue;
    // 根据段位调整行为
}
```

2. **读取攻击性**:
```sp
ConVar g_cvAggression;
float g_fAggression = 1.0;

public void OnPluginStart() {
    g_cvAggression = FindConVar("sm_pressure_aggression");
    if (g_cvAggression != null) {
        g_fAggression = g_cvAggression.FloatValue;
        HookConVarChange(g_cvAggression, OnAggressionChanged);
    }
}

// 使用攻击性缩放参数
float scaledValue = baseValue / g_fAggression;
```

## 性能特性

- **pressure_tracker**: 每波计算一次 (~0.5-2 分钟一次)
- **specialspawner**: 每波读一次段位
- **si_composition_manager**: 模式切换时读一次段位 (~35-50 秒一次)
- **AI_HardSI**: spawn 时注入一次，cvar 变化时批量更新

**总开销**: 极低，无明显性能影响

## 故障排查

### 问题: 段位不切换
- 检查 `sm_pressure_enable "1"`
- 检查稳定波数是否满足
- 查看 `sm_cvar sm_pressure_value` 确认压力值

### 问题: specialspawner 参数不变
- 确认 specialspawner 已重载
- 检查 `sm_pressure_tier` cvar 是否存在
- 查看 specialspawner 日志确认绑定

### 问题: AI 攻击性无变化
- 确认 AI_HardSI_bt.smx 已加载
- 检查 `sm_pressure_aggression` cvar
- 确认使用了 _Scaled 版本的条件节点

## 版本历史

- **v1.0.0** (2026-08-13): Phase 1 - pressure_tracker 核心引擎
- **v2.0.0** (2026-08-13): Phase 2 - specialspawner 波次调制
- **v2.5.0** (2026-08-13): Phase 3 - si_composition_manager 战术过滤
- **v5.8.0** (2026-08-13): Phase 4 - AI_HardSI 攻击性调制
- **v5.8.1** (2026-08-13): 性能优化 + per-SI 敏感度

## 未来扩展

- [ ] 压力可视化 HUD
- [ ] Hunter/Charger/Jockey 压力响应
- [ ] Tank 专属压力机制
- [ ] 非线性缩放曲线
- [ ] 地图难度系数
- [ ] 压力历史统计

## 许可

MIT License
