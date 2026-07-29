//This program is free software: you can redistribute it and/or modify
//it under the terms of the GNU General Public License as published by
//the Free Software Foundation, either version 3 of the License, or
//(at your option) any later version.
//This program is distributed in the hope that it will be useful,
//but WITHOUT ANY WARRANTY; without even the implied warranty of
//MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//GNU General Public License for more details.
//You should have received a copy of the GNU General Public License
//along with this program.  If not, see <http://www.gnu.org/licenses/>.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <dhooks>
#include <l4d_path_to_goal>

#define PLUGIN_VERSION 			"3.1 2026-07-28"

// Double-tap toggle state (used in CmdRequestGuide, must be declared before it)
// Per-client: each player toggles their own guide independently
bool g_bGuideToggled[MAXPLAYERS+1];
StringMap g_hReconnectToggle;  // SteamID → 1, persists toggle across disconnect/reconnect
Handle g_hToggleTimer = null;
float g_fLastPtgTime[MAXPLAYERS+1];

public Plugin myinfo =
{
	name = "[L4D1/L4D2] Path To Goal",
	author = "gvazdas, zyiks",
	description = "Automatic path to goal indicator for Survivor team.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=352685, https://github.com/gvazdas/l4d2_zombie_master"
}

public void OnPluginStart()
{
    AutoExecConfig(true, CONFIG_FILENAME);
    LoadTranslations("l4d_path_to_goal.phrases");

    g_hReconnectToggle = new StringMap();

    RegConsoleCmd("path_to_goal",       CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("pathtogoal",         CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("wheretogo",          CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("imlost",             CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("guide",              CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("ptg",                CmdRequestGuide, "Point where to go to progress in the map.");

    g_bL4D2 = GetEngineVersion()==Engine_Left4Dead2;
    LoadSDK();
    InitPlayerCaps();
    
    RegAdminCmd("l4d_path_to_goal_recalculate", CmdRecalculate, ADMFLAG_ROOT,"Recalculate guide points.");
    RegAdminCmd("l4d_path_to_goal_print",       CmdPrint, ADMFLAG_ROOT,"Print g_GuideCells.");
    if (g_bL4D2) RegAdminCmd("l4d_path_to_goal_rescue", CmdRescue, ADMFLAG_ROOT,"Send in rescue vehicle.");
    RegAdminCmd("l4d_path_to_goal_ground", CmdGround, ADMFLAG_ROOT,"Check if origin is near ground.");
    #if DEBUG
    RegAdminCmd("l4d_path_to_goal_validate", CmdValidate, ADMFLAG_ROOT,"Print validation results for cell index if provided, or closest cell to player.");
    #endif
    RegAdminCmd("l4d_path_to_goal_recomputeflow", CmdRecomputeFlow, ADMFLAG_ROOT,"Force TerrorNavMesh::RecomputeFlowDistances to fire.");

    g_hCvarEnable = CreateConVar("l4d_path_to_goal_enable", "1",
    "0=OFF, 1=ON.",FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvarEnable.AddChangeHook(ConVarChanged_Cvars);
  	
    g_hCvarMax = CreateConVar("l4d_path_to_goal_max", "32",
    "Max beams per request. Increasing this can potentially cause crashes for clients.",FCVAR_NOTIFY, true, 1.0, true, 1000.0);

    g_hCvarSurvivors = CreateConVar("l4d_path_to_goal_survivor", "1",
    "Allow survivors to request.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarInfected = CreateConVar("l4d_path_to_goal_infected", "1",
    "Allow infected to request.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarSpec = CreateConVar("l4d_path_to_goal_spec", "1",
    "Allow observers/spectators to request.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarAlive = CreateConVar("l4d_path_to_goal_alive", "0",
    "Allow request based on alive state: 0=all,1=alive only,2=dead only.",FCVAR_NOTIFY, true, 0.0, true, 2.0);

    g_hCvarBudget = CreateConVar("l4d_path_to_goal_budget", "0.5",
    "Max CPU budget (ms per frame) for escape route calculation. Larger budget makes requests available faster at the expense of server lag. 0 for infinite budget.",FCVAR_NOTIFY, true, 0.0, true, 1000.0);

    g_hCvarDetourBudget = CreateConVar("l4d_path_to_goal_detour_budget", "10.0",
    "Max CPU budget (ms) for detour beams. 0 for infinite budget.",FCVAR_NOTIFY, true, 0.0, true, 100.0);

    #if DEBUG
    SetConVarFloat(g_hCvarDetourBudget,0.0);
    #endif

    g_hCvarFinale = CreateConVar("l4d_path_to_goal_finale", "1",
    "On Finale maps, connect to rescue vehicle... 0: ALWAYS, 1: FINALE STARTED, 2: RESCUE ARRIVED, 3: NEVER",FCVAR_NOTIFY, true, 0.0, true, 3.0);

    g_hCvarFinaleAuto = CreateConVar("l4d_path_to_goal_finale_auto", "0",
    "Automatically draw beams to rescue vehicle for all clients. l4d_path_to_goal_finale must be less than 3.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarAutoEnable = CreateConVar("l4d_path_to_goal_auto", "0",
    "Auto guide mode: periodically draw the full escape route for all players. 0=OFF, 1=ON.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarAutoDuration = CreateConVar("l4d_path_to_goal_auto_duration", "1.0",
    "Guide beam lifetime in seconds. Keep low for instant OFF, auto-pulse may need higher.",FCVAR_NOTIFY, true, 1.0, true, 60.0);

    g_hCvarAutoInterval = CreateConVar("l4d_path_to_goal_auto_interval", "25.0",
    "Seconds between auto guide beam pulses.",FCVAR_NOTIFY, true, 5.0, true, 300.0);

    g_hCvarGapDzMax = CreateConVar("l4d_path_to_goal_gap_dz_max", "200.0",
    "Max vertical (Z) gap between guide cells before a beam is suppressed. 0=disable filter (draw all beams).",FCVAR_NOTIFY, true, 0.0, true, 2000.0);

    g_hCvarGapXyRatio = CreateConVar("l4d_path_to_goal_gap_xy_ratio", "2.0",
    "When Z gap exceeds gap_dz_max, draw beam only if horizontal distance >= Z_gap * this ratio.",FCVAR_NOTIFY, true, 0.5, true, 10.0);

    g_hCvarBeamMinDist = CreateConVar("l4d_path_to_goal_beam_min_dist", "32.0",
    "Minimum distance (units) between guide cells to draw a beam. Increase to reduce visual clutter on dense nav meshes.",FCVAR_NOTIFY, true, 0.0, true, 256.0);

    g_hCvarGapVertical = CreateConVar("l4d_path_to_goal_gap_vertical", "1",
    "When a beam is suppressed due to Z gap, draw a vertical bridge line instead: 0=skip entirely, 1=draw vertical indicator.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarStitchSteps = CreateConVar("l4d_path_to_goal_stitch_steps", "75",
    "Max steps for nav mesh exploration when stitching gaps between disconnected escape route cells.",FCVAR_NOTIFY, true, 20.0, true, 500.0);

    g_hCvarTraceHull = CreateConVar("l4d_path_to_goal_trace_hull", "1",
    "Use player-sized hull trace to skip beams blocked by world geometry (walls). 0=draw all beams including through walls.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarNonMesh = CreateConVar("l4d_path_to_goal_nonmesh", "0",
    "Enable non-mesh connection detection (jumps, vaults, crouch passages). 0=off, 1=on. Disabled by default — nav mesh edges are sufficient for correct pathfinding on most maps.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── v4.0 Advanced Features ──

    g_hCvarFunnel3D = CreateConVar("l4d_path_to_goal_funnel_3d", "1",
    "Enable 3D funnel algorithm for multi-floor building navigation. 0=2D funnel only (legacy), 1=3D funnel with Z-layer awareness.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarFunnelZStep = CreateConVar("l4d_path_to_goal_funnel_z_step", "80.0",
    "Max Z height change (units) between consecutive funnel portals before forcing an intermediate waypoint.",FCVAR_NOTIFY, true, 32.0, true, 500.0);

    g_hCvarRepairEnable = CreateConVar("l4d_path_to_goal_repair_enable", "1",
    "Enable STAGE_REPAIR: auto-fix beams blocked by world geometry after hull trace validation. 0=skip, 1=repair.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarRepairAttempts = CreateConVar("l4d_path_to_goal_repair_attempts", "8",
    "Max repair attempts per blocked beam before giving up and placing a beacon.",FCVAR_NOTIFY, true, 1.0, true, 20.0);

    g_hCvarBeaconEnable = CreateConVar("l4d_path_to_goal_beacon_enable", "1",
    "Draw bright beacon pillars at unreachable path break points. 0=off, 1=on.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarThetaStar = CreateConVar("l4d_path_to_goal_theta_star", "1",
    "Enable Theta* any-angle pathfinding: allows line-of-sight shortcuts during A* search for smoother paths.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarThetaLosMax = CreateConVar("l4d_path_to_goal_theta_los_max", "1500.0",
    "Theta* LOS check max distance (units). Larger = more aggressive shortcuts, higher CPU cost.",FCVAR_NOTIFY, true, 256.0, true, 5000.0);

    g_hCvarHpaEnable = CreateConVar("l4d_path_to_goal_hpa_enable", "1",
    "Enable HPA* hierarchical pathfinding for large maps (3000+ nav areas). 0=off, 1=on.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarHpaCellSize = CreateConVar("l4d_path_to_goal_hpa_cell_size", "1024.0",
    "HPA* cluster cell size (units). Smaller = finer hierarchy, more clusters.",FCVAR_NOTIFY, true, 256.0, true, 4096.0);

    g_hCvarFlowWeight = CreateConVar("l4d_path_to_goal_flow_weight", "0.25",
    "Flow heuristic weight for A* tie-breaking. 0.0=pure Euclidean, 1.0=pure flow.",FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarZCostFactor = CreateConVar("l4d_path_to_goal_z_cost_factor", "4.0",
    "Vertical cost multiplier in A* edge weights. Higher values strongly prefer level paths over climbing.",FCVAR_NOTIFY, true, 0.0, true, 10.0);

  	g_hCvarMPGameMode = FindConVar("mp_gamemode");
  	g_hCvarMPGameMode.AddChangeHook(ConVarGameMode);
    
    t_nav = -1.0;
    Check_Guidable();
    GetCvars();
    
    nav_started = true;
    guide_prep = false;
    HookEvent("round_start_post_nav",     evtPostNav,        EventHookMode_PostNoCopy);
    HookEvent("nav_blocked",              evtNavBlocked,     EventHookMode_Post);
    HookEvent("nav_generate",             evtNavGenerate,    EventHookMode_PostNoCopy);
	HookEvent("finale_start", 			  evtFinaleStart,    EventHookMode_PostNoCopy);
	HookEvent("finale_radio_start", 	  evtFinaleStart,    EventHookMode_PostNoCopy);
    HookEvent("finale_vehicle_ready", 	  evtFinaleVehicle,  EventHookMode_PostNoCopy);
    HookEvent("player_first_spawn",       evtFirstSpawn,     EventHookMode_PostNoCopy);
    HookEvent("player_spawn",             evtPlayerSpawn,    EventHookMode_Post);
    if (g_bL4D2)
    {
    HookEvent("gauntlet_finale_start", 	  evtGauntletStart,  EventHookMode_PostNoCopy);
    HookEvent("finale_vehicle_incoming",  evtFinaleVehicle,  EventHookMode_PostNoCopy);
    }

    // Auto-guide: check periodically if guide is ready, then start pulse timer
    // Use recursive one-shot timers (TIMER_REPEAT doesn't fire on empty servers)
    g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if(GetEngineVersion()!=Engine_Left4Dead2 && GetEngineVersion()!=Engine_Left4Dead)
	{
		strcopy(error,err_max,"Plugin only supports L4D1/L4D2.");
		return APLRes_SilentFailure;
	}
    MarkNativeAsOptional("L4D_NavArea_GetZ");
    MarkNativeAsOptional("L4D_NavArea_GetElevator");
    MarkNativeAsOptional("L4D_NavArea_IsBlocked");
    MarkNativeAsOptional("L4D_NavArea_GetCorner");
    MarkNativeAsOptional("L4D_NavArea_GetLadder");
    CreateNative("L4D_Path_To_Goal", Native_RequestGuide);
	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
    elevator_available = GetFeatureStatus(FeatureType_Native,"L4D_NavArea_GetElevator")==FeatureStatus_Available;
    corner_available  = GetFeatureStatus(FeatureType_Native,"L4D_NavArea_GetCorner")==FeatureStatus_Available;
    blocked_available = GetFeatureStatus(FeatureType_Native,"L4D_NavArea_IsBlocked")==FeatureStatus_Available;
    if (!elevator_available || !corner_available || !blocked_available) LogMessage("Please update l4dhooks for better performance.");
    if (g_bL4D2) g_hCvarZM = FindConVar("zm_enable"); // check if zombie master is active
}

void evtFinaleVehicle(Event event, const char[] name, bool dontBroadcast)
{
    #if DEBUG
    LogMessage("evtFinaleVehicle");
    #endif
    if (finale) finale_rescue = true;
    if (!enable) return;
    if (finale_rescue && g_hCvarFinale.IntValue < FINALE_NEVER)
    {
        if (guide_ready && !finale_stitched && should_stitch_finale()) stitch_finale();
        if (g_hCvarFinaleAuto.BoolValue) CreateTimer(2.0, Timer_Guide_All_Clients, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

void evtFinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    #if DEBUG
    LogMessage("evtFinaleStart");
    #endif
    finale = true;
    if (guide_ready && !finale_stitched && should_stitch_finale()) stitch_finale();
}

void evtGauntletStart(Event event, const char[] name, bool dontBroadcast)
{
    #if DEBUG
    LogMessage("evtGauntletStart");
    #endif
    finale = true;
    if (!use_gauntlet_logic() && finale_stitched) Guide_Cleanup(); // need to recalculate cells
    finale_gauntlet = true;
    if (!enable) return;
    if (guide_ready && !finale_stitched && should_stitch_finale()) stitch_finale();
}

void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();
}

void evtPostNav(Event event, const char[] name, bool dontBroadcast)
{
    #if DEBUG>1
        LogMessage("round_start_post_nav");
    #endif
    nav_started = true;
    finale = false;
    finale_rescue = false;
    finale_gauntlet = false;
    NavChanged();
}

void evtNavBlocked(Event event, const char[] name, bool dontBroadcast)
{
    if (!enable || !nav_started || !map_started) return;
    Address navArea = L4D_GetNavAreaByID(event.GetInt("area"));
    if (navArea == Address_Null) return;
    #if DEBUG>1
    bool blocked = event.GetBool("blocked");
    LogMessage("nav_blocked area %d blocked %d on_path %d", navArea, blocked, IsAreaOnPath(navArea));
    #endif
    // Re-plan if the blocked area is on our current path.
    // Removed the !g_bFlowRecomputeHooked||finale gate — it caused
    // nav_blocked events to be silently ignored 90% of the time.
    if (IsAreaOnPath(navArea))
        NavChanged(true);
}

void evtNavGenerate(Event event, const char[] name, bool dontBroadcast)
{
    #if DEBUG>1
    LogMessage("nav_generate");
    #endif
    NavChanged();
}

void ConVarGameMode(ConVar convar, const char[] oldValue, const char[] newValue)
{
	RequestFrame(Check_Guidable);
}

//int client_hint;

Action CmdRequestGuide(int client, int args)
{
    if (!enable || !map_started || !nav_started || !gamemode_guidable || !IsValidClient(client) || IsFakeClient(client)) return Plugin_Continue;

    // Double-tap detection: only toggle on two rapid presses within 0.5s
    float now = GetGameTime();
    float gap = g_fLastPtgTime[client] > 0.0 ? (now - g_fLastPtgTime[client]) : 999.0;
    g_fLastPtgTime[client] = now;

    if (gap > 0.5)
        return Plugin_Continue; // ignore single press, wait for double-tap

    // Double-tap detected — proceed to toggle or force guide prep.
    // (Don't pre-check MapMaxFlowDistance here — let the pipeline determine
    //  if the map is guidable. Custom maps without nav_analyze can still
    //  work via spatial-only A* with Euclidean distance goal detection.)

    // Force guide prep if needed
    if (!guide_ready)
    {
        Guide_Prep();
        if (!guide_ready || g_GuideCells == null)
        {
            ReplyToCommand(client, "[PTG] %t", "ptg_wait");
            return Plugin_Continue;
        }
    }

    if (g_bGuideToggled[client])
    {
        // Turn OFF (this client only)
        g_bGuideToggled[client] = false;
        ReplyToCommand(client, "[PTG] \x04Guide OFF");
        Guide_UpdateRedrawTimer();
    }
    else
    {
        // Turn ON — validate we can actually draw before confirming
        // v4.2: Don't show "Guide ON" if g_GuideCells is null/empty.
        // That would mean the path was cleaned up (NavChanged, integrity check, etc.)
        // and hasn't been rebuilt yet. Tell the user the real status.
        g_bGuideToggled[client] = true;
        Guide_UpdateRedrawTimer();

        if (guide_ready && g_GuideCells != null && g_GuideCells.Length >= 2)
        {
            AutoGuideDrawPath(client);
            ReplyToCommand(client, "[PTG] \x05Guide ON");
        }
        else
        {
            // Path not ready — prep is either already running or will start now.
            // The toggle is ON; beams will appear as soon as the pipeline finishes.
            if (!guide_prep)
                Guide_Prep();
            ReplyToCommand(client, "[PTG] \x04Guide queued — drawing as soon as path is ready...");
        }
    }

    return Plugin_Continue;
}

void Guide_UpdateRedrawTimer()
{
    bool anyOn = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bGuideToggled[i]) { anyOn = true; break; }
    }

    if (anyOn && g_hToggleTimer == null)
    {
        g_hToggleTimer = CreateTimer(0.6, Timer_ToggleRedraw, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    else if (!anyOn && g_hToggleTimer != null)
    {
        KillTimer(g_hToggleTimer);
        g_hToggleTimer = null;
    }
}

Action Timer_ToggleRedraw(Handle timer)
{
    bool anyOn = false;
    bool pathAvailable = (guide_ready && g_GuideCells != null && g_GuideCells.Length >= 2);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bGuideToggled[i] && IsValidClient(i) && !IsFakeClient(i))
        {
            anyOn = true;
            if (pathAvailable)
            {
                AutoGuideDrawPath(i);
            }
            else if (!guide_prep)
            {
                // v4.2: Path lost while client has toggle ON.
                // Trigger rebuild — beams will appear when pipeline finishes.
                Guide_Prep();
            }
        }
    }

    if (!anyOn)
    {
        g_hToggleTimer = null;
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

//Action TransmitInfoTarget(int entity, int client)
//{
//	 if (client==client_hint)
//   {
//        static float pos1[3],pos2[3];
//        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos1);
//        GetEntPropVector(client, Prop_Send, "m_vecOrigin", pos2); pos2[2] += 16.0;
//        if (GetVectorDistance(pos1,pos2,true)<=1024.0)
//        {
//            AcceptEntityInput(entity, "Kill");
//            return Plugin_Handled;
//        }
//        return Plugin_Continue;
//    }
//    return Plugin_Handled;
//}

// add custom flags for client from arg: duration, backward, g_sCustomKeys[client]
stock void process_cmd_arg(int client, char arg[16], float &duration, bool &backward)
{
    float duration_new = StringToFloat(arg);
    if (duration_new>=0.1)
    {
        duration = duration_new;
        return;
    }
    switch (CharToLower(arg[0]))
    {
        case 'a':
        {
            g_sCustomKeys[client][3] = 'a'; // arrow. beam increases in width from start to end
            return;
        }
        case 'b':
        {
            backward = true;
            return;
        }
        case 'c':
        {
            if (g_iLaserCustom!=0) g_sCustomKeys[client][0] = 'c'; // VMT_LASERBEAM_CUSTOM
            return;
        }
        case 'd':
        {
            g_sCustomKeys[client][4] = 'd'; // delay between beam draws, looks cool
            return;
        }
        case 's':
        {
            if (strncmp(arg,"small",5,false)==0) g_sCustomKeys[client][2] = 's'; // small beam size
            else if (strncmp(arg,"shake",5,false)==0) g_sCustomKeys[client][1] = 's'; // shake beam
            return;
        }
        case 'l':
        {
            g_sCustomKeys[client][2] = 'l'; // large beam size
            return;
        }
        case 'w':
        {
            if (g_iLaserWhite!=0) g_sCustomKeys[client][0] = 'w'; // VMT_LASERBEAM_WHITE
            return;
        }
    }
}

Action CmdRecalculate(int client, int args)
{
    if (!enable || !map_started || !nav_started || !gamemode_guidable) return Plugin_Continue;
    if (!guide_prep)
    {
        Guide_Cleanup();
        Guide_Prep();
    }
    else ReplyToCommand(client, "[PTG] %t", "ptg_busy");
    return Plugin_Continue;
}

Action CmdPrint(int client, int args)
{
    if (!guide_ready || g_GuideCells==null || g_GuideCells.Length<=0) return Plugin_Continue;
    static Cell cell;
    ReplyToCommand(client, "index navArea flow pos");
    for (int i = 0; i < g_GuideCells.Length; i++)
    {
        g_GuideCells.GetArray(i,cell,sizeof(Cell));
        ReplyToCommand(client, "%d %d %.1f (%.1f %1.f %.1f)", i, cell.navArea, cell.flow, cell.center[0], cell.center[1], cell.center[2]);
    }
    return Plugin_Continue;
}

#if DEBUG
Action CmdValidate(int client, int args)
{
    if (!guide_ready || g_GuideCells == null || g_GuideCells.Length<1) return Plugin_Continue;
    int i = 0;
    if (args>0)
    {
        i = GetCmdArgInt(1);
        if (i<0) i = 0;
        else if (i>=g_GuideCells.Length) i = g_GuideCells.Length-1;
    }
    else if (IsValidClient(client))
    {
        if (!RequestGuide(client,5.0,true)) return Plugin_Continue;
        i = g_iStart;
    }

    static Cell cell, cell_before, cell_after;
    
    g_GuideCells.GetArray(i,cell,sizeof(Cell));
    ReplyToCommand(client, "%d %d %.1f (%.1f %1.f %.1f)", i, cell.navArea, cell.flow, cell.center[0], cell.center[1], cell.center[2]);
    ReplyToCommand(client, "valid ground %d", valid_ground(cell.center));
    if (IsValidClient(client))
    {
        static float pos_down[3], pos_up[3];
        pos_down = cell.center; pos_down[2] -= 1000.0;
        pos_up = cell.center; pos_up[2] += 1000.0;
        DrawBeam(client,pos_down,pos_up);
    }
    bool cell_behind = (i-1)>=0;
    bool cell_ahead = (i+1)<g_GuideCells.Length;

    if (cell_behind)
    {
        g_GuideCells.GetArray(i-1,cell_before,sizeof(Cell));
        ReplyToCommand(client, "behind LOS %d (hit %d props %d flags %d name %s)",
        twopos_traversable(cell_before.center,cell.center), g_iHitEntity, g_iHitSurfaceProps, g_iHitSurfaceFlags, g_sHitSurfaceName);
    }
    if (cell_ahead)
    {
        g_GuideCells.GetArray(i+1,cell_after,sizeof(Cell));
        ReplyToCommand(client, "ahead LOS %d (hit %d props %d flags %d name %s)",
        twopos_traversable(cell_after.center,cell.center), g_iHitEntity, g_iHitSurfaceProps, g_iHitSurfaceFlags, g_sHitSurfaceName);
    }
    if (cell_behind && cell_ahead)
    {
        ReplyToCommand(client, "ahead-behind LOS %d (hit %d props %d flags %d name %s) mid-ground %d",
        twopos_traversable(cell_after.center,cell_before.center), g_iHitEntity, g_iHitSurfaceProps, g_iHitSurfaceFlags, g_sHitSurfaceName, midpoint_valid_ground(cell_after.center,cell_before.center));
    }
    return Plugin_Continue;
}
#endif

Action CmdRescue(int client, int args)
{
    L4D2_SendInRescueVehicle();
    return Plugin_Continue;
}

Action CmdGround(int client, int args)
{
    if (!IsValidClient(client) || IsFakeClient(client)) return Plugin_Stop;
    static float pos[3];
    GetEntPropVector(client, Prop_Send, "m_vecOrigin", pos);
    ReplyToCommand(client,"Ground %d",valid_ground(pos));
    return Plugin_Continue;
}

Action CmdRecomputeFlow(int client, int args)
{
    if (g_hRecomputeFlow == null) return Plugin_Continue;
    Address ptr_navmesh = L4D_GetPointer(POINTER_NAVMESH);
    if (ptr_navmesh == Address_Null) return Plugin_Continue;
    SDKCall(g_hRecomputeFlow,ptr_navmesh);
    return Plugin_Continue;
}

public void OnMapStart()
{
	g_iLaser = PrecacheModel(VMT_LASERBEAM, true);
    g_iLaserWhite = PrecacheModel(VMT_LASERBEAM_WHITE, true);
    g_iLaserCustom = PrecacheModel(VMT_LASERBEAM_CUSTOM, true);
    RequestFrame(MapStarted);
    //GetCurrentMap(mapName, sizeof(mapName));
}

// Global state for auto-guide fallback
int g_iPrepAttempts = 0;
int g_iFallbackStage = 0; // 0=normal, 1=fallback pending, 2=fallback done
int g_iFallbackRetries = 0;
#define MAX_FALLBACK_RETRIES 2

void MapStarted()
{
    map_started = true;
    t_nav = -1.0;
    timer_nav = null;
    g_iPrepAttempts = 0;
    g_iFallbackStage = 0;
    g_iFallbackRetries = 0;
    g_bPathDirty = false;

    // Re-create check timer on every map load (OnPluginStart only fires once;
    // OnMapEnd kills it, so we must recreate here after each map change)
    if (g_hAutoCheckTimer != null) { KillTimer(g_hAutoCheckTimer); }
    g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    map_started = false;
    nav_started = false;
    t_nav = -1.0;
    Guide_Cleanup();
    guide_prep = false;
    g_iPrepStage = STAGE_NONE;
    beams_cooldown_reset(_,true); // reset all requests and cooldowns
    timer_nav = null;
    finale = false;

    // Stop auto-guide timers
    if (g_hAutoTimer != null) { KillTimer(g_hAutoTimer); g_hAutoTimer = null; }
    if (g_hAutoCheckTimer != null) { KillTimer(g_hAutoCheckTimer); g_hAutoCheckTimer = null; }
    if (g_hToggleTimer != null) { KillTimer(g_hToggleTimer); g_hToggleTimer = null; }
    for (int i = 1; i <= MaxClients; i++) g_bGuideToggled[i] = false;
    g_hReconnectToggle.Clear(); // purge stale reconnect toggle entries
}

public void OnClientDisconnect(int client)
{
    // v4.2: Save toggle state by SteamID so it can be restored
    // if the same player reconnects in the same session.
    if (g_bGuideToggled[client] && !IsFakeClient(client))
    {
        char auth[64];
        if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
        {
            g_hReconnectToggle.SetValue(auth, 1);
        }
    }
    g_bGuideToggled[client] = false;
    g_fLastPtgTime[client] = 0.0;
}

public void OnPluginEnd()
{
    Guide_Cleanup();
    guide_prep = false;
    g_iPrepStage = STAGE_NONE;
    delete g_hReconnectToggle;
}

// --- Auto-Guide System (Overwatch-style pulse beacon) ---

Action Timer_AutoCheck(Handle timer)
{
    // Always reschedule (recursive one-shot — TIMER_REPEAT won't fire on empty servers)
    g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);

    // Always keep guide prepped in background, even when auto pulse is off.
    // This way !ptg is instant when a player uses it.
    if (!guide_ready && !guide_prep && g_iFallbackStage < 2)
    {
        if (g_iPrepAttempts >= 2 && g_iFallbackStage == 0)
        {
            LogMessage("[PTG] Standard prep failed after %d attempts. Trying fallback nav collection...", g_iPrepAttempts);
            g_iFallbackStage = 1;
            Guide_Prep_Fallback();
        }
        else if (g_iFallbackStage == 0)
        {
            g_iPrepAttempts++;
            Guide_Prep();
        }
        return Plugin_Stop;
    }

    // Fallback pipeline failure recovery: if fallback was attempted (stage==2),
    // but neither prep nor ready, the pipeline errored out. Retry a few times.
    if (!guide_ready && !guide_prep && g_iFallbackStage >= 2)
    {
        if (g_iFallbackRetries < MAX_FALLBACK_RETRIES)
        {
            g_iFallbackRetries++;
            LogMessage("[PTG] Fallback pipeline failed, retry %d/%d...", g_iFallbackRetries, MAX_FALLBACK_RETRIES);
            g_iFallbackStage = 1;
            g_iPrepAttempts = 0;
            Guide_Prep_Fallback();
        }
        else
        {
            // Give up on fallback, try standard prep again from scratch
            LogMessage("[PTG] Fallback pipeline exhausted retries. Resetting to standard prep attempts.");
            g_iFallbackStage = 0;
            g_iFallbackRetries = 0;
            g_iPrepAttempts = 0;
        }
        return Plugin_Stop;
    }

    // v4.2: Dirty path rebuild — NavChanged(true) flagged the path as stale
    // (blocked cells detected by PathIntegrityCheck or nav_blocked events).
    // Now it's safe to tear down the old path and rebuild in the background.
    // We delay the rebuild to this timer tick so toggled clients continue to see
    // the old (slightly stale) path rather than nothing at all.
    // This fires regardless of auto pulse mode — manual toggle clients also
    // need their path rebuilt when it goes stale.
    if (g_bPathDirty && guide_ready && !guide_prep)
    {
        LogMessage("[PTG] Rebuilding dirty path (%d cells, auto=%d)",
            g_GuideCells != null ? g_GuideCells.Length : 0,
            g_hCvarAutoEnable.BoolValue);
        g_bPathDirty = false;
        Guide_Cleanup();
        Guide_Prep();
    }

    // Auto pulse mode (only when cvar enabled)
    if (!g_hCvarAutoEnable.BoolValue) return Plugin_Stop;

    if (guide_ready && g_GuideCells != null && g_GuideCells.Length >= 2)
    {
        if (g_hAutoTimer == null)
        {
            LogMessage("[PTG] Guide ready (%d cells), starting pulse timer every %.0fs, duration %.0fs",
                g_GuideCells.Length, g_hCvarAutoInterval.FloatValue, g_hCvarAutoDuration.FloatValue);
            g_hAutoTimer = CreateTimer(g_hCvarAutoInterval.FloatValue, Timer_AutoGuidePulse, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
            AutoGuideDrawPath();
        }
        g_iPrepAttempts = 0;
        g_iFallbackStage = 0;
        g_iFallbackRetries = 0;
    }

    // --- Path integrity poll: check every 6s (every 3rd 2s tick) ---
    // Detects blocked path areas that didn't fire nav_blocked events
    // (prop physics, dynamic obstacles, etc.)
    {
        static int integrityTick = 0;
        integrityTick++;
        if (integrityTick >= 3 && blocked_available)
        {
            integrityTick = 0;
            PathIntegrityCheck();
        }
    }

    return Plugin_Stop;
}

// Fallback: Use A* over all nav areas (skip ESCAPE_ROUTE requirement).
// If A* fails, falls through to old flow-sort method as last resort.
void Guide_Prep_Fallback()
{
    if (!enable || !gamemode_guidable || !map_started || !nav_started) return;

    // Build A* node index if not already done (may have been built by standard prep)
    if (g_hAStarNodes == null || g_hAStarNodes.Length <= 1)
    {
        AStar_BuildNodeIndex();
    }

    if (g_hAStarNodes == null || g_hAStarNodes.Length <= 1)
    {
        LogMessage("[PTG] Fallback failed: A* node index is empty");
        g_iFallbackStage = 2;
        return;
    }

    // Compute max flow — prefer engine value, fall back to per-area scan
    g_fMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (g_fMaxFlow <= 0.0)
    {
        float maxAreaFlow = 0.0;
        for (int fi = 0; fi < g_hAStarNodes.Length; fi++)
        {
            int areaInt = g_hAStarNodes.Get(fi);
            float areaFlow = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(areaInt));
            if (areaFlow > maxAreaFlow)
                maxAreaFlow = areaFlow;
        }
        if (maxAreaFlow > 0.0)
        {
            g_fMaxFlow = maxAreaFlow;
            LogMessage("[PTG] Fallback: engine MapMaxFlowDistance was 0, computed from nav areas: %.1f", g_fMaxFlow);
        }
        else
        {
            // No valid flow data — keep g_fMaxFlow=0 as sentinel for spatial-only A*
            LogMessage("[PTG] Fallback: no flow data available — using spatial-only A*");
        }
    }

    // Track rescue vehicle
    g_fFlowRescueVehicle = -1.0;
    g_bFoundRescueVehicle = false;
    g_aNavRescueVehicle = Address_Null;
    for (int i = 0; i < g_hAStarNodes.Length; i++)
    {
        int areaInt = g_hAStarNodes.Get(i);
        Address area = view_as<Address>(areaInt);
        float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
        int spawnAttrs = L4D_GetNavArea_SpawnAttributes(area);

        if ((spawnAttrs & NAV_SPAWN_RESCUE_VEHICLE) && g_hCvarFinale.IntValue < FINALE_NEVER)
        {
            if (flow > g_fFlowRescueVehicle)
            {
                g_bFoundRescueVehicle = true;
                g_fFlowRescueVehicle = flow;
                g_aNavRescueVehicle = area;
            }
        }
    }

    // Set up rescue vehicle cells
    delete RescueVehicleCells;
    RescueVehicleCells = new ArrayList(sizeof(Cell));
    if (g_bFoundRescueVehicle)
    {
        Cell rvc;
        rvc.navArea = g_aNavRescueVehicle;
        rvc.flow = g_fFlowRescueVehicle;
        float rpos[3];
        L4D_GetNavAreaCenter(g_aNavRescueVehicle, rpos);
        rpos[2] += 16.0;
        if (pos_underwater(rpos)) rpos[2] += 16.0;
        rvc.center = rpos;
        RescueVehicleCells.PushArray(rvc);
    }

    finale_stitched = false;
    finale_backwards = false;

    // Identify start and goal
    int startIdx = AStar_IdentifyStart();
    int goalIdx = AStar_IdentifyGoal(startIdx);

    if (startIdx < 0 || goalIdx < 0)
    {
        LogMessage("[PTG] Fallback A*: cannot identify start (%d) or goal (%d)", startIdx, goalIdx);
        g_iFallbackStage = 2;
        return;
    }

    g_aAStarStart = g_hAStarNodes.Get(startIdx);
    g_aAStarGoal = g_hAStarNodes.Get(goalIdx);
    g_iAStarGoalIndex = goalIdx;

    LogMessage("[PTG] Fallback A*: %d nav areas, start=%d goal=%d",
        g_hAStarNodes.Length, startIdx, goalIdx);

    // Initialize A* and start search
    AStar_Init();
    AStar_SetStart(startIdx);
    DetectNonMeshConnections_Init();

    // Jump into pipeline at STAGE_ASTAR
    g_iPrepStage = STAGE_ASTAR;
    g_iLoop = 0;
    guide_prep = true;
    g_iFallbackStage = 2;

    RequestFrame(OnFramePrep, true);
}

// Wrapper: expose SortFlow from include to our fallback code
// SortFlow is defined in the include file, called via SortCustom
// We can't call it directly since it's file-static, but SortCustom with SortFlow works
// because SortFlow is in scope during compilation (include is inlined)

void AutoGuideDrawPath(int client = -1)
{
    if (g_GuideCells == null || g_GuideCells.Length < 2) return;

    // Trail: thin, semi-transparent amber — subtle guide that doesn't block the view
    int color_trail[4]   = {255, 200, 75, 150};
    // Arrow: brighter, more opaque — direction must be clear
    int color_chevron[4] = {255, 170, 30, 220};

    float duration = g_hCvarAutoDuration.FloatValue;
    int laser = g_iLaserWhite;
    if (laser == 0) laser = g_iLaser;
    if (laser == 0) return;

    int count = g_GuideCells.Length;

    // v2.2/v4.2: For per-client requests, start drawing from the nearest cell to the player.
    // This auto-updates as the player moves because the redraw timer fires every 0.6s.
    // v4.2: Handle dead/spectating/idle players — use observer target position instead
    // of falling back to index 0 (which draws beams at the map start, invisible to the
    // dead player's camera following another survivor).
    int startIndex = 0;
    if (client > 0 && IsValidClient(client) && !IsFakeClient(client))
    {
        float clientPos[3];
        bool alive = IsPlayerAlive(client);
        int target = client;

        if (!alive)
        {
            // Dead/spectating/idle — get the position of who they're watching
            int observermode = GetEntProp(client, Prop_Send, "m_iObserverMode");
            if (observermode == 4 || observermode == 5) // in-eye or chase cam
            {
                target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
                if (target < 1 || target > MaxClients || !IsClientInGame(target))
                    target = client;
            }
        }

        if (alive || target != client)
        {
            GetEntPropVector(target, Prop_Send, "m_vecOrigin", clientPos);
            float bestDist = -1.0;
            int bestIdx = 0;
            for (int j = 0; j < count; j++)
            {
                Cell cell;
                g_GuideCells.GetArray(j, cell, sizeof(Cell));
                float d = GetVectorDistance(clientPos, cell.center, true); // sq dist
                if (bestDist < 0.0 || d < bestDist)
                {
                    bestDist = d;
                    bestIdx = j;
                }
            }
            // Start 1-2 cells before nearest so the player can see the immediate next step
            // Also shows the path behind — important for maps that require backtracking
            startIndex = bestIdx > 1 ? bestIdx - 2 : 0;
        }
    }

    // On very dense nav meshes (complex 3rd-party maps), subsample to avoid
    // overwhelming the client's temp-entity buffer and to keep beams readable.
    int maxBeams = g_hCvarMax.IntValue;
    int step = 1;
    if (count > maxBeams && maxBeams > 0)
    {
        step = count / maxBeams;
        if (step < 1) step = 1;
    }

    // Trail: thin, close to ground, subtle amber shimmer
    int trailDrawn = 0;
    for (int i = startIndex; i < count - 1 && trailDrawn < maxBeams; i += step)
    {
        Cell cell1, cell2;
        g_GuideCells.GetArray(i, cell1, sizeof(Cell));
        g_GuideCells.GetArray(i + 1, cell2, sizeof(Cell));

        // v2.2: Skip beams blocked by world geometry (hull trace validation).
        // Doors, breakables, and trigger barriers are entity-based and pass through.
        // Draw a small beacon dot at the break point so players know the path continues.
        if (g_bBeamWalkable != null && i < g_bBeamWalkable.Length && g_bBeamWalkable.Get(i) == 0)
        {
            // Beacon: bright small dot at the blocked cell position — "path continues here"
            float beaconPos[3], beaconEnd[3];
            beaconPos = cell1.center;
            beaconEnd = cell1.center;
            beaconEnd[2] += 28.0; // above floor so beam is visible
            int color_beacon[4] = {255, 100, 50, 255}; // bright red-orange
            TE_SetupBeamPoints(beaconPos, beaconEnd, laser, 0, 0, 0,
                duration * 0.5, 2.0, 4.0, 0, 0.0, color_beacon, 0);
            if (client > 0) TE_SendToClient(client);
            else TE_SendToAll();
            trailDrawn++;
            continue;
        }

        float distSq = GetVectorDistance(cell1.center, cell2.center, true);
        float minDist = g_hCvarBeamMinDist.FloatValue;
        if (minDist > 0.0 && distSq < minDist * minDist) continue;

        // Skip or bridge beams between cells at drastically different heights.
        // On multi-floor buildings this prevents confusing diagonal beams through walls.
        float dz = FloatAbs(cell1.center[2] - cell2.center[2]);
        float dzMax = g_hCvarGapDzMax.FloatValue;
        float xyRatio = g_hCvarGapXyRatio.FloatValue;
        float distXY = GetVectorDistance(cell1.center, cell2.center, false);

        if (dzMax > 0.0 && dz > dzMax && distXY < dz * xyRatio)
        {
            // Draw vertical bridge instead of skipping entirely
            if (g_hCvarGapVertical.BoolValue)
            {
                float vpos[3];
                vpos[0] = cell1.center[0];
                vpos[1] = cell1.center[1];
                vpos[2] = cell2.center[2];

                // Vertical segment: thin, cool blue-white tint — lift above floor
                int color_vert[4] = {200, 220, 255, 180};
                float ve1[3], ve2[3];
                ve1 = cell1.center; ve1[2] += 28.0;
                ve2 = vpos; ve2[2] += 28.0;
                TE_SetupBeamPoints(ve1, ve2, laser, 0, 0, 0,
                    duration, 0.3, 3.0, 0, 0.0, color_vert, 0);
                if (client > 0) TE_SendToClient(client);
                else TE_SendToAll();

                // Horizontal bridge to next cell
                float pos1_bridge[3], pos2_bridge[3];
                pos1_bridge = vpos; pos1_bridge[2] += 28.0;
                pos2_bridge = cell2.center; pos2_bridge[2] += 28.0;
                TE_SetupBeamPoints(pos1_bridge, pos2_bridge, laser, 0, 0, 0,
                    duration, 0.6, 2.0, 0, 0.0, color_trail, 0);
                if (client > 0) TE_SendToClient(client);
                else TE_SendToAll();
                trailDrawn += 2;
            }
            continue;
        }

        float pos1[3], pos2[3];
        pos1 = cell1.center; pos1[2] += 28.0;
        pos2 = cell2.center; pos2[2] += 28.0;

        TE_SetupBeamPoints(pos1, pos2, laser, 0, 0, 0,
            duration, 0.8, 2.5, 0, 0.0, color_trail, 0);
        if (client > 0) TE_SendToClient(client);
        else TE_SendToAll();
        trailDrawn++;
    }

    // Arrows — clear directional indicators, subsampled for dense meshes
    int chevronInterval = 5 * step;
    if (chevronInterval < 5) chevronInterval = 5;
    for (int i = startIndex; i < count - 1; i += chevronInterval)
    {
        Cell cell1, cell2;
        g_GuideCells.GetArray(i, cell1, sizeof(Cell));
        g_GuideCells.GetArray(i + 1, cell2, sizeof(Cell));

        float dir[3];
        SubtractVectors(cell2.center, cell1.center, dir);
        float dist = GetVectorLength(dir);
        if (dist < 1.0) continue;

        dir[2] = 0.0;
        NormalizeVector(dir, dir);

        float perp[3];
        perp[0] = -dir[1];
        perp[1] = dir[0];
        perp[2] = 0.0;

        float tip[3], baseLeft[3], baseRight[3];
        float arrowLen = 28.0;
        float halfWidth = 16.0;

        tip[0] = cell1.center[0] + dir[0] * arrowLen;
        tip[1] = cell1.center[1] + dir[1] * arrowLen;
        tip[2] = cell1.center[2] + 28.0;

        baseLeft[0] = cell1.center[0] + perp[0] * halfWidth;
        baseLeft[1] = cell1.center[1] + perp[1] * halfWidth;
        baseLeft[2] = cell1.center[2] + 28.0;

        baseRight[0] = cell1.center[0] - perp[0] * halfWidth;
        baseRight[1] = cell1.center[1] - perp[1] * halfWidth;
        baseRight[2] = cell1.center[2] + 28.0;

        // Left blade
        TE_SetupBeamPoints(tip, baseLeft, laser, 0, 0, 0,
            duration, 3.5, 1.0, 0, 0.0, color_chevron, 0);
        if (client > 0) TE_SendToClient(client);
        else TE_SendToAll();

        // Right blade
        TE_SetupBeamPoints(tip, baseRight, laser, 0, 0, 0,
            duration, 3.5, 1.0, 0, 0.0, color_chevron, 0);
        if (client > 0) TE_SendToClient(client);
        else TE_SendToAll();
    }

    // Warn if beam cap was hit (indicates subsampling may be hiding cells)
    if (trailDrawn >= maxBeams && count > maxBeams)
    {
        LogMessage("[PTG] Beam cap reached: %d trails drawn out of %d cells (max %d, step %d). Increase l4d_path_to_goal_max or adjust filter cvars.",
            trailDrawn, count, maxBeams, step);
    }
}

Action Timer_AutoGuidePulse(Handle timer)
{
    if (!g_hCvarAutoEnable.BoolValue) { g_hAutoTimer = null; return Plugin_Stop; }
    if (!guide_ready || g_GuideCells == null || g_GuideCells.Length < 2) return Plugin_Continue;
    if (!gamemode_guidable || !map_started || !nav_started) return Plugin_Continue;
    AutoGuideDrawPath();
    return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client)) return;
    beams_cooldown_reset(client,true); // reset cooldown and last request from client
    g_sCustomKeys[client] = "";
}

// v4.2: Restore guide toggle state for players who rejoin after disconnecting.
// OnClientPostAdminCheck fires after Steam auth is complete, so GetClientAuthId
// returns a valid SteamID. OnClientPutInServer is too early for auth.
public void OnClientPostAdminCheck(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client)) return;

    char auth[64];
    if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
    {
        int toggleVal;
        if (g_hReconnectToggle.GetValue(auth, toggleVal) && toggleVal == 1)
        {
            g_hReconnectToggle.Remove(auth); // consume — don't reapply on further callbacks
            g_bGuideToggled[client] = true;
            Guide_UpdateRedrawTimer();

            // Immediate draw if path is ready; otherwise queue a rebuild
            if (guide_ready && g_GuideCells != null && g_GuideCells.Length >= 2)
            {
                AutoGuideDrawPath(client);
            }
            else if (!guide_prep && !g_bPathDirty)
            {
                Guide_Prep();
            }
        }
    }
}

void evtFirstSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (event == null) return;
    int userid = event.GetInt("userid");
    if (userid <= 0) return;
    // Delay bind until after client config.cfg has executed (~5s after first spawn)
    CreateTimer(5.0, Timer_FirstSpawnBind, userid, TIMER_FLAG_NO_MAPCHANGE);
}

// v4.2: Redraw beams immediately when a player respawns after death or takes over a bot.
// The redraw timer fires every 0.6s and would eventually pick up the new position,
// but immediate redraw eliminates the visible gap after respawn.
void evtPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (event == null) return;
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (client < 1 || client > MaxClients) return;
    if (!IsClientInGame(client) || IsFakeClient(client)) return;
    if (!g_bGuideToggled[client]) return;

    if (guide_ready && g_GuideCells != null && g_GuideCells.Length >= 2)
    {
        AutoGuideDrawPath(client);
    }
    else if (!guide_prep && !g_bPathDirty)
    {
        // Path lost while player was dead — try to rebuild
        Guide_Prep();
    }
}

Action Timer_FirstSpawnBind(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
    {
        ClientCommand(client, "bind m \"say !ptg\"");
        PrintToChat(client, "\x04[PTG] \x01Press \x05M\x01 or type \x05!ptg\x01 for navigation guide (double-tap to toggle)");
    }
    return Plugin_Stop;
}

// NATIVE //

void Native_RequestGuide(Handle plugin, int numParams)
{
    if (!enable || !gamemode_guidable || !nav_started || !map_started) return;
    int client = (numParams>0) ? GetNativeCell(1) : -1;
    float duration = (numParams>1) ? view_as<float>(GetNativeCell(2)) : 5.0;
    bool backward = (numParams>2) ? view_as<bool>(GetNativeCell(3)) : false;
    bool join_client = (numParams>3) ? view_as<bool>(GetNativeCell(4)) : true;
    RequestGuide(client,duration,backward,join_client);
}