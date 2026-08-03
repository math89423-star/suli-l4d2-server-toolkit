# L4D2 服务器插件清单

> 服务器: 81.71.101.135:27015 | 73 active / 0 disabled | 更新时间: 2026-08-03

## 🛠 核心依赖

| 插件 | 说明 |
|------|------|
| `left4dhooks.smx` | L4D2 专有 SourceMod Natives/Hooks，几乎所有 L4D2 插件的前置依赖 |
| `l4d2_source_keyvalues.smx` | Source KeyValues 工具库，为其他插件提供 KV 读写支持 |

## 🛡 SourceMod 官方插件

| 插件 | 说明 |
|------|------|
| `admin-flatfile.smx` | 管理员认证（flat file 方式） |
| `adminhelp.smx` | 管理员命令帮助 |
| `adminmenu.smx` | 管理员菜单界面 |
| `antiflood.smx` | 聊天/命令防刷屏保护 |
| `basebans.smx` | 基础封禁管理（ban/unban） |
| `basechat.smx` | 基础聊天命令（say/say_team 处理） |
| `basecomm.smx` | 通信限制（gag/mute/silence） |
| `basecommands.smx` | 基础管理命令（kick/slay/slap/map） |
| `basetriggers.smx` | 聊天触发器（!admin 等快捷指令） |
| `basevotes.smx` | 基础投票系统（踢人/换图/难度） |
| `clientprefs.smx` | 客户端偏好持久化存储（cookie 系统） |
| `funcommands.smx` | 娱乐命令（burn/freeze/timebomb/firebomb） |
| `funvotes.smx` | 娱乐投票（隐身/无敌/重力等） |
| `playercommands.smx` | 玩家自助命令（/rank /timeleft 等） |
| `reservedslots.smx` | 预留通道（管理员优先进入满服） |

## 🗳 地图/投票系统

| 插件 | 说明 |
|------|------|
| `sm_l4d_mapchanger.smx` | L4D2 增强地图切换管理（战役/关卡切换 + 团灭换图） |
| `l4d2_vote_manager3.smx` | L4D2 投票权限管理系统（免投/冷却/标志控制） |
| `l4d2_nativevote.smx` | L4D2 原生投票修复/增强 |

## 🧟 特感生成/控制

| 插件 | 说明 |
|------|------|
| `specialspawner.smx` | 特感生成控制器 — 刷新间隔/数量上限/安全区/各类权重 |
| `spawn_infected_nolimit.smx` | 移除引擎层特感生成数量限制 |
| `si_composition_manager.smx` | 特感刷新组合管理 — 6种战术模式轮换 + Tank协同，deficit-first 分配类型，动态 spawn_size 缩放 |
| `AI_HardSI_bt.smx` | 特感 AI 强化 — 行为树 v4.1.0（v4.0.5：Witch 死树移除 + Tank 13 cvar 审计接入 + 追击修正（bhop 500u 威胁圈外拉近、处决门控追杀未倒地优先）+ 近战/岩石簇对齐引擎间隔 1.5/5s；**v4.1：Tank 高级玩法四件套 — 协同窗口消费（锁被 pin 目标 + 窗口内拳杀，mode 6 保持小队分散）+ damager 追击门控 800u + 地形秒杀（打汽车/爆炸罐，注入拳伤确定性引爆）+ 飞石预判瞄准（lead=vel×dist/800）与 OnRelease 释放校正**），精准扑击/冲锋/连跳/协同攻击；引擎基准见 `scripting/AI_HardSI_optimized/ENGINE_CVARS.md` |
| `l4d2_tank_unified.smx` | **Tank/Witch 统一核心** — HP 缩放（存活人数 × 3000）+ 播报 |
| `l4d2_max_common.smx` | 普通感染者上限控制 |
| `l4d_path_to_goal.smx` | PTG — SI 导航路径计算（A* 寻路） |

## 📺 HUD / 公告 / 提示

| 插件 | 说明 |
|------|------|
| `l4d2_si_hud.smx` | 特感血量 HUD + 战地击杀横幅 + 计分/钱包/复活系统（v1.9.0；商店已解耦至 l4d2_shop，导出 SH_ API） |
| `l4d2_shop.smx` | 积分商店 !shop/!buy（v1.0.0；自 si_hud v1.8.2 解耦：商品表/菜单/透视特感/火炮支援 I/II + si_hud_shop_enable/si_hud_art_* cvar） |
| `l4d2_bf_killfeedback.smx` | 战地击杀音效（6 种 MP3，v4.2.0；v4.2.1 待发 sound.cache） |
| `advertisements.smx` | 定时轮播服务器公告（120s 间隔） |
| `auto_motd.smx` | 自动显示 MOTD 欢迎信息 |
| `l4d2_broadcast.smx` | 广播玩家死亡/受伤/受击事件 |
| `l4d2_player_status.smx` | 显示玩家状态变化（倒地/挂边/被控等） |
| `l4d2_skill_detect.smx` | 技能检测 — skeet/charger punch/instaclear 等操作提示 |
| `l4d2_witch_ranking.smx` | Witch 伤害排名显示 |
| `kill_cmd.smx` | 玩家 /kill 自杀命令 |
| `kills.smx` | 击杀统计显示 |

## 🔫 武器/弹药调整

| 插件 | 说明 |
|------|------|
| `l4d2_ammo_set.smx` | 弹药携带量自定义设置（SMG 720/AR 540/霰弹 192/猎枪 225 等） |
| `l4d2_m60_ammo.smx` | M60 弹药量设置（450 发） |
| `l4d2_shotgun_speed.smx` | 霰弹枪射速/换弹速度调整 |
| `l4d2_weapon_attributes.smx` | 武器属性修改（伤害/射速/射程等） |
| `WeaponHandling.smx` | 武器操作速度调整（拔枪动画/双枪射速等） |
| `l4d2_mounted_gun_damage.smx` | 固定机枪伤害调整 |

## ⚙️ 游戏性调整

| 插件 | 说明 |
|------|------|
| `l4d2_auto_respawn.smx` | ⛔ 已禁用（2026-08-02）— 无条件复活绕过复活币限次，功能已并入 l4d2_si_hud（si_hud_respawn_*） |
| `l4d2_ff_fix.smx` | 友伤调整 — 友伤倍率 0.30（降低70%），火伤 1.0 |
| `l4d2_shove_fatigue_scaler.smx` | 推挠疲劳度缩放控制 |
| `l4d2_medical_supply_scaler.smx` | 医疗补给数量按人数缩放（包/药/针） |
| `l4dmultislots.smx` | 多人生存者 — 最多 10 人，最少 4 人，免大厅等待 |
| `l4d2_chainsaw_fuel.smx` | 电锯燃料量控制 |
| `l4d2_loot_drop.smx` | 击杀掉落战利品 — Tank/Witch/特感/小僵尸概率掉落 |
| `l4d2_give_items.smx` | 右键递物 — 手持投掷物对队友右键递出（对方槽位空才给）；医疗包/药/电击器 cvar 开关默认关 |
| `l4d2_common_kill_reward.smx` | 击杀小僵尸奖励 |
| `survivor_chat_select.smx` | 聊天指令选择幸存者角色/皮肤 |
| `survivor_legs.smx` | 第一人称可见幸存者双腿（沉浸感增强） |
| `l4d2_ai_damagefix.smx` | AI 伤害计算修复 |
| `l4d2_change_prevent.smx` | 防止玩家恶意更改服务器设置 |

## 🔄 换图/过渡/进度

| 插件 | 说明 |
|------|------|
| `campaign_transition.smx` | 战役过渡管理 |
| `l4d2_survivor_transition.smx` | 换图时恢复幸存者状态（HP 80~100% 可配置） |
| `l4d2_transition_info_fix.smx` | 章节过渡信息传递修复 |
| `transition_restore_fix.smx` | 过渡数据恢复修复 |
| `l4d2_campaign_progression.smx` | 跨回合战役进度保存/加载 |
| `l4d2_last_map_saver.smx` | 最后地图记录保存 |
| `l4d2_mission_manager.smx` | 任务/章节流程管理 |
| `l4d2_lobby_match_manager.smx` | 大厅匹配管理，免 lobby 直接加入 |

## 🐛 BUG 修复

| 插件 | 说明 |
|------|------|
| `cge_l4d2_deathcheck.smx` | 死亡检测修复（deathcheck "1"） |
| `block_bot_kick.smx` | 阻止玩家投票踢出 BOT |
| `fix_botkick.smx` | 修复 BOT 被游戏引擎意外移除的问题（非投票场景） |
| `l4d2_GetWitchNumber.smx` | 正确获取 Witch 数量的函数修复 |
| `l4d2_pause_game.smx` | 游戏暂停功能 |
| `l4d2_gl_splash_fix.smx` | 榴弹发射器溅射伤害修复（Tank 2.5x / Witch 1.5x） |

## 🔧 服务器管理

| 插件 | 说明 |
|------|------|
| `l4d2_sethostname.smx` | 从 data/hostname.txt 读取并设置服务器名 |
| `l4d_unreservelobby.smx` | 解除大厅预留 — 10 人满后关闭 lobby 连接，heartbeat 30s |
| `l4d_CreateSurvivorBot.smx` | 动态创建/管理幸存者 BOT |
| `l4d2_tickrate_enabler.smx` | 60-tick 网络 cvar 自动配置 |
| `command_buffer.smx` | Cbuf_AddText 缓冲区溢出修复（支持大型 exec 文件） |

## ⚠️ 注意事项

- **副本服务器差异**：参考服务器不使用 `l4d2_tickrate_enabler.smx`（改用 `-tickrate 60` 启动参数），这是两项 60-tick 方案之间的唯一差异。
- **已删除的插件**：`mapchooser.smx`、`nominations.smx`、`rockthevote.smx`、`randomcycle.smx` 已永久删除（mapchooser 无法创建有效地图列表）。
- **已移除的插件**（2026-07-29）：`l4d2_maptankfix`、`l4d2_tank_ranking`、`l4d2_si_kill_heal`（`l4d2_bf_killfeedback` 已于 2026-07-31 以纯音效版 v4.2.0 恢复部署：HUD 归 si_hud，音效归 bf_killfeedback）。
- **重命名**：`l4d2_tank_core` → `l4d2_tank_unified`，`L4D_All_Infected_HUD_HP` → `l4d2_si_hud`。
- **关键配置**：武器属性、团灭换图阈值（4 次）、弹药量等在 `cfg/sourcemod/sourcemod.cfg` 中统一定义。
- **Tank HP**：`l4d2_tank_unified.smx` → 存活人数（含 BOT）× 3000，最低 12,000 HP。
- **SI 刷新链**：`specialspawner`（节奏/上限）→ `si_composition_manager`（类型分配）→ `AI_HardSI_bt`（行为决策），三层各司其职，无冲突。
- **HardSI 源码布局**：源码在 `scripting/AI_HardSI_optimized/`（AI_HardSI.sp + 12 个 bt_*.inc 专属头文件 + hardcoop_util.sp，不混入全局 include/）。**约定：源码目录只放 .sp/.inc，编译产物只输出到 `compiled/`，运行版在 `plugins/`**（2026-08-03 已清理源码目录内过期 .smx 残留）。
- **历史备份目录**：`all_plugins_disabled/`（10 个旧插件）、`disabled_crash/`（1 个）、`scripting/`（源码编译产物），这些目录中的 .smx 不会被 SourceMod 加载。
