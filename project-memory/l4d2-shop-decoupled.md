---
name: l4d2-shop-decoupled
description: 商店已解耦为 l4d2_shop v1.0.0 独立插件；si_hud v1.9.0 导出 SH_ API；部署状态与验证清单
metadata: 
  node_type: memory
  type: project
  originSessionId: 0f1dc315-4afb-4a7e-bc39-dce84be10ed3
  modified: 2026-08-15T10:21:27.107Z
---

# 商店解耦（2026-08-03 ✅ 已部署验证）

si_hud v1.8.2 → **v1.9.0**（计分/钱包/复活/排行榜/HUD）+ **l4d2_shop v1.0.0**（新插件，!shop/!buy）。commit 789a7b6，**2026-08-03 10:46 整服重启部署完成**（用户批准"直接重启"）：日志确认双插件加载（si_hud 无 shop-laser 报错=死代码已删；shop 无 "API 不可用"=绑定成功），l4d2_shop.cfg 自动生成 12 art cvar，nb_update_frequency 0.033 已注入，无 native 错误。旧 v1.8.2 smx 备份 /tmp/l4d2_si_hud.smx.bak.v1.8.2。**功能测试待玩家实测**（全商品/火炮退款路径/降级）。

## 架构

- **si_hud 拥有**：g_iWallet 所有权与持久化（data/si_hud_scores.txt）、计分入账 6 处、复活系统、排行榜。导出 2 个 natives（RegPluginLibrary "l4d2_si_hud_api"）：SH_GetWallet / SH_AddWallet（Add 钳制 >=0 并返回新余额）。**v1.12.0（2026-08-04）：复活币 4 个 natives（Get/AddReviveCoins/GetCoinMax/ReviveClient）已移除**——复活体系改为积分复活，见 [[l4d2-revive-system-v1120]]；[[l4d2-revive-coin-purchase-fix]] 机制随之废除。
- **l4d2_shop 拥有**：g_ShopTable 17 槽（价格编译期）、菜单（VguiMenu 单行标题）、ShopBuy、ShopSpawn/SpawnMelee、透视特感、火炮支援 I/II、g_iShopBought、si_hud_shop_enable + si_hud_art_* 共 13 cvar（+SetBounds 防残留坑）。自家独立 Witch 列表（不共享 Handle）。
- **绑定模式**：SM 1.12 懒绑定——l4d2_shop 直接 `native` 声明（left4dhooks 消费方同款），**不用** GetNativeHandle/CallNativeHandle（SM 1.12 已移除该 API）。可用性守卫：FindPluginByFile("l4d2_si_hud.smx") + 版本非 1.8 前缀（`StrContains(ver,"1.8")!=0`）。所有调用经守卫入口（Cmd_Shop/ShopBuy/ArtEndDesignate 退款），避免裸调缺失 native 刷错误日志。
- 聊天余额一律用 SH_AddWallet 返回值（最易漏的移植点）。断线顺序：商店插件字母序在前 → OnClientDisconnect 退款先于 si_hud 存档，重连不丢钱。
- 删除死代码：gamedata SetHasLaserSight SDKCall（L4D2 无此符号）+ sm_laser_test + gamedata/l4d2_si_hud.txt + 废弃 l4d2_shop_artillery2.sp。

## 部署步骤（空服 + 批准后）

1. `cp compiled/l4d2_shop.smx compiled/l4d2_si_hud.smx ../plugins/`（不再手工 .bak——e522a96 起版本由 git 管理）
2. 优先整服重启（清引擎残留 cvar）；或 rcon：`sm plugins reload l4d2_si_hud` → `sm plugins load l4d2_shop`（si_hud OnPluginEnd 存档，钱包不丢）
3. 验证 l4d2_shop.cfg 自动生成含 13 cvar；l4d2_si_hud.cfg 已手工移除商店段
4. 功能测试：全商品购买/复活币上限扣款前拒绝/透视续费 15min 上限/火炮退款路径（含瞄准中断线重连钱包含退款）/换图限购清零/新战役清零/`sm plugins unload l4d2_si_hud` 后 !shop 提示不可用 + 恢复后自动可用（懒绑定无需重载商店）

## 关联

- 契约文档：scripting/include/l4d2_si_hud.inc
- 完整测试清单：/root/.claude/plans/crispy-roaming-rainbow.md §5.3
- Related: [[l4d2-si-hud-scoring]] [[l4d2-source-code-location-pitfall]]

## ⚠️ si_hud 未部署坑（2026-08-04 修复）

**现象**：00:00 整服重启后 si_hud 未加载 → l4d2_shop `<Failed>` "Native SH_GetWallet was not found"，商店/计分/复活币/连杀全挂。
**根因**：23:14 编译 l4d2_si_hud.smx 时输出到了 **scripting/ 根目录**（而非 compiled/），没人拷到 plugins/ → 重启不加载。编译产物放错目录 = 部署静默丢失（与 [[l4d2-source-code-location-pitfall]] 是同一类"两套位置"坑）。
**修复（00:29，玩家在线低风险）**：`cp scripting/l4d2_si_hud.smx plugins/` → `sm plugins load l4d2_si_hud` → `sm plugins reload l4d2_shop`。验证：plugins list #77 "SI HUD" (1.9.6) loaded + #72 "Score Shop" (1.6.4) loaded 无 Failed；errors_20260804.log 无新错误（唯一旧错误是 flow_path_test 的 TE_Send Client 0）。**铁律：编译输出必须 -o compiled/ 或直接 cp 到 plugins/，smx 放 scripting/ 根目录不会加载。**

## 弹药补充商品（v1.7.3，2026-08-05 ✅ 热重载部署）

**「弹药补充」ammo_refill 800 分/无限购/补给品分类**（价格 800 默认，用户可调）——特殊商品不 spawn 实体，ShopBuy 分支直补：主武器(slot 0)+副武器(slot 1)的 `m_iClip1`(弹匣) + `m_iExtraPrimaryAmmo`(后备)。上限表 `Ammo_ClipMax`/`Ammo_ReserveMax`（官方默认 + 服务器配置覆盖）：弹匣 步枪50/AK47 40/SCAR 60/M60 254(=sm_m60_clip)/SMG 50/狙击 15-30/霰弹 8-10/电锯 90 燃料/GL 1；后备 步枪360/SMG 650/狙击 180/霰弹 72/手枪·马格南 100/GL 30/M60 150。未知武器跳过，无武器退款。SHOP_SLOTS 23→24 表尾追加（不动 WALLHACK_SLOT 11）。
⚠️ **部署踩坑**：spcomp64 不带 -o 输出到 scripting/ 根目录，plugins/ 旧 smx 未覆盖 → 首 reload 加载 v1.7.2；且 SM 1.12 smx 字符串池加密 strings 搜不到，只能按时间戳/md5 判断（详见 [[l4d2-source-code-location-pitfall]]）。

## 弹药补充动态定价 + 菜单实时刷新（v1.8.21/v1.8.22，2026-08-15 ✅ 热重载部署）

**v1.8.21 动态定价**：弹药补充按主武器枪种定价（`AmmoRefill_GetPrice` 覆盖表定价）——SMG 3500 / AR 5000（含 M60）/ 单喷 5500 / 连喷 6500 / 连狙(military) 7000 / 栓狙(hunting/scout/awp) 8500；无/未知武器回退 4500。菜单显示 `弹药补充[SMG] (3500分)`。M60/榴弹持有时不可补弹（扣款前拦截 + 菜单标 `[该武器不可补弹]`）。cat 从补给品(2)移到其他(3)，cat=3 菜单跳过价格排序（保持表顺序：透视+弹药固定）。

**v1.8.22 菜单实时刷新**（解决用户提的两个边界条件）：①打开商店后换武器→弹药价过期（显示 SMG 3500 实扣 AR 5000）②打开后获得积分→标题余额冻结在开启那刻。方案=**0.5s 心跳计时器 `Timer_ShopRefresh`** + **内容签名门控**（钱包 `g_iShopSigWallet` + 弹药动态价 `g_iShopSigAmmo`，只在真变化时重绘避免闪烁）。L4D2 数字键选择式菜单重绘无缝。状态：`g_hShopRefreshTimer`/`g_iShopView`(0无/1分类页/2商品页)。
⚠️ **双重释放坑**：`Timer_ShopRefresh` 会调 `OpenShopMenu`/`ShopCategoryMenu` 重绘，这俩函数**绝不能 KillTimer 自身句柄**（TIMER_REPEAT 回调内杀自己=崩溃）→ ensure 模式：只在 `== null` 时 CreateTimer。清理点：菜单 Cancel/End（`g_hShopMenu==menu` 守卫）+ OnClientDisconnect + （OnMapEnd 换图自然停）。
部署：18:19 RCON `sm plugins reload l4d2_shop` 成功（日志 `[shop] loaded v1.8.22`），18:20 换图再确认。测试计划 /opt/gameservers/l4d2/shop_refresh_test.md。⚠️ 有玩家在线，用户明确授权后才热更。

## 测试发分命令 sm_shop_give（v1.6.0，2026-08-03）

`sm_shop_give <名字> <积分>`（ADMFLAG_ROOT）→ `SH_AddWallet` 直写钱包。**⚠️ 中文名坑：SRCDS 控制台把中文名按字节拆成多个 arg**（粟藜 → 多段，GetCmdArg(2) 取到名字碎片）→ 必须整串 `GetCmdArgString` 解析：末段=积分，其余段去空格拼回名字。以后所有带中文参数的控制台命令都要注意。

## v1.8.23-25 商店收尾（2026-08-15 夜，git 已提交 0609310/d8cc52d，已 reload）

- **v1.8.23**：购买任意物品后自动关闭商店（不再重开同分类）；打开后无操作 **6 秒自动关闭**（g_hShopIdleTimer）
- **v1.8.24**：AGM 导弹爆炸后暂停特感+小僵尸刷新 20s（si_hud_art6_pause_spawn）——新增 **SS_PauseSpawning / MC_PauseCommon 两个可选绑定 native**（specialspawner + l4d2_max_common 各新增导出；AskPluginLoad2 MarkNativeAsOptional，未加载静默跳过）。连带 specialspawner 冷静期 20-30→25-35s、清缴阈值 40%→30%
- **v1.8.25**：AGM 爆炸音效前摇对齐 + **SH_ShowMissileBanner 导弹聚合击杀横幅**（si_hud v1.13.3 新增纯显示 native）
- ⚠ `l4d2_shop_version` cvar 是残留值（1.8.22）不代表实际版本——CreateConVar 不覆盖已存在 cvar 的当前值，以 `sm plugins info l4d2_shop` 的 Version 为准
- AGM 全史/参数/坑 → [[l4d2-agm-missile]]；价格表 → [[l4d2-shop-default-prices]]
