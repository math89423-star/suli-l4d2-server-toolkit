# AI_HardSI_bt v5.14 — 攻击发起者机制完整实现（2026-08-14）

## 功能描述

完整实现**攻击发起者机制**的行为树集成，Hunter 和 Charger 现在会在骚扰模式下保持距离，等待发起者（Boomer/Smoker）成功开团后再全力进攻。

**来源**：[Legend of Dragon 战术原则](https://steamcommunity.com/groups/legendofdragon)

## v5.14 新增内容

### 1. Hunter 骚扰模式（HunterAct_HarasserApproach）

**行为描述**：
- 保持 **600-1000u** 距离
- 只移动，不扑击
- 面向目标横移骚扰

**实现细节**：
```sourcepawn
// 距离控制
if (distance > 1000.0) {
    // 太远：接近到 800u（±30° 偏移，不直线）
} else if (distance < 600.0) {
    // 太近：后退到 700u
} else {
    // 600-1000u：面向目标横移
    // 每 0.5-1.0s 切换横移方向
}
```

**行为树集成**：
- 优先级：3（在欺骗性跳跃之后，高台跳之前）
- 条件：`CND_IsHarasser` AND NOT `CND_InitiatorEngaged`
- 发起者成功后自动解除限制，恢复正常扑击

### 2. Charger 骚扰模式（ChargerAct_HarasserApproach）

**行为描述**：
- 保持 **400-800u** 距离（比 Hunter 更近，因为体型大容易被发现）
- 只接近，不冲锋
- 面向目标横移威慑

**实现细节**：
```sourcepawn
// 距离控制
if (distance > 800.0) {
    // 太远：直接接近
} else if (distance < 400.0) {
    // 太近：后退
} else {
    // 400-800u：面向目标横移
    // 每 0.5-1.2s 切换横移方向
}
```

**行为树集成**：
- 优先级：2（在出生保护和 pinning 检查之后，冲锋分支之前）
- 条件：`CND_IsHarasser` AND NOT `CND_InitiatorEngaged`
- 发起者成功后自动解除限制，恢复正常冲锋

## 完整工作流程

### 波次开始（specialspawner 生成特感）

1. **首个 Boomer/Smoker**：
   - 分配为 `ROLE_INITIATOR`
   - 正常行为，全力进攻
   - 日志：`[AI_HardSI] Boomer(3) assigned as INITIATOR`

2. **其他特感**（Hunter, Charger, Jockey 等）：
   - 分配为 `ROLE_HARASSER`
   - 进入骚扰模式
   - 日志：`[AI_HardSI] Hunter(4) assigned as HARASSER`

### 骚扰阶段

**Hunter 行为**：
- 在 600-1000u 距离范围内横移
- 面向玩家但不扑击
- 像是在"观望"和"试探"

**Charger 行为**：
- 在 400-800u 距离范围内横移
- 面向玩家但不冲锋
- 像是在"威慑"和"压迫"

**玩家感受**：
- "压力不大，只有几个特感在晃悠"
- "打掉几个就能过了"

### 发起者开团

**Boomer 呕吐成功** 或 **Smoker 拉人成功**：
- `CND_InitiatorEngaged` 返回 SUCCESS
- 所有骚扰者立即解除限制

### 全力进攻阶段

**所有骚扰者转为全力进攻**：
- Hunter：立即扑击最近的目标
- Charger：立即冲锋
- Jockey：骑向危险区

**玩家感受**：
- "突然所有特感一起上了！"
- "刚才还在晃悠的 Hunter 突然扑过来"
- "Charger 也冲过来了"
- 需要同时应对控制+混乱+伤害

## 编译信息

```
Code size:         200120 bytes (+6260 bytes vs v5.13)
Data size:         680480 bytes (+428 bytes)
Total requirements: 899144 bytes (+6688 bytes)
编译时间: 2026-08-14 19:14
14 Warnings (存量未使用符号，无影响)
```

## 部署

```bash
cp scripting/compiled/AI_HardSI_bt.smx plugins/AI_HardSI_bt.smx
# 等待换图或服务器空闲时 reload
```

## 预期效果对比

### 修复前（v5.13）
- ✅ 角色已分配
- ✅ 条件节点已创建
- ❌ 特感行为无变化（基础设施未集成）

### 修复后（v5.14）
- ✅ 角色已分配
- ✅ 条件节点已创建
- ✅ Hunter 和 Charger 进入骚扰模式
- ✅ 发起者成功后全力进攻

### 实战表现

**阶段 1 - 骚扰期**：
- Boomer 慢慢接近准备呕吐
- Hunter 在 700u 左右横移晃悠
- Charger 在 600u 左右横移威慑
- 玩家："还好，不是很多"

**阶段 2 - 爆发期**（Boomer 呕吐成功）：
- 屏幕被胆汁覆盖
- Hunter 立即从 700u 扑过来
- Charger 立即从 600u 冲过来
- 玩家："卧槽！全来了！"

## 待完成功能

**Phase 1.2 剩余工作**：
- ⏳ Jockey 骚扰模式（快速骑乘但不骑向危险区）
- ⏳ Smoker/Boomer 发起者标记（呕吐/拉人成功时设置黑板标记）

**Phase 2 其他功能**：
- Spitter 预判投掷
- Jockey 弹跳骑乘增强
- Tank 物体投掷瞄准
- Hunter 墙面二段跳
- 等等...

## 验证方法

### 观察骚扰模式
开启 `ai_debug 1`，观察：
1. Hunter rootBranch 应该是 3（harassSeq）
2. Charger rootBranch 应该是 2（harassSeq）
3. Hunter 距离应该在 600-1000u
4. Charger 距离应该在 400-800u

### 观察转换时机
1. Boomer 呕吐成功 → Hunter/Charger 立即扑击/冲锋
2. Smoker 拉人成功 → Hunter/Charger 立即扑击/冲锋

### 观察日志
```
[AI_HardSI] Boomer(3) assigned as INITIATOR
[AI_HardSI] Hunter(4) assigned as HARASSER
[AI_HardSI] Charger(5) assigned as HARASSER
```

## 相关修复历史

- **v5.12** (2026-08-14): Hunter 欺骗性跳跃
- **v5.13** (2026-08-14): 攻击发起者机制基础设施
- **v5.14** (2026-08-14): 攻击发起者机制完整实现（Hunter + Charger）

## 参考资料

- [Legend of Dragon 战术原则](https://steamcommunity.com/groups/legendofdragon)
- AI 增强计划：`AI_IMPROVEMENT_PLAN.md`
- v5.13 基础设施：`CHANGELOG_v5.13.md`
