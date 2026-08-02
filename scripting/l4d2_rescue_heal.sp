#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

// v1.3: 两处修复
//  1) 拉倒地/挂边拉起/电击复活 只奖励救人者（被救者不加血）
//  2) 打包者奖励失效修复：SDKHooks OnUse 对打包/递药从不触发（实测 2.2 万条 OnUse 无一条
//     first_aid_kit/pills，OnUse 只在持枪/近战按 E 时触发）→ 改用 left4dhooks 引擎级 detour
//     L4D2_OnStartUseAction（打包必然触发：action=Healing，client=打包者，target=被打包者）
// v1.4: 递药检测修复 —— 用户实测递药不回血；StartUseAction 枚举不覆盖递药（无"记录递药者"
//     日志实锤）→ 0.2s 轮询差分推导：递药瞬间给药者 health 槽 pills 实体消失，吃药者
//     pills_used 时查 5s 内"失去药"的最近玩家 = 递药者

#define PLUGIN_VERSION "1.4"

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

// 打包/递药执行者记录（L4D2_OnStartUseAction 记录，heal_success/pills_used 完成时查表）
// 本版本事件无执行者字段：heal_success 全字段为 0，pills_used 的 user 也为 0
int g_iMedkitHealer[MAXPLAYERS+1];  // [被打包者] = 打包者 client
int g_iMedkitHealerTime[MAXPLAYERS+1]; // 打包记录时间戳（15s 有效期，防 use 后未完成的残留）
int g_iPillGiver[MAXPLAYERS+1];     // [吃药者] = 递药者 client
int g_iPillGiverTime[MAXPLAYERS+1]; // 递药记录时间戳（5s 有效期，防 use 后没给药的残留）

// v1.4: 递药差分推导 —— StartUseAction 枚举不覆盖 pills（实测无"记录递药者"日志），
// 轮询跟踪 health 槽（slot 4）pills/adrenaline 实体；实体消失时刻 = 给出/吃掉，
// pills_used 时查 5s 内"失去药"的最近玩家 = 递药者（排除吃药者本人）
int g_iPillSlotEnt[MAXPLAYERS + 1];   // [玩家] = health 槽当前 pills/adrenaline 实体（0=无）
float g_fPillLostTime[MAXPLAYERS + 1]; // [玩家] = 上次实体消失时刻（0=未失去过）

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

            // v1.4: health 槽差分 —— 记录当前 pills/adrenaline 实体，实体消失记时刻（递药推导用）
            int ent = GetPlayerWeaponSlot(i, 4);
            if (ent > 0 && IsValidEntity(ent))
            {
                char cls[32];
                GetEdictClassname(ent, cls, sizeof(cls));
                if (!StrEqual(cls, "weapon_pain_pills", false) && !StrEqual(cls, "weapon_adrenaline", false))
                    ent = 0;  // medkit/其他不算药
            }
            if (g_iPillSlotEnt[i] != ent)
            {
                if (g_iPillSlotEnt[i] > 0)
                    g_fPillLostTime[i] = GetEngineTime();  // 药离开手（递出/吃掉）
                g_iPillSlotEnt[i] = ent;
            }
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
// v1.3: 只奖励救人者 —— 被救的人不加血（用户指定）
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
    // 救人（按 E 交互）完成时清掉打包/递药残留，防误配
    g_iMedkitHealer[subject] = 0;
    g_iPillGiver[subject] = 0;

    if (ledge)
    {
        Reward(rescuer, g_hCvarLedge, "把挂边队友拉起来");
    }
    else if (defib)
    {
        Reward(rescuer, g_hCvarDefib, "电击复活队友");
    }
    else
    {
        Reward(rescuer, g_hCvarIncap, "救助倒地队友");
    }
}

void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    // 本版本 heal_success 无打包者字段，打包者由 L4D2_OnStartUseAction 记录
    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (subject < 1 || subject > MaxClients) return;

    int healer = g_iMedkitHealer[subject];
    g_iMedkitHealer[subject] = 0;
    if (healer < 1 || healer > MaxClients) return;
    if (GetTime() - g_iMedkitHealerTime[subject] > 15) return;  // 记录过期（开始打包但没完成）
    if (healer == subject) return;  // 自己打包不算

    Reward(healer, g_hCvarMedkit, "给队友打包");
    Reward(subject, g_hCvarMedkit, "打包", true);  // v1.2: 被打包队友也加血（用户指定）
}

void Event_HealInterrupted(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (subject >= 1 && subject <= MaxClients)
        g_iMedkitHealer[subject] = 0;
}

void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
    // 本版本 pills_used 无递药者字段。递药者来源：优先 L4D2_OnStartUseAction 记录
    // （实测枚举不覆盖递药，几乎必走差分推导）；未记录/过期/自己吃药 → v1.4 差分推导
    int subject = GetClientOfUserId(event.GetInt("subject"));  // 吃药的人
    if (subject < 1 || subject > MaxClients) return;

    int giver = g_iPillGiver[subject];
    g_iPillGiver[subject] = 0;
    if (giver < 1 || giver > MaxClients || GetTime() - g_iPillGiverTime[subject] > 5 || giver == subject)
    {
        giver = InferPillGiver(subject);
        if (giver < 1 || giver > MaxClients) return;
    }

    Reward(giver, g_hCvarPills, "给队友递药");
    Reward(subject, g_hCvarPills, "递药", true);
}

// v1.4: 递药者差分推导 —— 递药瞬间给药者 health 槽实体消失（g_fPillLostTime 记录），
// 吃药者吃药时查 5s 内"失去药"的最近玩家（排除自己）即为递药者
int InferPillGiver(int subject)
{
    float now = GetEngineTime();
    int bestGiver = 0;
    float bestAge = 99999.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == subject) continue;
        if (g_fPillLostTime[i] <= 0.0) continue;
        float age = now - g_fPillLostTime[i];
        if (age < 0.0 || age > 5.0) continue;
        if (age < bestAge)
        {
            bestAge = age;
            bestGiver = i;
        }
    }
    if (bestGiver > 0)
        LogMessage("[RescueHeal] 轮询差分推导递药者 %d(%N) -> %d(%N) age=%.1f",
            bestGiver, bestGiver, subject, subject, bestAge);
    return bestGiver;
}

// v1.3 FIX: 打包/递药检测改用 left4dhooks 引擎级 detour L4D2_OnStartUseAction。
// 原因：SDKHooks OnUse 在打包/递药时从不触发 —— 实测 2.2 万条 OnUse 日志全部是
// 持枪/近战按 E（weapon_melee/weapon_rifle 等），0 条 weapon_first_aid_kit/pills。
// CTerrorPlayer::StartUseAction 是打包的必经路径：action=1(Healing)，client=打包者。
public void L4D2_OnStartUseAction_Post(any action, int client, int target)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    // action=1 L4D2UseAction_Healing：开始打包/自我包扎（含对队友使用医疗包）
    if (action == view_as<int>(L4D2UseAction_Healing))
    {
        int patient = target;
        // target 参数对打包应是患者；兜底用 L4D_FindUseEntity 再试一次
        if (patient < 1 || patient > MaxClients || !IsClientInGame(patient) || GetClientTeam(patient) != 2)
            patient = L4D_FindUseEntity(client);
        if (patient < 1 || patient > MaxClients || !IsClientInGame(patient) || GetClientTeam(patient) != 2)
            return;
        if (patient == client)
            return;  // 自己包扎不算

        g_iMedkitHealer[patient] = client;
        g_iMedkitHealerTime[patient] = GetTime();
        LogMessage("[RescueHeal] OnStartUseAction(Healing): 记录打包者 %d(%N) -> %d(%N)",
            client, client, patient, patient);
    }
    else
    {
        // 递药兜底：pills/adrenaline 若也走 StartUseAction（枚举未列全），按手持武器记录递药者
        char weapon[32];
        GetClientWeapon(client, weapon, sizeof(weapon));
        if (StrEqual(weapon, "weapon_pain_pills", false) || StrEqual(weapon, "weapon_adrenaline", false))
        {
            int patient = target;
            if (patient < 1 || patient > MaxClients || !IsClientInGame(patient) || GetClientTeam(patient) != 2)
                patient = L4D_FindUseEntity(client);
            if (patient < 1 || patient > MaxClients || !IsClientInGame(patient) || GetClientTeam(patient) != 2)
                return;
            if (patient == client)
                return;

            g_iPillGiver[patient] = client;
            g_iPillGiverTime[patient] = GetTime();
            LogMessage("[RescueHeal] OnStartUseAction: 记录递药者 %d(%N) -> %d(%N) action=%d",
                client, client, patient, patient, action);
        }
    }
}

// v1.2: toSubject=true 时给"被帮助的队友"加血（仅打包/递药保留；救人动作 v1.3 起不再给被救者加血）
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
