// ============================================================================
// L4D2 M60 NoDrop + AmmoPile — M60 空弹不丢弃 + M60/GL 可通过地图弹药堆补弹
//
// v1.0.0（2026-08-16）：M60 空弹不丢弃。
//   原理（对运行中 server_srv.so 反汇编验证）：
//   CRifle_M60::PrimaryAttack() 在 m_iClip1 == 0 时执行：
//     CCSPlayer::DropWeapon(owner, weapon, true, NULL)
//     + CBaseCombatCharacter::SwitchToNextBestWeapon(NULL)
//     + CBaseEntity::SUB_StartFadeOut(...)
//   分支指令 `0F 85 67 F9 FF FF`（jnz rel32）：clip != 0 → 跳走（正常）；
//   clip == 0 → 落入丢弃块。补丁：偏移 222 处字节 0x85 -> 0x8D
//   （jnz -> jge，clip 恒 >= 0 → 跳转恒走正常返回 → 丢弃块永不执行）。
//   Windows 构建（0x75 jne 短跳）同样处理：0x75 -> 0xEB。
//   应用前校验字节，版本更新导致偏移变化时只报错不打补丁（不写坏内存）。
//
// v1.1.0（2026-08-16）：弹药堆补丁（用户拍板，GPT 调研 + 本机反汇编双重确认）——
//   CWeaponAmmoSpawn::Use() 按武器 ID 排除 M60/GL 给弹：
//     weapon->GetWeaponID(); cmp $0x15(%eax) /* GL=21 */ je reject;
//     cmp $0x25(%eax) /* M60=37 */ je reject;
//   补丁：偏移 81/101 处字节 0x15/0x25 -> 0xFF（武器 ID 永不匹配 → 排除失效，
//   弹药堆正常给弹）。+ ammo_m60_max 设非零（cvar sm_m60_ammo_max 默认 192，
//   与 AmmoSets hotgunammo 一致）——否则 M60 reserve 上限 0，给了也被吞；
//   GL 引擎上限 ammo_grenadelauncher_max 已是 30 不动。
//
// 移植自 LuxLuma 的 [L4D2] M60_NoDrop_AmmoPile_patch (GPLv3)。
// 保留了「地面 0 发 M60 拾取保护」：手动丢出的空 M60 在地面暂时显示 1 发
// （否则引擎拾取处理异常），玩家拾取瞬间减回 0 发。
// ============================================================================

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define GAMEDATA "l4d2_m60_nodrop"
#define PLUGIN_VERSION "1.1.0"

Address g_addrM60Drop = Address_Null;
int g_iM60DropOffset = -1;
int g_iM60DropOriginalByte = -1;

// v1.1.0: 弹药堆补丁状态
Address g_addrAmmoUse = Address_Null;
int g_iAmmoGLOffset = -1, g_iAmmoGLOriginal = -1;
int g_iAmmoM60Offset = -1, g_iAmmoM60Original = -1;

ConVar g_cvEnable;
ConVar g_cvAmmoPile;      // v1.1.0: 弹药堆补丁开关
ConVar g_cvM60AmmoMax;    // v1.1.0: ammo_m60_max 值

bool g_bM60AddedClip[2049];
int g_iM60Ref[2049];

public Plugin myinfo = {
    name = "L4D2 M60 NoDrop + AmmoPile",
    author = "claude (adapted from LuxLuma)",
    description = "M60 空弹不丢弃（patch CRifle_M60::PrimaryAttack）+ M60/GL 弹药堆补弹（patch CWeaponAmmoSpawn::Use）+ 地面 0 发 M60 拾取保护",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("sm_m60_nodrop", "1", "M60 空弹不丢弃补丁开关（0=禁用；运行时改需 reload 生效）", FCVAR_NOTIFY);
    g_cvAmmoPile = CreateConVar("sm_m60_ammopile", "1", "M60/GL 地图弹药堆补弹补丁开关（0=禁用；运行时改需 reload 生效）", FCVAR_NOTIFY);
    g_cvM60AmmoMax = CreateConVar("sm_m60_ammo_max", "192", "引擎 ammo_m60_max（M60 reserve 上限；0=引擎默认无后备）", FCVAR_NOTIFY);
    g_cvM60AmmoMax.AddChangeHook(OnM60AmmoMaxChanged);
    AutoExecConfig(true, "l4d2_m60_nodrop");

    Handle hGamedata = LoadGameConfigFile(GAMEDATA);
    if (hGamedata == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

    if (g_cvEnable.BoolValue)
        Patch_M60_Drop(hGamedata);
    if (g_cvAmmoPile.BoolValue)
        Patch_AmmoPile(hGamedata);

    delete hGamedata;

    RegAdminCmd("sm_m60nodrop_status", CmdStatus, ADMFLAG_ROOT, "显示 M60 NoDrop / 弹药堆补丁状态（当前内存字节）");

    ApplyM60AmmoMax();   // 热加载立即生效（正常流程 OnConfigsExecuted 也会执行）

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

// v1.1.0: 弹药堆补丁 —— CWeaponAmmoSpawn::Use 按武器 ID 排除 M60/GL 给弹
// （cmp $0x15 GL / cmp $0x25 M60 → je reject）。把两个比较立即数改成 0xFF，
// 武器 ID 永不匹配 → 排除判断失效 → 弹药堆对 M60/GL 正常给弹。
// 已对本机 server_srv.so (9309) 反汇编验证偏移 81/101 字节 = 0x15/0x25。
void Patch_AmmoPile(Handle hGamedata)
{
    Address patch = GameConfGetAddress(hGamedata, "CWeaponAmmoSpawn::Use");
    if (patch == Address_Null)
    {
        LogError("[M60NoDrop] 找不到 CWeaponAmmoSpawn::Use 签名，弹药堆补丁未应用（服务器版本可能已更新）");
        return;
    }

    int offGL = GameConfGetOffset(hGamedata, "Use_NadeLauncher_Patch");
    int offM60 = GameConfGetOffset(hGamedata, "Use_M60_Patch");
    if (offGL == -1 || offM60 == -1)
    {
        LogError("[M60NoDrop] gamedata 缺少弹药堆偏移，补丁未应用");
        return;
    }

    Address aGL = patch + view_as<Address>(offGL);
    Address aM60 = patch + view_as<Address>(offM60);
    int bGL = LoadFromAddress(aGL, NumberType_Int8);
    int bM60 = LoadFromAddress(aM60, NumberType_Int8);
    if (bGL != 0x15 || bM60 != 0x25)
    {
        LogError("[M60NoDrop] 弹药堆偏移字节不符（GL 0x%02X 预期 0x15 / M60 0x%02X 预期 0x25），补丁未应用（服务器版本可能已更新）",
            bGL, bM60);
        return;
    }

    g_addrAmmoUse = patch;
    g_iAmmoGLOffset = offGL;
    g_iAmmoGLOriginal = bGL;
    g_iAmmoM60Offset = offM60;
    g_iAmmoM60Original = bM60;

    StoreToAddress(aGL, 0xFF, NumberType_Int8);
    StoreToAddress(aM60, 0xFF, NumberType_Int8);

    PrintToServer("[M60NoDrop] CWeaponAmmoSpawn::Use 弹药堆补丁已应用 (GL 0x%02X->0xFF @%d, M60 0x%02X->0xFF @%d)",
        bGL, offGL, bM60, offM60);
}

public void OnConfigsExecuted()
{
    ApplyM60AmmoMax();
}

void OnM60AmmoMaxChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ApplyM60AmmoMax();
}

void ApplyM60AmmoMax()
{
    ConVar cvar = FindConVar("ammo_m60_max");
    if (cvar == null)
    {
        LogError("[M60NoDrop] 找不到引擎 cvar ammo_m60_max");
        return;
    }
    cvar.IntValue = g_cvM60AmmoMax.IntValue;
}

public void OnPluginEnd()
{
    if (g_addrM60Drop != Address_Null)
    {
        StoreToAddress(g_addrM60Drop, g_iM60DropOriginalByte, NumberType_Int8);
        PrintToServer("[M60NoDrop] CRifle_M60::PrimaryAttack 已还原 (0x%02X)", g_iM60DropOriginalByte);
        g_addrM60Drop = Address_Null;
    }

    if (g_addrAmmoUse != Address_Null)
    {
        StoreToAddress(g_addrAmmoUse + view_as<Address>(g_iAmmoGLOffset), g_iAmmoGLOriginal, NumberType_Int8);
        StoreToAddress(g_addrAmmoUse + view_as<Address>(g_iAmmoM60Offset), g_iAmmoM60Original, NumberType_Int8);
        PrintToServer("[M60NoDrop] CWeaponAmmoSpawn::Use 已还原 (GL 0x%02X / M60 0x%02X)",
            g_iAmmoGLOriginal, g_iAmmoM60Original);
        g_addrAmmoUse = Address_Null;
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
        ReplyToCommand(client, "[M60NoDrop] NoDrop 补丁未应用（gamedata 缺失/字节校验失败，见日志）");
    else
    {
        int b = LoadFromAddress(g_addrM60Drop, NumberType_Int8);
        ReplyToCommand(client, "[M60NoDrop] NoDrop：偏移 %d 字节 0x%02X（预期 0xEB 或 0x8D）", g_iM60DropOffset, b);
    }

    if (g_addrAmmoUse == Address_Null)
        ReplyToCommand(client, "[M60NoDrop] 弹药堆补丁未应用（gamedata 缺失/字节校验失败，见日志）");
    else
    {
        int bGL = LoadFromAddress(g_addrAmmoUse + view_as<Address>(g_iAmmoGLOffset), NumberType_Int8);
        int bM60 = LoadFromAddress(g_addrAmmoUse + view_as<Address>(g_iAmmoM60Offset), NumberType_Int8);
        ReplyToCommand(client, "[M60NoDrop] 弹药堆：GL 偏移 %d 字节 0x%02X / M60 偏移 %d 字节 0x%02X（预期 0xFF）",
            g_iAmmoGLOffset, bGL, g_iAmmoM60Offset, bM60);
    }

    ConVar cvar = FindConVar("ammo_m60_max");
    ReplyToCommand(client, "[M60NoDrop] ammo_m60_max = %d", cvar != null ? cvar.IntValue : -1);
    return Plugin_Handled;
}
