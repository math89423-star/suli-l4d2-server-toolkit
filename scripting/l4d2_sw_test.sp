// 临时测试插件：M60 / 榴弹发射器 打空后引擎是否自动丢弃武器
// 用法（RCON 控制台即 root）：
//   sm_sw_test <name|all> <m60|gl|rifle> <clip> [reserve]   # 给武器并设弹匣/后备
//   sm_sw_drain <name|all> [clip]                            # 把当前主武器弹匣设为 clip(默认0)，2秒后自动报告
//   sm_sw_status [name|all]                                  # 报告武器/弹匣/后备/是否出现无主掉落武器
#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
    name = "L4D2 SW Test",
    author = "claude",
    description = "Temp test: M60/GL empty weapon drop behavior",
    version = "0.1",
    url = ""
};

public void OnPluginStart()
{
    RegAdminCmd("sm_sw_test", CmdTest, ADMFLAG_ROOT, "sm_sw_test <name|all> <m60|gl|rifle> <clip> [reserve]");
    RegAdminCmd("sm_sw_drain", CmdDrain, ADMFLAG_ROOT, "sm_sw_drain <name|all> [clip]");
    RegAdminCmd("sm_sw_status", CmdStatus, ADMFLAG_ROOT, "sm_sw_status [name|all]");
    RegAdminCmd("sm_sw_common", CmdCommon, ADMFLAG_ROOT, "sm_sw_common <name|all> — spawn common 150u in front of each target");
    RegAdminCmd("sm_sw_world", CmdWorld, ADMFLAG_ROOT, "sm_sw_world <name> <m60|gl> <clip> — spawn world weapon 100u in front of target");
    RegAdminCmd("sm_sw_scan", CmdScan, ADMFLAG_ROOT, "sm_sw_scan — 枚举地图上 M60/GL/spawn/ammo 实体状态");
}

Action CmdScan(int client, int args)
{
    char classes[5][64] = {
        "weapon_rifle_m60", "weapon_grenade_launcher",
        "weapon_rifle_m60_spawn", "weapon_grenade_launcher_spawn",
        "weapon_ammo_spawn"
    };
    for (int c = 0; c < 5; c++)
    {
        int found = 0;
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
        {
            int owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
            int clip = GetEntProp(ent, Prop_Send, "m_iClip1");
            int extra = GetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo");
            float pos[3];
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
            ReplyToCommand(client, "[swtest] %s ent=%d owner=%d clip=%d extra=%d @(%.0f %.0f %.0f)",
                classes[c], ent, owner, clip, extra, pos[0], pos[1], pos[2]);
            found++;
        }
        ReplyToCommand(client, "[swtest] %s: %d total", classes[c], found);
    }
    return Plugin_Handled;
}

Action CmdWorld(int client, int args)
{
    if (args < 3) { ReplyToCommand(client, "usage: sm_sw_world <name> <m60|gl> <clip>"); return Plugin_Handled; }
    char target[64], wcls[32], buf[16];
    GetCmdArg(1, target, sizeof(target));
    GetCmdArg(2, wcls, sizeof(wcls));
    GetCmdArg(3, buf, sizeof(buf));
    int clip = StringToInt(buf);

    char cls[64];
    if (StrEqual(wcls, "m60")) strcopy(cls, sizeof(cls), "weapon_rifle_m60");
    else if (StrEqual(wcls, "gl")) strcopy(cls, sizeof(cls), "weapon_grenade_launcher");
    else { ReplyToCommand(client, "weapon must be m60|gl"); return Plugin_Handled; }

    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2) continue;
        char name[64]; GetClientName(i, name, sizeof(name));
        if (!(StrEqual(target, "all") || StrContains(name, target, false) != -1)) continue;

        int ent = CreateEntityByName(cls);
        if (ent <= 0) { ReplyToCommand(client, "[swtest] create %s failed", cls); continue; }
        DispatchSpawn(ent);
        SetEntProp(ent, Prop_Send, "m_iClip1", clip);
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 0);

        float pos[3], ang[3], fwd[3];
        GetClientEyePosition(i, pos);
        GetClientEyeAngles(i, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        pos[0] += fwd[0] * 100.0;
        pos[1] += fwd[1] * 100.0;
        pos[2] -= 40.0;
        TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
        ReplyToCommand(client, "[swtest] world %s clip=%d ent=%d at (%.0f %.0f %.0f) for %N",
            cls, clip, ent, pos[0], pos[1], pos[2], i);
        count++;
    }
    if (count == 0) ReplyToCommand(client, "[swtest] no target matched '%s'", target);
    return Plugin_Handled;
}

Action CmdCommon(int client, int args)
{
    char target[64] = "all";
    if (args >= 1) GetCmdArg(1, target, sizeof(target));
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2) continue;
        char name[64]; GetClientName(i, name, sizeof(name));
        if (!(StrEqual(target, "all") || StrContains(name, target, false) != -1)) continue;
        float pos[3], ang[3], fwd[3];
        GetClientEyePosition(i, pos);
        GetClientEyeAngles(i, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        pos[0] += fwd[0] * 150.0;
        pos[1] += fwd[1] * 150.0;
        pos[2] -= 10.0;
        int ent = CreateEntityByName("infected");
        if (ent <= 0) { ReplyToCommand(client, "[swtest] create infected failed"); continue; }
        DispatchSpawn(ent);
        SetEntityModel(ent, "models/infected/common_male_01.mdl");
        SetEntProp(ent, Prop_Send, "m_lifeState", 0);
        TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
        ReplyToCommand(client, "[swtest] spawned infected %d at (%.0f %.0f %.0f) for %N", ent, pos[0], pos[1], pos[2], i);
        count++;
    }
    if (count == 0) ReplyToCommand(client, "[swtest] no target matched '%s'", target);
    return Plugin_Handled;
}

Action CmdTest(int client, int args)
{
    if (args < 3) { ReplyToCommand(client, "usage: sm_sw_test <name|all> <m60|gl|rifle> <clip> [reserve]"); return Plugin_Handled; }
    char target[64], wcls[32], buf[16];
    GetCmdArg(1, target, sizeof(target));
    GetCmdArg(2, wcls, sizeof(wcls));
    GetCmdArg(3, buf, sizeof(buf));
    int clip = StringToInt(buf);
    int reserve = -1;
    if (args >= 4) { GetCmdArg(4, buf, sizeof(buf)); reserve = StringToInt(buf); }

    char cls[64];
    if (StrEqual(wcls, "m60")) strcopy(cls, sizeof(cls), "weapon_rifle_m60");
    else if (StrEqual(wcls, "gl")) strcopy(cls, sizeof(cls), "weapon_grenade_launcher");
    else if (StrEqual(wcls, "rifle")) strcopy(cls, sizeof(cls), "weapon_rifle");
    else { ReplyToCommand(client, "weapon must be m60|gl|rifle"); return Plugin_Handled; }

    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2) continue;
        char name[64]; GetClientName(i, name, sizeof(name));
        bool match = StrEqual(target, "all") || StrContains(name, target, false) != -1;
        if (!match) continue;
        GiveWeapon(i, cls, clip, reserve);
        ReplyToCommand(client, "[swtest] gave %s clip=%d reserve=%d to %N (slot0=%d active=%d)",
            cls, clip, reserve, i, GetPlayerWeaponSlot(i, 0), GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon"));
        count++;
    }
    if (count == 0) ReplyToCommand(client, "[swtest] no target matched '%s'", target);
    return Plugin_Handled;
}

Action CmdDrain(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "usage: sm_sw_drain <name|all> [clip]"); return Plugin_Handled; }
    char target[64], buf[16];
    GetCmdArg(1, target, sizeof(target));
    int clip = 0;
    if (args >= 2) { GetCmdArg(2, buf, sizeof(buf)); clip = StringToInt(buf); }
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2) continue;
        char name[64]; GetClientName(i, name, sizeof(name));
        if (!(StrEqual(target, "all") || StrContains(name, target, false) != -1)) continue;
        int slot0 = GetPlayerWeaponSlot(i, 0);
        if (slot0 <= 0) { ReplyToCommand(client, "[swtest] %N has no slot0 weapon", i); continue; }
        SetEntProp(slot0, Prop_Send, "m_iClip1", clip);
        int uid = GetClientUserId(i);
        CreateTimer(2.0, TimerReport, uid, TIMER_FLAG_NO_MAPCHANGE);
        ReplyToCommand(client, "[swtest] %N slot0=%d set clip=%d, report in 2s", i, slot0, clip);
        count++;
    }
    if (count == 0) ReplyToCommand(client, "[swtest] no target matched '%s'", target);
    return Plugin_Handled;
}

Action CmdStatus(int client, int args)
{
    char target[64] = "all";
    if (args >= 1) GetCmdArg(1, target, sizeof(target));
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2) continue;
        char name[64]; GetClientName(i, name, sizeof(name));
        if (!(StrEqual(target, "all") || StrContains(name, target, false) != -1)) continue;
        Report(client, i);
    }
    ReportWorld(client);
    return Plugin_Handled;
}

void GiveWeapon(int client, const char[] cls, int clip, int reserve)
{
    int old = GetPlayerWeaponSlot(client, 0);
    if (old > 0 && IsValidEdict(old))
    {
        RemovePlayerItem(client, old);
        AcceptEntityInput(old, "Kill");
    }
    int ent = CreateEntityByName(cls);
    if (ent <= 0) return;
    DispatchSpawn(ent);
    SetEntProp(ent, Prop_Send, "m_iClip1", clip);
    if (reserve >= 0)
    {
        int type = GetEntProp(ent, Prop_Send, "m_iPrimaryAmmoType");
        if (type != -1)
            SetEntProp(client, Prop_Send, "m_iAmmo", reserve, _, type);
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", reserve);
    }
    EquipPlayerWeapon(client, ent);
}

void Report(int toClient, int client)
{
    int slot0 = GetPlayerWeaponSlot(client, 0);
    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    char cls[64] = "none";
    int clip = -1, reserve = -1;
    if (slot0 > 0 && IsValidEdict(slot0))
    {
        GetEntityClassname(slot0, cls, sizeof(cls));
        clip = GetEntProp(slot0, Prop_Send, "m_iClip1");
        reserve = GetEntProp(slot0, Prop_Send, "m_iExtraPrimaryAmmo");
    }
    char acls[64] = "none";
    if (active > 0 && IsValidEdict(active)) GetEntityClassname(active, acls, sizeof(acls));
    ReplyToCommand(toClient, "[swtest] %N: slot0=%d(%s clip=%d res=%d) active=%d(%s)",
        client, slot0, cls, clip, reserve, active, acls);
}

void ReportWorld(int toClient)
{
    char names[2][64] = { "weapon_rifle_m60", "weapon_grenade_launcher" };
    for (int n = 0; n < 2; n++)
    {
        int dropped = 0;
        float pos[3];
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, names[n])) != -1)
        {
            if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") == -1)
            {
                dropped++;
                GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
            }
        }
        if (dropped > 0)
            ReplyToCommand(toClient, "[swtest] WORLD: %d ownerless %s @ (%.0f %.0f %.0f)", dropped, names[n], pos[0], pos[1], pos[2]);
        else
            ReplyToCommand(toClient, "[swtest] WORLD: 0 ownerless %s", names[n]);
    }
}

Action TimerReport(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0) return Plugin_Handled;
    Report(0, client);
    ReportWorld(0);
    return Plugin_Handled;
}
