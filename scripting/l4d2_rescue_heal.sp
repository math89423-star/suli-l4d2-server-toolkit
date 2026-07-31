#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0"

ConVar g_hCvarEnable;
ConVar g_hCvarIncap;
ConVar g_hCvarLedge;
ConVar g_hCvarMedkit;
ConVar g_hCvarDefib;
ConVar g_hCvarPills;
ConVar g_hCvarMax;
ConVar g_hCvarAnnounce;

// 状态镜像（0.2s 轮询），用于区分 revive_success 三种来源：挂边拉起 / 电击复活 / 救助倒地
// L4D2 只有 revive_success 一个复活事件（无 defibrillated 事件），需靠事件前状态区分
bool g_bHanging[MAXPLAYERS+1];  // m_isHangingFromLedge — 挂边中
bool g_bDead[MAXPLAYERS+1];     // m_isDead — 已死亡（电击复活前必为 true）

public Plugin myinfo =
{
    name        = "[L4D2] Rescue Heal",
    author      = "claude",
    description = "Reward real HP for helping teammates: revive +20, medkit/defib +20, ledge rescue +10, give pills +3.",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_hCvarEnable   = CreateConVar("l4d2_rescue_heal_enable", "1",
        "0=OFF, 1=ON.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarIncap    = CreateConVar("l4d2_rescue_heal_incap", "20",
        "Real HP rewarded for reviving an incapped teammate (0=off).", FCVAR_NOTIFY, true, 0.0, true, 100.0);

    g_hCvarLedge    = CreateConVar("l4d2_rescue_heal_ledge", "10",
        "Real HP rewarded for pulling a teammate up from a ledge (0=off).", FCVAR_NOTIFY, true, 0.0, true, 100.0);

    g_hCvarMedkit   = CreateConVar("l4d2_rescue_heal_medkit", "20",
        "Real HP rewarded for healing a teammate with a medkit (0=off).", FCVAR_NOTIFY, true, 0.0, true, 100.0);

    g_hCvarDefib    = CreateConVar("l4d2_rescue_heal_defib", "20",
        "Real HP rewarded for defibrillating a teammate (0=off).", FCVAR_NOTIFY, true, 0.0, true, 100.0);

    g_hCvarPills    = CreateConVar("l4d2_rescue_heal_pills", "3",
        "Real HP rewarded for giving pills/adrenaline to a teammate (0=off).", FCVAR_NOTIFY, true, 0.0, true, 100.0);

    g_hCvarMax      = CreateConVar("l4d2_rescue_heal_max", "100",
        "Maximum real HP after reward (won't heal past this).", FCVAR_NOTIFY, true, 1.0, true, 9999.0);

    g_hCvarAnnounce = CreateConVar("l4d2_rescue_heal_announce", "1",
        "0=OFF, 1=ON. Announce reward in chat.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_rescue_heal");

    HookEvent("revive_success",  Event_ReviveSuccess);
    HookEvent("heal_success",    Event_HealSuccess);
    HookEvent("pills_used",      Event_PillsUsed);
    HookEvent("round_start",     Event_RoundStart);

    CreateTimer(0.2, Timer_StateCheck, _, TIMER_REPEAT);
}

public void OnClientDisconnect(int client)
{
    g_bHanging[client] = false;
    g_bDead[client] = false;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bHanging[i] = false;
        g_bDead[i] = false;
    }
}

// 轮询状态镜像：挂边中 m_isHangingFromLedge=1；已死亡 m_isDead=1（死亡躯体保留期间持续为 1）
public Action Timer_StateCheck(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2)
        {
            g_bHanging[i] = view_as<bool>(GetEntProp(i, Prop_Send, "m_isHangingFromLedge"));
            g_bDead[i]    = view_as<bool>(GetEntProp(i, Prop_Send, "m_isDead"));
        }
        else
        {
            g_bHanging[i] = false;
            g_bDead[i] = false;
        }
    }
    return Plugin_Continue;
}

// revive_success 是 L4D2 唯一的复活事件，覆盖三种来源，按事件前状态区分：
// 挂边中 → 挂边拉起；已死亡 → 电击复活；否则 → 救助倒地
void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (subject < 1 || subject > MaxClients)
        return;

    int rescuer = GetClientOfUserId(event.GetInt("rescuer"));
    if (subject == rescuer)  // 自己爬起来不算
        return;

    // 状态镜像 + 事件时刻实时 prop 双重判定（prop 时机在事件前后不确定）
    bool ledge = g_bHanging[subject] || view_as<bool>(GetEntProp(subject, Prop_Send, "m_isHangingFromLedge"));
    bool defib = g_bDead[subject]    || view_as<bool>(GetEntProp(subject, Prop_Send, "m_isDead"));
    g_bHanging[subject] = false;
    g_bDead[subject] = false;

    if (ledge)
        Reward(rescuer, g_hCvarLedge, "把挂边队友拉起来");
    else if (defib)
        Reward(rescuer, g_hCvarDefib, "电击复活队友");
    else
        Reward(rescuer, g_hCvarIncap, "救助倒地队友");
}

void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));
    int rescuer = GetClientOfUserId(event.GetInt("rescuer"));
    if (subject == rescuer) return;  // 自己打包不算

    Reward(rescuer, g_hCvarMedkit, "给队友打包");
}

void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));  // 吃药的人
    int user    = GetClientOfUserId(event.GetInt("user"));     // 递药的人
    if (subject == user) return;  // 自己吃药不算

    Reward(user, g_hCvarPills, "给队友递药");
}

void Reward(int client, ConVar cvar, const char[] what)
{
    if (!g_hCvarEnable.BoolValue) return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return;
    if (IsFakeClient(client)) return;
    if (GetClientTeam(client) != 2) return;
    if (!IsPlayerAlive(client)) return;

    int amount = cvar.IntValue;
    if (amount <= 0) return;

    int maxHP = g_hCvarMax.IntValue;
    int curHP = GetClientHealth(client);
    if (curHP >= maxHP) return;

    int newHP = curHP + amount;
    if (newHP > maxHP) newHP = maxHP;

    SetEntProp(client, Prop_Send, "m_iHealth", newHP);

    if (g_hCvarAnnounce.BoolValue)
        PrintToChat(client, "\x04[奖励]\x01 %s，恢复 \x05+%d\x01 实血！", what, newHP - curHP);
}
