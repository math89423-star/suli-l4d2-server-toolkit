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

#define PLUGIN_VERSION 			"1.53 2026-07-19"

// Double-tap toggle state (used in CmdRequestGuide, must be declared before it)
bool g_bGuideToggled = false;
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

    RegConsoleCmd("path_to_goal",       CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("pathtogoal",         CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("wheretogo",          CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("imlost",             CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("guide",              CmdRequestGuide, "Point where to go to progress in the map.");
    RegConsoleCmd("ptg",                CmdRequestGuide, "Point where to go to progress in the map.");

    g_bL4D2 = GetEngineVersion()==Engine_Left4Dead2;
    LoadSDK();
    
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

    g_hCvarAutoDuration = CreateConVar("l4d_path_to_goal_auto_duration", "20.0",
    "Auto guide beam duration in seconds. Also used for manual !ptg trigger duration.",FCVAR_NOTIFY, true, 1.0, true, 60.0);

    g_hCvarAutoInterval = CreateConVar("l4d_path_to_goal_auto_interval", "25.0",
    "Seconds between auto guide beam pulses.",FCVAR_NOTIFY, true, 5.0, true, 300.0);

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
    blocked_available = GetFeatureStatus(FeatureType_Native,"L4D_NavArea_IsBlocked")==FeatureStatus_Available;
    if (!elevator_available || !blocked_available) LogMessage("Please update l4dhooks for better performance.");
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
    LogMessage("nav_blocked escape %d blocked %d area %d", navArea_escape(navArea), blocked, navArea);
    #endif
    if (!g_bFlowRecomputeHooked || finale) NavChanged();
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

    // Double-tap detected — force guide prep if needed
    if (!guide_ready)
    {
        Guide_Prep();
        if (!guide_ready || g_GuideCells == null)
        {
            ReplyToCommand(client, "[PTG] %t", "ptg_wait");
            return Plugin_Continue;
        }
    }

    if (g_bGuideToggled)
    {
        // Turn OFF
        g_bGuideToggled = false;
        if (g_hToggleTimer != null) { KillTimer(g_hToggleTimer); g_hToggleTimer = null; }
        ReplyToCommand(client, "[PTG] \x04Guide OFF");
    }
    else
    {
        // Turn ON — redraw every 15s (beams last 20s, always visible)
        g_bGuideToggled = true;
        AutoGuideDrawPath();
        if (g_hToggleTimer != null) { KillTimer(g_hToggleTimer); }
        g_hToggleTimer = CreateTimer(15.0, Timer_ToggleRedraw, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        ReplyToCommand(client, "[PTG] \x04Guide ON");
    }

    return Plugin_Continue;
}

Action Timer_ToggleRedraw(Handle timer)
{
    if (!g_bGuideToggled) { g_hToggleTimer = null; return Plugin_Stop; }
    if (!guide_ready || g_GuideCells == null) return Plugin_Continue;
    AutoGuideDrawPath();
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

void MapStarted()
{
    map_started = true;
    t_nav = -1.0;
    timer_nav = null;
    g_iPrepAttempts = 0;
    g_iFallbackStage = 0;

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
    g_bGuideToggled = false;
}

public void OnPluginEnd()
{
    Guide_Cleanup();
    guide_prep = false;
    g_iPrepStage = STAGE_NONE;
}

// --- Auto-Guide System (Overwatch-style pulse beacon) ---

Action Timer_AutoCheck(Handle timer)
{
    if (!g_hCvarAutoEnable.BoolValue)
    {
        g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    // Reschedule before other logic (recursive one-shot pattern — TIMER_REPEAT won't fire on empty servers)
    g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);

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
    }
    else if (!guide_ready && !guide_prep && g_iFallbackStage < 2)
    {
        // If standard prep keeps failing, try fallback after 10 attempts (~20s)
        if (g_iPrepAttempts >= 10 && g_iFallbackStage == 0)
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
    }

    return Plugin_Stop;
}

// Fallback: collect ALL nav areas sorted by flow (skip ESCAPE_ROUTE requirement)
// Works on custom maps where the nav mesh lacks proper spawn attributes
void Guide_Prep_Fallback()
{
    if (!enable || !gamemode_guidable || !map_started || !nav_started) return;

    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlow <= 0.0)
    {
        LogMessage("[PTG] Fallback failed: MapMaxFlowDistance = %.1f", maxFlow);
        g_iFallbackStage = 2;
        return;
    }

    ArrayList fbAreas = new ArrayList();
    L4D_GetAllNavAreas(fbAreas);
    if (fbAreas.Length <= 1)
    {
        LogMessage("[PTG] Fallback failed: L4D_GetAllNavAreas returned %d areas", fbAreas.Length);
        delete fbAreas;
        g_iFallbackStage = 2;
        return;
    }

    ArrayList fallbackCells = new ArrayList(sizeof(Cell));
    Cell cell;
    float pos[3];

    for (int i = 0; i < fbAreas.Length; i++)
    {
        Address navArea = fbAreas.Get(i);
        if (navArea == Address_Null) continue;
        if (blocked_available && L4D_NavArea_IsBlocked(navArea, TEAM_SURVIVOR, true)) continue;

        float flow = L4D2Direct_GetTerrorNavAreaFlow(navArea);
        if (flow < 0.0) continue;

        L4D_GetNavAreaCenter(navArea, pos);
        pos[2] += 16.0;
        // Skip underwater positions
        if (pos[2] < -1000.0) continue;

        cell.navArea = navArea;
        cell.center = pos;
        cell.flow = flow;
        fallbackCells.PushArray(cell);
    }

    delete fbAreas;

    if (fallbackCells.Length < 2)
    {
        LogMessage("[PTG] Fallback failed: only %d cells with valid flow collected", fallbackCells.Length);
        delete fallbackCells;
        g_iFallbackStage = 2;
        return;
    }

    // Sort by flow (ascending: start → end)
    fallbackCells.SortCustom(SortFlow);

    // Build g_GuideCells (dedup identical flows)
    delete g_GuideCells;
    g_GuideCells = new ArrayList(sizeof(Cell));

    Cell cellPrev;
    fallbackCells.GetArray(0, cell, sizeof(Cell));
    g_GuideCells.PushArray(cell);
    cellPrev = cell;

    for (int i = 1; i < fallbackCells.Length; i++)
    {
        fallbackCells.GetArray(i, cell, sizeof(Cell));
        // Skip if same flow as previous (duplicate)
        if (cell.flow == cellPrev.flow) continue;
        g_GuideCells.PushArray(cell);
        cellPrev = cell;
    }

    delete fallbackCells;

    if (g_GuideCells.Length < 2)
    {
        LogMessage("[PTG] Fallback failed: only %d unique flow cells after dedup", g_GuideCells.Length);
        delete g_GuideCells;
        g_iFallbackStage = 2;
        return;
    }

    guide_ready = true;
    guide_prep = false;
    g_iFallbackStage = 2;
    LogMessage("[PTG] Fallback success: %d guide cells built (bypassing ESCAPE_ROUTE requirement)", g_GuideCells.Length);
}

// Wrapper: expose SortFlow from include to our fallback code
// SortFlow is defined in the include file, called via SortCustom
// We can't call it directly since it's file-static, but SortCustom with SortFlow works
// because SortFlow is in scope during compilation (include is inlined)

void AutoGuideDrawPath()
{
    if (g_GuideCells == null || g_GuideCells.Length < 2) return;

    // Warm golden trail — like Fable breadcrumb on the ground
    // RGBA: soft amber, semi-transparent so it blends with the floor
    int color_trail[4]   = {255, 200, 75, 200};
    int color_chevron[4] = {255, 180, 40, 240};

    float duration = g_hCvarAutoDuration.FloatValue;
    int laser = g_iLaserWhite;
    if (laser == 0) laser = g_iLaser;
    if (laser == 0) return;

    int count = g_GuideCells.Length;

    for (int i = 0; i < count - 1; i++)
    {
        Cell cell1, cell2;
        g_GuideCells.GetArray(i, cell1, sizeof(Cell));
        g_GuideCells.GetArray(i + 1, cell2, sizeof(Cell));

        float distSq = GetVectorDistance(cell1.center, cell2.center, true);
        if (distSq < 4096.0) continue;

        // Hug the ground: cell centers are at ground+16, drop to ground+3
        float pos1[3], pos2[3];
        pos1 = cell1.center; pos1[2] -= 13.0;
        pos2 = cell2.center; pos2[2] -= 13.0;

        // Thin arrow beam on the ground: 1.2→4.5 wide, thin→thick shows direction
        TE_SetupBeamPoints(pos1, pos2, laser, 0, 0, 0,
            duration, 1.2, 4.5, 0, 0.0, color_trail, 0);
        TE_SendToAll();
    }

    // Small ground chevrons every ~5 cells — directional arrow marks
    int chevronInterval = 5;
    for (int i = 0; i < count - 1; i += chevronInterval)
    {
        Cell cell1, cell2;
        g_GuideCells.GetArray(i, cell1, sizeof(Cell));
        g_GuideCells.GetArray(i + 1, cell2, sizeof(Cell));

        float dir[3];
        SubtractVectors(cell2.center, cell1.center, dir);
        float dist = GetVectorLength(dir);
        if (dist < 1.0) continue;

        // Normalize direction (XY only, keep flat on ground)
        dir[2] = 0.0;
        NormalizeVector(dir, dir);

        // Perpendicular direction
        float perp[3];
        perp[0] = -dir[1];
        perp[1] = dir[0];
        perp[2] = 0.0;

        // Chevron tip and base positions on the ground
        float tip[3], baseLeft[3], baseRight[3];
        float arrowLen = 24.0;
        float halfWidth = 14.0;

        tip[0] = cell1.center[0] + dir[0] * arrowLen;
        tip[1] = cell1.center[1] + dir[1] * arrowLen;
        tip[2] = cell1.center[2] - 13.0;

        baseLeft[0] = cell1.center[0] + perp[0] * halfWidth;
        baseLeft[1] = cell1.center[1] + perp[1] * halfWidth;
        baseLeft[2] = cell1.center[2] - 13.0;

        baseRight[0] = cell1.center[0] - perp[0] * halfWidth;
        baseRight[1] = cell1.center[1] - perp[1] * halfWidth;
        baseRight[2] = cell1.center[2] - 13.0;

        // Left blade: tip → baseLeft
        TE_SetupBeamPoints(tip, baseLeft, laser, 0, 0, 0,
            duration, 3.0, 0.8, 0, 0.0, color_chevron, 0);
        TE_SendToAll();

        // Right blade: tip → baseRight
        TE_SetupBeamPoints(tip, baseRight, laser, 0, 0, 0,
            duration, 3.0, 0.8, 0, 0.0, color_chevron, 0);
        TE_SendToAll();
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