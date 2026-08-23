#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>

ConVar g_cvIncend, g_cvExplosive;

int g_iRemaining[MAXPLAYERS+1]; // 兼容旧：剩余弹夹数
int g_iTotalSpecial[MAXPLAYERS+1]; // 精确总特殊弹药数（150）
int g_iUpgradeBit[MAXPLAYERS+1]; // 1=燃烧 2=高爆
int g_iClipSize[MAXPLAYERS+1];
int g_iWeaponRef[MAXPLAYERS+1];
bool g_bLaser[MAXPLAYERS+1];
int g_iOrigReserve[MAXPLAYERS+1];
int g_iAmmoType[MAXPLAYERS+1];

Handle g_hTimer = null;
Handle g_hHudSync = null;

public Plugin myinfo = {
    name = "[L4D2] Upgradepack 3 Clip",
    author = "suli",
    description = "燃烧/高爆弹药包维持3个弹夹（50*3）+ 备弹HUD",
    version = "1.2.0",
    url = ""
};

public void OnPluginStart()
{
    g_cvIncend = CreateConVar("l4d2_upgradepack_incend_mult", "3.0", "燃烧弹维持弹夹数", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    g_cvExplosive = CreateConVar("l4d2_upgradepack_explosive_mult", "3.0", "高爆弹维持弹夹数", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    HookEvent("upgrade_pack_used", Event_UpgradeUsed, EventHookMode_Post);
    HookEvent("upgrade_pack_added", Event_UpgradeUsed, EventHookMode_Post);
    HookEvent("player_use", Event_PlayerUse, EventHookMode_Post);
    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    RegConsoleCmd("sm_testhud", Cmd_TestHud);
    RegConsoleCmd("sm_upinfo", Cmd_UpInfo);
    RegConsoleCmd("sm_forceup", Cmd_ForceUp);
    AutoExecConfig(true, "l4d2_upgradepack_3clip");
    g_hTimer = CreateTimer(0.3, Timer_Check, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    g_hHudSync = CreateHudSynchronizer();
    CreateTimer(0.5, Timer_HUD, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_DebugLog, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    // 保持定时器跨地图
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
        ResetClient(i);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0) ResetClient(client);
}

void ResetClient(int client)
{
    // 恢复原始备弹显示
    if ((g_iRemaining[client] > 0 || g_iTotalSpecial[client] > 0) && IsClientInGame(client) && g_iAmmoType[client] >= 0)
    {
        int cur = GetPlayerWeaponSlot(client, 0);
        if (cur > 0 && IsValidEdict(cur))
        {
            int at = GetEntProp(cur, Prop_Send, "m_iPrimaryAmmoType");
            if (at == g_iAmmoType[client])
                SetEntProp(client, Prop_Send, "m_iAmmo", g_iOrigReserve[client], _, at);
        }
    }
    g_iRemaining[client] = 0;
    g_iTotalSpecial[client] = 0;
    g_iUpgradeBit[client] = 0;
    g_iClipSize[client] = 0;
    g_iWeaponRef[client] = 0;
    g_bLaser[client] = false;
    g_iOrigReserve[client] = 0;
    g_iAmmoType[client] = -1;
    if (client > 0 && IsClientInGame(client))
        ClearSyncHud(client, g_hHudSync);
}

public void OnClientDisconnect(int client)
{
    ResetClient(client);
}

public void Event_PlayerUse(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;
    int entity = event.GetInt("entity");
    if (entity <= 0 || !IsValidEdict(entity)) return;
    char cls[64];
    GetEdictClassname(entity, cls, sizeof(cls));
    // 只处理升级弹药实体：upgrade_ammo_* 或 weapon_upgradepack_*
    if (StrContains(cls, "upgrade_ammo", false) == -1 && StrContains(cls, "upgradepack", false) == -1)
        return;
    if (StrContains(cls, "laser", false) != -1) return;
    LogMessage("[updbg] player_use client=%d entity=%d cls=%s", client, entity, cls);
    DataPack pack;
    CreateDataTimer(0.15, Timer_Init, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteCell(GetClientUserId(client));
    // 将 cls 转为标准 upgrade_ammo_* 形式供 Timer_Init 判断燃烧/高爆
    char std[64];
    if (StrContains(cls, "incendiary", false) != -1) std = "upgrade_ammo_incendiary";
    else if (StrContains(cls, "explosive", false) != -1) std = "upgrade_ammo_explosive";
    else strcopy(std, sizeof(std), cls);
    pack.WriteString(std);
}
public void Event_UpgradeUsed(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    int upgradeEnt = 0;
    if (StrEqual(name, "upgrade_pack_used")) upgradeEnt = event.GetInt("upgradeid");
    else if (StrEqual(name, "upgrade_pack_added")) upgradeEnt = event.GetInt("upgradeid");
    char cls[64];
    cls[0] = '\0';
    if (upgradeEnt > 0 && IsValidEdict(upgradeEnt))
        GetEdictClassname(upgradeEnt, cls, sizeof(cls));
    else
    {
        // 有些事件的 upgradeid 是实体索引但可能已失效，回退用武器 bit 判断
        cls[0] = '\0';
    }
    LogMessage("[updbg] %s client=%d upgradeEnt=%d cls=%s", name, client, upgradeEnt, cls);
    if (StrContains(cls, "laser", false) != -1)
        return;

    DataPack pack;
    CreateDataTimer(0.1, Timer_Init, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(cls);
}

public Action Timer_Init(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    char cls[64];
    pack.ReadString(cls, sizeof(cls));
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Stop;

    int weapon = GetPlayerWeaponSlot(client, 0);
    if (weapon <= 0 || !IsValidEdict(weapon))
        return Plugin_Stop;

    int bit = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
    if (bit == 0 || bit == 4)
        return Plugin_Stop;

    bool isExplosive = false;
    if (cls[0] != '\0')
        isExplosive = StrEqual(cls, "upgrade_ammo_explosive");
    else
        isExplosive = (bit & 2) != 0;

    float mult = isExplosive ? g_cvExplosive.FloatValue : g_cvIncend.FloatValue;
    int clips = RoundToNearest(mult);
    if (clips < 1) clips = 1;
    if (clips > 10) clips = 10;

    int ammo = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
    if (ammo <= 0) return Plugin_Stop;

    // 初始弹夹已在武器上，记录总数为 clips（包含当前），同时记录精确总数 150
    g_iRemaining[client] = clips;
    g_iTotalSpecial[client] = ammo * clips; // 150
    g_iClipSize[client] = ammo; // 当前 clip 即最大 clip
    g_iUpgradeBit[client] = isExplosive ? 2 : 1;
    g_bLaser[client] = (bit & 4) != 0;
    g_iWeaponRef[client] = EntIndexToEntRef(weapon);
    int at = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
    g_iAmmoType[client] = at;
    g_iOrigReserve[client] = GetEntProp(client, Prop_Send, "m_iAmmo", _, at);
    LogMessage("[updbg] Init client=%d clips=%d ammo=%d total=%d bit=%d at=%d origReserve=%d", client, clips, ammo, g_iTotalSpecial[client], bit, at, g_iOrigReserve[client]);
    PrintToChat(client, "[弹药包] %s %d弹夹已生效 当前%d/%d 备弹%d 总计%d", isExplosive?"高爆":"燃烧", clips, ammo, g_iClipSize[client], (g_iTotalSpecial[client]-ammo), g_iTotalSpecial[client]);
    return Plugin_Stop;
}

public Action Timer_Check(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_iTotalSpecial[client] <= 0 && g_iRemaining[client] <= 0) continue;
        // 总量耗尽后等待换回普通
        if (g_iTotalSpecial[client] <= 0)
        {
            if (!IsClientInGame(client) || !IsPlayerAlive(client)) continue;
            int ref1 = g_iWeaponRef[client];
            if (ref1 == 0) continue;
            int w1 = EntRefToEntIndex(ref1);
            if (w1 == INVALID_ENT_REFERENCE || !IsValidEdict(w1)) continue;
            int cur1 = GetPlayerWeaponSlot(client, 0);
            if (cur1 != w1) continue;
            int ammo1 = GetEntProp(w1, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
            int bit1 = GetEntProp(w1, Prop_Send, "m_upgradeBitVec");
            bool has1 = (bit1 & g_iUpgradeBit[client]) != 0;
            if (ammo1 == 0 && !has1)
                ResetClient(client);
            continue;
        }
        if (!IsClientInGame(client) || !IsPlayerAlive(client)) continue;

        int ref = g_iWeaponRef[client];
        if (ref == 0) continue;
        int weapon = EntRefToEntIndex(ref);
        if (weapon == INVALID_ENT_REFERENCE || !IsValidEdict(weapon))
        {
            // 武器已掉落/更换，尝试用当前主武器重新绑定? 不转移，清除计数
            int cur = GetPlayerWeaponSlot(client, 0);
            if (cur <= 0 || EntIndexToEntRef(cur) != ref)
            {
                // 主武器已换，视为升级结束
                ResetClient(client);
                continue;
            }
            weapon = cur;
        }
        else
        {
            int cur = GetPlayerWeaponSlot(client, 0);
            if (cur != weapon)
            {
                // 切了枪，暂停补充，切回再判断
                continue;
            }
        }

        int ammo = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
        int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
        int bit = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
        bool hasUpgrade = (bit & g_iUpgradeBit[client]) != 0;

        // 换弹完成：弹夹已回满但升级弹不满 -> 补充下一弹夹（精确总量 150）
        if (clip == g_iClipSize[client] && ammo != g_iClipSize[client])
        {
            if (!hasUpgrade || ammo < g_iClipSize[client])
            {
                if (g_iTotalSpecial[client] <= 0)
                {
                    ResetClient(client);
                    continue;
                }
                int newAmmo = g_iTotalSpecial[client] >= g_iClipSize[client] ? g_iClipSize[client] : g_iTotalSpecial[client];
                // 若新弹夹与当前相同则不补（避免抖动）
                if (newAmmo == ammo && hasUpgrade) continue;
                LogMessage("[updbg] Refill client=%d clip=%d ammo=%d->%d bit=%d hasUpgrade=%d total=%d", client, clip, ammo, newAmmo, bit, hasUpgrade, g_iTotalSpecial[client]);
                int newBit = g_iUpgradeBit[client] | (g_bLaser[client] ? 4 : 0);
                int keepLaser = (bit & 4);
                SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", newBit | keepLaser);
                SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", newAmmo);
                // 剩余弹夹数同步
                g_iRemaining[client] = (g_iTotalSpecial[client] + g_iClipSize[client] - 1) / g_iClipSize[client];
                PrintToChat(client, "[弹药包] 补充 %s %d发 总剩余%d", g_iUpgradeBit[client]==2?"高爆":"燃烧", newAmmo, g_iTotalSpecial[client]);
            }
        }
        // 额外兜底：打空后未换弹前 ammo==0 clip==0 hasUpgrade 可能仍为 true，但不补，等换弹后再补
    }
    return Plugin_Continue;
}

public Action Cmd_TestHud(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    SetHudTextParams(0.5, 0.5, 3.0, 255, 0, 0, 255, 0, 0.0, 0.0, 0.0);
    ShowSyncHudText(client, g_hHudSync, "HUD测试 高爆弹 备弹 100发");
    PrintHintText(client, "Hint测试 高爆弹 备弹 100发 (2弹夹) | 当前 50/50");
    PrintCenterText(client, "Center测试 高爆弹");
    PrintToChat(client, "[测试] 已发送三种HUD，请确认哪种可见");
    return Plugin_Handled;
}
public Action Cmd_ForceUp(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    int clips = 3;
    if (args >= 1)
    {
        char buf[16];
        GetCmdArg(1, buf, sizeof(buf));
        clips = StringToInt(buf);
    }
    int weapon = GetPlayerWeaponSlot(client, 0);
    if (weapon <= 0 || !IsValidEdict(weapon))
    {
        PrintToChat(client, "[forceup] 无主武器");
        return Plugin_Handled;
    }
    int bit = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
    if (bit == 0 || bit == 4)
    {
        SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", 2);
        SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", 50);
        bit = 2;
    }
    int ammo = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
    g_iRemaining[client] = clips;
    g_iTotalSpecial[client] = ammo * clips;
    g_iClipSize[client] = ammo > 0 ? ammo : 50;
    g_iUpgradeBit[client] = (bit & 2) ? 2 : 1;
    g_bLaser[client] = (bit & 4) != 0;
    g_iWeaponRef[client] = EntIndexToEntRef(weapon);
    g_iAmmoType[client] = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
    g_iOrigReserve[client] = GetEntProp(client, Prop_Send, "m_iAmmo", _, g_iAmmoType[client]);
    PrintToChat(client, "[forceup] 已强制剩余=%d total=%d clipSize=%d bit=%d", g_iRemaining[client], g_iTotalSpecial[client], g_iClipSize[client], g_iUpgradeBit[client]);
    return Plugin_Handled;
}
public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;
    if (g_iTotalSpecial[client] <= 0) return;
    int ref = g_iWeaponRef[client];
    if (ref == 0) return;
    int weapon = EntRefToEntIndex(ref);
    if (weapon == INVALID_ENT_REFERENCE || !IsValidEdict(weapon)) return;
    int cur = GetPlayerWeaponSlot(client, 0);
    if (cur != weapon) return;
    int bit = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
    if ((bit & g_iUpgradeBit[client]) == 0) return;
    // 每发射一次扣1发特殊弹药（霰弹枪也按1次算，足够精确）
    g_iTotalSpecial[client]--;
    if (g_iTotalSpecial[client] < 0) g_iTotalSpecial[client] = 0;
    // 同步更新剩余弹夹数（用于兼容旧逻辑）
    g_iRemaining[client] = (g_iTotalSpecial[client] + g_iClipSize[client] - 1) / g_iClipSize[client];
    if (g_iRemaining[client] <= 0 && g_iTotalSpecial[client] <= 0)
    {
        // 最后一发打完，下次换弹后会清理
    }
}
public Action Cmd_UpInfo(int client, int args)
{
    if (client <= 0) return Plugin_Handled;
    int idx = client;
    int ref = g_iWeaponRef[idx];
    int weapon = ref ? EntRefToEntIndex(ref) : 0;
    int cur = GetPlayerWeaponSlot(idx, 0);
    int ammo = 0, bit = 0, clip = 0;
    if (weapon > 0 && IsValidEdict(weapon)) { ammo = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"); bit = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec"); clip = GetEntProp(weapon, Prop_Send, "m_iClip1"); }
    int at = g_iAmmoType[idx];
    int reserve = (at >= 0 && IsClientInGame(idx)) ? GetEntProp(idx, Prop_Send, "m_iAmmo", _, at) : -1;
    PrintToChat(client, "[upinfo] 剩余夹=%d total=%d bit=%d clipSize=%d ref=%d cur=%d ammo=%d bitNow=%d clip=%d at=%d reserve=%d orig=%d", g_iRemaining[idx], g_iTotalSpecial[idx], g_iUpgradeBit[idx], g_iClipSize[idx], ref, cur, ammo, bit, clip, at, reserve, g_iOrigReserve[idx]);
    return Plugin_Handled;
}
public Action Timer_DebugLog(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i)) continue;
        if (g_iRemaining[i] > 0)
        {
            int ref = g_iWeaponRef[i];
            int weapon = ref ? EntRefToEntIndex(ref) : 0;
            if (weapon > 0 && IsValidEdict(weapon))
            {
                int ammo = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
                int bit = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
                int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
                LogMessage("[updbg] client=%d remaining=%d clipSize=%d ammo=%d bit=%d clip=%d ref=%d", i, g_iRemaining[i], g_iClipSize[i], ammo, bit, clip, ref);
            }
        }
    }
    return Plugin_Continue;
}
public Action Timer_HUD(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
            continue;
        if (g_iRemaining[client] <= 0)
        {
            // 已在 ResetClient 恢复，这里仅清 HUD
            ClearSyncHud(client, g_hHudSync);
            continue;
        }
        int ref = g_iWeaponRef[client];
        if (ref == 0) { ClearSyncHud(client, g_hHudSync); continue; }
        int weapon = EntRefToEntIndex(ref);
        if (weapon == INVALID_ENT_REFERENCE || !IsValidEdict(weapon)) { ClearSyncHud(client, g_hHudSync); continue; }
        int cur = GetPlayerWeaponSlot(client, 0);
        if (cur != weapon) 
        { 
            // 切走主武器时恢复正常备弹显示
            if (g_iAmmoType[client] >= 0)
                SetEntProp(client, Prop_Send, "m_iAmmo", g_iOrigReserve[client], _, g_iAmmoType[client]);
            ClearSyncHud(client, g_hHudSync); 
            continue; 
        }

        int ammo = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
        int bit = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
        if ((bit & g_iUpgradeBit[client]) == 0 && ammo == 0) 
        { 
            // 升级已耗尽，恢复
            if (g_iAmmoType[client] >= 0)
                SetEntProp(client, Prop_Send, "m_iAmmo", g_iOrigReserve[client], _, g_iAmmoType[client]);
            ClearSyncHud(client, g_hHudSync); 
            continue; 
        }

        // 武器栏备弹 = 总特殊 - 当前特殊弹夹
        int at = g_iAmmoType[client];
        if (at >= 0)
        {
            int reserve = g_iTotalSpecial[client] - ammo;
            if (reserve < 0) reserve = 0;
            // 若总量已耗尽，恢复原始备弹
            if (g_iTotalSpecial[client] <= 0)
                SetEntProp(client, Prop_Send, "m_iAmmo", g_iOrigReserve[client], _, at);
            else
                SetEntProp(client, Prop_Send, "m_iAmmo", reserve, _, at);
        }

        // 可选：右下角同步显示文字（已改为武器栏为主，保留轻量提示可注释）
        // char sName[16];
        // sName = g_iUpgradeBit[client] == 2 ? "高爆弹" : "燃烧弹";
        // SetHudTextParams(0.85, 0.85, 0.6, 255, 120, 0, 255, 0, 0.0, 0.0, 0.0);
        // ShowSyncHudText(client, g_hHudSync, "%s 备弹 %d发 (%d弹夹)", sName, totalReserve, g_iRemaining[client]-1);
    }
    return Plugin_Continue;
}
