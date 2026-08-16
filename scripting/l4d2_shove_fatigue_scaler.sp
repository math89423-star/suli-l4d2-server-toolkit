#include <sourcemod>
#include <left4dhooks>

public Plugin myinfo = {
    name = "Shove Fatigue Scaler",
    author = "claude",
    description = "Catch all shoves (air+hit) and set penalty to target (faster shove)",
    version = "3.0",
    url = ""
};

int g_iPrevButtons[MAXPLAYERS+1];
ConVar g_cvPenaltyTarget;

public void OnPluginStart()
{
    // v3.0 (2026-08-17, 用户): 推搡速度 +30% 目标 —— 推搡后把 m_iShovePenalty 设为
    // 目标值（替代 v2.0 的"减半"）。引擎推搡冷却 = z_gun_swing_interval(0.7)
    // × f(penalty)，penalty 越小推得越快：
    //   target=1 → 预期 ~13 次/10s（+30%，10s 10 次 → 13 次）
    //   target=0 → 最快（~14 次/10s，无疲劳）
    //   target 越大 → 越慢。实测偏快/偏慢调这里即可。
    g_cvPenaltyTarget = CreateConVar("sm_shove_penalty_target", "1",
        "推搡后 m_iShovePenalty 目标值: 0=最快(无疲劳) | 1≈13次/10s(+30%) | 越大越慢",
        FCVAR_NONE, true, 0.0, true, 10.0);
    AutoExecConfig(true, "l4d2_shove_fatigue_scaler");
}

public void OnClientPutInServer(int client)
{
    g_iPrevButtons[client] = 0;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;

    int prev = g_iPrevButtons[client];
    g_iPrevButtons[client] = buttons;

    // Shove button (IN_ATTACK2) newly pressed
    if ((buttons & IN_ATTACK2) && !(prev & IN_ATTACK2))
    {
        CreateTimer(0.1, Timer_SetShovePenalty, GetClientUserId(client));
    }

    return Plugin_Continue;
}

// Also catch shoves that hit infected (left4dhooks reliable forward)
public void L4D_OnShovedBySurvivor_Post(int client, int victim, const float vecDir[3])
{
    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
    {
        CreateTimer(0.1, Timer_SetShovePenalty, GetClientUserId(client));
    }
}

public Action Timer_SetShovePenalty(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
    {
        // v3.0: 直接设为目标值（替换 v2.0 的 penalty/2；penalty==1 时旧逻辑也是清 0）
        SetEntProp(client, Prop_Send, "m_iShovePenalty", g_cvPenaltyTarget.IntValue);
    }
    return Plugin_Stop;
}
