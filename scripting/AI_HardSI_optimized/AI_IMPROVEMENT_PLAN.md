# AI_HardSI 特感增强计划（基于社区最佳实践研究）

## 排除项（明确不做）

- ❌ 不修改被推后恢复时间（保持原版）
- ❌ 不修改任何伤害数值
- ❌ Charger 不做冲锋中转向（技术难度高 + 可能过强）
- ❌ Charger 不做智能防坠落（悬崖下一换一是有效战术）
- ❌ Tank 不做动态切换投掷目标（技术难度高）
- ❌ Tank 不修改速度（保持 z_tank_speed=210）
- ❌ Boomer 目前不做修改（已有的优化保持）

---

## 🔥 Phase 1：高优先级（立即实施）

### 1.1 Hunter 欺骗性跳跃（Deception Leap）

**来源**：[Improved Hunter AI](https://steamcommunity.com/workshop/filedetails/?id=3140922442)

**功能描述**：
- 当 Hunter 感知到被瞄准时，执行随机方向的假跳
- 不是扑击跳，而是纯闪避跳跃
- 使 Hunter 更难被爆头，模拟人类玩家的闪避行为

**实现方案**：
```sourcepawn
// 检测威胁
- 遍历幸存者，检测是否有人瞄准 Hunter（视线夹角 < 15°）
- 距离在 300-800u 之间（太近来不及跳，太远无威胁）
- Hunter 在地面且未蹲伏

// 触发假跳
- 随机方向（±60° 到 ±120°）
- 按 IN_JUMP，不按 IN_ATTACK2
- 冷却 3-5 秒（避免频繁跳）
```

**代码位置**：`bt_hunter.inc` 新增 `HunterCond_UnderThreat` + `HunterAct_EvasiveJump`

**预期效果**：Hunter 在接近时会突然侧跳/后跳，打断玩家瞄准节奏

---

### 1.2 攻击发起者机制（Attack Initiator Role）

**来源**：[Legend of Dragon](https://steamcommunity.com/groups/legendofdragon)

**功能描述**：
- 每波攻击指定一个"发起者"（Boomer 或 Smoker）
- 发起者优先攻击，其他特感作为"骚扰者"
- 骚扰者避免过早暴露，等待发起者成功后再全力进攻

**实现方案**：
```sourcepawn
// 波次开始时分配角色
- si_composition_manager 在波次生成时随机选择：
  - 50% Boomer 发起（适合近战开团）
  - 50% Smoker 发起（适合远程拉人）
- 通过黑板变量标记：BB_SetInt(client, "wave_role", ROLE_INITIATOR/ROLE_HARASSER)

// 发起者行为
- ROLE_INITIATOR：正常攻击，优先级不变
- ROLE_HARASSER：
  - Hunter：保持 600-1000u 距离，只在发起者成功后才扑击
  - Charger：等待 Boomer 炸人/Smoker 拉人后再冲锋
  - Jockey：骚扰模式，快速骑乘但不骑向危险区
  
// 转换条件
- 发起者成功控制目标后，所有骚扰者转为全力进攻
- 发起者死亡，随机选一个骚扰者升级为发起者
```

**代码位置**：
- `si_composition_manager.smx` 新增角色分配逻辑
- `bt_common.inc` 新增 `CND_IsInitiator` / `CND_IsHarasser`
- 各特感行为树添加角色分支

**预期效果**：攻击更有层次感，不再一窝蜂，给玩家更多应对时间但压力更持续

---

## 🌟 Phase 2：中优先级（深入研究后实施）

### 2.1 Hunter 墙面二段跳（Wall Pounce）

**来源**：[Improved Hunter AI](https://steamcommunity.com/workshop/filedetails/?id=3140922442)

**功能描述**：
- Hunter 在空中扑击失败时，如果贴墙可以再次扑击
- 类似人类玩家的"壁蹬"技巧

**实现难点**：
- 检测空中状态 + 贴墙判断（trace 多个方向）
- 引擎允许空中二次扑击（可能需要解除 FL_ONGROUND 检查）
- 冷却机制（避免无限连跳）

**技术方案**：
```sourcepawn
// 空中贴墙检测
- Hunter 在空中（!(GetEntityFlags & FL_ONGROUND)）
- 刚扑击过（g_bHunterJustLunged[client]）
- Trace 四个方向（前/左/右），距离 < 50u 判定为贴墙

// 允许二次扑击
- 临时移除 CND_OnGround 限制
- 按 IN_ATTACK2 触发扑击
- 标记已使用二段跳（本次起跳只能用一次）
```

**代码位置**：`bt_hunter.inc` 新增 `HunterCond_CanWallPounce` + `HunterAct_WallPounce`

**预期效果**：Hunter 扑空后不再无助落地，可以利用墙面再次发起攻击

---

### 2.2 Hunter 高空伤害加成（High Pounce Damage Bonus）

**来源**：[Improved Hunter AI](https://steamcommunity.com/workshop/filedetails/?id=3140922442)

**功能描述**：
- 根据扑击前的高度差或垂直速度增加伤害
- 奖励高位扑击，符合物理直觉

**⚠️ 矛盾点**：用户要求"不修改伤害"，此项可能需要重新确认

**实现方案**（如批准）：
```sourcepawn
// 监听 ability_use（Hunter 扑击）
- 记录扑击瞬间的高度 z1
// 监听 lunge_pounce（命中目标）
- 记录命中瞬间的高度 z2
- 高度差 dz = z1 - z2
// 额外伤害计算
- 如果 dz > 100u，额外伤害 = (dz - 100) / 20
- 通过 SDKHooks_TakeDamage 注入额外伤害
```

**代码位置**：`bt_hunter.inc` 新增事件监听

**状态**：⚠️ **暂缓**（与"不修改伤害"原则冲突）

---

### 2.3 Spitter 酸液扩散修复（Acid Spread Fix）

**来源**：[Improved Acid Spread](https://steamcommunity.com/sharedfiles/filedetails/?id=3132874203), [Spitter acid spread fix](https://steamcommunity.com/sharedfiles/filedetails/?id=2945425218)

**功能描述**：
- 修复酸液落在物理道具（prop_physics/prop_dynamic）上时穿透到地面下方的 bug
- 酸液应该正确扩散在道具表面

**实现方案**：
```sourcepawn
// 监听 insect_spit（酸液生成）
- 追踪酸液实体
// 检测碰撞
- 定时检查酸液是否碰到 prop_physics/prop_dynamic
- 如果碰到，调整酸液的 z 坐标到道具表面
- 触发扩散效果
```

**技术难点**：
- 需要理解引擎的酸液扩散机制
- 可能需要 detour 引擎函数

**代码位置**：新增 `l4d2_spitter_acid_fix.sp` 独立插件

**预期效果**：酸液在桌子/车辆上正确扩散，不再穿透到地面

---

### 2.4 Spitter 预判投掷（Predictive Spit）

**功能描述**：
- 根据幸存者的移动方向和速度，预判投掷位置
- 提高酸液命中率

**实现方案**：
```sourcepawn
// 获取目标移动信息
- 速度向量：GetEntPropVector(target, Prop_Data, "m_vecVelocity", vel)
- 如果速度 > 100u/s，计算预判点

// 预判计算
- 飞行时间 t ≈ distance / projectile_speed（估算）
- 预判点 = 当前位置 + 速度向量 × t × 0.6（保守系数）

// 瞄准预判点
- BT_SetAimAngles 瞄准预判点而非当前位置
```

**代码位置**：`bt_spitter.inc` 修改 `SpitterAct_Spit`

**预期效果**：Spitter 对移动中的幸存者命中率显著提升

---

### 2.5 Jockey 弹跳骑乘增强（Bounce Riding）

**来源**：[TGMaster/hardcoop](https://github.com/TGMaster/hardcoop) "jockeys bounce around!"

**功能描述**：
- 骑乘时更频繁、更大幅度地变换方向
- 模拟"弹簧"效果，更难被队友解救

**实现方案**：
```sourcepawn
// 骑乘时的 steering 增强
- 当前 v5.6 已有 steering，但幅度较小
- 提升转向频率：0.3-0.5s 切换一次（原 0.5-1.0s）
- 提升转向角度：±60° 到 ±90°（原 ±30° 到 ±45°）
- 偶尔反向拉扯（180° 转向）

// 垂直抖动
- 随机按 IN_JUMP（10% 概率每 tick）
- 制造上下抖动效果
```

**代码位置**：`bt_jockey.inc` 修改 `JockeyAct_Steer`

**预期效果**：被骑乘的玩家感觉像坐过山车，队友更难瞄准 Jockey

---

### 2.6 Tank 物体投掷瞄准（Prop Throw Aim）

**来源**：[Improved Tank AI](https://steamcommunity.com/sharedfiles/filedetails/?id=3069974243)

**功能描述**：
- Tank 击打周围物体（车辆、桌子）时，控制其飞行轨迹朝向幸存者
- 增加环境物体的威胁性

**实现方案**：
```sourcepawn
// 监听 Tank 近战攻击
- player_shoved 或 weapon_melee_hit（Tank 的拳击）
- 检测被击中的实体是否是 prop_physics/prop_car_alarm

// 修改物体速度
- 获取最近的幸存者位置
- 计算从物体到幸存者的方向向量
- SDKHook OnTakeDamagePost 或直接修改 m_vecVelocity
- 设置速度 = 方向 × 力度（800-1200 u/s）
```

**代码位置**：`bt_tank.inc` 新增事件监听

**预期效果**：被 Tank 打飞的车辆会朝玩家方向飞来，而非随机方向

---

## 💡 Phase 3：实验性功能（待评估）

### 3.1 Smoker 拖向危险区（Pull to Hazard）

**功能描述**：
- Smoker 拉人时优先选择悬崖边缘、火焰区、酸液区作为拉拽方向
- 增加拉人的致命性

**技术难点**：
- 需要检测周围的危险区域（nav attributes、火焰/酸液实体）
- 计算最优拉拽角度
- 引擎对 Smoker 拉拽方向控制有限

**状态**：⚠️ **待技术验证**

---

### 3.2 Hunter 逃跑跳转扑击跳（Flee to Pounce）

**来源**：[Improved Hunter AI](https://steamcommunity.com/workshop/filedetails/?id=3140922442)

**功能描述**：
- Hunter 扑空后的逃跑跳（EscapeJump）自动转为扑击跳
- 避免浪费逃跑的跳跃高度

**实现方案**：
```sourcepawn
// 修改 HunterAct_EscapeJump
- 原版只按 IN_JUMP
- 新版同时按 IN_ATTACK2（扑击）
- 随机角度保持不变
```

**代码位置**：`bt_hunter.inc` 修改 `HunterAct_EscapeJump`

**状态**：✅ **简单修改，可快速实施**

---

## 📊 实施优先级总结

| Phase | 功能 | 难度 | 收益 | 状态 |
|-------|------|------|------|------|
| **Phase 1** | Hunter 欺骗性跳跃 | ⭐⭐ | 🔥🔥🔥 | 待实施 |
| **Phase 1** | Charger 智能防坠落 | ⭐⭐⭐ | 🔥🔥🔥 | 待实施 |
| **Phase 1** | 攻击发起者机制 | ⭐⭐ | 🔥🔥🔥 | 待实施 |
| **Phase 2** | Hunter 墙面二段跳 | ⭐⭐⭐⭐ | 🔥🔥 | 待研究 |
| **Phase 2** | Spitter 酸液扩散修复 | ⭐⭐⭐ | 🔥🔥 | 待研究 |
| **Phase 2** | Spitter 预判投掷 | ⭐⭐ | 🔥🔥 | 待实施 |
| **Phase 2** | Jockey 弹跳骑乘增强 | ⭐⭐ | 🔥🔥 | 待实施 |
| **Phase 2** | Tank 物体投掷瞄准 | ⭐⭐⭐⭐ | 🔥🔥 | 待研究 |
| **Phase 3** | Hunter 逃跑转扑击跳 | ⭐ | 🔥 | 可快速实施 |
| **Phase 3** | Smoker 拖向危险区 | ⭐⭐⭐⭐ | 🔥 | 待技术验证 |

---

## 📝 实施计划时间线

### Week 1：Phase 1 高优先级
- Day 1-2: Hunter 欺骗性跳跃
- Day 3-4: Charger 智能防坠落
- Day 5-7: 攻击发起者机制

### Week 2-3：Phase 2 中优先级
- Week 2: Spitter 预判投掷 + Jockey 弹跳增强
- Week 3: Spitter 酸液扩散修复 + Tank 物体投掷瞄准

### Week 4+：Phase 2 高难度 + Phase 3
- Hunter 墙面二段跳（需深入引擎机制研究）
- 其他实验性功能

---

## 🎯 预期整体效果

实施 Phase 1 后：
- Hunter 更难被爆头，接近时会突然闪避
- Charger 不再愚蠢地冲下悬崖
- 特感攻击更有层次，先骚扰再全力进攻

实施 Phase 2 后：
- Hunter 可以利用墙面二次攻击
- Spitter 命中率显著提升，酸液扩散更真实
- Jockey 骑乘时像弹簧一样难以解救
- Tank 打飞的物体会朝玩家飞来

最终效果：
- 特感 AI 达到甚至超越社区最佳实践水平
- 保持原版平衡（不修改伤害/速度/恢复时间）
- 行为更像人类玩家，更有战术深度

---

## 参考资料

- Hunter: [Improved Hunter AI](https://steamcommunity.com/workshop/filedetails/?id=3140922442)
- Charger: [Improved Charger AI](https://steamcommunity.com/sharedfiles/filedetails/?id=3482161405), [Prevent AI Charge](https://steamcommunity.com/workshop/filedetails/?id=2987835896)
- Spitter: [Improved Spitter AI](https://steamcommunity.com/sharedfiles/filedetails/?id=3449751998), [Acid Spread Fix](https://steamcommunity.com/sharedfiles/filedetails/?id=3132874203)
- Jockey: [Improved Jockey AI](https://steamcommunity.com/sharedfiles/filedetails/?id=3449750974)
- Tank: [Improved Tank AI](https://steamcommunity.com/sharedfiles/filedetails/?id=3069974243)
- Coordination: [Legend of Dragon](https://steamcommunity.com/groups/legendofdragon)
- Overall: [TGMaster/hardcoop](https://github.com/TGMaster/hardcoop)
