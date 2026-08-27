/**
 * [L4D2] Scoreboard UI — 常驻得分榜 (EMS 直写)  v1.3.0
 *
 * 架构 (2026-08-27 极简重构):
 *   本插件直接调 sorall l4d2_ems_hud.inc (EnableHUD + HUDSetLayout/HUDPlace)
 *   社区 100% 常驻榜都用此法 (LinLinLin t=340601 / Gold Fish t=352495)。
 *
 * 槽位: 7 行 Excel 表 (HUD_LEFT_TOP..TICKER)
 *   0: 标题  [得分榜 TOP5] 共4人
 *   1: 表头  #  玩家       积分 特感 击杀 友伤 被黑  (五属性, 显示宽度对齐)
 *   2-6: 数据 #1 Ellis     1372    6    7   45    0 (0.024 紧凑)
 *  数据源: l4d2_score_core SH_ 只读 (积分>特感>击杀 同 !rank 口径)
 *   五属性: 积分(SH_GetRoundScore) 特感(SH_GetSIKills) 击杀(SH_GetCommonKills=小僵) 友伤(SH_GetFFDamage) 被黑(SH_GetBlacked)
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <l4d2_ems_hud>

#define PLUGIN_VERSION      "1.3.5"

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
    g_cvTop.SetBounds(ConVarBound_Upper, true, 5.0);
    g_cvTop.SetBounds(ConVarBound_Lower, true, 1.0);
    // v1.3.2 旧 cvar 上限 3 残留, 热重载需强制扩到 5
    if (g_cvTop.IntValue > 5) g_cvTop.SetInt(5);
    else if (g_cvTop.IntValue < 1) g_cvTop.SetInt(1);
    g_cvInterval  = CreateConVar("sui_interval", "1.0", "刷新间隔秒（修改需重载插件）", _, true, 0.5, true, 10.0);
    g_cvNameLen   = CreateConVar("sui_name_len", "10", "玩家名最大字节数（UTF-8 安全截断）", _, true, 4.0, true, 24.0);

    AutoExecConfig(true, "l4d2_scoreboard_ui");
}

public void OnMapStart()
{
    RemoveAllHUD();
    EnableHUD();
    // 7 行表: 标题 0.02, 表头 0.044, 数据 0.068/0.092/0.116/0.14/0.164, 紧凑 0.024 步进, 高 0.022
    HUDPlace(HUD_LEFT_TOP, 0.02, 0.020, 0.42, 0.022);
    HUDPlace(HUD_LEFT_BOT, 0.02, 0.044, 0.42, 0.022);
    HUDPlace(HUD_MID_TOP,  0.02, 0.068, 0.42, 0.022);
    HUDPlace(HUD_MID_BOT,  0.02, 0.092, 0.42, 0.022);
    HUDPlace(HUD_RIGHT_TOP,0.02, 0.116, 0.42, 0.022);
    HUDPlace(HUD_RIGHT_BOT,0.02, 0.140, 0.42, 0.022);
    HUDPlace(HUD_TICKER,   0.02, 0.164, 0.42, 0.022);
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
        HUDPlace(HUD_LEFT_TOP, 0.02, 0.020, 0.42, 0.022);
        HUDPlace(HUD_LEFT_BOT, 0.02, 0.044, 0.42, 0.022);
        HUDPlace(HUD_MID_TOP,  0.02, 0.068, 0.42, 0.022);
        HUDPlace(HUD_MID_BOT,  0.02, 0.092, 0.42, 0.022);
        HUDPlace(HUD_RIGHT_TOP,0.02, 0.116, 0.42, 0.022);
        HUDPlace(HUD_RIGHT_BOT,0.02, 0.140, 0.42, 0.022);
        HUDPlace(HUD_TICKER,   0.02, 0.164, 0.42, 0.022);
        g_bHudReady = true;
    }
    HUDPlace(HUD_LEFT_TOP, 0.02, 0.020, 0.42, 0.022);
    HUDPlace(HUD_LEFT_BOT, 0.02, 0.044, 0.42, 0.022);
    HUDPlace(HUD_MID_TOP,  0.02, 0.068, 0.42, 0.022);
    HUDPlace(HUD_MID_BOT,  0.02, 0.092, 0.42, 0.022);
    HUDPlace(HUD_RIGHT_TOP,0.02, 0.116, 0.42, 0.022);
    HUDPlace(HUD_RIGHT_BOT,0.02, 0.140, 0.42, 0.022);
    HUDPlace(HUD_TICKER,   0.02, 0.164, 0.42, 0.022);
    for (int s = HUD_SCORE_TITLE; s <= HUD_SCORE_4; s++) RemoveHUD(s);

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

    // 标题 (去排序提示)
    Format(lines[0], 128, "[得分榜 TOP%d] 共%d人", top, count);
    // 表头: 显示宽度对齐, 列宽按用户定: 积分6 特感3(表头4需容纳"特感"故取4) 击杀4 友伤5 被黑5, 玩家10
    {
        char hRank[16], hName[32], hScore[16], hSI[16], hKill[16], hFF[16], hBlk[16];
        PadRight(hRank, sizeof(hRank), "#", 3);
        PadRight(hName, sizeof(hName), "玩家", 10);
        PadLeft(hScore, sizeof(hScore), "积分", 6);
        PadLeft(hSI, sizeof(hSI), "特感", 4);
        PadLeft(hKill, sizeof(hKill), "击杀", 4);
        PadLeft(hFF, sizeof(hFF), "友伤", 5);
        PadLeft(hBlk, sizeof(hBlk), "被黑", 5);
        Format(lines[1], 128, "%s %s %s %s %s %s %s", hRank, hName, hScore, hSI, hKill, hFF, hBlk);
    }

    char name[32];
    int nameMax = g_cvNameLen.IntValue;
    for (int k = 0; k < top; k++)
    {
        int c = clients[k];
        GetClientName(c, name, sizeof(name));
        SanitizeName(name, nameMax);
        // 玩家名按显示宽度截断补齐, 保证 Excel 对齐 (最长 10 显示宽, CJK=2)
        TruncateByDisplayWidth(name, 10);
        char namePad[32], rankPad[16], scorePad[16], siPad[16], killPad[16], ffPad[16], blkPad[16];
        char rankStr[8], scoreStr[16], siStr[16], killStr[16], ffStr[16], blkStr[16];
        Format(rankStr, sizeof(rankStr), "#%d", k+1);
        PadRight(rankPad, sizeof(rankPad), rankStr, 3);
        PadRight(namePad, sizeof(namePad), name, 10);
        int si = SH_GetSIKills(c);
        int kill = SH_GetCommonKills(c);
        int ff = 0, blacked = 0;
        if (GetFeatureStatus(FeatureType_Native, "SH_GetFFDamage") == FeatureStatus_Available)
            ff = SH_GetFFDamage(c);
        if (GetFeatureStatus(FeatureType_Native, "SH_GetBlacked") == FeatureStatus_Available)
            blacked = SH_GetBlacked(c);
        Format(scoreStr, sizeof(scoreStr), "%d", scores[k]);
        Format(siStr, sizeof(siStr), "%d", si);
        Format(killStr, sizeof(killStr), "%d", kill);
        Format(ffStr, sizeof(ffStr), "%d", ff);
        Format(blkStr, sizeof(blkStr), "%d", blacked);
        // 列宽: 积分6 特感3→4 击杀4 友伤5 被黑5 (与表头一致, 钳制超长)
        PadLeft(scorePad, sizeof(scorePad), scoreStr, 6);
        PadLeft(siPad, sizeof(siPad), siStr, 4);
        PadLeft(killPad, sizeof(killPad), killStr, 4);
        PadLeft(ffPad, sizeof(ffPad), ffStr, 5);
        PadLeft(blkPad, sizeof(blkPad), blkStr, 5);
        Format(lines[2+k], 128, "%s %s %s %s %s %s %s", rankPad, namePad, scorePad, siPad, killPad, ffPad, blkPad);
    }
    return 2 + top;
}


int GetDisplayWidth(const char[] s)
{
    int w = 0;
    for (int i = 0; s[i] != '\0'; i++)
    {
        int b = s[i] & 0xFF;
        if (b < 0x80) w += 1;
        else if ((b & 0xE0) == 0xC0) { w += 2; i += 1; }
        else if ((b & 0xF0) == 0xE0) { w += 2; i += 2; }
        else if ((b & 0xF8) == 0xF0) { w += 2; i += 3; }
        else w += 1;
    }
    return w;
}
void PadRight(char[] out, int maxlen, const char[] src, int targetWidth)
{
    int cur = GetDisplayWidth(src);
    strcopy(out, maxlen, src);
    int pad = targetWidth - cur;
    for (int i = 0; i < pad; i++) StrCat(out, maxlen, " ");
}
void PadLeft(char[] out, int maxlen, const char[] src, int targetWidth)
{
    int cur = GetDisplayWidth(src);
    int pad = targetWidth - cur;
    out[0] = '\0';
    for (int i = 0; i < pad; i++) StrCat(out, maxlen, " ");
    StrCat(out, maxlen, src);
}
void TruncateByDisplayWidth(char[] s, int maxWidth)
{
    int w = 0;
    int pos = 0;
    int len = strlen(s);
    for (int i = 0; i < len; )
    {
        int b = s[i] & 0xFF;
        int charLen = 1;
        int cw = 1;
        if (b < 0x80) { charLen = 1; cw = 1; }
        else if ((b & 0xE0) == 0xC0) { charLen = 2; cw = 2; }
        else if ((b & 0xF0) == 0xE0) { charLen = 3; cw = 2; }
        else if ((b & 0xF8) == 0xF0) { charLen = 4; cw = 2; }
        else { charLen = 1; cw = 1; }
        if (w + cw > maxWidth) { s[pos] = '\0'; return; }
        for (int k = 0; k < charLen; k++) s[pos++] = s[i++];
        w += cw;
    }
    s[pos] = '\0';
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
