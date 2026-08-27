/**
 * [L4D2] Scoreboard UI — 常驻得分榜 (EMS 直写)  v1.2.0
 *
 * 架构 (2026-08-27 极简重构):
 *   本插件直接调 sorall l4d2_ems_hud.inc (EnableHUD + HUDSetLayout/HUDPlace)
 *   不再依赖 Marttt l4d2_scripted_hud 中转 (4 cvar 喂食已废弃)。
 *   社区 100% 常驻榜都用此法 (LinLinLin t=340601 / Gold Fish t=352495)。
 *
 * 槽位: HUD_LEFT_TOP(0)=标题, LEFT_BOT(1)=#1, MID_TOP(2)=#2, MID_BOT(3)=#3
 *   用通用左侧槽 (非 SCORE 专用 10-13, SCORE 槽受计分板布局影响 y 会漂), 纯文本 127 字符/槽, NOBG 左对齐。
 *   位置 0.02,0.02 起纵向 0.03 步进, 紧凑贴左上 (图1实测 0.04 步进仍散到中屏, 改 0.03 并每帧重申 Place)。
 *
 * 数据源: l4d2_score_core SH_GetRoundScore/SIKills/CommonKills 只读 native
 *   三级排序 积分>特感>击杀 同 !rank 口径, 可选绑定 score_core 未加载时空转。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <l4d2_ems_hud>

#define PLUGIN_VERSION      "1.2.2"

#define SCORE_CORE_FILE     "l4d2_score_core.smx"

public Plugin myinfo = {
    name        = "[L4D2] Scoreboard UI",
    author      = "suli",
    description = "Persistent leaderboard via EMS HUD (direct, no scripted_hud middleman)",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ── 可选绑定：score_core 只读榜单 API（v1.13.7+）──
native int SH_GetRoundScore(int client);
native int SH_GetSIKills(int client);
native int SH_GetCommonKills(int client);

ConVar  g_cvEnable;
ConVar  g_cvTop;        // 名次行数，实际 = min(top, 3)
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
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("sui_version", PLUGIN_VERSION, "Plugin Version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_cvEnable    = CreateConVar("sui_enable", "1", "常驻得分榜总开关 [0=关|1=开]", _, true, 0.0, true, 1.0);
    g_cvTop       = CreateConVar("sui_top", "3", "显示前 N 名 [1-3]（标题+3行名次）", _, true, 1.0, true, 3.0);
    g_cvInterval  = CreateConVar("sui_interval", "1.0", "刷新间隔秒（修改需重载插件）", _, true, 0.5, true, 10.0);
    g_cvNameLen   = CreateConVar("sui_name_len", "10", "玩家名最大字节数（UTF-8 安全截断）", _, true, 4.0, true, 24.0);

    AutoExecConfig(true, "l4d2_scoreboard_ui");
}

public void OnMapStart()
{
    // EMS 启用 + 槽位定位 (左上四槽, 紧凑 0.03 步进, 用 LEFT/MID 通用槽而非 SCORE 专用槽——SCORE 槽受计分板布局管理器影响 y 会漂到中屏)
    RemoveAllHUD(); // 清旧 SCORE 10-14 残留 (v1.2.0 切槽后双榜)
    EnableHUD();
    HUDPlace(HUD_LEFT_TOP, 0.02, 0.02, 0.30, 0.03);
    HUDPlace(HUD_LEFT_BOT, 0.02, 0.05, 0.30, 0.03);
    HUDPlace(HUD_MID_TOP,  0.02, 0.08, 0.30, 0.03);
    HUDPlace(HUD_MID_BOT,  0.02, 0.11, 0.30, 0.03);
    g_bHudReady = true;

    // late load / 热重载后 timer 需重建 (OnConfigsExecuted 不一定再调)
    if (g_hTimer == null)
        g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Refresh, _, TIMER_REPEAT);
}

public void OnMapEnd()
{
    // 清理残留 (换图隐藏)
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
    // late load 补一次 EnableHUD+Place (OnMapStart 已过时)
    if (!g_bHudReady)
    {
        RemoveAllHUD(); // 热重载清旧 SCORE 残留
        EnableHUD();
        HUDPlace(HUD_LEFT_TOP, 0.02, 0.02, 0.30, 0.03);
        HUDPlace(HUD_LEFT_BOT, 0.02, 0.05, 0.30, 0.03);
        HUDPlace(HUD_MID_TOP,  0.02, 0.08, 0.30, 0.03);
        HUDPlace(HUD_MID_BOT,  0.02, 0.11, 0.30, 0.03);
        g_bHudReady = true;
    }
    // 每轮重申 Place (社区证实: HUDSetLayout 后位置可能被重置, 需每帧同设)
    HUDPlace(HUD_LEFT_TOP, 0.02, 0.02, 0.30, 0.03);
    HUDPlace(HUD_LEFT_BOT, 0.02, 0.05, 0.30, 0.03);
    HUDPlace(HUD_MID_TOP,  0.02, 0.08, 0.30, 0.03);
    HUDPlace(HUD_MID_BOT,  0.02, 0.11, 0.30, 0.03);
    // 旧 SCORE 槽 10-14 若残留则清掉 (双榜根因)
    for (int s = HUD_SCORE_TITLE; s <= HUD_SCORE_4; s++) RemoveHUD(s);

    char lines[4][96];
    int lineCount = BuildLeaderboard(lines);

    if (!g_cvEnable.BoolValue)
    {
        RemoveAllHUD();
        return Plugin_Continue;
    }

    // 无数据 / 未加载时标题显示提示，其余槽隐藏
    if (lineCount == 1 && (StrContains(lines[0], "未加载") != -1 || StrContains(lines[0], "暂无数据") != -1))
    {
        int flags = HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_LEFT;
        HUDSetLayout(HUD_LEFT_TOP, flags, lines[0]);
        RemoveHUD(HUD_LEFT_BOT);
        RemoveHUD(HUD_MID_TOP);
        RemoveHUD(HUD_MID_BOT);
        return Plugin_Continue;
    }

    int flags = HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_LEFT;
    int slots[4] = {HUD_LEFT_TOP, HUD_LEFT_BOT, HUD_MID_TOP, HUD_MID_BOT};
    for (int i = 0; i < 4; i++)
    {
        int slot = slots[i];
        if (i < lineCount)
            HUDSetLayout(slot, flags, lines[i]);
        else
            RemoveHUD(slot);
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
