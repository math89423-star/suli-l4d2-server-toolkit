/**
 * [L4D2] V1 导弹素材验证插件 v1.0.0
 *
 * 目的：验证 c1m2/c5m2 原版导弹素材能否被提取并在服务器上使用。
 * 验证项：
 *   1. PrecacheModel("models/missiles/f18_agm65maverick.mdl") 是否成功（返回 >0）
 *   2. prop_dynamic 生成该模型是否成功（实体有效 + 客户端可见）
 *   3. 粒子系统 missile_hit1 / tanker_fireball_parent / gen_dest_fireball
 *      能否 precache 并播放
 *   4. 原版音效 animation/overpass_jets.wav（c5m2.missile_explosion）
 *      + animation/Tanker_Explosion.wav（c1m2.TankerExplosion）能否 precache
 *
 * 命令（admin）：
 *   sm_v1check      — 打印所有 precache 结果
 *   sm_v1model      — 准星处生成导弹模型（静止，看模型是否可见）
 *   sm_v1fly        — 准星处上方 2000u 生成导弹俯冲落地（完整飞行验证）
 *   sm_v1boom       — 准星处播放全部爆炸粒子 + 音效
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define MISSILE_MDL   "models/missiles/f18_agm65maverick.mdl"
#define SND_MISSILE   "animation/overpass_jets.wav"
#define SND_TANKER    "animation/Tanker_Explosion.wav"

// 全部粒子系统（需注册进 ParticleEffectNames 才能生成）
// 说明：带 _f / fireball 的是火球系（会留火焰残留），V1 不用
char g_sParticles[][] = {
    // 军用炮击弹着（无火）—— V1 主力
    "missile_hit1_rockblast",
    "missile_hit_explosionshockwave",
    "rockblast_posZ",
    "rockblast_negZ",
    "bridge_smokepuff",
    // 通用破坏（无火）
    "gen_hit1_rockblast",
    "gen_hit_explosionshockwave",
    "gen_rockblast_posZ",
    "gen_dest_risingsmoke",
    "plaster_dust_from_model",
    // 土石尘爆
    "weapon_pipebomb_dirt",
    "weapon_grenadelauncher_dirt",
    "weapon_grenade_debris",
    // 混凝土/建筑崩塌尘云
    "concrete_debris",
    "concrete_smoke",
    "tankwall_concrete",
    "tankwall_concrete_debris",
    "bridge_collapse",
    "bridge_collapse_b",
    "greenhouse_dust",
    "greenhouse_dust_bits",
    "stache_break_dust",
    "sheetrock_debris",
    "debris_generic_random",
    "Dust_Ceiling_Rumble_512Square",
    // 大烟柱
    "smoke_large_01",
    "smoke_large_02",
    "burning_city_effect_plume",
    // 冲击波
    "tanker_explosion_shockwave",
    // 天生大尺度（加油站/筒仓/建筑倒塌/天空盒级）
    "gas_explosion_shockwave",
    "gas_explosion_shockwave2",
    "gas_explosion_ground_wave",
    "gas_explosion_ground_wave2",
    "gas_explosion_initialburst_blast",
    "gas_explosion_initialburst_smoke",
    "gas_explosion_smoke",
    "explosion_silo",
    "building_destroyed_01",
    "skybox_smoke_01",
    "Dust_Ceiling_Rumble_256Line",
    "awning_collapse_dust",
    "awning_collapse_grit",
    "impact_physics_dust",
    "smoke_cloud_point",
    // 火球系（仅供对比，V1 不用）
    "missile_hit1_f",
    "tanker_fireball_parent",
    "gen_dest_fireball"
};

// ===== 无火爆炸预设：逐套对比找最像 BF5 V1 的 =====
// 每套 = 冲击波 + 尘爆 + 向上尘柱 + 烟云
char g_sPreset1[][] = { "missile_hit_explosionshockwave", "missile_hit1_rockblast", "rockblast_posZ" };
char g_sPreset2[][] = { "gen_hit_explosionshockwave", "gen_hit1_rockblast", "gen_rockblast_posZ", "gen_dest_risingsmoke" };
char g_sPreset3[][] = { "missile_hit_explosionshockwave", "weapon_pipebomb_dirt", "rockblast_posZ", "smoke_large_01" };
char g_sPreset4[][] = { "tanker_explosion_shockwave", "concrete_debris", "concrete_smoke", "gen_dest_risingsmoke" };
char g_sPreset5[][] = { "missile_hit_explosionshockwave", "bridge_collapse", "bridge_collapse_b", "bridge_smokepuff" };
char g_sPreset6[][] = { "missile_hit1_rockblast", "rockblast_posZ", "tankwall_concrete_debris", "burning_city_effect_plume", "smoke_large_02" };
// ===== 7-9：天生大尺度粒子（单个就覆盖大面积，不靠铺开） =====
// 7 加油站爆炸级冲击波+尘（gas_explosion 本身是整栋楼规模）
char g_sPreset7[][] = { "gas_explosion_shockwave", "gas_explosion_ground_wave", "gas_explosion_initialburst_blast", "gas_explosion_smoke" };
// 8 筒仓/建筑倒塌级
char g_sPreset8[][] = { "missile_hit_explosionshockwave", "explosion_silo", "Dust_Ceiling_Rumble_512Square", "skybox_smoke_01" };
// 9 预设3 + 大尺度增强（推荐：保留3的观感，范围拉满）
char g_sPreset9[][] = { "missile_hit_explosionshockwave", "weapon_pipebomb_dirt", "rockblast_posZ", "gas_explosion_ground_wave", "Dust_Ceiling_Rumble_512Square", "skybox_smoke_01" };
// ===== 10-12：用户定稿组合（gen_rockblast_posZ + gas_explosion_main）及微调变体 =====
// 10 纯定稿：两个粒子
char g_sPreset10[][] = { "gen_rockblast_posZ", "gas_explosion_main" };
// 11 定稿 + 地面冲击波环（增强"炸开"的第一帧张力）
char g_sPreset11[][] = { "missile_hit_explosionshockwave", "gen_rockblast_posZ", "gas_explosion_main" };
// 12 定稿 + 冲击波 + 上升烟（尘云滞留更久，更像 V1 的蘑菇状浮尘）
char g_sPreset12[][] = { "missile_hit_explosionshockwave", "gen_rockblast_posZ", "gas_explosion_main", "gen_dest_risingsmoke" };
// ===== 13：explosion_silo 干净版——剔除坏的 _d/_g 子系统（缺材质 warp4/smokesprites），
// 保留 7 个完好子系统 + silo 自己的主火球（silo 虽然也缺 vistasmokev2 但其余材质能撑起主视觉）
char g_sPreset13[][] = { "explosion_huge_e", "explosion_huge_b", "explosion_huge_c", "explosion_huge_h",
                          "explosion_huge_flames", "explosion_huge_burning_chunks", "explosion_huge_smoking_chunks" };

// 一次爆炸最多创建多少粒子实例。info_particle_system 占 edict（引擎上限 2048），
// 客户端也要同时渲染，超量会直接把客户端打崩。60 是实测安全线。
#define MAX_PARTICLES_PER_BOOM 60

int   g_iPreset  = 12;     // 当前预设，sm_v1p 切换（12=定稿，用户拍板）
float g_fRadius  = 800.0;  // 特效铺开半径，sm_v1r 调
int   g_iRings   = 0;      // 环数（不含中心）。0=只放中心，走"少量但天生大"路线
int   g_iPerRing = 6;      // 每环点数
float g_fWaveDelay = 0.08; // 逐环延迟秒数，sm_v1w 调；制造扩张波观感
bool  g_bTEMode  = true;   // true=TE 派发（不占 edict，推荐）false=实体模式
int   g_iBoomCount = 0;    // 当前爆炸已生成数，用于硬性封顶

int   g_iEffectDispatchIdx = -1;  // "ParticleEffect" 在 EffectDispatch 表的索引

int  g_iMdlIdx = -1;
bool g_bMdlOk;
bool g_bSndMissileOk;
bool g_bSndTankerOk;

public Plugin myinfo =
{
    name = "[L4D2] V1 Asset Test",
    author = "Kiro",
    description = "验证 c1m2 导弹素材可提取可用",
    version = "1.0.0"
};

public void OnPluginStart()
{
    RegAdminCmd("sm_v1check",  Cmd_Check,  ADMFLAG_ROOT, "打印素材 precache 结果");
    RegAdminCmd("sm_v1model",  Cmd_Model,  ADMFLAG_ROOT, "准星处生成导弹模型");
    RegAdminCmd("sm_v1fly",    Cmd_Fly,    ADMFLAG_ROOT, "导弹俯冲落地验证");
    RegAdminCmd("sm_v1boom",   Cmd_Boom,   ADMFLAG_ROOT, "爆炸粒子+音效验证");
    RegAdminCmd("sm_v1autotest", Cmd_Auto, ADMFLAG_ROOT, "自动全素材测试（无需客户端）");
    RegAdminCmd("sm_v1p",      Cmd_Preset, ADMFLAG_ROOT, "切换无火爆炸预设 1-6");
    RegAdminCmd("sm_v1one",    Cmd_One,    ADMFLAG_ROOT, "单独播放一个粒子");
    RegAdminCmd("sm_v1list",   Cmd_List,   ADMFLAG_ROOT, "列出已注册粒子");
    RegAdminCmd("sm_v1r",      Cmd_Radius, ADMFLAG_ROOT, "调特效铺开半径/环数/每环点数");
    RegAdminCmd("sm_v1w",      Cmd_Wave,   ADMFLAG_ROOT, "调逐环延迟（扩张波观感）");
    RegAdminCmd("sm_v1te",     Cmd_TEMode, ADMFLAG_ROOT, "切 TE 派发 / 实体模式");
    RegAdminCmd("sm_v1big",    Cmd_Big,    ADMFLAG_ROOT, "列出/点播大尺度候选");
    RegAdminCmd("sm_v1n",      Cmd_Next,   ADMFLAG_ROOT, "播下一个候选（游标自增）");
    RegAdminCmd("sm_v1c",      Cmd_Cursor, ADMFLAG_ROOT, "设置游标");
    RegAdminCmd("sm_v1mix",    Cmd_Mix,    ADMFLAG_ROOT, "同点叠放多个粒子做组合试验");
}

public void OnMapStart()
{
    // 1. 模型 precache
    g_bMdlOk = IsModelPrecached(MISSILE_MDL);
    g_iMdlIdx = PrecacheModel(MISSILE_MDL, true);
    LogMessage("[v1test] PrecacheModel(%s) -> idx=%d (was_precached=%d)",
        MISSILE_MDL, g_iMdlIdx, g_bMdlOk);

    // 找 "ParticleEffect" 在 EffectDispatch stringtable 的索引，供 TE 派发用
    g_iEffectDispatchIdx = -1;
    int tbl = FindStringTable("EffectDispatch");
    if (tbl != INVALID_STRING_TABLE)
    {
        int cnt = GetStringTableNumStrings(tbl);
        char buf[64];
        for (int i = 0; i < cnt; i++)
        {
            ReadStringTable(tbl, i, buf, sizeof(buf));
            if (StrEqual(buf, "ParticleEffect", false)) { g_iEffectDispatchIdx = i; break; }
        }
    }
    LogMessage("[v1test] EffectDispatch 'ParticleEffect' idx=%d (TE 模式%s可用)",
        g_iEffectDispatchIdx, g_iEffectDispatchIdx < 0 ? "不" : "");

    // 2. 粒子 precache（PrecacheGeneric 粒子文件 + 粒子系统名靠地图/pcf 清单）
    for (int i = 0; i < sizeof(g_sParticles); i++)
    {
        int idx = PrecacheParticle(g_sParticles[i]);
        LogMessage("[v1test] particle '%s' -> stringtable idx=%d", g_sParticles[i], idx);
    }

    // 3. 音效 precache
    g_bSndMissileOk = PrecacheSound(SND_MISSILE, true);
    g_bSndTankerOk  = PrecacheSound(SND_TANKER, true);
    LogMessage("[v1test] PrecacheSound(%s)=%d  PrecacheSound(%s)=%d",
        SND_MISSILE, g_bSndMissileOk, SND_TANKER, g_bSndTankerOk);
}

// 粒子系统名注册到 ParticleEffectNames stringtable。
// 这些 pcf 全在全局 particles_manifest.txt 里（客户端启动即加载），
// 服务端只需把系统名写进 stringtable，客户端就能按名索引到自己已加载的粒子。
int PrecacheParticle(const char[] name)
{
    int tbl = FindStringTable("ParticleEffectNames");
    if (tbl == INVALID_STRING_TABLE) return -1;

    int count = GetStringTableNumStrings(tbl);
    char buf[128];
    for (int i = 0; i < count; i++)
    {
        ReadStringTable(tbl, i, buf, sizeof(buf));
        if (StrEqual(buf, name, false)) return i;
    }
    // 不在表里 → 主动追加（写表期必须在 OnMapStart 的 precache 窗口内）
    bool save = LockStringTables(false);
    AddToStringTable(tbl, name);
    LockStringTables(save);

    count = GetStringTableNumStrings(tbl);
    for (int i = 0; i < count; i++)
    {
        ReadStringTable(tbl, i, buf, sizeof(buf));
        if (StrEqual(buf, name, false)) return i;
    }
    return -1;
}

public Action Cmd_Check(int client, int args)
{
    ReplyToCommand(client, "=== V1 素材验证 ===");
    ReplyToCommand(client, "模型 %s: precache idx=%d valid=%s",
        MISSILE_MDL, g_iMdlIdx, g_iMdlIdx > 0 ? "YES" : "NO");
    ReplyToCommand(client, "音效 overpass_jets.wav: %s", g_bSndMissileOk ? "OK" : "FAIL");
    ReplyToCommand(client, "音效 Tanker_Explosion.wav: %s", g_bSndTankerOk ? "OK" : "FAIL");

    int tbl = FindStringTable("ParticleEffectNames");
    ReplyToCommand(client, "ParticleEffectNames 表条目数: %d",
        tbl == INVALID_STRING_TABLE ? -1 : GetStringTableNumStrings(tbl));
    for (int i = 0; i < sizeof(g_sParticles); i++)
    {
        int idx = PrecacheParticle(g_sParticles[i]);
        ReplyToCommand(client, "  粒子 %-24s idx=%d %s", g_sParticles[i], idx,
            idx >= 0 ? "IN TABLE" : "NOT IN TABLE");
    }
    return Plugin_Handled;
}

// 自动测试：不依赖客户端准星，在地图出生点附近验证实体生成/属性/动画序列
public Action Cmd_Auto(int client, int args)
{
    ReplyToCommand(client, "=== V1 自动素材测试 ===");
    LogMessage("[v1test] ===== AUTOTEST BEGIN =====");

    // 找一个有效坐标：info_player_start 或世界原点上方
    float pos[3] = { 0.0, 0.0, 100.0 };
    int spawn = FindEntityByClassname(-1, "info_survivor_position");
    if (spawn <= 0) spawn = FindEntityByClassname(-1, "info_player_start");
    if (spawn > 0) GetEntPropVector(spawn, Prop_Send, "m_vecOrigin", pos);
    LogMessage("[v1test] test pos from ent=%d (%.0f %.0f %.0f)", spawn, pos[0], pos[1], pos[2]);

    // ---- 测试 1: prop_dynamic_override ----
    int e1 = CreateEntityByName("prop_dynamic_override");
    bool ok1 = false;
    if (e1 > 0)
    {
        DispatchKeyValue(e1, "model", MISSILE_MDL);
        DispatchKeyValue(e1, "solid", "0");
        ok1 = DispatchSpawn(e1);
        if (ok1)
        {
            TeleportEntity(e1, pos, NULL_VECTOR, NULL_VECTOR);
            char mdl[128];
            GetEntPropString(e1, Prop_Data, "m_ModelName", mdl, sizeof(mdl));
            int mi = GetEntProp(e1, Prop_Send, "m_nModelIndex");
            LogMessage("[v1test] prop_dynamic_override ent=%d spawn=OK model='%s' modelindex=%d (precache idx=%d MATCH=%d)",
                e1, mdl, mi, g_iMdlIdx, mi == g_iMdlIdx);
            ReplyToCommand(client, "prop_dynamic_override: OK ent=%d modelindex=%d(=%d) model=%s",
                e1, mi, g_iMdlIdx, mdl);
        }
        else LogMessage("[v1test] prop_dynamic_override DispatchSpawn FAILED");
    }
    if (!ok1) ReplyToCommand(client, "prop_dynamic_override: FAILED");

    // ---- 测试 2: prop_physics_override（带物理，可自由坠落）----
    int e2 = CreateEntityByName("prop_physics_override");
    bool ok2 = false;
    if (e2 > 0)
    {
        DispatchKeyValue(e2, "model", MISSILE_MDL);
        DispatchKeyValue(e2, "solid", "6");
        ok2 = DispatchSpawn(e2);
        if (ok2)
        {
            float p2[3];
            p2 = pos; p2[2] += 200.0;
            TeleportEntity(e2, p2, NULL_VECTOR, NULL_VECTOR);
            int mi = GetEntProp(e2, Prop_Send, "m_nModelIndex");
            LogMessage("[v1test] prop_physics_override ent=%d spawn=OK modelindex=%d", e2, mi);
            ReplyToCommand(client, "prop_physics_override: OK ent=%d modelindex=%d", e2, mi);
        }
        else LogMessage("[v1test] prop_physics_override DispatchSpawn FAILED (无 .phy 碰撞模型 → 预期可能失败)");
    }
    if (!ok2) ReplyToCommand(client, "prop_physics_override: FAILED (模型无 .phy，预期结果)");

    // ---- 测试 3: 动画序列（模型有 @idle）----
    if (ok1)
    {
        int seq = GetEntProp(e1, Prop_Send, "m_nSequence");
        LogMessage("[v1test] m_nSequence=%d", seq);
        ReplyToCommand(client, "动画序列 m_nSequence=%d", seq);
    }

    // ---- 测试 4: 粒子 + 音效实播 ----
    float pb[3];
    pb = pos; pb[2] += 30.0;
    V1Detonate(pb);
    ReplyToCommand(client, "粒子+音效已触发（无客户端在场，仅验证服务端不报错）");

    // 清理
    if (e1 > 0 && IsValidEntity(e1)) CreateTimer(3.0, Timer_KillEnt, EntIndexToEntRef(e1));
    if (e2 > 0 && IsValidEntity(e2)) CreateTimer(3.0, Timer_KillEnt, EntIndexToEntRef(e2));

    LogMessage("[v1test] ===== AUTOTEST END =====");
    ReplyToCommand(client, "=== 测试完毕，详见 SM 日志 ===");
    return Plugin_Handled;
}

bool AimPoint(int client, float out[3])
{
    float eye[3], ang[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    Handle tr = TR_TraceRayFilterEx(eye, ang, MASK_SOLID, RayType_Infinite, TraceIgnorePlayers);
    bool hit = TR_DidHit(tr);
    if (hit) TR_GetEndPosition(out, tr);
    delete tr;
    return hit;
}

public bool TraceIgnorePlayers(int entity, int mask)
{
    return entity > MaxClients;
}

public Action Cmd_Model(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    float pos[3];
    if (!AimPoint(client, pos))
    {
        ReplyToCommand(client, "准星未命中");
        return Plugin_Handled;
    }
    pos[2] += 40.0;

    int ent = CreateEntityByName("prop_dynamic_override");
    if (ent <= 0)
    {
        ReplyToCommand(client, "CreateEntityByName 失败");
        return Plugin_Handled;
    }
    DispatchKeyValue(ent, "model", MISSILE_MDL);
    DispatchKeyValue(ent, "solid", "0");
    DispatchKeyValue(ent, "disableshadows", "1");
    if (!DispatchSpawn(ent))
    {
        ReplyToCommand(client, "DispatchSpawn 失败");
        return Plugin_Handled;
    }
    float ang[3] = { 0.0, 0.0, 0.0 };
    TeleportEntity(ent, pos, ang, NULL_VECTOR);

    ReplyToCommand(client, "导弹模型已生成 ent=%d 位置=(%.0f %.0f %.0f) — 看得见吗？",
        ent, pos[0], pos[1], pos[2]);
    LogMessage("[v1test] model spawned ent=%d pos=(%.0f %.0f %.0f)", ent, pos[0], pos[1], pos[2]);
    CreateTimer(20.0, Timer_KillEnt, EntIndexToEntRef(ent));
    return Plugin_Handled;
}

public Action Timer_KillEnt(Handle t, int ref)
{
    int ent = EntRefToEntIndex(ref);
    if (ent > 0 && IsValidEntity(ent)) AcceptEntityInput(ent, "Kill");
    return Plugin_Stop;
}

// 完整俯冲：准星上方 2000u 生成，朝落点飞，落地播粒子+音效
public Action Cmd_Fly(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    float ground[3];
    if (!AimPoint(client, ground))
    {
        ReplyToCommand(client, "准星未命中");
        return Plugin_Handled;
    }

    float start[3];
    start = ground;
    start[0] += 600.0;      // 斜着俯冲（水平偏移制造倾角）
    start[2] += 2000.0;

    int ent = CreateEntityByName("prop_dynamic_override");
    if (ent <= 0) return Plugin_Handled;
    DispatchKeyValue(ent, "model", MISSILE_MDL);
    DispatchKeyValue(ent, "solid", "0");
    DispatchSpawn(ent);

    // 朝向落点
    float dir[3], ang[3];
    SubtractVectors(ground, start, dir);
    NormalizeVector(dir, dir);
    GetVectorAngles(dir, ang);
    TeleportEntity(ent, start, ang, NULL_VECTOR);

    DataPack dp;
    CreateDataTimer(0.03, Timer_FlyStep, dp, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    dp.WriteCell(EntIndexToEntRef(ent));
    dp.WriteFloat(start[0]); dp.WriteFloat(start[1]); dp.WriteFloat(start[2]);
    dp.WriteFloat(ground[0]); dp.WriteFloat(ground[1]); dp.WriteFloat(ground[2]);
    dp.WriteFloat(0.0);        // progress
    dp.WriteCell(GetClientUserId(client));

    // 飞行音效只在起飞时播一次（跟随实体，落地随实体 Kill 自动停）
    EmitSoundToAll(SND_MISSILE, ent, SNDCHAN_STATIC, SNDLEVEL_TRAIN, _, 1.0);

    ReplyToCommand(client, "导弹俯冲中 ent=%d from(%.0f %.0f %.0f) to(%.0f %.0f %.0f)",
        ent, start[0], start[1], start[2], ground[0], ground[1], ground[2]);
    return Plugin_Handled;
}

public Action Timer_FlyStep(Handle timer, DataPack dp)
{
    dp.Reset();
    int ref = dp.ReadCell();
    float s[3], g[3];
    s[0] = dp.ReadFloat(); s[1] = dp.ReadFloat(); s[2] = dp.ReadFloat();
    g[0] = dp.ReadFloat(); g[1] = dp.ReadFloat(); g[2] = dp.ReadFloat();
    float prog = dp.ReadFloat();
    int userid = dp.ReadCell();

    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent)) return Plugin_Stop;

    prog += 0.04;    // 25 步 ≈ 0.75s 到达
    if (prog >= 1.0)
    {
        // 命中：先掐掉飞行音效，再放爆炸声（否则两条音轨叠着响）
        StopSound(0, SNDCHAN_STATIC, SND_MISSILE);
        for (int c2 = 1; c2 <= MaxClients; c2++)
            if (IsClientInGame(c2) && !IsFakeClient(c2))
                StopSound(c2, SNDCHAN_STATIC, SND_MISSILE);

        V1Detonate(g);
        AcceptEntityInput(ent, "Kill");
        int c = GetClientOfUserId(userid);
        if (c > 0 && IsClientInGame(c))
            PrintToChat(c, "\x04[v1test]\x01 导弹命中，爆炸效果已播放");
        return Plugin_Stop;
    }

    float pos[3];
    for (int i = 0; i < 3; i++)
        pos[i] = s[i] + (g[i] - s[i]) * prog;
    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);

    // 回写 progress
    dp.Reset();
    dp.ReadCell();
    for (int i = 0; i < 6; i++) dp.ReadFloat();
    dp.WriteFloat(prog, false);
    return Plugin_Continue;
}

public Action Cmd_Boom(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    float pos[3];
    if (!AimPoint(client, pos))
    {
        ReplyToCommand(client, "准星未命中");
        return Plugin_Handled;
    }
    V1Detonate(pos);
    ReplyToCommand(client, "爆炸效果已播放 @(%.0f %.0f %.0f)", pos[0], pos[1], pos[2]);
    return Plugin_Handled;
}

// 取当前预设的粒子数组长度和内容
int GetPreset(char[][] dst, int maxn)
{
    int n = 0;
    switch (g_iPreset)
    {
        case 1: { n = sizeof(g_sPreset1); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset1[i]); }
        case 2: { n = sizeof(g_sPreset2); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset2[i]); }
        case 3: { n = sizeof(g_sPreset3); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset3[i]); }
        case 4: { n = sizeof(g_sPreset4); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset4[i]); }
        case 5: { n = sizeof(g_sPreset5); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset5[i]); }
        case 6: { n = sizeof(g_sPreset6); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset6[i]); }
        case 7: { n = sizeof(g_sPreset7); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset7[i]); }
        case 8: { n = sizeof(g_sPreset8); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset8[i]); }
        case 9: { n = sizeof(g_sPreset9); for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset9[i]); }
        case 10:{ n = sizeof(g_sPreset10);for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset10[i]); }
        case 11:{ n = sizeof(g_sPreset11);for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset11[i]); }
        case 12:{ n = sizeof(g_sPreset12);for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset12[i]); }
        case 13:{ n = sizeof(g_sPreset13);for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset13[i]); }
        default:{ n = sizeof(g_sPreset10);for (int i=0;i<n && i<maxn;i++) strcopy(dst[i], 128, g_sPreset10[i]); }
    }
    return n > maxn ? maxn : n;
}

// 把点贴到地面（粒子悬空会看着假）
void SnapToGround(float pos[3])
{
    float from[3], to[3];
    from = pos; from[2] += 200.0;
    to   = pos; to[2]   -= 600.0;
    Handle tr = TR_TraceRayFilterEx(from, to, MASK_SOLID, RayType_EndPoint, TraceIgnorePlayers);
    if (TR_DidHit(tr))
    {
        float hit[3];
        TR_GetEndPosition(hit, tr);
        pos[2] = hit[2] + 8.0;
    }
    delete tr;
}

// bNoSound: 已经在别处播过音效时跳过（防重复）
void V1Detonate(const float pos[3], bool bNoSound = false)
{
    char names[8][128];
    int n = GetPreset(names, 8);

    g_iBoomCount = 0;   // 重置本次爆炸计数

    // 中心：完整预设
    for (int i = 0; i < n; i++) SpawnParticle(pos, names[i]);

    // 环形铺开：逐环延迟触发（扩张波），视觉上成一团持续外扩+上翻的尘云，
    // 而不是同一帧一堆小爆炸。冲击波只在中心放一次，避免叠成一堵墙。
    int total = n;
    for (int r = 1; r <= g_iRings; r++)
    {
        float delay = g_fWaveDelay * float(r);
        for (int k = 0; k < g_iPerRing; k++)
        {
            DataPack dp;
            CreateDataTimer(delay, Timer_RingSpawn, dp, TIMER_FLAG_NO_MAPCHANGE);
            dp.WriteFloat(pos[0]); dp.WriteFloat(pos[1]); dp.WriteFloat(pos[2]);
            dp.WriteCell(r);
            dp.WriteCell(k);
            total += n;
        }
    }

    // 音效：只放爆炸声一次（overpass_jets 归飞行阶段，落地不再播，否则听着重复）
    if (!bNoSound)
        EmitAmbientSound(SND_TANKER, pos, 0, SNDLEVEL_RAIDSIREN, _, 1.0);

    LogMessage("[v1test] detonate preset=%d radius=%.0f rings=%d particles=%d at (%.0f %.0f %.0f)",
        g_iPreset, g_fRadius, g_iRings, total, pos[0], pos[1], pos[2]);
}

// 延迟到点的单环点生成
public Action Timer_RingSpawn(Handle t, DataPack dp)
{
    dp.Reset();
    float c[3];
    c[0] = dp.ReadFloat(); c[1] = dp.ReadFloat(); c[2] = dp.ReadFloat();
    int r = dp.ReadCell();
    int k = dp.ReadCell();

    char names[8][128];
    int n = GetPreset(names, 8);

    float dist = g_fRadius * float(r) / float(g_iRings);
    float phase = (r % 2 == 0) ? (180.0 / float(g_iPerRing)) : 0.0;   // 奇偶环交错
    float ang = phase + 360.0 * float(k) / float(g_iPerRing);

    float p[3];
    p[0] = c[0] + dist * Cosine(DegToRad(ang));
    p[1] = c[1] + dist * Sine(DegToRad(ang));
    p[2] = c[2];
    SnapToGround(p);

    for (int i = 0; i < n; i++)
    {
        if (StrContains(names[i], "shockwave", false) != -1) continue;
        SpawnParticle(p, names[i], false);
    }
    return Plugin_Stop;
}

// sm_v1w <每环延迟秒>  0=同帧全炸
public Action Cmd_Wave(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "当前每环延迟 = %.2fs（总扩张时长 %.2fs）",
            g_fWaveDelay, g_fWaveDelay * float(g_iRings));
        ReplyToCommand(client, "用法: sm_v1w <秒>   0=同帧全炸  0.08=推荐  0.15=慢速翻涌");
        return Plugin_Handled;
    }
    char a[16];
    GetCmdArg(1, a, sizeof(a));
    g_fWaveDelay = StringToFloat(a);
    if (g_fWaveDelay < 0.0)  g_fWaveDelay = 0.0;
    if (g_fWaveDelay > 1.0)  g_fWaveDelay = 1.0;
    // 0 会让 CreateDataTimer 立即触发，等效同帧
    if (g_fWaveDelay < 0.01) g_fWaveDelay = 0.01;
    ReplyToCommand(client, "每环延迟 = %.2fs（总扩张时长 %.2fs）",
        g_fWaveDelay, g_fWaveDelay * float(g_iRings));
    return Plugin_Handled;
}

// sm_v1r <半径> [环数] [每环点数]
public Action Cmd_Radius(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "当前 半径=%.0f 环数=%d 每环点数=%d（总生成点 %d）",
            g_fRadius, g_iRings, g_iPerRing, 1 + g_iRings * g_iPerRing);
        ReplyToCommand(client, "用法: sm_v1r <半径> [环数=2] [每环点数=6]");
        ReplyToCommand(client, "参考: 400=手雷级 800=中型 1200=V1级 1600=超大");
        return Plugin_Handled;
    }
    char a[16];
    GetCmdArg(1, a, sizeof(a));
    g_fRadius = StringToFloat(a);
    if (g_fRadius < 0.0) g_fRadius = 0.0;
    if (args >= 2) { GetCmdArg(2, a, sizeof(a)); g_iRings = StringToInt(a); }
    if (args >= 3) { GetCmdArg(3, a, sizeof(a)); g_iPerRing = StringToInt(a); }
    if (g_iRings   < 0) g_iRings = 0;
    if (g_iRings   > 8) g_iRings = 8;
    if (g_iPerRing < 1) g_iPerRing = 1;
    if (g_iPerRing > 24) g_iPerRing = 24;

    // 预算校验：总粒子数 = 生成点 x 预设粒子数，超 MAX 会被截断
    char names[8][128];
    int n = GetPreset(names, 8);
    int pts = 1 + g_iRings * g_iPerRing;
    int est = pts * n;

    ReplyToCommand(client, "设定 半径=%.0f 环数=%d 每环点数=%d（生成点 %d）",
        g_fRadius, g_iRings, g_iPerRing, pts);
    ReplyToCommand(client, "预计粒子 %d 个（预设%d 有 %d 个粒子/点，上限 %d）",
        est, g_iPreset, n, MAX_PARTICLES_PER_BOOM);
    if (est > MAX_PARTICLES_PER_BOOM)
        ReplyToCommand(client, "\x04警告\x01 超上限，多余会被丢弃。建议降到每环 %d 点",
            (MAX_PARTICLES_PER_BOOM / n - 1) / (g_iRings > 0 ? g_iRings : 1));
    return Plugin_Handled;
}

// sm_v1te <0|1>  切 TE 模式 / 实体模式
public Action Cmd_TEMode(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "当前模式 = %s", g_bTEMode ? "TE 派发（不占 edict）" : "实体（info_particle_system）");
        ReplyToCommand(client, "用法: sm_v1te <0|1>   1=TE  0=实体");
        ReplyToCommand(client, "EffectDispatch 表索引 = %d %s",
            g_iEffectDispatchIdx, g_iEffectDispatchIdx < 0 ? "(不可用，TE 模式会自动退回实体)" : "");
        return Plugin_Handled;
    }
    char a[8];
    GetCmdArg(1, a, sizeof(a));
    g_bTEMode = (StringToInt(a) != 0);
    ReplyToCommand(client, "模式 = %s", g_bTEMode ? "TE 派发" : "实体");
    return Plugin_Handled;
}

// sm_v1p <1-6>  切换预设；sm_v1p 单独用=显示当前
public Action Cmd_Preset(int client, int args)
{
    static const char sDesc[][] = {
        "",
        "1 军用弹着：冲击波+尘爆+向上尘柱（最贴 V1）",
        "2 通用破坏：冲击波+石爆+尘柱+上升烟",
        "3 土石尘爆：冲击波+管子雷土爆+尘柱+大烟",
        "4 混凝土崩塌：油罐冲击波+混凝土碎片+混凝土烟+上升烟",
        "5 桥梁崩塌：冲击波+崩塌尘云x2+烟团",
        "6 重型组合：尘爆+尘柱+墙体碎片+城市烟柱+大烟",
        "7 加油站级：整栋楼规模冲击波+地面波+爆燃+烟（天生大）",
        "8 筒仓级：冲击波+筒仓爆+512天花板扬尘+天空盒烟柱",
        "9 预设3增强：3的观感+地面波+512扬尘+天空盒烟柱",
        "10 ★定稿：gen_rockblast_posZ + gas_explosion_main",
        "11 ★定稿+冲击波环（炸开第一帧更有张力）",
        "12 ★定稿+冲击波+上升烟（浮尘滞留更久，最像V1蘑菇云）",
        "13 explosion_silo干净版：7个完好子系统（剔除缺材质的_d/_g，0紫0抖）"
    };

    if (args < 1)
    {
        ReplyToCommand(client, "当前预设 = %d", g_iPreset);
        for (int i = 1; i <= 13; i++)
            ReplyToCommand(client, "  %s%s", sDesc[i], i == g_iPreset ? "  <= 当前" : "");
        ReplyToCommand(client, "用法: sm_v1p <1-13>");
        return Plugin_Handled;
    }

    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    int p = StringToInt(arg);
    if (p < 1 || p > 13)
    {
        ReplyToCommand(client, "预设范围 1-13");
        return Plugin_Handled;
    }
    g_iPreset = p;
    ReplyToCommand(client, "预设切到 %s", sDesc[p]);
    ReplyToCommand(client, "现在用 sm_v1boom 或 sm_v1fly 看效果");
    return Plugin_Handled;
}

// sm_v1one <粒子名>  单独播一个粒子，用于精细挑选
public Action Cmd_One(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    if (args < 1)
    {
        ReplyToCommand(client, "用法: sm_v1one <粒子系统名>");
        ReplyToCommand(client, "可用列表见 sm_v1list");
        return Plugin_Handled;
    }
    char name[128];
    GetCmdArg(1, name, sizeof(name));
    int idx = PrecacheParticle(name);
    if (idx < 0)
    {
        ReplyToCommand(client, "粒子 '%s' 注册失败（stringtable 满或名字错）", name);
        return Plugin_Handled;
    }
    float pos[3];
    if (!AimPoint(client, pos)) { ReplyToCommand(client, "准星未命中"); return Plugin_Handled; }

    g_iBoomCount = 0;     // 关键：单播必须重置封顶计数，否则上次爆炸顶满后这里静默失败
    SpawnParticle(pos, name);
    ReplyToCommand(client, "播放 '%s' (idx=%d) 模式=%s @(%.0f %.0f %.0f)",
        name, idx, g_bTEMode ? "TE" : "实体", pos[0], pos[1], pos[2]);
    return Plugin_Handled;
}

// ===== 大尺度候选巡演：sm_v1big  逐个播放，每个间隔 3s，聊天框报名字 =====
char g_sBigList[][] = {
    "gas_explosion_ground_wave",
    "gas_explosion_ground_wave2",
    "gas_explosion_shockwave",
    "gas_explosion_shockwave2",
    "gas_explosion_initialburst_blast",
    "gas_explosion_initialburst_smoke",
    "gas_explosion_smoke",
    "gas_explosion_main",
    "explosion_silo",
    "building_destroyed_01",
    "Dust_Ceiling_Rumble_512Square",
    "Dust_Ceiling_Rumble_256Line",
    "skybox_smoke_01",
    "smoke_cloud_point",
    "smoke_large_01",
    "smoke_large_02",
    "burning_city_effect_plume",
    "bridge_collapse",
    "bridge_collapse_b",
    "tankwall_concrete",
    "concrete_smoke",
    "awning_collapse_dust",
    "rockblast_posZ",
    "gen_rockblast_posZ",
    "gen_dest_risingsmoke",
    "missile_hit1_rockblast"
};

int g_iBigCursor = 0;   // sm_v1n 步进游标

// sm_v1big          列出编号（不播）
// sm_v1big <n>      只播第 n 个
// sm_v1big <n> <m>  连播 n..m（手动小批量对比）
public Action Cmd_Big(int client, int args)
{
    if (client <= 0) return Plugin_Handled;

    if (args < 1)
    {
        ReplyToCommand(client, "=== 大尺度候选 %d 个（sm_v1big <编号> 点播）===", sizeof(g_sBigList));
        for (int i = 0; i < sizeof(g_sBigList); i++)
            ReplyToCommand(client, "  %2d. %s", i + 1, g_sBigList[i]);
        ReplyToCommand(client, "sm_v1n = 播下一个（当前游标 %d）", g_iBigCursor + 1);
        return Plugin_Handled;
    }

    float pos[3];
    if (!AimPoint(client, pos)) { ReplyToCommand(client, "准星未命中"); return Plugin_Handled; }

    char a[8];
    GetCmdArg(1, a, sizeof(a));
    int from = StringToInt(a) - 1;
    int to = from;
    if (args >= 2) { GetCmdArg(2, a, sizeof(a)); to = StringToInt(a) - 1; }

    if (from < 0 || from >= sizeof(g_sBigList) || to < from || to >= sizeof(g_sBigList))
    {
        ReplyToCommand(client, "编号范围 1-%d", sizeof(g_sBigList));
        return Plugin_Handled;
    }

    if (from == to)
    {
        BigPlay(client, pos, from);
        g_iBigCursor = from + 1;
        if (g_iBigCursor >= sizeof(g_sBigList)) g_iBigCursor = 0;
    }
    else
    {
        // 小批量连播，间隔 3s
        for (int i = from; i <= to; i++)
        {
            DataPack dp;
            CreateDataTimer(0.1 + 3.0 * float(i - from), Timer_BigStep, dp, TIMER_FLAG_NO_MAPCHANGE);
            dp.WriteFloat(pos[0]); dp.WriteFloat(pos[1]); dp.WriteFloat(pos[2]);
            dp.WriteCell(i);
            dp.WriteCell(GetClientUserId(client));
        }
        ReplyToCommand(client, "连播 %d..%d，每 3s 一个", from + 1, to + 1);
        g_iBigCursor = to + 1;
        if (g_iBigCursor >= sizeof(g_sBigList)) g_iBigCursor = 0;
    }
    return Plugin_Handled;
}

// sm_v1n  播下一个（游标自增），最省事的逐个看法
public Action Cmd_Next(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    float pos[3];
    if (!AimPoint(client, pos)) { ReplyToCommand(client, "准星未命中"); return Plugin_Handled; }

    BigPlay(client, pos, g_iBigCursor);
    g_iBigCursor++;
    if (g_iBigCursor >= sizeof(g_sBigList))
    {
        g_iBigCursor = 0;
        ReplyToCommand(client, "（已到末尾，游标回到 1）");
    }
    return Plugin_Handled;
}

// sm_v1c <n>  设游标
public Action Cmd_Cursor(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "当前游标 = %d (%s)", g_iBigCursor + 1, g_sBigList[g_iBigCursor]);
        return Plugin_Handled;
    }
    char a[8];
    GetCmdArg(1, a, sizeof(a));
    int n = StringToInt(a) - 1;
    if (n < 0 || n >= sizeof(g_sBigList))
    {
        ReplyToCommand(client, "编号范围 1-%d", sizeof(g_sBigList));
        return Plugin_Handled;
    }
    g_iBigCursor = n;
    ReplyToCommand(client, "游标 = %d (%s)", n + 1, g_sBigList[n]);
    return Plugin_Handled;
}

void BigPlay(int client, const float pos[3], int i)
{
    g_iBoomCount = 0;
    SpawnParticle(pos, g_sBigList[i], false);
    ReplyToCommand(client, "\x04[%d/%d]\x01 %s  @(%.0f %.0f %.0f)",
        i + 1, sizeof(g_sBigList), g_sBigList[i], pos[0], pos[1], pos[2]);
}

public Action Timer_BigStep(Handle t, DataPack dp)
{
    dp.Reset();
    float p[3];
    p[0] = dp.ReadFloat(); p[1] = dp.ReadFloat(); p[2] = dp.ReadFloat();
    int i = dp.ReadCell();
    int c = GetClientOfUserId(dp.ReadCell());

    g_iBoomCount = 0;
    SpawnParticle(p, g_sBigList[i], false);
    if (c > 0 && IsClientInGame(c))
        PrintToChat(c, "\x04[%d/%d]\x01 %s", i + 1, sizeof(g_sBigList), g_sBigList[i]);
    return Plugin_Stop;
}

// ===== sm_v1mix <名1> [名2] ... 最多6个，同点叠放，用来手动组合定稿 =====
public Action Cmd_Mix(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    if (args < 1)
    {
        ReplyToCommand(client, "用法: sm_v1mix <粒子1> [粒子2] ... 最多6个");
        ReplyToCommand(client, "同一点叠放，用来试'少量但天生大'的组合");
        return Plugin_Handled;
    }
    float pos[3];
    if (!AimPoint(client, pos)) { ReplyToCommand(client, "准星未命中"); return Plugin_Handled; }

    g_iBoomCount = 0;
    int n = args > 6 ? 6 : args;
    char name[128];
    for (int i = 1; i <= n; i++)
    {
        GetCmdArg(i, name, sizeof(name));
        int idx = PrecacheParticle(name);
        if (idx < 0) { ReplyToCommand(client, "  '%s' 注册失败，跳过", name); continue; }
        SpawnParticle(pos, name, false);
        ReplyToCommand(client, "  + %s (idx=%d)", name, idx);
    }
    EmitAmbientSound(SND_TANKER, pos, 0, SNDLEVEL_RAIDSIREN, _, 1.0);
    ReplyToCommand(client, "已叠放 %d 个 @(%.0f %.0f %.0f)", n, pos[0], pos[1], pos[2]);
    return Plugin_Handled;
}

// sm_v1list  列出全部已注册粒子
public Action Cmd_List(int client, int args)
{
    ReplyToCommand(client, "=== 已注册粒子 (%d) ===", sizeof(g_sParticles));
    for (int i = 0; i < sizeof(g_sParticles); i++)
        ReplyToCommand(client, "  %s", g_sParticles[i]);
    return Plugin_Handled;
}

// TE 派发粒子：走 TempEntity，不创建实体、不占 edict、播完自动消失。
// 代价：无法中途停止/无法挂父实体，但一次性爆炸正好不需要。
void TEParticle(const float pos[3], int particleIdx)
{
    TE_Start("EffectDispatch");
    TE_WriteFloat("m_vOrigin.x", pos[0]);
    TE_WriteFloat("m_vOrigin.y", pos[1]);
    TE_WriteFloat("m_vOrigin.z", pos[2]);
    TE_WriteFloat("m_vStart.x", 0.0);
    TE_WriteFloat("m_vStart.y", 0.0);
    TE_WriteFloat("m_vStart.z", 0.0);
    TE_WriteNum("m_nHitBox", particleIdx);
    TE_WriteNum("m_iEffectName", g_iEffectDispatchIdx);
    TE_SendToAll();
}

void SpawnParticle(const float pos[3], const char[] name, bool bLog = true)
{
    // 硬性封顶：超了直接不生成，防客户端崩
    if (g_iBoomCount >= MAX_PARTICLES_PER_BOOM) return;
    g_iBoomCount++;

    // TE 模式：零 edict
    if (g_bTEMode && g_iEffectDispatchIdx >= 0)
    {
        int idx = PrecacheParticle(name);
        if (idx >= 0)
        {
            TEParticle(pos, idx);
            if (bLog) LogMessage("[v1test] TE particle '%s' idx=%d", name, idx);
            return;
        }
    }

    int ent = CreateEntityByName("info_particle_system");
    if (ent <= 0) return;
    DispatchKeyValue(ent, "effect_name", name);
    DispatchKeyValue(ent, "start_active", "1");
    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
    DispatchSpawn(ent);
    ActivateEntity(ent);
    AcceptEntityInput(ent, "Start");
    CreateTimer(8.0, Timer_KillEnt, EntIndexToEntRef(ent));
    if (bLog) LogMessage("[v1test] particle '%s' ent=%d", name, ent);
}
