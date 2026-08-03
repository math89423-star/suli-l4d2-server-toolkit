/**
 * [L4D2] Score Shop v1.0.8 — !shop / !buy（自 l4d2_si_hud v1.8.2 解耦独立）
 *
 * 从 l4d2_si_hud v1.8.2 整体提取（2026-08-03）：
 *   - si_hud（v1.9.0）保留：计分入账、钱包/复活币所有权与持久化、
 *     复活系统、排行榜、HUD。导出 SH_* natives（RegPluginLibrary
 *     "l4d2_si_hud_api"，契约见 include/l4d2_si_hud.inc）。
 *   - 本插件拥有：商品表（g_ShopTable 编译期）、菜单 UI、ShopBuy、
 *     ShopSpawn/SpawnMelee、透视特感（wallhack）、火炮支援 I/II、
 *     g_iShopBought 限购计数、si_hud_shop_enable + si_hud_art_* cvar。
 *
 * 跨插件绑定（字母序 l4d2_shop < l4d2_si_hud，必须可选绑定）：
 *   OnAllPluginsLoaded / OnLibraryAdded("l4d2_si_hud_api") 时用
 *   GetNativeHandle 获取 5 个 SH_ 句柄，OnLibraryRemoved 清空；
 *   全部有效 = API 可用，否则商店降级为"计分系统未加载"。
 *
 * 商品表（价格用户定稿 2026-08-02/08-03，与 si_hud v1.8.2 完全一致）：
 * 瓦斯罐/煤气罐 100、汽油桶 3500、止痛药/肾上腺素 1000、电击器 3500、
 * 医疗包 3000、激光 1500、M60 5000、电锯 5000、榴弹 6500、复活币 8500、
 * 透视 4000/5min（生效期间不可重复购买）、近战盲盒 1000、烟花 1200、
 * 火力支援I-绿色雨幕 3500/15s、火力支援II-地狱烈火 6500/25s、火力支援III-饱和轰炸 7500/30s（罐+榴弹混合）。
 *
 * v1.0.1（2026-08-03）：火力支援仅收紧半径（时长 30s/25s 不变）——
 * I -25%：750/525/375→562.5/393.75/281.25；II -10%：半径拆独立组
 * si_hud_art2_radius_*（675/472.5/337.5），不再与 I 共用。
 * v1.0.2/v1.0.3（2026-08-03）：去震退实验（手动 env_explosion）——已回退：
 * 用户实测 flag64 去不掉 stagger、燃烧视觉丢失，拍板"回退接受瑕疵"
 * （油桶爆炸有动能、震退合理）。v1.0.4 恢复引擎死亡爆炸（燃烧动画
 * 全原版），改为**震退触发半径分级**（玩家距罐子超阈值只受伤不震退）。
 * v1.0.5：用户定稿两档——油桶/烟花 si_hud_art_nk_radius_oil=100u，
 * 瓦斯/煤气 si_hud_art_nk_radius_gas=200u。
 * v1.0.6（2026-08-03）：瞄准圈分色（I-炮击蓝 / II-燃烧黄 / 无效红）且只
 * 购买者可见（TE_SendToClient）；确认后 si_hud_art_warn_time=5s 预警：
 * 目标光圈全员可见 + y 键聊天区播报，预警结束光圈消失、开始落罐。
 * v1.0.7（2026-08-03）：光圈与轰炸半径解耦——用户反馈收紧后圈太小，
 * 拍板"只放大光圈"：瞄准圈/预警圈用 si_hud_art_ring_out/mid/small
 * （默认收紧前原值 750/525/375 档位），实际落罐范围仍按收紧后半径。
 * 预警增强（用户定稿）：时长 8s、光圈圆心加 800u 光柱（全员可见）、
 * 播报模板 "[火力支援]xxx 已呼叫火力支援，空袭将在 x 秒后到来，注意躲避！"
 * （聊天区）+ 每秒倒计时 PrintHintText 屏幕中央带阴影显示（需 priming，
 * 见记忆 l4d2-printhinttext-priming-bug）；文案统一"到来"（用户纠正：
 * 预警结束轰炸才开始，没有"结束"语义）；轰炸开始瞬间额外显示
 * "空袭将在 X 秒后结束"（X=实际轰炸时长 30/25s）。
 * v1.0.9（2026-08-03）：商店菜单去掉"·左键射击轰炸"描述；购买火炮后
 * 改用屏幕中央 PrintHintText 教学"左键确认轰炸，右键取消"（需 priming）。
 * v1.0.10（2026-08-03）：透视特感——生效期间不可重复购买（去掉续费/900s
 * 封顶），购买后 textprint 提示"特感透视已开启持续300秒"（需 priming）。
 * v1.1.0（2026-08-03）：火力支援III-胆汁雨——商城第三支援技能（用户定稿
 * 3500 分 / 15s，纯控场）。**SDKCall 引擎工厂 CVomitJarProjectile::Create
 * 直生真弹丸**（artillery2 v1.0.x 直生弹丸不爆的正解，签名在
 * left4dhooks.l4d2.txt Signatures 段）：高空坠落 → 撞击地面引擎 Detonate
 * → 原版碎裂（粒子/音效/上胆汁/info_goal_infected_chase 吸引）全自动。
 * 兜底：落地 0.5s 后仍存活 → SDKCall Detonate 强制碎裂。绿圈预警 +
 * 独立 cvar 组 si_hud_art3_*（半径 750/525/375 无伤害更大覆盖更安全）、
 * 每秒 1-2 瓶（ART3_JARS_* 写死，用户拍板可调）。类型链 bool art2
 * 升级为 int kind(1/2/3) 贯通瞄准圈色/确认/预警/落罐模型池。
 * v1.2.0（2026-08-03）：火力支援IV-榴弹雨——商城第四支援技能（TEST 期
 * 1 分/15s，价格用户定稿）。**left4dhooks 现成 native 直生引擎激活态
 * grenadelauncher_projectile**（L4D2_GrenadeLauncherPrj = 引擎工厂
 * CGrenadeLauncher_Projectile::Create 包装，"Creates an activated
 * projectile"——正是 artillery2 v1.0.x 直生缺的初始化）。爆炸伤害/友伤
 * 缩放/击杀归属全原版（m_flDamage=270，与手持 GL 一致，属性 dump 实证）。
 * 引信 ~1.2s → 生成高度特调 ART4_FUSE_HEIGHT 1500u（-900 初速 ≈1.1s
 * 触地，贴近地面空爆；罐子高度 1800-2600 会半空空爆浪费）。红圈预警 +
 * 独立 cvar 组 si_hud_art4_*（半径收紧档 562.5/393.75/281.25 = 与 I/II
 * 一致的有伤害口径）、每秒 1-2 发（ART4_GRENADES_* 写死，用户可调）。
 * 兜底：L4D_DetonateProjectile 强制引爆（激活失败异常态）。kind 链
 * 1/2/3 → 1/2/3/4。
 * v1.2.1（2026-08-03）：修复支援III"引擎签名未解析"（12:59 实测禁用）——
 * 根因：left4dhooks 新版 gamedata 的 L4DD:: 条目是动态生成块（"signature"
 * 值为裸符号名），GetMemSig 解析不了（v1.1.0 用 "L4DD::" 前缀 key 实测
 * sig not found）。迁移到现成 native L4D2_VomitJarPrj（= 引擎工厂
 * CVomitJarProjectile::Create 包装）+ L4D_DetonateProjectile 兜底，与
 * 支援IV 同打法，删除整套 SDKCall 机制（句柄/Prep/惰性解析/禁用标志）。
 * v1.2.2（2026-08-03）：修复胆汁雨落地触发角色语音（用户实测）——幸存者
 * 被胆汁淋到 → 引擎 CTerrorPlayer::OnHitByVomitJar 触发角色反应语音（原版
 * 行为，但雨式轰炸每瓶都触发很吵）。正解：L4D2_VomitJar_Detonate pre 检查
 * 瓶子是否自家生成（g_hArtCans）→ 置标志 → L4D2_OnHitByVomitJar pre 对
 * 幸存者 return Plugin_Handled（语音+被小僵尸盯上都掐掉）；感染者照常放行
 * （控场功能本体）。玩家手扔的瓶子不受影响（标志窗口外，原版行为保留）。
 * v1.2.3（2026-08-03）：投掷语音根因坐实（用户实测：未淋到也响，判断为
 * 投掷时语音）——L4D2_VomitJarPrj 实现 = 模拟完整投掷流程（含角色投掷
 * 喊话），每次生成都播。正解：GetMemSig 经典条目 "CVomitJarProjectile::
 * Create"（无 L4DD:: 前缀，@_ZN 符号格式，3131 行）SDKCall 引擎工厂优先
 * （工厂不播语音），解析失败回退 L4D2_VomitJarPrj（功能不挂仅带语音）。
 * v1.2.2 的碎裂被淋拦截保留（队友防淋+防群殴）。
 * v1.2.4（2026-08-03）：修复躺尸玩家购买复活币不复活（用户反馈）——复活
 * 判定只响应 player_death：次数用完且无币 → 死亡 → 躺尸，之后买币不会再
 * 有死亡事件，币白买。si_hud v1.9.1 新增 SH_ReviveClient native：真死亡
 * 状态（非 alive/非倒下/非 bot/无挂起复活计时器）消耗 1 枚币立即安排复活；
 * 本插件购买复活币后调用（存活 → 返回 0，币正常囤积）。
 * v1.2.5（2026-08-03）：语音仍在的根因排查（13:20 日志实证：v1.2.4 工厂
 * 路径无投掷语音但用户仍听到语音；bile applied 全天零记录 + fallback
 * detonate 74 次 = 瓶子从未自然碎裂全靠兜底强裂）→ 被淋拦截失效：
 * 拦截标志依赖 L4D2_VomitJar_Detonate pre 窗口，但 L4D_DetonateProjectile
 * 兜底路径可能不触发该 pre → 标志恒 false → 碎裂瞬间站在附近的幸存者
 * 被淋 → 角色语音照响（L4D2 被淋视觉反馈弱，用户看不出被淋）。修复：
 * Timer_Art3Detonate 强裂前手动置标志（覆盖 fallback 路径），并加诊断
 * 日志（Detonate pre 触发与否 / OnHitByVomitJar 拦放行）锁定语音来源。
 * v1.2.6（2026-08-03）：**用户拍板换方向：不纠结弹丸碎裂，直接生成
 * "碎裂效果 + 绿色烟雾"**。13:27 日志终局铁证：所有瓶子（native/工厂
 * 路径）100% 走 fallback、Detonate pre/post/survivor-biled/bile applied
 * 全部零记录 = 呕吐瓶从未碎裂（引擎 Touch 不触发，artillery2 同病，
 * 工厂创建 ≠ 激活），无碎裂 → 无碎裂效果/无上胆汁/控场从未生效，语音
 * 只能是 fallback 强拆副产物。v1.2.6 直接效果版：不生成弹丸实体，每瓶
 * 落点 = info_particle_system 碎裂粒子（绿色烟雾）+ 半径内感染者
 * L4D2_Infected_OnHitByVomitJar 上胆汁（变绿+互殴+吸引 = 控场本体）。
 * 无弹丸 → 投掷/被淋语音问题连根消失。删除：工厂 SDKCall 全套、fallback
 * Detonate、被淋拦截 forwards。bile applied 验证日志保留（首次真正可用）。
 * v1.2.7（2026-08-03）：**用户拍板回滚（"回到效果可以但声音太吵的那个
 * 稳定版"）**——v1.2.6 直接效果版用户实测"什么都没有"（info_particle
 * _system 粒子名无效或不可见 + 无上胆汁证据），废弃。回滚到 v1.2.5
 * 完整形态：掉落瓶子雨（工厂 CVomitJarProjectile::Create 无投掷语音 +
 * native 回退）+ 被淋拦截（VomitJar_Detonate pre + OnHitByVomitJar
 * Handle）+ fallback 强拆 manual block window。声音处理已做满：无投掷
 * 语音（工厂）+ 被淋语音拦截。若用户仍嫌吵（fallback 碎裂音效/引擎
 * 副产物）→ 降每秒瓶数或去掉 fallback 音效路径。
 * v1.3.0（2026-08-03）：火力支援V-混合轰炸——商城第五支援技能（用户拍板
 * 新增，TEST 期 1 分/25s，价格/时长/混合比用户定稿）。**罐子+榴弹同时掉**：
 * kind=5 在 Timer_ArtSpawnCan 内随机分流（si_hud_art5_can_pct 罐子占比，
 * 默认 50%）——罐子路径落 kind=1 模型池（丙烷罐 70%/氧气罐 30%，点火强爆），
 * 榴弹路径走 Art4_SpawnGrenade（native 直生 + 引信高度钳制）。每秒总件数
 * 2-3（ART5_* 写死）。品红圈预警 + 独立 cvar 组 si_hud_art5_*（时长 25s、
 * 半径同 I 562.5/393.75/281.25）。购买拦截含榴弹路径 → 与支援IV 同走
 * Art4_CheckNatives。附带修复 v1.2.0 遗留：榴弹引信高度钳制在 pos 计算
 * 之后（只改参数不改落点，弹丸仍生成在 1800-2600 半空空爆浪费）——钳制
 * 提前到 pos 生成前（kind 4/5 同修，与 sm_art4test 口径一致）。
 * v1.4.0（2026-08-03）：火力支援 I/III 正式定稿（用户拍板）——
 * ①混合轰炸转正「火力支援I-轰炸」artillery5 5500 分/30s：榴弹:罐子 = 1:1
 * （si_hud_art5_can_pct 默认 50）、罐子内丙烷:氧气 70/30 → **50/50**（新增
 * ART2_CAN_PROPANE_PCT 70 承接 kind=2 油桶/烟花池原比例）；每秒 2-3 件、
 * 半径 562.5/393.75/281.25 不变（同原 I 口径）。**禁用原火力支援I-炮击
 * （artillery）与火力支援IV-榴弹雨（artillery4）**——商店表删除两行
 * （SHOP_SLOTS 20→18），菜单即消失；kind 1/4 代码路径全部保留（kind=5 罐子
 * 分流依赖 kind=1 模型池路径，将来恢复只需加回表行）。
 * ②火力支援III-胆汁雨定稿 3500/15s 不变：范围 = I-轰炸的 **75%**
 * （421.875/295.3125/210.9375，v1.4.0 前 750/525/375 太大）、**每 2 秒 1-2 罐**
 * （循环步进 2，15s ≈ 8-16 瓶，v1.4.0 前每秒 1-2 瓶减半）。
 * ③商店菜单新增「火力支援」分类（cat=4，用户拍板）——I-轰炸/II-燃烧/III-胆汁雨
 * 从"其他"移入，菜单分类页 0-4。
 * ④新增商品（用户定稿）：马格南 2000（武器栏，weapon_pistol_magnum）、
 * 燃烧弹包 500 / 高爆弹包 500（其它栏，weapon_upgradepack_incendiary/
 * weapon_upgradepack_explosive，升级包走现有 ShopSpawn 通用路径）。表尾
 * 追加三行不动 WALLHACK_SLOT 12。SHOP_SLOTS 18→21。
 * v1.4.1（2026-08-03）：TEST 期结束（用户拍板）——0-14 槽全部恢复原价
 * （瓦斯/煤气 100、油桶 3500、药/肾上腺素 1000、电击器 3500、医疗包 3000、
 * 激光 1500、M60 5000、电锯 5000、榴弹 6500、复活币 8500、透视 4000、
 * 盲盒 1000、烟花 1200）+ 火力支援II 恢复 6500；火力支援 I/III 与新商品
 * 价格为 v1.4.0 定稿不动。TEST 注释行删除。
 * v1.4.2（2026-08-03）：瞄准圈定稿（用户拍板）——**四色**：I-轰炸蓝 / II-燃烧
 * 黄 / III-胆汁雨绿 / 无效红（kind 5 原品红 → 蓝，kind 1/4 已禁用落默认蓝）；
 * **三档圈大小**：Art_RingParams 加 kind 参数，圈 = 各火力轰炸半径 × 4/3——
 * I-轰炸 750/525/375、II-燃烧 900/630/450、III-胆汁 562.5/393.75/281.25
 * （v1.0.7 的 si_hud_art_ring_* 独立 cvar 废弃不再读，残留惰性无害）。
 * v1.4.3（2026-08-03）：商店布局定稿（用户拍板）——
 * ①火力支援按价格重排编号：I-胆汁雨 3500（原 III）/ II-轰炸 5500（原 I-轰炸）/
 * III-燃烧 6500（原 II）；只改显示名+描述，classname/kind/cvar 组全不动
 * （菜单、圈色、时长等全部跟随 kind 自动正确）。
 * ②复活币/燃烧弹包/高爆弹包移入道具类（cat 3→1）。
 * ③菜单分类顺序：武器/道具/医疗/[火力支援(第4)]/[其他(第5)]——AddItem
 * 顺序 0,1,2,4,3（cat 值不变，显示顺序调换）。
 * v1.4.4（2026-08-03）：火力支援 II/III 对调编号 + 轰炸涨价（用户实测反馈
 * "2 和 3 都过强"）——「火力支援III-饱和轰炸」7500/30s（原 II-轰炸 5500，其余
 * 参数不变）、「火力支援II-地狱烈火」6500/25s（原 III-燃烧，全不变）。编号按
 * 价格升序：I-胆汁雨 3500 < II-燃烧 6500 < III-轰炸 7500。
 * v1.4.5（2026-08-03）：正式定名（用户拍板，弃用"胆汁雨/燃烧/轰炸"直白词）——
 * 火力支援I-**绿色雨幕**（绿圈·控场）/ 火力支援II-**地狱烈火**（黄圈·燃烧）/
 * 火力支援III-**地毯轰炸**（蓝圈·混合轰炸）。只改显示名+描述+cvar 文案，
 * classname/kind/参数全不动。
 * v1.4.6（2026-08-03）：新增「投掷」分类 + 补给品改名（用户拍板）——
 * ①投掷类（cat=5，菜单第 4 类，火力支援/其他顺移第 5/6）：胆汁 850
 * （weapon_vomitjar）/ 土质炸弹 900（weapon_pipe_bomb）/ 燃烧瓶 2500
 * （weapon_molotov），走 ShopSpawn 通用生成路径；SHOP_SLOTS 21→24。
 * ②燃烧弹包/高爆弹包从道具类移入医疗类（cat 1→2），医疗类改名「补给品」
 * （菜单 AddItem/catNames 同步）。
 * v1.4.7（2026-08-03）：菜单分类「投掷」改名「投掷品」（用户拍板，仅显示名）；
 * 复活币移入其他类（cat 1→3）。
 * v1.4.8（2026-08-03）：火力支援涨价（用户实测后拍板）——I-绿色雨幕
 * 3500→**4500**、II-地狱烈火 6500→**8500**、III-地毯轰炸 7500→**10000**
 * （时长/范围/机制全不变，只改价格）。
 * v1.4.9（2026-08-03）：分类涨价（用户拍板）——投掷品 ×1.5：胆汁 1275/
 * 土质炸弹 1350/燃烧瓶 3750；补给品 ×1.25：药/肾上腺素 1250、电击器 4375、
 * 医疗包 3750、燃烧弹包/高爆弹包 625。
 * v1.5.0（2026-08-03）：火力支援III 改名「饱和轰炸」（用户拍板，仅显示名，
 * 覆盖商店表/cvar 描述/注释全部文案；classname/kind/价格机制全不变）。
 * v1.5.1（2026-08-03）：复活套装（用户拍板）——监听 si_hud v1.9.2 的
 * SH_OnClientRespawned 全局 forward，复活币死亡复活时发放固定装备 +
 * 满血。sm_shop_respawn_gear（默认 M60+消防斧+止痛药+土质炸弹）+
 * sm_shop_respawn_health 100；闲置/接管引擎自管。
 * 注意：v1.0.2-v1.5.1 均未提交 git（用户要求，测试迭代中）。
 *
 * 依赖：l4d2_si_hud.smx >= v1.9.2（SH_ API + 复活 forward）。未加载时商店不可用。
 */

#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>      // SDKHooks_TakeDamage（火炮引爆击杀归属）
#include <float>         // 火炮弹道数学 Sqrt/Cos/Sin
#include <left4dhooks>   // v1.1.0: L4D2_Infected_HitByVomitJar forward（胆汁验证日志；全部 native 已 MarkNativeAsOptional，缺失不挡加载）

#define PLUGIN_VERSION "1.6.2"

// ============================================================================
// SH_ public API（l4d2_si_hud >= v1.9.0 导出；契约见 include/l4d2_si_hud.inc）
//
// 绑定方式（SM 1.12）：plain native 声明 + 运行时懒绑定——项目既有模式
// （left4dhooks 消费方、废弃的 l4d2_shop_artillery2 同款）。si_hud 未加载
// 时调用缺失 native 会记错误日志，故所有调用走 SH_Ready() 守卫的入口
// （Cmd_Shop / ShopBuy / ArtEndDesignate 退款），正常情况不发起裸调用。
// ============================================================================

native int SH_GetWallet(int client);
native int SH_AddWallet(int client, int amount);
native int SH_GetReviveCoins(int client);
native int SH_AddReviveCoins(int client, int amount);
native int SH_GetCoinMax();
native int SH_ReviveClient(int client);   // v1.2.4: 躺尸玩家购买复活币立即生效

ConVar g_cvSIHudEnable;      // si_hud 总开关（FindConVar 读；null 视为开启）

bool SH_Ready()
{
    Handle plugin = FindPluginByFile("l4d2_si_hud.smx");
    if (plugin == INVALID_HANDLE)
        return false;
    // v1.8.x 及更早无 SH_ API（商店内嵌）；v1.9.0 起导出
    char ver[16];
    GetPluginInfo(plugin, PlInfo_Version, ver, sizeof(ver));
    return (StrContains(ver, "1.8") != 0);
}

// ============================================================================
// ConVar handles（13 个：shop_enable + 火炮 12 个；默认值/上下界与 si_hud
// v1.8.2 完全一致。respawn_coin_* 留在 si_hud，经 SH_GetCoinMax 读）
// ============================================================================

ConVar g_cvShopEnable;
ConVar g_cvArtEnable;
ConVar g_cvArtTargetTime;
ConVar g_cvArtDuration;
ConVar g_cvArtDuration2;
ConVar g_cvArtRadiusOut;
ConVar g_cvArtRadiusMid;
ConVar g_cvArtRadiusSmall;
ConVar g_cvArt2RadiusOut;   // v1.0.1: II-燃烧独立半径组（I 收紧 25% / II 收紧 10%，不再共用）
ConVar g_cvArt2RadiusMid;
ConVar g_cvArt2RadiusSmall;
ConVar g_cvArt3Duration;    // v1.1.0: III-胆汁雨独立时长（15s 用户定稿）
ConVar g_cvArt3RadiusOut;   // v1.1.0: III-胆汁雨独立半径组（750/525/375——无伤害，更大覆盖更安全）
ConVar g_cvArt3RadiusMid;
ConVar g_cvArt3RadiusSmall;
ConVar g_cvArt4Duration;    // v1.2.0: IV-榴弹雨独立时长（TEST 15s，价格/时长用户定稿）
ConVar g_cvArt4RadiusOut;   // v1.2.0: IV-榴弹雨独立半径组（562.5/393.75/281.25 = 有伤害口径同 I/II）
ConVar g_cvArt4RadiusMid;
ConVar g_cvArt4RadiusSmall;
ConVar g_cvArt5Duration;    // v1.3.0: V-混合轰炸独立时长（TEST 25s）/半径组（同 I）/罐子占比
ConVar g_cvArt5RadiusOut;
ConVar g_cvArt5RadiusMid;
ConVar g_cvArt5RadiusSmall;
ConVar g_cvArt5CanPct;      // v1.3.0: 罐子占比 %（余下为榴弹）
ConVar g_cvArtHeightMin;
ConVar g_cvArtHeightMax;
ConVar g_cvArtDelay;
ConVar g_cvArtBurn;
ConVar g_cvArtCooldown;
ConVar g_cvArtNkRadiusOil;  // v1.0.5: 油桶/烟花震退触发距离（100）
ConVar g_cvArtNkRadiusGas;  // v1.0.5: 瓦斯/煤气震退触发距离（200）
ConVar g_cvArtWarnTime;     // v1.0.6: 确认后预警时长（5s）
ConVar g_cvArtRingOut;      // v1.0.7: 光圈显示半径-开阔地（750）
ConVar g_cvArtRingMid;      // v1.0.7: 光圈显示半径-高顶（525）
ConVar g_cvArtRingSmall;    // v1.0.7: 光圈显示半径-矮房（375）
ConVar g_cvRespawnGear;     // v1.5.1: 复活套装装备列表（逗号分隔；近战 weapon_melee|脚本名）
ConVar g_cvRespawnHealth;   // v1.5.1: 复活套装满血值（0=不动）

// ============================================================================
// 常量（自 si_hud 逐字移植）
// ============================================================================

#define ART_AIM_MAX_DIST     2000.0   // 准星 trace 最远距离
#define ART_CEIL_CLEAR       4096.0   // 向上探测上限（无遮挡 = 室外）
#define ART_CEIL_LOW         600.0    // 天花板 < 600 且上方非开阔 → 无效（拒绝确认）
#define ART_CEIL_MID         900.0    // 天花板 ≥ 900 → 中等规模
#define ART_GRAVITY          800.0    // 引擎重力 u/s²（落时 t=sqrt(2h/g)）
#define ART_MAX_TOTAL        600      // v1.7.95: 单次空袭罐数硬上限（防 cvar 误配超载）
#define ART_CANS_MIN_PER_SEC 2        // v1.7.96: 每秒落罐数随机范围（用户拍板 2-3）
#define ART_CANS_MAX_PER_SEC 3
// v1.1.0: 支援III-胆汁雨 每秒瓶数 1-2（单瓶胆汁覆盖半径大，2-3瓶/秒会重叠+卡顿）
// v1.2.7: 用户嫌吵——若碎裂音效仍吵，可降为 1（MAX 改 1 即每秒 1 瓶）
#define ART3_JARS_MIN_PER_SEC 1
#define ART3_JARS_MAX_PER_SEC 2
// v1.2.0: 支援IV-榴弹雨 每秒发数 1-2（爆炸半径大且满伤，2-3发/秒过载）
#define ART4_GRENADES_MIN_PER_SEC 1
#define ART4_GRENADES_MAX_PER_SEC 2
// v1.3.0: V-混合轰炸每秒总件数（罐+榴弹混合，用户拍板可调）
#define ART5_MIN_PER_SEC 2
#define ART5_MAX_PER_SEC 3
// v1.2.0: 引信 ~1.2s——生成高度特调 1500u（-900 初速 ≈1.1s 触地，贴近
// 地面空爆）；罐子高度（1800-2600）会让榴弹在半空空爆，伤害打空浪费
#define ART4_FUSE_HEIGHT 1500.0
// v1.4.0: 罐型比例拆常量——kind1/5 罐子池 50/50（用户定稿：瓦斯:煤气=1:1）；
// kind2 油桶/烟花池保持 70/30（原比例，v1.4.0 前共用同一常量会互相影响）
#define ART_CAN_PROPANE_PCT  50       // kind 1/5 罐子池：50% 瓦斯罐 + 50% 煤气罐
#define ART2_CAN_PROPANE_PCT 70       // kind 2 池：70% 油桶 + 30% 烟花
#define ART_TICK_INT         0.05     // 瞄准心跳间隔（标记更新 + 右键/超时/死亡检测）
#define ART_CEIL_THIN        100.0    // 薄遮挡厚度阈值（u）

#define SHOP_SLOTS      24      // v1.4.6: +3（胆汁/土质炸弹/燃烧瓶 投掷类）

#define MELEE_POOL_COUNT   12

#define WALLHACK_SLOT       12      // g_ShopTable 槽位（= 透视特感）
#define WALLHACK_DURATION   300.0   // v1.8.1: 5 分钟（用户定稿，原 v1.7.67 定稿 180=3 分钟）
// v1.0.10: 生效期间不可重复购买 → WALLHACK_CAP（900s 续费封顶）已删除

// ============================================================================
// 商品表（!shop）——价格/限购编译期写死（改价格需重编译本插件）
// ============================================================================

enum struct ShopItem
{
    char name[32];      // 显示名
    char classname[64]; // 实体 classname（空 = 特殊商品：复活币）
    int  price;         // 价格（可用积分）
    int  limit;         // 每图限购次数（0 = 无限）
    int  cat;           // v1.7.64: 菜单分类 0=武器 1=道具 2=补给品 3=其他；v1.4.0: 4=火力支援；v1.4.6: 5=投掷
}

// 商品表（价格用户定稿 2026-08-02/08-03 修订：近战盲盒 1000/激光 1500/罐子 100/医疗包
// 3000/电击器 3500/药 1000/肾上腺素 1000/烟花 1200/油桶 3500/复活币 8500/透视 4000；
// v1.4.0: I-轰炸 5500/II-燃烧 6500/III-胆汁雨 3500/马格南 2000/燃烧弹包 500/高爆弹包 500）
ShopItem g_ShopTable[SHOP_SLOTS] = {
    // v1.7.36 (user): 全部商品不限购（limit 0）——只有复活币受持有上限
    // (si_hud_respawn_coin_max 5) 约束
    // v1.4.1: TEST 期结束，全部恢复原价（2026-08-03 用户拍板）
    { "瓦斯罐",      "weapon_propanetank",               100,  0,  1 },   // v1.7.96: 用户定稿 100
    { "煤气罐",      "weapon_oxygentank",                100,  0,  1 },   // v1.7.96: 用户定稿 100
    { "汽油桶",      "weapon_gascan",                    3500,  0,  1 },   // v1.7.96: 用户定稿 3500（原 5000）
    { "止痛药",      "weapon_pain_pills",                1250,  0,  2 },   // v1.4.9: 补给品 ×1.25（原 1000）
    { "肾上腺素",    "weapon_adrenaline",                1250,  0,  2 },   // v1.4.9: 补给品 ×1.25（原 1000）
    { "电击器",      "weapon_defibrillator",             4375,  0,  2 },   // v1.4.9: 补给品 ×1.25（原 3500）
    { "医疗包",      "weapon_first_aid_kit",             3750,  0,  2 },   // v1.4.9: 补给品 ×1.25（原 3000）
    { "激光瞄准",    "weapon_upgradepack_laser_sight",   1500,  0,  0 },   // v1.7.96: 用户定稿 1500（原 3500）
    { "M60 轻机枪",  "weapon_rifle_m60",                 5000,  0,  0 },   // v1.7.96: 用户定稿 5000
    { "电锯",        "weapon_chainsaw",                  5000,  0,  0 },   // v1.7.44
    { "榴弹发射器",  "weapon_grenade_launcher",          6500,  0,  0 },   // v1.7.96: 用户定稿 6500（原 8000）
    { "复活币",      "",                                 8500,  0,  3 },   // v1.8.1: 用户定稿 8500（v1.7.96 定稿 9000）；v1.4.7: 移入其他类
    { "透视特感",    "wallhack",                         4000,  0,  3 },   // v1.8.1: 用户定稿 4000/5分钟（原 6000/3分钟；可续费至 15 分钟）
    { "近战盲盒",    "melee_box",                        1000,  0,  0 },   // v1.7.96: 用户定稿 1000（原 3000）
    { "烟花",        "weapon_fireworkcrate",             1200,  0,  1 },   // v1.7.96: 用户定稿 1200（原 2500）
    // v1.4.3: 按价格重排编号（用户拍板）——胆汁雨 3500 最低 = I、轰炸 5500 = II、
    // 燃烧 6500 = III（原 III-胆汁雨/I-轰炸/II-燃烧）；v1.4.5 定名：绿色雨幕/地狱烈火/地毯轰炸
    { "火力支援II-地狱烈火", "artillery2",                 8500,   0,  4 },  // v1.4.8: 用户定稿涨价 6500→8500（25s）；v1.0.1: 半径收紧 10%
    { "火力支援I-绿色雨幕", "artillery3",             4500,  0,  4 }   // v1.4.8: 用户定稿涨价 3500→4500（15s，范围=轰炸 75%，每 2 秒 1-2 罐）
    // v1.3.0: 支援V-混合轰炸 → v1.4.0 转正定稿「火力支援III-饱和轰炸」5500/30s
    // （罐+榴弹 1:1；原火力支援I-炮击 artillery + IV-榴弹雨 artillery4 已禁用，表行删除）
    , { "火力支援III-饱和轰炸", "artillery5",               10000,  0,  4 }   // v1.4.8: 用户定稿涨价 7500→10000（30s）
    // v1.4.0: 新增商品（用户定稿；表尾追加不动透视特感槽位 12）——
    // 马格南 2000（武器栏）、燃烧弹包/高爆弹包 500（升级包走现有
    // ShopSpawn 通用生成路径，与激光瞄准同类）
    // v1.4.3: 燃烧弹包/高爆弹包移入道具类（cat 3→1）
    , { "马格南",      "weapon_pistol_magnum",          2000,  0,  0 }
    , { "燃烧弹包",    "weapon_upgradepack_incendiary",  625,  0,  2 }   // v1.4.9: 补给品 ×1.25（原 500）
    , { "高爆弹包",    "weapon_upgradepack_explosive",   625,  0,  2 }   // v1.4.9: 补给品 ×1.25（原 500）
    // v1.4.6: 投掷类新增商品（用户定稿）——胆汁 850 / 土质炸弹(pipe_bomb) 900 /
    // 燃烧瓶(molotov) 2500；cat=5 投掷（菜单第 4 类，火力支援/其他顺移）；
    // 走 ShopSpawn 通用生成路径（投掷物实体直接生成可拾取）
    , { "胆汁",        "weapon_vomitjar",                1275,  0,  5 }   // v1.4.9: 投掷品 ×1.5（原 850）
    , { "土质炸弹",    "weapon_pipe_bomb",               1350,  0,  5 }   // v1.4.9: 投掷品 ×1.5（原 900）
    , { "燃烧瓶",      "weapon_molotov",                 3750,  0,  5 }   // v1.4.9: 投掷品 ×1.5（原 2500）
};

int       g_iShopBought[MAXPLAYERS + 1][SHOP_SLOTS];   // 每图已购次数（OnMapEnd 清零）

// v1.7.72: 近战盲盒奖池（12 把，不含电锯）——2D 字符数组初始化规则
// （spcomp64 实测）：尺寸全显式 + 行数必须与初始化行数一致（[12][16] 配
// 2 行 → error 047；const + 省略首维 → parse error）
// v1.7.76 FIX: 抽取下标用显式常量 MELEE_POOL_COUNT——sizeof(x)/sizeof(x[])
// 在全局数组上实测算出 0（GetRandomInt(0,0) 永远棒球棍）
char g_MeleePool[MELEE_POOL_COUNT][16] = {
    "baseball_bat", "cricket_bat", "crowbar", "electric_guitar",
    "fireaxe", "frying_pan", "golfclub", "katana",
    "knife", "machete", "tonfa", "shovel"
};

// ============================================================================
// 全局状态
// ============================================================================

// 透视特感（!shop 特殊商品）——购买者独占的蓝色高亮（全队可见）
bool      g_bWallhack[MAXPLAYERS + 1];          // 透视生效中
float     g_fWallhackEnd[MAXPLAYERS + 1];       // v1.7.69: 效果结束的 GameTime（续费累计）
Handle    g_hWallhackTimer[MAXPLAYERS + 1];     // 到期计时器
Handle    g_hWallhackWarnTimer[MAXPLAYERS + 1]; // v1.7.68: 结束前 30 秒提醒计时器
Handle    g_hWallhackSyncTimer;                 // 补光心跳（0.5s，无购买者自动停）
ArrayList g_hWitchList;                         // 当前 Witch 实体索引（自家独立维护；si_hud 另有伤害 hook 用的列表）
Handle    g_hShopMenu[MAXPLAYERS + 1];          // 当前打开的商店菜单
int       g_iShopCat[MAXPLAYERS + 1];           // 当前打开的商品分类（购买后重开同分类刷新）

// 火炮支援 I/II/III（!shop 特殊商品）——瞄准指示 + 罐/瓶雨轰炸
bool      g_bArtAiming[MAXPLAYERS + 1];       // 瞄准指示中
int       g_iArtSlot[MAXPLAYERS + 1];         // 商店槽位（取消退款用）
int       g_iArtPrice[MAXPLAYERS + 1];        // 购买价格（取消退款用）
int       g_iArtMarker[MAXPLAYERS + 1];       // env_sprite 标记 entref
Handle    g_hArtAimTimer[MAXPLAYERS + 1];     // 瞄准心跳
float     g_fArtAimEnd[MAXPLAYERS + 1];       // 超时 GameTime
ArrayList g_hArtCans;                         // 活跃罐子 entref（换图/卸载兜底清理）
int       g_iBeamLaser;                       // precache 的 beam 模型索引（OnMapStart）
int       g_iBeamHalo;
float     g_fArtNextBuyTime;                  // 下次可购买 GameTime（轰炸中+冷却=禁止全体购买）
// v1.0.6: 确认后预警阶段（5s 光圈全员可见 + 聊天播报，之后才开始落罐）
bool      g_bArtWarning;                      // 预警阶段中
int       g_iArtWarnKind;                     // v1.1.0/v1.3.0: 预警目标火力类型 1/2/3/4/5（决定光圈颜色）
bool      g_bArt3NativesFail;                 // v1.2.1: left4dhooks native 缺失 → 购买拦截禁用
bool      g_bArt4NativesFail;                 // v1.2.0: left4dhooks native 缺失 → 购买拦截禁用
bool      g_bArt3Detonating;                  // v1.2.2: 当前碎裂的瓶子是否自家生成（VomitJar_Detonate pre→Post 窗口）
Handle    g_hCallVomitJarCreate;              // v1.2.3: CVomitJarProjectile::Create 工厂句柄（经典条目 @_ZN，无投掷语音）
bool      g_bArt3SDKResolved;                 // v1.2.3: 工厂惰性解析已尝试（成功/失败都只试一次）
float     g_fArtWarnTarget[3];                // 预警落点
float     g_fArtWarnRing;                     // 预警光圈显示半径（v1.0.7 与轰炸半径解耦）
float     g_fArtWarnRadius;                   // 实际落罐半径（收紧后）
float     g_fArtWarnHeight;                   // 落罐高度
float     g_fArtWarnDuration;                 // 轰炸时长
int       g_iArtWarnBuyer;                    // 召唤者
float     g_fArtWarnEnd;                      // 预警结束 GameTime
Handle    g_hArtWarnTimer;                    // 预警光圈心跳
int       g_iArtWarnLastSec;                  // 上次播报的剩余秒数（每秒倒计时去重）

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Score Shop",
    author      = "suli",
    description = "Score shop (!shop/!buy) — extracted from l4d2_si_hud v1.8.2 (requires si_hud >= v1.9.0)",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// OnPluginStart
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("l4d2_shop_version", PLUGIN_VERSION,
        "Score Shop version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // v1.7.27: score shop — !shop / !buy (prices are compile-time in g_ShopTable)
    g_cvShopEnable = CreateConVar("si_hud_shop_enable", "1",
        "Enable the score shop (!shop / !buy).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvShopEnable.SetBounds(ConVarBound_Upper, true, 1.0);
    g_cvShopEnable.SetBounds(ConVarBound_Lower, true, 0.0);

    // v1.7.80: 火炮支援1（!shop 特殊商品；v1.7.93 用户定稿命名，价格暂定 1 分）
    // 所有 cvar 创建后补 SetBounds——残留 cvar 坑：cfg exec 曾自动创建同名
    // cvar 时 CreateConVar 不更新 def/max（v1.7.47 实锤），强制重设
    g_cvArtEnable = CreateConVar("si_hud_art_enable", "1",
        "Enable the artillery strike shop item (0=off, purchase refunded).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvArtEnable.SetBounds(ConVarBound_Upper, true, 1.0);
    g_cvArtEnable.SetBounds(ConVarBound_Lower, true, 0.0);

    g_cvArtTargetTime = CreateConVar("si_hud_art_target_time", "15.0",
        "Seconds to designate the strike target with the magnum before auto-cancel+refund.", FCVAR_NOTIFY, true, 3.0, true, 60.0);
    g_cvArtTargetTime.SetBounds(ConVarBound_Upper, true, 60.0);
    g_cvArtTargetTime.SetBounds(ConVarBound_Lower, true, 3.0);

    // v1.7.96: 持续轰炸——时长秒数 × 每秒随机 2-3 罐（用户拍板：30s ≈ 60-90 罐）
    // v1.8.1: I-炮击 30s；II-燃烧 25s（用户定稿；v1.0.1 收紧仅限半径，时长不变）
    g_cvArtDuration = CreateConVar("si_hud_art_duration", "30.0",
        "Total barrage duration in seconds for 火力支援I-炮击 (2-3 cans fall randomly each second).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvArtDuration.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArtDuration.SetBounds(ConVarBound_Lower, true, 5.0);

    g_cvArtDuration2 = CreateConVar("si_hud_art2_duration", "25.0",
        "Total barrage duration in seconds for 火力支援II-地狱烈火 (2-3 cans fall randomly each second).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvArtDuration2.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArtDuration2.SetBounds(ConVarBound_Lower, true, 5.0);

    // v1.0.1: I 收紧 25%：750→562.5 / 525→393.75 / 375→281.25
    g_cvArtRadiusOut = CreateConVar("si_hud_art_radius_out", "562.5",
        "Spread radius (units) of the open-area strike; also the target ring radius.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusOut.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRadiusOut.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArtRadiusMid = CreateConVar("si_hud_art_radius_mid", "393.75",
        "Spread radius for ceiling >= 900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusMid.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRadiusMid.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArtRadiusSmall = CreateConVar("si_hud_art_radius_small", "281.25",
        "Spread radius for ceiling 600-900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusSmall.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRadiusSmall.SetBounds(ConVarBound_Lower, true, 50.0);

    // v1.0.1: II 独立半径组，收紧 10%：750→675 / 525→472.5 / 375→337.5
    g_cvArt2RadiusOut = CreateConVar("si_hud_art2_radius_out", "675.0",
        "Spread radius (units) of the 火力支援II-地狱烈火 open-area strike; also the target ring radius.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt2RadiusOut.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt2RadiusOut.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt2RadiusMid = CreateConVar("si_hud_art2_radius_mid", "472.5",
        "Spread radius for ceiling >= 900 (火力支援II-地狱烈火).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt2RadiusMid.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt2RadiusMid.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt2RadiusSmall = CreateConVar("si_hud_art2_radius_small", "337.5",
        "Spread radius for ceiling 600-900 (火力支援II-地狱烈火).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt2RadiusSmall.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt2RadiusSmall.SetBounds(ConVarBound_Lower, true, 50.0);

    // v1.1.0: III-胆汁雨独立组（用户定稿 15s；半径 750/525/375 = 无伤害更大覆盖）
    g_cvArt3Duration = CreateConVar("si_hud_art3_duration", "15.0",
        "Total barrage duration in seconds for 火力支援I-绿色雨幕 (1-2 jars fall randomly every 2 seconds).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvArt3Duration.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArt3Duration.SetBounds(ConVarBound_Lower, true, 5.0);

    // v1.4.0: III 范围 = 火力支援I-轰炸的 75%（用户定稿）：562.5→421.875 /
    // 393.75→295.3125 / 281.25→210.9375（纯控场圈收小）
    g_cvArt3RadiusOut = CreateConVar("si_hud_art3_radius_out", "421.875",
        "Spread radius (units) of the 火力支援I-绿色雨幕 open-area strike; also the target ring radius.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt3RadiusOut.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt3RadiusOut.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt3RadiusMid = CreateConVar("si_hud_art3_radius_mid", "295.3125",
        "Spread radius for ceiling >= 900 (火力支援I-绿色雨幕).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt3RadiusMid.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt3RadiusMid.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt3RadiusSmall = CreateConVar("si_hud_art3_radius_small", "210.9375",
        "Spread radius for ceiling 600-900 (火力支援I-绿色雨幕).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt3RadiusSmall.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt3RadiusSmall.SetBounds(ConVarBound_Lower, true, 50.0);

    // v1.2.0: IV-榴弹雨独立组（TEST 15s；半径收紧档 = 有伤害口径同 I/II）
    g_cvArt4Duration = CreateConVar("si_hud_art4_duration", "15.0",
        "Total barrage duration in seconds for 火力支援IV-榴弹雨 (disabled item; grenade path reused by 火力支援III-饱和轰炸).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvArt4Duration.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArt4Duration.SetBounds(ConVarBound_Lower, true, 5.0);

    g_cvArt4RadiusOut = CreateConVar("si_hud_art4_radius_out", "562.5",
        "Spread radius (units) of the 火力支援IV-榴弹雨 open-area strike (disabled item).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt4RadiusOut.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt4RadiusOut.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt4RadiusMid = CreateConVar("si_hud_art4_radius_mid", "393.75",
        "Spread radius for ceiling >= 900 (火力支援IV-榴弹雨, disabled item).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt4RadiusMid.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt4RadiusMid.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt4RadiusSmall = CreateConVar("si_hud_art4_radius_small", "281.25",
        "Spread radius for ceiling 600-900 (火力支援IV-榴弹雨, disabled item).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt4RadiusSmall.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt4RadiusSmall.SetBounds(ConVarBound_Lower, true, 50.0);

    // v1.3.0: V-混合轰炸独立组（用户定稿 TEST 25s；半径同 I 562.5/393.75/281.25；
    // 混合比 can_pct 罐子占比，余下为榴弹——全引擎路径，无新增 native）
    g_cvArt5Duration = CreateConVar("si_hud_art5_duration", "30.0",   // v1.4.0: 用户定稿 30s
        "Total barrage duration in seconds for 火力支援III-饱和轰炸 (cans+grenades mixed, 2-3 items per second).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvArt5Duration.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArt5Duration.SetBounds(ConVarBound_Lower, true, 5.0);

    g_cvArt5RadiusOut = CreateConVar("si_hud_art5_radius_out", "562.5",
        "Spread radius (units) of the 火力支援III-饱和轰炸 open-area strike; also the target ring radius.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt5RadiusOut.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt5RadiusOut.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt5RadiusMid = CreateConVar("si_hud_art5_radius_mid", "393.75",
        "Spread radius for ceiling >= 900 (火力支援III-饱和轰炸).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt5RadiusMid.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt5RadiusMid.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt5RadiusSmall = CreateConVar("si_hud_art5_radius_small", "281.25",
        "Spread radius for ceiling 600-900 (火力支援III-饱和轰炸).", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArt5RadiusSmall.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArt5RadiusSmall.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArt5CanPct = CreateConVar("si_hud_art5_can_pct", "50.0",
        "Percent of falling items that are propane/oxygen cans in 火力支援III-饱和轰炸 (rest are grenades).", FCVAR_NOTIFY, true, 0.0, true, 100.0);
    g_cvArt5CanPct.SetBounds(ConVarBound_Upper, true, 100.0);
    g_cvArt5CanPct.SetBounds(ConVarBound_Lower, true, 0.0);

    g_cvArtHeightMin = CreateConVar("si_hud_art_height_min", "1800.0",
        "Min drop height (units) for open areas.", FCVAR_NOTIFY, true, 400.0, true, 8000.0);
    g_cvArtHeightMin.SetBounds(ConVarBound_Upper, true, 8000.0);
    g_cvArtHeightMin.SetBounds(ConVarBound_Lower, true, 400.0);

    g_cvArtHeightMax = CreateConVar("si_hud_art_height_max", "2600.0",
        "Max drop height (units) for open areas.", FCVAR_NOTIFY, true, 400.0, true, 8000.0);
    g_cvArtHeightMax.SetBounds(ConVarBound_Upper, true, 8000.0);
    g_cvArtHeightMax.SetBounds(ConVarBound_Lower, true, 400.0);

    // v1.7.93: si_hud_art_damage 已删除——爆炸伤害由模型 propdata 决定（原版 200 falloff）
    g_cvArtDelay = CreateConVar("si_hud_art_delay", "0.5",
        "Seconds between confirm and the first can spawning.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvArtDelay.SetBounds(ConVarBound_Upper, true, 10.0);
    g_cvArtDelay.SetBounds(ConVarBound_Lower, true, 0.0);

    g_cvArtBurn = CreateConVar("si_hud_art_burn", "2.0",
        "Secs the can keeps burning after landing (burns out, then detonates).", FCVAR_NOTIFY, true, 1.0, true, 60.0);
    g_cvArtBurn.SetBounds(ConVarBound_Upper, true, 60.0);
    g_cvArtBurn.SetBounds(ConVarBound_Lower, true, 1.0);

    g_cvArtCooldown = CreateConVar("si_hud_art_cooldown", "10.0",
        "Global hard cooldown after a strike ends before anyone can buy again (user: 10s).", FCVAR_NOTIFY, true, 0.0, true, 300.0);
    g_cvArtCooldown.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArtCooldown.SetBounds(ConVarBound_Lower, true, 0.0);

    // v1.0.4: 爆炸震退触发距离——玩家距爆炸罐子 <= 阈值时保留震退，
    // 更远只受伤不震退。v1.0.5 用户定稿两档：油桶/烟花 100、瓦斯/煤气 200
    g_cvArtNkRadiusOil = CreateConVar("si_hud_art_nk_radius_oil", "100.0",
        "Stagger trigger radius (units) for gas-can/firework explosions (oil cans); beyond this players take damage without stagger knockback.", FCVAR_NOTIFY, true, 0.0, true, 1500.0);
    g_cvArtNkRadiusOil.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtNkRadiusOil.SetBounds(ConVarBound_Lower, true, 0.0);

    g_cvArtNkRadiusGas = CreateConVar("si_hud_art_nk_radius_gas", "200.0",
        "Stagger trigger radius (units) for propane/oxygen tank explosions; beyond this players take damage without stagger knockback.", FCVAR_NOTIFY, true, 0.0, true, 1500.0);
    g_cvArtNkRadiusGas.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtNkRadiusGas.SetBounds(ConVarBound_Lower, true, 0.0);

    // v1.0.6: 确认后预警时长——目标光圈全员可见 + 聊天播报，预警结束才开始落罐
    // v1.0.7: 用户定稿 8s，每秒倒计时播报
    g_cvArtWarnTime = CreateConVar("si_hud_art_warn_time", "8.0",
        "Pre-strike warning seconds after confirm: target ring visible to all + chat broadcast, then cans start falling.", FCVAR_NOTIFY, true, 1.0, true, 30.0);
    g_cvArtWarnTime.SetBounds(ConVarBound_Upper, true, 30.0);
    g_cvArtWarnTime.SetBounds(ConVarBound_Lower, true, 1.0);

    // v1.0.7: 光圈显示半径（收紧前原值档位）——瞄准圈/预警圈用，与轰炸半径解耦
    g_cvArtRingOut = CreateConVar("si_hud_art_ring_out", "750.0",
        "Ring display radius (units) for open-area aim/warning rings; actual can spread uses si_hud_art_radius_*.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRingOut.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRingOut.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArtRingMid = CreateConVar("si_hud_art_ring_mid", "525.0",
        "Ring display radius for ceiling >= 900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRingMid.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRingMid.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArtRingSmall = CreateConVar("si_hud_art_ring_small", "375.0",
        "Ring display radius for ceiling 600-900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRingSmall.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRingSmall.SetBounds(ConVarBound_Lower, true, 50.0);

    // v1.5.1: 复活套装（用户拍板：复活币死亡复活时发放固定装备 + 满血）
    g_cvRespawnGear = CreateConVar("sm_shop_respawn_gear",
        "weapon_rifle_m60,weapon_melee|fireaxe,weapon_pain_pills,weapon_pipe_bomb",
        "Respawn gear list (comma separated; melee uses weapon_melee|<script>). Empty = disabled.", FCVAR_NOTIFY);
    g_cvRespawnHealth = CreateConVar("sm_shop_respawn_health", "100",
        "Health to set on respawn (0 = leave engine default).", FCVAR_NOTIFY, true, 0.0, true, 100.0);

    AutoExecConfig(true, "l4d2_shop");

    // ── Commands ────────────────────────────────────────

    RegConsoleCmd("sm_shop", Cmd_Shop, "Open the score shop (spend score on supplies/weapons).");
    RegConsoleCmd("sm_buy", Cmd_Shop, "Open the score shop (spend score on supplies/weapons).");

    // v1.1.0: 空服实测脚手架——准星单瓶（admin；实测后按需保留）
    RegAdminCmd("sm_art3test", Cmd_Art3Test, ADMFLAG_ROOT,
        "[DEBUG] 火力支援III: spawn one bile jar at the crosshair (empty-server test).");
    // v1.2.0: 空服实测脚手架——准星单发榴弹（admin；实测后按需保留）
    RegAdminCmd("sm_art4test", Cmd_Art4Test, ADMFLAG_ROOT,
        "[DEBUG] 火力支援IV: spawn one grenade at the crosshair (empty-server test).");
    // v1.3.0: 空服实测脚手架——准星单件（admin；随机罐子或榴弹，走正式 kind=5 分流）
    RegAdminCmd("sm_art5test", Cmd_Art5Test, ADMFLAG_ROOT,
        "[DEBUG] 火力支援III-饱和轰炸: spawn one random mixed item at the crosshair (empty-server test).");
    // v1.6.0: 测试发分——直接写钱包（admin；sm_shop_give <名字> <积分>）
    RegAdminCmd("sm_shop_give", Cmd_ShopGive, ADMFLAG_ROOT,
        "[DEBUG] give wallet score: sm_shop_give <name> <amount>");

    // ── Events ──────────────────────────────────────────

    HookEvent("round_start",   Event_RoundStart);    // 换图/团灭重开 → 透视失效
    HookEvent("player_team",   Event_PlayerTeam);    // 闲置/换队 → 透视失效
    HookEvent("weapon_fire",   Event_WeaponFire);    // 火炮：任意开火 = 确认轰炸
    HookEvent("player_death",  Event_PlayerDeath);   // 幸存者死亡 → 透视失效

    // v1.7.85 FIX: reload 后 OnMapStart 不重跑 → g_iBeamLaser/g_iBeamHalo 归 0 →
    // 心跳 TE_SetupBeamRingPoint(0,...) 发送空模型索引 → segfault（17:28:36 第三方图
    // 瞄准中崩溃实锤 "Segmentation fault (core dumped)"）→ OnPluginStart 补 precache
    g_iBeamLaser = PrecacheModel("sprites/laserbeam.vmt");
    g_iBeamHalo = PrecacheModel("sprites/halo01.vmt");
    PrecacheModel("sprites/glow01.spr");

    g_hWitchList = new ArrayList();          // 透视特感 Witch 实体表（自家独立）
    WallhackClearGlow();                     // reload 安全网——清掉残留特感发光（防 reload 后光不灭）

    g_cvSIHudEnable = FindConVar("si_hud_enable");   // 总开关（可能为 null——si_hud 未加载）

    // v1.0.4 FIX: reload 时不触发 OnClientPutInServer → 已在服玩家补挂震退 hook
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            SDKHook(i, SDKHook_OnTakeDamage, Can_PlayerStagger);
    }

    LogMessage("[shop] loaded v%s — requires l4d2_si_hud >= v1.9.0 (SH_ API)", PLUGIN_VERSION);
}

// ============================================================================
// 绑定生命周期（懒绑定无需重刷句柄——只做加载完成时的可用性日志）
// ============================================================================

public void OnAllPluginsLoaded()
{
    if (!SH_Ready())
        LogMessage("[shop] si_hud API 不可用（si_hud 未加载或 < v1.9.0）——商店降级");
}

// ============================================================================
// OnMapStart — 商店物品模型 precache（非战役图不 precache → 物品隐形）
// ============================================================================

public void OnMapStart()
{
    // shop heavy weapons — precache models (non-campaign maps don't
    // precache M60 / grenade launcher; without this the items spawn invisible)
    PrecacheModel("models/w_models/weapons/w_m60.mdl");
    PrecacheModel("models/v_models/v_m60.mdl");
    PrecacheModel("models/w_models/weapons/w_grenade_launcher.mdl");
    PrecacheModel("models/v_models/v_grenade_launcher.mdl");
    // v1.7.44: chainsaw (电锯 5000)
    PrecacheModel("models/w_models/weapons/w_chainsaw.mdl");
    PrecacheModel("models/v_models/v_chainsaw.mdl");
    // v1.7.46b: 激光升级包附件模型（三方图可能缺 precache → 升级包隐形/不 spawn）
    PrecacheModel("models/w_models/weapons/w_laser_sights.mdl");
    // v1.7.72: 近战盲盒——12 把近战世界模型 precache（与 M60/榴弹同坑：
    // 非战役图不 precache → 生成的近战隐形）
    PrecacheModel("models/weapons/melee/w_bat.mdl");
    PrecacheModel("models/weapons/melee/w_cricket_bat.mdl");
    PrecacheModel("models/weapons/melee/w_crowbar.mdl");
    PrecacheModel("models/weapons/melee/w_guitar.mdl");
    PrecacheModel("models/weapons/melee/w_fireaxe.mdl");
    PrecacheModel("models/weapons/melee/w_frying_pan.mdl");
    PrecacheModel("models/weapons/melee/w_golfclub.mdl");
    PrecacheModel("models/weapons/melee/w_katana.mdl");
    PrecacheModel("models/weapons/melee/w_knife.mdl");
    PrecacheModel("models/weapons/melee/w_machete.mdl");
    PrecacheModel("models/weapons/melee/w_tonfa.mdl");
    PrecacheModel("models/weapons/melee/w_shovel.mdl");
    // v1.7.72: 烟花（道具类）——非战役图缺 precache 会隐形（M60/榴弹同坑）
    PrecacheModel("models/w_models/weapons/w_firework_crate.mdl");
    // v1.7.80: 火炮支援1——瞄准标记特效（TE 模型必须 precache，否则光柱/圆圈不渲染）
    g_iBeamLaser = PrecacheModel("sprites/laserbeam.vmt");
    g_iBeamHalo = PrecacheModel("sprites/halo01.vmt");
    PrecacheModel("sprites/glow01.spr");
    // v1.7.93: 火炮/商店罐子 = prop_physics + 罐模型（地图罐子等价物）→ 手动 precache 模型
    PrecacheModel("models/props_junk/propanecanister001a.mdl");
    PrecacheModel("models/props_equipment/oxygentank01.mdl");
    PrecacheModel("models/props_junk/gascan001a.mdl");          // v1.7.93: 商店汽油桶
    PrecacheModel("models/props_junk/explosive_box001.mdl");    // v1.7.93: 商店烟花
    // v1.7.85: 日志确认 precache 结果（reload 后 OnPluginStart 也 precache，防归 0）
    LogMessage("[artillery] beam precache laser=%d halo=%d", g_iBeamLaser, g_iBeamHalo);
}

// ============================================================================
// OnMapEnd / OnClientDisconnect / OnPluginEnd — 清理
// ============================================================================

public void OnMapEnd()
{
    // shop purchase counters reset per map
    for (int i = 1; i <= MaxClients; i++)
        for (int j = 0; j < SHOP_SLOTS; j++)
            g_iShopBought[i][j] = 0;
    Art_CleanupAll();                      // 换图清理残留火炮罐子/瞄准状态
}

public void OnClientPutInServer(int client)
{
    // v1.0.4: 玩家受伤 hook——油桶/烟花爆炸震退距离门控
    SDKHook(client, SDKHook_OnTakeDamage, Can_PlayerStagger);
}

public void OnClientDisconnect(int client)
{
    ArtEndDesignate(client, true);          // 断线取消火炮瞄准（退款须在 si_hud 存档前，见加载顺序说明）
    WallhackEnd(client, true);             // 断线清理透视（克隆/计时器）
    g_hShopMenu[client] = null;            // 断线菜单句柄失效
    // v1.7.31b fix: 限购计数断线清零（否则下个进服玩家继承"已购满"）
    for (int j = 0; j < SHOP_SLOTS; j++)
        g_iShopBought[client][j] = 0;
}

public void OnPluginEnd()
{
    WallhackEndAll();                        // 卸载/reload 清理透视
    Art_CleanupAll();                        // 卸载/reload 清理火炮瞄准状态/残留罐子
}

// ============================================================================
// Witch 实体表（自家独立维护；si_hud 另有同名列表供伤害 hook 用，互不共享）
// ============================================================================

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrContains(classname, "witch") == -1)
        return;
    if (entity <= 0)
        return;
    if (g_hWitchList != null && g_hWitchList.FindValue(entity) == -1)
        g_hWitchList.Push(entity);
}

// Witch 实体销毁时从表剔除（同步计时器每 tick 也会懒校验）
public void OnEntityDestroyed(int entity)
{
    if (g_hWitchList != null)
    {
        int idx = g_hWitchList.FindValue(entity);
        if (idx != -1)
            g_hWitchList.Erase(idx);
    }
}

bool IsWitchEntity(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char cls[32];
    GetEntityClassname(entity, cls, sizeof(cls));
    return (StrContains(cls, "witch") != -1);
}

// ============================================================================
// 事件：round_start / player_death — 透视生命周期（自 si_hud 移植）
// ============================================================================

// 换图/团灭重开 → 透视效果失效（静默）
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    WallhackEndAll();
    return Plugin_Continue;
}

// 幸存者死亡 → 透视效果丢失（用户规则）
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim >= 1 && victim <= MaxClients
        && IsClientInGame(victim) && GetClientTeam(victim) == 2)
    {
        if (g_bWallhack[victim])
            WallhackEnd(victim);
    }
    return Plugin_Continue;
}

// ============================================================================
// 商店核心：购买分发（守卫顺序与 si_hud v1.8.2 完全一致；钱包/复活币走 SH_ API）
// ============================================================================

public bool ShopTraceFilter(int entity, int contentsMask, any data)
{
    return entity != data;
}

// v1.7.93: 可爆炸类 classname → prop_physics 模型映射（返回 true = 可爆炸类）
bool Art_ExplosiveModel(const char[] cls, char[] model, int maxlen)
{
    if (StrEqual(cls, "weapon_propanetank"))
        strcopy(model, maxlen, "models/props_junk/propanecanister001a.mdl");
    else if (StrEqual(cls, "weapon_oxygentank"))
        strcopy(model, maxlen, "models/props_equipment/oxygentank01.mdl");
    else if (StrEqual(cls, "weapon_gascan"))
        strcopy(model, maxlen, "models/props_junk/gascan001a.mdl");
    else if (StrEqual(cls, "weapon_fireworkcrate"))
        strcopy(model, maxlen, "models/props_junk/explosive_box001.mdl");
    else
        return false;
    return true;
}

// v1.0.4: 爆炸震退触发半径分级（用户拍板：震退保留，按现实逻辑分档——
// "油桶爆炸存在动能，震退合理；但必须贴得足够近才触发"）。
// v1.0.5: 两档——油桶/烟花 100u（gascan001a/explosive_box001）、
// 瓦斯/煤气 200u（propanecanister001a/oxygentank01）。
// 返回 0=非爆炸罐子 1=油桶/烟花 2=瓦斯/煤气（商店/火炮/地图统一处理）。
int Art_CanType(int ent)
{
    if (ent <= MaxClients || !IsValidEntity(ent))
        return 0;
    char cls[64];
    GetEntityClassname(ent, cls, sizeof(cls));
    if (StrContains(cls, "prop_physics") == -1)
        return 0;
    char model[PLATFORM_MAX_PATH];
    GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
    if (StrEqual(model, "models/props_junk/gascan001a.mdl")
        || StrEqual(model, "models/props_junk/explosive_box001.mdl"))
        return 1;
    if (StrEqual(model, "models/props_junk/propanecanister001a.mdl")
        || StrEqual(model, "models/props_equipment/oxygentank01.mdl"))
        return 2;
    return 0;
}

// v1.0.4: 玩家受伤距离门控——罐子爆炸（DMG_BLAST）按距爆炸源距离决定是否
// 保留震退（stagger 随 DMG_BLAST 位触发；抹位只去震退，伤害保留）。
public Action Can_PlayerStagger(int victim, int &attacker, int &inflictor,
    float &damage, int &damagetype)
{
    if (!(damagetype & DMG_BLAST))
        return Plugin_Continue;

    int src = 0;
    int type = 0;
    if (inflictor > MaxClients)
        type = Art_CanType(inflictor);
    if (type != 0)
        src = inflictor;
    else if (attacker > MaxClients)
    {
        type = Art_CanType(attacker);
        if (type != 0)
            src = attacker;
    }
    if (src == 0)
        return Plugin_Continue;                     // 非罐子爆炸：原样

    float limit = (type == 1) ? g_cvArtNkRadiusOil.FloatValue : g_cvArtNkRadiusGas.FloatValue;
    float canPos[3], plyPos[3];
    GetEntPropVector(src, Prop_Data, "m_vecAbsOrigin", canPos);
    GetClientAbsOrigin(victim, plyPos);
    if (GetVectorDistance(canPos, plyPos) > limit)
        damagetype &= ~DMG_BLAST;                   // 远处：只受伤，不震退
    return Plugin_Changed;
}

// spawn 单个商品（trace 落地面 + glow + 重武器弹药）
int ShopSpawn(const char[] cls, float pos[3])
{
    // v1.7.93: 可爆炸类商品（罐/桶/烟花）直接生成 prop_physics + 对应模型
    // （= 地图罐子等价物，可捡可扔可炸）：死亡/点燃过热 → 引擎爆炸。
    // weapon_* 类名不可 break/ignite/explode（v1.7.92 give+drop 转换依赖
    // 槽位/拾取竞态，弃用——见 Timer_ArtSpawnCan v1.7.93 注释）。
    char model[PLATFORM_MAX_PATH];
    bool explosive = Art_ExplosiveModel(cls, model, sizeof(model));

    int ent;
    if (explosive)
    {
        ent = CreateEntityByName("prop_physics");
        if (ent != -1)
            DispatchKeyValue(ent, "model", model);
    }
    else
    {
        ent = CreateEntityByName(cls);
    }
    if (ent == -1) return -1;

    float from[3], to[3];
    from = pos;
    from[2] += 60.0;
    Handle tr = TR_TraceRayFilterEx(from, view_as<float>({ 90.0, 0.0, 0.0 }),
        MASK_SOLID, RayType_Infinite, ShopTraceFilter, ent);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(to, tr);
        to[2] += 5.0;
    }
    else
    {
        to = from;
    }
    delete tr;

    DispatchSpawn(ent);
    TeleportEntity(ent, to, NULL_VECTOR, NULL_VECTOR);

    if (StrEqual(cls, "weapon_grenade_launcher"))
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 30);
    else if (StrEqual(cls, "weapon_rifle_m60"))
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 150);

    SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
    SetEntProp(ent, Prop_Send, "m_nGlowRange", 800);
    SetEntProp(ent, Prop_Send, "m_glowColorOverride", 50 | (255 << 8) | (50 << 16) | (255 << 24));

    // v1.7.93: 可爆炸类商品（瓦斯罐/煤气罐/汽油桶/烟花）——prop_physics 罐子
    // 强制可破坏（正血量），枪直接打爆走引擎死亡爆炸（原版音效/伤害/友伤缩放）。
    // 普通武器（M60/电锯等）不可破坏，不在此列。
    if (explosive)
    {
        SetEntProp(ent, Prop_Data, "m_takedamage", 2);
        SetEntProp(ent, Prop_Data, "m_iHealth", 100);
    }

    return ent;
}

// v1.7.72: 近战盲盒——生成指定近战武器（melee_script_name keyvalue 必须
// 在 DispatchSpawn 前；trace 落地面 + glow 与 ShopSpawn 一致）
int SpawnMelee(const char[] meleeName, float pos[3])
{
    int ent = CreateEntityByName("weapon_melee");
    if (ent == -1)
        return -1;

    // v1.7.77 FIX: 只用 melee_script_name keyvalue（v1.7.76 加的双保险
    // SetEntPropString m_MeleeWeaponName 在 spawn 前不存在该 prop →
    // 抛异常：不生成 + 购买后菜单不重开，日志实锤 "Property not found"）
    DispatchKeyValue(ent, "melee_script_name", meleeName);
    LogMessage("[melee-box] spawn melee=%s ent=%d", meleeName, ent);

    float from[3], to[3];
    from = pos;
    from[2] += 60.0;
    Handle tr = TR_TraceRayFilterEx(from, view_as<float>({ 90.0, 0.0, 0.0 }),
        MASK_SOLID, RayType_Infinite, ShopTraceFilter, ent);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(to, tr);
        to[2] += 5.0;
    }
    else
    {
        to = from;
    }
    delete tr;

    DispatchSpawn(ent);
    TeleportEntity(ent, to, NULL_VECTOR, NULL_VECTOR);

    SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
    SetEntProp(ent, Prop_Send, "m_nGlowRange", 800);
    SetEntProp(ent, Prop_Send, "m_glowColorOverride", 50 | (255 << 8) | (50 << 16) | (255 << 24));

    return ent;
}

// ============================================================================
// v1.5.1: 复活套装 — 监听 si_hud v1.9.2 的 SH_OnClientRespawned 全局 forward
// （复活币死亡复活完成、确认存活后触发；闲置/接管引擎自管不在此列）。
// 用户拍板固定配置：M60 + 消防斧 + 止痛药 + 土质炸弹，复活满血 100。
// ============================================================================
public void SH_OnClientRespawned(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return;
    if (GetClientTeam(client) != 2 || !IsPlayerAlive(client))
        return;

    char gear[256];
    g_cvRespawnGear.GetString(gear, sizeof(gear));
    if (gear[0] != '\0')
    {
        char items[8][64];
        int count = ExplodeString(gear, ",", items, sizeof(items), sizeof(items[]));
        for (int i = 0; i < count; i++)
        {
            TrimString(items[i]);
            if (items[i][0] == '\0')
                continue;

            // 近战:weapon_melee|fireaxe（melee_script_name 键值，与 SpawnMelee 同法）
            char parts[2][64];
            if (ExplodeString(items[i], "|", parts, sizeof(parts), sizeof(parts[])) == 2)
            {
                int ent = CreateEntityByName("weapon_melee");
                if (ent == -1)
                    continue;
                DispatchKeyValue(ent, "melee_script_name", parts[1]);
                DispatchSpawn(ent);
                EquipPlayerWeapon(client, ent);
                LogMessage("[respawn-gear] %N melee=%s ent=%d", client, parts[1], ent);
            }
            else
            {
                int ent = GivePlayerItem(client, items[i]);
                if (ent != -1)
                {
                    EquipPlayerWeapon(client, ent);
                    LogMessage("[respawn-gear] %N item=%s ent=%d", client, items[i], ent);
                }
                else
                {
                    LogMessage("[respawn-gear] %N item=%s FAILED", client, items[i]);
                }
            }
        }
    }

    int hp = g_cvRespawnHealth.IntValue;
    if (hp > 0)
    {
        SetEntityHealth(client, hp);
        LogMessage("[respawn-gear] %N hp=%d", client, hp);
    }
}

void ShopBuy(int client, int slot)
{
    if (slot < 0 || slot >= SHOP_SLOTS) return;
    if (!IsClientInGame(client) || GetClientTeam(client) != 2) return;
    if (!SH_Ready()) return;                 // si_hud 已卸载（菜单开着时）——静默放弃

    // DEBUG v1.7.43b: 全量购买日志（排障激光分支不执行）
    LogMessage("[shop-buy] client=%N slot=%d cls='%s' price=%d wallet=%d",
        client, slot, g_ShopTable[slot].classname, g_ShopTable[slot].price, SH_GetWallet(client));

    int price = g_ShopTable[slot].price;
    if (SH_GetWallet(client) < price)
    {
        PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 需要 \x03%d\x01 当前积分，你只有 \x03%d\x01",
            g_ShopTable[slot].name, price, SH_GetWallet(client));
        return;
    }
    if (g_ShopTable[slot].limit > 0
        && g_iShopBought[client][slot] >= g_ShopTable[slot].limit)
    {
        PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 本图已购满（%d/%d）",
            g_ShopTable[slot].name, g_iShopBought[client][slot], g_ShopTable[slot].limit);
        return;
    }

    // 复活币持有上限检查（必须在扣款前——v1.7.31b fix：原来在扣款后，
    // 达上限购买会扣分不给币）
    if (g_ShopTable[slot].classname[0] == '\0'
        && SH_GetReviveCoins(client) >= SH_GetCoinMax())
    {
        PrintToChat(client, "\x04[商店]\x01 复活币已达持有上限 \x03%d\x01 枚，无法再购买",
            SH_GetCoinMax());
        return;
    }

    // v1.0.10: 透视特感——生效期间不可重复购买（用户定稿；去掉续费/900s 封顶）
    if (StrEqual(g_ShopTable[slot].classname, "wallhack") && g_bWallhack[client])
    {
        PrintToChat(client, "\x04[商店]\x01 特感透视正在生效中，无法重复购买（剩余 \x03%d\x01 秒）",
            RoundToCeil(g_fWallhackEnd[client] - GetGameTime()));
        return;
    }

    // v1.7.78: 激光——主武器已有激光 → 拦截（扣款前检查；用户实测重复购买
    // 会白扣款）
    if (StrEqual(g_ShopTable[slot].classname, "weapon_upgradepack_laser_sight"))
    {
        int weapon = GetPlayerWeaponSlot(client, 0);
        if (weapon > 0 && IsValidEntity(weapon))
        {
            int upgrade = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
            if (upgrade & 4)   // 位值 4 = 激光（1=燃烧弹 2=高爆弹 4=激光）
            {
                PrintToChat(client, "\x04[商店]\x01 你的主武器已装备激光，无需重复购买");
                return;
            }
        }
    }

    SH_AddWallet(client, -price);
    g_iShopBought[client][slot]++;

    // 复活币（classname 空）：不 spawn 物品，余额 +1 枚（战役内保留）
    if (g_ShopTable[slot].classname[0] == '\0')
    {
        int coins = SH_AddReviveCoins(client, 1);
        // v1.2.4 (bug): 复活判定只响应 player_death——已躺尸玩家买币后
        // 不会再有死亡事件，币白买。SH_ReviveClient 对真死亡玩家消耗刚买
        // 的币立即安排复活（内部播报倒计时）；存活玩家返回 0 正常囤积
        bool revived = (SH_ReviveClient(client) == 1);
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05复活币\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），复活币余额 \x03%d\x01 枚%s",
            price, SH_GetWallet(client), coins,
            revived ? "——复活币已生效，即将复活" : "");
        return;
    }

    // v1.7.49: 激光直接上主武器——L4D2 激光 = 武器升级位 m_upgradeBitVec
    // （netprops dump 实锤 offset 6116, networked）。位值：1=燃烧弹 2=高爆弹 4=激光。
    // 排障链（2026-08-02）：SetEntProp m_bHasLaserSight 无此 prop / upgrade_laser_sight
    // 脚下 spawn 被用户否决（激光堆拾取物）/ SDKCall SetHasLaserSight 是 CS:GO 符号不存在。
    if (StrEqual(g_ShopTable[slot].classname, "weapon_upgradepack_laser_sight"))
    {
        int weapon = GetPlayerWeaponSlot(client, 0);
        if (weapon <= 0 || !IsValidEntity(weapon))
        {
            // 无主武器（异常）——退款
            SH_AddWallet(client, price);
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 购买失败（未持有武器），积分已退回");
            return;
        }

        int upgrade = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
        SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", upgrade | 4);
        LogMessage("[shop-laser] m_upgradeBitVec %d -> %d weapon=%d client=%N",
            upgrade, upgrade | 4, weapon, client);
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05激光瞄准\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），激光已装备到当前主武器",
            price, SH_GetWallet(client));
        return;
    }

    // v1.7.64: 透视特感——不 spawn 物品，直接激活购买者视角（5 分钟）
    if (StrEqual(g_ShopTable[slot].classname, "wallhack"))
    {
        WallhackStart(client, price);
        return;
    }

    // v1.7.72: 近战盲盒——随机掉落一把非电锯近战武器
    if (StrEqual(g_ShopTable[slot].classname, "melee_box"))
    {
        char picked[32];
        strcopy(picked, sizeof(picked), g_MeleePool[GetRandomInt(0, MELEE_POOL_COUNT - 1)]);

        float pos[3], ang[3], fwd[3];
        GetClientEyePosition(client, pos);
        GetClientEyeAngles(client, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        pos[0] += fwd[0] * 70.0;
        pos[1] += fwd[1] * 70.0;
        pos[2] -= 20.0;

        int ent = SpawnMelee(picked, pos);
        if (ent <= 0)
        {
            SH_AddWallet(client, price);
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 近战盲盒生成失败，积分已退回");
            return;
        }
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05近战盲盒\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01）：开出 \x05%s\x01",
            price, SH_GetWallet(client), picked);
        return;
    }

    // v1.7.80: 火炮支援1/2/3/4——进入瞄准指示（射击确认轰炸）。
    // 不 spawn 实体；扣款已在上游完成，取消/超时/死亡/断线由 ArtEndDesignate 退款。
    // v1.7.98: 支援2 = 油桶/烟花模型池；v1.1.0: 支援3 = 胆汁瓶雨（kind=3）；
    // v1.2.0: 支援4 = 榴弹雨（kind=4）
    if (StrEqual(g_ShopTable[slot].classname, "artillery")
        || StrEqual(g_ShopTable[slot].classname, "artillery2")
        || StrEqual(g_ShopTable[slot].classname, "artillery3")
        || StrEqual(g_ShopTable[slot].classname, "artillery4")
        || StrEqual(g_ShopTable[slot].classname, "artillery5"))
    {
        // v1.7.82: 倒地/死亡状态拦截（用户边界审查）——倒地/死亡无法开火确认，
        // 买了也立即被心跳退款，直接拒绝更清晰
        if (!IsPlayerAlive(client))
        {
            SH_AddWallet(client, price);
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 倒地/死亡状态无法使用\x05%s\x01，积分已退回",
                g_ShopTable[slot].name);
            return;
        }
        // v1.7.80: 全局硬冷却——轰炸中/结束后 si_hud_art_cooldown 秒内全体禁止购买（用户拍板）
        float wait = g_fArtNextBuyTime - GetGameTime();
        if (!g_cvArtEnable.BoolValue || wait > 0.0)
        {
            SH_AddWallet(client, price);
            g_iShopBought[client][slot]--;
            if (wait > 0.0)
                PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 冷却中，\x03%d\x01 秒后可购买",
                    g_ShopTable[slot].name, RoundToCeil(wait));
            else
                PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 不可用，积分已退回",
                    g_ShopTable[slot].name);
            return;
        }
        if (g_bArtAiming[client])
        {
            SH_AddWallet(client, price);
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 你已在瞄准中，请先确认或取消（右键）");
            return;
        }
        // v1.2.1: 支援III 检查 left4dhooks native 可用性——失败拒绝购买退款（防白花钱）
        if (StrEqual(g_ShopTable[slot].classname, "artillery3"))
        {
            Art3_CheckNatives();
            if (g_bArt3NativesFail)
            {
                SH_AddWallet(client, price);
                g_iShopBought[client][slot]--;
                PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 暂不可用（left4dhooks 未加载），积分已退回",
                    g_ShopTable[slot].name);
                return;
            }
        }
        // v1.2.0: 支援IV 检查 left4dhooks native 可用性——失败拒绝购买退款（防白花钱）
        // v1.3.0: 支援V 混合含榴弹路径 → 与支援IV 同检查
        if (StrEqual(g_ShopTable[slot].classname, "artillery4")
            || StrEqual(g_ShopTable[slot].classname, "artillery5"))
        {
            Art4_CheckNatives();
            if (g_bArt4NativesFail)
            {
                SH_AddWallet(client, price);
                g_iShopBought[client][slot]--;
                PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 暂不可用（left4dhooks 未加载），积分已退回",
                    g_ShopTable[slot].name);
                return;
            }
        }
        ArtStartDesignate(client, slot, price);
        return;
    }

    // 落点：玩家面前 70 单位（购买时刻的方向）
    float pos[3], ang[3], fwd[3];
    GetClientEyePosition(client, pos);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    pos[0] += fwd[0] * 70.0;
    pos[1] += fwd[1] * 70.0;
    pos[2] -= 20.0;

    ShopSpawn(g_ShopTable[slot].classname, pos);   // v1.7.93: 可爆炸类商品直接生成 prop_physics

    PrintToChat(client, "\x04[商店]\x01 已购买 \x05%s\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），物品已放在你面前",
        g_ShopTable[slot].name, price, SH_GetWallet(client));
}

// ============================================================================
// 商店菜单（分类 → 商品；VguiMenu 标题必须单行）
// ============================================================================

void OpenShopMenu(int client)
{
    Menu menu = new Menu(ShopCatMenuHandler);
    // v1.7.32c FIX: title 必须单行 — L4D2 VguiMenu 标题不支持 \n，
    // 多行标题 → 整个菜单不渲染（用户实测 !buy 无反应，!csm 的 Panel 单行正常）
    menu.SetTitle("商店: 可用积分 %d  复活币 %d 枚",
        SH_GetWallet(client), SH_GetReviveCoins(client));
    menu.AddItem("0", "武器类");
    menu.AddItem("1", "道具类");
    menu.AddItem("2", "补给品");    // v1.4.6: 原"医疗类"改名（含医疗+弹药升级包）
    menu.AddItem("5", "投掷品");      // v1.4.7: 第 4 类（cat 值 5：胆汁/土质炸弹/燃烧瓶）
    menu.AddItem("4", "火力支援");    // v1.4.6: 第 5 类（cat 值 4）
    menu.AddItem("3", "其他");        // v1.4.6: 第 6 类（cat 值 3）
    menu.ExitButton = true;
    g_hShopMenu[client] = menu;
    menu.Display(client, 20);
}

void ShopCategoryMenu(int client, int cat)
{
    if (cat < 0 || cat > 5) cat = 5;
    g_iShopCat[client] = cat;
    char catNames[6][16] = { "武器类", "道具类", "补给品", "其他", "火力支援", "投掷品" };   // v1.4.6/v1.4.7: 医疗类→补给品、投掷→投掷品
    Menu menu = new Menu(ShopItemMenuHandler);
    char title[96];
    Format(title, sizeof(title), "%s: 可用积分 %d  复活币 %d 枚",
        catNames[cat], SH_GetWallet(client), SH_GetReviveCoins(client));
    menu.SetTitle(title);

    char info[4];
    char line[96];
    // v1.8.1: 商品按价格升序展示（用户需求）——收集分类内槽位下标，插入排序
    int slots[SHOP_SLOTS];
    int count = 0;
    for (int i = 0; i < SHOP_SLOTS; i++)
    {
        if (g_ShopTable[i].cat == cat)
            slots[count++] = i;
    }
    for (int a = 1; a < count; a++)
    {
        int key = slots[a];
        int j = a - 1;
        while (j >= 0 && g_ShopTable[slots[j]].price > g_ShopTable[key].price)
        {
            slots[j + 1] = slots[j];
            j--;
        }
        slots[j + 1] = key;
    }
    for (int k = 0; k < count; k++)
    {
        int i = slots[k];
        int price = g_ShopTable[i].price;
        int limit = g_ShopTable[i].limit;
        if (i == WALLHACK_SLOT && g_bWallhack[client])
        {
            // v1.0.10: 生效期间不可重复购买 → 标签去掉"可续费"
            Format(line, sizeof(line), "%s (%d分) [透视生效中]", g_ShopTable[i].name, price);
        }
        else if (limit <= 0)
        {
            if (SH_GetWallet(client) < price)
                Format(line, sizeof(line), "%s (%d分) [积分不足]", g_ShopTable[i].name, price);
            else
                Format(line, sizeof(line), "%s (%d分) [无限购]", g_ShopTable[i].name, price);
        }
        else
        {
            int left = limit - g_iShopBought[client][i];
            if (left <= 0)
                Format(line, sizeof(line), "%s (%d分) [已购满]", g_ShopTable[i].name, price);
            else if (SH_GetWallet(client) < price)
                Format(line, sizeof(line), "%s (%d分) [积分不足]", g_ShopTable[i].name, price);
            else
                Format(line, sizeof(line), "%s (%d分) [可购 x%d]", g_ShopTable[i].name, price, left);
        }

        IntToString(i, info, sizeof(info));
        menu.AddItem(info, line);
    }
    // v1.7.75: 用 SM 原生按钮——ExitBackButton=8 返回上一页（社区插件同款，
    // 见 survivor_chat_select.sp 注释"显示数字8返回上一页选项"），ExitButton
    // 退出。原生按钮不占商品槽位 → 位置恒定 8/9 且无填充空行
    // （v1.7.73 自定义项位置漂移；v1.7.74 空白占位渲染出空行，均废弃）
    menu.ExitBackButton = true;
    menu.ExitButton = true;
    g_hShopMenu[client] = menu;
    menu.Display(client, 20);
}

public int ShopCatMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    // CancelMenu 触发的回调 client/item 是 -3（取消标记）——必须挡在 GetItem 前，
    // 否则数组越界崩溃（用户实测 !buy 关不掉菜单，日志 index -3 实锤）
    if (action == MenuAction_Select && item >= 0 && client >= 1)
    {
        char info[4];
        menu.GetItem(item, info, sizeof(info));
        ShopCategoryMenu(client, StringToInt(info));
    }
    else if (action == MenuAction_Cancel || action == MenuAction_End)
    {
        if (client >= 1 && g_hShopMenu[client] == menu)   // 只清自己（旧菜单 End 不覆盖新菜单句柄）
            g_hShopMenu[client] = null;
        if (action == MenuAction_End)   // 只删一次（Cancel 后必跟 End）
            delete menu;
    }
    return 0;
}

public int ShopItemMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    // CancelMenu 触发回调时 client/item 是 -3——同上防护
    if (action == MenuAction_Select && item >= 0 && client >= 1)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        ShopBuy(client, StringToInt(info));
        if (IsClientInGame(client) && !g_bArtAiming[client])   // 火炮瞄准中不重开菜单（避免遮挡瞄准视野）
            ShopCategoryMenu(client, g_iShopCat[client]);   // 刷新余额/状态（留在当前分类）
    }
    else if (action == MenuAction_Cancel || action == MenuAction_End)
    {
        // v1.7.75: 原生 8=返回上一页（MenuCancel_ExitBack）——重开分类页
        if (action == MenuAction_Cancel && item == MenuCancel_ExitBack && client >= 1)
        {
            OpenShopMenu(client);
            return 0;
        }
        if (client >= 1 && g_hShopMenu[client] == menu)   // 只清自己（旧菜单 End 不覆盖新菜单句柄）
            g_hShopMenu[client] = null;
        if (action == MenuAction_End)   // 只删一次（Cancel 后必跟 End）
            delete menu;
    }
    return 0;
}

// v1.6.0: 测试发分——sm_shop_give <名字> <积分>（直接改钱包，不经过购买链路）
// 注意：SRCDS 控制台会把中文名按字节拆成多个 arg（粟藜 → 多段），故不走
// GetCmdArg(1/2)，用整串解析：末段 = 积分，其余段去掉空格拼回名字。
public Action Cmd_ShopGive(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[商店] 用法: sm_shop_give <名字> <积分>");
        return Plugin_Handled;
    }
    char full[160];
    GetCmdArgString(full, sizeof(full));

    int pos = -1;
    for (int i = strlen(full) - 1; i >= 0; i--)
    {
        if (full[i] == ' ')
        {
            pos = i;
            break;
        }
    }
    if (pos <= 0)
    {
        ReplyToCommand(client, "[商店] 用法: sm_shop_give <名字> <积分>");
        return Plugin_Handled;
    }

    char amt[16];
    strcopy(amt, sizeof(amt), full[pos + 1]);
    int amount = StringToInt(amt);
    if (amount == 0)
    {
        ReplyToCommand(client, "[商店] 积分必须非 0");
        return Plugin_Handled;
    }

    char name[96];
    int n = 0;
    for (int i = 0; i < pos; i++)
    {
        if (full[i] != ' ')                    // 多 token 拼接（中文名拆分场景）
            name[n++] = full[i];
    }
    name[n] = '\0';

    int target = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        char cname[64];
        GetClientName(i, cname, sizeof(cname));
        if (StrEqual(cname, name, false))
        {
            target = i;                        // 精确命中优先
            break;
        }
        if (target == 0 && StrContains(cname, name, false) == 0)
            target = i;                        // 前缀匹配（小服够用）
    }
    if (target == 0)
    {
        ReplyToCommand(client, "[商店] 找不到玩家 \"%s\"", name);
        return Plugin_Handled;
    }

    int before = SH_GetWallet(target);
    SH_AddWallet(target, amount);
    int after = SH_GetWallet(target);
    LogMessage("[shop] give client=%N amount=%d wallet %d -> %d", target, amount, before, after);
    ReplyToCommand(client, "[商店] 已给 %N 发 %d 积分（%d → %d）", target, amount, before, after);
    PrintToChat(target, "\x04[商店]\x01 管理员给你发放 \x03%d\x01 积分（当前 \x04%d\x01）", amount, after);
    return Plugin_Handled;
}

public Action Cmd_Shop(int client, int args)
{
    if (client < 1 || !IsClientInGame(client))
        return Plugin_Handled;
    // v1.7.77: 关闭方式定稿——数字 9 关闭键（原生 ExitButton，与其他服务器
    // 一致）+ 20s 超时自动关。!buy 二次输入关不掉面板（L4D2 vgui 实测），
    // 废弃"二次输入关闭"（原 CancelClientMenu 方案），重复输入只重开菜单
    if (!SH_Ready())
    {
        PrintToChat(client, "\x04[商店]\x01 商店不可用（计分系统未加载）");
        return Plugin_Handled;
    }
    if (!g_cvShopEnable.BoolValue
        || (g_cvSIHudEnable != null && !g_cvSIHudEnable.BoolValue))
    {
        PrintToChat(client, "\x04[商店]\x01 商店未开启");
        return Plugin_Handled;
    }
    if (GetClientTeam(client) != 2)
    {
        PrintToChat(client, "\x04[商店]\x01 只有幸存者可以使用商店");
        return Plugin_Handled;
    }
    OpenShopMenu(client);
    return Plugin_Handled;
}

// ============================================================================
// v1.7.67: 透视特感（!shop 特殊商品）——全局蓝色高亮（用户定稿 2026-08-02）
// 直接给特感实体加发光（与商店物品同机制 m_iGlowType 3 + 颜色）——轮廓完美
// 贴合动作。克隆方案已废弃（prop 不播特感动画 → 冻结人偶轮廓，用户否决）。
// 全队可见（co-op 团队增益）；任一购买者生效 → 全部特感蓝色；最后一位结束
// → 清光。价格 4000 / 5 分钟（v1.0.10: 生效期间不可重复购买，时长恒 300s）。
// ============================================================================

void WallhackStart(int client, int price)
{
    // v1.0.10: ShopBuy 已拦截生效中重复购买 → 无续费路径，时长恒 WALLHACK_DURATION
    float total = WALLHACK_DURATION;
    float now = GetGameTime();

    g_bWallhack[client] = true;
    g_fWallhackEnd[client] = now + total;

    // 到期计时器
    if (g_hWallhackTimer[client] != null)
    {
        KillTimer(g_hWallhackTimer[client]);
        g_hWallhackTimer[client] = null;
    }
    g_hWallhackTimer[client] = CreateTimer(total, Timer_WallhackExpire,
        GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    // v1.7.68: 结束前 30 秒提醒（一次性；剩余不足 30s 不排）
    if (g_hWallhackWarnTimer[client] != null)
    {
        KillTimer(g_hWallhackWarnTimer[client]);
        g_hWallhackWarnTimer[client] = null;
    }
    if (total > 30.0)
        g_hWallhackWarnTimer[client] = CreateTimer(total - 30.0, Timer_WallhackWarn,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    if (g_hWallhackSyncTimer == null)
        g_hWallhackSyncTimer = CreateTimer(0.5, Timer_WallhackSync, INVALID_HANDLE, TIMER_REPEAT);

    LogMessage("[wallhack] start client=%N wallet=%d total=%.0fs",
        client, SH_GetWallet(client), total);

    // v1.0.10: 聊天只留扣费信息；提示改屏幕中央 textprint（用户定稿文案）——
    // priming 占位后 0.1s 替换成真消息（记忆 l4d2-printhinttext-priming-bug）
    PrintToChat(client, "\x04[商店]\x01 已购买 \x05透视特感\x01（-\x03%d\x01 可用积分）。",
        price);
    PrintHintText(client, " ");
    CreateTimer(0.1, Timer_WallhackTeach, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    // v1.7.68: 全服播报购买（y 键聊天可见）
    PrintToChatAll("\x04[商店]\x01 \x05%N\x01 购买了特感透视（\x03%d\x01 秒）",
        client, RoundToNearest(total));
    WallhackApplyGlow();   // 立即上光（不等首 tick）
}

// v1.0.10: 购买透视后的 textprint 教学（用户定稿："特感透视已开启持续300秒"）
public Action Timer_WallhackTeach(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Stop;
    PrintHintText(client, "[商店] 特感透视已开启持续%d秒", RoundToNearest(WALLHACK_DURATION));
    return Plugin_Stop;
}

// 给当前所有特感/Witch 上蓝色发光（幂等——新刷新的特感由心跳计时器自动补光）
void WallhackApplyGlow()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != 3)
            continue;
        SetEntProp(i, Prop_Send, "m_iGlowType", 3);
        SetEntProp(i, Prop_Send, "m_nGlowRange", 999999);
        SetEntProp(i, Prop_Send, "m_nGlowRangeMin", 0);
        SetEntProp(i, Prop_Send, "m_glowColorOverride", 0 | (0 << 8) | (255 << 16) | (255 << 24));  // 蓝
    }
    for (int i = 0; i < g_hWitchList.Length; i++)
    {
        int w = g_hWitchList.Get(i);
        if (!IsValidEntity(w) || !IsWitchEntity(w))
        {
            g_hWitchList.Erase(i--);
            continue;
        }
        SetEntProp(w, Prop_Send, "m_iGlowType", 3);
        SetEntProp(w, Prop_Send, "m_nGlowRange", 999999);
        SetEntProp(w, Prop_Send, "m_nGlowRangeMin", 0);
        SetEntProp(w, Prop_Send, "m_glowColorOverride", 0 | (0 << 8) | (255 << 16) | (255 << 24));  // 蓝
    }
}

void WallhackClearGlow()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != 3)
            continue;
        SetEntProp(i, Prop_Send, "m_iGlowType", 0);
    }
    for (int i = 0; i < g_hWitchList.Length; i++)
    {
        int w = g_hWitchList.Get(i);
        if (IsValidEntity(w) && IsWitchEntity(w))
            SetEntProp(w, Prop_Send, "m_iGlowType", 0);
    }
}

void WallhackEnd(int client, bool silent = false)
{
    g_bWallhack[client] = false;
    g_fWallhackEnd[client] = 0.0;   // v1.7.69: 累计清零
    if (g_hWallhackTimer[client] != null)
    {
        KillTimer(g_hWallhackTimer[client]);
        g_hWallhackTimer[client] = null;
    }
    if (g_hWallhackWarnTimer[client] != null)
    {
        KillTimer(g_hWallhackWarnTimer[client]);
        g_hWallhackWarnTimer[client] = null;
    }
    LogMessage("[wallhack] end client=%N silent=%d", client, silent ? 1 : 0);
    // 若已无任何购买者 → 立即清光（不等心跳下 tick）
    bool any = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bWallhack[i])
        {
            any = true;
            break;
        }
    }
    if (!any)
        WallhackClearGlow();
    if (!silent && IsClientInGame(client))
        PrintToChat(client, "\x04[商店]\x01 透视特感效果已结束");
}

void WallhackEndAll()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bWallhack[i])
            WallhackEnd(i, true);
    }
}

// 0.5s 心跳：有购买者 → 补光新刷新的特感/Witch；无购买者 → 清光停表
Action Timer_WallhackSync(Handle timer)
{
    bool any = false;
    for (int b = 1; b <= MaxClients; b++)
    {
        if (g_bWallhack[b])
        {
            any = true;
            break;
        }
    }
    if (!any)
    {
        WallhackClearGlow();   // 最后一位失效时清光
        g_hWallhackSyncTimer = null;
        return Plugin_Stop;
    }
    WallhackApplyGlow();
    return Plugin_Continue;
}

Action Timer_WallhackExpire(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client >= 1 && client <= MaxClients)
    {
        g_hWallhackTimer[client] = null;   // 先置空，避免 WallhackEnd 自杀计时器
        WallhackEnd(client);
    }
    return Plugin_Continue;
}

// v1.7.68: 结束前 30 秒全服提醒（y 键聊天可见）
Action Timer_WallhackWarn(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client >= 1 && client <= MaxClients && g_bWallhack[client])
    {
        g_hWallhackWarnTimer[client] = null;   // 一次性——先置空防 WallhackEnd 杀已关句柄
        PrintToChatAll("\x04[商店]\x01 特感透视剩余 \x0330\x01 秒");
    }
    return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;
    if (event.GetInt("team") != 2 && g_bWallhack[client])   // 闲置/旁观/换队 → 透视失效
        WallhackEnd(client);
    return Plugin_Continue;
}

// ============================================================================
// v1.7.80: 火炮支援1/2（!shop 特殊商品「artillery」/「artillery2」）——BFV 式目标指示轰炸
//
// 交互（v1.7.95 用户拍板简化）：购买 → 扣款 → 准星瞄准处显示爆炸半径圆圈+
//   光柱+光点（全队可见；天花板 <600 或瞄天空 → 变红无效）→ 玩家当前武器
//   任意开火（weapon_fire）= 确认轰炸 → 右键 / 15s 超时 / 死亡 / 断线 → 取消
//   退款。
// 轰炸（v1.7.96 按秒随机）：着火的 prop_physics + 罐模型（I: 70% 瓦斯罐/30%
//   煤气罐；II: 70% 油桶/30% 烟花）从高空坠落，si_hud_art_duration 秒内每秒
//   随机 2-3 罐 → 落地时刻定时器强制引爆（v1.7.94: attacker=inflictor=罐子自身，
//   召唤者/队友全吃伤害；v1.7.97: inflictor=buyer 击杀归属=召唤者）→ 原版爆炸
//   伤害（全伤害，含队友，受友伤规则）。
// 室内自适应：天花板 ≥900 → 吊顶下 150u 生成，半径缩到 525；600-900 → 375；
//   落罐密度不变（用户拍板 2-3 罐/秒）；<600 或瞄天空 → 无效（红圈，确认被拒，
//   留在瞄准模式）。天花板阈值 600/900/4096 与 70/30 罐型比例写死。
// 全局状态/常量声明在文件头部（ShopBuy 提前引用）。
// ============================================================================

// 进入瞄准指示：创建标记 + 启动心跳（v1.7.95: 不再切换马格南——玩家当前武器
// 任意开火即确认，右键取消；彻底消除切枪/恢复武器的问题）
void ArtStartDesignate(int client, int slot, int price)
{
    g_iArtSlot[client] = slot;
    g_iArtPrice[client] = price;
    g_fArtAimEnd[client] = GetGameTime() + g_cvArtTargetTime.FloatValue;

    // 标记光点（env_sprite，全队可见；颜色随合法性心跳更新）
    int sprite = CreateEntityByName("env_sprite");
    if (sprite > 0)
    {
        DispatchKeyValue(sprite, "model", "sprites/glow01.spr");
        DispatchKeyValue(sprite, "scale", "0.35");
        DispatchKeyValue(sprite, "spawnflags", "1");          // Start On
        DispatchKeyValue(sprite, "rendercolor", "0 255 0");
        DispatchSpawn(sprite);
        float pos[3];
        GetClientAbsOrigin(client, pos);
        pos[2] += 100.0;
        TeleportEntity(sprite, pos, NULL_VECTOR, NULL_VECTOR);
        g_iArtMarker[client] = EntIndexToEntRef(sprite);
    }

    // v1.7.81: 瞄准状态最后置位——上面任何一步抛错（如属性缺失）都不会留下
    // "g_bArtAiming=true 但 timer 未建"的永久卡死（无法取消/无法重买）
    g_bArtAiming[client] = true;
    g_hArtAimTimer[client] = CreateTimer(ART_TICK_INT, Timer_ArtAim,
        GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    PrintToChat(client, "\x04[商店]\x01 已购买 \x05%s\x01（-\x03%d\x01 可用积分）。",
        g_ShopTable[slot].name, price);

    // v1.0.9: 购买后屏幕中央 textprint 教学（菜单描述已去掉"左键射击"字样）。
    // priming（记忆 l4d2-printhinttext-priming-bug）：先空格占位，0.1s 后替换成真消息
    PrintHintText(client, " ");
    CreateTimer(0.1, Timer_ArtTeach, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// v1.0.9: 购买火炮后的教学提示（左键确认 / 右键取消），带剩余有效期
public Action Timer_ArtTeach(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Stop;
    PrintHintText(client, "[商店] 左键确认轰炸，右键取消（%.0f 秒内有效）",
        g_cvArtTargetTime.FloatValue);
    return Plugin_Stop;
}

// 退出瞄准指示：清理标记/心跳（v1.7.95: 无武器切换，无需恢复武器），可退款
void ArtEndDesignate(int client, bool refund)
{
    if (!g_bArtAiming[client]) return;
    g_bArtAiming[client] = false;

    if (g_hArtAimTimer[client] != null)
    {
        KillTimer(g_hArtAimTimer[client]);
        g_hArtAimTimer[client] = null;
    }

    int marker = EntRefToEntIndex(g_iArtMarker[client]);
    if (marker > 0 && IsValidEntity(marker))
        AcceptEntityInput(marker, "Kill");
    g_iArtMarker[client] = 0;

    if (refund && SH_Ready())     // si_hud 未加载/过旧时跳过退款（懒绑定缺失 native 会记错）
    {
        SH_AddWallet(client, g_iArtPrice[client]);
        g_iShopBought[client][g_iArtSlot[client]]--;
        LogMessage("[artillery] designate cancelled client=%N refund=%d", client, g_iArtPrice[client]);
    }
}

// 瞄准心跳：更新标记（圆圈+光柱+光点，全队可见）+ 右键取消 + 超时/死亡
public Action Timer_ArtAim(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0) return Plugin_Stop;          // 断线（OnClientDisconnect 已清理）
    if (!g_bArtAiming[client]) return Plugin_Stop;

    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ArtEndDesignate(client, true);            // 死亡 → 取消退款
        return Plugin_Stop;
    }

    if (GetGameTime() >= g_fArtAimEnd[client])
    {
        PrintToChat(client, "\x04[商店]\x01 \x05%s\x01瞄准超时，积分已退回",
            g_ShopTable[g_iArtSlot[client]].name);
        ArtEndDesignate(client, true);
        return Plugin_Stop;
    }

    if (GetClientButtons(client) & IN_ATTACK2)    // 右键 → 取消退款
    {
        PrintToChat(client, "\x04[商店]\x01 已取消\x05%s\x01，积分已退回",
            g_ShopTable[g_iArtSlot[client]].name);
        ArtEndDesignate(client, true);
        return Plugin_Stop;
    }

    // 标记更新：瞄准点 + 圆圈（爆炸范围）+ 光柱；v1.4.2: I-轰炸蓝 / II-燃烧黄 /
    // I-绿色雨幕绿 / 无效红（用户定稿四色；原 v1.2.0 IV-榴弹雨红已禁用）
    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);

    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
        valid = false;

    int color[4] = { 0, 0, 255, 255 };            // 火力支援III-饱和轰炸：蓝
    int radius = 150;
    if (valid)
    {
        // v1.0.1: 预览圈按火力类型用对应半径组（与 ConfirmStrike 口径一致）
        // v1.1.0/v1.4.2/v1.4.3: kind = 1 炮击[已禁] / 2 燃烧→III / 3 胆汁雨→I / 4 榴弹雨[已禁] / 5 轰炸→II
        int kind = Art_KindOfSlot(g_iArtSlot[client]);
        if (kind == 2)
            color[0] = 255, color[1] = 255, color[2] = 0;   // 火力支援II-地狱烈火：黄
        else if (kind == 3)
            color[0] = 0, color[1] = 255, color[2] = 0;     // 火力支援I-绿色雨幕：绿
        // v1.4.2: kind 5（II-轰炸）落默认分支 = 蓝；kind 1/4 已禁用不可购买
        // v1.0.7/v1.4.2: 光圈显示用 ring 档位 = 各火力轰炸半径 × 4/3（三档大小分明）
        float ring;
        Art_RingParams(kind, ceiling, openAbove, ring);
        radius = RoundToNearest(ring);
    }
    else
    {
        color[0] = 255; color[1] = 0; color[2] = 0;   // 无效红
    }

    int marker = EntRefToEntIndex(g_iArtMarker[client]);
    if (marker > 0 && IsValidEntity(marker))
    {
        char col[32];
        Format(col, sizeof(col), "%d %d %d", color[0], color[1], color[2]);
        DispatchKeyValue(marker, "rendercolor", col);
        float pos[3];
        pos = target;
        pos[2] += 15.0;
        TeleportEntity(marker, pos, NULL_VECTOR, NULL_VECTOR);
    }

    // v1.7.85 FIX: beam 索引 0 时跳过 TE 发送（reload 后 OnMapStart 不重跑会归 0，
    // 空模型索引发送可能 segfault——17:28:36 实锤）
    // v1.0.6: 瞄准圈只发给购买者（TE_SendToClient）；确认后的预警光圈才全员可见
    if (g_iBeamLaser > 0 && g_iBeamHalo > 0)
    {
        float ground[3];
        ground = target;
        ground[2] += 5.0;
        TE_SetupBeamRingPoint(ground, float(radius) - 5.0, float(radius),
            g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15, 3.0, 0.0, color, 0, 0);
        TE_SendToClient(client);

        float top[3];
        top = ground;
        top[2] += 500.0;
        TE_SetupBeamPoints(ground, top, g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15,
            2.0, 2.0, 0, 0.0, color, 0);
        TE_SendToClient(client);
    }
    return Plugin_Continue;
}

// 任意武器左键开火 = 确认轰炸（v1.7.95: 不再切马格南/限定武器，用户拍板简化）
public Action Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !g_bArtAiming[client])
        return Plugin_Continue;

    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);
    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
        valid = false;
    LogMessage("[artillery] confirm client=%N valid=%d ceiling=%.0f openAbove=%d target=(%.0f %.0f %.0f)",
        client, valid, ceiling, openAbove, target[0], target[1], target[2]);
    if (!valid)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效：需要能落到地面的开阔区域（天花板过低或瞄天空），请重新瞄准开火");
        return Plugin_Continue;                   // 留在瞄准模式，可再次开火
    }

    ArtEndDesignate(client, false);
    Art_ConfirmStrike(client, target);
    return Plugin_Continue;
}

// 准星瞄准点（只碰世界固体，不碰玩家/特感）；瞄天花板底面 → 落点下移 120u
// v1.7.82: 水面支持——水面是 CONTENTS_WATER 不是 brush，MASK_SOLID_BRUSHONLY
// 不命中 → 瞄水面必报无效；补一次 CONTENTS_WATER trace（水面 = 开阔落点，合法）。
void Art_AimPoint(int client, float out[3], bool &valid)
{
    valid = false;
    float eye[3], ang[3], fwd[3], end[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    end = eye;
    end[0] += fwd[0] * ART_AIM_MAX_DIST;
    end[1] += fwd[1] * ART_AIM_MAX_DIST;
    end[2] += fwd[2] * ART_AIM_MAX_DIST;

    char hitType[16];
    strcopy(hitType, sizeof(hitType), "brush");
    Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID_BRUSHONLY,
        RayType_EndPoint, ShopTraceFilter, client);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(out, tr);
        float normal[3];
        TR_GetPlaneNormal(tr, normal);
        if (normal[2] < -0.7)                     // 瞄到天花板底面 → 落到室内地面
            out[2] -= 120.0;
        valid = true;
    }
    else
    {
        // 水面兜底（瞄天空/无遮挡时此 trace 也无命中 → 保持无效）
        Handle trw = TR_TraceRayFilterEx(eye, end, CONTENTS_WATER,
            RayType_EndPoint, ShopTraceFilter, client);
        if (TR_DidHit(trw))
        {
            TR_GetEndPosition(out, trw);
            valid = true;
            strcopy(hitType, sizeof(hitType), "water");
        }
        delete trw;
    }
    delete tr;
}

// 落点上方找天花板：返回距离；0 = 4096u 内无遮挡（室外）
// v1.7.82: 薄遮挡穿透——公园树冠/路灯/电线/雨棚是 <50u 的薄 brush（c5m2 实测
// 开阔室外被树冠误判 ceiling<600 报"目标无效"），穿透后继续向上找，只认
// ≥50u 的实心结构（楼板/岩石/桥面）为天花板；最多穿透 3 层。
// v1.7.83: 侧面命中穿透——树干/柱/墙是"竖直柱面"（法线近乎水平），向上 trace
// 穿树干时侧面命中被判"实心天花板"（17:22 日志 dist=339 实锤）；法线 z>-0.7
// → 不是天花板，穿透继续。薄遮挡阈值 50→100u（树冠/雨棚常见 50-100u）。
// v1.7.84: openAbove 输出——最终判定实心天花板的上方是否开阔（再向上 4096u
// 无遮挡）。平台/桥/单层屋顶上方是天空 → openAbove=true → <600 也放行
// （罐子从遮挡下 150u 短落爆炸，用户在大平台/桥上也有轰炸效果）；
// 多层建筑/地下室 → openAbove=false → <600 拒绝（保持 v1.7.80 用户拍板）。
float Art_FindCeiling(const float pos[3], bool &openAbove)
{
    openAbove = false;
    float from[3], to[3];
    from = pos;
    from[2] += 60.0;
    to = from;
    to[2] += ART_CEIL_CLEAR;

    // data=-1 → ShopTraceFilter(entity != -1) 恒真 → 忽略所有实体，只算世界几何
    float dist = 0.0;
    int hops = 0;
    int hits = 0;
    float lastNormal[3] = { 0.0, 0.0, 0.0 };
    float lastHit[3];
    while (hops < 4)
    {
        Handle tr = TR_TraceRayFilterEx(from, to, MASK_SOLID,
            RayType_EndPoint, ShopTraceFilter, -1);
        if (!TR_DidHit(tr))
        {
            dist = 0.0;                       // 到顶无遮挡 → 室外
            delete tr;
            break;
        }
        hits++;
        float frac = TR_GetFraction(tr);
        float seg = frac * (to[2] - from[2]);
        TR_GetEndPosition(lastHit, tr);
        TR_GetPlaneNormal(tr, lastNormal);
        delete tr;

        // 侧面命中（树干/柱/墙，法线近乎水平）→ 不是天花板 → 穿透继续
        if (lastNormal[2] > -0.7)
        {
            dist += seg;
            from = lastHit;
            from[2] += 2.0;
            hops++;
            continue;
        }

        // 从命中点继续向上 probe：100u 内无再命中 → 薄遮挡（树冠等），穿透继续
        float probe[3];
        probe = lastHit;
        probe[2] += ART_CEIL_THIN;
        Handle tr2 = TR_TraceRayFilterEx(lastHit, probe, MASK_SOLID,
            RayType_EndPoint, ShopTraceFilter, -1);
        bool solidAbove = TR_DidHit(tr2);
        delete tr2;

        if (!solidAbove)
        {
            dist += seg;
            from = probe;                     // 穿透：从命中点上方继续
            hops++;
            continue;
        }
        dist += seg;                          // 实心天花板：累计到命中点
        break;
    }

    // 实心遮挡上方是否开阔：从命中点上方 120u 再向上探测（无再命中 = 开阔）
    if (dist <= 0.0)
    {
        openAbove = true;                     // 室外
    }
    else
    {
        float above[3], to2[3];
        above = lastHit;
        above[2] += 120.0;
        to2 = above;
        to2[2] += ART_CEIL_CLEAR;
        Handle tr = TR_TraceRayFilterEx(above, to2, MASK_SOLID,
            RayType_EndPoint, ShopTraceFilter, -1);
        openAbove = !TR_DidHit(tr);
        delete tr;
    }
    return dist;
}

// 三级参数：室外 / 室内大(≥900) / 室内小(600-900) / 遮挡下短落(<600 且上方开阔)
// v1.7.84: 短落——平台/桥/树冠下，罐子从遮挡下 150u（下限 100u）掉落照样爆炸，
// 大平台/桥上使用不再"目标无效"；高度与爆炸伤害无关（落地触发）。
// v1.7.95: count 参数已移除——罐数由 ConfirmStrike 的 duration×rate 统一推导；
// 室内自适应只缩半径/落高（落罐密度不变，用户拍板 2-3 罐/秒）。
// v1.0.1: II-燃烧独立半径组；v1.1.0: kind 参数——III-胆汁雨用 art3 独立组
void Art_PickParams(int kind, float ceiling, bool openAbove, float &radius, float &height)
{
    ConVar cvOut  = kind == 2 ? g_cvArt2RadiusOut  : (kind == 3 ? g_cvArt3RadiusOut  : (kind == 4 ? g_cvArt4RadiusOut  : (kind == 5 ? g_cvArt5RadiusOut  : g_cvArtRadiusOut)));
    ConVar cvMid  = kind == 2 ? g_cvArt2RadiusMid  : (kind == 3 ? g_cvArt3RadiusMid  : (kind == 4 ? g_cvArt4RadiusMid  : (kind == 5 ? g_cvArt5RadiusMid  : g_cvArtRadiusMid)));
    ConVar cvSmall = kind == 2 ? g_cvArt2RadiusSmall : (kind == 3 ? g_cvArt3RadiusSmall : (kind == 4 ? g_cvArt4RadiusSmall : (kind == 5 ? g_cvArt5RadiusSmall : g_cvArtRadiusSmall)));

    if (ceiling <= 0.0)
    {
        radius = cvOut.FloatValue;
        height = GetRandomFloat(g_cvArtHeightMin.FloatValue, g_cvArtHeightMax.FloatValue);
    }
    else if (ceiling >= ART_CEIL_MID)
    {
        radius = cvMid.FloatValue;
        height = ceiling - 150.0;                 // 吊顶下生成，保证落地高度
    }
    else if (openAbove)
    {
        // v1.7.88: 开阔（平台/桥上方有天，如实测点位 ceiling=339）——之前锁小档
        // 用户反馈"太小了" → 按室外规模炸，落点高度仍压到吊顶-150 防撞头顶结构
        radius = cvOut.FloatValue;
        height = ceiling - 150.0;
        if (height < 100.0) height = 100.0;
        if (height > 500.0) height = 500.0;
    }
    else if (ceiling >= ART_CEIL_LOW)
    {
        radius = cvSmall.FloatValue;   // 封闭矮房（600-900）：小规模
        height = ceiling - 150.0;
        if (height < 100.0) height = 100.0;
    }
    else
    {
        radius = cvSmall.FloatValue;   // 拒绝级：确认前被拦截，不会真正使用
        height = ceiling - 150.0;
    }
}

// v1.4.2: 瞄准圈按火力类型区分大小（用户拍板）——圈 = 各火力轰炸半径 × 4/3
// （保持"光圈 > 轰炸范围"便于看落点；I-轰炸 750/525/375、II-燃烧 900/630/450、
// III-胆汁 562.5/393.75/281.25 三档分明）。v1.0.7 的 si_hud_art_ring_* 独立
// cvar 废弃不再读（残留惰性无害）。
void Art_RingParams(int kind, float ceiling, bool openAbove, float &ring)
{
    ConVar cvOut  = kind == 2 ? g_cvArt2RadiusOut  : (kind == 3 ? g_cvArt3RadiusOut  : (kind == 5 ? g_cvArt5RadiusOut  : g_cvArtRadiusOut));
    ConVar cvMid  = kind == 2 ? g_cvArt2RadiusMid  : (kind == 3 ? g_cvArt3RadiusMid  : (kind == 5 ? g_cvArt5RadiusMid  : g_cvArtRadiusMid));
    ConVar cvSmall = kind == 2 ? g_cvArt2RadiusSmall : (kind == 3 ? g_cvArt3RadiusSmall : (kind == 5 ? g_cvArt5RadiusSmall : g_cvArtRadiusSmall));

    float r;
    if (ceiling <= 0.0)                r = cvOut.FloatValue;
    else if (ceiling >= ART_CEIL_MID)  r = cvMid.FloatValue;
    else if (openAbove)                r = cvOut.FloatValue;
    else if (ceiling >= ART_CEIL_LOW)  r = cvSmall.FloatValue;
    else                               r = cvSmall.FloatValue;   // 拒绝级：确认前被拦截
    ring = r * 1.333333;    // 4/3：I-轰炸 562.5→750 / II-燃烧 675→900 / III-胆汁 421.875→562.5
}

// 确认轰炸（v1.0.6 重构）: 锁定落点 → 5s 预警（光圈全员可见 + 聊天播报）
// → 预警结束光圈消失、开始落罐（Art_LaunchBarrage）
void Art_ConfirmStrike(int client, float target[3])
{
    if (g_hArtCans == null)
        g_hArtCans = new ArrayList();

    // v1.1.0/v1.2.0: kind = 1 炮击 / 2 燃烧 / 3 胆汁雨 / 4 榴弹雨（g_iArtSlot 在确认时未被清除，仍有效）
    int kind = Art_KindOfSlot(g_iArtSlot[client]);

    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    float radius, height;
    Art_PickParams(kind, ceiling, openAbove, radius, height);
    float duration = kind == 2 ? g_cvArtDuration2.FloatValue
        : (kind == 3 ? g_cvArt3Duration.FloatValue
        : (kind == 4 ? g_cvArt4Duration.FloatValue
        : (kind == 5 ? g_cvArt5Duration.FloatValue : g_cvArtDuration.FloatValue)));   // v1.8.0/v1.1.0/v1.2.0/v1.3.0: 分项时长

    // v1.0.6: 预警参数入全局——预警结束（Timer_ArtWarnEnd）才开始落罐
    g_bArtWarning = true;
    g_iArtWarnKind = kind;
    g_fArtWarnTarget = target;
    // v1.0.7/v1.4.2: 光圈显示半径（ring 档位 = 各火力轰炸半径 × 4/3）与落罐半径分开存
    float ring;
    Art_RingParams(kind, ceiling, openAbove, ring);
    g_fArtWarnRing = ring;
    g_fArtWarnRadius = radius;
    g_fArtWarnHeight = height;
    g_fArtWarnDuration = duration;
    g_iArtWarnBuyer = client;
    g_fArtWarnEnd = GetGameTime() + g_cvArtWarnTime.FloatValue;
    g_iArtWarnLastSec = 999;   // v1.0.8: 心跳第一 tick 播首秒（prime 已就位）

    // v1.0.8: PrintHintText priming（记忆 l4d2-printhinttext-priming-bug）——
    // 第一条 hint 必须替换已有 hint 才正常渲染 CJK；空格占位 0.1s 内被倒计时替换
    PrintHintTextToAll(" ");

    // 结束时刻 = 预警 + 首罐延迟 + 末秒生成 + 落地(fallT) + 落地后燃烧 + 引爆（播报"剩余 x 秒"）
    // v1.7.86: 点燃的罐子对伤害免疫且燃烧结束不自爆（实测"假火"）→ 火灭后引擎引爆
    float fallT = SquareRoot((2.0 * height) / ART_GRAVITY);
    float endT = g_cvArtWarnTime.FloatValue + g_cvArtDelay.FloatValue
        + float(RoundToCeil(duration)) + fallT + g_cvArtBurn.FloatValue + 0.15;
    g_fArtNextBuyTime = GetGameTime() + endT + g_cvArtCooldown.FloatValue;

    // v1.0.7（用户定稿模板）: 预警播报——召唤者 + 空袭倒计时 + 注意躲避
    PrintToChatAll("\x04[火力支援]\x01 \x05%N\x01 已呼叫火力支援，空袭将在 \x03%.0f\x01 秒后到来，注意躲避！",
        client, g_cvArtWarnTime.FloatValue);
    CreateTimer(endT, Timer_ArtNotifyEnd, INVALID_HANDLE, TIMER_FLAG_NO_MAPCHANGE);

    // v1.0.6: 预警光圈心跳（全员可见，I 蓝 / II 黄）+ 预警结束落罐
    g_hArtWarnTimer = CreateTimer(ART_TICK_INT, Timer_ArtWarn, INVALID_HANDLE,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(g_cvArtWarnTime.FloatValue, Timer_ArtWarnEnd, INVALID_HANDLE,
        TIMER_FLAG_NO_MAPCHANGE);

    LogMessage("[artillery] confirm client=%N target=(%.0f,%.0f,%.0f) ceiling=%.0f warn=%.0fs dur=%.0fs r=%.0f h=%.0f",
        client, target[0], target[1], target[2], ceiling, g_cvArtWarnTime.FloatValue, duration, radius, height);
}

// v1.0.6: 预警光圈心跳（全员可见）——颜色 I-炮击蓝 / II-燃烧黄；预警结束自动停
// v1.0.7: 光圈用 ring 显示半径 + 圆心光柱（显眼，全员可见）+ 每秒倒计时播报
public Action Timer_ArtWarn(Handle timer)
{
    if (!g_bArtWarning || GetGameTime() >= g_fArtWarnEnd)
        return Plugin_Stop;

    // v1.0.7: 每秒倒计时播报（剩余 8..1 秒，confirm 已播首条聊天）
    // v1.0.8: 改屏幕中央 PrintHintText（带阴影更醒目，用户拍板）；
    // 文案统一"到来"——预警结束轰炸才开始，无"结束"语义（用户纠正）。
    // 不主动清除——自然淡出
    int remain = RoundToCeil(g_fArtWarnEnd - GetGameTime());
    if (remain != g_iArtWarnLastSec && remain >= 1)
    {
        g_iArtWarnLastSec = remain;
        PrintHintTextToAll("[火力支援] 空袭将在 %d 秒后到来，注意躲避！", remain);
    }

    if (g_iBeamLaser <= 0 || g_iBeamHalo <= 0)
        return Plugin_Continue;

    float ground[3];
    ground = g_fArtWarnTarget;
    ground[2] += 5.0;
    int color[4];
    if (g_iArtWarnKind == 2)
        color = { 255, 255, 0, 255 };      // 火力支援II-地狱烈火：黄
    else if (g_iArtWarnKind == 3)
        color = { 0, 255, 0, 255 };        // v1.1.0: 火力支援I-绿色雨幕：绿
    // v1.4.2: kind 1/4/5 全落默认蓝（II-轰炸蓝；kind 1/4 已禁用）——用户定稿四色
    else
        color = { 0, 0, 255, 255 };        // 火力支援III-饱和轰炸：蓝
    TE_SetupBeamRingPoint(ground, g_fArtWarnRing - 5.0, g_fArtWarnRing,
        g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15, 3.0, 0.0, color, 0, 0);
    TE_SendToAll();

    // v1.0.7: 圆心光柱（醒目提示落点，全员可见）
    float top[3];
    top = ground;
    top[2] += 800.0;
    TE_SetupBeamPoints(ground, top, g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15,
        3.0, 3.0, 0, 0.0, color, 0);
    TE_SendToAll();
    return Plugin_Continue;
}

// v1.0.6: 预警结束：光圈消失（心跳停）→ 开始落罐
// v1.0.8: 轰炸开始瞬间额外播报"空袭将在 X 秒后结束"（I=30s / II=25s /
// III=15s，该是多久就是多久）——hint 单槽，替换掉"1 秒后到来"
public Action Timer_ArtWarnEnd(Handle timer)
{
    if (g_hArtWarnTimer != null)
    {
        KillTimer(g_hArtWarnTimer);
        g_hArtWarnTimer = null;
    }
    g_bArtWarning = false;
    PrintHintTextToAll("[火力支援] 空袭将在 %.0f 秒后结束，注意躲避！", g_fArtWarnDuration);
    Art_LaunchBarrage(g_iArtWarnBuyer, g_fArtWarnTarget, g_iArtWarnKind,
        g_fArtWarnRadius, g_fArtWarnHeight, g_fArtWarnDuration);
    return Plugin_Continue;
}

// 落罐主体（v1.0.6 从 ConfirmStrike 抽出，预警结束后调用）：
// 按秒分槽——每秒随机 2-3 罐（用户拍板：30s × 2-3/秒 ≈ 60-90 罐）；
// v1.1.0: kind=3 胆汁雨每秒 1-2 瓶（ART3_JARS_* 写死，单瓶覆盖大）；
// v1.2.0: kind=4 榴弹雨每秒 1-2 发（ART4_GRENADES_* 写死，爆炸满伤）
// 每罐在所属秒内随机偏移，保证每秒必有掉落
void Art_LaunchBarrage(int client, const float target[3], int kind,
    float radius, float height, float duration)
{
    int seconds = RoundToCeil(duration);
    if (seconds < 1) seconds = 1;
    int total = 0;

    int minPerSec = (kind == 3) ? ART3_JARS_MIN_PER_SEC
        : ((kind == 4) ? ART4_GRENADES_MIN_PER_SEC
        : ((kind == 5) ? ART5_MIN_PER_SEC : ART_CANS_MIN_PER_SEC));
    int maxPerSec = (kind == 3) ? ART3_JARS_MAX_PER_SEC
        : ((kind == 4) ? ART4_GRENADES_MAX_PER_SEC
        : ((kind == 5) ? ART5_MAX_PER_SEC : ART_CANS_MAX_PER_SEC));

    // v1.4.0: kind==3 每 2 秒一槽（用户定稿：每 2 秒 1-2 罐，15s ≈ 8-16 瓶）
    for (int sec = 0; sec < seconds; sec += (kind == 3 ? 2 : 1))
    {
        int cans = GetRandomInt(minPerSec, maxPerSec);
        for (int c = 0; c < cans; c++)
        {
            if (total >= ART_MAX_TOTAL) break;          // 防 cvar 误配超载
            DataPack dp = new DataPack();
            dp.WriteFloat(target[0]);
            dp.WriteFloat(target[1]);
            dp.WriteFloat(target[2]);
            dp.WriteFloat(radius);
            dp.WriteFloat(height);
            dp.WriteCell(client);            // v1.7.97: 召唤者传给引爆（击杀归属=召唤者）
            dp.WriteCell(kind);              // v1.1.0/v1.2.0: 火力类型 1=瓦斯/煤气 2=油桶/烟花 3=胆汁瓶 4=榴弹
            CreateTimer(g_cvArtDelay.FloatValue + float(sec) + GetRandomFloat(0.0, 0.9),
                Timer_ArtSpawnCan, dp, TIMER_FLAG_NO_MAPCHANGE);
            total++;
        }
        if (total >= ART_MAX_TOTAL) break;
    }

    LogMessage("[artillery] strike client=%N target=(%.0f,%.0f,%.0f) kind=%d dur=%.0fs secs=%d total=%d r=%.0f h=%.0f",
        client, target[0], target[1], target[2], kind, duration, seconds, total, radius, height);
}

// 生成单个着火罐子（圆内均匀散布）→ 安排落地强制引爆
public Action Timer_ArtSpawnCan(Handle timer, DataPack dp)
{
    dp.Reset();
    float target[3];
    target[0] = dp.ReadFloat();
    target[1] = dp.ReadFloat();
    target[2] = dp.ReadFloat();
    float radius = dp.ReadFloat();
    float height = dp.ReadFloat();
    int buyer = dp.ReadCell();              // v1.7.97: 召唤者（引爆归属=召唤者）
    int kind = dp.ReadCell();               // v1.1.0: 火力类型 1=瓦斯/煤气 2=油桶/烟花 3=胆汁瓶
    delete dp;

    // v1.3.0 FIX: 榴弹/混合的引信高度钳制提前到 pos 计算前——v1.2.0 先算
    // pos 再钳 height 只改参数不改落点（弹丸仍生成在 1800-2600 半空空爆浪费；
    // sm_art4test 口径一致是钳后才算 pos，正式路径漏了）
    // v1.6.0: kind 2（II-地狱烈火）同钳——露天高天花板下 III 罐子钳 1500 而
    // II 不钳（2182）高度不统一；罐子虽无引信，统一钳制更稳（坠落时长/卡结构
    // 风险随高度上升，且 II/III 罐子视觉节奏一致）。
    if ((kind == 2 || kind == 4 || kind == 5) && height > ART4_FUSE_HEIGHT)
        height = ART4_FUSE_HEIGHT;

    // v1.6.2 FIX: 头顶隐形实体探测——c4m2 空地 z=972 防飞顶实体实锤（16:54 测试
    // h=2196 罐子 8/8 全停 972：ShopTraceFilter 忽略实体 → ceiling/落点 validate
    // 都检测不到 → 罐子撞实体不触发触碰碎裂 → fallback 半碎裂无胆汁视觉）。
    // 从 target 向上 5000u trace（不带 filter，MASK_SOLID 含实体）→ 首面即头顶
    // 阻挡 → height 压到阻挡下方 50u。室内真实天花板 ceiling-150 余量更大 →
    // maxH 更大 → 保持原值不变；露天防飞顶（972）→ 2196 钳到 801，罐子从
    // 阻挡下方生成 → 直接落地触碰世界 → 引擎完整碎裂（14:12 h=189 同款流程）。
    float up[3];
    up = target;
    up[2] += 5000.0;
    Handle trUp = TR_TraceRayEx(target, up, MASK_SOLID, RayType_EndPoint);
    if (TR_DidHit(trUp))
    {
        float hit[3];
        TR_GetEndPosition(hit, trUp);
        float maxH = hit[2] - target[2] - 50.0;
        if (maxH >= 100.0 && height > maxH)
        {
            char cls[64] = "world";
            int entHit = TR_GetEntityIndex(trUp);
            if (entHit > 0)
                GetEntityClassname(entHit, cls, sizeof(cls));
            LogMessage("[artillery3] head-block hit z=%.0f maxH=%.0f class=%s height %.0f -> %.0f",
                hit[2], maxH, cls, height, maxH);
            height = maxH;
        }
    }
    delete trUp;

    float ang = GetRandomFloat(0.0, 6.2831853);
    float r = radius * SquareRoot(GetRandomFloat(0.0, 1.0));
    float pos[3];
    pos[0] = target[0] + Cosine(ang) * r;
    pos[1] = target[1] + Sine(ang) * r;
    pos[2] = target[2] + height;

    // v1.6.1 FIX: 落点验证——散布圈盖到建筑时罐子会落到屋顶（16:46 实测 jar 落
    // 到 z=972 屋顶 vs 目标地面 169，800u 落差 → 全在屋顶爆，地面零效果）。
    // 从生成点向下 trace：首面非目标地面（|end.z - target[2]| > 150）→ 重掷
    // 坐标（≤8 次）；无命中（地面是实体几何）→ 放行（fallback groundZ 兜底）。
    for (int tries = 0; tries < 8; tries++)
    {
        float probe[3];
        probe = pos;
        probe[2] -= 5000.0;
        Handle tr = TR_TraceRayFilterEx(pos, probe, MASK_SOLID, RayType_EndPoint,
            ShopTraceFilter, -1);
        if (!TR_DidHit(tr))
        {
            delete tr;
            break;                             // 下方无实心世界几何 → 放行
        }
        float end[3];
        TR_GetEndPosition(end, tr);
        delete tr;
        if (FloatAbs(end[2] - target[2]) <= 150.0)
            break;                             // 首面即目标地面 → 落点 OK
        LogMessage("[artillery3] validate reject try=%d endz=%.0f target=%.0f → 重掷",
            tries, end[2], target[2]);
        ang = GetRandomFloat(0.0, 6.2831853);
        r = radius * SquareRoot(GetRandomFloat(0.0, 1.0));
        pos[0] = target[0] + Cosine(ang) * r;
        pos[1] = target[1] + Sine(ang) * r;
        pos[2] = target[2] + height;
    }

    // v1.1.0: kind==3 胆汁瓶——走引擎工厂直生真弹丸（不走 prop_physics 罐子路径）
    if (kind == 3)
    {
        Art3_SpawnJar(pos, height, buyer);
        return Plugin_Continue;
    }

    // v1.2.0: kind==4 榴弹——left4dhooks native 直生引擎激活态弹丸
    // （引信特调：高度超 ART4_FUSE_HEIGHT 会在半空空爆，压到 1500）
    if (kind == 4)
    {
        Art4_SpawnGrenade(pos, height, buyer);
        return Plugin_Continue;
    }

    // v1.3.0: kind==5 混合轰炸——每件随机分流：罐子路径（kind=1 模型池：
    // 丙烷罐 70%/氧气罐 30%，点火强爆）或榴弹路径（引信高度已钳制）
    if (kind == 5)
    {
        if (GetRandomInt(1, 100) <= g_cvArt5CanPct.IntValue)
            kind = 1;    // 落到下方 prop_physics 罐子路径
        else
        {
            Art4_SpawnGrenade(pos, height, buyer);
            return Plugin_Continue;
        }
    }

    // v1.7.93 FIX（死亡爆炸最终方案）: 直接生成 prop_physics + 罐模型 = 地图罐子
    // 等价物。引擎爆炸能力由模型 propdata（physgun_interactions onbreak:explode_fire）
    // 承载，只有 prop_physics 破碎/死亡时触发；weapon_* 类名实体不走 propdata 破碎
    // 路径：v1.7.90/91 实锤生成态 weapon_propanetank 死亡静默消失（post-blast
    // hp=-99942），v1.7.92 give+drop 转换依赖购买者槽位/触地拾取竞态（slot4 掉落 +
    // 脚边闪现）。社区定论（[L4D1 & L4D2] Weapon Prop Give Fix, t-331053 /
    // disawar1 Physics fix, t-178076）：能炸的罐子 = prop_physics + 罐模型，
    // weapon_* drop 后不可 break/ignite/explode。直接生成最终形态 → 无 give+drop
    // 副作用；死亡/点燃过热 → 引擎爆炸（音效/火球/伤害/友伤缩放全原版）。
    char model[PLATFORM_MAX_PATH];
    // v1.7.98: 支援2 模型池 = 油桶(gascan001a，商店汽油桶) 70% + 烟花(explosive_box001)
    // 30%——两个模型都已在 v1.7.93 precache + can_full_damage 清单，引擎死亡爆炸原版。
    if (kind == 2)
    {
        if (GetRandomInt(1, 100) <= ART2_CAN_PROPANE_PCT)   // v1.4.0: 独立常量，保持 70/30
            strcopy(model, sizeof(model), "models/props_junk/gascan001a.mdl");
        else
            strcopy(model, sizeof(model), "models/props_junk/explosive_box001.mdl");
    }
    else
    {
        if (GetRandomInt(1, 100) <= ART_CAN_PROPANE_PCT)    // v1.4.0: 50/50（用户定稿瓦斯:煤气=1:1）
            strcopy(model, sizeof(model), "models/props_junk/propanecanister001a.mdl");
        else
            strcopy(model, sizeof(model), "models/props_equipment/oxygentank01.mdl");
    }

    int ent = CreateEntityByName("prop_physics");
    if (ent == -1)
    {
        LogError("[artillery] spawn prop_physics failed");
        return Plugin_Continue;
    }
    DispatchKeyValue(ent, "model", model);
    DispatchKeyValueVector(ent, "origin", pos);     // 直接生成在落点上空（不经世界原点）
    DispatchSpawn(ent);
    SetEntProp(ent, Prop_Data, "m_takedamage", 2);

    Art_LaunchCan(ent, pos, height, true, buyer);
    return Plugin_Continue;
}

// 罐子发射共用尾部：传送落点 + 点火 + 跟踪 + 安排引爆
// v1.1.0: 仅 kind 1/2 罐子使用（kind=3 胆汁瓶走 Art3_SpawnJar 独立路径，不点火）
void Art_LaunchCan(int ent, const float pos[3], float height, bool converted, int buyer)
{
    // 火会持续伤害罐子（v1.7.91 实锤 100→57）→ 抬高血量防燃烧中途过热自爆
    // （500hp ≈ 31s 燃烧才自爆，手动引爆时序内安全）
    if (converted && HasEntProp(ent, Prop_Data, "m_iHealth"))
        SetEntProp(ent, Prop_Data, "m_iHealth", 500);

    float vel[3] = { 0.0, 0.0, -80.0 };             // 轻微初速，防止悬停
    TeleportEntity(ent, pos, NULL_VECTOR, vel);

    // 坠落全程 + 落地后 burn 秒带火尾；火灭 0.15s 后引爆定时器（节奏错峰）
    float fallT = SquareRoot((2.0 * height) / ART_GRAVITY);
    float burn = g_cvArtBurn.FloatValue;
    if (burn < 0.5) burn = 0.5;
    IgniteEntity(ent, fallT + burn);

    int ref = EntIndexToEntRef(ent);
    if (ref != 0 && g_hArtCans != null)
        g_hArtCans.Push(ref);

    DataPack dp3 = new DataPack();
    dp3.WriteCell(ref);
    dp3.WriteCell(buyer);               // v1.7.97: 召唤者传给引爆（击杀归属=召唤者）
    CreateTimer(fallT + burn + 0.15, Timer_ArtExplode, dp3,
        TIMER_FLAG_NO_MAPCHANGE);
}

// 轰炸结束播报（含硬冷却提示）
public Action Timer_ArtNotifyEnd(Handle timer)
{
    PrintToChatAll("\x04[商店]\x01 \x05火炮支援结束\x01，\x03%.0f\x01 秒后可重新购买", g_cvArtCooldown.FloatValue);
    return Plugin_Continue;
}

// 火灭后引爆：击杀罐子 → 引擎死亡爆炸（原版音效/伤害/友伤缩放/击杀归属全自动）
public Action Timer_ArtExplode(Handle timer, DataPack dp)
{
    dp.Reset();
    int ent = EntRefToEntIndex(dp.ReadCell());
    int buyer = dp.ReadCell();              // v1.7.97: 召唤者（击杀归属）
    delete dp;

    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Continue;                     // 已被玩家提前打爆 → 无事

    // v1.7.91 FIX（静默消失根因）: 去掉 DMG_ALWAYSGIB——强制碎尸会跳过引擎死亡
    // 爆炸（v1.7.90 实测：罐子死了但没炸，直接消失）。纯 DMG_BLAST 走正常死亡
    // 流程 → 引擎死亡爆炸（音效/火球/伤害/友伤缩放全原版）。
    // v1.7.97 FIX: 回归 v1.7.93 参数 (victim=ent, attacker=ent, inflictor=buyer)。
    // 引擎爆炸伤害归属跟随 inflictor：v1.7.93（inflictor=召唤者）爆炸伤害正常
    // 发往队友/特感/僵尸（18:09-18:14 实测 engine 122/184）+ 击杀归属=召唤者
    // （hit 记录）；v1.7.94 把 inflictor 改成 ent（罐子自己）→ 归属=已死实体 →
    // 爆炸伤害全灭（19:00 后 13+ 次轰炸零记录，用户实测火炮打不到特感）。
    // 召唤者自己被引擎豁免（归属者豁免，wiki 原版亦然）→ 由 l4d2_can_full_damage
    // 插件在罐子销毁时对"最后攻击者"注入伤害+stagger 补炸。
    // 伤害位置传罐子自身位置（防爆炸 falloff 按 NULL_VECTOR=世界原点 衰减）。
    float pos[3];
    GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
    int killer = (buyer >= 1 && buyer <= MaxClients && IsClientInGame(buyer)) ? buyer : 0;
    SDKHooks_TakeDamage(ent, ent, killer, 99999.0,
        DMG_BLAST, -1, NULL_VECTOR, pos, false);
    return Plugin_Continue;
}

// ============================================================================
// 火力支援I-绿色雨幕（v1.1.0 原名火力支援III-胆汁雨）——SDKCall 引擎工厂 CVomitJarProjectile::Create
// 直生真弹丸（v1.2.3 定稿：GetMemSig 经典条目 "CVomitJarProjectile::Create"
// 无 L4DD:: 前缀、@_ZN 符号格式 → 工厂无投掷语音；L4D2_VomitJarPrj = 模拟
// 完整投掷流程含角色喊话，仅作回退）。版本史：v1.1.0 SDKCall 死于 L4DD::
// 新格式 gamedata（12:59 sig not found）→ v1.2.1 迁移 native → v1.2.2 修
// 碎裂被淋语音 → v1.2.3 坐实投掷语音根因改工厂优先。artillery2 教训
// （v1.0.0-1.0.4 直生 grenade_launcher_projectile 永不爆）的正解：必须走
// 引擎工厂（CProjectileEntity::Create 做的事），CreateEntityByName 生成的
// 弹丸缺发射路径初始化。走引擎路径后全自动：坠落 → 撞击地面 → 引擎 Detonate
// → 原版碎裂（粒子/音效/上胆汁/info_goal_infected_chase 吸引小僵尸）——
// "落到地上自然碎裂"由引擎保证。
// ============================================================================

// v1.1.0/v1.2.0/v1.3.0: 商店槽位 → 火力类型（1=炮击[已禁] 2=燃烧 3=胆汁雨 4=榴弹雨[已禁] 5=I-轰炸 0=非火炮）
int Art_KindOfSlot(int slot)
{
    if (slot < 0 || slot >= SHOP_SLOTS)
        return 0;
    if (StrEqual(g_ShopTable[slot].classname, "artillery2"))
        return 2;
    if (StrEqual(g_ShopTable[slot].classname, "artillery3"))
        return 3;
    if (StrEqual(g_ShopTable[slot].classname, "artillery4"))
        return 4;
    if (StrEqual(g_ShopTable[slot].classname, "artillery5"))
        return 5;
    if (StrEqual(g_ShopTable[slot].classname, "artillery"))
        return 1;
    return 0;
}

// v1.2.1: 检查 left4dhooks native 可用性（惰性一次；缺失 → 购买拦截）。
// v1.2.7 回滚恢复：L4D2_VomitJarPrj（生成）+ L4D_DetonateProjectile（兜底）。
void Art3_CheckNatives()
{
    if (g_bArt3NativesFail)
        return;
    if (GetFeatureStatus(FeatureType_Native, "L4D2_VomitJarPrj") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "L4D_DetonateProjectile") != FeatureStatus_Available)
    {
        g_bArt3NativesFail = true;
        LogError("[artillery3] left4dhooks natives unavailable — 火力支援III 已禁用");
    }
}

// v1.2.3: 引擎工厂惰性解析——GetMemSig 经典条目（无 L4DD:: 前缀）：
// "CVomitJarProjectile::Create" + linux "@_ZN19CVomitJarProjectile6CreateERK
// 6VectorRK6QAngleS2_S2_P20CBaseCombatCharacter"（gamedata 3131 行，@ = 标准
// 符号表解析）。SDKCall 直调工厂 = 不播投掷语音（L4D2_VomitJarPrj 实现 =
// 模拟完整投掷流程含角色喊话，每次生成都响——v1.2.2 只修了碎裂被淋路径）。
// 解析失败不拦截购买：回退 L4D2_VomitJarPrj（功能不挂仅带语音），日志见分晓。
void Art3_ResolveSDK()
{
    if (g_bArt3SDKResolved)
        return;
    g_bArt3SDKResolved = true;

    GameData gd = new GameData("left4dhooks.l4d2");
    if (gd == null)
    {
        LogError("[artillery3] GameData left4dhooks.l4d2 load failed — 回退 native（有投掷语音）");
        return;
    }
    Address addrCreate = gd.GetMemSig("CVomitJarProjectile::Create");
    delete gd;

    if (addrCreate == Address_Null)
    {
        LogError("[artillery3] sig CVomitJarProjectile::Create not found — 回退 native（有投掷语音）");
        return;
    }

    // Create(Vector& origin, QAngle& angles, Vector& angVel, Vector& velocity, CBaseCombatCharacter* thrower)
    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetAddress(addrCreate);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
    g_hCallVomitJarCreate = EndPrepSDKCall();

    if (g_hCallVomitJarCreate == null)
    {
        LogError("[artillery3] EndPrepSDKCall(Create) failed — 回退 native（有投掷语音）");
        return;
    }
    LogMessage("[artillery3] factory SDK ready (no throw voice): CVomitJarProjectile::Create");
}

// v1.2.7 回滚：生成单瓶（引擎工厂直生真弹丸）→ 登记清理链 → 落地兜底强裂。
// 工厂优先（无投掷语音），解析失败回退 L4D2_VomitJarPrj（功能不挂仅带语音）。
void Art3_SpawnJar(const float pos[3], float height, int buyer)
{
    Art3_CheckNatives();
    if (g_bArt3NativesFail)
        return;    // native 未就绪已日志禁用，正常购买流程到不了这里

    float angles[3] = { 0.0, 0.0, 0.0 };
    float angVel[3] = { 0.0, 0.0, 0.0 };
    float vel[3] = { 0.0, 0.0, -900.0 };       // 直坠初速（引擎重力叠加，落地前加速）
    int thrower = (buyer >= 1 && buyer <= MaxClients) ? buyer : 0;

    int ent;
    Art3_ResolveSDK();
    if (g_hCallVomitJarCreate != null)
        ent = SDKCall(g_hCallVomitJarCreate, pos, angles, angVel, vel, thrower);
    else
        ent = L4D2_VomitJarPrj(buyer, pos, angles, vel, angVel);
    if (ent <= 0 || !IsValidEntity(ent))
    {
        LogError("[artillery3] spawn invalid ent=%d factory=%d", ent,
            g_hCallVomitJarCreate != null);
        return;
    }

    int ref = EntIndexToEntRef(ent);
    if (ref != 0 && g_hArtCans != null)
        g_hArtCans.Push(ref);                  // 换图/卸载清理链自动覆盖

    // 兜底：自然碎裂应在 ~fallT 发生；落后 0.5s 仍未碎 → 降到落点地面再触碰/强裂
    float fallT = SquareRoot((2.0 * height) / ART_GRAVITY);
    DataPack dp = new DataPack();
    dp.WriteCell(ref);
    dp.WriteFloat(pos[2] - height);   // v1.6.0: 空袭落点地面高度（高 h 强爆落点兜底）
    CreateTimer(fallT + 0.5, Timer_Art3Detonate, dp, TIMER_FLAG_NO_MAPCHANGE);

    LogMessage("[artillery3] jar spawned ent=%d fallT=%.1f h=%.0f pos=(%.0f %.0f %.0f) thrower=%N",
        ent, fallT, height, pos[0], pos[1], pos[2], buyer);
}

// 兜底：落地后仍存活 → 降到地面再强制引擎 Detonate（原版碎裂+胆汁全流程）
public Action Timer_Art3Detonate(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref = dp.ReadCell();
    float groundZ = dp.ReadFloat();   // v1.6.0: 空袭落点地面高度
    delete dp;
    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Continue;                // 已自然碎裂/被打碎 → 无事

    // v1.6.0 FIX: 高 h 罐子从不落地（c4m2 露天 h=2182 实测 10 罐全 fallback、
    // bile-applied 全 0）——trace 只算世界几何（ShopTraceFilter 忽略实体），
    // 地面是 func_brush 实体几何时穿透 miss / 命中屋顶 → 罐子在 58m 高空被引爆，
    // 地面零效果。正解：trace 失效或罐子离地太远（悬停/穿地）→ 直接传到
    // 空袭落点地面高度再炸，保证胆汁必覆盖目标地面。
    float origin[3];
    GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin);
    float z = groundZ;
    float below[3];
    below = origin;
    below[2] -= 5000.0;
    Handle tr = TR_TraceRayFilterEx(origin, below, MASK_SOLID, RayType_EndPoint,
        ShopTraceFilter, -1);
    if (TR_DidHit(tr))
    {
        float end[3];
        TR_GetEndPosition(end, tr);
        // v1.6.1: 守卫改比「目标地面」而非「罐子当前高度」——屋顶上的罐子
        // origin.z==end.z 但 end.z 距目标地面 800u，之前误判"已在地面"留在屋顶
        if (FloatAbs(end[2] - groundZ) <= 150.0)
            z = end[2];                        // 首面 ≈ 目标地面 → 用局部地形
    }
    delete tr;
    float dest[3];
    dest = origin;
    dest[2] = z + 5.0;
    TeleportEntity(ent, dest, NULL_VECTOR, NULL_VECTOR);

    // v1.6.2 FIX: 传送后不立即强裂——v1.2.x 时代"fallback 无 bile"实为立即
    // 强裂半碎裂（L4D_DetonateProjectile = CBaseGrenade::Detonate 基类，不喷
    // 胆汁；16:54 dbg after-detonate alive=1 证明碎裂流程未走完 → 用户听到
    // 声音看不到胆汁烟雾）。传送落点 + 延迟 0.15s → 引擎物理掉落触碰地面 →
    // 完整碎裂（14:12 实测 h=189 落地触碰 = 引擎碎裂 + bile applied 13 人
    // 全流程）。仍存活（传送未唤醒/悬停）→ 兜底强裂（原 v1.2.5 手动窗口）。
    DataPack dp2 = new DataPack();
    dp2.WriteCell(EntIndexToEntRef(ent));
    CreateTimer(0.15, Timer_Art3GroundTouch, dp2, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

// v1.6.2: 传送落点后等待引擎触碰碎裂（完整胆汁效果）；仍未碎 → 兜底强裂
public Action Timer_Art3GroundTouch(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref = dp.ReadCell();
    delete dp;
    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Continue;              // 已自然触碰碎裂 → 引擎全流程 ✓
    LogMessage("[artillery3] touch-miss ent=%d force-detonate (fallback 兜底半碎裂)", ent);
    g_bArt3Detonating = true;                // v1.2.5 手动窗口：拦截幸存者被淋
    L4D_DetonateProjectile(ent);             // v1.2.1: 现成 native 强裂（原 SDKCall 已删）
    g_bArt3Detonating = false;
    if (IsValidEntity(ent))                  // Detonate 未销毁实体 → 兜底 Kill
        AcceptEntityInput(ent, "Kill");
    return Plugin_Continue;
}

// v1.1.0: 空服实测验证——引擎上胆汁日志（left4dhooks forward；小僵尸/女巫被
// 胆汁命中即触发）。实测通过后可按需保留（无副作用，仅日志）。
// 注意：left4dhooks.inc 里 Infected 版只有 pre-Action（无 _Post），
// return Plugin_Continue 放行即可。
public Action L4D2_Infected_HitByVomitJar(int victim, int &attacker)
{
    if (victim <= 0 || !IsValidEntity(victim))
        return Plugin_Continue;
    char cls[64];
    GetEntityClassname(victim, cls, sizeof(cls));
    LogMessage("[artillery3] bile applied victim=%d cls=%s attacker=%d",
        victim, cls, attacker);
    return Plugin_Continue;
}

// v1.2.2: 修复"落地触发角色语音"（用户实测）——幸存者被胆汁淋到 → 引擎
// CTerrorPlayer::OnHitByVomitJar → 角色反应语音。雨式轰炸每瓶都触发很吵，
// 且幸存者被淋会被小僵尸群殴（友伤隐患）。正解：碎裂 pre 标记自家瓶子 →
// 幸存者 pre 拦截（语音+盯上都掐掉），感染者放行（控场功能本体）。
// 玩家手扔的瓶子：标志窗口外 → 原版行为保留。

// CVomitJarProjectile::Detonate pre：entity 是自家瓶子 → 置标志
// v1.2.5 诊断：日志确认该 pre 是否被 L4D_DetonateProjectile 兜底路径触发
public Action L4D2_VomitJar_Detonate(int entity, int client)
{
    g_bArt3Detonating = (g_hArtCans != null
        && g_hArtCans.FindValue(EntIndexToEntRef(entity)) != -1);
    LogMessage("[artillery3] VomitJar_Detonate pre ent=%d own=%d", entity,
        g_bArt3Detonating);
    return Plugin_Continue;      // 碎裂放行（感染者淋胆汁 = 控场本体）
}

public void L4D2_VomitJar_Detonate_Post(int entity, int client)
{
    LogMessage("[artillery3] VomitJar_Detonate post ent=%d own-was=%d", entity,
        g_bArt3Detonating);
    g_bArt3Detonating = false;
}

// CTerrorPlayer::OnHitByVomitJar pre：victim = 幸存者；自家瓶子 → 阻止
// v1.2.5 诊断：victim 类型 + 标志值 + 拦/放行（定位语音来源）
public Action L4D2_OnHitByVomitJar(int victim, int &attacker)
{
    if (g_bArt3Detonating && victim >= 1 && victim <= MaxClients)
    {
        LogMessage("[artillery3] BLOCK survivor-biled victim=%d flag=1", victim);
        return Plugin_Handled;
    }
    if (victim >= 1 && victim <= MaxClients)
        LogMessage("[artillery3] PASS survivor-biled victim=%d flag=0", victim);
    return Plugin_Continue;
}

// v1.1.0: 空服实测脚手架——准星处单瓶（验证坠落→碎裂→上胆汁全链路）
public Action Cmd_Art3Test(int client, int args)
{
    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);
    if (!valid)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效——请照准地面/开阔处");
        return Plugin_Handled;
    }
    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效——天花板过低");
        return Plugin_Handled;
    }
    float radius, height;
    Art_PickParams(3, ceiling, openAbove, radius, height);
    float pos[3];
    pos = target;
    pos[2] += height;
    Art3_SpawnJar(pos, height, client);
    PrintToChat(client, "\x04[商店]\x01 火力支援III 测试瓶：h=%.0f（坠落 ~%.1fs 后碎裂）",
        height, SquareRoot((2.0 * height) / ART_GRAVITY));
    return Plugin_Handled;
}

// ============================================================================
// 火力支援IV-榴弹雨（v1.2.0）——left4dhooks 现成 native 直生引擎激活态
// grenadelauncher_projectile。artillery2 v1.0.0-1.0.4 直生弹丸永不爆的根因
// 破案后的正解：L4D2_GrenadeLauncherPrj = 引擎工厂 CGrenadeLauncher_Projectile
// ::Create 的包装（"Creates an activated projectile"——激活正是直生缺的
// 初始化，gamedata 签名 6 参含 bIncendiary 佐证）。爆炸伤害/友伤缩放/击杀
// 归属全原版（m_flDamage=270 与手持发射态属性 dump 一致）；兜底 native
// L4D_DetonateProjectile 强制引爆（激活失败异常态）。
// ============================================================================

// v1.2.0: 检查 left4dhooks native 可用性（惰性一次；缺失 → 购买拦截）
void Art4_CheckNatives()
{
    if (g_bArt4NativesFail)
        return;
    if (GetFeatureStatus(FeatureType_Native, "L4D2_GrenadeLauncherPrj") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "L4D_DetonateProjectile") != FeatureStatus_Available)
    {
        g_bArt4NativesFail = true;
        LogError("[artillery4] left4dhooks natives unavailable — 火力支援IV 已禁用");
    }
}

// 生成单发榴弹（引擎激活态）→ 登记清理链 → 兜底引爆
void Art4_SpawnGrenade(const float pos[3], float height, int buyer)
{
    Art4_CheckNatives();
    if (g_bArt4NativesFail)
        return;    // native 未就绪已日志禁用，正常购买流程到不了这里

    float angles[3] = { 0.0, 0.0, 0.0 };
    float vel[3] = { 0.0, 0.0, -900.0 };       // 直坠初速（引信 ~1.2s × 高度特调见 ART4_FUSE_HEIGHT）
    float rot[3] = { 0.0, 0.0, 0.0 };
    int ent = L4D2_GrenadeLauncherPrj(buyer, pos, angles, vel, rot, false);
    if (ent <= 0 || !IsValidEntity(ent))
    {
        LogError("[artillery4] L4D2_GrenadeLauncherPrj invalid ent=%d", ent);
        return;
    }

    int ref = EntIndexToEntRef(ent);
    if (ref != 0 && g_hArtCans != null)
        g_hArtCans.Push(ref);                  // 换图/卸载清理链自动覆盖

    // 兜底：激活态弹丸 ~1.2s 引信自爆；落后于零初速 fallT 仍未爆 → 强爆
    float fallT = SquareRoot((2.0 * height) / ART_GRAVITY);
    DataPack dp = new DataPack();
    dp.WriteCell(ref);
    CreateTimer(fallT + 0.6, Timer_Art4Detonate, dp, TIMER_FLAG_NO_MAPCHANGE);
    LogMessage("[artillery4] grenade spawned ent=%d fallT=%.1f h=%.0f thrower=%N",
        ent, fallT, height, buyer);
}

// 兜底：激活失败悬停未爆 → 落回地面再强制引爆（爆炸半径覆盖地面目标）
public Action Timer_Art4Detonate(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref = dp.ReadCell();
    delete dp;
    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Continue;                // 已自爆/被引信引爆 → 无事

    float origin[3];
    GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin);
    float below[3];
    below = origin;
    below[2] -= 5000.0;
    Handle tr = TR_TraceRayFilterEx(origin, below, MASK_SOLID, RayType_EndPoint,
        ShopTraceFilter, -1);
    if (TR_DidHit(tr))
    {
        float end[3];
        TR_GetEndPosition(end, tr);
        end[2] += 5.0;
        TeleportEntity(ent, end, NULL_VECTOR, NULL_VECTOR);
    }
    delete tr;

    L4D_DetonateProjectile(ent);
    if (IsValidEntity(ent))                    // 强爆未销毁实体 → 兜底 Kill
        AcceptEntityInput(ent, "Kill");
    LogMessage("[artillery4] fallback detonate ent=%d", ent);
    return Plugin_Continue;
}

// v1.2.0: 空服实测脚手架——准星处单发榴弹（验证坠落→近地空爆→伤害全链路）
public Action Cmd_Art4Test(int client, int args)
{
    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);
    if (!valid)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效——请照准地面/开阔处");
        return Plugin_Handled;
    }
    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效——天花板过低");
        return Plugin_Handled;
    }
    float radius, height;
    Art_PickParams(4, ceiling, openAbove, radius, height);
    if (height > ART4_FUSE_HEIGHT)
        height = ART4_FUSE_HEIGHT;             // 引信特调（与 Timer_ArtSpawnCan kind==4 同口径）
    float pos[3];
    pos = target;
    pos[2] += height;
    Art4_SpawnGrenade(pos, height, client);
    PrintToChat(client, "\x04[商店]\x01 火力支援IV 测试弹：h=%.0f（引信 ~1.2s，贴近地面空爆）", height);
    return Plugin_Handled;
}

// v1.3.0: 空服实测脚手架——准星单件，走正式 kind=5 分流（随机罐子/榴弹）
public Action Cmd_Art5Test(int client, int args)
{
    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);
    if (!valid)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效——请照准地面/开阔处");
        return Plugin_Handled;
    }
    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效——天花板过低");
        return Plugin_Handled;
    }
    float radius, height;
    Art_PickParams(5, ceiling, openAbove, radius, height);
    DataPack dp = new DataPack();            // 复用 Timer_ArtSpawnCan 正式路径（含 kind=5 随机分流）
    dp.WriteFloat(target[0]);
    dp.WriteFloat(target[1]);
    dp.WriteFloat(target[2]);
    dp.WriteFloat(radius);
    dp.WriteFloat(height);
    dp.WriteCell(client);
    dp.WriteCell(5);
    Timer_ArtSpawnCan(INVALID_HANDLE, dp);
    PrintToChat(client, "\x04[商店]\x01 火力支援V 测试件：h=%.0f（随机罐子或榴弹，混合比 si_hud_art5_can_pct=%d%%）",
        height, g_cvArt5CanPct.IntValue);
    return Plugin_Handled;
}

// 换图 / 卸载 / reload 兜底清理：所有瞄准状态 + 残留罐子
void Art_CleanupAll()
{
    g_fArtNextBuyTime = 0.0;                       // 换图清冷却（通知定时器 NO_MAPCHANGE 已随图自动清）

    // v1.0.6: 清理预警阶段（心跳/结束 timer 随换图自动清，这里兜底状态）
    if (g_hArtWarnTimer != null)
    {
        KillTimer(g_hArtWarnTimer);
        g_hArtWarnTimer = null;
    }
    g_bArtWarning = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bArtAiming[i])
            ArtEndDesignate(i, false);
    }

    if (g_hArtCans != null)
    {
        for (int i = 0; i < g_hArtCans.Length; i++)
        {
            int ent = EntRefToEntIndex(g_hArtCans.Get(i));
            if (ent > 0 && IsValidEntity(ent))
                AcceptEntityInput(ent, "Kill");
        }
        g_hArtCans.Clear();
    }
}
