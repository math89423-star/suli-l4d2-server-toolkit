#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#define MODE_NORMAL 0
#define MODE_INCEND 1
#define MODE_EXPLOS 2
ConVar g_cvIncendAdd, g_cvExplosAdd;
int g_iTotalPool[MAXPLAYERS+1];
int g_iMode[MAXPLAYERS+1];
bool g_bUnlocked[MAXPLAYERS+1];
int g_iClipSize[MAXPLAYERS+1];
float g_fRStart[MAXPLAYERS+1];
bool g_bRSwitched[MAXPLAYERS+1];
bool g_bForceReload[MAXPLAYERS+1];
int g_iOldBtn[MAXPLAYERS+1];
int g_iPendingMode[MAXPLAYERS+1];
int g_iWeaponRef[MAXPLAYERS+1];
bool g_bLaser[MAXPLAYERS+1];
int g_iAmmoType[MAXPLAYERS+1];
Handle g_hHudSync=null;
public Plugin myinfo={name="[L4D2] Tactical Shared Pool",author="suli",description="共享总池 40/540+40=620 T切换",version="1.0.0",url=""};
public void OnPluginStart(){
    g_cvIncendAdd=CreateConVar("l4d2_tactical_incend_add","40","燃烧包追加",FCVAR_NOTIFY,true,1.0,true,200.0);
    g_cvExplosAdd=CreateConVar("l4d2_tactical_explos_add","40","高爆包追加",FCVAR_NOTIFY,true,1.0,true,200.0);
    HookEvent("upgrade_pack_used",Event_Upgrade,EventHookMode_Post);
    HookEvent("upgrade_pack_added",Event_Upgrade,EventHookMode_Post);
    HookEvent("player_use",Event_Use,EventHookMode_Post);
    HookEvent("weapon_fire",Event_Fire,EventHookMode_Post);
    HookEvent("round_start",Event_RoundStart,EventHookMode_PostNoCopy);
    RegConsoleCmd("sm_tactical",Cmd_Switch);
    RegConsoleCmd("sm_changeammo",Cmd_Switch);
    RegConsoleCmd("sm_t",Cmd_Switch);
    RegConsoleCmd("sm_tinfo",Cmd_Info);
    AutoExecConfig(true,"l4d2_tactical_shared");
    g_hHudSync=CreateHudSynchronizer();
    CreateTimer(0.3,Timer_HUD,_,TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    for(int i=1;i<=MaxClients;i++) g_iAmmoType[i]=-1;
}
public void Event_RoundStart(Event e,const char[] n,bool d){ for(int i=1;i<=MaxClients;i++){ g_iTotalPool[i]=0; g_iMode[i]=0; g_bUnlocked[i]=false; }}
public void OnClientPutInServer(int c){ CreateTimer(5.0,Timer_Bind,GetClientUserId(c),TIMER_FLAG_NO_MAPCHANGE); }
public Action Timer_Bind(Handle t,int id){ int c=GetClientOfUserId(id); if(c>0&&IsClientInGame(c)&&!IsFakeClient(c)){ ClientCommand(c,"bind t \"sm_tactical\""); } return Plugin_Stop; }
void EnsurePool(int client){
    int w=GetPlayerWeaponSlot(client,0);
    if(w<=0||!IsValidEdict(w)) return;
    int clip=GetEntProp(w,Prop_Send,"m_iClip1");
    int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
    int curClip= clip>0?clip:up;
    if(curClip<=0) curClip=40;
    g_iClipSize[client]=curClip;
    int at=GetEntProp(w,Prop_Send,"m_iPrimaryAmmoType");
    g_iAmmoType[client]=at;
    g_iWeaponRef[client]=EntIndexToEntRef(w);
    g_bLaser[client]=(GetEntProp(w,Prop_Send,"m_upgradeBitVec")&4)!=0;
    if(g_iTotalPool[client]==0){
        int reserve=GetEntProp(client,Prop_Send,"m_iAmmo",_,at);
        g_iTotalPool[client]=reserve+curClip;
    }
}
public void Event_Upgrade(Event e,const char[] n,bool d){
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return;
    int ent=e.GetInt("upgradeid"); char cls[64]; cls[0]='\0'; if(ent>0&&IsValidEdict(ent)) GetEdictClassname(ent,cls,sizeof(cls));
    if(StrContains(cls,"laser",false)!=-1) return;
    bool isExpl=StrContains(cls,"explosive",false)!=-1;
    if(cls[0]=='\0'){ int w=GetPlayerWeaponSlot(c,0); if(w>0&&IsValidEdict(w)) isExpl=(GetEntProp(w,Prop_Send,"m_upgradeBitVec")&2)!=0; }
    EnsurePool(c);
    int add=isExpl?g_cvExplosAdd.IntValue:g_cvIncendAdd.IntValue;
    g_iTotalPool[c]+=add;
    g_bUnlocked[c]=true;
    // 强制回满当前弹夹并切入该特殊
    int w=GetPlayerWeaponSlot(c,0);
    if(w>0&&IsValidEdict(w)){
        int need=g_iClipSize[c];
        int newBit=(isExpl?2:1)|(g_bLaser[c]?4:0);
        SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
        SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",need);
        SetEntProp(w,Prop_Send,"m_iClip1",need);
        g_iMode[c]=isExpl?MODE_EXPLOS:MODE_INCEND;
        if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-need,_,g_iAmmoType[c]);
        PrintCenterText(c,"→ %s +%d 总池%d",isExpl?"💥高爆":"🔥燃烧",add,g_iTotalPool[c]);
    }
    LogMessage("[shared] Upgrade client=%d %s +%d pool=%d",c,isExpl?"explos":"incend",add,g_iTotalPool[c]);
}
public void Event_Use(Event e,const char[] n,bool d){
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return;
    int ent=e.GetInt("entity"); if(ent<=0||!IsValidEdict(ent)) return;
    char cls[64]; GetEdictClassname(ent,cls,sizeof(cls));
    if(StrContains(cls,"upgrade_ammo",false)!=-1 || StrContains(cls,"upgradepack",false)!=-1){
        bool isExpl=StrContains(cls,"explosive",false)!=-1;
        EnsurePool(c);
        int add=isExpl?g_cvExplosAdd.IntValue:g_cvIncendAdd.IntValue;
        g_iTotalPool[c]+=add;
        g_bUnlocked[c]=true;
        int w=GetPlayerWeaponSlot(c,0);
        if(w>0&&IsValidEdict(w)){
            int need=g_iClipSize[c];
            int newBit=(isExpl?2:1)|(g_bLaser[c]?4:0);
            SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
            SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",need);
            SetEntProp(w,Prop_Send,"m_iClip1",need);
            g_iMode[c]=isExpl?MODE_EXPLOS:MODE_INCEND;
            if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-need,_,g_iAmmoType[c]);
            PrintCenterText(c,"→ %s +%d 总池%d",isExpl?"💥高爆":"🔥燃烧",add,g_iTotalPool[c]);
        }
    } else if(StrContains(cls,"ammo",false)!=-1){
        // 弹药堆：回满总池
        CreateTimer(0.2,Timer_SyncAmmo,GetClientUserId(c),TIMER_FLAG_NO_MAPCHANGE);
    }
}
public Action Timer_SyncAmmo(Handle t,int id){ int c=GetClientOfUserId(id); if(c>0&&IsClientInGame(c)){ EnsurePool(c); int w=GetPlayerWeaponSlot(c,0); if(w>0&&IsValidEdict(w)){ int at=g_iAmmoType[c]; if(at>=0){ int reserve=GetEntProp(c,Prop_Send,"m_iAmmo",_,at); int clip=GetEntProp(w,Prop_Send,"m_iClip1"); int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded"); int cur=clip>0?clip:up; g_iTotalPool[c]=reserve+cur; } } } return Plugin_Stop; }
public void Event_Fire(Event e,const char[] n,bool d){
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)) return;
    EnsurePool(c);
    if(g_iTotalPool[c]>0) g_iTotalPool[c]--;
    if(g_iTotalPool[c]<0) g_iTotalPool[c]=0;
}
void SwitchMode(int c){
    if(!g_bUnlocked[c]){ PrintCenterText(c,"未解锁特殊弹"); return; }
    int cur=g_iMode[c];
    int next=cur;
    if(cur==MODE_NORMAL) next=MODE_INCEND;
    else if(cur==MODE_INCEND) next=MODE_EXPLOS;
    else next=MODE_NORMAL;
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return;
    if(GetEntProp(w,Prop_Send,"m_bInReload")) SetEntProp(w,Prop_Send,"m_bInReload",0);
    EnsurePool(c);
    // 丢弃当前弹夹
    SetEntProp(w,Prop_Send,"m_iClip1",0);
    SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",0);
    int curBit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
    SetEntProp(w,Prop_Send,"m_upgradeBitVec",curBit & 4);
    g_iPendingMode[c]=next;
    g_iMode[c]=next;
    char wcls[64]; GetEdictClassname(w,wcls,sizeof(wcls));
    float dur=L4D2_GetFloatWeaponAttribute(wcls,L4D2FWA_ReloadDuration);
    if(dur<=0.1) dur=0.8;
    bool isShotgun=StrContains(wcls,"shotgun",false)!=-1;
    if(isShotgun) dur=dur*g_iClipSize[c]+0.2; else dur+=0.1;
    g_bForceReload[c]=true;
    char snd[64]; Format(snd,sizeof(snd),"weapons/%s/reload.wav",wcls[7]);
    EmitSoundToClient(c,snd);
    PrintCenterText(c,"换弹中... → %s (%.1fs)",next==0?"普通":next==1?"🔥燃烧":"💥高爆",dur);
    DataPack p; CreateDataTimer(dur,Timer_GiveNewAmmo,p,TIMER_FLAG_NO_MAPCHANGE);
    p.WriteCell(GetClientUserId(c));
    LogMessage("[shared] Switch %d %d->%d dur=%.2f pool=%d",c,cur,next,dur,g_iTotalPool[c]);
}
public Action Timer_GiveNewAmmo(Handle t,DataPack p){
    p.Reset(); int id=p.ReadCell(); int c=GetClientOfUserId(id);
    if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return Plugin_Stop;
    int next=g_iPendingMode[c];
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return Plugin_Stop;
    int need=g_iClipSize[c];
    int give=g_iTotalPool[c]>=need?need:g_iTotalPool[c];
    if(give>0) g_iTotalPool[c]-=give;
    if(next==MODE_NORMAL){
        int bit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
        SetEntProp(w,Prop_Send,"m_upgradeBitVec",bit&4);
        SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",0);
        SetEntProp(w,Prop_Send,"m_iClip1",give);
        if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-give,_,g_iAmmoType[c]);
        PrintCenterText(c,"→ 普通弹 %d发 池%d",give,g_iTotalPool[c]);
    } else {
        int newBit=(next==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
        SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
        SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",give);
        SetEntProp(w,Prop_Send,"m_iClip1",give);
        if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-give,_,g_iAmmoType[c]);
        PrintCenterText(c,"→ %s %d发 池%d",next==MODE_INCEND?"🔥燃烧":"💥高爆",give,g_iTotalPool[c]);
    }
    return Plugin_Stop;
}
public Action Timer_HUD(Handle t){
    for(int c=1;c<=MaxClients;c++){
        if(!IsClientInGame(c)||IsFakeClient(c)||!IsPlayerAlive(c)) continue;
        if(g_iTotalPool[c]==0) EnsurePool(c);
        int mode=g_iMode[c];
        int w=GetPlayerWeaponSlot(c,0);
        if(w>0&&IsValidEdict(w) && g_iAmmoType[c]>=0){
            int clip=GetEntProp(w,Prop_Send,"m_iClip1");
            int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
            int cur= up>0?up:clip;
            SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-cur,_,g_iAmmoType[c]);
        }
        if(g_bUnlocked[c]){
            char line[64]; Format(line,sizeof(line),"总池 %d [%s]",g_iTotalPool[c],mode==0?"普通":mode==1?"燃烧":"高爆");
            SetHudTextParams(0.85,0.88,0.4,255,200,0,255,0,0.0,0.0,0.0);
            ShowSyncHudText(c,g_hHudSync,line);
        } else ClearSyncHud(c,g_hHudSync);
    }
    return Plugin_Continue;
}
public Action OnPlayerRunCmd(int c,int &buttons,int &impulse,float vel[3],float angles[3],int &weapon,int &subtype,int &cmdnum,int &tickcount,int &seed,int mouse[2]){
    if(g_bForceReload[c]){ buttons |= IN_RELOAD; g_bForceReload[c]=false; }
    g_iOldBtn[c]=buttons;
    return Plugin_Continue;
}
public Action Cmd_Switch(int c,int a){ if(c>0&&IsPlayerAlive(c)) SwitchMode(c); return Plugin_Handled; }
public Action Cmd_Info(int c,int a){ if(c>0) PrintToChat(c,"[shared] 池%d 模式%d 解锁%d",g_iTotalPool[c],g_iMode[c],g_bUnlocked[c]); return Plugin_Handled; }
