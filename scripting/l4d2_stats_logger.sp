/**
 * l4d2_stats_logger — L4D2 玩家表现统计持久化插件
 *
 * 目标: 为 QQ bot 管理工具 (MCP) 提供"玩家表现评价"的数据底座。
 * 按 SteamID 聚合以下指标并持久化到 data/l4d2_player_stats.txt:
 *
 *   si_kills        击杀特感数 (infected_death / player_death, 仅特感/Witch/Tank)
 *   deaths          幸存者死亡次数
 *   ff_damage       造成友伤总量 (player_hurt, 幸存者→幸存者)
 *   blacked         被队友击杀次数 (被黑)
 *   controlled      被特感控次数 (tongue_grab / lunge_pounce / jockey_ride /
 *                   charger_carry_start / charger_pummel_start)
 *   rescues         救援次数 (revive_success, 非电击)
 *   score           本关积分 (排行榜口径, OnMapEnd 清零)
 *   spent           商店消费总额 (读 l4d2_shop 日志不可靠 → 用事件口径:
 *                   不采集, 由 admin-panel 解析 [shop-buy] 日志)
 *
 * 持久化策略 (与 si_hud_scores.txt 同模式):
 *   - 每 60 秒 Timer_ScoreSave → SaveAll()
 *   - 断线 OnClientDisconnect → SavePlayer()
 *   - 插件卸载 OnPluginEnd → SaveAll()
 *   - 换图 OnMapEnd → score 清零, 其余保留
 *
 * 兼容: 独立插件, 不依赖 si_hud / left4dhooks / shop, 只 hook 原生事件。
 * 编译: spcomp l4d2_stats_logger.sp -ocompiled/l4d2_stats_logger.smx
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"

char g_sSavePath[PLATFORM_MAX_PATH];

// ── per-client 统计 (1=生还者 玩家; bot 不统计) ──
int  g_iSIKills[MAXPLAYERS + 1];
int  g_iDeaths[MAXPLAYERS + 1];
int  g_iFFDamage[MAXPLAYERS + 1];
int  g_iBlacked[MAXPLAYERS + 1];
int  g_iControlled[MAXPLAYERS + 1];
int  g_iRescues[MAXPLAYERS + 1];
int  g_iScore[MAXPLAYERS + 1];

// ── 存档快照 (团灭回滚不用, 只做 OnMapEnd 后 score 归零的保护) ──

public Plugin myinfo =
{
    name        = "L4D2 Stats Logger",
    author      = "suli",
    description = "按 SteamID 持久化玩家表现统计 (击杀/死亡/友伤/被黑/被控/救援)",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    BuildPath(Path_SM, g_sSavePath, sizeof(g_sSavePath), "data/l4d2_player_stats.txt");

    HookEvent("player_death",       Event_PlayerDeath);
    HookEvent("player_hurt",        Event_PlayerHurt);
    HookEvent("infected_death",     Event_InfectedDeath);
    HookEvent("tongue_grab",        Event_TongueGrab);
    HookEvent("lunge_pounce",       Event_LungePounce);
    HookEvent("jockey_ride",        Event_JockeyRide);
    HookEvent("charger_carry_start", Event_ChargerCarryStart);
    HookEvent("charger_pummel_start", Event_ChargerPummelStart);
    HookEvent("revive_success",     Event_ReviveSuccess);
    HookEvent("round_end",          Event_RoundEnd);

    // 每 60 秒全员存档 (与 si_hud 同模式)
    CreateTimer(60.0, Timer_SaveAll, INVALID_HANDLE, TIMER_REPEAT);

    // 启动时加载存档 (内存恢复)
    LoadAll();

    // 命令: sm_stats 给玩家看自己的统计 (仅在线)
    RegConsoleCmd("sm_stats", Cmd_Stats, "Show your stats");
    // 管理命令: sm_stats2 <名字> 查任意玩家统计 (admin)
    RegAdminCmd("sm_stats2", Cmd_Stats2, ADMFLAG_GENERIC, "Show stats of a player");

    AutoExecConfig(true, "l4d2_stats_logger");

    LogMessage("[StatsLogger] v%s loaded — events hooked, timer started", PLUGIN_VERSION);
}

// ═══════════════════════════════════════════════════════════
// 事件采集
// ═══════════════════════════════════════════════════════════

// 幸存者死亡: deaths + 被黑 (attacker 是队友)
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    // 只统计幸存者玩家死亡 (team 2, 非 bot)
    if (!IsSurvivorPlayer(victim))
        return Plugin_Continue;

    g_iDeaths[victim]++;

    // 被黑: 被队友击杀 (attacker 也是幸存者玩家, 且非自己)
    if (attacker >= 1 && attacker <= MaxClients
        && attacker != victim
        && IsClientInGame(attacker)
        && !IsFakeClient(attacker)
        && GetClientTeam(attacker) == 2)
    {
        g_iBlacked[victim]++;
    }

    return Plugin_Continue;
}

// 友伤: 幸存者→幸存者伤害累计 (口径与 si_hud g_iFFDamage 一致)
public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim   = GetClientOfUserId(event.GetInt("userid"));

    if (attacker >= 1 && attacker <= MaxClients
        && attacker != victim
        && IsClientInGame(attacker)
        && !IsFakeClient(attacker)
        && GetClientTeam(attacker) == 2
        && IsSurvivorPlayer(victim))
    {
        int dmg = event.GetInt("dmg_health");
        if (dmg > 0)
            g_iFFDamage[attacker] += dmg;
    }

    return Plugin_Continue;
}

// 特感击杀: infected_death (Witch/Tank/特感), 玩家击杀者
public Action Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (IsSurvivorPlayer(attacker))
        g_iSIKills[attacker]++;

    return Plugin_Continue;
}

// ── 被特感控 (5 种控制事件) ──
public Action Event_TongueGrab(Event event, const char[] name, bool dontBroadcast)
{
    CountControlled(event);
    return Plugin_Continue;
}

public Action Event_LungePounce(Event event, const char[] name, bool dontBroadcast)
{
    CountControlled(event);
    return Plugin_Continue;
}

public Action Event_JockeyRide(Event event, const char[] name, bool dontBroadcast)
{
    CountControlled(event);
    return Plugin_Continue;
}

public Action Event_ChargerCarryStart(Event event, const char[] name, bool dontBroadcast)
{
    CountControlled(event);
    return Plugin_Continue;
}

public Action Event_ChargerPummelStart(Event event, const char[] name, bool dontBroadcast)
{
    CountControlled(event);
    return Plugin_Continue;
}

void CountControlled(Event event)
{
    // 这些事件的 victim 是被控的幸存者
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (IsSurvivorPlayer(victim))
        g_iControlled[victim]++;
}

// 救援: revive_success (拉人/电击统一走此事件)
// 实测: 救人者字段是 "userid"（不是 "reviver"，后者恒为 0）；被救者是 "subject"
public Action Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    // 实测: revive_success 的救人者字段是 "userid"，不是 "reviver"（恒为 0）
    int reviver = GetClientOfUserId(event.GetInt("userid"));
    if (IsSurvivorPlayer(reviver))
        g_iRescues[reviver]++;

    return Plugin_Continue;
}

// round_end: 本关积分清空 (与 si_hud 口径一致: 排行榜每关清零)
public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
        g_iScore[i] = 0;
    return Plugin_Continue;
}

// ═══════════════════════════════════════════════════════════
// 辅助
// ═══════════════════════════════════════════════════════════

bool IsSurvivorPlayer(int client)
{
    return (client >= 1 && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && GetClientTeam(client) == 2);
}

bool GetSteamID(int client, char[] buf, int len)
{
    return GetClientAuthId(client, AuthId_Steam2, buf, len, false);
}

// ═══════════════════════════════════════════════════════════
// 持久化 (KeyValues, 与 si_hud_scores.txt 同风格)
// ═══════════════════════════════════════════════════════════

void SavePlayer(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    char auth[32];
    if (!GetSteamID(client, auth, sizeof(auth)))
        return;

    KeyValues kv = new KeyValues("l4d2_player_stats");
    if (FileExists(g_sSavePath))
        kv.ImportFromFile(g_sSavePath);

    kv.JumpToKey(auth, true);
    kv.SetNum("si_kills",    g_iSIKills[client]);
    kv.SetNum("deaths",      g_iDeaths[client]);
    kv.SetNum("ff_damage",   g_iFFDamage[client]);
    kv.SetNum("blacked",     g_iBlacked[client]);
    kv.SetNum("controlled",  g_iControlled[client]);
    kv.SetNum("rescues",     g_iRescues[client]);
    kv.SetNum("score",       g_iScore[client]);
    kv.Rewind();
    kv.ExportToFile(g_sSavePath);
    delete kv;
}

void SaveAll()
{
    for (int i = 1; i <= MaxClients; i++)
        SavePlayer(i);
}

void LoadAll()
{
    if (!FileExists(g_sSavePath))
        return;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (i > MaxClients || !IsClientInGame(i) || IsFakeClient(i))
            continue;

        char auth[32];
        if (!GetSteamID(i, auth, sizeof(auth)))
            continue;

        KeyValues kv = new KeyValues("l4d2_player_stats");
        if (!kv.ImportFromFile(g_sSavePath))
        {
            delete kv;
            return;
        }

        if (kv.JumpToKey(auth))
        {
            g_iSIKills[i]   = kv.GetNum("si_kills", 0);
            g_iDeaths[i]    = kv.GetNum("deaths", 0);
            g_iFFDamage[i]  = kv.GetNum("ff_damage", 0);
            g_iBlacked[i]   = kv.GetNum("blacked", 0);
            g_iControlled[i] = kv.GetNum("controlled", 0);
            g_iRescues[i]   = kv.GetNum("rescues", 0);
            g_iScore[i]     = kv.GetNum("score", 0);
        }
        delete kv;
    }
}

public Action Timer_SaveAll(Handle timer)
{
    SaveAll();
    return Plugin_Continue;
}

public void OnClientDisconnect(int client)
{
    SavePlayer(client);
}

public void OnPluginEnd()
{
    SaveAll();
}

public void OnMapEnd()
{
    // score 清零前先存档一次 (防旧值丢失)
    SaveAll();
    for (int i = 1; i <= MaxClients; i++)
        g_iScore[i] = 0;
}

// ═══════════════════════════════════════════════════════════
// 命令
// ═══════════════════════════════════════════════════════════

public Action Cmd_Stats(int client, int args)
{
    if (client < 1 || !IsClientInGame(client))
        return Plugin_Handled;

    PrintStatsTo(client, client);
    return Plugin_Handled;
}

public Action Cmd_Stats2(int client, int args)
{
    if (args < 1)
    {
        if (client > 0)
            ReplyToCommand(client, "[Stats] 用法: sm_stats2 <玩家名或SteamID>");
        return Plugin_Handled;
    }

    char target[64];
    GetCmdArg(1, target, sizeof(target));

    // 先按 SteamID 匹配
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsSurvivorPlayer(i))
            continue;
        char auth[32];
        if (GetSteamID(i, auth, sizeof(auth)) && StrEqual(auth, target))
        {
            PrintStatsTo(client, i);
            return Plugin_Handled;
        }
    }

    // 再按名字匹配
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsSurvivorPlayer(i))
            continue;
        char name[64];
        GetClientName(i, name, sizeof(name));
        if (StrContains(name, target, false) != -1)
        {
            PrintStatsTo(client, i);
            return Plugin_Handled;
        }
    }

    ReplyToCommand(client, "[Stats] 未找到玩家: %s", target);
    return Plugin_Handled;
}

void PrintStatsTo(int client, int target)
{
    char name[64];
    GetClientName(target, name, sizeof(name));
    ReplyToCommand(client,
        "[Stats] %s: SI击杀=%d 死亡=%d 友伤=%d 被黑=%d 被控=%d 救援=%d 本关分=%d",
        name, g_iSIKills[target], g_iDeaths[target], g_iFFDamage[target],
        g_iBlacked[target], g_iControlled[target], g_iRescues[target], g_iScore[target]);
}
