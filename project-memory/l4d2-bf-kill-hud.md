---
name: l4d2-bf-kill-hud
description: 战地击杀反馈 HUD（si_hud v1.7.29）— 双轨积分（本关榜/战役钱包）+ !shop 商店（11 商品含复活币）+ 复活次数系统（每图 2 次/15s）+ 掉落表（loot_drop v1.7.0）
metadata:
  node_type: memory
  type: project
  originSessionId: c491550d-af6d-47f3-9199-7c36c747789b
  modified: 2026-08-02T08:48:57.636Z
---

# L4D2 战地击杀反馈 HUD（si_hud v1.7.31 + loot_drop v1.7.0，2026-08-01 20:3x 部署）

> 状态：**v1.7.79 running**（2026-08-02：商店分类菜单 + 原生 8=返回/9=退出 + 新商品透视特感 6000 / 近战盲盒 3000 / 烟花 2500 / 油桶 5000 / 激光 3500，详见 [[l4d2-wallhack-clone]]；commit ebc209c）。
> bf_killfeedback **v4.4.3**（同一排障链同改）。
> source: scripting/l4d2_si_hud.sp + scripting/l4d2_loot_drop.sp（均已在 git）
> + cfg/sourcemod/l4d2_si_hud.cfg + l4d2_loot_drop.cfg
> （**cfg 必须手动追加**，AutoExecConfig 从不覆盖；改 cfg 后需 reload/换图生效）

## 积分体系（v1.7.27–28 用户定稿，BF 同款三轨）

| 变量 | 语义 | 清零时机 |
|---|---|---|
| `g_iTotalScore` | **本关积分**（排行榜显示） | 每关从 0 算（OnMapEnd）；断线 |
| `g_iWallet` | **可用积分**（商店消费） | 战役内跨图保留；**新战役**（地图前缀变化，OnMapStart 判定）；断线 |
| `g_iReviveCoins` | **复活币**（商店 12000，上限 5） | 同战役级；断线 |

- 得分事件（伤害分/击杀分）同时进本关 + 钱包
- 战役判定：GetMapPrefix（"_" 前的部分，官图 c1–c14 / 三方图通用）；前缀变化 → 清钱包+复活币 + PrintToChatAll 播报
- 播报（排行榜 45s/结算）：追加"可用积分 X  复活币 X 枚  复活 X 次"
- 断线清零（防 client 槽位泄漏）；服务器重启清零（内存，无持久化）
- **v1.7.30 每图存档**：OnMapStart 拍本关积分快照（分/特/死/友伤/被黑）；
  团灭重开（round_start 且无 OnMapStart = 同图 restart，用 g_bFreshMapStart
  标志区分）→ RestoreScoreState 回滚到开局快照 + 复活次数回初始 + 杀旧计时器。
  钱包/复活币战役级不受团灭影响
- **v1.7.31 新玩家默认**：OnClientPutInServer 全默认状态 = 0 可用积分 +
  si_hud_respawn_coin_start(2) 复活币 + base 复活次数（显式初始化全部槽位）

## v1.7.28 复活次数系统（替代 l4d2_auto_respawn，已卸载）

- 每图初始 `si_hud_respawn_base 2` 次自动复活（=3 条命），`si_hud_respawn_delay 15s`
- 死亡判定（Branch C）：次数>0 → 扣次复活；=0 且复活币>0 → 自动耗币（播报剩余）；
  都没有 → 躺尸等电击器/过关 → **电击器回归价值**
- 移植 auto_respawn：倒计时提示（10/5/3/2/1s）+ L4D_RespawnPlayer + 0.5s 传送队友
- 复活币：商店 12000 无限购（classname 空 = 不 spawn，余额+1）；**持有上限 5**
  （si_hud_respawn_coin_max，购买前检查 + 进服/新图 clamp）
- include <left4dhooks>（L4D_RespawnPlayer）；每图 OnMapStart 重置次数+clamp

## v1.7.27 商店（!shop / !buy，原生 Menu）

价格/限购**编译期写死**在 `g_ShopTable`（改价重编译）；只留 `si_hud_shop_enable` 开关

| 商品 | classname | 价格 | 限购/图 |
|---|---|---|---|
| 瓦斯罐 | weapon_propanetank | 800 | 2 |
| 煤气罐 | weapon_oxygentank | 800 | 2 |
| 汽油桶 | weapon_gascan | 2000 | 2 |
| 止痛药 | weapon_pain_pills | 2000 | 2 |
| 肾上腺素 | weapon_adrenaline | 2000 | 2 |
| 电击器 | weapon_defibrillator | **4000**（v1.7.28 涨） | 2 |
| 医疗包 | weapon_first_aid_kit | **4000**（v1.7.28 涨） | 2 |
| 激光瞄准 | weapon_upgradepack_laser_sight | 3500 | 1 |
| M60 | weapon_rifle_m60 | 5000 | 1 |
| 榴弹发射器 | weapon_grenade_launcher | 8000 | 1 |
| 复活币 | （空，特殊处理） | 12000 | 0=无限（上限 5） |

- 物品 trace 落面前 70 单位 + glow；重武器带备用弹药（GL 30 / M60 150）
- **M60/榴弹模型 OnMapStart precache**（非战役图缺模型会隐形）
- 菜单标题：可用积分 + 本关分 + 复活币枚数；limit 0 显示 [无限购]

## loot_drop v1.7.0 掉落表（用户定稿）

| 来源 | 掉落 | 概率 |
|---|---|---|
| 小僵尸 | 胆汁/土制炸弹 50/50 | 总 1% (sm_loot_common_chance) |
| 特感 | 肾上腺素/药丸 各 1%，燃烧瓶 2%，高爆/燃烧弹药包 各 1.5% | 5 独立 roll 合计 7% |
| Tank | 医疗包 + M60/榴弹 2选1 + 3 投掷物（各 1） | 必掉 |
| Witch | 医疗包/电击器/燃烧瓶/高爆弹药包 4选1 | 必掉 |

- 概率全 cvar；**重型武器双来源**：Tank 必掉 + 商店限购
- 坑：reload 时 AutoExecConfig 会执行 cfg → 旧 cfg 残留旧 cvar 值覆盖新默认；
  引擎对未知 cvar 名 exec 时自动创建（废弃 cvar 残留无害，重启消失）
- v1.6.0 曾误删武器掉落（"什么都掉不合理"误读）→ v1.7.0 按用户表恢复 Tank 必掉

## 得分体系（v1.7.16–26，全部 cvar）

- 伤害分：dmg × 枪种倍率 × coeff 0.1（小僵尸 coeff_common 0.1）；击杀分固定不乘
- 枪种倍率：AR 1.0 / SMG 1.5 / 马格南+近战 1.75 / pump 1.5 / auto+sniper 0.75
- 击杀分：Smoker/Boomer 75、Hunter/Jockey 100、Spitter 125、Charger 150、
  Tank/Witch 500、小僵尸 5（爆头+5）、爆头/近战/满血 bonus +50、streak bonus 30/50/100
- 三类目标三条路径：SI/Tank=player_hurt、小僵尸=infected_hurt+infected_death
  （**infected_death 无 entityid** → g_iLastCommonEnt 回退）、Witch=SDKHooks
- per-killer 网格 g_iDmgPtsKiller[killer][2048]
- 连杀窗口 6s；结算 center + 聊天双通道
- **聊天安全字符**：只有 \x01-\x05（\x07RRGGBB 渲染成字面文本）；Verdana 无
  ═/☠/×（× 用 ASCII x）；center/HUD 字体有 ☠/†/★；hint 通道死路（priming bug）

## 部署备忘

```bash
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting
./spcomp64 l4d2_si_hud.sp -o compiled/l4d2_si_hud.smx
cp compiled/*.smx ../plugins/
bash /home/ubuntu/rcon_cmd.sh "sm plugins reload l4d2_si_hud"
# cfg 手动追加新 cvar；改 cfg 后 reload 对应插件才生效
# 玩家在线时禁止重启/操作（[[l4d2-dont-touch-server]]）；reload 插件 OK
# 源码权威：/opt/gameservers/l4d2/data/addons/sourcemod/scripting/（容器挂载，编译源）
# （旧"正版副本" /home/ubuntu/l4d2-server-pack 是标准 SM 部署包，从不含自定义插件源码，2026-08-02 已删）
```

## 激光购买 — ✅ 已验证生效（2026-08-02 玩家实测）

排障链定论（前三个方案全失败，第四个成功）：
1. ~~SetEntProp `m_bHasLaserSight`~~ — L4D2 无此 prop
2. ~~`upgrade_laser_sight` 脚下 spawn~~ — 用户实测否决（激光堆拾取物）
3. ~~SDKCall `SetHasLaserSight`（@_ZN17CBaseCombatWeapon16SetHasLaserSightEb）~~ — **CS:GO 符号，L4D2 引擎不存在** → EndPrepSDKCall null 实锤
4. ✅ **`m_upgradeBitVec`**（netprops dump 实锤：所有武器类，offset 6116, networked 32-bit）位值 1=燃烧弹 2=高爆弹 4=激光（weapon_upgrade_id_t）——v1.7.49 购买分支读现值 `| 4` 写回，**玩家实测直接挂主武器，无拾取物，激光生效**

备份 `plugins/l4d2_si_hud.smx.bak.v1.7.48`；日志 `[shop-laser] m_upgradeBitVec %d -> %d` 可查读回值。
- [ ] 复活系统实测（15s 节奏、复活币消耗链路、电击器价值回归）
- [ ] 平衡观察：8000 榴弹获取节奏、复活币 12000 攒钱周期
- [ ] 移除调试日志：v1.7.43b 的 `[shop-buy]` LogMessage + `[laser-test]` 命令
      （确认激光修复后清理）

## 音效响度排障链（2026-08-02 实测闭环，用户认可）

**现象**：连杀结算音 + 特感击杀音偏小，想调大。
**结论**：播放路径唯一有效的变量是**空间化**；BF1 素材本身均值 -14dB 偏轻是次要因素。

| 尝试 | 结果 |
|---|---|
| volume 0.8/1.0 → 1.2/1.5（上限 2.0） | **反而更小** —— 引擎对 EmitSoundToClient volume>1.0 处理异常（用户实测实锤） |
| 文件重母带（+6dB + alimiter） | 无效 —— 源文件峰值已 0dB，limiter 压回增益（均值仅 +2-3dB） |
| loudnorm 单遍 / acompressor+makeup | 无效/更差 —— 短促音效测量窗口问题 |
| SNDCHAN_STATIC → SNDCHAN_AUTO | 无变化 —— 通道不是衰减源 |
| **SOUND_FROM_PLAYER（非空间化）→ entity=client（空间化）** | **有效**（"似乎好一点"）—— 非空间化 UI 声音有固定衰减；空间化听者=源、距离 0、衰减≈1.0（游戏内响亮音效如倒地音都是空间化的） |

**定稿**：EmitSoundToClient(client, sound, **client**, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, vol)，vol 必须 ≤1.0。
**素材**：bf_award_*（6 个）均值 -14.3~-14.9dB、击杀音效 -11~-18dB、峰值全 0dB。用户接受现状（"也可能就是本身 bf 的音效小"）。

## 关联

- [[l4d2-bf-killfeedback]] — 击杀音效（v4.4.0）
- [[l4d2-bf-score-system-plan]] — 计分玩法计划（Step2 被商店/复活设计取代）
- [[l4d2-printhinttext-priming-bug]] / [[l4d2-sound-cache-pitfall]]
- [[l4d2-source-code-location-pitfall]] — 源码副本同步规则
