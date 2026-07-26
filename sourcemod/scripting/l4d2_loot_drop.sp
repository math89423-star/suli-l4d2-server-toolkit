#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.5.0"
#define CHAT_PREFIX "\x04[战利品]\x01"
#define MAX_LOOT_ITEMS 16

// ============================================================================
// 掉落物品定义
// ============================================================================
enum struct LootItem
{
    char classname[64];
    char displayName[32];
    int weight;
}

// SI 补给池：普通特感 6%（仅弹药包/医疗包/电击器）
LootItem g_Pool_SI[MAX_LOOT_ITEMS];
int g_Count_SI = 0;

// 投掷物池：普通特感 / 小僵尸（仅投掷物，不含药品）
LootItem g_Pool_Throw[MAX_LOOT_ITEMS];
int g_Count_Throw = 0;

// 投掷+药品池：普通特感 3% / 小僵尸 2%（投掷物 50% + 药品 50%）
LootItem g_Pool_ThrowMed[MAX_LOOT_ITEMS];
int g_Count_ThrowMed = 0;

// 全池：SI + 投掷物（Tank / Witch 用）
LootItem g_Pool_Full[MAX_LOOT_ITEMS];
int g_Count_Full = 0;

// 重型武器池：M60 / 榴弹发射器
LootItem g_Pool_Weapon[MAX_LOOT_ITEMS];
int g_Count_Weapon = 0;

// ============================================================================
// ConVars
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvSI_SupplyChance;
ConVar g_cvSI_ThrowChance;
ConVar g_cvSI_WeaponChance;
ConVar g_cvCommonChance;
ConVar g_cvWitchWeaponChance;
ConVar g_cvAnnounce;

// ============================================================================
// Plugin Info
// ============================================================================
public Plugin myinfo =
{
    name        = "L4D2 Loot Drop",
    author      = "Claude",
    description = "击杀掉落战利品：Tank 100%掉重型武器+3件, Witch 1件+20%重型武器, 特感单次10%掉1件, 小僵尸2%",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled            = CreateConVar("sm_loot_enabled",              "1",    "启用战利品掉落 (0=关闭, 1=开启)", _, true, 0.0, true, 1.0);
    g_cvSI_SupplyChance    = CreateConVar("sm_loot_si_supply_chance",     "6.0",  "特感掉落补给品概率 (%)", _, true, 0.0, true, 100.0);
    g_cvSI_ThrowChance     = CreateConVar("sm_loot_si_throw_chance",      "3.0",  "特感掉落投掷物/药品概率 (%)", _, true, 0.0, true, 100.0);
    g_cvSI_WeaponChance    = CreateConVar("sm_loot_si_weapon_chance",     "1.0",  "特感掉落重型武器概率 (%)", _, true, 0.0, true, 100.0);
    g_cvCommonChance       = CreateConVar("sm_loot_common_chance",        "2.0",  "普通感染者掉落概率 (%)", _, true, 0.0, true, 100.0);
    g_cvWitchWeaponChance  = CreateConVar("sm_loot_witch_weapon_chance",  "20.0", "Witch 额外掉落重型武器概率 (%)", _, true, 0.0, true, 100.0);
    g_cvAnnounce           = CreateConVar("sm_loot_announce",              "1",    "掉落通知 (0=关闭, 1=仅击杀者, 2=全体)", _, true, 0.0, true, 2.0);

    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("witch_killed",   Event_WitchKilled);
    HookEvent("infected_death", Event_InfectedDeath);

    AutoExecConfig(true, "l4d2_loot_drop");

    LoadTables();
}

public void OnMapStart()
{
    AddFileToDownloadsTable("sound/erasounds/bounce_era.wav");
    PrecacheSound("erasounds/bounce_era.wav", true);
}

// ============================================================================
// 掉落表
// ============================================================================
void LoadTables()
{
    // —— 普通特感补给池（6%）——
    g_Count_SI = 0;
    AddSI("weapon_upgradepack_incendiary", "燃烧弹药包", 30);
    AddSI("weapon_upgradepack_explosive",  "高爆弹药包", 30);
    AddSI("weapon_first_aid_kit",          "医疗包",     20);
    AddSI("weapon_defibrillator",          "电击器",     20);

    // —— 投掷物池：仅投掷物（构建全池用）——
    g_Count_Throw = 0;
    AddThrow("weapon_pipe_bomb",  "土制炸弹", 40);
    AddThrow("weapon_molotov",    "燃烧瓶",   30);
    AddThrow("weapon_vomitjar",   "胆汁罐",   30);

    // —— 投掷+药品池：普通特感 3% / 小僵尸 2%（投掷物 50% + 药品 50%）——
    g_Count_ThrowMed = 0;
    AddThrowMed("weapon_pipe_bomb",   "土制炸弹", 17);
    AddThrowMed("weapon_molotov",     "燃烧瓶",   17);
    AddThrowMed("weapon_vomitjar",    "胆汁罐",   16);
    AddThrowMed("weapon_pain_pills",  "止痛药",   25);
    AddThrowMed("weapon_adrenaline",  "肾上腺素", 25);

    // —— 全池：SI + 投掷物（Tank / Witch）——
    g_Count_Full = 0;
    for (int i = 0; i < g_Count_SI; i++)
        AddFull(g_Pool_SI[i].classname, g_Pool_SI[i].displayName, g_Pool_SI[i].weight);
    for (int i = 0; i < g_Count_Throw; i++)
        AddFull(g_Pool_Throw[i].classname, g_Pool_Throw[i].displayName, g_Pool_Throw[i].weight);

    // —— 重型武器池：M60 / 榴弹发射器 ——
    g_Count_Weapon = 0;
    AddWeapon("weapon_rifle_m60",         "M60 轻机枪", 50);
    AddWeapon("weapon_grenade_launcher",  "榴弹发射器", 50);
}

void AddSI(const char[] cls, const char[] name, int w)
{
    if (g_Count_SI >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_SI[g_Count_SI].classname, 64, cls);
    strcopy(g_Pool_SI[g_Count_SI].displayName, 32, name);
    g_Pool_SI[g_Count_SI].weight = w;
    g_Count_SI++;
}

void AddThrow(const char[] cls, const char[] name, int w)
{
    if (g_Count_Throw >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_Throw[g_Count_Throw].classname, 64, cls);
    strcopy(g_Pool_Throw[g_Count_Throw].displayName, 32, name);
    g_Pool_Throw[g_Count_Throw].weight = w;
    g_Count_Throw++;
}

void AddThrowMed(const char[] cls, const char[] name, int w)
{
    if (g_Count_ThrowMed >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_ThrowMed[g_Count_ThrowMed].classname, 64, cls);
    strcopy(g_Pool_ThrowMed[g_Count_ThrowMed].displayName, 32, name);
    g_Pool_ThrowMed[g_Count_ThrowMed].weight = w;
    g_Count_ThrowMed++;
}

void AddFull(const char[] cls, const char[] name, int w)
{
    if (g_Count_Full >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_Full[g_Count_Full].classname, 64, cls);
    strcopy(g_Pool_Full[g_Count_Full].displayName, 32, name);
    g_Pool_Full[g_Count_Full].weight = w;
    g_Count_Full++;
}

void AddWeapon(const char[] cls, const char[] name, int w)
{
    if (g_Count_Weapon >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_Weapon[g_Count_Weapon].classname, 64, cls);
    strcopy(g_Pool_Weapon[g_Count_Weapon].displayName, 32, name);
    g_Pool_Weapon[g_Count_Weapon].weight = w;
    g_Count_Weapon++;
}

// ============================================================================
// 权重随机选 1 个
// ============================================================================
int WeightedPick(LootItem pool[MAX_LOOT_ITEMS], int count)
{
    if (count <= 0) return -1;
    int total = 0;
    for (int i = 0; i < count; i++)
        total += pool[i].weight;
    if (total <= 0) return -1;

    int roll = GetRandomInt(1, total);
    int cum = 0;
    for (int i = 0; i < count; i++)
    {
        cum += pool[i].weight;
        if (roll <= cum) return i;
    }
    return count - 1;
}

// ============================================================================
// 权重不重复抽取 N 个（N ≤ count 时退化为全排列）
// 返回选中的索引数组，结果存在 result[] 中
// ============================================================================
void WeightedPickN(LootItem pool[MAX_LOOT_ITEMS], int count, int n, int result[MAX_LOOT_ITEMS])
{
    // 不足 N 个时全取
    int need = n;
    if (need > count) need = count;

    // 构建候选列表
    int candidates[MAX_LOOT_ITEMS];
    int weights[MAX_LOOT_ITEMS];
    int candCount = count;
    for (int i = 0; i < count; i++)
    {
        candidates[i] = i;
        weights[i] = pool[i].weight;
    }

    for (int pick = 0; pick < need; pick++)
    {
        // 计算剩余候选总权重
        int total = 0;
        for (int i = 0; i < candCount; i++)
            total += weights[i];
        if (total <= 0) break;

        int roll = GetRandomInt(1, total);
        int cum = 0;
        int chosen = 0;
        for (int i = 0; i < candCount; i++)
        {
            cum += weights[i];
            if (roll <= cum)
            {
                chosen = i;
                break;
            }
        }

        result[pick] = candidates[chosen];

        // 移除已选（尾部替换）
        candCount--;
        candidates[chosen] = candidates[candCount];
        weights[chosen] = weights[candCount];
    }
}

// ============================================================================
// 射线过滤
// ============================================================================
public bool TraceFilterIgnoreEntity(int entity, int contentsMask, any data)
{
    return entity != data;
}

// ============================================================================
// 地面追踪 + 生成单个物品
// ============================================================================
void SpawnOne(const char[] classname, float base[3], float off[3])
{
    int ent = CreateEntityByName(classname);
    if (ent == -1) return;

    float from[3];
    from[0] = base[0] + off[0];
    from[1] = base[1] + off[1];
    from[2] = base[2] + 20.0;

    float to[3];
    Handle tr = TR_TraceRayFilterEx(from, view_as<float>({ 90.0, 0.0, 0.0 }), MASK_SOLID, RayType_Infinite, TraceFilterIgnoreEntity, ent);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(to, tr);
        to[2] += 5.0;
    }
    else
    {
        to = from;
    }
    delete tr;

    DispatchSpawn(ent);
    TeleportEntity(ent, to, NULL_VECTOR, NULL_VECTOR);

    // Give reserve ammo to heavy weapons
    if (StrEqual(classname, "weapon_grenade_launcher"))
    {
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 30);
    }

    // Glow highlight: golden outline visible through walls at close range
    SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
    SetEntProp(ent, Prop_Send, "m_nGlowRange", 800);
    SetEntProp(ent, Prop_Send, "m_glowColorOverride", 50 | (255 << 8) | (50 << 16) | (255 << 24)); // bright green
}

// ============================================================================
// 按索引数组生成 N 个物品（散布），可选是否播放音效
// ============================================================================
void SpawnN(LootItem pool[MAX_LOOT_ITEMS], int indices[MAX_LOOT_ITEMS], int n, float pos[3], bool playSound = true)
{
    float offsets[6][3] = {
        {   0.0,   0.0 },
        { -40.0,  30.0 },
        {  40.0,  30.0 },
        { -50.0, -20.0 },
        {  50.0, -20.0 },
        {   0.0, -40.0 }
    };

    for (int i = 0; i < n; i++)
    {
        float off[3];
        if (i < 6)
        {
            off[0] = offsets[i][0];
            off[1] = offsets[i][1];
            off[2] = 0.0;
        }
        else
        {
            off[0] = GetRandomFloat(-50.0, 50.0);
            off[1] = GetRandomFloat(-50.0, 50.0);
            off[2] = 0.0;
        }
        SpawnOne(pool[indices[i]].classname, pos, off);
    }

    // Play bounce sound when loot drops
    if (playSound)
        EmitSoundToAll("erasounds/bounce_era.wav", SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.4);
}

// ============================================================================
// 拼接选中物品名
// ============================================================================
void JoinNames(LootItem pool[MAX_LOOT_ITEMS], int indices[MAX_LOOT_ITEMS], int n, char[] out, int maxlen)
{
    Format(out, maxlen, "");
    for (int i = 0; i < n; i++)
    {
        if (i > 0) StrCat(out, maxlen, "\x01, \x04");
        StrCat(out, maxlen, pool[indices[i]].displayName);
    }
}

// ============================================================================
// 通知
// ============================================================================
void Announce(int attacker, const char[] names, int n, const char[] killType)
{
    int mode = g_cvAnnounce.IntValue;
    if (mode == 0) return;

    if (mode == 1)
        PrintToChat(attacker,  "%s 击杀 \x05%s\x01 掉落: \x04%s\x01 (x%d)", CHAT_PREFIX, killType, names, n);
    else if (mode == 2)
        PrintToChatAll("%s \x05%N\x01 击杀 \x05%s\x01 掉落: \x04%s\x01 (x%d)", CHAT_PREFIX, attacker, killType, names, n);
}

// ============================================================================
// event: infected_death — common infected kills
// ============================================================================
void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return;
    if (GetClientTeam(attacker) != 2) return;

    // 小僵尸：2% 概率掉落 1 件（投掷物/药品各 50%，权重编码在池中）
    if (GetRandomFloat(0.0, 100.0) > g_cvCommonChance.FloatValue) return;
    int idx = WeightedPick(g_Pool_ThrowMed, g_Count_ThrowMed);
    if (idx < 0) return;

    float pos[3];
    GetClientAbsOrigin(attacker, pos);

    int tmp[MAX_LOOT_ITEMS]; tmp[0] = idx;
    SpawnN(g_Pool_ThrowMed, tmp, 1, pos);
    Announce(attacker, g_Pool_ThrowMed[idx].displayName, 1, "普通感染者");
}

// ============================================================================
// event: player_death
// ============================================================================
void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (victim == 0 || attacker == 0) return;
    if (victim == attacker) return;
    if (!g_cvEnabled.BoolValue) return;
    if (!IsClientInGame(attacker) || GetClientTeam(attacker) != 2) return;
    if (GetClientTeam(victim) != 3) return;

    float pos[3];
    GetClientAbsOrigin(victim, pos);
    int zClass = GetEntProp(victim, Prop_Send, "m_zombieClass");

    if (zClass == 0)
    {
        // ---- 小僵尸：2% 概率 1 件（投掷物/药品各 50%）----
        if (GetRandomFloat(0.0, 100.0) > g_cvCommonChance.FloatValue) return;
        int idx = WeightedPick(g_Pool_ThrowMed, g_Count_ThrowMed);
        if (idx < 0) return;
        int tmp[MAX_LOOT_ITEMS]; tmp[0] = idx;
        SpawnN(g_Pool_ThrowMed, tmp, 1, pos);
        Announce(attacker, g_Pool_ThrowMed[idx].displayName, 1, "普通感染者");
    }
    else
    {
        char siName[32];
        switch (zClass)
        {
            case 1: siName = "Smoker";
            case 2: siName = "Boomer";
            case 3: siName = "Hunter";
            case 4: siName = "Spitter";
            case 5: siName = "Jockey";
            case 6: siName = "Charger";
            case 8: siName = "Tank";
            default: siName = "特感";
        }

        if (zClass == 8)
        {
            // ---- Tank：100% 重型武器 + 全池不重复 3 件 = 4 件 ----
            int weaponIdx = WeightedPick(g_Pool_Weapon, g_Count_Weapon);
            int picks[MAX_LOOT_ITEMS];
            WeightedPickN(g_Pool_Full, g_Count_Full, 3, picks);

            // 组合 4 件：武器在前，全池 3 件在后
            LootItem combined[MAX_LOOT_ITEMS];
            int combinedIndices[MAX_LOOT_ITEMS];
            combined[0] = g_Pool_Weapon[weaponIdx]; combinedIndices[0] = 0;
            for (int i = 0; i < 3; i++)
            {
                combined[1 + i] = g_Pool_Full[picks[i]];
                combinedIndices[1 + i] = 1 + i;
            }

            char names[256];
            // 收集所有名字到 names（用 JoinNames 逻辑但跨池）
            Format(names, sizeof(names), "\x04%s\x01, \x04", g_Pool_Weapon[weaponIdx].displayName);
            char rest[192];
            JoinNames(g_Pool_Full, picks, 3, rest, sizeof(rest));
            StrCat(names, sizeof(names), rest);

            SpawnN(combined, combinedIndices, 4, pos);
            Announce(attacker, names, 4, siName);
        }
        else
        {
            // ---- 普通特感：单次 roll，总概率 = 补给% + 投掷药品% + 武器%，仅掉 1 件 ----
            float supplyProb = g_cvSI_SupplyChance.FloatValue;
            float throwProb  = g_cvSI_ThrowChance.FloatValue;
            float weaponProb = g_cvSI_WeaponChance.FloatValue;
            float totalProb  = supplyProb + throwProb + weaponProb;
            if (totalProb <= 0.0) return;

            float roll = GetRandomFloat(0.0, 100.0);
            if (roll > totalProb) return;

            if (roll <= weaponProb)
            {
                // 1%：重型武器
                int idx = WeightedPick(g_Pool_Weapon, g_Count_Weapon);
                if (idx >= 0)
                {
                    int tmp[MAX_LOOT_ITEMS]; tmp[0] = idx;
                    SpawnN(g_Pool_Weapon, tmp, 1, pos);
                    Announce(attacker, g_Pool_Weapon[idx].displayName, 1, siName);
                }
            }
            else if (roll <= weaponProb + throwProb)
            {
                // 3%：投掷物/药品（各 50%）
                int idx = WeightedPick(g_Pool_ThrowMed, g_Count_ThrowMed);
                if (idx >= 0)
                {
                    int tmp[MAX_LOOT_ITEMS]; tmp[0] = idx;
                    SpawnN(g_Pool_ThrowMed, tmp, 1, pos);
                    Announce(attacker, g_Pool_ThrowMed[idx].displayName, 1, siName);
                }
            }
            else
            {
                // 6%：补给品
                int idx = WeightedPick(g_Pool_SI, g_Count_SI);
                if (idx >= 0)
                {
                    int tmp[MAX_LOOT_ITEMS]; tmp[0] = idx;
                    SpawnN(g_Pool_SI, tmp, 1, pos);
                    Announce(attacker, g_Pool_SI[idx].displayName, 1, siName);
                }
            }
        }
    }
}

// ============================================================================
// event: witch_killed — 全池不重复 1 件 + 20% 重型武器
// ============================================================================
void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return;

    int attacker = GetClientOfUserId(event.GetInt("userid"));
    if (attacker == 0 || !IsClientInGame(attacker) || GetClientTeam(attacker) != 2) return;

    int witchid = event.GetInt("witchid");
    if (witchid <= 0 || !IsValidEntity(witchid)) return;

    float pos[3];
    GetEntPropVector(witchid, Prop_Send, "m_vecOrigin", pos);

    int picks[MAX_LOOT_ITEMS];
    WeightedPickN(g_Pool_Full, g_Count_Full, 1, picks);
    char names[256];
    JoinNames(g_Pool_Full, picks, 1, names, sizeof(names));

    // 20% 额外掉落重型武器
    if (GetRandomFloat(0.0, 100.0) <= g_cvWitchWeaponChance.FloatValue)
    {
        int weaponIdx = WeightedPick(g_Pool_Weapon, g_Count_Weapon);
        if (weaponIdx >= 0)
        {
            // 组合 2 件
            LootItem combined[MAX_LOOT_ITEMS];
            int combinedIndices[MAX_LOOT_ITEMS];
            combined[0] = g_Pool_Full[picks[0]];     combinedIndices[0] = 0;
            combined[1] = g_Pool_Weapon[weaponIdx];  combinedIndices[1] = 1;

            char weaponName[32];
            strcopy(weaponName, sizeof(weaponName), g_Pool_Weapon[weaponIdx].displayName);
            Format(names, sizeof(names), "\x04%s\x01, \x04%s", g_Pool_Full[picks[0]].displayName, weaponName);

            SpawnN(combined, combinedIndices, 2, pos);
            Announce(attacker, names, 2, "Witch");
        }
        else
        {
            SpawnN(g_Pool_Full, picks, 1, pos);
            Announce(attacker, names, 1, "Witch");
        }
    }
    else
    {
        SpawnN(g_Pool_Full, picks, 1, pos);
        Announce(attacker, names, 1, "Witch");
    }
}
