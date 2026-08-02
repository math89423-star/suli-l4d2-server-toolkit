#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// v1.0: 右键递物 —— 手持投掷物/医疗包/药 对着队友点右键，对方槽位空则递出
//  - 触发：OnPlayerRunCmd IN_ATTACK2 按下沿（按住不重复触发）
//  - 目标：GetClientAimTarget 视线追踪 + 距离限制 + 幸存者队友（倒地队友也可收）
//  - 槽位（left4dhooks L4DWeaponSlot）：投掷物=2 医疗包=3 药/肾上腺素=4
//  - 用过的医疗包/空药瓶仍占槽（L4D2 引擎特性），replace_used=1 时自动替换（同原版拾取）
//  - 消息走 PrintToChat（PrintHintText CJK 乱码坑太多，见 si_hud v3.5.1 系列）
//  - 手持近战推挤 / si_hud 火炮瞄准右键取消 等场景不受影响（非可递物品不响应）
// v1.1: 递出音效 + 蓄力防误递
//  - 递出成功时给双方播原版递药音效（用户要求"同款递药音效"），cvar l4d2_give_items_sound
//  - 参考 Gear Transfer line-1114 修复（Harry）：按住 IN_ATTACK 时右键不触发递物，
//    防投掷蓄力（左键按住瞄准）中误递
// v1.2: 音效默认关闭 —— 用户实测 v1.1 无音效。根因调查：本镜像服务端无任何原版音效
//  数据（镜像解包 VPK 时删除全部音效文件/脚本，pak01 vpk 是垃圾文件），
//  "weapon_pain_pills/use.wav" 只是推测路径无法服务器侧验证 → cvar 默认置空，
//  音效代码保留，待有可靠音效来源（客户端提取原版文件/自定义 mp3）再开启

#define PLUGIN_VERSION "1.2"

ConVar g_hCvarEnable;
ConVar g_hCvarRange;
ConVar g_hCvarCooldown;
ConVar g_hCvarThrowable;
ConVar g_hCvarMedkit;
ConVar g_hCvarPills;
ConVar g_hCvarDefib;
ConVar g_hCvarReplaceUsed;
ConVar g_hCvarAnnounce;
ConVar g_hCvarSound;

enum GiveItemType
{
    GiveType_None = 0,
    GiveType_Throwable,
    GiveType_Medkit,
    GiveType_Pills,
    GiveType_Defib
}

bool  g_bPrevAttack2[MAXPLAYERS + 1]; // 上次 tick 是否按着右键（按下沿检测）
float g_fLastGive[MAXPLAYERS + 1];    // 上次尝试时刻（防连点刷屏）

public Plugin myinfo =
{
    name        = "[L4D2] Give Items",
    author      = "claude",
    description = "Right-click to give throwables/medkit/pills to teammates if they have a free slot.",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_hCvarEnable      = CreateConVar("l4d2_give_items_enable", "1", "0=OFF, 1=ON.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarRange       = CreateConVar("l4d2_give_items_range", "110", "Max distance (units) to give an item.", FCVAR_NOTIFY, true, 10.0, true, 500.0);
    g_hCvarCooldown    = CreateConVar("l4d2_give_items_cooldown", "0.6", "Seconds between give attempts.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_hCvarThrowable   = CreateConVar("l4d2_give_items_throwable", "1", "0=OFF, 1=ON. Allow giving throwables (pipe bomb/molotov/vomit jar).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarMedkit      = CreateConVar("l4d2_give_items_medkit", "0", "0=OFF, 1=ON. Allow giving medkits.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarPills       = CreateConVar("l4d2_give_items_pills", "0", "0=OFF, 1=ON. Allow giving pills/adrenaline.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarDefib       = CreateConVar("l4d2_give_items_defib", "0", "0=OFF, 1=ON. Allow giving defibrillators (slot unverified).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarReplaceUsed = CreateConVar("l4d2_give_items_replace_used", "1", "0=OFF, 1=ON. Replace target's used medkit/empty pill bottle with the fresh item (vanilla pickup behavior).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarAnnounce    = CreateConVar("l4d2_give_items_announce", "1", "0=OFF, 1=ON. Announce give in chat.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarSound       = CreateConVar("l4d2_give_items_sound", "", "Sound played to both players on give (empty=off). Vanilla sound path, plays client-side without precache.", FCVAR_NOTIFY);

    AutoExecConfig(true, "l4d2_give_items");
}

public void OnClientDisconnect(int client)
{
    g_bPrevAttack2[client] = false;
    g_fLastGive[client] = 0.0;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!(buttons & IN_ATTACK2))
    {
        g_bPrevAttack2[client] = false;
        return Plugin_Continue;
    }
    if (g_bPrevAttack2[client])   // 按住不重复触发
        return Plugin_Continue;
    g_bPrevAttack2[client] = true;

    // v1.1: 参考 Gear Transfer line-1114 修复 —— 按住攻击键（投掷蓄力瞄准中）时右键不递物，防误递
    if (buttons & IN_ATTACK)
        return Plugin_Continue;

    TryGiveItem(client);
    return Plugin_Continue;
}

void TryGiveItem(int client)
{
    if (!g_hCvarEnable.BoolValue) return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return;
    if (GetClientTeam(client) != 2 || !IsPlayerAlive(client)) return;

    float now = GetEngineTime();
    if (now - g_fLastGive[client] < g_hCvarCooldown.FloatValue) return;

    // 手持武器必须是可递物品（近战推挤 / 火炮瞄准等场景不受影响）
    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsValidEdict(active)) return;

    char cls[32];
    GetEdictClassname(active, cls, sizeof(cls));
    GiveItemType type = ClassToType(cls);
    if (type == GiveType_None || !TypeEnabled(type)) return;

    // 正在使用物品（打包/吃药动画中）不递，防移除动画中的武器
    if (HasEntProp(client, Prop_Send, "m_hUsingEntity") && GetEntPropEnt(client, Prop_Send, "m_hUsingEntity") > 0)
        return;

    // 目标：准星指向的队友（视线内），距离在范围内；倒地队友也可收
    int target = GetClientAimTarget(client, true);
    if (target < 1 || target > MaxClients || target == client) return;
    if (!IsClientInGame(target) || GetClientTeam(target) != 2 || !IsPlayerAlive(target)) return;

    float eye[3], org[3];
    GetClientEyePosition(client, eye);
    GetEntPropVector(target, Prop_Send, "m_vecOrigin", org);
    if (GetVectorDistance(eye, org) > g_hCvarRange.FloatValue) return;

    g_fLastGive[client] = now;  // 通过校验即计入冷却，防失败场景连点刷屏

    // 槽位检查：L4D2 投掷物=2 医疗包=3 药=4（left4dhooks L4DWeaponSlot 枚举）
    int targetWeapon = GetPlayerWeaponSlot(target, TypeSlot(type));
    if (targetWeapon > 0 && IsValidEdict(targetWeapon))
    {
        if (g_hCvarReplaceUsed.BoolValue && IsUsedItem(targetWeapon))
        {
            // 用过的医疗包/空药瓶：清掉再给新的（同原版拾取行为）
            RemovePlayerItem(target, targetWeapon);
            RemoveEntity(targetWeapon);
            LogMessage("[GiveItems] replaced used item: %N -> %N (%s)", client, target, cls);
        }
        else
        {
            PrintToChat(client, "\x04[递物]\x01 队友 \x05%N\x01 该槽位已有物品，递不出去", target);
            return;
        }
    }

    int newEnt = GivePlayerItem(target, cls);
    if (newEnt <= 0 || !IsValidEdict(newEnt))
    {
        LogMessage("[GiveItems] GivePlayerItem FAILED: %N -> %N (%s)", client, target, cls);
        PrintToChat(client, "\x04[递物]\x01 递送失败");
        return;
    }

    // 移除自己手里的物品（若为主动武器，引擎自动切换）
    if (IsValidEdict(active))
    {
        RemovePlayerItem(client, active);
        RemoveEntity(active);
    }

    char name[24];
    ItemNameFromClass(cls, name, sizeof(name));
    LogMessage("[GiveItems] %N gave %s to %N", client, name, target);

    // v1.1: 递出音效 —— 原版递药音效（weapon_pain_pills/use.wav），双方各播一次
    char sound[128];
    g_hCvarSound.GetString(sound, sizeof(sound));
    if (sound[0] != '\0')
    {
        EmitSoundToClient(client, sound, client, SNDCHAN_AUTO);
        EmitSoundToClient(target, sound, target, SNDCHAN_AUTO);
    }

    if (g_hCvarAnnounce.BoolValue)
    {
        PrintToChat(client, "\x04[递物]\x01 你把 \x05%s\x01 递给了队友 \x05%N\x01", name, target);
        PrintToChat(target, "\x04[递物]\x01 队友 \x05%N\x01 给了你 \x05%s\x01", client, name);
    }
}

GiveItemType ClassToType(const char[] cls)
{
    if (StrEqual(cls, "weapon_pipe_bomb", false) || StrEqual(cls, "weapon_molotov", false) || StrEqual(cls, "weapon_vomitjar", false))
        return GiveType_Throwable;
    if (StrEqual(cls, "weapon_first_aid_kit", false))
        return GiveType_Medkit;
    if (StrEqual(cls, "weapon_pain_pills", false) || StrEqual(cls, "weapon_adrenaline", false))
        return GiveType_Pills;
    if (StrEqual(cls, "weapon_defibrillator", false))
        return GiveType_Defib;
    return GiveType_None;
}

bool TypeEnabled(GiveItemType type)
{
    switch (type)
    {
        case GiveType_Throwable: return g_hCvarThrowable.BoolValue;
        case GiveType_Medkit:    return g_hCvarMedkit.BoolValue;
        case GiveType_Pills:     return g_hCvarPills.BoolValue;
        case GiveType_Defib:     return g_hCvarDefib.BoolValue;
    }
    return false;
}

int TypeSlot(GiveItemType type)
{
    switch (type)
    {
        case GiveType_Throwable: return 2;  // L4DWeaponSlot_Grenade
        case GiveType_Medkit:    return 3;  // L4DWeaponSlot_FirstAid
        case GiveType_Pills:     return 4;  // L4DWeaponSlot_Pills
        case GiveType_Defib:     return 3;  // 待实测：defib 槽位未验证，仅 cvar 开启时生效
    }
    return -1;
}

void ItemNameFromClass(const char[] cls, char[] buf, int len)
{
    if (StrEqual(cls, "weapon_pipe_bomb", false))        strcopy(buf, len, "土制炸弹");
    else if (StrEqual(cls, "weapon_molotov", false))     strcopy(buf, len, "燃烧瓶");
    else if (StrEqual(cls, "weapon_vomitjar", false))    strcopy(buf, len, "胆汁");
    else if (StrEqual(cls, "weapon_first_aid_kit", false)) strcopy(buf, len, "医疗包");
    else if (StrEqual(cls, "weapon_pain_pills", false))  strcopy(buf, len, "药丸");
    else if (StrEqual(cls, "weapon_adrenaline", false))  strcopy(buf, len, "肾上腺素");
    else if (StrEqual(cls, "weapon_defibrillator", false)) strcopy(buf, len, "电击器");
    else strcopy(buf, len, "物品");
}

// 判定槽内物品是否"已用过"：L4D2 用过的医疗包/空药瓶仍占槽位。
// 防御式双探测（HasEntProp 防 prop 不存在抛异常）+ 日志留证，首次实测后校准。
bool IsUsedItem(int ent)
{
    if (HasEntProp(ent, Prop_Send, "m_bIsUsed"))
    {
        bool used = view_as<bool>(GetEntProp(ent, Prop_Send, "m_bIsUsed"));
        LogMessage("[GiveItems] used-check %d m_bIsUsed=%d", ent, used);
        return used;
    }
    if (HasEntProp(ent, Prop_Send, "m_iClip1"))
    {
        int clip = GetEntProp(ent, Prop_Send, "m_iClip1");
        LogMessage("[GiveItems] used-check %d m_iClip1=%d", ent, clip);
        return clip <= 0;
    }
    LogMessage("[GiveItems] used-check %d: no usable prop", ent);
    return false;
}
