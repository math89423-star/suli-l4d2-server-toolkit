/**
 * [L4D2] Scoreboard UI — 常驻得分榜数据源（scripted_hud 喂食器） v1.1.0
 *
 * 架构（2026-08-26 定稿，用户拍板"先用别人的插件再慢慢改"）：
 *   渲染层 = Marttt [L4D2] Scripted HUD v1.0.2（原版插件，0.1s 全量重写 4 槽，
 *            实测无黑框/无残留/无闪烁——本服已验证）
 *   数据层 = 本插件：每秒把 score_core 榜单写进 scripted_hud 的 4 个文本 cvar。
 *
 * 槽位分配（4 槽上限，标题+TOP3）：
 *   HUD1 = "[得分榜 TOPn] 共N人"
 *   HUD2 = "#1 名字 分/特x/杀x"   （三级排序 积分>特感>击杀，同 !rank 口径）
 *   HUD3 = "#2 ..."
 *   HUD4 = "#3 ..."
 *
 * ⚠ 必须占满全部 4 个 text cvar：scripted_hud 对空 cvar 会启用预定义内容
 *   （HUD2=幸存者血量/HUD3=Tank 血量），留空就会串台。
 *
 * 数据源：l4d2_score_core SH_GetRoundScore/SIKills/CommonKills 只读 native
 * （可选绑定，score_core 未加载时本插件空转）。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION      "1.1.0"

#define SCORE_CORE_FILE     "l4d2_score_core.smx"

public Plugin myinfo = {
    name        = "[L4D2] Scoreboard UI",
    author      = "suli",
    description = "Leaderboard data feeder -> l4d2_scripted_hud cvars (data from l4d2_score_core)",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ── 可选绑定：score_core 只读榜单 API（v1.13.7+）──
native int SH_GetRoundScore(int client);
native int SH_GetSIKills(int client);
native int SH_GetCommonKills(int client);

ConVar  g_cvEnable;
ConVar  g_cvTop;        // 名次行数（受 4 槽限制，实际 = min(top, 3)）
ConVar  g_cvInterval;
ConVar  g_cvNameLen;

bool    g_bCoreAvailable = false;
bool    g_bHudAvailable = false;
Handle  g_hTimer = null;
ConVar  g_hHudText[4];          // l4d2_scripted_hud_hud1..4_text

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("SH_GetRoundScore");
    MarkNativeAsOptional("SH_GetSIKills");
    MarkNativeAsOptional("SH_GetCommonKills");
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("sui_version", PLUGIN_VERSION, "Plugin Version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_cvEnable    = CreateConVar("sui_enable", "1", "常驻得分榜总开关 [0=关|1=开]", _, true, 0.0, true, 1.0);
    g_cvTop       = CreateConVar("sui_top", "3", "显示前 N 名 [1-3]（4 槽 = 标题 + 3 行名次）", _, true, 1.0, true, 3.0);
    g_cvInterval  = CreateConVar("sui_interval", "1.0", "刷新间隔秒（修改需重载插件）", _, true, 0.5, true, 10.0);
    g_cvNameLen   = CreateConVar("sui_name_len", "10", "玩家名最大字节数（UTF-8 安全截断）", _, true, 4.0, true, 24.0);
}

public void OnConfigsExecuted()
{
    if (g_hTimer == null)
        g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Refresh, _, TIMER_REPEAT);
}

// ── 主刷新循环 ──────────────────────────────────────────────
public Action Timer_Refresh(Handle timer)
{
    // 渲染器/数据源可用性探测（热重载后自动接通）
    g_bHudAvailable = false;
    char cname[64];
    for (int i = 0; i < 4; i++)
    {
        Format(cname, sizeof(cname), "l4d2_scripted_hud_hud%d_text", i+1);
        g_hHudText[i] = FindConVar(cname);
        if (g_hHudText[i] == null)
        {
            g_bHudAvailable = false;
            break;
        }
        g_bHudAvailable = true;
    }

    char lines[4][96];
    int lineCount = BuildLeaderboard(lines);

    if (!g_cvEnable.BoolValue || !g_bHudAvailable)
    {
        // 关闭时清空渲染器文本（防残留；注意不能置 ""——会触发预定义串台，
        // 写一个空格占位）
        for (int i = 0; i < 4; i++)
            if (g_hHudText[i] != null)
                g_hHudText[i].SetString("-");
        return Plugin_Continue;
    }

    for (int i = 0; i < 4; i++)
    {
        if (i < lineCount)
            g_hHudText[i].SetString(lines[i]);
        else
            g_hHudText[i].SetString("-");   // 占位防预定义串台
    }
    return Plugin_Continue;
}

// 组装 4 行榜单，返回行数
int BuildLeaderboard(char lines[4][96])
{
    if (!g_bCoreAvailable)
    {
        g_bCoreAvailable = (GetFeatureStatus(FeatureType_Native, "SH_GetRoundScore") == FeatureStatus_Available
            && FindPluginByFile(SCORE_CORE_FILE) != INVALID_HANDLE);
        if (!g_bCoreAvailable)
        {
            strcopy(lines[0], 96, "[得分榜] score_core 未加载");
            return 1;
        }
    }

    // 收集幸存者队伍（与 score_core 口径一致：team==2 在游戏内即可）
    int count = 0;
    int clients[MAXPLAYERS + 1];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2)
            clients[count++] = i;
    }
    if (count == 0)
    {
        strcopy(lines[0], 96, "[得分榜] 暂无数据");
        return 1;
    }

    // 三级排序（降序）：积分 > 特感击杀 > 总击杀 —— 同 !rank 口径
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
    if (top > 3) top = 3;

    Format(lines[0], 96, "[得分榜 TOP%d] 共%d人", top, count);
    char name[32];
    int nameMax = g_cvNameLen.IntValue;
    for (int k = 0; k < top; k++)
    {
        int c = clients[k];
        GetClientName(c, name, sizeof(name));
        SanitizeName(name, nameMax);
        int si = SH_GetSIKills(c);
        int kill = si + SH_GetCommonKills(c);
        Format(lines[k+1], 96, "#%d %s %d分/特%d/杀%d", k+1, name, scores[k], si, kill);
    }
    return top + 1;
}

// 名字清洗：控制字符/引号/反斜杠 → '?'；UTF-8 安全按字节截断（不切半个汉字）
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
