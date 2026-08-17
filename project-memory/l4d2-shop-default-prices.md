---
name: l4d2-shop-default-prices
description: 商店 24 槽最终定稿价格清单（v1.4.9，2026-08-03；分类 0武器/1道具/2补给品/3其他/4火力支援/5投掷品；投掷×1.5 补给×1.25 火力已涨价）
metadata:
  node_type: memory
  type: project
  originSessionId: 0f1dc315-4afb-4a7e-bc39-dce84be10ed3
  modified: 2026-08-15T10:02:00.120Z
---

# 商店价格定稿（l4d2_shop v1.8.25 商品表，编译期定死）

> 价格在 `scripting/l4d2_shop.sp` 的 `g_ShopTable[SHOP_SLOTS]`（25 槽 0-24），改价格必须重编译 + reload 插件。
> ⚠ **必须与 SHOP_SLOTS 严格一致**：少了 spcomp 静默截断末行（末尾商品消失），多了末槽零初始化（菜单 0 分幽灵商品）。
> **v1.7.1（2026-08-05）：SHOP_SLOTS 24→23**——v1.7.0 删复活币后表内只剩 23 行，末槽零初始化导致武器类菜单出现 0 分幽灵商品；WALLHACK_SLOT 12→11（透视特感随复活币删除滑到 11）。已编译部署 plugins/（待 reload）。
> **v1.8.0（2026-08-15）：SHOP_SLOTS 23→25**（+AGM 导弹；表尾追加）。**v1.8.5：火力支援全档涨价+范围收紧（见 [[l4d2-artillery-strike]]）**。**v1.8.6：电锯降价 5000→3500、透视涨价 4000→5000、弹药补充 800→4500 并移入其他类（cat 2→3）**。

| 槽位 | 商品 | classname | 价格 | cat |
|---|---|---|---|---|
| 0 | 瓦斯罐 | weapon_propanetank | 100 | 1 |
| 1 | 煤气罐 | weapon_oxygentank | 100 | 1 |
| 2 | 汽油桶 | weapon_gascan | 3500 | 1 |
| 3 | 止痛药 | weapon_pain_pills | 1250 | 2 |
| 4 | 肾上腺素 | weapon_adrenaline | 1250 | 2 |
| 5 | 电击器 | weapon_defibrillator | 4375 | 2 |
| 6 | 医疗包 | weapon_first_aid_kit | 3750 | 2 |
| 7 | 激光瞄准 | weapon_upgradepack_laser_sight | 1500 | 0 |
| 8 | M60 轻机枪 | weapon_rifle_m60 | 5000 | 0 |
| 9 | 电锯 | weapon_chainsaw | 3500 | 0 |  // v1.8.6: 降价 5000→3500
| 10 | 榴弹发射器 | weapon_grenade_launcher | 6500 | 0 |
| 11 | 透视特感 | wallhack | 5000 | 3 |  // v1.8.6: 涨价 4000→5000
| 12 | 近战盲盒 | melee_box | 1000 | 0 |
| 13 | 烟花 | weapon_fireworkcrate | 1200 | 1 |
| 14 | 火力支援II-地狱烈火 | artillery2 | 10000 | 4 |  // v1.8.5: 涨价 8500→10000
| 15 | 火力支援I-绿色雨幕 | artillery3 | 6500 | 4 |  // v1.8.5: 涨价 4500→6500
| 16 | 火力支援III-区域轰炸 | artillery5 | 14500 | 4 |  // v1.8.5: 涨价 10000→14500（改全榴弹）
| 17 | 火力支援IV-AGM导弹 | artillery6 | 18000 | 4 |  // v1.8.0 新增（15000）→ v1.8.4 定稿 18000
| 18 | 马格南 | weapon_pistol_magnum | 2000 | 0 |
| 19 | 燃烧弹包 | weapon_upgradepack_incendiary | 625 | 2 |
| 20 | 高爆弹包 | weapon_upgradepack_explosive | 625 | 2 |
| 21 | 胆汁 | weapon_vomitjar | 1275 | 5 |
| 22 | 土质炸弹 | weapon_pipe_bomb | 1350 | 5 |
| 23 | 燃烧瓶 | weapon_molotov | 3750 | 5 |
| 24 | 弹药补充 | ammo_refill | 4500 | 3 |  // v1.8.6: 移入其他类 + 涨价 800→4500；实际扣款走动态定价（见下）

- 火力支援显示顺序按菜单价格升序（v1.8.1）：I-绿色雨幕 6500 < II-地狱烈火 10000 < III-区域轰炸 14500 < IV-AGM 18000；火力支援机制/参数/坑见 [[l4d2-artillery-strike]] 和 [[l4d2-agm-missile]]
- 原「火力支援I-炮击」artillery（4500）与「火力支援IV-榴弹雨」artillery4（TEST 1 分）已禁用删行（v1.4.0），kind 1/4 代码路径保留
- 复活币商品已删（v1.7.0 积分复活体系，见 [[l4d2-revive-system-v1120]]）
- 全商品不限购（limit 0）；AGM 额外受 si_hud_art6_max_per_map 全服限购（⚠ 默认 0=不限，注释写 1 次/图——矛盾未决）

## v1.8.21 弹药补充动态定价（2026-08-15，已 reload 生效）

**用户拍板**：弹药补充不再固定价，按**当前主武器（slot 0）枪种**动态计价（SMG 耗弹快威力小应便宜，狙/喷弹药珍贵应贵）。表定价 4500 仅作回退。

| 枪种 | 价格 | classname |
|---|---|---|
| SMG | 3500 | smg / smg_silenced / smg_mp5 |
| AR（含 M60） | 5000 | rifle / rifle_sg552 / rifle_ak47 / rifle_desert / rifle_m60 |
| 单喷 | 5500 | pumpshotgun / shotgun_chrome |
| 连喷 | 6500 | autoshotgun / shotgun_spas |
| 连狙 | 7000 | sniper_military |
| 栓狙 | 8500 | hunting_rifle / sniper_scout / sniper_awp |
| 榴弹/电锯/无主武器 | 4500（回退） | grenade_launcher / chainsaw |

- 实现：`AmmoRefill_GetPrice(client, weaponTag, len)` 返回价格+枪种标签；`ShopBuy` 在钱包校验前覆盖 price（扣款/校验全用动态价）；菜单渲染 `ShopCategoryMenu` 特判 ammo_refill 显示"弹药补充[SMG] (3500分)"；购买成功聊天含枪种标签
- M60 归 AR 5000（用步枪弹 assaultammo + 254 弹匣已够强，未单列）
- 商品表 g_ShopTable 里 ammo_refill 那行的 price 4500 保留（无主武器/未知武器回退用）

相关：[[l4d2-shop-decoupled]]（商店架构与部署）[[l4d2-artillery-strike]]（火炮参数）

## v1.11.1 M60/榴弹下架（2026-08-17 用户拍板）

**原因**：两把大杀器可补给弹药（弹药堆）后全程持续作战，商店可买 → 长战役后期
人手一把 → 平衡崩坏（全僵尸换 Tank 也平推）。地图刷新保留（稀有不改）。
**改动**：表删两行（M60 5000 / 榴弹 6500），SHOP_SLOTS 25→23，
WALLHACK_SLOT 11→9（透视随前移）；弹药补充对 M60/GL 拦截保持（弹药堆是唯一补给）。
**来源现状**：M60/榴弹 = 地图刷新（稀有）+ 弹药堆补给；Tank 不掉、复活不发、商店不卖。

## v1.11.2 武器盲盒 + 补弹价调整（2026-08-17 用户拍板）

**轻武器盲盒 3000**（cat 0）：SMG×3 各8% / 单喷×2 各12% / scout 23% / 猎枪 24% + **M60 彩蛋 5%**
**重武器盲盒 5500**（cat 0）：连喷×2 各13% / AR×4 各9% / 连狙14% / awp 14% + **M60 彩蛋 5% + 榴弹彩蛋 5%**
（权重合计均 100，直接加权随机发放 GivePlayerItem；表尾追加 SHOP_SLOTS 23→25）

**弹药补充动态价**（全枪种 -1500）：SMG 2000 / AR 3500 / 单喷 4000 / 连喷 5000 / 连狙 5500 / 栓狙 7000；
**M60 专属 6000**（原并入 AR 档）、**榴弹专属 7000**（原回退表价 4500）——M60/榴弹补弹正式放行
（原来菜单只是显示层拦截，购买路径本就通；现移除 [该武器不可补弹] 标签）。
**弹药表同步**：M60 clip 254→150 / reserve 192→600；GL reserve 30→40。

## v1.11.3 电锯并入近战盲盒（2026-08-17 用户拍板）

- 电锯下架单独售卖（原 3500），**并入近战盲盒**：13 等份 = 12 把近战 + 电锯（≈7.7%）
- 近战盲盒 1000 → **2500**
- SHOP_SLOTS 25→24；**WALLHACK_SLOT 9→8**（电锯行在透视之前，删行使透视前移 1，已同步修正并核实行序）

## v1.11.4 盲盒/复活直发武器备弹修复（2026-08-17 用户实测）

**症状**：盲盒开出的武器没有备弹（裸枪）。
**根因**：盲盒走 GivePlayerItem 直接入包，**绕过拾取路径** → AmmoSets（拾取时给
备弹）不触发。
**修复**：新增 `ApplyReserveAmmo(client, weapon)` —— 按 Ammo_ReserveMax 表写
玩家 m_iAmmo[ammoType]（真值）+ 武器 m_iExtraPrimaryAmmo（镜像）。盲盒分支 +
复活套装随机主武器分支（同为直发，同一 bug）均调用。开箱/复活日志带 reserve 数值。

## v1.11.5 近战盲盒/马格南改直接入手（2026-08-17 用户实测）

**症状**：购买近战盲盒、马格南，武器掉地上不是出现在手上。
**修复**：近战盲盒（近战/电锯）改 CreateEntityByName + DispatchSpawn + EquipPlayerWeapon
直接装手（删除地面生成 + 死代码 SpawnMelee 函数）；马格南加特殊分支 GivePlayerItem +
EquipPlayerWeapon + ApplyReserveAmmo（备弹 100 同步）。

## v1.11.6 全商品直接入手（2026-08-17 用户拍板）

**规则**：商店所有商品不再地面生成——手持类（汽油桶/瓦斯罐/煤气罐/烟花/可乐/侏儒）
直接抱手上（`IsCarryingProp` 检测活动武器）；**已抱着物品时购买 → 才掉落地面**
（一次只能抱一个）；其余商品 GivePlayerItem 直发（武器同步备弹），GivePlayerItem
失败才地面兜底防丢。
