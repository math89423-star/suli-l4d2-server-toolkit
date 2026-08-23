#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define MODE_NORMAL 0
#define MODE_INCEND 1
#define MODE_EXPLOS 2

ConVar g_cvIncendPerPack, g_cvExplosPerPack, g_cvHoldTime, g_cvMaxIncend, g_cvMaxExplos;
int g_iSpecial[MAXPLAYERS+1][2];
int g_iMode[MAXPLAYERS+1];
int g_iPendingMode[MAXPLAYERS+1];
int g_iClipSize[MAXPLAYERS+1];
int g_iWeaponRef[MAXPLAYERS+1];
bool g_bLaser[MAXPLAYERS+1];
int g_iAmmoType[MAXPLAYERS+1];
int g_iOrigReserve[MAXPLAYERS+1];
int g_iNormalClip[MAXPLAYERS+1];
float g_fReloadStart[MAXPLAYERS+1];
bool g_bSwitchTriggered[MAXPLAYERS+1];
bool g_bForceReload[MAXPLAYERS+1];
int g_iOldButtons[MAXPLAYERS+1];
Handle g_hHudSync = null;

public Plugin myinfo = {
    name = "[L4D2] Tactical Ammo System",
    author = "suli",
    description = "双池燃烧/高爆 T切换 武器栏备弹",
    version = "1.0.0",
    url = ""
};

public void OnPluginStart()
{
    g_cvIncendPerPack = CreateConVar("l4d2_tactical_incend_per_pack", "150", "每包燃烧弹补充量", FCVAR_NOTIFY, true, 1.0, true, 1000.0);
    g_cvExplosPerPack = CreateConVar("l4d2_tactical_explos_per_pack", "150", "每包高爆弹补充量", FCVAR_NOTIFY, true, 1.0, true, 1000.0);
    g_cvHoldTime = CreateConVar("l4d2_tactical_hold", "0.5", "长按R阈值", FCVAR_NOTIFY, true, 0.2, true, 2.0);
    g_cvMaxIncend = CreateConVar("l4d2_tactical_max_incend", "300", "燃烧上限", FCVAR_NOTIFY, true, 30.0, true, 2000.0);
    g_cvMaxExplos = CreateConVar("l4d2_tactical_max_explos", "300", "高爆上限", FCVAR_NOTIFY, true, 30.0, true, 2000.0);
    HookEvent("upgrade_pack_used", Event_UpgradePack, EventHookMode_Post);
    HookEvent("upgrade_pack_added", Event_UpgradePack, EventHookMode_Post);
    HookEvent("player_use", Event_PlayerUse, EventHookMode_Post);
    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    RegConsoleCmd("sm_tactical", Cmd_Switch);
    RegConsoleCmd("sm_changeammo", Cmd_Switch);
    RegConsoleCmd("sm_t", Cmd_Switch);
    RegConsoleCmd("sm_ammo", Cmd_Tactical);
    RegConsoleCmd("sm_switch", Cmd_Switch);
    RegConsoleCmd("sm_tadd", Cmd_TAdd);
    RegConsoleCmd("sm_tinfo", Cmd_TInfo);
    AutoExecConfig(true, "l4d2_tactical_ammo");
    g_hHudSync = CreateHudSynchronizer();
    CreateTimer(0.3, Timer_HUD, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    for (int i = 1; i <= MaxClients; i++) g_iAmmoType[i] = -1;
}
public void OnMapEnd(){}
public void Event_RoundStart(Event e, const char[] n, bool d){ for(int i=1;i<=MaxClients;i++) ResetClient(i); }
public void Event_PlayerDeath(Event e, const char[] n, bool d){ int c=GetClientOfUserId(e.GetInt("userid")); if(c>0) ResetClient(c); }
public void OnClientPutInServer(int c){ CreateTimer(8.0, Timer_AutoBind, GetClientUserId(c), TIMER_FLAG_NO_MAPCHANGE); CreateTimer(4.0, Timer_SpoofAmmo, GetClientUserId(c), TIMER_FLAG_NO_MAPCHANGE); }
public Action Timer_AutoBind(Handle t, int userid){ int c=GetClientOfUserId(userid); if(c>0 && IsClientInGame(c) && !IsFakeClient(c)){ ClientCommand(c, "bind t \"sm_tactical\""); PrintToChat(c, "[战术弹药] 已尝试自动绑定 T->切换弹种，若无效请手动 bind t \"sm_tactical\""); } return Plugin_Stop; }
public Action Timer_SpoofAmmo(Handle t, int userid){ int c=GetClientOfUserId(userid); if(c>0 && IsClientInGame(c) && !IsFakeClient(c)){ SpoofAmmoMax(c); } return Plugin_Stop; }
void SpoofAmmoMax(int client)
{
    char convars[][] = {"ammo_assaultrifle_max","ammo_autoshotgun_max","ammo_shotgun_max","ammo_smg_max","ammo_smg_silenced_max","ammo_huntingrifle_max","ammo_sniperrifle_max","ammo_grenadelauncher_max","ammo_rifle_max","ammo_rifle_desert_max","ammo_rifle_ak47_max","ammo_rifle_sg552_max","ammo_smg_mp5_max"};
    for(int i=0;i<sizeof(convars);i++){ ConVar cv=FindConVar(convars[i]); if(cv!=null) SendConVarValue(client, cv, "999"); }
}
public void OnClientDisconnect(int c){ ResetClient(c); }
void ResetClient(int c)
{
    if (IsClientInGame(c) && g_iAmmoType[c]>=0)
    {
        int cur=GetPlayerWeaponSlot(c,0);
        if(cur>0 && IsValidEdict(cur) && GetEntProp(cur,Prop_Send,"m_iPrimaryAmmoType")==g_iAmmoType[c])
            SetEntProp(c,Prop_Send,"m_iAmmo",g_iOrigReserve[c],_,g_iAmmoType[c]);
        ClearSyncHud(c,g_hHudSync);
    }
    g_iSpecial[c][0]=0; g_iSpecial[c][1]=0; g_iMode[c]=MODE_NORMAL; g_iPendingMode[c]=0; g_iClipSize[c]=0; g_iWeaponRef[c]=0; g_bLaser[c]=false; g_iOrigReserve[c]=0; g_iAmmoType[c]=-1; g_fReloadStart[c]=0.0; g_bSwitchTriggered[c]=false; g_bForceReload[c]=false; g_iOldButtons[c]=0; g_iNormalClip[c]=0;
}
void AddSpecial(int client, int type, int amount)
{
    if(type<0||type>1) return;
    int maxv = type==0 ? g_cvMaxIncend.IntValue : g_cvMaxExplos.IntValue;
    g_iSpecial[client][type] += amount;
    if(g_iSpecial[client][type] > maxv) g_iSpecial[client][type] = maxv;
    PrintToChat(client, "[战术弹药] %s +%d 库存 %d/%d (T切换)", type==0?"🔥燃烧":"💥高爆", amount, g_iSpecial[client][type], maxv);
    LogMessage("[tactical] Add client=%d type=%d +%d total=%d", client, type, amount, g_iSpecial[client][type]);
}
public void Event_UpgradePack(Event e, const char[] n, bool d)
{
    int client=GetClientOfUserId(e.GetInt("userid")); if(client<=0||!IsClientInGame(client)||!IsPlayerAlive(client)) return;
    int ent=e.GetInt("upgradeid"); char cls[64]; cls[0]='\0'; if(ent>0&&IsValidEdict(ent)) GetEdictClassname(ent,cls,sizeof(cls));
    if(StrContains(cls,"laser",false)!=-1) return;
    LogMessage("[tactical] %s client=%d ent=%d cls=%s", n, client, ent, cls);
    bool isExpl = StrContains(cls,"explosive",false)!=-1;
    if(cls[0]=='\0'){ int w=GetPlayerWeaponSlot(client,0); if(w>0&&IsValidEdict(w)) { int b=GetEntProp(w,Prop_Send,"m_upgradeBitVec"); isExpl=(b&2)!=0; } }
    int amt = isExpl ? g_cvExplosPerPack.IntValue : g_cvIncendPerPack.IntValue;
    int before = g_iSpecial[client][isExpl?1:0];
    AddSpecial(client, isExpl?1:0, amt);
    int w=GetPlayerWeaponSlot(client,0);
    if(w>0&&IsValidEdict(w))
    {
        if(g_iAmmoType[client]==-1)
        {
            g_iAmmoType[client]=GetEntProp(w,Prop_Send,"m_iPrimaryAmmoType");
            g_iOrigReserve[client]=GetEntProp(client,Prop_Send,"m_iAmmo",_,g_iAmmoType[client]);
            g_iClipSize[client]=GetEntProp(w,Prop_Send,"m_iClip1");
            if(g_iClipSize[client]<=0) g_iClipSize[client]=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
            if(g_iClipSize[client]<=0) g_iClipSize[client]=50;
            g_iWeaponRef[client]=EntIndexToEntRef(w);
            g_bLaser[client]=(GetEntProp(w,Prop_Send,"m_upgradeBitVec")&4)!=0;
        }
        if(before<=0 && g_iMode[client]==MODE_NORMAL)
        {
            g_iMode[client]=isExpl?MODE_EXPLOS:MODE_INCEND;
            int need=g_iClipSize[client];
            int idx=isExpl?1:0;
            int give=g_iSpecial[client][idx]>=need?need:g_iSpecial[client][idx];
            if(give>0) g_iSpecial[client][idx]-=give;
            int newBit=(isExpl?2:1)|(g_bLaser[client]?4:0);
            SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
            SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",give);
            SetEntProp(w,Prop_Send,"m_iClip1",give);
            if(g_iAmmoType[client]>=0) SetEntProp(client,Prop_Send,"m_iAmmo",g_iSpecial[client][idx],_,g_iAmmoType[client]);
            PrintCenterText(client, "→ %s %d发", isExpl?"💥高爆弹":"🔥燃烧弹", give);
        }
    }
}
public void Event_PlayerUse(Event e, const char[] n, bool d)
{
    int client=GetClientOfUserId(e.GetInt("userid")); if(client<=0||!IsClientInGame(client)||!IsPlayerAlive(client)) return;
    int ent=e.GetInt("entity"); if(ent<=0||!IsValidEdict(ent)) return;
    char cls[64]; GetEdictClassname(ent,cls,sizeof(cls));
    if(StrContains(cls,"upgrade_ammo",false)==-1 && StrContains(cls,"upgradepack",false)==-1) return;
    if(StrContains(cls,"laser",false)!=-1) return;
    LogMessage("[tactical] player_use client=%d ent=%d cls=%s", client, ent, cls);
    bool isExpl=StrContains(cls,"explosive",false)!=-1;
    int amt=isExpl?g_cvExplosPerPack.IntValue:g_cvIncendPerPack.IntValue;
    int before2=g_iSpecial[client][isExpl?1:0];
    AddSpecial(client,isExpl?1:0,amt);
    int w2=GetPlayerWeaponSlot(client,0);
    if(w2>0&&IsValidEdict(w2))
    {
        if(g_iAmmoType[client]==-1)
        {
            g_iAmmoType[client]=GetEntProp(w2,Prop_Send,"m_iPrimaryAmmoType");
            g_iOrigReserve[client]=GetEntProp(client,Prop_Send,"m_iAmmo",_,g_iAmmoType[client]);
            g_iClipSize[client]=GetEntProp(w2,Prop_Send,"m_iClip1");
            if(g_iClipSize[client]<=0) g_iClipSize[client]=GetEntProp(w2,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
            if(g_iClipSize[client]<=0) g_iClipSize[client]=50;
            g_iWeaponRef[client]=EntIndexToEntRef(w2);
            g_bLaser[client]=(GetEntProp(w2,Prop_Send,"m_upgradeBitVec")&4)!=0;
        }
        if(before2<=0 && g_iMode[client]==MODE_NORMAL)
        {
            g_iMode[client]=isExpl?MODE_EXPLOS:MODE_INCEND;
            int need2=g_iClipSize[client];
            int idx2=isExpl?1:0;
            int give2=g_iSpecial[client][idx2]>=need2?need2:g_iSpecial[client][idx2];
            if(give2>0) g_iSpecial[client][idx2]-=give2;
            int newBit2=(isExpl?2:1)|(g_bLaser[client]?4:0);
            SetEntProp(w2,Prop_Send,"m_upgradeBitVec",newBit2);
            SetEntProp(w2,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",give2);
            SetEntProp(w2,Prop_Send,"m_iClip1",give2);
            if(g_iAmmoType[client]>=0) SetEntProp(client,Prop_Send,"m_iAmmo",g_iSpecial[client][idx2],_,g_iAmmoType[client]);
            PrintCenterText(client, "→ %s %d发", isExpl?"💥高爆弹":"🔥燃烧弹", give2);
        }
    }
}
public void Event_WeaponFire(Event e, const char[] n, bool d)
{
    int client=GetClientOfUserId(e.GetInt("userid")); if(client<=0||!IsClientInGame(client)) return;
    if(g_iMode[client]==MODE_NORMAL) return;
    int idx=g_iMode[client]==MODE_INCEND?0:1;
    if(g_iSpecial[client][idx]>0)
    {
        g_iSpecial[client][idx]--;
        if(g_iSpecial[client][idx]<0) g_iSpecial[client][idx]=0;
    }
}
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if(g_bForceReload[client]){ buttons |= IN_RELOAD; g_bForceReload[client]=false; }
    g_iOldButtons[client]=buttons;
    return Plugin_Continue;
}
void SwitchMode(int client)
{
    LogMessage("[tactical] Switch attempt client=%d mode=%d special=%d,%d", client, g_iMode[client], g_iSpecial[client][0], g_iSpecial[client][1]);
    int weapon=GetPlayerWeaponSlot(client,0);
    if(weapon>0 && IsValidEdict(weapon) && GetEntProp(weapon, Prop_Send, "m_bInReload"))
        SetEntProp(weapon, Prop_Send, "m_bInReload", 0);
    int curMode=g_iMode[client];
    int next=curMode;
    for(int i=0;i<3;i++)
    {
        next=(next+1)%3;
        if(next==MODE_NORMAL) break;
        int idx=next==MODE_INCEND?0:1;
        if(g_iSpecial[client][idx]>0) break;
    }
    if(next!=MODE_NORMAL)
    {
        int idx=next==MODE_INCEND?0:1;
        if(g_iSpecial[client][idx]<=0) next=MODE_NORMAL;
    }
    if(next==curMode){ PrintCenterText(client, "已是 %s", next==0?"普通弹":next==1?"🔥燃烧弹":"💥高爆弹"); return; }
    weapon=GetPlayerWeaponSlot(client,0);
    if(weapon<=0||!IsValidEdict(weapon)) return;
    // 丢弃当前弹夹
    if(curMode==MODE_NORMAL)
    {
        SetEntProp(weapon, Prop_Send, "m_iClip1", 0);
        if(g_iAmmoType[client]>=0) g_iOrigReserve[client]=GetEntProp(client,Prop_Send,"m_iAmmo",_,g_iAmmoType[client]);
    }
    else
    {
        SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", 0);
        int curBit2=GetEntProp(weapon,Prop_Send,"m_upgradeBitVec");
        SetEntProp(weapon,Prop_Send,"m_upgradeBitVec",curBit2 & 4);
        SetEntProp(weapon, Prop_Send, "m_iClip1", 0);
    }
    int clipTmp=GetEntProp(weapon,Prop_Send,"m_iClip1");
    if(clipTmp>0) g_iClipSize[client]=clipTmp;
    else{ int upTmp=GetEntProp(weapon,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded"); if(upTmp>0) g_iClipSize[client]=upTmp; }
    if(g_iClipSize[client]<=0) g_iClipSize[client]=50;
    if(g_iAmmoType[client]==-1)
    {
        g_iAmmoType[client]=GetEntProp(weapon,Prop_Send,"m_iPrimaryAmmoType");
        g_iOrigReserve[client]=GetEntProp(client,Prop_Send,"m_iAmmo",_,g_iAmmoType[client]);
        g_iWeaponRef[client]=EntIndexToEntRef(weapon);
        g_bLaser[client]=(GetEntProp(weapon,Prop_Send,"m_upgradeBitVec")&4)!=0;
    }
    g_iPendingMode[client]=next;
    g_iMode[client]=next;
    char wcls2[64]; GetEdictClassname(weapon, wcls2, sizeof(wcls2));
    float dur = L4D2_GetFloatWeaponAttribute(wcls2, L4D2FWA_ReloadDuration);
    if(dur <= 0.1) dur = 0.8;
    bool isShotgun = StrContains(wcls2, "shotgun", false)!=-1;
    int estNeed = g_iClipSize[client];
    if(isShotgun) dur = dur * estNeed + 0.2; else dur += 0.1;
    g_bForceReload[client]=true;
    char snd2[64]; Format(snd2,sizeof(snd2),"weapons/%s/reload.wav", wcls2[7]);
    EmitSoundToClient(client, snd2);
    PrintCenterText(client, "换弹中... → %s (%.1fs)", next==0?"普通":next==1?"🔥燃烧":"💥高爆", dur);
    DataPack p; CreateDataTimer(dur, Timer_GiveNewAmmo, p, TIMER_FLAG_NO_MAPCHANGE);
    p.WriteCell(GetClientUserId(client));
    LogMessage("[tactical] Switch client=%d %d->%d dur=%.2f wcls=%s shotgun=%d", client, curMode, next, dur, wcls2, isShotgun);
}
public Action Timer_GiveNewAmmo(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid=pack.ReadCell();
    int client=GetClientOfUserId(userid);
    if(client<=0||!IsClientInGame(client)||!IsPlayerAlive(client)) return Plugin_Stop;
    int next=g_iPendingMode[client];
    int weapon=GetPlayerWeaponSlot(client,0);
    if(weapon<=0||!IsValidEdict(weapon)) return Plugin_Stop;
    if(next==MODE_NORMAL)
    {
        int bit=GetEntProp(weapon,Prop_Send,"m_upgradeBitVec");
        int keepLaser=bit&4;
        SetEntProp(weapon,Prop_Send,"m_upgradeBitVec",keepLaser);
        SetEntProp(weapon,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",0);
        if(g_iNormalClip[client]>0) SetEntProp(weapon,Prop_Send,"m_iClip1",g_iNormalClip[client]);
        else SetEntProp(weapon,Prop_Send,"m_iClip1",g_iClipSize[client]);
        if(g_iAmmoType[client]>=0) SetEntProp(client,Prop_Send,"m_iAmmo",g_iOrigReserve[client],_,g_iAmmoType[client]);
        PrintCenterText(client, "→ 普通弹");
        PrintToChat(client, "[战术弹药] 切换 普通弹");
    }
    else
    {
        int idx=next==MODE_INCEND?0:1;
        int need=g_iClipSize[client];
        int give= g_iSpecial[client][idx]>=need?need:g_iSpecial[client][idx];
        if(give>0) g_iSpecial[client][idx]-=give;
        int newBit=(next==MODE_INCEND?1:2) | (g_bLaser[client]?4:0);
        SetEntProp(weapon,Prop_Send,"m_upgradeBitVec",newBit);
        SetEntProp(weapon,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",give);
        SetEntProp(weapon,Prop_Send,"m_iClip1",give);
        if(g_iAmmoType[client]>=0) SetEntProp(client,Prop_Send,"m_iAmmo",g_iSpecial[client][idx],_,g_iAmmoType[client]);
        PrintCenterText(client, "→ %s %d发", next==MODE_INCEND?"🔥燃烧弹":"💥高爆弹", give);
        PrintToChat(client, "[战术弹药] 切换 %s 弹夹%d 库存%d", next==MODE_INCEND?"燃烧":"高爆", give, g_iSpecial[client][idx]);
        SpoofAmmoMax(client);
    }
    return Plugin_Stop;
}
public Action Timer_HUD(Handle timer)
{
    for(int c=1;c<=MaxClients;c++)
    {
        if(!IsClientInGame(c)||IsFakeClient(c)||!IsPlayerAlive(c)) continue;
        int mode=g_iMode[c];
        if(mode!=MODE_NORMAL && g_iWeaponRef[c]!=0)
        {
            int w=EntRefToEntIndex(g_iWeaponRef[c]);
            if(w==INVALID_ENT_REFERENCE||!IsValidEdict(w)) continue;
            int cur=GetPlayerWeaponSlot(c,0);
            if(cur!=w) continue;
            int idx=mode==MODE_INCEND?0:1;
            if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iSpecial[c][idx],_,g_iAmmoType[c]);
            int ammo=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
            int bit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
            bool has=(bit & (mode==MODE_INCEND?1:2))!=0;
            if(ammo==0 && !has && g_iSpecial[c][idx]==0) SwitchMode(c);
        }
        if(g_iSpecial[c][0]>0 || g_iSpecial[c][1]>0 || mode!=MODE_NORMAL)
        {
            char line[128];
            Format(line,sizeof(line),"🔥%d 💥%d [%s]", g_iSpecial[c][0], g_iSpecial[c][1], mode==0?"普通":mode==1?"燃烧":"高爆");
            SetHudTextParams(0.85, 0.88, 0.4, 255,200,0,255,0, 0.0,0.0,0.0);
            ShowSyncHudText(c,g_hHudSync,line);
        }
        else ClearSyncHud(c,g_hHudSync);
    }
    return Plugin_Continue;
}
public Action Cmd_Tactical(int c,int a){ if(c>0) PrintToChat(c,"[战术] 🔥%d 💥%d 模式%d 短按T切换", g_iSpecial[c][0], g_iSpecial[c][1], g_iMode[c]); return Plugin_Handled; }
public Action Cmd_TInfo(int c,int a){ if(c>0){ int w=GetPlayerWeaponSlot(c,0); int b=w>0&&IsValidEdict(w)?GetEntProp(w,Prop_Send,"m_upgradeBitVec"): -1; int am=w>0&&IsValidEdict(w)?GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded"):-1; int cl=w>0&&IsValidEdict(w)?GetEntProp(w,Prop_Send,"m_iClip1"):-1; PrintToChat(c,"[tinfo] mode=%d special %d/%d clip=%d/%d bit=%d inReload=%d", g_iMode[c], g_iSpecial[c][0], g_iSpecial[c][1], cl, am, b, w>0?GetEntProp(w,Prop_Send,"m_bInReload"): -1); } return Plugin_Handled; }
public Action Cmd_Switch(int c,int a){ if(c>0 && IsPlayerAlive(c)) SwitchMode(c); else if(c==0) { for(int i=1;i<=MaxClients;i++) if(IsClientInGame(i)&&IsPlayerAlive(i)) SwitchMode(i); } return Plugin_Handled; }
public Action Cmd_TAdd(int c,int a)
{
    if(a<2){ ReplyToCommand(c,"sm_tadd <0燃烧1高爆> <数量>"); return Plugin_Handled; }
    char b1[16],b2[16]; GetCmdArg(1,b1,sizeof(b1)); GetCmdArg(2,b2,sizeof(b2));
    int t=StringToInt(b1); int n=StringToInt(b2); if(c>0) AddSpecial(c,t,n); else for(int i=1;i<=MaxClients;i++) if(IsClientInGame(i)) AddSpecial(i,t,n);
    return Plugin_Handled;
}
