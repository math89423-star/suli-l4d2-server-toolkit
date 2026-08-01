#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <sdkhooks>    // v1.1: 打包/递药检测改用 SDKHooks OnUse（player_use 事件在 L4D2 不触发）

#define PLUGIN_VERSION "1.2"

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
// 注意：m_isDead prop 在玩家实体上不存在（GetEntProp 会抛异常），死亡判定用 IsPlayerAlive()
bool g_bHanging[MAXPLAYERS+1];  // m_isHangingFromLedge — 挂边中
bool g_bDead[MAXPLAYERS+1];     // !IsPlayerAlive — 已死亡（电击复活前必为 true）

// 打包/递药执行者记录（player_use 事件记录，heal_success/pills_used 完成时查表）
// 本版本事件无执行者字段：heal_success 全字段为 0，pills_used 的 user 也为 0
int g_iMedkitHealer[MAXPLAYERS+1];  // [被打包者] = 打包者 client
int g_iPillGiver[MAXPLAYERS+1];     // [吃药者] = 递药者 client
int g_iPillGiverTime[MAXPLAYERS+1]; // 递药记录时间戳（5s 有效期，防 use 后没给药的残留）

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

    HookEvent("revive_success",   Event_ReviveSuccess);
    HookEvent("heal_success",     Event_HealSuccess);
    HookEvent("heal_interrupted", Event_HealInterrupted);
    HookEvent("pills_used",       Event_PillsUsed);
    HookEvent("round_start",      Event_RoundStart);

    CreateTimer(0.2, Timer_StateCheck, _, TIMER_REPEAT);

    // v1.1 FIX: L4D2 的 player_use 事件从不触发（打包/递药无 PlayerUse 日志，
    // 实测 0 条）→ 改用 SDKHooks OnUse（队友实体被 E 对准时引擎级回调）。
    // 补 hook 已在线的玩家（reload 不触发 OnClientPutInServer）。
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            SDKHook(i, SDKHook_Use, OnUseHook);
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_Use, OnUseHook);
}

public void OnClientDisconnect(int client)
{
    g_bHanging[client] = false;
    g_bDead[client] = false;
    g_iMedkitHealer[client] = 0;
    g_iPillGiver[client] = 0;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bHanging[i] = false;
        g_bDead[i] = false;
        g_iMedkitHealer[i] = 0;
        g_iPillGiver[i] = 0;
    }
}

// 轮询状态镜像：挂边中 m_isHangingFromLedge=1；死亡用 IsPlayerAlive（m_isDead prop 不存在）
public Action Timer_StateCheck(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2)
        {
            g_bHanging[i] = view_as<bool>(GetEntProp(i, Prop_Send, "m_isHangingFromLedge"));
            g_bDead[i] = !IsPlayerAlive(i);
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
    // 实测（2026-07-31）：本版本 revive_success 的救人者字段是 "userid"，"rescuer" 恒为 0
    int rawSubject = event.GetInt("subject");
    int rawRescuer = event.GetInt("userid");
    int subject = GetClientOfUserId(rawSubject);
    int rescuer = GetClientOfUserId(rawRescuer);

    LogMessage("[RescueHeal] ReviveSuccess RAW: subject=%d userid=%d | resolved=%d/%d hang=%d dead=%d",
        rawSubject, rawRescuer, subject, rescuer,
        g_bHanging[subject >= 1 && subject <= MaxClients ? subject : 0],
        g_bDead[subject >= 1 && subject <= MaxClients ? subject : 0]);

    if (subject < 1 || subject > MaxClients)
        return;

    if (subject == rescuer)  // 自己爬起来不算
        return;

    LogMessage("[RescueHeal] ReviveSuccess: subject=%d rescuer=%d hang=%d dead=%d",
        subject, rescuer,
        g_bHanging[subject], g_bDead[subject]);

    // 挂边镜像 + 事件时刻实时 prop 双重判定（prop 时机在事件前后不确定）；死亡只看镜像（无 prop 可读）
    bool ledge = g_bHanging[subject] || view_as<bool>(GetEntProp(subject, Prop_Send, "m_isHangingFromLedge"));
    bool defib = g_bDead[subject];
    g_bHanging[subject] = false;
    g_bDead[subject] = false;
    // v1.1: 救人（按 E 交互）也会触发 OnUse 但手里是空手/电击器不记录；
    // 保险起见救人完成时清掉打包/递药残留，防误配
    g_iMedkitHealer[subject] = 0;
    g_iPillGiver[subject] = 0;

    if (ledge)
    {
        Reward(rescuer, g_hCvarLedge, "把挂边队友拉起来");
        Reward(subject, g_hCvarLedge, "拉起来", true);
    }
    else if (defib)
    {
        Reward(rescuer, g_hCvarDefib, "电击复活队友");
        Reward(subject, g_hCvarDefib, "电击复活", true);
    }
    else
    {
        Reward(rescuer, g_hCvarIncap, "救助倒地队友");
        Reward(subject, g_hCvarIncap, "救助", true);
    }
}

void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    // 本版本 heal_success 无打包者字段，打包者由 player_use 记录
    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (subject < 1 || subject > MaxClients) return;

    int rescuer = g_iMedkitHealer[subject];
    g_iMedkitHealer[subject] = 0;
    if (rescuer < 1 || rescuer > MaxClients) return;
    if (rescuer == subject) return;  // 自己打包不算

    Reward(rescuer, g_hCvarMedkit, "给队友打包");
    Reward(subject, g_hCvarMedkit, "打包", true);
}

void Event_HealInterrupted(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (subject >= 1 && subject <= MaxClients)
        g_iMedkitHealer[subject] = 0;
}

void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
    // 本版本 pills_used 无递药者字段，递药者由 player_use 记录（5s 内有效）
    int subject = GetClientOfUserId(event.GetInt("subject"));  // 吃药的人
    if (subject < 1 || subject > MaxClients) return;

    int giver = g_iPillGiver[subject];
    g_iPillGiver[subject] = 0;
    if (giver < 1 || giver > MaxClients) return;
    if (GetTime() - g_iPillGiverTime[subject] > 5) return;  // 记录过期（use 了但没给药）
    if (giver == subject) return;  // 自己吃药不算

    Reward(giver, g_hCvarPills, "给队友递药");
    Reward(subject, g_hCvarPills, "递药", true);
}

// v1.1 FIX: SDKHooks OnUse —— 队友实体被 E 对准（打包/递药）时引擎回调，
// 按 activator（使用方）手里武器记录执行者。player_use 事件在 L4D2 从不触发。
public Action OnUseHook(int entity, int activator, int caller, UseType type, float value)
{
    if (entity < 1 || entity > MaxClients || !IsClientInGame(entity) || GetClientTeam(entity) != 2)
        return Plugin_Continue;
    if (activator < 1 || activator > MaxClients || !IsClientInGame(activator) || IsFakeClient(activator))
        return Plugin_Continue;
    if (activator == entity || GetClientTeam(activator) != 2)
        return Plugin_Continue;

    char weapon[32];
    GetClientWeapon(activator, weapon, sizeof(weapon));
    LogMessage("[RescueHeal] OnUse: %d(%N) use %d(%N) weapon %s type %d", activator, activator, entity, entity, weapon, type);

    if (StrEqual(weapon, "weapon_first_aid_kit", false))
    {
        g_iMedkitHealer[entity] = activator;
        LogMessage("[RescueHeal] OnUse: 记录打包者 %d -> %d", activator, entity);
    }
    else if (StrEqual(weapon, "weapon_pain_pills", false) || StrEqual(weapon, "weapon_adrenaline", false))
    {
        g_iPillGiver[entity] = activator;
        g_iPillGiverTime[entity] = GetTime();
        LogMessage("[RescueHeal] OnUse: 记录递药者 %d -> %d", activator, entity);
    }
    return Plugin_Continue;
}

// v1.2: toSubject=true 时给"被帮助的队友"加血（用户："给队友打包点击队友也要加血"）
void Reward(int client, ConVar cvar, const char[] what, bool toSubject = false)
{
    char cvarName[64];
    cvar.GetName(cvarName, sizeof(cvarName));

    if (!g_hCvarEnable.BoolValue) { LogMessage("[RescueHeal] Reward(%N) skip: disabled", client); return; }
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) { LogMessage("[RescueHeal] Reward skip: invalid client %d", client); return; }
    if (IsFakeClient(client)) { LogMessage("[RescueHeal] Reward(%N) skip: bot", client); return; }
    if (GetClientTeam(client) != 2) { LogMessage("[RescueHeal] Reward(%N) skip: team %d", client, GetClientTeam(client)); return; }
    if (!IsPlayerAlive(client)) { LogMessage("[RescueHeal] Reward(%N) skip: dead", client); return; }

    int amount = cvar.IntValue;
    if (amount <= 0) { LogMessage("[RescueHeal] Reward(%N) skip: %s amount=0", client, cvarName); return; }

    int maxHP = g_hCvarMax.IntValue;
    int curHP = GetClientHealth(client);
    if (curHP >= maxHP)
    {
        LogMessage("[RescueHeal] Reward(%N) skip: at max HP (%d/%d) %s", client, curHP, maxHP, cvarName);
        if (g_hCvarAnnounce.BoolValue)
        {
            if (toSubject)
                PrintToChat(client, "\x04[奖励]\x01 你被队友%s，但你已满血！", what);
            else
                PrintToChat(client, "\x04[奖励]\x01 %s，但你已满血，奖励无法生效！", what);
        }
        return;
    }

    int newHP = curHP + amount;
    if (newHP > maxHP) newHP = maxHP;

    SetEntProp(client, Prop_Send, "m_iHealth", newHP);
    LogMessage("[RescueHeal] Reward(%N): %s +%d (curHP %d -> %d)", client, cvarName, newHP - curHP, curHP, newHP);

    if (g_hCvarAnnounce.BoolValue)
    {
        if (toSubject)
            PrintToChat(client, "\x04[奖励]\x01 你被队友%s，恢复 \x05+%d\x01 实血！", what, newHP - curHP);
        else
            PrintToChat(client, "\x04[奖励]\x01 %s，恢复 \x05+%d\x01 实血！", what, newHP - curHP);
    }
}
