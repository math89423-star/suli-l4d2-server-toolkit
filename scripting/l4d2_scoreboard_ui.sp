/**
 * [L4D2] Scoreboard UI — 常驻得分榜 (EMS 直写)  v1.3.0
 *
 * 架构 (2026-08-27 极简重构):
 *   本插件直接调 sorall l4d2_ems_hud.inc (EnableHUD + HUDSetLayout/HUDPlace)
 *   社区 100% 常驻榜都用此法 (LinLinLin t=340601 / Gold Fish t=352495)。
 *
 * 槽位: 5 行 Excel 表 (HUD_LEFT_TOP/MID 等通用槽, 非 SCORE 专用 10-13)
 *   0: 标题  [得分榜 TOP3] 共4人
 *   1: 表头  #  玩家       积分 特感 击杀 友伤 被黑  (五属性对齐)
 *   2-4: 数据 #1 Ellis     1372    6    7   45    0
 *  数据源: l4d2_score_core SH_ 只读 (积分>特感>击杀 同 !rank 口径)
 *   五属性: 积分(SH_GetRoundScore) 特感(SH_GetSIKills) 击杀(SH_GetCommonKills=小僵) 友伤(SH_GetFFDamage) 被黑(SH_GetBlacked)
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <l4d2_ems_hud>

#define PLUGIN_VERSION      "1.3.2"

#define SCORE_CORE_FILE     "l4d2_score_core.smx"

public Plugin myinfo = {
    name        = "[L4D2] Scoreboard UI",
    author      = "suli",
    description = "Persistent leaderboard via EMS HUD (Excel table, 5 cols)",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ── 可选绑定：score_core 只读榜单 API（v1.13.7+）──
native int SH_GetRoundScore(int client);
native int SH_GetSIKills(int client);
native int SH_GetCommonKills(int client);
native int SH_GetFFDamage(int client);
native int SH_GetBlacked(int client);

ConVar  g_cvEnable;
ConVar  g_cvTop;
ConVar  g_cvInterval;
ConVar  g_cvNameLen;

bool    g_bCoreAvailable = false;
bool    g_bHudReady = false;
Handle  g_hTimer = null;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("SH_GetRoundScore");
    MarkNativeAsOptional("SH_GetSIKills");
    MarkNativeAsOptional("SH_GetCommonKills");
    MarkNativeAsOptional("SH_GetFFDamage");
    MarkNativeAsOptional("SH_GetBlacked");
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("sui_version", PLUGIN_VERSION, "Plugin Version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_cvEnable    = CreateConVar("sui_enable", "1", "常驻得分榜总开关 [0=关|1=开]", _, true, 0.0, true, 1.0);
    g_cvTop       = CreateConVar("sui_top", "5", "显示前 N 名 [1-5]（标题+表头+5行）", _, true, 1.0, true, 5.0);
    g_cvInterval  = CreateConVar("sui_interval", "1.0", "刷新间隔秒（修改需重载插件）", _, true, 0.5, true, 10.0);
    g_cvNameLen   = CreateConVar("sui_name_len", "10", "玩家名最大字节数（UTF-8 安全截断）", _, true, 4.0, true, 24.0);

    AutoExecConfig(true, "l4d2_scoreboard_ui");
}

public void OnMapStart()
{
    RemoveAllHUD();
    EnableHUD();
    // 7 行表: 标题 0.02, 表头 0.05, 数据 0.08/0.11/0.14/0.17/0.20, 宽 0.40
    HUDPlace(HUD_LEFT_TOP, 0.02, 0.02, 0.40, 0.025);
    HUDPlace(HUD_LEFT_BOT, 0.02, 0.05, 0.40, 0.025);
    HUDPlace(HUD_MID_TOP,  0.02, 0.08, 0.40, 0.025);
    HUDPlace(HUD_MID_BOT,  0.02, 0.11, 0.40, 0.025);
    HUDPlace(HUD_RIGHT_TOP,0.02, 0.14, 0.40, 0.025);
    HUDPlace(HUD_RIGHT_BOT,0.02, 0.17, 0.40, 0.025);
    HUDPlace(HUD_TICKER,   0.02, 0.20, 0.40, 0.025);
    g_bHudReady = true;

    if (g_hTimer == null)
        g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Refresh, _, TIMER_REPEAT);
}

public void OnMapEnd()
{
    RemoveAllHUD();
    g_bHudReady = false;
    if (g_hTimer != null)
    {
        KillTimer(g_hTimer);
        g_hTimer = null;
    }
}

public void OnConfigsExecuted()
{
    if (g_hTimer == null)
        g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Refresh, _, TIMER_REPEAT);
}

// ── 主刷新循环 ──────────────────────────────────────────────
public Action Timer_Refresh(Handle timer)
{
    if (!g_bHudReady)
    {
        RemoveAllHUD();
        EnableHUD();
        HUDPlace(HUD_LEFT_TOP, 0.02, 0.02, 0.40, 0.025);
        HUDPlace(HUD_LEFT_BOT, 0.02, 0.05, 0.40, 0.025);
        HUDPlace(HUD_MID_TOP,  0.02, 0.08, 0.40, 0.025);
        HUDPlace(HUD_MID_BOT,  0.02, 0.11, 0.40, 0.025);
        HUDPlace(HUD_RIGHT_TOP,0.02, 0.14, 0.40, 0.025);
        HUDPlace(HUD_RIGHT_BOT,0.02, 0.17, 0.40, 0.025);
        HUDPlace(HUD_TICKER,   0.02, 0.20, 0.40, 0.025);
        g_bHudReady = true;
    }
    HUDPlace(HUD_LEFT_TOP, 0.02, 0.02, 0.40, 0.025);
    HUDPlace(HUD_LEFT_BOT, 0.02, 0.05, 0.40, 0.025);
    HUDPlace(HUD_MID_TOP,  0.02, 0.08, 0.40, 0.025);
    HUDPlace(HUD_MID_BOT,  0.02, 0.11, 0.40, 0.025);
    HUDPlace(HUD_RIGHT_TOP,0.02, 0.14, 0.40, 0.025);
    HUDPlace(HUD_RIGHT_BOT,0.02, 0.17, 0.40, 0.025);
    HUDPlace(HUD_TICKER,   0.02, 0.20, 0.40, 0.025);
    for (int s = HUD_SCORE_TITLE; s <= HUD_SCORE_4; s++) RemoveHUD(s);
    // 旧 LEFT/MID 以外残留也清 (5槽外)
    RemoveHUD(HUD_RIGHT_BOT);
    RemoveHUD(HUD_TICKER);

    char lines[7][128];
    int lineCount = BuildLeaderboard(lines);

    if (!g_cvEnable.BoolValue)
    {
        RemoveAllHUD();
        return Plugin_Continue;
    }

    if (lineCount == 1 && (StrContains(lines[0], "未加载") != -1 || StrContains(lines[0], "暂无数据") != -1))
    {
        int flags = HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_LEFT;
        HUDSetLayout(HUD_LEFT_TOP, flags, lines[0]);
        RemoveHUD(HUD_LEFT_BOT);
        RemoveHUD(HUD_MID_TOP);
        RemoveHUD(HUD_MID_BOT);
        RemoveHUD(HUD_RIGHT_TOP);
        RemoveHUD(HUD_RIGHT_BOT);
        RemoveHUD(HUD_TICKER);
        return Plugin_Continue;
    }

    int flags = HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_LEFT;
    int slots[7] = {HUD_LEFT_TOP, HUD_LEFT_BOT, HUD_MID_TOP, HUD_MID_BOT, HUD_RIGHT_TOP, HUD_RIGHT_BOT, HUD_TICKER};
    for (int i = 0; i < 7; i++)
    {
        int slot = slots[i];
        if (i < lineCount)
            HUDSetLayout(slot, flags, lines[i]);
        else
            RemoveHUD(slot);
    }
    return Plugin_Continue;
}

// 组装 7 行 Excel 表 (标题+表头+TOP5)，返回行数
int BuildLeaderboard(char lines[7][128])
{
    if (!g_bCoreAvailable)
    {
        g_bCoreAvailable = (GetFeatureStatus(FeatureType_Native, "SH_GetRoundScore") == FeatureStatus_Available
            && FindPluginByFile(SCORE_CORE_FILE) != INVALID_HANDLE);
        if (!g_bCoreAvailable)
        {
            strcopy(lines[0], 128, "[得分榜] score_core 未加载");
            return 1;
        }
    }

    int count = 0;
    int clients[MAXPLAYERS + 1];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2)
            clients[count++] = i;
    }
    if (count == 0)
    {
        strcopy(lines[0], 128, "[得分榜] 暂无数据");
        return 1;
    }

    int scores[MAXPLAYERS + 1];
    for (int k = 0; k < count; k++)
        scores[k] = SH_GetRoundScore(clients[k]);

    for (int i = 1; i < count; i++)
    {
        int ks = scores[i], kc = clients[i];
        int kSI = SH_GetSIKills(kc);
        int kKill = SH_GetSIKills(kc) + SH_GetCommonKills(kc);
        int j = i - 1;
        while (j >= 0)
        {
            int sj = scores[j];
            int sSI = SH_GetSIKills(clients[j]);
            int sKill = SH_GetSIKills(clients[j]) + SH_GetCommonKills(clients[j]);
            bool less = (sj < ks)
                || (sj == ks && sSI < kSI)
                || (sj == ks && sSI == kSI && sKill < kKill);
            if (!less) break;
            scores[j+1] = scores[j];
            clients[j+1] = clients[j];
            j--;
        }
        scores[j+1] = ks;
        clients[j+1] = kc;
    }

    int top = g_cvTop.IntValue;
    if (top > count) top = count;
    if (top > 5) top = 5;

    // 标题 (去排序提示) + 表头
    Format(lines[0], 128, "[得分榜 TOP%d] 共%d人", top, count);
    Format(lines[1], 128, "%-3s %-10s %5s %4s %4s %5s %4s", "#", "玩家", "积分", "特感", "击杀", "友伤", "被黑");

    char name[32];
    char nameFixed[32];
    int nameMax = g_cvNameLen.IntValue;
    for (int k = 0; k < top; k++)
    {
        int c = clients[k];
        GetClientName(c, name, sizeof(name));
        SanitizeName(name, nameMax);
        // 名字左对齐 10 宽, 不足补空格
        Format(nameFixed, sizeof(nameFixed), "%-10s", name);
        int si = SH_GetSIKills(c);
        int kill = SH_GetCommonKills(c);
        int ff = 0, blacked = 0;
        if (GetFeatureStatus(FeatureType_Native, "SH_GetFFDamage") == FeatureStatus_Available)
            ff = SH_GetFFDamage(c);
        if (GetFeatureStatus(FeatureType_Native, "SH_GetBlacked") == FeatureStatus_Available)
            blacked = SH_GetBlacked(c);
        // 数据行右对齐, 与表头同宽
        Format(lines[2+k], 128, "#%-2d %-10s %5d %4d %4d %5d %4d", k+1, nameFixed, scores[k], si, kill, ff, blacked);
    }
    return 2 + top;
}

void SanitizeName(char[] name, int maxBytes)
{
    int len = strlen(name);
    for (int i = 0; i < len; i++)
    {
        if (name[i] < 0x20 || name[i] == '"' || name[i] == '\\')
            name[i] = '?';
    }
    if (len <= maxBytes)
        return;
    int cut = maxBytes;
    while (cut > 0 && (name[cut] & 0xC0) == 0x80)
        cut--;
    name[cut] = '\0';
}
