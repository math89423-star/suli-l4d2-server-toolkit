#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.9.0"
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

// 投掷物池：Tank 必掉 1 个 / 小僵尸 1%（胆汁/土制 50/50）
LootItem g_Pool_Throw[MAX_LOOT_ITEMS];
int g_Count_Throw = 0;

// Witch 池：4 选 1（高爆弹包35/燃烧弹包35/医疗包15/电击器15）
LootItem g_Pool_Witch[MAX_LOOT_ITEMS];
int g_Count_Witch = 0;

// 装备池：Tank 必掉 2 选 1（医疗包/电击器 50/50——v1.9.0 移除 M60/榴弹：
// 两把大杀器可补给弹药后持续作战，Tank 再掉落不合理，用户拍板 2026-08-17）
LootItem g_Pool_Equip[MAX_LOOT_ITEMS];
int g_Count_Equip = 0;

// 小药池：Tank 必掉 1 个（止痛药/肾上腺素 50/50）
LootItem g_Pool_SmallMed[MAX_LOOT_ITEMS];
int g_Count_SmallMed = 0;

// ============================================================================
// ConVars
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvSI_Molotov;
ConVar g_cvSI_Meds;
ConVar g_cvSI_Packs;
ConVar g_cvCommonChance;
ConVar g_cvAnnounce;

// ============================================================================
// Plugin Info
// ============================================================================
public Plugin myinfo =
{
    name        = "L4D2 Loot Drop",
    author      = "Claude",
    description = "击杀掉落战利品：小僵尸1%(胆汁/土制), 特感4%(单件), Tank 必掉3件(医疗包/电击器+投掷物+小药), Witch 4选1",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled            = CreateConVar("sm_loot_enabled",              "1",    "启用战利品掉落 (0=关闭, 1=开启)", _, true, 0.0, true, 1.0);
    // v1.8.0：特感单次 roll，只掉 1 件（总概率 = 三个 cvar 之和，默认 4%）
    g_cvSI_Molotov         = CreateConVar("sm_loot_si_molotov",           "1.0",  "特感掉落燃烧瓶概率 (%)", _, true, 0.0, true, 100.0);
    g_cvSI_Meds            = CreateConVar("sm_loot_si_meds",              "1.0",  "特感掉落药品组概率 (%) — 止痛药/肾上腺素 50/50", _, true, 0.0, true, 100.0);
    g_cvSI_Packs           = CreateConVar("sm_loot_si_packs",             "2.0",  "特感掉落弹药包组概率 (%) — 燃烧弹包/高爆弹包 50/50", _, true, 0.0, true, 100.0);
    g_cvCommonChance       = CreateConVar("sm_loot_common_chance",        "1.0",  "普通感染者掉落概率 (%) — 胆汁/土制炸弹 50/50", _, true, 0.0, true, 100.0);
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
    // —— 投掷物池：Tank 必掉 1 个 / 小僵尸 1%（50/50）——
    g_Count_Throw = 0;
    AddThrow("weapon_pipe_bomb",  "土制炸弹", 40);
    AddThrow("weapon_molotov",    "燃烧瓶",   30);
    AddThrow("weapon_vomitjar",   "胆汁罐",   30);

    // —— Witch 池：4 选 1（高爆弹包35/燃烧弹包35/医疗包15/电击器15）——
    g_Count_Witch = 0;
    AddWitch("weapon_upgradepack_explosive",  "高爆弹药包", 35);
    AddWitch("weapon_upgradepack_incendiary", "燃烧弹药包", 35);
    AddWitch("weapon_first_aid_kit",          "医疗包",     15);
    AddWitch("weapon_defibrillator",          "电击器",     15);

    // —— 装备池：Tank 必掉 2 选 1（医疗包/电击器 50/50）——
    // v1.9.0: 移除 M60/榴弹（可补给弹药后持续作战，Tank 再掉落不合理——用户拍板）
    g_Count_Equip = 0;
    AddEquip("weapon_first_aid_kit",   "医疗包",     25);
    AddEquip("weapon_defibrillator",   "电击器",     25);

    // —— 小药池：Tank 必掉 1 个（止痛药/肾上腺素 50/50）——
    g_Count_SmallMed = 0;
    AddSmallMed("weapon_pain_pills", "止痛药",   50);
    AddSmallMed("weapon_adrenaline", "肾上腺素", 50);
}

void AddThrow(const char[] cls, const char[] name, int w)
{
    if (g_Count_Throw >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_Throw[g_Count_Throw].classname, 64, cls);
    strcopy(g_Pool_Throw[g_Count_Throw].displayName, 32, name);
    g_Pool_Throw[g_Count_Throw].weight = w;
    g_Count_Throw++;
}

void AddWitch(const char[] cls, const char[] name, int w)
{
    if (g_Count_Witch >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_Witch[g_Count_Witch].classname, 64, cls);
    strcopy(g_Pool_Witch[g_Count_Witch].displayName, 32, name);
    g_Pool_Witch[g_Count_Witch].weight = w;
    g_Count_Witch++;
}

void AddEquip(const char[] cls, const char[] name, int w)
{
    if (g_Count_Equip >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_Equip[g_Count_Equip].classname, 64, cls);
    strcopy(g_Pool_Equip[g_Count_Equip].displayName, 32, name);
    g_Pool_Equip[g_Count_Equip].weight = w;
    g_Count_Equip++;
}

void AddSmallMed(const char[] cls, const char[] name, int w)
{
    if (g_Count_SmallMed >= MAX_LOOT_ITEMS) return;
    strcopy(g_Pool_SmallMed[g_Count_SmallMed].classname, 64, cls);
    strcopy(g_Pool_SmallMed[g_Count_SmallMed].displayName, 32, name);
    g_Pool_SmallMed[g_Count_SmallMed].weight = w;
    g_Count_SmallMed++;
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
// ============================================================================
// 生成单个物品 — spawn 到僵尸位置上方，引擎物理自然掉落
// ============================================================================
int SpawnOne(const char[] classname, float base[3], float off[3])
{
    int ent = CreateEntityByName(classname);
    if (ent == -1) return -1;

    float spawnPos[3];
    spawnPos[0] = base[0] + off[0];
    spawnPos[1] = base[1] + off[1];
    spawnPos[2] = base[2] + 40.0;

    DispatchSpawn(ent);
    TeleportEntity(ent, spawnPos, NULL_VECTOR, NULL_VECTOR);

    // Give reserve ammo to heavy weapons
    if (StrEqual(classname, "weapon_grenade_launcher"))
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 30);
    else if (StrEqual(classname, "weapon_rifle_m60"))
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 150);

    // Glow highlight
    SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
    SetEntProp(ent, Prop_Send, "m_nGlowRange", 800);
    SetEntProp(ent, Prop_Send, "m_glowColorOverride", 50 | (255 << 8) | (50 << 16) | (255 << 24));

    return ent;
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
// 小僵尸掉落：1% 总概率，胆汁/土制炸弹 50/50（只掉 1 件）
// ============================================================================
void SpawnCommonLoot(int attacker, float pos[3])
{
    char cls[64];
    char itemName[32];
    if (GetRandomInt(0, 1) == 0)
    {
        strcopy(cls, sizeof(cls), "weapon_vomitjar");
        strcopy(itemName, sizeof(itemName), "胆汁罐");
    }
    else
    {
        strcopy(cls, sizeof(cls), "weapon_pipe_bomb");
        strcopy(itemName, sizeof(itemName), "土制炸弹");
    }
    float zero[3]; zero[0] = 0.0; zero[1] = 0.0; zero[2] = 0.0;
    SpawnOne(cls, pos, zero);
    Announce(attacker, itemName, 1, "普通感染者");
}

// ============================================================================
// 普通特感掉落：单次 roll，有且只有 1 件（总概率 = 三组之和，默认 4%）
// 燃烧瓶 1% ｜ 止痛药/肾上腺素 1% ｜ 燃烧弹包/高爆弹包 2%
// ============================================================================
void SpawnSILoot(int attacker, float pos[3], const char[] siName)
{
    float m     = g_cvSI_Molotov.FloatValue;
    float meds  = g_cvSI_Meds.FloatValue;
    float packs = g_cvSI_Packs.FloatValue;

    float roll = GetRandomFloat(0.0, 100.0);
    char cls[64];
    char itemName[32];

    if (roll <= m)
    {
        strcopy(cls, sizeof(cls), "weapon_molotov");
        strcopy(itemName, sizeof(itemName), "燃烧瓶");
    }
    else if (roll <= m + meds)
    {
        if (GetRandomInt(0, 1) == 0)
        {
            strcopy(cls, sizeof(cls), "weapon_pain_pills");
            strcopy(itemName, sizeof(itemName), "止痛药");
        }
        else
        {
            strcopy(cls, sizeof(cls), "weapon_adrenaline");
            strcopy(itemName, sizeof(itemName), "肾上腺素");
        }
    }
    else if (roll <= m + meds + packs)
    {
        if (GetRandomInt(0, 1) == 0)
        {
            strcopy(cls, sizeof(cls), "weapon_upgradepack_incendiary");
            strcopy(itemName, sizeof(itemName), "燃烧弹药包");
        }
        else
        {
            strcopy(cls, sizeof(cls), "weapon_upgradepack_explosive");
            strcopy(itemName, sizeof(itemName), "高爆弹药包");
        }
    }
    else
    {
        return;   // 本次不掉落
    }

    float zero[3]; zero[0] = 0.0; zero[1] = 0.0; zero[2] = 0.0;
    SpawnOne(cls, pos, zero);
    Announce(attacker, itemName, 1, siName);
}

// ============================================================================
// event: infected_death — common infected kills（只处理普通感染者）
// ============================================================================
void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return;
    if (GetClientTeam(attacker) != 2) return;

    // v1.8.0：引擎对 Witch/特感死亡也会触发 infected_death —— 只允许
    // 普通感染者(classname "infected")走这条路径，保证"有且只有一件"
    int infected = event.GetInt("entityid");
    if (infected <= 0 || !IsValidEntity(infected)) return;
    char cls[16];
    GetEntityClassname(infected, cls, sizeof(cls));
    if (!StrEqual(cls, "infected")) return;

    // 小僵尸：1% 掉 1 件
    if (GetRandomFloat(0.0, 100.0) > g_cvCommonChance.FloatValue) return;

    // 从僵尸身上掉落，不是击杀者
    float pos[3];
    GetEntPropVector(infected, Prop_Send, "m_vecOrigin", pos);

    SpawnCommonLoot(attacker, pos);
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
        // ---- 小僵尸：1% 掉 1 件 ----
        if (GetRandomFloat(0.0, 100.0) > g_cvCommonChance.FloatValue) return;
        SpawnCommonLoot(attacker, pos);
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
            // ---- Tank：必掉 3 件 = 装备(医疗包/电击器 2选1) + 投掷物 + 小药 ----
            int equipIdx = WeightedPick(g_Pool_Equip, g_Count_Equip);
            int throwIdx = WeightedPick(g_Pool_Throw, g_Count_Throw);
            int medIdx   = WeightedPick(g_Pool_SmallMed, g_Count_SmallMed);
            if (equipIdx < 0 || throwIdx < 0 || medIdx < 0) return;

            float offs[3][3] = {
                {   0.0,  0.0 },
                { -40.0, 30.0 },
                {  40.0, 30.0 }
            };
            SpawnOne(g_Pool_Equip[equipIdx].classname, pos, offs[0]);
            SpawnOne(g_Pool_Throw[throwIdx].classname, pos, offs[1]);
            SpawnOne(g_Pool_SmallMed[medIdx].classname, pos, offs[2]);

            char names[256];
            Format(names, sizeof(names), "\x04%s\x01, \x04%s\x01, \x04%s\x01",
                g_Pool_Equip[equipIdx].displayName,
                g_Pool_Throw[throwIdx].displayName,
                g_Pool_SmallMed[medIdx].displayName);
            Announce(attacker, names, 3, siName);

            EmitSoundToAll("erasounds/bounce_era.wav", SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.4);
        }
        else
        {
            // ---- 普通特感：单次 roll，只掉 1 件 ----
            SpawnSILoot(attacker, pos, siName);
        }
    }
}

// ============================================================================
// event: witch_killed — 4 选 1（高爆弹包35/燃烧弹包35/医疗包15/电击器15）
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
    WeightedPickN(g_Pool_Witch, g_Count_Witch, 1, picks);
    SpawnN(g_Pool_Witch, picks, 1, pos);
    char names[256];
    JoinNames(g_Pool_Witch, picks, 1, names, sizeof(names));
    Announce(attacker, names, 1, "Witch");
}
