/**
 * [L4D2] Shop Artillery II — 榴弹炮弹雨  v1.0.0
 *
 * 「火炮支援II」商店商品（!shop → 其他 → 火炮支援II，TEMP-TEST 1 分）。
 * BFV 式瞄准轰炸进阶版：购买后切服务器马格南 → 准星圈定轰炸区域 →
 * 开火确认 → N 发 grenade_launcher_projectile 从高空垂直下坠 →
 * 落地引擎碰撞爆炸（原生特效+音效+伤害管线全自动）。
 *
 * 与 l4d2_si_hud 的关系（独立插件维护，通过商店扩展 API 接线）：
 *   - si_hud 导出 SH_GetWallet / SH_AddWallet natives + SH_OnShopItemBuy
 *     forward（v1.7.93+）。本插件实现 forward 接管 classname "ext_artillery2"
 *     的购买：Plugin_Handled = 接管（si_hud 已完成扣款）;
 *     Plugin_Stop = 拒绝且已自行提示（si_hud 静默退款）。
 *   - 瞄准 UI（马格南切换/圆圈标记/右键取消/超时退款）从 si_hud 火炮I 移植，
 *     改名 Art2_ 前缀。两套独立互不干扰，各自冷却。
 *   - 积分入账走 si_hud（击杀得分体系），本插件只读钱包用于播报。
 *
 * 伤害管线（全部引擎原生 / l4d2_gl_splash_fix v2.1.26 自动接管，零手搓）：
 *   - gl_splash_fix:OnEntityCreated 捕获一切 grenade_launcher_projectile →
 *     下一帧设 m_flDamage=270（幸存者后置扣血 18 直击/10 溅射）
 *   - 特感固定 750 / Tank ×2.5 / Witch DMG_GENERIC 750（两发必死）/
 *     自伤注入 / ExtendSplash 500 半径——全在 gl_splash_fix 内
 *   - 击杀归属：SetEntPropEnt(m_hThrower, 购买者) → 引擎+注入伤害全记购买者
 *   - 弹丸碰撞（地面/墙/实体）即爆 = 引擎原生爆炸特效音效（客户端播放）
 *     ——这是罐子流（火炮I）缺的一环，弹丸流天然自带
 *
 * 兜底（弹丸无 fuse 计时，必须自管）：
 *   - 落地兜底：fallT+0.8s 弹丸仍存活（悬停/穿模）= 没爆 → Kill 输入 →
 *     gl_splash_fix OnEntityDestroyed 注入全伤害管线（无特效音效但伤害不丢）
 *   - 超时兜底：si_hud_art2_shell_timeout（10s）Kill（防卡地图缝隙永不落地）
 *
 * 依赖：l4d2_si_hud.smx（≥v1.7.93）+ l4d2_gl_splash_fix.smx。
 * 未装 si_hud 时商品无法购买（forward 无处理器 → si_hud 退款"不可用"）；
 * 未装 gl_splash_fix 时爆炸仍走引擎默认伤害（减配不崩溃）。
 *
 * Changelog v1.0.0:
 *   - 首版：瞄准 UI 移植 + 榴弹弹丸雨（垂直下坠零误差落点）。
 *     实测清单：①弹丸生成后是否受重力下落（vel -120 预期激活；悬停走
 *     落地兜底，日志 [art2] shell alive 观察）②真实模型路径（运行时读
 *     m_ModelName 与 precache 候选 models/weapons/gl_grenade.mdl 对照）
 *     ③m_hThrower 归属（gl_splash_fix GL boom/GL splash SI 日志验证）
 *     ④低天花板早爆（height=ceiling-200 已规避头顶结构）。
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <float>

// si_hud 商店扩展 API（v1.7.93+ 导出；forward/native 运行时自动绑定）
forward Action SH_OnShopItemBuy(int client, int slot, const char[] classname, int price);
native int  SH_GetWallet(int client);
native void SH_AddWallet(int client, int amount);

#define PLUGIN_VERSION "1.0.4"
#define ART2_SLOT_CLASS  "ext_artillery2"     // si_hud g_ShopTable 里的 classname
#define ART2_PROJECTILE  "grenade_launcher_projectile"
#define ART2_SHELL_MODEL "models/weapons/gl_grenade.mdl"   // 候选，实测 m_ModelName 确认

// 瞄准/弹道常量（与 si_hud 火炮I 同源）
#define ART2_AIM_MAX_DIST 2000.0
#define ART2_CEIL_CLEAR   4096.0
#define ART2_CEIL_LOW     600.0               // 天花板 < 600 且上方非开阔 → 无效
#define ART2_CEIL_MID     900.0
#define ART2_CEIL_THIN    100.0               // 薄遮挡穿透阈值
#define ART2_GRAVITY      800.0               // 引擎重力 u/s²（落时 t=sqrt(2h/g)）
#define ART2_MAX_SHELLS   32                  // 单次弹雨上限（防 cvar 误配）
#define ART2_HEIGHT_MAX   900.0               // 室外/高顶生成高度上限（u）
#define ART2_HEIGHT_MIN   300.0               // 生成高度下限（u，低天花板室内）
#define ART2_TICK_INT     0.05                // 瞄准心跳间隔
// v1.0.1 FIX: 弹丸初速 -120 → -800（实测 18:42 日志：8 发全部缓落触地停在
// 贴地位置（z=-50，地面 -63）但引擎碰撞爆炸不触发——低速碰撞不触发
// CProjectileEntity::Touch，全部走 kill fallback 静默消失）。
// 高速砸地（触地速度 ≈700u/s）触发 Touch → 引擎爆炸特效/音效/伤害全回来。
// 垂直下落，落点仍零误差。
#define ART2_SHELL_VEL_Z  -800.0
#define ART2_FALL_MARGIN  0.8                 // 落地兜底余量（秒）

// ============================================================================
// ConVar handles
// ============================================================================
ConVar g_cvEnable;       // 总开关
ConVar g_cvTargetTime;   // 瞄准窗口（超时退款）
ConVar g_cvCountOut;     // 室外弹数
ConVar g_cvCountMid;     // 室内大（≥900）弹数
ConVar g_cvCountSmall;   // 室内小（600-900）弹数
ConVar g_cvRadiusOut;    // 室外散布半径（=瞄准圆圈）
ConVar g_cvRadiusMid;    // 室内大半径
ConVar g_cvRadiusSmall;  // 室内小半径
ConVar g_cvDelay;        // 确认后首弹延迟
ConVar g_cvStagger;      // 弹间生成间隔
ConVar g_cvCooldown;     // 轰炸后硬冷却（禁止全体购买）
ConVar g_cvShellTimeout; // 弹丸超时 Kill（防永不落地）

// ============================================================================
// 状态变量（独立插件自有，不碰 si_hud 内部）
// ============================================================================
int       g_iArt2Slot[MAXPLAYERS + 1];       // 商店槽位（仅日志）
int       g_iArt2Price[MAXPLAYERS + 1];      // 购买价格（退款用）
int       g_iArt2Magnum[MAXPLAYERS + 1];     // 服务器马格南 entref（0 = 用的是玩家自己的）
int       g_iArt2Marker[MAXPLAYERS + 1];     // env_sprite 标记 entref
Handle    g_hArt2AimTimer[MAXPLAYERS + 1];   // 瞄准心跳
float     g_fArt2AimEnd[MAXPLAYERS + 1];     // 超时 GameTime
bool      g_bArt2Aiming[MAXPLAYERS + 1];     // 瞄准中
char      g_sArt2PrevWeapon[MAXPLAYERS + 1][32];  // 原副武器 classname（恢复用）
char      g_sArt2PrevMelee[MAXPLAYERS + 1][64];   // 原近战种类名（精确恢复）
int       g_iArt2PrevUpgrade[MAXPLAYERS + 1];     // 原副武器升级位全量
int       g_iArt2PrevClip[MAXPLAYERS + 1];        // 原副武器弹匣（-1 = 不恢复）
ArrayList g_hShells;                            // 活跃弹丸 entref（换图/卸载兜底清理）
float     g_fArt2NextBuyTime;                   // 下次可购买 GameTime（轰炸中+冷却）
int       g_iBeamLaser;                         // precache 的 beam 模型索引
int       g_iBeamHalo;

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Shop Artillery II",
    author      = "suli",
    description = "榴弹炮弹雨（!shop 火炮支援II）— grenade_launcher_projectile 垂直轰炸",
    version     = PLUGIN_VERSION,
    url         = ""
};

// v1.0.2: FIX 弹丸触地不爆炸根因——m_hOwnerEntity 缺失（见 Timer_Art2SpawnShell）。
// v1.0.1: FIX 弹丸触地不爆炸（缓落速度≈0 不触发 Touch）→ 初速 -800 砸地（无效，v1.0.2 找到真根因）。

// ============================================================================
// OnPluginStart / OnMapStart / OnPluginEnd
// ============================================================================

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("si_hud_art2_enable", "1",
        "Artillery II master switch (0=off, 1=on).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTargetTime = CreateConVar("si_hud_art2_target_time", "15.0",
        "Artillery II designate window in seconds (timeout auto-refund).", FCVAR_NOTIFY, true, 1.0, true, 60.0);
    g_cvCountOut = CreateConVar("si_hud_art2_count_out", "8",
        "Artillery II shell count outdoors.", FCVAR_NOTIFY, true, 1.0, true, float(ART2_MAX_SHELLS));
    g_cvCountMid = CreateConVar("si_hud_art2_count_mid", "5",
        "Artillery II shell count indoor tall (ceiling >= 900).", FCVAR_NOTIFY, true, 1.0, true, float(ART2_MAX_SHELLS));
    g_cvCountSmall = CreateConVar("si_hud_art2_count_small", "3",
        "Artillery II shell count indoor small (600-900).", FCVAR_NOTIFY, true, 1.0, true, float(ART2_MAX_SHELLS));
    g_cvRadiusOut = CreateConVar("si_hud_art2_radius_out", "400",
        "Artillery II spread radius outdoors (= aim circle radius).", FCVAR_NOTIFY, true, 1.0);
    g_cvRadiusMid = CreateConVar("si_hud_art2_radius_mid", "300",
        "Artillery II spread radius indoor tall.", FCVAR_NOTIFY, true, 1.0);
    g_cvRadiusSmall = CreateConVar("si_hud_art2_radius_small", "200",
        "Artillery II spread radius indoor small.", FCVAR_NOTIFY, true, 1.0);
    g_cvDelay = CreateConVar("si_hud_art2_delay", "0.5",
        "Artillery II seconds after confirm before first shell.", FCVAR_NOTIFY, true, 0.0);
    g_cvStagger = CreateConVar("si_hud_art2_stagger", "0.25",
        "Artillery II seconds between shell spawns.", FCVAR_NOTIFY, true, 0.0);
    g_cvCooldown = CreateConVar("si_hud_art2_cooldown", "10.0",
        "Artillery II hard cooldown (s) after barrage ends, blocks all purchases.", FCVAR_NOTIFY, true, 0.0);
    g_cvShellTimeout = CreateConVar("si_hud_art2_shell_timeout", "10.0",
        "Artillery II shell kill-fallback timeout (s): projectile has no fuse, stuck shells get killed (damage still injected by gl_splash_fix).", FCVAR_NOTIFY, true, 1.0);

    AutoExecConfig(true, "l4d2_shop_artillery2");

    HookEvent("weapon_fire", Event_Art2WeaponFire);

    // 弹丸模型 precache：直接 CreateEntityByName 需要引擎已注册模型；
    // 引擎发射榴弹时自动注册，但首局无人发射过 → 手动 precache 保险。
    // 缺文件只记日志不崩（运行时读 m_ModelName 兜底对照）。
    PrecacheModel(ART2_SHELL_MODEL, true);
    // beam/halo：瞄准圆圈 + 光柱（reload 后 OnMapStart 不重跑 → 这里补）
    g_iBeamLaser = PrecacheModel("sprites/laserbeam.vmt");
    g_iBeamHalo = PrecacheModel("sprites/halo01.vmt");
    PrecacheModel("sprites/glow01.spr", true);

    // 依赖说明：si_hud 商店扩展 API（v1.7.93+）。native/forward 由 SM 运行时
    // 懒绑定——si_hud 未加载时购买 forward 不触发（si_hud 退款"不可用"），
    // 不会崩溃；GetFeatureStatus 对未 require 的 native 恒报 Unavailable，
    // 不可用作加载检查（SM 1.12 行为），故此处仅记录日志。
    LogMessage("[art2] loaded v%s — requires l4d2_si_hud >= v1.7.93 (SH_GetWallet/SH_AddWallet/SH_OnShopItemBuy)", PLUGIN_VERSION);
}

public void OnMapStart()
{
    // 换图后 sprite/beam 索引归 0，重 precache（si_hud 火炮I 同款）
    g_iBeamLaser = PrecacheModel("sprites/laserbeam.vmt");
    g_iBeamHalo = PrecacheModel("sprites/halo01.vmt");
    PrecacheModel("sprites/glow01.spr", true);
}

public void OnMapEnd()
{
    Art2_CleanupAll();
}

public void OnPluginEnd()
{
    Art2_CleanupAll();
}

// ============================================================================
// 商店购买接管（si_hud forward）
// ============================================================================

public Action SH_OnShopItemBuy(int client, int slot, const char[] classname, int price)
{
    if (!StrEqual(classname, ART2_SLOT_CLASS))
        return Plugin_Continue;

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;

    if (!g_cvEnable.BoolValue)
    {
        PrintToChat(client, "\x04[商店]\x01 \x05火炮支援II\x01 当前不可用，积分已退回");
        return Plugin_Stop;
    }
    if (!IsPlayerAlive(client))
    {
        PrintToChat(client, "\x04[商店]\x01 倒地/死亡状态无法使用\x05火炮支援II\x01，积分已退回");
        return Plugin_Stop;
    }
    float wait = g_fArt2NextBuyTime - GetGameTime();
    if (wait > 0.0)
    {
        PrintToChat(client, "\x04[商店]\x01 \x05火炮支援II\x01 冷却中，\x03%d\x01 秒后可购买",
            RoundToCeil(wait));
        return Plugin_Stop;
    }
    if (g_bArt2Aiming[client])
    {
        PrintToChat(client, "\x04[商店]\x01 你已在瞄准中，请先确认或取消（右键）");
        return Plugin_Stop;
    }

    Art2StartDesignate(client, slot, price);
    return Plugin_Handled;                 // si_hud 扣款已完成，本插件接管后续
}

// ============================================================================
// 瞄准指示（BFV 式，移植自 si_hud 火炮I ArtStartDesignate）
// ============================================================================

void Art2StartDesignate(int client, int slot, int price)
{
    g_iArt2Slot[client] = slot;
    g_iArt2Price[client] = price;
    g_iArt2Magnum[client] = 0;
    g_sArt2PrevWeapon[client][0] = '\0';
    g_sArt2PrevMelee[client][0] = '\0';
    g_iArt2PrevUpgrade[client] = 0;
    g_iArt2PrevClip[client] = -1;
    g_fArt2AimEnd[client] = GetGameTime() + g_cvTargetTime.FloatValue;

    // 副武器处理：已是马格南 → 不动（用户拍板）；否则保存原武器 → 切服务器
    // 马格南（原武器掉落 → 立即移除；恢复时按 classname 重给 + 补升级位/弹匣）。
    // 近战没有 m_upgradeBitVec/m_iClip1 → HasEntProp 保护读属性（防异常中止）。
    int weapon = GetPlayerWeaponSlot(client, 1);
    if (weapon > 0 && IsValidEntity(weapon))
    {
        char cls[32];
        GetEntityClassname(weapon, cls, sizeof(cls));
        if (!StrEqual(cls, "weapon_pistol_magnum"))
        {
            g_sArt2PrevMelee[client][0] = '\0';
            if (StrEqual(cls, "weapon_melee"))
                Art2_SaveMeleeName(client, weapon);
            if (HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
                g_iArt2PrevUpgrade[client] = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
            if (HasEntProp(weapon, Prop_Send, "m_iClip1"))
                g_iArt2PrevClip[client] = GetEntProp(weapon, Prop_Send, "m_iClip1");
            strcopy(g_sArt2PrevWeapon[client], sizeof(g_sArt2PrevWeapon[]), cls);
            int ref = EntIndexToEntRef(weapon);
            int newWep = GivePlayerItem(client, "weapon_pistol_magnum");
            int dropped = EntRefToEntIndex(ref);
            if (dropped > 0 && IsValidEntity(dropped))
                AcceptEntityInput(dropped, "Kill");
            if (newWep > 0)
                g_iArt2Magnum[client] = EntIndexToEntRef(newWep);
            LogMessage("[art2] start client=%N slot1=%s prevMelee='%s' upgrade=%d clip=%d magnum=%d",
                client, cls, g_sArt2PrevMelee[client], g_iArt2PrevUpgrade[client],
                g_iArt2PrevClip[client], newWep);
        }
        else
        {
            // 已是马格南 → 不切；0 弹提示（否则无法开火确认，只能等超时退款）
            if (HasEntProp(weapon, Prop_Send, "m_iClip1")
                && GetEntProp(weapon, Prop_Send, "m_iClip1") <= 0)
                PrintToChat(client, "\x04[商店]\x01 你的马格南弹匣为空，\x05换弹后开火\x01确认轰炸（超时自动退款）");
            LogMessage("[art2] start client=%N already magnum", client);
        }
    }
    else
    {
        int newWep = GivePlayerItem(client, "weapon_pistol_magnum");
        if (newWep > 0)
            g_iArt2Magnum[client] = EntIndexToEntRef(newWep);
        LogMessage("[art2] start client=%N empty slot1, magnum=%d", client, newWep);
    }

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
        g_iArt2Marker[client] = EntIndexToEntRef(sprite);
    }

    // 瞄准状态最后置位——上面任何一步抛错都不会留下"瞄准中但 timer 未建"卡死
    g_bArt2Aiming[client] = true;
    g_hArt2AimTimer[client] = CreateTimer(ART2_TICK_INT, Timer_Art2Aim,
        GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    PrintToChat(client, "\x04[商店]\x01 已购买 \x05火炮支援II\x01（-\x03%d\x01 可用积分）。\x05瞄准轰炸区域后开火（马格南）确认\x01，\x05右键取消\x01，\x03%.0f 秒\x01内有效",
        price, g_cvTargetTime.FloatValue);
}

// 退出瞄准指示：清理标记/马格南/心跳，恢复原副武器，可退款
void Art2EndDesignate(int client, bool refund, bool restoreWeapon = true)
{
    if (!g_bArt2Aiming[client]) return;
    g_bArt2Aiming[client] = false;

    if (g_hArt2AimTimer[client] != null)
    {
        KillTimer(g_hArt2AimTimer[client]);
        g_hArt2AimTimer[client] = null;
    }

    int marker = EntRefToEntIndex(g_iArt2Marker[client]);
    if (marker > 0 && IsValidEntity(marker))
        AcceptEntityInput(marker, "Kill");
    g_iArt2Marker[client] = 0;

    int magnum = EntRefToEntIndex(g_iArt2Magnum[client]);
    if (magnum > 0 && IsValidEntity(magnum))
    {
        if (IsClientInGame(client))
            RemovePlayerItem(client, magnum);
        AcceptEntityInput(magnum, "Kill");
    }
    g_iArt2Magnum[client] = 0;

    // 恢复原副武器（重给 classname + 补升级位/弹匣；断线/死亡跳过）。
    // 近战恢复：GivePlayerItem("weapon_melee") 无 script 名 → 引擎返回 -1，
    // 定稿方案 = 兜底手枪保证槽位不空 + 原近战种类放面前 50u 可捡 +
    // 0.4s 核查贴近提示（与 si_hud 火炮I v1.7.85 定稿一致）。
    if (restoreWeapon && g_sArt2PrevWeapon[client][0] != '\0'
        && IsClientInGame(client) && GetClientTeam(client) == 2)
    {
        int newWep = 0;
        if (StrEqual(g_sArt2PrevWeapon[client], "weapon_melee"))
        {
            newWep = GivePlayerItem(client, "weapon_pistol");
            if (g_sArt2PrevMelee[client][0] != '\0')
            {
                int meleeEnt = CreateEntityByName("weapon_melee");
                if (meleeEnt > 0)
                {
                    DispatchKeyValue(meleeEnt, "melee_script_name", g_sArt2PrevMelee[client]);
                    DispatchSpawn(meleeEnt);
                    float pos[3], ang[3], fwd[3];
                    GetClientAbsOrigin(client, pos);
                    GetClientEyeAngles(client, ang);
                    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
                    pos[0] += fwd[0] * 50.0;
                    pos[1] += fwd[1] * 50.0;
                    pos[2] += 5.0;
                    TeleportEntity(meleeEnt, pos, NULL_VECTOR, NULL_VECTOR);
                    DataPack pack;
                    CreateDataTimer(0.4, Timer_Art2RestoreCheck, pack,
                        TIMER_FLAG_NO_MAPCHANGE);
                    WritePackCell(pack, GetClientUserId(client));
                    WritePackCell(pack, EntIndexToEntRef(meleeEnt));
                }
            }
            LogMessage("[art2] end restore client=%N prevWeapon='weapon_melee' "
                ... "pistol=%d slot1=%d",
                client, newWep, GetPlayerWeaponSlot(client, 1));
        }
        else
        {
            newWep = GivePlayerItem(client, g_sArt2PrevWeapon[client]);
            if (g_iArt2PrevUpgrade[client] != 0 && newWep > 0 && IsValidEntity(newWep)
                && HasEntProp(newWep, Prop_Send, "m_upgradeBitVec"))
                SetEntProp(newWep, Prop_Send, "m_upgradeBitVec", g_iArt2PrevUpgrade[client]);
            if (g_iArt2PrevClip[client] >= 0 && newWep > 0 && IsValidEntity(newWep)
                && HasEntProp(newWep, Prop_Send, "m_iClip1"))
                SetEntProp(newWep, Prop_Send, "m_iClip1", g_iArt2PrevClip[client]);
            LogMessage("[art2] end restore client=%N prevWeapon='%s' slot1=%d upgrade=%d clip=%d",
                client, g_sArt2PrevWeapon[client],
                GetPlayerWeaponSlot(client, 1), g_iArt2PrevUpgrade[client], g_iArt2PrevClip[client]);
        }
    }
    g_sArt2PrevWeapon[client][0] = '\0';
    g_sArt2PrevMelee[client][0] = '\0';
    g_iArt2PrevUpgrade[client] = 0;
    g_iArt2PrevClip[client] = -1;

    if (refund)
    {
        SH_AddWallet(client, g_iArt2Price[client]);   // si_hud 积分加回（退款）
        LogMessage("[art2] designate cancelled client=%N refund=%d", client, g_iArt2Price[client]);
    }
}

// 近战恢复核查：面前掉落的近战 0.4s 后若玩家仍未拾取，放回脚下（touch 拾取）
public Action Timer_Art2RestoreCheck(Handle timer, DataPack pack)
{
    ResetPack(pack);
    int userid = ReadPackCell(pack);
    int ref = ReadPackCell(pack);
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Stop;
    int slot1 = GetPlayerWeaponSlot(client, 1);
    if (slot1 > 0 && IsValidEntity(slot1))
        return Plugin_Stop;                       // 已拾取装备

    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Stop;
    float pos[3];
    GetClientAbsOrigin(client, pos);
    pos[2] += 30.0;
    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
    LogMessage("[art2] restore check: melee not picked, dropped at feet client=%N", client);
    return Plugin_Stop;
}

// 近战种类名读取——m_MeleeWeaponName(Prop_Send) 实测读空 → 多属性名/多域回退
void Art2_SaveMeleeName(int client, int weapon)
{
    char name[64];
    static const char props[][] = { "m_MeleeWeaponName", "m_szMeleeWeaponName" };
    for (int i = 0; i < 2 && g_sArt2PrevMelee[client][0] == '\0'; i++)
    {
        if (HasEntProp(weapon, Prop_Send, props[i]))
            GetEntPropString(weapon, Prop_Send, props[i], name, sizeof(name));
        if (name[0] == '\0' && HasEntProp(weapon, Prop_Data, props[i]))
            GetEntPropString(weapon, Prop_Data, props[i], name, sizeof(name));
        if (name[0] != '\0')
        {
            strcopy(g_sArt2PrevMelee[client], sizeof(g_sArt2PrevMelee[]), name);
            break;
        }
        name[0] = '\0';
    }
}

// 瞄准心跳：更新标记（圆圈+光柱+光点）+ 右键取消 + 超时/死亡
public Action Timer_Art2Aim(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0) return Plugin_Stop;          // 断线（OnClientDisconnect 已清理）
    if (!g_bArt2Aiming[client]) return Plugin_Stop;

    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        Art2EndDesignate(client, true);           // 死亡 → 取消退款
        return Plugin_Stop;
    }

    if (GetGameTime() >= g_fArt2AimEnd[client])
    {
        PrintToChat(client, "\x04[商店]\x01 火炮支援II瞄准超时，积分已退回");
        Art2EndDesignate(client, true);
        return Plugin_Stop;
    }

    if (GetClientButtons(client) & IN_ATTACK2)    // 右键 → 取消退款
    {
        PrintToChat(client, "\x04[商店]\x01 已取消火炮支援II，积分已退回");
        Art2EndDesignate(client, true);
        return Plugin_Stop;
    }

    // 标记更新：瞄准点 + 圆圈（爆炸范围）+ 光柱；合法绿 / 无效红
    float target[3];
    bool valid;
    Art2_AimPoint(client, target, valid);

    bool openAbove;
    float ceiling = Art2_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART2_CEIL_LOW && !openAbove)
        valid = false;

    int color[4] = { 0, 255, 0, 255 };            // 合法绿
    int radius = 150;
    if (valid)
    {
        int count; float r, h;
        Art2_PickParams(ceiling, openAbove, count, r, h);
        radius = RoundToNearest(r);
    }
    else
    {
        color[0] = 255; color[1] = 0; color[2] = 0;   // 无效红
    }

    int marker = EntRefToEntIndex(g_iArt2Marker[client]);
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

// 马格南开火 = 确认轰炸（weapon_fire 事件；只用设计器马格南判定）
public Action Event_Art2WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !g_bArt2Aiming[client])
        return Plugin_Continue;

    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (active <= 0)
        return Plugin_Continue;
    if (g_iArt2Magnum[client] != 0 && EntRefToEntIndex(g_iArt2Magnum[client]) != active)
        return Plugin_Continue;                   // 开的不是设计器马格南（如主武器）
    char cls[32];
    GetEntityClassname(active, cls, sizeof(cls));
    if (!StrEqual(cls, "weapon_pistol_magnum"))
        return Plugin_Continue;

    float target[3];
    bool valid;
    Art2_AimPoint(client, target, valid);
    bool openAbove;
    float ceiling = Art2_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART2_CEIL_LOW && !openAbove)
        valid = false;
    LogMessage("[art2] confirm client=%N valid=%d ceiling=%.0f openAbove=%d target=(%.0f %.0f %.0f)",
        client, valid, ceiling, openAbove, target[0], target[1], target[2]);
    if (!valid)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效：需要能落到地面的开阔区域（天花板过低或瞄天空），请重新瞄准开火");
        return Plugin_Continue;                   // 留在瞄准模式，可再次开火
    }

    Art2EndDesignate(client, false);
    Art2_ConfirmStrike(client, target);
    return Plugin_Continue;
}

// 准星瞄准点（只碰世界固体，不碰玩家/特感）；瞄天花板底面 → 落点下移 120u
void Art2_AimPoint(int client, float out[3], bool &valid)
{
    valid = false;
    float eye[3], ang[3], fwd[3], end[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    end = eye;
    end[0] += fwd[0] * ART2_AIM_MAX_DIST;
    end[1] += fwd[1] * ART2_AIM_MAX_DIST;
    end[2] += fwd[2] * ART2_AIM_MAX_DIST;

    char hitType[16];
    strcopy(hitType, sizeof(hitType), "brush");
    Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID_BRUSHONLY,
        RayType_EndPoint, Art2_TraceFilter, client);
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
        // 水面兜底（水面是 CONTENTS_WATER 不是 brush；水面 = 开阔落点，合法）
        Handle trw = TR_TraceRayFilterEx(eye, end, CONTENTS_WATER,
            RayType_EndPoint, Art2_TraceFilter, client);
        if (TR_DidHit(trw))
        {
            TR_GetEndPosition(out, trw);
            valid = true;
            strcopy(hitType, sizeof(hitType), "water");
        }
        delete trw;
    }
    delete tr;
    LogMessage("[art2] aimpoint client=%N hit=%s valid=%d pos=(%.0f %.0f %.0f)",
        client, hitType, valid, out[0], out[1], out[2]);
}

public bool Art2_TraceFilter(int entity, int contentsMask, any data)
{
    return entity != data;
}

// 落点上方找天花板：返回距离；0 = 4096u 内无遮挡（室外）
// 薄遮挡穿透（树冠/雨棚 <100u）+ 侧面命中穿透（树干/柱）——与 si_hud 火炮I 同源
float Art2_FindCeiling(const float pos[3], bool &openAbove)
{
    openAbove = false;
    float from[3], to[3];
    from = pos;
    from[2] += 60.0;
    to = from;
    to[2] += ART2_CEIL_CLEAR;

    float dist = 0.0;
    int hops = 0;
    int hits = 0;
    float lastNormal[3] = { 0.0, 0.0, 0.0 };
    float lastHit[3];
    while (hops < 4)
    {
        Handle tr = TR_TraceRayFilterEx(from, to, MASK_SOLID,
            RayType_EndPoint, Art2_TraceFilter, -1);
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
        probe[2] += ART2_CEIL_THIN;
        Handle tr2 = TR_TraceRayFilterEx(lastHit, probe, MASK_SOLID,
            RayType_EndPoint, Art2_TraceFilter, -1);
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
        to2[2] += ART2_CEIL_CLEAR;
        Handle tr = TR_TraceRayFilterEx(above, to2, MASK_SOLID,
            RayType_EndPoint, Art2_TraceFilter, -1);
        openAbove = !TR_DidHit(tr);
        delete tr;
    }
    LogMessage("[art2] ceiling pos=(%.0f %.0f %.0f) dist=%.0f openAbove=%d hops=%d hits=%d",
        pos[0], pos[1], pos[2], dist, openAbove, hops, hits);
    return dist;
}

// 三级参数：室外 / 室内大(≥900) / 室内小(600-900) / 遮挡下短落(<600 且上方开阔)
// 弹丸版高度 = 落点上方（吊顶下 200u 起，防碰头顶结构；室外固定上限 900）
void Art2_PickParams(float ceiling, bool openAbove, int &count, float &radius, float &height)
{
    if (ceiling <= 0.0)
    {
        count  = g_cvCountOut.IntValue;
        radius = g_cvRadiusOut.FloatValue;
        height = ART2_HEIGHT_MAX;
    }
    else if (ceiling >= ART2_CEIL_MID)
    {
        count  = g_cvCountMid.IntValue;
        radius = g_cvRadiusMid.FloatValue;
        height = ceiling - 200.0;
    }
    else if (openAbove)
    {
        // 开阔（平台/桥上方有天）——按室外规模炸，高度压到遮挡下短落
        count  = g_cvCountOut.IntValue;
        radius = g_cvRadiusOut.FloatValue;
        height = ceiling - 200.0;
    }
    else if (ceiling >= ART2_CEIL_LOW)
    {
        count  = g_cvCountSmall.IntValue;     // 封闭矮房（600-900）：小规模
        radius = g_cvRadiusSmall.FloatValue;
        height = ceiling - 200.0;
    }
    else
    {
        count  = g_cvCountSmall.IntValue;     // 拒绝级：确认前被拦截，不会真正使用
        radius = g_cvRadiusSmall.FloatValue;
        height = ceiling - 200.0;
    }
    if (height < ART2_HEIGHT_MIN) height = ART2_HEIGHT_MIN;
    if (height > ART2_HEIGHT_MAX) height = ART2_HEIGHT_MAX;
    if (count < 1) count = 1;
    if (count > ART2_MAX_SHELLS) count = ART2_MAX_SHELLS;
}

// ============================================================================
// 轰炸（榴弹弹丸雨）
// ============================================================================

// 确认轰炸：锁定落点 → 全服警报 → 错峰生成弹丸
void Art2_ConfirmStrike(int client, float target[3])
{
    if (g_hShells == null)
        g_hShells = new ArrayList();

    bool openAbove;
    float ceiling = Art2_FindCeiling(target, openAbove);
    int count; float radius, height;
    Art2_PickParams(ceiling, openAbove, count, radius, height);

    // 轰炸总时长 = 首弹延迟 + 末弹生成 + 坠落 + 余量（弹丸碰撞即爆，无燃烧段）
    float fallT = SquareRoot((2.0 * height) / ART2_GRAVITY);
    float duration = g_cvDelay.FloatValue + float(count - 1) * g_cvStagger.FloatValue
        + fallT + 1.0;
    g_fArt2NextBuyTime = GetGameTime() + duration + g_cvCooldown.FloatValue;

    PrintToChatAll("\x04[商店]\x01 \x05火炮支援来袭，注意躲避！\x01剩余：\x03%d\x01 秒", RoundToCeil(duration));
    PrintToChatAll("\x04[商店]\x01 \x05%N\x01 召唤了火炮支援II：榴弹炮弹雨即将从天而降！", client);
    CreateTimer(duration, Timer_Art2NotifyEnd, INVALID_HANDLE, TIMER_FLAG_NO_MAPCHANGE);

    for (int i = 0; i < count; i++)
    {
        DataPack dp = new DataPack();
        dp.WriteFloat(target[0]);
        dp.WriteFloat(target[1]);
        dp.WriteFloat(target[2]);
        dp.WriteFloat(radius);
        dp.WriteFloat(height);
        dp.WriteCell(GetClientUserId(client));
        CreateTimer(g_cvDelay.FloatValue + float(i) * g_cvStagger.FloatValue,
            Timer_Art2SpawnShell, dp, TIMER_FLAG_NO_MAPCHANGE);
    }

    LogMessage("[art2] strike client=%N target=(%.0f,%.0f,%.0f) ceiling=%.0f count=%d r=%.0f h=%.0f",
        client, target[0], target[1], target[2], ceiling, count, radius, height);
}

public Action Timer_Art2NotifyEnd(Handle timer)
{
    PrintToChatAll("\x04[商店]\x01 \x05火炮支援结束\x01，\x03%.0f\x01 秒后可重新购买", g_cvCooldown.FloatValue);
    return Plugin_Continue;
}

// 生成单颗弹丸（圆内均匀散布 → 垂直下坠，落点 = 瞄准点投影零误差）
public Action Timer_Art2SpawnShell(Handle timer, DataPack dp)
{
    dp.Reset();
    float target[3];
    target[0] = dp.ReadFloat();
    target[1] = dp.ReadFloat();
    target[2] = dp.ReadFloat();
    float radius = dp.ReadFloat();
    float height = dp.ReadFloat();
    int userid = dp.ReadCell();
    delete dp;

    int buyer = GetClientOfUserId(userid);

    float ang = GetRandomFloat(0.0, 6.2831853);
    float r = radius * SquareRoot(GetRandomFloat(0.0, 1.0));
    float pos[3];
    pos[0] = target[0] + Cosine(ang) * r;
    pos[1] = target[1] + Sine(ang) * r;
    pos[2] = target[2] + height;

    int ent = CreateEntityByName(ART2_PROJECTILE);
    if (ent == -1)
    {
        LogError("[art2] spawn %s failed", ART2_PROJECTILE);
        return Plugin_Continue;
    }
    DispatchSpawn(ent);

    // 击杀归属：弹丸引擎伤害 + gl_splash_fix 注入（Witch/ExtendSplash/SI）全记购买者。
    // 购买者离线/死亡 → 0（世界），伤害照发（SI 引擎路径）但无归属——可接受边缘。
    if (buyer > 0 && IsClientInGame(buyer))
        SetEntPropEnt(ent, Prop_Send, "m_hThrower", buyer);

    // v1.0.2 FIX（触地不爆炸根因）: 必须设 m_hOwnerEntity（拥有者）——
    // 引擎弹丸 Touch 防自爆判定 `if (pOther == GetOwnerEntity()) return;`，
    // 无 owner 时 GetOwnerEntity() 返回 0 = worldspawn（世界），弹丸触地时
    // pOther=世界 → 0==0 → 引擎以为弹丸碰了自己 → 永远跳过爆炸（v1.0.0/1.0.1
    // 实测：-120 缓落与 -800 砸地均不爆）。设 owner=购买者后世界≠owner →
    // 触地爆炸恢复。m_hThrower（投掷者，gl_splash_fix 归属）是另一个属性，
    // 两者都要设。
    if (buyer > 0 && IsClientInGame(buyer))
    {
        if (HasEntProp(ent, Prop_Send, "m_hOwnerEntity"))
            SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", buyer);
        else if (HasEntProp(ent, Prop_Data, "m_hOwnerEntity"))
            SetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity", buyer);
    }

    // v1.0.4 FIX（对照实锤）: ①不设 m_flGravity——引擎 GL 弹丸默认 0.4，
    // 之前强制 1.0 是我引入的差异（对照日志 gravity 1.00 vs 0.40）。
    // ②清 EFL_IN_BRUSH(0x4000)+EFL_IN_BOUNCE(0x8000)：CreateEntityByName 时
    // 实体原点在 0,0,0，DispatchSpawn 在原点做 brush 包含检查（若原点在世界
    // 几何内 → 打上 IN_BRUSH），Teleport 到落点后标志不清 → 引擎对带
    // IN_BRUSH 的实体跳过世界 brush 碰撞 → Touch(世界) 永不触发 → 永不爆炸。
    // 玩家发射的弹丸 spawn 在枪口（无 IN_BRUSH），对照日志 eflags
    // 0x204c000(ours) vs 0x2040000(launched)。清标志后与发射态一致。
    if (HasEntProp(ent, Prop_Data, "m_iEFlags"))
    {
        int flags = GetEntProp(ent, Prop_Data, "m_iEFlags");
        if (flags & 0xC000)
            SetEntProp(ent, Prop_Data, "m_iEFlags", flags & ~0xC000);
    }

    float vel[3] = { 0.0, 0.0, ART2_SHELL_VEL_Z };   // 垂直下坠（落点零误差）
    TeleportEntity(ent, pos, NULL_VECTOR, vel);

    int ref = EntIndexToEntRef(ent);
    if (ref != 0 && g_hShells != null)
        g_hShells.Push(ref);

    // 落地兜底：fallT+0.8s 弹丸仍存活（悬停/穿模）= 引擎碰撞没触发 → Kill 输入
    // → gl_splash_fix OnEntityDestroyed 注入全伤害管线（无特效音效但伤害不丢）
    float fallT = SquareRoot((2.0 * height) / ART2_GRAVITY);
    DataPack dpChk = new DataPack();
    dpChk.WriteCell(ref);
    CreateTimer(fallT + ART2_FALL_MARGIN, Timer_Art2ShellCheck, dpChk,
        TIMER_FLAG_NO_MAPCHANGE);

    // 超时兜底：弹丸无 fuse 计时，防卡地图缝隙/永不落地
    DataPack dpTo = new DataPack();
    dpTo.WriteCell(ref);
    CreateTimer(g_cvShellTimeout.FloatValue, Timer_Art2ShellTimeout, dpTo,
        TIMER_FLAG_NO_MAPCHANGE);

    LogMessage("[art2] shell %d spawned pos=(%.0f %.0f %.0f) h=%.0f buyer=%N",
        ent, pos[0], pos[1], pos[2], height, buyer > 0 ? buyer : 0);
    return Plugin_Continue;
}

// 落地兜底：该爆没爆（弹丸还在）→ 依次试引擎爆炸输入（Explode/Detonate/
// SelfExplode——pipe bomb 有 SelfExplode 输入，GL 弹丸可能也有），全无效
// 才 Kill（Kill 触发 gl_splash_fix 伤害注入，无特效音效）
public Action Timer_Art2ShellCheck(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref = dp.ReadCell();
    delete dp;

    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Continue;                 // 已引擎碰撞爆炸 → 无事

    float pos[3];
    GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
    LogMessage("[art2] shell %d still alive at (%.0f %.0f %.0f) — trying explode inputs",
        ent, pos[0], pos[1], pos[2]);
    AcceptEntityInput(ent, "Explode");
    if (IsValidEntity(ent))
        AcceptEntityInput(ent, "Detonate");
    if (IsValidEntity(ent))
        AcceptEntityInput(ent, "SelfExplode");
    if (IsValidEntity(ent))
    {
        LogMessage("[art2] shell %d explode inputs ignored — kill fallback "
            ... "(gl_splash_fix injects damage on destroy)", ent);
        AcceptEntityInput(ent, "Kill");
    }
    return Plugin_Continue;
}

// v1.0.3 诊断：hook 所有 GL 弹丸（玩家发射的 + 我们生成的）dump 属性到日志。
// 对照"正常发射能爆的弹丸 vs 我们生成不爆的弹丸"的属性差异 → 找到缺的状态。
// 用法：日志里找两行 [art2] dump ours=0（玩家发射，要爆的）和 ours=1（我们的）。
public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity < 1 || classname[0] != 'g')
        return;
    if (StrEqual(classname, ART2_PROJECTILE))
        RequestFrame(Frame_Art2DumpShell, EntIndexToEntRef(entity));
}

void Frame_Art2DumpShell(int ref)
{
    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return;

    int ours = 0;
    if (g_hShells != null && g_hShells.FindValue(EntIndexToEntRef(ent)) != -1)
        ours = 1;

    int movetype = -1, solid = -1, eflags = -1, spawnflags = -1, model = -1;
    float gravity = -1.0, damage = -1.0;
    int owner = -1, thrower = -1;
    if (HasEntProp(ent, Prop_Data, "m_nMovetype"))
        movetype = GetEntProp(ent, Prop_Data, "m_nMovetype");
    if (HasEntProp(ent, Prop_Data, "m_nSolidType"))
        solid = GetEntProp(ent, Prop_Data, "m_nSolidType");
    if (HasEntProp(ent, Prop_Data, "m_iEFlags"))
        eflags = GetEntProp(ent, Prop_Data, "m_iEFlags");
    if (HasEntProp(ent, Prop_Data, "m_spawnflags"))
        spawnflags = GetEntProp(ent, Prop_Data, "m_spawnflags");
    if (HasEntProp(ent, Prop_Send, "m_nModelIndex"))
        model = GetEntProp(ent, Prop_Send, "m_nModelIndex");
    if (HasEntProp(ent, Prop_Data, "m_flGravity"))
        gravity = GetEntPropFloat(ent, Prop_Data, "m_flGravity");
    if (HasEntProp(ent, Prop_Send, "m_flDamage"))
        damage = GetEntPropFloat(ent, Prop_Send, "m_flDamage");
    if (HasEntProp(ent, Prop_Send, "m_hOwnerEntity"))
        owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
    else if (HasEntProp(ent, Prop_Data, "m_hOwnerEntity"))
        owner = GetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity");
    if (HasEntProp(ent, Prop_Send, "m_hThrower"))
        thrower = GetEntPropEnt(ent, Prop_Send, "m_hThrower");

    LogMessage("[art2] dump ent=%d ours=%d movetype=%d solid=%d eflags=0x%x "
        ... "spawnflags=%d model=%d gravity=%.2f damage=%.1f owner=%d thrower=%d",
        ent, ours, movetype, solid, eflags, spawnflags, model, gravity, damage, owner, thrower);
}

// 超时兜底：长时间未爆（卡缝隙等）→ Kill 止损
public Action Timer_Art2ShellTimeout(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref = dp.ReadCell();
    delete dp;

    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Continue;

    LogMessage("[art2] shell %d timed out — kill fallback", ent);
    AcceptEntityInput(ent, "Kill");
    return Plugin_Continue;
}

// ============================================================================
// 清理（换图 / 卸载 / reload 兜底）
// ============================================================================

void Art2_CleanupAll()
{
    g_fArt2NextBuyTime = 0.0;                   // 换图清冷却（通知定时器随图自动清）

    for (int i = 1; i <= MaxClients; i++)
    {
        // restoreWeapon=false——换图/卸载时机不恢复武器（重生自动重置，防竞态）
        if (g_bArt2Aiming[i])
            Art2EndDesignate(i, true, false);
    }

    if (g_hShells != null)
    {
        for (int i = 0; i < g_hShells.Length; i++)
        {
            int ent = EntRefToEntIndex(g_hShells.Get(i));
            if (ent > 0 && IsValidEntity(ent))
                AcceptEntityInput(ent, "Kill");
        }
        g_hShells.Clear();
    }
}

// 断线取消瞄准（退款；不恢复武器——人已不在场）
public void OnClientDisconnect(int client)
{
    Art2EndDesignate(client, true, false);
}
