#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// ============================================================================
// jtest_bots.sp — 空服 SI 行为实测工具（骑跃射程等），常驻仓库、按需临时部署
//
// 部署:  spcomp64 jtest_bots.sp -iinclude -o <plugins>/jtest_bots.smx && rcon "sm plugins load jtest_bots"
// 卸载:  rcon "sm plugins unload jtest_bots" 后删除 smx（非常驻插件！）
//
// 前置条件（详见 AGENTS.md「空服 AI 实测方法论」）:
//   1. sv_cheats 1 + sb_stop 1 + nb_stop 1（冻结大脑隔离纯按键路径）
//   2. 至少 1 个幸存者 bot: sm_jt_mkbot（CreateFakeClient+ChangeClientTeam）
//   3. si_composition_manager 必须卸载 —— 它 hook L4D_OnSpawnSpecial 强改类别，
//      jockey 被其编制政策排除，不卸载则永远生成不出 jockey！
//
// 实测循环（每轮原子化，防大脑竞态/骑乘粘滞污染）:
//   sm_jt_run <D>    杀旧jockey→无敌化幸存者→安全点生成新jockey→摆位到 D u
//   sm_jt_press [pitch]   原子重摆+强制 IN_ATTACK（pitch 负值=上仰）
//   sm_jt_sample          采样瞬时速度
//   sm_jt_eval <D>        输出 JTEST_RESULT D= moved= spd= attached=
// 判读: attached>0=骑上(命中); moved≈飞行弧长; spd≈起跳初速(~405)
// ============================================================================

int   g_iJockey = -1;
int   g_iSurv = -1;
float g_fStartPos[3];
float g_fStartAng[3];
float g_fSpeedSample = 0.0;

public void OnPluginStart() {
    RegAdminCmd("sm_jt_mkbot", Cmd_MakeBot, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_kickbots", Cmd_KickBots, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_mksi", Cmd_MkSI, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_setup", Cmd_Setup, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_press", Cmd_Press, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_sample", Cmd_Sample, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_eval", Cmd_Eval, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_reset", Cmd_Reset, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_run", Cmd_Run, ADMFLAG_ROOT);
    RegAdminCmd("sm_jt_tp", Cmd_TpSurv, ADMFLAG_ROOT);
}

// ---------- 环境准备 ----------

Action Cmd_MakeBot(int client, int args) {
    int bot = CreateFakeClient("JTestBot");
    if (!bot) {
        PrintToServer("[jtest] CreateFakeClient FAIL");
        return Plugin_Handled;
    }
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(bot));
    RequestFrame(Frame_JoinTeam, dp);
    return Plugin_Handled;
}

void Frame_JoinTeam(any data) {
    DataPack dp = view_as<DataPack>(data);
    dp.Reset();
    int client = GetClientOfUserId(dp.ReadCell());
    delete dp;
    if (client <= 0 || !IsClientInGame(client)) return;
    ChangeClientTeam(client, 2);   // 注意: FakeClientCommand "jointeam 2" 在空服无效!
}

Action Cmd_KickBots(int client, int args) {
    char name[32];
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsFakeClient(i)) {
            GetClientName(i, name, sizeof(name));
            if (StrEqual(name, "JTestBot")) {
                KickClient(i, "jtest cleanup");
            }
        }
    }
    return Plugin_Handled;
}

Action Cmd_MkSI(int client, int args) {
    if (args < 3) {
        PrintToServer("[jtest] usage: sm_jt_mksi <x> <y> <z>");
        return Plugin_Handled;
    }
    char buf[4][32];
    float pos[3];
    for (int i = 0; i < 3; i++) {
        GetCmdArg(i + 1, buf[i], sizeof(buf[]));
        pos[i] = StringToFloat(buf[i]);
    }
    // zombieClass 参数用 m_zombieClass 值域: 1 smoker 2 boomer 3 hunter
    // 4 spitter 5 jockey 6 charger（si_composition_manager 未卸载时会被改写!）
    int zombie = L4D2_SpawnSpecial(5, pos, NULL_VECTOR);
    PrintToServer("[jtest] L4D2_SpawnSpecial jockey -> %d", zombie);
    return Plugin_Handled;
}

// ---------- 实测主流程 ----------

bool Filter_WorldOnly(int entity, int mask) {
    return entity == 0 || entity > MaxClients;
}

void FindPair() {
    g_iJockey = -1;
    g_iSurv = -1;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        int team = GetClientTeam(i);
        if (team == 3 && GetEntProp(i, Prop_Send, "m_zombieClass") == 5) {
            g_iJockey = i;
        } else if (team == 2) {
            g_iSurv = i;
        }
    }
}

float GroundZ(const float v[3]) {
    float up[3], down[3];
    up = v; up[2] += 512.0;
    down = v; down[2] -= 256.0;
    TR_TraceRayFilter(up, down, MASK_PLAYERSOLID, RayType_EndPoint, Filter_WorldOnly);
    if (!TR_DidHit()) return view_as<float>(-99999.0);
    float end[3];
    TR_GetEndPosition(end);
    return end[2];
}

bool ClearLine(const float a[3], const float b[3]) {
    float aa[3], bb[3];
    aa = a; aa[2] += 56.0;
    bb = b; bb[2] += 56.0;
    TR_TraceRayFilter(aa, bb, MASK_SOLID, RayType_EndPoint, Filter_WorldOnly);
    return !TR_DidHit();
}

Action Cmd_Setup(int client, int args) {
    if (args < 1) { PrintToServer("[jtest] usage: sm_jt_setup <D>"); return Plugin_Handled; }
    char buf[16];
    GetCmdArg(1, buf, sizeof(buf));
    float D = StringToFloat(buf);

    FindPair();
    if (g_iJockey <= 0 || g_iSurv <= 0) {
        PrintToServer("JTEST_ERR entities");
        return Plugin_Handled;
    }
    return DoSetup(D);
}

// 在幸存者周围环形找"平地(±20u)+视线通畅"的点位并精确摆位
Action DoSetup(float D) {
    float so[3];
    GetClientAbsOrigin(g_iSurv, so);

    float found[3];
    bool ok = false;
    int shift = GetRandomInt(0, 23);   // 随机方向起点: 避免重试总撞同一坏点位
    for (int k = 0; k < 24 && !ok; k++) {
        int i = (k + shift) % 24;
        float rad = (i * 15.0) * FLOAT_PI / 180.0;
        float cand[3];
        cand[0] = so[0] + Cosine(rad) * D;
        cand[1] = so[1] + Sine(rad) * D;
        cand[2] = so[2];
        float gz = GroundZ(cand);
        if (gz < -90000.0) continue;
        if (FloatAbs(gz - so[2]) > 20.0) continue;
        cand[2] = gz;
        if (!ClearLine(cand, so)) continue;
        found = cand;
        ok = true;
    }
    if (!ok) {
        PrintToServer("JTEST_ERR nospot D=%.0f", D);
        return Plugin_Handled;
    }

    float dy = so[1] - found[1];
    float dx = so[0] - found[0];
    g_fStartAng[0] = 0.0;
    g_fStartAng[1] = ArcTangent2(dy, dx) * 180.0 / FLOAT_PI;
    g_fStartAng[2] = 0.0;
    g_fStartPos = found;

    float vel[3];
    TeleportEntity(g_iJockey, found, g_fStartAng, vel);
    g_fSpeedSample = 0.0;
    PrintToServer("JTEST_SETUP D=%.0f ok", D);
    return Plugin_Handled;
}

Action Cmd_Press(int client, int args) {
    if (g_iJockey <= 0 || !IsClientInGame(g_iJockey)) {
        PrintToServer("JTEST_ERR press");
        return Plugin_Handled;
    }
    float ang[3];
    ang = g_fStartAng;
    if (args >= 1) {
        char buf[16];
        GetCmdArg(1, buf, sizeof(buf));
        ang[0] = StringToFloat(buf);   // 负值 = 上仰
    }
    float vel[3];
    TeleportEntity(g_iJockey, g_fStartPos, ang, vel);   // 原子重摆消除视角漂移
    SetEntProp(g_iJockey, Prop_Data, "m_afButtonForced", IN_ATTACK);
    return Plugin_Handled;
}

Action Cmd_Sample(int client, int args) {
    if (g_iJockey <= 0 || !IsClientInGame(g_iJockey)) return Plugin_Handled;
    float v[3];
    GetEntPropVector(g_iJockey, Prop_Data, "m_vecVelocity", v);
    g_fSpeedSample = GetVectorLength(v);
    return Plugin_Handled;
}

Action Cmd_Eval(int client, int args) {
    if (args < 1) return Plugin_Handled;
    char buf[16];
    GetCmdArg(1, buf, sizeof(buf));
    float D = StringToFloat(buf);
    if (g_iJockey <= 0 || !IsClientInGame(g_iJockey)) {
        PrintToServer("JTEST_ERR eval");
        return Plugin_Handled;
    }
    SetEntProp(g_iJockey, Prop_Data, "m_afButtonForced", 0);
    float now[3];
    GetClientAbsOrigin(g_iJockey, now);
    float moved = GetVectorDistance(now, g_fStartPos);
    int victim = GetEntPropEnt(g_iJockey, Prop_Send, "m_jockeyVictim");
    PrintToServer("JTEST_RESULT D=%.0f moved=%.0f spd=%.0f attached=%d", D, moved, g_fSpeedSample, victim);
    return Plugin_Handled;
}

// 杀旧 jockey（解除骑乘粘滞）、满血+无敌化幸存者
// 波次观测辅助: 把第一个幸存者 bot 传到环形搜索到的安全平地点（脱离安全屋,
// 建立导航流让 specialspawner 能真实刷怪）。用法: sm_jt_tp [半径=800]
Action Cmd_TpSurv(int client, int args) {
    float radius = 800.0;
    if (args >= 1) {
        char buf[16];
        GetCmdArg(1, buf, sizeof(buf));
        radius = StringToFloat(buf);
        if (radius < 200.0) radius = 200.0;
    }
    int surv = -1;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
            surv = i;
            break;
        }
    }
    if (surv <= 0) {
        PrintToServer("JTEST_ERR nosurv");
        return Plugin_Handled;
    }
    float pos[3], base[3], g;
    GetEntPropVector(surv, Prop_Data, "m_vecOrigin", base);
    float ang[3] = {0.0, 0.0, 0.0};
    float step = 15.0 * FLOAT_PI / 180.0;
    for (int k = 0; k < 24; k++) {
        pos[0] = base[0] + radius * Cosine(k * step);
        pos[1] = base[1] + radius * Sine(k * step);
        pos[2] = base[2] + 64.0;
        g = GroundZ(pos);
        if (g < -90000.0) continue;
        if (FloatAbs(g - base[2]) > 120.0) continue;   // 只落与当前高度接近的平面
        pos[2] = g + 4.0;
        TeleportEntity(surv, pos, ang, NULL_VECTOR);
        PrintToServer("JTEST_TP ok %.1f %.1f %.1f (deg %.0f)", pos[0], pos[1], pos[2], k * 15.0);
        return Plugin_Handled;
    }
    PrintToServer("JTEST_ERR noground");
    return Plugin_Handled;
}

Action Cmd_Reset(int client, int args) {
    FindPair();
    if (g_iJockey > 0 && IsClientInGame(g_iJockey)) {
        ForcePlayerSuicide(g_iJockey);
    }
    if (g_iSurv > 0 && IsClientInGame(g_iSurv)) {
        SetEntProp(g_iSurv, Prop_Data, "m_takedamage", 0);
        SetEntProp(g_iSurv, Prop_Data, "m_iHealth", 100);
    }
    return Plugin_Handled;
}

// 原子化单轮: 杀旧 → 幸存者无敌满血 → 测试圈外沿安全点生成新 jockey → 摆位。
// 一个命令完成（同帧），不给引擎大脑任何自行起跳/移动的窗口。
Action Cmd_Run(int client, int args) {
    if (args < 1) { PrintToServer("[jtest] usage: sm_jt_run <D>"); return Plugin_Handled; }
    char buf[16];
    GetCmdArg(1, buf, sizeof(buf));
    float D = StringToFloat(buf);

    FindPair();
    if (g_iJockey > 0 && IsClientInGame(g_iJockey)) {
        ForcePlayerSuicide(g_iJockey);
    }
    if (g_iSurv <= 0 || !IsClientInGame(g_iSurv)) {
        PrintToServer("JTEST_ERR nosurv");
        return Plugin_Handled;
    }
    SetEntProp(g_iSurv, Prop_Data, "m_takedamage", 0);
    SetEntProp(g_iSurv, Prop_Data, "m_iHealth", 100);

    // 出生点在测试圈外沿随机方向找平地（固定偏移会掉出地图秒死）
    float sp[3];
    GetClientAbsOrigin(g_iSurv, sp);
    float spawn[3];
    bool gotSpawn = false;
    int shift2 = GetRandomInt(0, 23);
    for (int k2 = 0; k2 < 24 && !gotSpawn; k2++) {
        int i = (k2 + shift2) % 24;
        float rad = (i * 15.0) * FLOAT_PI / 180.0;
        float cand[3];
        cand[0] = sp[0] + Cosine(rad) * (D + 200.0);
        cand[1] = sp[1] + Sine(rad) * (D + 200.0);
        cand[2] = sp[2];
        float gz = GroundZ(cand);
        if (gz < -90000.0) continue;
        if (FloatAbs(gz - sp[2]) > 20.0) continue;
        cand[2] = gz;
        spawn = cand;
        gotSpawn = true;
    }
    if (!gotSpawn) {
        PrintToServer("JTEST_ERR nospawnspot");
        return Plugin_Handled;
    }
    int bot = L4D2_SpawnSpecial(5, spawn, NULL_VECTOR);
    if (bot <= 0) {
        PrintToServer("JTEST_ERR spawnfail");
        return Plugin_Handled;
    }
    g_iJockey = bot;

    return DoSetup(D);
}
