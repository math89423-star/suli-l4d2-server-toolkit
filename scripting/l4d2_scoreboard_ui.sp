/**
 * [L4D2] Scoreboard UI — 常驻得分榜 (EMS 列地理化)  v1.4.0
 *
 * 架构: 1 列 1 槽 + \n 行, X 用 HUDPlace 定死, 不靠空格对齐
 *   纯服务端最佳 (比例字体空格永远飘, 社区无表均避多列)
 *   7 列: #/玩家/积分/特感/击杀/友伤/被黑 -> 7 槽 0-6 + 标题 10
 *   每列一个 127 串: "头\n#1\n#2..." , 列内对齐用 HUD_FLAG_ALIGN_*
 *   数据源: SH_ 只读, 截断按显示宽度(CJK=2), 五属性 6/4/4/5/5(积分6) + 玩家12
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <l4d2_ems_hud>

#define PLUGIN_VERSION      "1.4.0"

#define SCORE_CORE_FILE     "l4d2_score_core.smx"

// 列槽位 (0-6 通用) + 标题 10
#define COL_RANK   HUD_LEFT_TOP
#define COL_NAME   HUD_LEFT_BOT
#define COL_SCORE  HUD_MID_TOP
#define COL_SI     HUD_MID_BOT
#define COL_KILL   HUD_RIGHT_TOP
#define COL_FF     HUD_RIGHT_BOT
#define COL_BLK    HUD_TICKER
#define COL_TITLE  HUD_SCORE_TITLE

public Plugin myinfo = {
    name        = "[L4D2] Scoreboard UI",
    author      = "suli",
    description = "Persistent leaderboard via EMS HUD (geographic columns, no VPK)",
    version     = PLUGIN_VERSION,
    url         = ""
};

native int SH_GetRoundScore(int client);
native int SH_GetSIKills(int client);
native int SH_GetCommonKills(int client);
native int SH_GetFFDamage(int client);
native int SH_GetFFTaken(int client);
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
    MarkNativeAsOptional("SH_GetFFTaken");
    MarkNativeAsOptional("SH_GetBlacked");
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("sui_version", PLUGIN_VERSION, "Plugin Version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_cvEnable    = CreateConVar("sui_enable", "1", "常驻得分榜总开关 [0=关|1=开]", _, true, 0.0, true, 1.0);
    g_cvTop       = CreateConVar("sui_top", "5", "显示前 N 名 [1-5]（标题+7列）", _, true, 1.0, true, 5.0);
    g_cvTop.SetBounds(ConVarBound_Upper, true, 5.0);
    g_cvTop.SetBounds(ConVarBound_Lower, true, 1.0);
    if (g_cvTop.IntValue > 5) g_cvTop.SetInt(5);
    else if (g_cvTop.IntValue < 1) g_cvTop.SetInt(1);
    g_cvInterval  = CreateConVar("sui_interval", "1.0", "刷新间隔秒", _, true, 0.5, true, 10.0);
    g_cvNameLen   = CreateConVar("sui_name_len", "12", "玩家名最大显示宽（CJK=2）", _, true, 4.0, true, 24.0);
    RegConsoleCmd("sm_boarddebug", Cmd_BoardDebug, "Dump raw board values");
    AutoExecConfig(true, "l4d2_scoreboard_ui");
}

public void OnMapStart()
{
    RemoveAllHUD();
    EnableHUD();
    // 标题 + 7 列地理化, 标题 0.005 高 0.02, 列从 0.03 起高 0.16 覆盖 6 行(头+5)
    HUDPlace(COL_TITLE, 0.02, 0.005, 0.50, 0.020);
    HUDPlace(COL_RANK,  0.02, 0.030, 0.03, 0.16);
    HUDPlace(COL_NAME,  0.05, 0.030, 0.14, 0.16);
    HUDPlace(COL_SCORE, 0.19, 0.030, 0.07, 0.16);
    HUDPlace(COL_SI,    0.26, 0.030, 0.05, 0.16);
    HUDPlace(COL_KILL,  0.31, 0.030, 0.05, 0.16);
    HUDPlace(COL_FF,    0.36, 0.030, 0.06, 0.16);
    HUDPlace(COL_BLK,   0.42, 0.030, 0.06, 0.16);
    g_bHudReady = true;
    if (g_hTimer == null)
        g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Refresh, _, TIMER_REPEAT);
}

public void OnMapEnd()
{
    RemoveAllHUD();
    g_bHudReady = false;
    if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
}

public void OnConfigsExecuted()
{
    if (g_hTimer == null)
        g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Refresh, _, TIMER_REPEAT);
}

public Action Timer_Refresh(Handle timer)
{
    if (!g_bHudReady)
    {
        RemoveAllHUD();
        EnableHUD();
        HUDPlace(COL_TITLE, 0.02, 0.005, 0.50, 0.020);
        HUDPlace(COL_RANK,  0.02, 0.030, 0.03, 0.16);
        HUDPlace(COL_NAME,  0.05, 0.030, 0.14, 0.16);
        HUDPlace(COL_SCORE, 0.19, 0.030, 0.07, 0.16);
        HUDPlace(COL_SI,    0.26, 0.030, 0.05, 0.16);
        HUDPlace(COL_KILL,  0.31, 0.030, 0.05, 0.16);
        HUDPlace(COL_FF,    0.36, 0.030, 0.06, 0.16);
        HUDPlace(COL_BLK,   0.42, 0.030, 0.06, 0.16);
        g_bHudReady = true;
    }
    HUDPlace(COL_TITLE, 0.02, 0.005, 0.50, 0.020);
    HUDPlace(COL_RANK,  0.02, 0.030, 0.03, 0.16);
    HUDPlace(COL_NAME,  0.05, 0.030, 0.14, 0.16);
    HUDPlace(COL_SCORE, 0.19, 0.030, 0.07, 0.16);
    HUDPlace(COL_SI,    0.26, 0.030, 0.05, 0.16);
    HUDPlace(COL_KILL,  0.31, 0.030, 0.05, 0.16);
    HUDPlace(COL_FF,    0.36, 0.030, 0.06, 0.16);
    HUDPlace(COL_BLK,   0.42, 0.030, 0.06, 0.16);
    for (int s = 7; s <= 9; s++) RemoveHUD(s); // 清旧 FAR 残留
    for (int s = HUD_SCORE_1; s <= HUD_SCORE_4; s++) RemoveHUD(s);

    if (!g_cvEnable.BoolValue) { RemoveAllHUD(); return Plugin_Continue; }

    char title[64];
    char colRank[128], colName[128], colScore[128], colSI[128], colKill[128], colFF[128], colBlk[128];
    int lineCount = BuildColumns(title, sizeof(title), colRank, colName, colScore, colSI, colKill, colFF, colBlk);

    if (lineCount == 0)
    {
        int f = HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_LEFT;
        HUDSetLayout(COL_TITLE, f, title);
        RemoveHUD(COL_RANK); RemoveHUD(COL_NAME); RemoveHUD(COL_SCORE);
        RemoveHUD(COL_SI); RemoveHUD(COL_KILL); RemoveHUD(COL_FF); RemoveHUD(COL_BLK);
        return Plugin_Continue;
    }

    // 标题 + 7 列
    HUDSetLayout(COL_TITLE, HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_LEFT, title);
    HUDSetLayout(COL_RANK,  HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_RIGHT, colRank);
    HUDSetLayout(COL_NAME,  HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_LEFT, colName);
    HUDSetLayout(COL_SCORE, HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_RIGHT, colScore);
    HUDSetLayout(COL_SI,    HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_RIGHT, colSI);
    HUDSetLayout(COL_KILL,  HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_RIGHT, colKill);
    HUDSetLayout(COL_FF,    HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_RIGHT, colFF);
    HUDSetLayout(COL_BLK,   HUD_FLAG_TEXT|HUD_FLAG_NOBG|HUD_FLAG_ALIGN_RIGHT, colBlk);
    return Plugin_Continue;
}

// 组列: 标题 + 7 列 \n 串, 返回数据行数+1(标题) 0=无数据
int BuildColumns(char[] title, int tlen, char[] cRank, char[] cName, char[] cScore, char[] cSI, char[] cKill, char[] cFF, char[] cBlk)
{
    if (!g_bCoreAvailable)
    {
        g_bCoreAvailable = (GetFeatureStatus(FeatureType_Native, "SH_GetRoundScore") == FeatureStatus_Available
            && FindPluginByFile(SCORE_CORE_FILE) != INVALID_HANDLE);
        if (!g_bCoreAvailable) { strcopy(title, tlen, "[得分榜] score_core 未加载"); return 0; }
    }
    int count = 0;
    int clients[MAXPLAYERS+1];
    for (int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2) clients[count++]=i;
    if (count==0) { strcopy(title, tlen, "[得分榜] 暂无数据"); return 0; }

    int scores[MAXPLAYERS+1];
    for (int k=0;k<count;k++) scores[k]=SH_GetRoundScore(clients[k]);
    for (int i=1;i<count;i++)
    {
        int ks=scores[i], kc=clients[i];
        int kSI=SH_GetSIKills(kc), kKill=SH_GetSIKills(kc)+SH_GetCommonKills(kc);
        int j=i-1;
        while (j>=0)
        {
            int sj=scores[j], sSI=SH_GetSIKills(clients[j]), sKill=SH_GetSIKills(clients[j])+SH_GetCommonKills(clients[j]);
            bool less=(sj<ks)|| (sj==ks && sSI<kSI) || (sj==ks && sSI==kSI && sKill<kKill);
            if (!less) break;
            scores[j+1]=scores[j]; clients[j+1]=clients[j]; j--;
        }
        scores[j+1]=ks; clients[j+1]=kc;
    }
    int top=g_cvTop.IntValue;
    if (top>count) top=count;
    if (top>5) top=5;
    Format(title, tlen, "[得分榜 TOP%d] 共%d人", top, count);

    // 列头
    strcopy(cRank, 128, "#");
    strcopy(cName, 128, "玩家");
    strcopy(cScore,128, "积分");
    strcopy(cSI,   128, "特感");
    strcopy(cKill, 128, "击杀");
    strcopy(cFF,   128, "友伤");
    strcopy(cBlk,  128, "被黑");

    char name[32];
    int nameMax=g_cvNameLen.IntValue;
    for (int k=0;k<top;k++)
    {
        int c=clients[k];
        GetClientName(c, name, sizeof(name));
        SanitizeName(name, nameMax);
        TruncateByDisplayWidth(name, 12);
        char rankStr[8], scoreStr[16], siStr[16], killStr[16], ffStr[16], blkStr[16];
        Format(rankStr,sizeof(rankStr),"#%d",k+1);
        int si=SH_GetSIKills(c), kill=SH_GetCommonKills(c), ff=0, blk=0;
        if (GetFeatureStatus(FeatureType_Native,"SH_GetFFDamage")==FeatureStatus_Available) ff=SH_GetFFDamage(c);
        if (GetFeatureStatus(FeatureType_Native,"SH_GetFFTaken")==FeatureStatus_Available) blk=SH_GetFFTaken(c);
        else if (GetFeatureStatus(FeatureType_Native,"SH_GetBlacked")==FeatureStatus_Available) blk=SH_GetBlacked(c);
        Format(scoreStr,sizeof(scoreStr),"%d",scores[k]);
        Format(siStr,sizeof(siStr),"%d",si);
        Format(killStr,sizeof(killStr),"%d",kill);
        Format(ffStr,sizeof(ffStr),"%d",ff);
        Format(blkStr,sizeof(blkStr),"%d",blk);

        StrCat(cRank,128,"\n"); StrCat(cRank,128,rankStr);
        StrCat(cName,128,"\n"); StrCat(cName,128,name);
        StrCat(cScore,128,"\n"); StrCat(cScore,128,scoreStr);
        StrCat(cSI,128,"\n"); StrCat(cSI,128,siStr);
        StrCat(cKill,128,"\n"); StrCat(cKill,128,killStr);
        StrCat(cFF,128,"\n"); StrCat(cFF,128,ffStr);
        StrCat(cBlk,128,"\n"); StrCat(cBlk,128,blkStr);
    }
    return top;
}

int GetDisplayWidth(const char[] s)
{
    int w=0;
    for(int i=0;s[i]!='\0';i++)
    {
        int b=s[i]&0xFF;
        if(b<0x80) w+=1;
        else if((b&0xE0)==0xC0){w+=2;i+=1;}
        else if((b&0xF0)==0xE0){w+=2;i+=2;}
        else if((b&0xF8)==0xF0){w+=2;i+=3;}
        else w+=1;
    }
    return w;
}
void TruncateByDisplayWidth(char[] s, int maxWidth)
{
    int w=0,pos=0,len=strlen(s);
    for(int i=0;i<len;)
    {
        int b=s[i]&0xFF, cl=1,cw=1;
        if(b<0x80){cl=1;cw=1;}
        else if((b&0xE0)==0xC0){cl=2;cw=2;}
        else if((b&0xF0)==0xE0){cl=3;cw=2;}
        else if((b&0xF8)==0xF0){cl=4;cw=2;}
        else{cl=1;cw=1;}
        if(w+cw>maxWidth){s[pos]='\0';return;}
        for(int k=0;k<cl;k++) s[pos++]=s[i++];
        w+=cw;
    }
    s[pos]='\0';
}
public Action Cmd_BoardDebug(int client,int args)
{
    for(int i=1;i<=MaxClients;i++)
    {
        if(!IsClientInGame(i)||GetClientTeam(i)!=2) continue;
        int sc=-1,si=-1,kill=-1,ff=-1,blk=-1;
        if(GetFeatureStatus(FeatureType_Native,"SH_GetRoundScore")==FeatureStatus_Available) sc=SH_GetRoundScore(i);
        if(GetFeatureStatus(FeatureType_Native,"SH_GetSIKills")==FeatureStatus_Available) si=SH_GetSIKills(i);
        if(GetFeatureStatus(FeatureType_Native,"SH_GetCommonKills")==FeatureStatus_Available) kill=SH_GetCommonKills(i);
        if(GetFeatureStatus(FeatureType_Native,"SH_GetFFDamage")==FeatureStatus_Available) ff=SH_GetFFDamage(i);
        if(GetFeatureStatus(FeatureType_Native,"SH_GetFFTaken")==FeatureStatus_Available) blk=SH_GetFFTaken(i);
        else if(GetFeatureStatus(FeatureType_Native,"SH_GetBlacked")==FeatureStatus_Available) blk=SH_GetBlacked(i);
        char name[32]; GetClientName(i,name,sizeof(name));
        if(client>0&&IsClientInGame(client)) PrintToChat(client,"[DBG] %s: 分%d 特%d 杀%d 友伤%d 被黑%d",name,sc,si,kill,ff,blk);
        PrintToServer("[DBG] %N: score %d SI %d kill %d FF %d blk %d",i,sc,si,kill,ff,blk);
    }
    if(client==0) PrintToServer("[DBG] dump done");
    else ReplyToCommand(client,"[DBG] dump done");
    return Plugin_Handled;
}
void SanitizeName(char[] name,int maxBytes)
{
    int len=strlen(name);
    for(int i=0;i<len;i++) if(name[i]<0x20||name[i]=='"'||name[i]=='\\') name[i]='?';
    if(len<=maxBytes) return;
    int cut=maxBytes;
    while(cut>0&&(name[cut]&0xC0)==0x80) cut--;
    name[cut]='\0';
}
