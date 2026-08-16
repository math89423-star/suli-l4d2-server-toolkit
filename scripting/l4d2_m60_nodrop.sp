// ============================================================================
// L4D2 M60 NoDrop — 防止 M60 空弹后被引擎自动丢弃
//
// 原理（2026-08-20 对运行中 server_srv.so 反汇编验证）：
//   CRifle_M60::PrimaryAttack() 在 m_iClip1 == 0 时执行：
//     CCSPlayer::DropWeapon(owner, weapon, true, NULL)
//     + CBaseCombatCharacter::SwitchToNextBestWeapon(NULL)
//     + CBaseEntity::SUB_StartFadeOut(...)
//   整块丢弃逻辑。
//   分支指令为 `0F 85 67 F9 FF FF`（jnz rel32，正常返回路径在 0x...67a）：
//   clip != 0 → jnz 跳走（正常）；clip == 0 → 落入丢弃块。
//   补丁：偏移 222 处字节 0x85 -> 0x8D（jnz -> jge）。clip 恒 >= 0，
//   SF==OF 恒成立 → 跳转恒走正常返回路径 → 丢弃块永不执行。
//   对 Windows 构建（0x75 jne 短跳）同样处理：0x75 -> 0xEB。
//   应用前校验字节，版本更新导致偏移变化时只报错不打补丁（不写坏内存）。
//
// 移植自 LuxLuma 的 [L4D2] M60_NoDrop_AmmoPile_patch (GPLv3)。
// 去掉了 ammo pile 补丁（CWeaponAmmoSpawn::Use）与弹药量 cvar 部分：
// 本服 M60 后备弹药由 l4d2_ammo_set (AmmoSets, hotgunammo 192) 管理，
// 弹药补充由商店体系负责（见 l4d2_shop），地图 ammo pile 是否给 M60 补弹
// 后续如需再单独处理。
//
// 保留了 Lux 的「地面 0 发 M60 拾取保护」：手动丢出的空 M60 在地面暂时
// 显示 1 发（否则引擎拾取处理异常），玩家拾取瞬间减回 0 发。
// ============================================================================

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define GAMEDATA "l4d2_m60_nodrop"
#define PLUGIN_VERSION "1.0.0"

Address g_addrM60Drop = Address_Null;
int g_iM60DropOffset = -1;
int g_iM60DropOriginalByte = -1;

ConVar g_cvEnable;

bool g_bM60AddedClip[2049];
int g_iM60Ref[2049];

public Plugin myinfo = {
    name = "L4D2 M60 NoDrop",
    author = "claude (adapted from LuxLuma)",
    description = "M60 空弹不丢弃（patch CRifle_M60::PrimaryAttack）+ 地面 0 发 M60 拾取保护",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("sm_m60_nodrop", "1", "M60 空弹不丢弃补丁开关（0=禁用；运行时改需 reload 生效）", FCVAR_NOTIFY);
    AutoExecConfig(true, "l4d2_m60_nodrop");

    Handle hGamedata = LoadGameConfigFile(GAMEDATA);
    if (hGamedata == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

    if (g_cvEnable.BoolValue)
        Patch_M60_Drop(hGamedata);

    delete hGamedata;

    RegAdminCmd("sm_m60nodrop_status", CmdStatus, ADMFLAG_ROOT, "显示 M60 NoDrop 补丁状态（当前内存字节）");

    // late load：给已在线的玩家补挂拾取保护钩子
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_WeaponCanUse, OnM60AllowPreserveClip);
            SDKHook(i, SDKHook_WeaponDrop, OnM60PreservePickup);
        }
    }
}

void Patch_M60_Drop(Handle hGamedata)
{
    Address patch = GameConfGetAddress(hGamedata, "CRifle_M60::PrimaryAttack");
    if (patch == Address_Null)
    {
        LogError("[M60NoDrop] 找不到 CRifle_M60::PrimaryAttack 签名，补丁未应用（服务器版本可能已更新）");
        return;
    }

    int offset = GameConfGetOffset(hGamedata, "CRifle_M60::PrimaryAttack");
    if (offset == -1)
    {
        LogError("[M60NoDrop] gamedata 缺少偏移，补丁未应用");
        return;
    }

    Address addr = patch + view_as<Address>(offset);
    int byte = LoadFromAddress(addr, NumberType_Int8);
    if (byte != 0x75 && byte != 0x85)
    {
        LogError("[M60NoDrop] 偏移 %d 处字节 0x%02X 与预期不符（0x75/0x85），补丁未应用（服务器版本可能已更新）", offset, byte);
        return;
    }

    g_addrM60Drop = addr;
    g_iM60DropOffset = offset;
    g_iM60DropOriginalByte = byte;

    if (byte == 0x75)
        StoreToAddress(g_addrM60Drop, 0xEB, NumberType_Int8);   // jne -> jmp（Windows 短跳）
    else
        StoreToAddress(g_addrM60Drop, 0x8D, NumberType_Int8);   // 0F 85 jnz -> 0F 8D jge（Linux）

    PrintToServer("[M60NoDrop] CRifle_M60::PrimaryAttack 补丁已应用 (offset=%d, 0x%02X -> %s)",
        offset, byte, byte == 0x75 ? "0xEB" : "0x8D");
}

public void OnPluginEnd()
{
    if (g_addrM60Drop != Address_Null)
    {
        StoreToAddress(g_addrM60Drop, g_iM60DropOriginalByte, NumberType_Int8);
        PrintToServer("[M60NoDrop] CRifle_M60::PrimaryAttack 已还原 (0x%02X)", g_iM60DropOriginalByte);
        g_addrM60Drop = Address_Null;
    }
}

// ---- 地面 0 发 M60 拾取保护（Lux 1.0.7 同款逻辑）----

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity < 1 || entity > 2048)
        return;

    g_bM60AddedClip[entity] = false;

    if (classname[0] != 'w' || !StrEqual(classname, "weapon_rifle_m60"))
        return;

    g_iM60Ref[entity] = EntIndexToEntRef(entity);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponCanUse, OnM60AllowPreserveClip);
    SDKHook(client, SDKHook_WeaponDrop, OnM60PreservePickup);
}

// 玩家即将拾取地面 M60：若它是「0 发但地面临时 1 发」的受保护实体，减回真实 0 发
public void OnM60AllowPreserveClip(int client, int weapon)
{
    if (weapon < MaxClients + 1 || !IsValidEntRef(g_iM60Ref[weapon]))
        return;

    if (!g_bM60AddedClip[weapon])
        return;

    g_bM60AddedClip[weapon] = false;

    int iClip = GetEntProp(weapon, Prop_Send, "m_iClip1");   // 地面期间可能被改成 >1，一律减 1 还原
    if (iClip >= 1)
        SetEntProp(weapon, Prop_Send, "m_iClip1", --iClip);
}

// 玩家丢出 M60 时若弹匣 <= 0：地面临时改成 1 发并标记（否则引擎对 0 发地面 M60 拾取处理异常）
public void OnM60PreservePickup(int client, int weapon)
{
    if (weapon < MaxClients + 1 || !IsValidEntRef(g_iM60Ref[weapon]))
        return;

    int iClip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (iClip <= 0)
    {
        g_bM60AddedClip[weapon] = true;
        SetEntProp(weapon, Prop_Send, "m_iClip1", 1);
    }
}

static bool IsValidEntRef(int iEntRef)
{
    return (iEntRef != 0 && EntRefToEntIndex(iEntRef) != INVALID_ENT_REFERENCE);
}

// ---- 诊断 ----

Action CmdStatus(int client, int args)
{
    if (g_addrM60Drop == Address_Null)
    {
        ReplyToCommand(client, "[M60NoDrop] 补丁未应用（gamedata 缺失/字节校验失败，见日志）");
        return Plugin_Handled;
    }

    int b = LoadFromAddress(g_addrM60Drop, NumberType_Int8);
    ReplyToCommand(client, "[M60NoDrop] 已应用：偏移 %d，当前字节 0x%02X（预期 0xEB 或 0x8D）",
        g_iM60DropOffset, b);
    return Plugin_Handled;
}
