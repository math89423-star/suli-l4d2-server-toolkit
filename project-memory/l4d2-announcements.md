---
name: l4d2-announcements
description: L4D2 服务器游戏公告系统 — advertisements.txt / motd.txt 路径、生效方式、当前全部数值对照（2026-08-03 已同步）
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - server
    - announcements
    - advertisements
    - y-key
  originSessionId: 44cc02ce-0db4-43de-8821-a543aa3c31a2
  modified: 2026-08-04T17:10:44.429Z
---

# L4D2 游戏公告系统

玩家看到公告的三个途径：Y 键聊天区滚动广告（Advertisements 插件周期轮播）、`!motd` 面板（H 键）、入服欢迎消息。

## 三个组件

| 组件 | 文件 | 触发方式 | 更新生效 |
|------|------|----------|----------|
| 周期广告 | `addons/sourcemod/configs/advertisements.txt`（**4 条精华版**，2026-08-03 精简） | 每 120 秒聊天区轮播 | 下一轮自动生效 |
| MOTD 面板 | `data/motd.txt` | `!motd` / H 键 | 玩家下次打开自动读到新内容 |
| 入服欢迎 | Welcome Message on Connect 插件 (**1.2**) | 玩家进服后 6s | 源码 `scripting/auto_motd.sp`，改后需重编译 + `sm plugins reload auto_motd` |

## 生效路径（2026-08-03 实测）

- **motd.txt 唯一生效份 = 主机 `/opt/gameservers/l4d2/data/motd.txt`**（bind mount → 容器 `/home/louis/l4d2/left4dead2/motd.txt`，md5 一致实测）。`data/l4d2-server/left4dead2/motd.txt` 是**空文件残留**（旧部署副本），改它无效。
- advertisements.txt 直接改 `configs/` 下文件，无需 reload。
- 都是纯文本，改数值后**不会自动同步**——改了任何插件 cvar 必须手动同步这两个文件（历史教训：复活 35s/掉落 6%+3%+1% 都是过时残留）。

## 当前广告内容 vs 实际配置（2026-08-03 全量核对）

| 公告项 | 广告值 | 实际配置（来源） |
|--------|--------|------------------|
| 特感波次 | **20-35s 分批进场**（2026-08-05 v2.0.0 同步） | `si_comp_mode_interval_min/max` 20/35（钉值区间）；冷静期 12-18s 缓冲 + 批次 4 只/批（见 [[l4d2-specialspawner-config]]） |
| 特感公式 | **基础8特，1人2特，上限22特**（2026-08-05 同步） | `ss_base_limit 8` / `ss_extra_limit 2.0`（4人基准 2×4）+ 类别上限 3/4/4/4/4/3 合计 22 先绑（大房封 22）；ss_si_limit 32 永不触发 |
| 标签 | 快乐 · 8特（2026-08-05 同步） | hostname "粟藜24人快乐多特战役服[8特]"（原 纯净/6特）；motd 标题 [困难\|8特] |
| Tank 血量 | 人数x3000 | `sm_tank_hp_per_survivor 3000` |
| 自动复活 | **20 秒** | `si_hud_respawn_delay 20`（v1.9.4 定稿；l4d2_auto_respawn 已卸载，复活并入 si_hud） |
| 团灭换图 | 4次 | `sm_l4d_fmc_crec_coop_map 4` / `final 4` |
| 友伤 | 专家15/困难8/普通4/简单2% | `survivor_friendly_fire_factor_*` 0.15/0.08/0.04/0.02 |
| 推搡疲劳 | /2 | `l4d2_shove_fatigue_scaler.sp`（独立插件 Shove Fatigue Scaler 2.0，penalty/2，非 weapon_attributes） |
| 掉落 | Tank必掉3件/Witch必掉1件/特感约4%/小僵尸1% | `l4d2_loot_drop.cfg` v1.8.0: common 1.0 / si 池 2.0+1.0+1.0（弹药包2%+药肾上1%+燃烧瓶1%） |
| 电锯燃料 | x3 | `l4d2_chainsaw_fuel 90` |
| M60 | 150发弹夹+600备弹 | `sm_m60_clip 150` + `sm_m60_ammo_max 600` |
| 备弹 | 1.5x | ammo_*_max 540/270/192/225/270/720/30 |
| 60tick | ✓ | tickrate enabler + `nb_update_frequency 0.033`（注意：memory 旧值 0.066 已过时） |
| 击杀回血 2% | 广告未提 | ⚠️ `l4d2_common_kill_reward_enable 0` **已关闭**（原 l4d2_si_kill_heal 改名） |

## 2026-08-03 同步操作

- 复活 35s → **20s**（两文件）
- 掉落：特感 6%+3%+1% → **约4%**、小僵尸 2% → **1%**（两文件，用户拍板笼统描述）
- motd 删除 `!ptg` 指令（PTG 已禁用，见 [[l4d2-ptg-disabled]]）
- 用户拍板：广告只修正过时内容，不新增特性（复活币/商店未入广告）
- **Y 键滚动广告精简为 4 条精华版**（用户拍板，减少与 H 键冗余）：IP / QQ群+Steam组 / 规则+!motd引导 / 趣味(高光+MVP，H 键独有)。特性/指令/掉落详情统一指向 `!motd`（H 键）。删除原 6 条特性重复条目。
- **入服欢迎消息（第三处同步点）**：auto_motd v1.1→**1.2**，群号 1051172300 → **873133645** + 掉落同步（特感约4%/小僵尸1%），已重编译部署重载（commit 96eeeb3）。教训：改群号/数值要查全 **三处**（advertisements.txt / motd.txt / auto_motd.sp），不要只同步前两处。

## 2026-08-05 描述同步（纯净→快乐 / 6特→8特 / 波次 40-55 / 上限22）

hostname 改"快乐[8特]"后，同步全部公告描述（h 键 motd + Y 键广告）：
- motd.txt（`data/motd.txt` 唯一生效份）4 处：标题 `纯净...6特`→`快乐...8特`；
  特感行 `基础6特，人数×1.5，上限28特`→`基础8特，1人2特，上限22特`；
  波次 `45-60`→`40-55`（**v2.0.0 再改 `20-35 秒分批进场`**）；规则 `纯净战役`→`快乐战役`
- advertisements.txt 2 处 `[粟藜24人困难|6特]`→`[困难|8特]`（Y 键轮播）
- **⚠️ 2026-08-05 新教训：hostname 有第四处源**——`addons/sourcemod/data/hostname.txt`
  （l4d2_sethostname 插件在换图/启动时读它覆盖 server.cfg 的 hostname，曾把
  "快乐[8特]"覆盖回"纯净[6特]"）。改 hostname 必须同步 **server.cfg + hostname.txt
  + motd + advertisements** 四处，改完 RCON `sm_hostname_reload` 即时生效。

## 历史残留注意

- memory 旧值全部过时：波次 40-60（现在 45-60）、友伤 0.11（现在 0.08）、团灭 6（现在 4）、复活 40s（现在 20s）、掉落 1.25/24（现在 1.5/28）、tick nb_update 0.066（现在 0.033）。

## 关联记忆

- [[l4d2-server-quick-reference]] — 服务器管理速查
- [[l4d2-si-health]] — 特感血量配置
- [[l4d2-loot-drop-v180]] — 击杀掉落表
- [[l4d2-ptg-disabled]] — PTG 已弃用（motd !ptg 删除原因）
