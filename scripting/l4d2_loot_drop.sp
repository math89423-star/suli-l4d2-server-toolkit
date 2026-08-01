#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.7.0"
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

// 投掷物池：Tank 必掉 3 个（权重抽 3 不重复 = 各 1 个）/ 小僵尸 1%（胆汁/土制 50/50）
LootItem g_Pool_Throw[MAX_LOOT_ITEMS];
int g_Count_Throw = 0;

// Witch 池：4 选 1（医疗包/电击器/燃烧瓶/高爆弹药包）
LootItem g_Pool_Witch[MAX_LOOT_ITEMS];
int g_Count_Witch = 0;

// 重型武器池：Tank 必掉 2 选 1（M60 / 榴弹发射器）
LootItem g_Pool_Weapon[MAX_LOOT_ITEMS];
int g_Count_Weapon = 0;

// ============================================================================
// ConVars
// ============================================================================
ConVar g_cvEnabled;
ConVar g_cvSI_Adrenaline;
ConVar g_cvSI_Pills;
ConVar g_cvSI_Molotov;
ConVar g_cvSI_Explosive;
ConVar g_cvSI_Incendiary;
ConVar g_cvCommonChance;
ConVar g_cvAnnounce;

// ============================================================================
// Plugin Info
// ============================================================================
public Plugin myinfo =
{
    name        = "L4D2 Loot Drop",
    author      = "Claude",
    description = "击杀掉落战利品：小僵尸1%, 特感7%(5种独立概率), Tank 必掉医疗包+M60/榴弹+3投掷物, Witch 4选1",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
public void OnPluginStart()
{
    g_cvEnabled            = CreateConVar("sm_loot_enabled",              "1",    "启用战利品掉落 (0=关闭, 1=开启)", _, true, 0.0, true, 1.0);
    // v1.7.0：普通特感 5 种物品独立概率（合计 7%），可单独调
    g_cvSI_Adrenaline      = CreateConVar("sm_loot_si_adrenaline",        "1.0",  "特感掉落肾上腺素概率 (%)", _, true, 0.0, true, 100.0);
    g_cvSI_Pills           = CreateConVar("sm_loot_si_pills",             "1.0",  "特感掉落止痛药概率 (%)", _, true, 0.0, true, 100.0);
    g_cvSI_Molotov         = CreateConVar("sm_loot_si_molotov",           "2.0",  "特感掉落燃烧瓶概率 (%)", _, true, 0.0, true, 100.0);
    g_cvSI_Explosive       = CreateConVar("sm_loot_si_explosive",         "1.5",  "特感掉落高爆弹药包概率 (%)", _, true, 0.0, true, 100.0);
    g_cvSI_Incendiary      = CreateConVar("sm_loot_si_incendiary",        "1.5",  "特感掉落燃烧弹药包概率 (%)", _, true, 0.0, true, 100.0);
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
    // —— 投掷物池：Tank 必掉 3 个（权重抽 3 不重复 = 3 种各 1）/ 小僵尸 1%（50/50）——
    g_Count_Throw = 0;
    AddThrow("weapon_pipe_bomb",  "土制炸弹", 40);
    AddThrow("weapon_molotov",    "燃烧瓶",   30);
    AddThrow("weapon_vomitjar",   "胆汁罐",   30);

    // —— Witch 池：4 选 1（等权重）——
    g_Count_Witch = 0;
    AddWitch("weapon_first_aid_kit",         "医疗包",     25);
    AddWitch("weapon_defibrillator",         "电击器",     25);
    AddWitch("weapon_molotov",               "燃烧瓶",     25);
    AddWitch("weapon_upgradepack_explosive", "高爆弹药包", 25);

    // —— 重型武器池：Tank 必掉 2 选 1 ——
    g_Count_Weapon = 0;
    AddWeapon("weapon_rifle_m60",        "M60 轻机枪", 50);
    AddWeapon("weapon_grenade_launcher", "榴弹发射器", 50);
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
// 普通特感掉落：5 种物品独立概率（默认合计 7%），多件同时掉概率可忽略
// ============================================================================
void SpawnSILoot(int attacker, float pos[3], const char[] siName)
{
    float zero[3]; zero[0] = 0.0; zero[1] = 0.0; zero[2] = 0.0;

    if (GetRandomFloat(0.0, 100.0) <= g_cvSI_Adrenaline.FloatValue)
    {
        SpawnOne("weapon_adrenaline", pos, zero);
        Announce(attacker, "肾上腺素", 1, siName);
    }
    if (GetRandomFloat(0.0, 100.0) <= g_cvSI_Pills.FloatValue)
    {
        SpawnOne("weapon_pain_pills", pos, zero);
        Announce(attacker, "止痛药", 1, siName);
    }
    if (GetRandomFloat(0.0, 100.0) <= g_cvSI_Molotov.FloatValue)
    {
        SpawnOne("weapon_molotov", pos, zero);
        Announce(attacker, "燃烧瓶", 1, siName);
    }
    if (GetRandomFloat(0.0, 100.0) <= g_cvSI_Explosive.FloatValue)
    {
        SpawnOne("weapon_upgradepack_explosive", pos, zero);
        Announce(attacker, "高爆弹药包", 1, siName);
    }
    if (GetRandomFloat(0.0, 100.0) <= g_cvSI_Incendiary.FloatValue)
    {
        SpawnOne("weapon_upgradepack_incendiary", pos, zero);
        Announce(attacker, "燃烧弹药包", 1, siName);
    }
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

    // 小僵尸：1% 掉 1 件
    if (GetRandomFloat(0.0, 100.0) > g_cvCommonChance.FloatValue) return;

    // 从僵尸身上掉落，不是击杀者
    float pos[3];
    int infected = event.GetInt("entityid");
    if (infected > 0 && IsValidEntity(infected))
        GetEntPropVector(infected, Prop_Send, "m_vecOrigin", pos);
    else
        GetClientAbsOrigin(attacker, pos);

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
            // ---- Tank：必掉 医疗包 + 强武器(M60/榴弹 2选1) + 3 投掷物 ----
            int picks[MAX_LOOT_ITEMS];
            WeightedPickN(g_Pool_Throw, g_Count_Throw, 3, picks);
            SpawnN(g_Pool_Throw, picks, 3, pos);          // 偏移 0,1,2

            float off3[3] = { -50.0, -20.0, 0.0 };        // 偏移 3：医疗包
            SpawnOne("weapon_first_aid_kit", pos, off3);

            int wIdx = WeightedPick(g_Pool_Weapon, g_Count_Weapon);
            char weaponName[32];
            if (wIdx >= 0)
            {
                float off4[3] = { 50.0, -20.0, 0.0 };     // 偏移 4：强武器
                SpawnOne(g_Pool_Weapon[wIdx].classname, pos, off4);
                strcopy(weaponName, sizeof(weaponName), g_Pool_Weapon[wIdx].displayName);
            }
            else
            {
                strcopy(weaponName, sizeof(weaponName), "(无)");
            }

            char names[256];
            Format(names, sizeof(names), "\x04%s\x01, \x04医疗包\x01, \x04", weaponName);
            char rest[192];
            JoinNames(g_Pool_Throw, picks, 3, rest, sizeof(rest));
            StrCat(names, sizeof(names), rest);
            Announce(attacker, names, 5, siName);
        }
        else
        {
            // ---- 普通特感：5 种独立概率 roll ----
            SpawnSILoot(attacker, pos, siName);
        }
    }
}

// ============================================================================
// event: witch_killed — 4 选 1（医疗包/电击器/燃烧瓶/高爆弹药包，等权重）
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
