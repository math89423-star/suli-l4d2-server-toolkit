# AI_HardSI_bt v5.11 — Hunter 增强横移和角度偏移（2026-08-14）

## 问题

用户反馈："左右随机角度 实际还是直来直去"

## 根因

v5.10 的代码已经实现了横移和角度偏移，但参数相对保守：
- **Sprint 横移切换**：0.3-0.8s
- **Sprint 角度偏移**：±25°
- **绕后概率**：30%
- **绕后距离**：200u
- **Crouch 横移切换**：0.5-1.2s
- **Crouch 角度偏移**：0°（只有横移，无角度偏移）
- **开阔地形扑击**：±25° 高斯偏移

这些参数在实战中可能表现不够明显，看起来"直来直去"。

## 修复（v5.11）

### 1. Sprint 阶段增强

**bt_hunter.inc:171-233** — `HunterAct_SprintApproach`

```sourcepawn
// v5.11: 增强横移+角度偏移（用户反馈"直来直去"）—— 切换间隔缩短到 0.2-0.5s，
// 角度偏移加大到 ±40°，绕后概率提升到 50%，绕后距离加大到 300u。

// 横移切换：0.3-0.8s → 0.2-0.5s（更频繁）
BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.2, 0.5));

// 角度偏移：±25° → ±40°（更大弧线）
BB_SetFloat(client, "_aim_offset", GetRandomFloat(-40.0, 40.0));

// 绕后概率：30% → 50%（一半时间都在绕后）
BB_SetBool(client, "_flank_behind", GetRandomFloat(0.0, 1.0) < 0.5);
BB_SetFloat(client, "_flank_next", now + GetRandomFloat(1.0, 1.8));

// 绕后距离：200u → 300u（更大弧线）
behind[0] = tPos[0] + dir[0] * 300.0;
behind[1] = tPos[1] + dir[1] * 300.0;
```

### 2. Crouch 阶段增强

**bt_hunter.inc:235-287** — `HunterAct_CrouchApproach`

```sourcepawn
// v5.11: 增强横移频率（用户反馈"直来直去"）—— 切换间隔缩短到 0.3-0.8s。

// 横移切换：0.5-1.2s → 0.3-0.8s（更频繁）
BB_SetFloat(client, "_strafe_next_crouch", now + GetRandomFloat(0.3, 0.8));

// 新增：蹲伏接近时也加 ±20° 角度偏移（原来只有横移，无角度偏移）
ang[1] += GetRandomFloat(-20.0, 20.0);

// 使用独立的黑板变量（避免和 Sprint 阶段冲突）
BB_GetFloat(client, "_strafe_next_crouch")
BB_GetBool(client, "_strafe_left_crouch", false)
```

### 3. 开阔地形扑击增强

**bt_hunter.inc:304-316** — `HunterAct_WideGaussOffset`

```sourcepawn
// v5.11: 加大到 ~35° 标准差，使开阔地形扑击更难预测。

// 高斯偏移：25° → 35°（更大角度随机）
float offset = (GetRandomFloat(-1.0, 1.0) + GetRandomFloat(-1.0, 1.0) + GetRandomFloat(-1.0, 1.0)) * 35.0;
```

## 编译

```bash
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting/AI_HardSI_optimized
../spcomp AI_HardSI.sp -o../compiled/AI_HardSI_bt.smx -i../include
```

- **编译输出**: 13 warnings（存量未使用符号，无影响）
- **代码大小**: 190016 bytes（+104 bytes vs v5.10）
- **数据大小**: 679412 bytes（+16 bytes）
- **总计**: 887972 bytes（+120 bytes）
- **部署时间**: 2026-08-14 18:41

## 部署

```bash
cp scripting/compiled/AI_HardSI_bt.smx plugins/AI_HardSI_bt.smx
# 等待换图自动重载，或服务器空闲时手动 reload
```

⚠️ **当前服务器有玩家在线**，等待换图或空闲时生效。

## 预期效果

修复后 Hunter 的行为应该明显更加"飘忽不定"：

### Sprint 阶段（远距离 >400u）
- **横移切换**：每 0.2-0.5 秒变换左右方向
- **角度偏移**：±40° 随机偏离目标方向
- **绕后概率**：50% 的时间会跑弧线绕到幸存者背后
- **绕后距离**：300u 的大弧线

观感：Hunter 应该像是在"跳舞前进"，而不是直线冲刺。

### Crouch 阶段（近距离 400-600u）
- **横移切换**：每 0.3-0.8 秒变换左右方向
- **角度偏移**：±20° 随机偏离
- **蹲伏接近**：蛇形蹲爬，不再是直线蹲伏

观感：Hunter 应该像是在"蛇形潜行"，左右摇摆接近。

### 扑击阶段
- **开阔地形**：±35° 高斯偏移（Strategy 0）
- **标准扑击**：±15° 高斯偏移 + 30% 过顶扑
- **近距离**：直扑（≤200u，反应优先）

观感：扑击角度应该很难预测，经常从意想不到的角度飞过来。

## 验证方法

开启 `ai_debug 1`，观察 Hunter 的行为：
1. 远距离应该有明显的 Z 字形轨迹
2. 经常看到 Hunter 跑向幸存者侧面或后方，而不是直线冲过来
3. 蹲伏接近时应该有明显的左右摇摆
4. 扑击角度应该很分散，不是每次都正面扑

如果还是"直来直去"，可能的原因：
1. 插件未生效（需要换图或 reload）
2. 其他行为树分支优先级更高（例如窄巷直扑、高台跳跃）
3. BT_StuckDetour 的绕行机制覆盖了横移（顶墙时）

## 相关历史

- **v5.5** (2026-08-05): 首次实现 Sprint 横移 + 缓存角度偏移 + 绕后机制
- **v5.10** (2026-08-14): 修复最后一个站桩 bug（`fastPounceSeq` Cooldown）
- **v5.11** (2026-08-14): 增强横移频率和角度偏移（应对"直来直去"反馈）

## 参数对比

| 参数 | v5.10 | v5.11 | 变化 |
|------|-------|-------|------|
| Sprint 横移切换 | 0.3-0.8s | 0.2-0.5s | **更频繁 ~40%** |
| Sprint 角度偏移 | ±25° | ±40° | **+60%** |
| 绕后概率 | 30% | 50% | **+67%** |
| 绕后距离 | 200u | 300u | **+50%** |
| Crouch 横移切换 | 0.5-1.2s | 0.3-0.8s | **更频繁 ~50%** |
| Crouch 角度偏移 | 0° | ±20° | **新增** |
| 开阔地形扑击 | ±25° | ±35° | **+40%** |

所有参数都朝"更飘忽"的方向调整。
