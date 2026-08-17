---
name: l4d2-rescue-heal-plugin
description: L4D2 救人回血插件 l4d2_rescue_heal — 救助倒地+20/打包电击+20/挂边拉起+10/递药+3；v1.4 递药差分推导已部署待实测
metadata: 
  node_type: memory
  type: project
  originSessionId: dafad0ff-6c8c-4d29-b792-2858510a4960
  modified: 2026-08-02T02:22:06.194Z
---

# L4D2 救人回血插件（l4d2_rescue_heal v1.3）

2026-07-31 部署。之前服务器上**根本不存在**救人回血插件（74 插件清单里没有），从零编写。
2026-08-02 升 v1.3（修两 bug，commit 9d4881b）。

## 行为（奖励给**救人者**，用户指定）

| 动作 | 事件 | 实血奖励 | cvar |
|------|------|---------|------|
| 救助倒地队友 | revive_success（非挂边非死亡） | +20 **仅救人者** | `l4d2_rescue_heal_incap` |
| 给队友打包 | heal_success（打包者由 StartUseAction 记录） | +20 打包者 + 被打包者 | `l4d2_rescue_heal_medkit` |
| 电击复活队友 | revive_success（事件前 m_isDead=1） | +20 **仅救人者** | `l4d2_rescue_heal_defib` |
| 挂边拉起队友 | revive_success（事件前 m_isHangingFromLedge=1） | +10 **仅救人者** | `l4d2_rescue_heal_ledge` |
| 给队友递药/肾上腺素 | pills_used（递药者由 StartUseAction 记录） | +3 递药者 + 吃药者 | `l4d2_rescue_heal_pills` |

其他 cvar：`_enable` 总开关、`_max` 奖励后血量上限(100)、`_announce` 聊天播报。

> **v1.3 行为变更**：救人动作（拉倒地/挂边/电击）**不再给被救者加血**（用户指定"被救的人不应该加血"）。
> 打包/递药保留 v1.2 的双向加血（用户当时指定"给队友打包点击队友也要加血"）。

## 实现要点

- 0.2s 轮询镜像 `m_isDead` + `m_isHangingFromLedge` 两个 prop，区分 revive_success 三种来源（见 [[l4d2-no-defibrillated-event]]）
- 自己吃药/自己打包/自己爬起不算（subject==user/rescuer 过滤）；BOT 无奖励
- **打包/递药执行者检测（v1.3 关键坑）**：SDKHooks OnUse 对打包/递药**从不触发**——实测 2.2 万条 OnUse 日志全部是持枪/近战按 E（weapon_melee/weapon_rifle 等），0 条 weapon_first_aid_kit/pills → 打包者记录永远写不上 → 打包奖励全灭。v1.3 改用 left4dhooks 引擎级 detour `L4D2_OnStartUseAction_Post`（SilverShot Direct 版 API，非老版 prodigysiml 的 L4D_OnHealSuccess）：action=1(L4D2UseAction_Healing) 时 client=打包者、target=被打包者，heal_success 查表发放；target 异常时 L4D_FindUseEntity 兜底；记录 15s 过期
- 递药同理走 StartUseAction（手持 pills/adrenaline 武器判定），5s 过期——**未实测验证** pills 是否触发 StartUseAction（枚举"未列全"），递药奖励待玩家实测，日志搜 `记录递药者`
- 配置文件 `cfg/sourcemod/l4d2_rescue_heal.cfg`，改数值 RCON `sm_cvar` 即刻生效
- 源码 `scripting/l4d2_rescue_heal.sp`（git 已提交，smx 被 gitignore 只提交 .sp），smx 在 `plugins/`
- 旧版备份 `plugins/l4d2_rescue_heal.smx.bak.v1.2`

## v1.7（2026-08-16 热加载部署，commit 6597d2a）

**用户定稿**：递药改单向——只有递药者 +3 实血，吃药者不再加血（与打包修改
一致；药丸自身回血效果不受影响）。清理 Reward 的 toSubject 双向死分支
（v1.2 双向加血逻辑全部移除）。至此**所有救助奖励都是单向（只给执行者）**：

| 动作 | 实血 | 积分 |
|------|------|------|
| 救助倒地 | +20 救人者 | +600 |
| 打包 | +20 打包者 | +800 |
| 电击 | +20 电击者 | +1000 |
| 挂边 | +10 救人者 | 无 |
| 递药 | +3 递药者 | 无 |

## v1.6（2026-08-16 热加载部署，commit cd22fa0）

**用户定稿**：电击复活 +1000 积分（电击器最稀缺，奖励最高档）——`l4d2_rescue_heal_defib_score`；实血 +20 保留。至此救助积分全齐：

| 动作 | 实血 | 积分 |
|------|------|------|
| 救助倒地 | +20 | **+600** |
| 打包 | +20（仅打包者） | **+800** |
| 电击 | +20 | **+1000** |
| 挂边/递药 | +10/+3 | 无 |

## v1.5（2026-08-16 热加载部署，commit d74949f）

**用户定稿**：打包 +800 积分、拉起倒地 +600 积分；FIX 打包双向回血 bug。

| 动作 | 实血奖励（保留） | 积分奖励（v1.5 新增） | cvar |
|------|---------|---------|------|
| 救助倒地队友 | +20 仅救人者 | **+600 救人者** | `l4d2_rescue_heal_incap_score` |
| 给队友打包 | +20 仅打包者（**删双向**） | **+800 打包者** | `l4d2_rescue_heal_medkit_score` |
| 电击/挂边/递药 | +20/+10/+3（不变） | 无 | — |

- **FIX bug**：v1.2"被打包者 +20 回血"删除（用户实测为 bug；医疗包引擎自身回血不受影响）
- 积分走 si_hud `SH_AddWallet` native（可选绑定，si_hud 未加载静默跳过）；与实血 Reward 独立（满血不影响积分）
- cfg 已手动追加两 cvar（AutoExecConfig 对已存在 cfg 不追加）

## 实测结果（2026-08-02 上午，玩家实测）

- ✅ 救助倒地 +20 正常、打包 +20 正常（日志 `OnStartUseAction(Healing): 记录打包者` 有记录）
- ✅ 被救者不加血正常（无异议反馈）
- ❌ **递药无回血** → v1.4 修复（见下）

## v1.4（2026-08-02 已热重载部署，待玩家实测）

**根因实锤**：`L4D2_OnStartUseAction_Post` 的递药兜底分支**从未打印过**"记录递药者"（日志零记录）→ pills 递药不走 StartUseAction detour，枚举确实不覆盖。

**方案（轮询差分推导）**：
- 0.2s 轮询（Timer_StateCheck 扩展）跟踪每个玩家 health 槽（slot 4）pills/adrenaline 武器实体 `g_iPillSlotEnt`，实体消失记时刻 `g_fPillLostTime`（medkit 不算）
- `Event_PillsUsed` 时 StartUseAction 记录缺失/过期 → `InferPillGiver(subject)`：查 5s 内"失去药"的最近玩家（排除吃药者本人）= 递药者
- 日志 `轮询差分推导递药者` 可验证链路
- 误判场景（可接受，待实测）：两人 5s 内先后各自吃药会误判递药

**验证方法**：递药给队友 → 聊天应提示"给队友递药 +3" 双方各 +3；不行查日志 `轮询差分推导递药者`（有推导无奖励→事件问题；无推导→看 g_fPillLostTime 是否记录）。
