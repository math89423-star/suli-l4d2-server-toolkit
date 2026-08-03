/**
 * [L4D2] Score Shop v1.0.0 — !shop / !buy（自 l4d2_si_hud v1.8.2 解耦独立）
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
 * 透视 4000/5min（续费至 15min）、近战盲盒 1000、烟花 1200、
 * 火力支援I-炮击 4500/30s、火力支援II-燃烧 6500/25s。
 *
 * 依赖：l4d2_si_hud.smx >= v1.9.0（SH_ API）。未加载时商店不可用。
 */

#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>      // SDKHooks_TakeDamage（火炮引爆击杀归属）
#include <float>         // 火炮弹道数学 Sqrt/Cos/Sin

#define PLUGIN_VERSION "1.0.0"

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
ConVar g_cvArtHeightMin;
ConVar g_cvArtHeightMax;
ConVar g_cvArtDelay;
ConVar g_cvArtBurn;
ConVar g_cvArtCooldown;

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
#define ART_CAN_PROPANE_PCT  70       // 罐型混合：70% 瓦斯罐 + 30% 煤气罐
#define ART_TICK_INT         0.05     // 瞄准心跳间隔（标记更新 + 右键/超时/死亡检测）
#define ART_CEIL_THIN        100.0    // 薄遮挡厚度阈值（u）

#define SHOP_SLOTS      17

#define MELEE_POOL_COUNT   12

#define WALLHACK_SLOT       12      // g_ShopTable 槽位（= 透视特感）
#define ARTILLERY_SLOT      15      // g_ShopTable 槽位（= 火炮支援1）
#define WALLHACK_DURATION   300.0   // v1.8.1: 5 分钟（用户定稿，原 v1.7.67 定稿 180=3 分钟）
#define WALLHACK_CAP        900.0   // v1.7.69: 可续费，单次效果累计上限 15 分钟（用户定稿）

// ============================================================================
// 商品表（!shop）——价格/限购编译期写死（改价格需重编译本插件）
// ============================================================================

enum struct ShopItem
{
    char name[32];      // 显示名
    char classname[64]; // 实体 classname（空 = 特殊商品：复活币）
    int  price;         // 价格（可用积分）
    int  limit;         // 每图限购次数（0 = 无限）
    int  cat;           // v1.7.64: 菜单分类 0=武器 1=道具 2=医疗 3=其他
}

// 商品表（价格用户定稿 2026-08-02 修订：近战盲盒 1000/激光 1500/罐子 100/医疗包
// 3000/电击器 3500/药 1000/肾上腺素 1000/烟花 1200/油桶 3500；复活币 12000 不变）
ShopItem g_ShopTable[SHOP_SLOTS] = {
    // v1.7.36 (user): 全部商品不限购（limit 0）——只有复活币受持有上限
    // (si_hud_respawn_coin_max 5) 约束
    { "瓦斯罐",      "weapon_propanetank",             100,  0,  1 },   // v1.7.96: 用户定稿 100
    { "煤气罐",      "weapon_oxygentank",              100,  0,  1 },   // v1.7.96: 用户定稿 100
    { "汽油桶",      "weapon_gascan",                 3500,  0,  1 },   // v1.7.96: 用户定稿 3500（原 5000）
    { "止痛药",      "weapon_pain_pills",             1000,  0,  2 },   // v1.7.96: 用户定稿 1000（原 2000）
    { "肾上腺素",    "weapon_adrenaline",             1000,  0,  2 },   // v1.7.96: 用户定稿 1000（原 2000）
    { "电击器",      "weapon_defibrillator",          3500,  0,  2 },   // v1.7.96: 用户定稿 3500（原 4000）
    { "医疗包",      "weapon_first_aid_kit",          3000,  0,  2 },   // v1.7.96: 用户定稿 3000（原 4000）
    { "激光瞄准",    "weapon_upgradepack_laser_sight", 1500,  0,  0 },   // v1.7.96: 用户定稿 1500（原 3500）
    { "M60 轻机枪",  "weapon_rifle_m60",              5000,  0,  0 },   // v1.7.96: 用户定稿 5000
    { "电锯",        "weapon_chainsaw",               5000,  0,  0 },   // v1.7.44
    { "榴弹发射器",  "weapon_grenade_launcher",       6500,  0,  0 },   // v1.7.96: 用户定稿 6500（原 8000）
    { "复活币",      "",                              8500,  0,  3 },   // v1.8.1: 用户定稿 8500（v1.7.96 定稿 9000）
    { "透视特感",    "wallhack",                      4000,   0,  3 },   // v1.8.1: 用户定稿 4000/5分钟（原 6000/3分钟；可续费至 15 分钟）
    { "近战盲盒",    "melee_box",                     1000,   0,  0 },   // v1.7.96: 用户定稿 1000（原 3000）
    { "烟花",        "weapon_fireworkcrate",          1200,   0,  1 },   // v1.7.96: 用户定稿 1200（原 2500）
    { "火力支援I-炮击", "artillery",               4500,   0,  3 },  // v1.8.1: 用户定稿 4500/30s（v1.7.99 定稿 4000/35s）
    { "火力支援II-燃烧", "artillery2",             6500,   0,  3 }   // v1.8.1: 用户定稿 6500/25s（v1.7.99 定稿 7000/30s）
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

// 火炮支援 I/II（!shop 特殊商品）——瞄准指示 + 罐雨轰炸
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
    // v1.8.1: I-炮击 30s；II-燃烧 25s（用户定稿）
    g_cvArtDuration = CreateConVar("si_hud_art_duration", "30.0",
        "Total barrage duration in seconds for 火力支援I-炮击 (2-3 cans fall randomly each second).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvArtDuration.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArtDuration.SetBounds(ConVarBound_Lower, true, 5.0);

    g_cvArtDuration2 = CreateConVar("si_hud_art2_duration", "25.0",
        "Total barrage duration in seconds for 火力支援II-燃烧 (2-3 cans fall randomly each second).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvArtDuration2.SetBounds(ConVarBound_Upper, true, 300.0);
    g_cvArtDuration2.SetBounds(ConVarBound_Lower, true, 5.0);

    g_cvArtRadiusOut = CreateConVar("si_hud_art_radius_out", "750.0",
        "Spread radius (units) of the open-area strike; also the target ring radius.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusOut.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRadiusOut.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArtRadiusMid = CreateConVar("si_hud_art_radius_mid", "525.0",
        "Spread radius for ceiling >= 900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusMid.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRadiusMid.SetBounds(ConVarBound_Lower, true, 50.0);

    g_cvArtRadiusSmall = CreateConVar("si_hud_art_radius_small", "375.0",
        "Spread radius for ceiling 600-900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusSmall.SetBounds(ConVarBound_Upper, true, 1500.0);
    g_cvArtRadiusSmall.SetBounds(ConVarBound_Lower, true, 50.0);

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

    AutoExecConfig(true, "l4d2_shop");

    // ── Commands ────────────────────────────────────────

    RegConsoleCmd("sm_shop", Cmd_Shop, "Open the score shop (spend score on supplies/weapons).");
    RegConsoleCmd("sm_buy", Cmd_Shop, "Open the score shop (spend score on supplies/weapons).");

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

    // v1.7.69: 透视特感——生效期间可续费，累计上限 15 分钟（900 秒）
    if (StrEqual(g_ShopTable[slot].classname, "wallhack") && g_bWallhack[client])
    {
        float now = GetGameTime();
        if (g_fWallhackEnd[client] - now >= WALLHACK_CAP)
        {
            PrintToChat(client, "\x04[商店]\x01 特感透视已达上限 \x0315 分钟\x01（900 秒），无法继续续费");
            return;
        }
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
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05复活币\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），复活币余额 \x03%d\x01 枚",
            price, SH_GetWallet(client), coins);
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

    // v1.7.80: 火炮支援1/2——进入瞄准指示（射击确认轰炸）。
    // 不 spawn 实体；扣款已在上游完成，取消/超时/死亡/断线由 ArtEndDesignate 退款。
    // v1.7.98: 支援2 = 油桶/烟花模型池，与支援1 共用瞄准/冷却/半径（仅模型与文案不同）
    if (StrEqual(g_ShopTable[slot].classname, "artillery")
        || StrEqual(g_ShopTable[slot].classname, "artillery2"))
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
    menu.AddItem("2", "医疗类");
    menu.AddItem("3", "其他");
    menu.ExitButton = true;
    g_hShopMenu[client] = menu;
    menu.Display(client, 20);
}

void ShopCategoryMenu(int client, int cat)
{
    if (cat < 0 || cat > 3) cat = 3;
    g_iShopCat[client] = cat;
    char catNames[4][16] = { "武器类", "道具类", "医疗类", "其他" };
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
            Format(line, sizeof(line), "%s (%d分) [透视生效中·可续费]", g_ShopTable[i].name, price);
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

        if (i == ARTILLERY_SLOT && SH_GetWallet(client) >= price)   // 火炮提示使用方式
            Format(line, sizeof(line), "%s ·左键射击轰炸", line);

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
// → 清光。价格 4000 / 5 分钟（用户定稿；可续费至 15 分钟）。
// ============================================================================

void WallhackStart(int client, int price)
{
    // v1.7.69: 续费逻辑——已有剩余时长 + 300s，封顶 WALLHACK_CAP（900s）
    bool renew = g_bWallhack[client];
    float now = GetGameTime();
    float remaining = (renew && g_fWallhackEnd[client] > now) ? g_fWallhackEnd[client] - now : 0.0;
    float total = remaining + WALLHACK_DURATION;
    if (total > WALLHACK_CAP)
        total = WALLHACK_CAP;

    g_bWallhack[client] = true;
    g_fWallhackEnd[client] = now + total;

    // 重启到期计时器（续费时旧计时器作废重排）
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

    LogMessage("[wallhack] %s client=%N wallet=%d total=%.0fs", renew ? "renew" : "start",
        client, SH_GetWallet(client), total);
    int secs = RoundToNearest(total);
    if (renew)
    {
        PrintToChat(client, "\x04[商店]\x01 已续费 \x05透视特感\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），剩余生效时长：\x03%d\x01 秒",
            price, SH_GetWallet(client), secs);
    }
    else
    {
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05透视特感\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01）：特感蓝色高亮生效，剩余生效时长：\x03%d\x01 秒（全队可见；死亡/切图/重开/闲置后失效）",
            price, SH_GetWallet(client), secs);
    }
    // v1.7.68: 全服播报购买/续费（y 键聊天可见）
    PrintToChatAll("\x04[商店]\x01 \x05%N\x01 购买了特感透视，剩余生效时长：\x03%d\x01 秒",
        client, secs);
    WallhackApplyGlow();   // 立即上光（不等首 tick）
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

    PrintToChat(client, "\x04[商店]\x01 已购买 \x05%s\x01（-\x03%d\x01 可用积分）。\x05瞄准轰炸区域后左键开火确认\x01，\x05右键取消\x01，\x03%.0f 秒\x01内有效",
        g_ShopTable[slot].name, price, g_cvArtTargetTime.FloatValue);
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

    // 标记更新：瞄准点 + 圆圈（爆炸范围）+ 光柱；合法绿 / 无效红
    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);

    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
        valid = false;

    int color[4] = { 0, 255, 0, 255 };            // 合法绿
    int radius = 150;
    if (valid)
    {
        float r, h;
        Art_PickParams(ceiling, openAbove, r, h);
        radius = RoundToNearest(r);
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
    if (g_iBeamLaser > 0 && g_iBeamHalo > 0)
    {
        float ground[3];
        ground = target;
        ground[2] += 5.0;
        TE_SetupBeamRingPoint(ground, float(radius) - 5.0, float(radius),
            g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15, 3.0, 0.0, color, 0, 0);
        TE_SendToAll();

        float top[3];
        top = ground;
        top[2] += 500.0;
        TE_SetupBeamPoints(ground, top, g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15,
            2.0, 2.0, 0, 0.0, color, 0);
        TE_SendToAll();
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
void Art_PickParams(float ceiling, bool openAbove, float &radius, float &height)
{
    if (ceiling <= 0.0)
    {
        radius = g_cvArtRadiusOut.FloatValue;
        height = GetRandomFloat(g_cvArtHeightMin.FloatValue, g_cvArtHeightMax.FloatValue);
    }
    else if (ceiling >= ART_CEIL_MID)
    {
        radius = g_cvArtRadiusMid.FloatValue;
        height = ceiling - 150.0;                 // 吊顶下生成，保证落地高度
    }
    else if (openAbove)
    {
        // v1.7.88: 开阔（平台/桥上方有天，如实测点位 ceiling=339）——之前锁小档
        // 用户反馈"太小了" → 按室外规模炸，落点高度仍压到吊顶-150 防撞头顶结构
        radius = g_cvArtRadiusOut.FloatValue;
        height = ceiling - 150.0;
        if (height < 100.0) height = 100.0;
        if (height > 500.0) height = 500.0;
    }
    else if (ceiling >= ART_CEIL_LOW)
    {
        radius = g_cvArtRadiusSmall.FloatValue;   // 封闭矮房（600-900）：小规模
        height = ceiling - 150.0;
        if (height < 100.0) height = 100.0;
    }
    else
    {
        radius = g_cvArtRadiusSmall.FloatValue;   // 拒绝级：确认前被拦截，不会真正使用
        height = ceiling - 150.0;
    }
}

// 确认轰炸：锁定落点 → 全服警报 → 持续轰炸（duration 秒 × rate 罐/秒，错峰下落）
void Art_ConfirmStrike(int client, float target[3])
{
    if (g_hArtCans == null)
        g_hArtCans = new ArrayList();

    // v1.7.98: 支援2 = 油桶/烟花模型池（g_iArtSlot 在确认时未被清除，仍有效）
    int slot = g_iArtSlot[client];
    bool art2 = (slot >= 0 && slot < SHOP_SLOTS
        && StrEqual(g_ShopTable[slot].classname, "artillery2"));

    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    float radius, height;
    Art_PickParams(ceiling, openAbove, radius, height);

    // v1.7.96: 按秒分槽——每秒随机 2-3 罐（用户拍板：30s × 2-3/秒 ≈ 60-90 罐），
    // 每罐在所属秒内随机偏移，保证每秒必有掉落
    float duration = art2 ? g_cvArtDuration2.FloatValue : g_cvArtDuration.FloatValue;   // v1.8.0: 分项时长
    int seconds = RoundToCeil(duration);
    if (seconds < 1) seconds = 1;
    int total = 0;

    // 结束时刻 = 首罐延迟 + 末秒生成 + 落地(fallT) + 落地后燃烧 + 引爆（播报"剩余 x 秒"）
    // v1.7.86: 点燃的罐子对伤害免疫且燃烧结束不自爆（实测"假火"）→ 火灭后引擎引爆
    float fallT = SquareRoot((2.0 * height) / ART_GRAVITY);
    float endT = g_cvArtDelay.FloatValue + float(seconds) + fallT + g_cvArtBurn.FloatValue + 0.15;
    g_fArtNextBuyTime = GetGameTime() + endT + g_cvArtCooldown.FloatValue;

    // v1.7.80（用户拍板）：开始/结束全服聊天播报 + 轰炸中/冷却中禁止全体购买
    PrintToChatAll("\x04[商店]\x01 \x05火炮支援来袭，注意躲避！\x01剩余：\x03%.0f\x01 秒", duration);
    if (art2)
        PrintToChatAll("\x04[商店]\x01 \x05%N\x01 召唤了\x05火力支援II-燃烧\x01：着火的油桶/烟花即将从天而降！", client);
    else
        PrintToChatAll("\x04[商店]\x01 \x05%N\x01 召唤了\x05火力支援I-炮击\x01：着火的瓦斯罐/煤气罐即将从天而降！", client);
    CreateTimer(endT, Timer_ArtNotifyEnd, INVALID_HANDLE, TIMER_FLAG_NO_MAPCHANGE);

    for (int sec = 0; sec < seconds; sec++)
    {
        int cans = GetRandomInt(ART_CANS_MIN_PER_SEC, ART_CANS_MAX_PER_SEC);
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
            dp.WriteCell(art2 ? 2 : 1);      // v1.7.98: 罐型池（1=瓦斯/煤气 2=油桶/烟花）
            CreateTimer(g_cvArtDelay.FloatValue + float(sec) + GetRandomFloat(0.0, 0.9),
                Timer_ArtSpawnCan, dp, TIMER_FLAG_NO_MAPCHANGE);
            total++;
        }
        if (total >= ART_MAX_TOTAL) break;
    }

    LogMessage("[artillery] strike client=%N target=(%.0f,%.0f,%.0f) ceiling=%.0f dur=%.0fs secs=%d total=%d r=%.0f h=%.0f",
        client, target[0], target[1], target[2], ceiling, duration, seconds, total, radius, height);
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
    int kind = dp.ReadCell();               // v1.7.98: 罐型池（1=瓦斯/煤气 2=油桶/烟花）
    delete dp;

    float ang = GetRandomFloat(0.0, 6.2831853);
    float r = radius * SquareRoot(GetRandomFloat(0.0, 1.0));
    float pos[3];
    pos[0] = target[0] + Cosine(ang) * r;
    pos[1] = target[1] + Sine(ang) * r;
    pos[2] = target[2] + height;

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
        if (GetRandomInt(1, 100) <= ART_CAN_PROPANE_PCT)
            strcopy(model, sizeof(model), "models/props_junk/gascan001a.mdl");
        else
            strcopy(model, sizeof(model), "models/props_junk/explosive_box001.mdl");
    }
    else
    {
        if (GetRandomInt(1, 100) <= ART_CAN_PROPANE_PCT)
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

// 换图 / 卸载 / reload 兜底清理：所有瞄准状态 + 残留罐子
void Art_CleanupAll()
{
    g_fArtNextBuyTime = 0.0;                       // 换图清冷却（通知定时器 NO_MAPCHANGE 已随图自动清）

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
