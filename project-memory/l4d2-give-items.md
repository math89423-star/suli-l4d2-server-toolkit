---
name: l4d2-give-items
description: L4D2 右键递物插件 l4d2_give_items — 手持投掷物对队友右键递出（槽位空才给），无音效（原版音效不可用，见 v1.2）；医疗包/药/电击器代码就绪默认关
metadata: 
  node_type: memory
  type: project
  originSessionId: 66686e24-5284-42a1-b757-66a65ab1574a
  modified: 2026-08-02T10:07:47.822Z
---

# L4D2 右键递物插件（l4d2_give_items v1.1）

2026-08-02 部署（热加载）。需求："投掷物或医疗包槽位物品，右键队友、对方有空位就递过去"。用户多选只勾了投掷物 → 默认只开投掷物。

## v1.1（2026-08-02 热更新）→ v1.2 音效已默认关闭

- **蓄力防误递（保留）**：参考 Gear Transfer line-1114 修复（Harry）——按住 IN_ATTACK 时右键不触发递物，防投掷蓄力瞄准中误递
- **递出音效（已撤）**：v1.1 加 `l4d2_give_items_sound` 默认 `weapon_pain_pills/use.wav`（原版递药音效=药丸使用声），成功递出时双方各播一次；**用户实测无音效 → v1.2 默认置空关闭**（代码保留，cvar 留空即不播，未来有可靠音效来源再开）

### 音效调查结论（为什么要猜：服务器上没有可以查证的数据）

1. 同款插件 Gear Transfer **本身不播音效**（只有聊天通知 `l4d_gear_transfer_notify`）——"同款递药音效"实指原版 E 递药播的药丸使用声
2. **本镜像服务端无任何原版音效数据**（见 [[l4d2-no-vanilla-sounds]]）：sound/ 只有自定义音效，scripts 无 game_sounds/soundscripts，pak01 vpk 全是垃圾文件 → `weapon_pain_pills/use.wav` 只是推测路径，服务器侧无法验证
3. EmitSoundToClient 播原版路径时**客户端用自己的游戏文件解析**（服务端有无该文件不影响发送），实测无声 = 路径名不对或客户端无此文件
4. 未来可行方案（任选）：① 从任一客户端安装提取原版 use.wav 的**真实文件名**（sound/weapon_pain_pills/ 下）改 cvar；② 自定义 mp3 走已验证的 precache 管线（[[l4d2-bf-killfeedback]] 的结论）
5. ⚠️ 引擎残留坑复现：v1.2 把 cvar 默认值改为 "" 后 reload，**cvar 值仍是旧值**（CreateConVar 对已存在 cvar 不更新默认）——必须 `sm_cvar l4d2_give_items_sound ""` 显式置空（[[l4d2-source-code-location-pitfall]] 已记录该坑）

## 行为

| 动作 | 结果 |
|------|------|
| 手持炸弹/燃烧瓶/胆汁 + 右键对队友 | 对方槽2空 → 递出，双方聊天提示；满 → "该槽位已有物品" |
| 手持医疗包/药/肾上腺素 | 代码就绪，`l4d2_give_items_medkit/pills/defib` 默认 0 关闭 |
| 手持近战右键 | 不受影响（非可递物品不响应）→ 推挤/火炮瞄准取消等场景零冲突 |

## 实现要点

- **触发**：OnPlayerRunCmd IN_ATTACK2 按下沿（g_bPrevAttack2 边沿检测），按住不重复
- **目标**：GetClientAimTarget(client, true) + 距离 ≤ `l4d2_give_items_range`(110) + 幸存者队友（倒地可收）
- **槽位（left4dhooks L4DWeaponSlot 枚举）**：投掷物=2、医疗包=3、药/肾上腺素=4 —— rescue_heal 用 slot 4 跟踪药是对的（L4D2 引擎药和医疗包分开占槽）
- **转移**：`GivePlayerItem(target, cls)` 先给 → `RemovePlayerItem(client, active) + RemoveEntity(active)` 后移除（主动武器引擎自动切换）；m_hUsingEntity 使用中跳过（防移除动画中武器）
- **消息走 PrintToChat**（`\x04[递物]\x01`），不用 PrintHintText（CJK 坑，见 [[l4d2-printhinttext-priming-bug]]）
- **用过的物品替换**：`l4d2_give_items_replace_used` 默认 1。L4D2 用过的医疗包/空药瓶仍占槽，`IsUsedItem()` 防御式双探测（HasEntProp m_bIsUsed → m_iClip1<=0）+ 日志留证 `used-check`，**未实测校准**（医疗包/药开启后首次测试验证）
- cvar 全英文描述（cfg 注释不能中文，[[l4d2-howto-plugins]] 铁律）；`AutoExecConfig(true, "l4d2_give_items")` cfg 已自动生成
- 源码 `scripting/l4d2_give_items.sp`，smx `plugins/l4d2_give_items.smx`，已加 PLUGINS.md 清单

## 验证

- ✅ 编译零警告（spcomp 1.12.0.7220）、RCON 热加载成功、cvar 查询存在即证明插件存活
- ⚠️ **RCON 脚本 `sm plugins list` 响应不可靠**（每次返回子集不同，长响应截断）——验证插件是否加载用 `sm plugins reload` 输出或查 cvar，别信列表
- ⏳ 待玩家实测：递投掷物、槽满拒绝、近战推挤无干扰、递出音效双方可闻（若无声 → 原版 wave 名需再校准，VPK 压缩 strings 搜不到，需解包或 soundinfo）

## 关联

- [[l4d2-rescue-heal-plugin]] — 同款槽位/递药研究
- [[l4d2-howto-plugins]] — 部署/验证流程
- [[l4d2-dont-touch-server]] — 玩家在玩时的静默规则
