/**
 * L4D2 Can Explosion Full Damage (v1.0)
 * 引擎对"打爆罐子的归属者"有爆炸自伤豁免（旁路直接扣血，不调 OnTakeDamage hook，
 * 不打爆者本人：无伤害无震退——原版 wiki 贴脸打爆掉 5-30 血 + stagger 1.5s）。
 * 本插件：罐子被幸存者打爆/点燃的瞬间，对打爆者注入爆炸伤害 + 原版 stagger 硬直。
 * 注入 attacker=world(0)（非玩家）→ 不触发"attacker==victim"豁免；
 * 队友/特感伤害由引擎旁路正常处理（本插件不碰）。
 */
#include <sourcemod>
#include <sdkhooks>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.2.1"
#define MAX_CAN_MODELS 4
#define MAX_EDICTS 2048

static const char g_sCanModels[MAX_CAN_MODELS][] =
{
    "models/props_junk/propanecanister001a.mdl",
    "models/props_equipment/oxygentank01.mdl",
    "models/props_junk/gascan001a.mdl",
    "models/props_junk/explosive_box001.mdl"
};

ConVar g_cvDmgMax;
ConVar g_cvRadius;
ConVar g_cvStagger;

bool g_bCan[MAX_EDICTS];
bool g_bWasCan[MAX_EDICTS];      // 曾是罐子（weapon 形态互转后仍可被爆炸侧引用）
bool g_bInjected[MAX_EDICTS];    // 该罐子的打爆者已注入（防重复）
int g_iAttacker[MAX_EDICTS];
float g_fPos[MAX_EDICTS][3];

public Plugin myinfo =
{
    name = "L4D2 Can Explosion Full Damage",
    author = "claude",
    description = "打爆罐子的幸存者也受到爆炸伤害 + stagger（补引擎自伤豁免）",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvDmgMax = CreateConVar("sm_can_dmg_max", "30.0", "打爆罐子时打爆者贴脸受到的伤害（原版 easy 5-30，hard 更高）");
    g_cvRadius = CreateConVar("sm_can_radius", "350.0", "打爆者受伤判定半径（超出无伤害）");
    g_cvStagger = CreateConVar("sm_can_stagger", "1", "打爆者是否受到原版 stagger 硬直");
    AutoExecConfig(true, "l4d2_can_full_damage");

    // late load：地图已有罐子（reload 场景）
    CreateTimer(0.5, Timer_Sweep, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Sweep(Handle timer)
{
    SweepExisting();
    return Plugin_Continue;
}

public void OnMapStart()
{
    SweepExisting();
}

// 罐子可爆炸形态 classname：世界态 prop_physics（含 override/multiplayer 变体）/
// 地图静态 prop_dynamic（CAN-LIKE 诊断实测：地图罐子=prop_dynamic）/ 拾取丢弃态 weapon_*
bool IsCanClass(const char[] cls)
{
    return StrEqual(cls, "prop_physics") || StrEqual(cls, "prop_physics_multiplayer")
        || StrEqual(cls, "prop_physics_override") || StrEqual(cls, "prop_dynamic")
        || StrEqual(cls, "prop_dynamic_override")
        || StrEqual(cls, "weapon_propanetank") || StrEqual(cls, "weapon_gascan")
        || StrEqual(cls, "weapon_oxygentank") || StrEqual(cls, "weapon_fireworkcrate");
}

// late load / reload：地图已有实体不会重触发 OnEntityCreated → 主动补扫
void SweepExisting()
{
    int found = 0;
    for (int e = MaxClients + 1; e < GetMaxEntities(); e++)
    {
        if (!IsValidEntity(e))
            continue;
        char cls[32];
        GetEntityClassname(e, cls, sizeof(cls));
        if (IsCanClass(cls))
        {
            TryHookCan(e);
            found++;
        }
    }
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity > MaxClients && IsCanClass(classname))
    {
        // v1.1.2 诊断：所有候选类实体创建记录（找 281 类漏网罐子）
        SDKHook(entity, SDKHook_SpawnPost, OnCanSpawnPost);
    }
}

public void OnCanSpawnPost(int entity)
{
    TryHookCan(entity);
}

void TryHookCan(int entity)
{
    // v1.0.6: hook 挂到所有 prop_physics（模型匹配只决定是否注入）；记录返回值
    bool hooked = SDKHook(entity, SDKHook_OnTakeDamage, CanTakeDamage);
    char model[PLATFORM_MAX_PATH];
    if (!GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model)))
        strcopy(model, sizeof(model), "?");

    for (int i = 0; i < MAX_CAN_MODELS; i++)
    {
        if (StrEqual(model, g_sCanModels[i], false))
        {
            g_bCan[entity] = true;
            g_bWasCan[entity] = true;
            return;
        }
    }
}

public Action CanTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
    int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
    // v1.0.4 诊断：罐子收到的所有伤害
    // 只记录幸存者玩家的攻击（火/世界伤害不覆盖：火烧爆的罐子引擎归属=火，
    // 旁路不豁免任何人，无需注入）
    if (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker)
        && GetClientTeam(attacker) == 2)
    {
        g_iAttacker[victim] = attacker;
        GetEntPropVector(victim, Prop_Data, "m_vecAbsOrigin", g_fPos[victim]);
    }

    // v1.2.0：爆炸波及侧反推——weapon 形态罐子被打爆（引擎武器伤害路径不调
    // TakeDamage hook，拿不到打爆者），但其爆炸打其它罐子时这里能拿到
    // inflictor=爆炸源 + attacker=打爆者 → 延迟补注入（源已销毁时 OnEntityDestroyed
    // 的注入不会执行，由这里兜底）
    if ((damagetype & DMG_BLAST) && inflictor > MaxClients && inflictor < MAX_EDICTS
        && g_bWasCan[inflictor] && !g_bInjected[inflictor]
        && attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker)
        && GetClientTeam(attacker) == 2)
    {
        g_bInjected[inflictor] = true;
        DataPack dp2 = new DataPack();
        dp2.WriteCell(inflictor);
        dp2.WriteCell(attacker);
        dp2.WriteFloat(damagePosition[0]);
        dp2.WriteFloat(damagePosition[1]);
        dp2.WriteFloat(damagePosition[2]);
        CreateTimer(0.01, Timer_BoomInject, dp2, TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Continue;
}

// 爆炸侧补注入（延迟等爆炸传播完成）
public Action Timer_BoomInject(Handle timer, DataPack dp)
{
    dp.Reset();
    int src = dp.ReadCell();
    int attacker = dp.ReadCell();
    float pos[3];
    pos[0] = dp.ReadFloat();
    pos[1] = dp.ReadFloat();
    pos[2] = dp.ReadFloat();
    delete dp;
    g_bInjected[src] = false;

    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2 || !IsPlayerAlive(attacker))
        return Plugin_Continue;

    float ap[3];
    GetClientAbsOrigin(attacker, ap);
    float dist = GetVectorDistance(pos, ap);
    float radius = g_cvRadius.FloatValue;
    if (radius <= 0.0 || dist >= radius)
        return Plugin_Continue;

    float dmg = g_cvDmgMax.FloatValue * (1.0 - dist / radius);
    if (dmg <= 0.0)
        return Plugin_Continue;

    SDKHooks_TakeDamage(attacker, 0, 0, dmg, DMG_BLAST, -1, NULL_VECTOR, pos, false);

    if (g_cvStagger.BoolValue)
        L4D_StaggerPlayer(attacker, attacker, pos);   // v1.0.10: world 抛异常，传打爆者本人
    return Plugin_Continue;
}

public void OnEntityDestroyed(int entity)
{
    if (entity <= MaxClients || entity >= MAX_EDICTS)
        return;
    if (!g_bCan[entity])
        return;
    g_bCan[entity] = false;

    int attacker = g_iAttacker[entity];
    g_iAttacker[entity] = 0;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
    {
        return;
    }
    if (GetClientTeam(attacker) != 2 || !IsPlayerAlive(attacker))
    {
        return;
    }

    float pos[3];
    pos = g_fPos[entity];
    float ap[3];
    GetClientAbsOrigin(attacker, ap);
    float dist = GetVectorDistance(pos, ap);
    float radius = g_cvRadius.FloatValue;
    if (radius <= 0.0 || dist >= radius)
    {
        return;
    }

    float dmg = g_cvDmgMax.FloatValue * (1.0 - dist / radius);
    if (dmg <= 0.0)
        return;

    // v1.0.9: attacker=世界(0)——gl_splash_fix v2.1.4 实证套路（自伤注入用
    // attacker=世界绕过减伤判定）。武器实体当 attacker 会被引擎解析归属到
    // 武器主人（打爆者自己）→ 又触发自伤豁免（20:08:17 实测注入 20 不掉血）。
    // 世界归属无主 → 不触发任何豁免/FF 缩放。
    g_bInjected[entity] = true;      // 防爆炸侧补注入重复
    SDKHooks_TakeDamage(attacker, 0, 0, dmg, DMG_BLAST, -1, NULL_VECTOR, pos, false);

    if (g_cvStagger.BoolValue)
        L4D_StaggerPlayer(attacker, attacker, pos);   // v1.0.10: 同上，world 会抛异常
}
