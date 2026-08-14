# AI_HardSI_bt v5.12 — Hunter 欺骗性跳跃（2026-08-14）

## 功能描述

**Hunter 欺骗性跳跃（Evasive Jump）** — 当 Hunter 检测到被幸存者瞄准时，执行随机方向的闪避跳跃。

**来源**：[Improved Hunter AI (Steam Workshop #3140922442)](https://steamcommunity.com/workshop/filedetails/?id=3140922442)

## 实现细节

### 威胁检测（HunterCond_UnderThreat）

Hunter 必须满足以下所有条件才会触发闪避：

1. **冷却时间**：上次闪避后 3-5 秒（避免频繁跳跃）
2. **位置状态**：在地面且未蹲伏（蹲伏时是潜行模式，不适合跳跃）
3. **被瞄准检测**：
   - 遍历所有幸存者
   - 距离在 **300-800u** 之间
     - <300u：太近，来不及反应
     - >800u：太远，无威胁
   - 幸存者视线夹角 < 15°（cos(15°) ≈ 0.966）
   - 视线通畅（trace 检测，95% 无遮挡）

### 闪避行为（HunterAct_EvasiveJump）

触发闪避时，Hunter 会：

1. **选择跳跃方向**（随机三选一）：
   - 左侧跳：60-120°
   - 右侧跳：-120° 到 -60°
   - 后跳：150-180°（左右随机）

2. **执行跳跃**：
   - 只按 `IN_JUMP`（不按 `IN_ATTACK2`，不是扑击跳）
   - 纯闪避动作

3. **设置冷却**：3-5 秒随机冷却时间

## 行为树集成

欺骗性跳跃被放置在**优先级 2**（仅次于扑空逃跑）：

```
Priority 1: Escape after miss (扑空后逃跑)
Priority 2: Evasive jump when aimed at (被瞄准时闪避) ← NEW
Priority 3: High-ground positioning (高台跳跃)
...其他分支...
```

这确保了：
- 扑空后的安全逃离仍是最高优先级
- 闪避优先于高台跳跃和所有攻击行为
- 不会干扰正常的扑击流程

## 编译信息

```
Code size:         192740 bytes (+2724 bytes vs v5.11)
Data size:         679904 bytes (+492 bytes)
Total requirements: 891188 bytes (+3216 bytes)
编译时间: 2026-08-14 18:59
13 Warnings (存量未使用符号，无影响)
```

## 部署

```bash
cp scripting/compiled/AI_HardSI_bt.smx plugins/AI_HardSI_bt.smx
# 等待换图或服务器空闲时 reload
```

## 预期效果

### 修复前
- Hunter 直线接近幸存者
- 容易被爆头击杀
- 行为模式可预测

### 修复后
- Hunter 接近时会突然侧跳/后跳
- 打断玩家瞄准节奏
- 更像人类玩家的闪避行为
- 在 300-800u 距离段内表现最明显

## 验证方法

### 观察要点
1. Hunter 在中距离（300-800u）接近时会突然跳跃
2. 跳跃方向是侧向或后向（不是扑击跳）
3. 不会频繁跳跃（有 3-5 秒冷却）
4. 蹲伏潜行时不会触发闪避

### 调试方法
开启 `ai_debug 1`，观察：
- Hunter 的 `g_iBTLastWinningChild`
- 分支 2（evasiveJumpSeq）的触发频率
- Hunter 在接近时的行为变化

### 实战表现
- 玩家瞄准 Hunter 时，Hunter 突然横跳
- 玩家需要快速调整瞄准
- Hunter 生存时间应该延长

## 技术细节

### 视线夹角计算
```sourcepawn
// 幸存者视线方向
GetAngleVectors(survivorAng, dir, NULL_VECTOR, NULL_VECTOR);

// 幸存者到 Hunter 的方向
MakeVectorFromPoints(survivorPos, hunterPos, toHunter);
NormalizeVector(toHunter, toHunter);

// 点积计算夹角
float dotProduct = GetVectorDotProduct(dir, toHunter);

// cos(15°) ≈ 0.966
if (dotProduct > 0.966) {
    // 被瞄准
}
```

### 视线通畅检测
```sourcepawn
TR_TraceRayFilter(survivorPos, hunterPos, MASK_SHOT, RayType_EndPoint, TracerayFilter, i);
if (TR_GetFraction() > 0.95) {
    // 95% 无遮挡
}
```

## 后续优化方向

1. **自适应冷却**：根据玩家枪法调整冷却时间
2. **团队感知**：多个幸存者瞄准时优先闪避
3. **地形感知**：避免闪避跳到悬崖/障碍物
4. **连续闪避**：少量情况下允许连续跳 2 次

## 相关修复历史

- **v5.5** (2026-08-05): Sprint 蛇形走位 + 绕后机制
- **v5.10** (2026-08-14): 修复最后一个站桩 bug
- **v5.11** (2026-08-14): 增强横移频率和角度偏移
- **v5.12** (2026-08-14): 新增欺骗性跳跃（被瞄准时闪避）

## 参考资料

- [Improved Hunter AI (Steam Workshop)](https://steamcommunity.com/workshop/filedetails/?id=3140922442)
- [TGMaster/hardcoop](https://github.com/TGMaster/hardcoop)
- AI 增强计划：`AI_IMPROVEMENT_PLAN.md`
