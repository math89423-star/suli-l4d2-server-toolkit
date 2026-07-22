# L4D2 服务器插件清单

> 服务器: 81.71.101.135:27015 | 70 active / 0 disabled | 更新时间: 2026-07-21

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
| `sounds.smx` | 声音表情管理（播放/下载自定义音效） |

## 🗳 地图/投票系统

| 插件 | 说明 |
|------|------|
| `sm_l4d_mapchanger.smx` | L4D2 增强地图切换管理（战役/关卡切换 + 团灭换图） |
| `l4d2_vote_manager3.smx` | L4D2 投票权限管理系统（免投/冷却/标志控制） |
| `l4d2_nativevote.smx` | L4D2 原生投票修复/增强 |

## 🧟 特感生成/控制

| 插件 | 说明 |
|------|------|
| `specialspawner.smx` | 特感生成控制器——2 + 0.5×人数 配置，限 nav mesh 地图 |
| `spawn_infected_nolimit.smx` | 移除特感生成数量限制 |
| `AI_HardSI.smx` | 特感 AI 强化——精准扑击、冲锋、连跳、投石 |

## 📺 HUD / 公告 / 提示

| 插件 | 说明 |
|------|------|
| `L4D_All_Infected_HUD_HP.smx` | 所有特感血量 HUD 实时显示 |
| `advertisements.smx` | 定时轮播服务器公告（120s 间隔，9 条中文消息） |
| `auto_motd.smx` | 自动显示 MOTD 欢迎信息 |
| `l4d2_broadcast.smx` | 广播玩家死亡/受伤/受击事件 |
| `l4d2_player_status.smx` | 显示玩家状态变化（倒地/挂边/被控等） |
| `l4d2_skill_detect.smx` | 技能检测——skeet/charger punch/instaclear 等操作提示 |
| `l4d2_tank_announce.smx` | Tank/Witch 出现通告 + 血量显示 |
| `l4d2_tank_ranking.smx` | Tank 伤害排名显示 |
| `l4d2_witch_ranking.smx` | Witch 伤害排名显示 |
| `l4d_explosion_announcer.smx` | 爆炸物引爆通告（油桶/煤气罐/氧气瓶等） |
| `l4d_throwable_announcer.smx` | 投掷物使用通告（火瓶/胆汁/土制） |
| `kill_cmd.smx` | 玩家 /kill 自杀命令 |
| `kills.smx` | 击杀统计显示 |

## 🔫 武器/弹药调整

| 插件 | 说明 |
|------|------|
| `l4d2_ammo_set.smx` | 弹药携带量自定义设置（SMG 720/AR 540/霰弹 192/猎枪 225 等） |
| `l4d2_m60_ammo.smx` | M60 弹药量设置（450 发） |
| `l4d2_shotgun_speed.smx` | 霰弹枪射速/换弹速度调整 |
| `l4d2_weapon_attributes.smx` | 武器属性修改（伤害/射速/射程等，配合 sourcemod.cfg） |
| `WeaponHandling.smx` | 武器操作速度调整（拔枪动画/双枪射速等） |

## ⚙️ 游戏性调整

| 插件 | 说明 |
|------|------|
| `l4d2_auto_respawn.smx` | 自动复活（45 秒） |
| `l4d2_ff_fix.smx` | 友伤调整——友伤倍率 0.30（降低70%），火伤 1.0 |
| `l4d2_shove_fatigue_scaler.smx` | 推挠疲劳度缩放控制 |
| `l4d2_medical_supply_scaler.smx` | 医疗补给数量按人数缩放（包/药/针） |
| `l4d2_tank_hp_scaler.smx` | Tank 血量按人数缩放——每人 3000 HP，最低 12,000 |
| `l4dmultislots.smx` | 多人生存者——最多 10 人，最少 4 人，免大厅等待 |
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
| `l4d2_maptankfix.smx` | 地图 Tank 相关 bug 修复 |
| `block_bot_kick.smx` | 阻止玩家投票踢出 BOT |
| `fix_botkick.smx` | 修复 BOT 被游戏引擎意外移除的问题（非投票场景） |
| `l4d2_GetWitchNumber.smx` | 正确获取 Witch 数量的函数修复 |
| `l4d2_pause_game.smx` | 游戏暂停功能 |

## 🔧 服务器管理

| 插件 | 说明 |
|------|------|
| `l4d2_sethostname.smx` | 从 data/hostname.txt 读取并设置服务器名 |
| `l4d_unreservelobby.smx` | 解除大厅预留——10 人满后关闭 lobby 连接，heartbeat 30s |
| `l4d_CreateSurvivorBot.smx` | 动态创建/管理幸存者 BOT |
| `l4d2_tickrate_enabler.smx` | 60-tick 网络 cvar 自动配置 |

## ⚠️ 注意事项

- **副本服务器差异**：参考服务器不使用 `l4d2_tickrate_enabler.smx`（改用 `-tickrate 60` 启动参数），这是两项 60-tick 方案之间的唯一差异。
- **已删除的插件**：`mapchooser.smx`、`nominations.smx`、`rockthevote.smx`、`randomcycle.smx` 已永久删除（mapchooser 无法创建有效地图列表）。
- **关键配置**：武器属性、团灭换图阈值（4 次）、弹药量等在 `cfg/sourcemod/sourcemod.cfg` 中统一定义。
- **Tank HP**：`l4d2_tank_hp_scaler.smx` → 存活人数（含 BOT）× 3000，最低 12,000 HP。
