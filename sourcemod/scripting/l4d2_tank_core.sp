#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define TANK_CLASS  8
#define WITCH_CLASS 7

#define ANNOUNCE_CHAT   1
#define ANNOUNCE_CENTER 2

// ============================================================================
// 统一 Tank/Witch HP 管理 + 播报插件
// 替代 l4d2_tank_announce.smx (黑盒) + l4d2_tank_hp_scaler.smx (补丁)
//
// 单一权威数据源: hp = alive_survivors × per_survivor_cvar
//   → 设置实体 HP (m_iMaxHealth + m_iHealth)
//   → 播报 (聊天 + 屏幕中央)
//   → 写入共享 convar 供外部读取
// ============================================================================

public Plugin myinfo = {
    name        = "L4D2 Tank & Witch Core",
    author      = "claude",
    description = "Unified HP scaling + announce — single authoritative source for Tank/Witch health",
    version     = "1.0",
    url         = ""
};

// --- Tank cvars ---
ConVar g_cvTankHPPerSurvivor;    // Tank 每人生还者血量
ConVar g_cvTankAnnounce;         // 播报方式: 0=禁用 1=聊天 2=屏幕中央 3=两者

// --- Witch cvars ---
ConVar g_cvWitchSwitch;          // Witch HP 缩放开关
ConVar g_cvWitchHPPerSurvivor;   // Witch 每人生还者血量 (0=禁用)

// ============================================================================
public void OnPluginStart()
{
    // Tank
    g_cvTankHPPerSurvivor = CreateConVar(
        "sm_tank_hp_per_survivor", "3000",
        "Tank HP per alive survivor. Total = survivors x this value. Keep in sync with ads / motd / HUD.");

    g_cvTankAnnounce = CreateConVar(
        "sm_tank_announce_type", "3",
        "Tank spawn announcement: 0=off, 1=chat, 2=center text, 3=both",
        _, true, 0.0, true, 3.0);

    // Witch
    g_cvWitchSwitch = CreateConVar(
        "sm_witch_hp_switch", "0",
        "Enable Witch HP scaling? 0=off (game default), 1=on (survivors × per-survivor)");

    g_cvWitchHPPerSurvivor = CreateConVar(
        "sm_witch_hp_per_survivor", "200",
        "Witch HP per alive survivor (only active when switch=1)");

    // Tank spawn — Pre-hook ensures our HP value is available before any other plugin reads it
    // (backward-compat: third-party plugins reading l4d2_tank_minimum will see the right value)
    HookEvent("tank_spawn",   Event_TankSpawn,   EventHookMode_Pre);
    HookEvent("player_spawn", Event_PlayerSpawn);

    // Witch
    HookEvent("witch_spawn",  Event_WitchSpawn);

    AutoExecConfig(true, "l4d2_tank_core");
}

// ============================================================================
// Tank
// ============================================================================

void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    // Calculate HP — this is the SINGLE AUTHORITATIVE VALUE
    int survivors = AliveSurvivorCount();
    int hp        = survivors * g_cvTankHPPerSurvivor.IntValue;

    // 1) 写入共享 convar (向后兼容：外部插件若读 l4d2_tank_minimum 会看到正确值)
    ConVar hCompat = FindConVar("l4d2_tank_minimum");
    if (hCompat != null)
        hCompat.IntValue = hp;

    // 2) 播报
    AnnounceTank(hp, survivors);
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;
    if (GetClientTeam(client) != 3)
        return;

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");

    if (zombieClass == TANK_CLASS)
    {
        int survivors = AliveSurvivorCount();
        int hp        = survivors * g_cvTankHPPerSurvivor.IntValue;

        // 3) 立即设置实体 HP (不再与黑盒插件竞争 — 已经没有 tank_announce.smx 了)
        //    但最小延迟 0.1s 让引擎完全初始化 Tank entity
        DataPack pack = new DataPack();
        pack.WriteCell(GetClientUserId(client));
        pack.WriteCell(hp);
        CreateTimer(0.1, Timer_SetTankHP, pack, TIMER_FLAG_NO_MAPCHANGE);
    }
}

Action Timer_SetTankHP(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int hp     = pack.ReadCell();
    delete pack;

    int tank = GetClientOfUserId(userid);
    if (tank <= 0 || tank > MaxClients || !IsClientInGame(tank) || !IsPlayerAlive(tank))
        return Plugin_Stop;

    SetEntProp(tank, Prop_Send, "m_iMaxHealth", hp);
    SetEntProp(tank, Prop_Send, "m_iHealth",    hp);

    return Plugin_Stop;
}

// ============================================================================
// Witch
// ============================================================================

void Event_WitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvWitchSwitch.BoolValue)
        return;

    int witch = event.GetInt("witchid");
    if (witch <= 0 || !IsValidEntity(witch))
        return;

    int survivors = AliveSurvivorCount();
    int hp        = survivors * g_cvWitchHPPerSurvivor.IntValue;
    if (hp <= 0)
        return;

    // Witch is a non-player entity — set via m_iHealth / m_iMaxHealth
    SetEntProp(witch, Prop_Data, "m_iHealth",    hp);
    SetEntProp(witch, Prop_Data, "m_iMaxHealth", hp);
}

// ============================================================================
// Announce
// ============================================================================

void AnnounceTank(int hp, int survivors)
{
    int mode = g_cvTankAnnounce.IntValue;
    if (mode == 0)
        return;

    char msg_chat[128];
    Format(msg_chat, sizeof(msg_chat),
        "\x04[Tank]\x01 HP: \x05%d\x01 (\x03%d\x01 人存活)",
        hp, survivors);

    if (mode & ANNOUNCE_CHAT)
        PrintToChatAll(msg_chat);

    if (mode & ANNOUNCE_CENTER)
    {
        char msg_center[64];
        Format(msg_center, sizeof(msg_center), "Tank\nHP: %d", hp);
        PrintCenterTextAll(msg_center);
    }
}

// ============================================================================
// Utility
// ============================================================================

int AliveSurvivorCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
            count++;
    }
    return count;
}
