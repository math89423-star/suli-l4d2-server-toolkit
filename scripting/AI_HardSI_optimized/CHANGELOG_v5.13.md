# AI_HardSI_bt v5.13 — 攻击发起者机制（2026-08-14）

## 功能描述

**攻击发起者机制（Attack Initiator Role）** — 每波攻击指定一个"发起者"（Boomer 或 Smoker），其他特感作为"骚扰者"，实现分层次的协同攻击。

**来源**：[Legend of Dragon 战术原则](https://steamcommunity.com/groups/legendofdragon)

## 设计理念

```
"only boomer or smoker should start an attack"
"if boomer starts → hunters harass in safe way"
"if smoker starts → boomer helps, hunter takes rest"
```

取代"一窝蜂冲上去"的无脑攻击，改为**有序的两阶段进攻**：
- **阶段 1**：发起者单独发动攻击，其他特感保持距离骚扰
- **阶段 2**：发起者成功后，所有骚扰者转为全力进攻

## 角色定义

### ROLE_INITIATOR（发起者）
- **候选者**：Boomer 或 Smoker
- **行为**：正常攻击，全力进攻
- **选择规则**：每波首个生成的 Boomer 或 Smoker

### ROLE_HARASSER（骚扰者）
- **候选者**：所有其他特感（包括后续的 Boomer/Smoker）
- **行为**：保持距离，等待发起者成功后再全力进攻
- **行为限制**：
  - Hunter：保持 600-1000u 距离，不扑击
  - Charger：不冲锋
  - Jockey：快速骑乘但不骑向危险区

### 转换条件

骚扰者转为全力进攻的触发条件（`CND_InitiatorEngaged`）：
1. Boomer 成功呕吐（检测 `just_vomited` 黑板标记）
2. Smoker 成功拉人（检测 `m_tongueVictim` > 0）

## 实现细节

### 1. 角色分配（AssignWaveRole）

```sourcepawn
// 在 Event_PlayerSpawn 时自动分配
void AssignWaveRole(int client) {
    // Tank 不参与角色系统
    if (class == 8) return;

    // 波次重置检测（超过 60 秒视为新波）
    if (now - g_fWaveStartTime > 60.0) {
        g_bWaveHasInitiator = false;
    }

    // 已有发起者 → 所有新特感都是骚扰者
    if (g_bWaveHasInitiator) {
        BB_SetInt(client, "wave_role", ROLE_HARASSER);
        return;
    }

    // 首个 Boomer/Smoker → 发起者
    if (class == 2 || class == 1) {
        BB_SetInt(client, "wave_role", ROLE_INITIATOR);
        g_bWaveHasInitiator = true;
    } else {
        BB_SetInt(client, "wave_role", ROLE_HARASSER);
    }
}
```

### 2. 条件节点（bt_common.inc）

新增 3 个条件节点：

```sourcepawn
// 检查是否为发起者
BT_Status CND_IsInitiator(int client);

// 检查是否为骚扰者
BT_Status CND_IsHarasser(int client);

// 检查发起者是否成功开团
BT_Status CND_InitiatorEngaged(int client);
```

### 3. 行为树集成（待实施）

**Phase 1.2 完成了基础设施**：
- ✅ 角色分配逻辑
- ✅ 条件节点
- ✅ 发起者检测

**待集成到各特感行为树**（下一步工作）：
- Hunter: 骚扰模式分支（保持距离，不扑击）
- Charger: 骚扰模式分支（不冲锋）
- Jockey: 骚扰模式分支（快速骑乘）
- 所有特感：检测 `CND_InitiatorEngaged` 后解除限制

## 编译信息

```
Code size:         193860 bytes (+1120 bytes vs v5.12)
Data size:         680052 bytes (+148 bytes)
Total requirements: 892456 bytes (+1268 bytes)
编译时间: 2026-08-14 19:02
16 Warnings (存量未使用符号，无影响)
```

## 部署

```bash
cp scripting/compiled/AI_HardSI_bt.smx plugins/AI_HardSI_bt.smx
# 等待换图或服务器空闲时 reload
```

⚠️ **注意**：当前版本只实现了角色分配和检测逻辑，尚未集成到各特感的行为树中。特感行为暂时不会改变，需要继续实施 Phase 1.2 的行为树集成部分。

## 下一步工作

### Phase 1.2 行为树集成（未完成）

1. **Hunter 骚扰模式**
   - 在 approach 分支前加 `CND_IsHarasser` 检查
   - 骚扰模式：保持 600-1000u 距离，只移动不扑击
   - 检测到 `CND_InitiatorEngaged` 后解除限制

2. **Charger 骚扰模式**
   - 在 charge 分支前加 `CND_IsHarasser` 检查
   - 骚扰模式：只接近不冲锋
   - 检测到 `CND_InitiatorEngaged` 后解除限制

3. **Jockey 骚扰模式**
   - 在 steering 中加骚扰模式
   - 快速骑乘但不骑向危险区
   - 检测到 `CND_InitiatorEngaged` 后全力骑向危险区

4. **其他特感**
   - Spitter/Smoker/Boomer 作为发起者时正常行为
   - 作为骚扰者时可以正常攻击（它们本身就是控制型）

## 预期效果

### 修复前
- 所有特感同时冲上去
- 容易被集中火力击杀
- 攻击模式可预测

### 修复后
- **阶段 1**（发起者单独）：
  - Boomer 接近呕吐 或 Smoker 远程拉人
  - 其他特感在周围骚扰（移动、吸引火力）
  - 给玩家"压力不大"的假象

- **阶段 2**（发起者成功后）：
  - 发起者成功呕吐/拉人 → 混乱开始
  - 所有骚扰者立即全力进攻
  - Hunter 扑击、Charger 冲锋、Jockey 骑向危险区
  - 玩家需要同时应对控制+混乱+伤害

## 验证方法

### 当前阶段（基础设施）
开启 `ai_debug 1`，查看日志：
```
[AI_HardSI] Boomer(3) assigned as INITIATOR
[AI_HardSI] Hunter(4) assigned as HARASSER
[AI_HardSI] Charger(5) assigned as HARASSER
```

### 完整集成后
观察特感行为：
1. 首个 Boomer/Smoker 发动攻击
2. 其他特感保持距离骚扰
3. Boomer 呕吐成功或 Smoker 拉人成功
4. 所有特感立即全力进攻

## 相关修复历史

- **v5.12** (2026-08-14): Hunter 欺骗性跳跃（被瞄准时闪避）
- **v5.13** (2026-08-14): 攻击发起者机制基础设施（角色分配+条件节点）
- **v5.14** (待实施): 攻击发起者机制行为树集成

## 参考资料

- [Legend of Dragon 战术原则](https://steamcommunity.com/groups/legendofdragon)
- AI 增强计划：`AI_IMPROVEMENT_PLAN.md`
