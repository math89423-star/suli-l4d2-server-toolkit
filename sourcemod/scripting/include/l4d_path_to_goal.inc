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

#if defined _ptg_inc_included
 #endinput
#endif
#define _ptg_inc_included

/**
 * Draw survivor escape path in L4D1 or L4D2.
 *
 * @param client       Client entity index for which to draw beams. Must be a real in game client.
 * @param duration     Beam lifetime.
 * @param backward     Draw backwards-going path.
 * @param join_client  Visually connect client origin to nearest point in survivor path. Can be expensive.
 */
native void L4D_Path_To_Goal(int client = -1, float duration = 5.0, bool backward = false, bool join_client = true);

public SharedPlugin __pl_l4d_path_to_goal =
{
    name     = "l4d_path_to_goal",
    file     = "l4d_path_to_goal.smx",
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d_path_to_goal_SetNTVOptional()
{
    MarkNativeAsOptional("L4D_Path_To_Goal");
}
#endif

#if defined _NATIVE_ONLY
 #endinput
#endif

#pragma semicolon 1
#pragma newdecls required

#define DEBUG 0 // 1 for basic debug, 2 for details, 3 for EXTREME amount of detail

#include <sourcemod>
#include <left4dhooks>
#include <dhooks>
#include <gvazdas_navmesh_utils>

#define PLUGIN_NAME			    "l4d_path_to_goal"
#define GAMEDATA_FILE           PLUGIN_NAME
#define CONFIG_FILENAME         PLUGIN_NAME

#define NAV_COOLDOWN 3.1416 // GameTime cooldown after nav events fire before Guide_Prep can be requested

#define TEAM_SPECTATOR		1
#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3

#define VMT_LASERBEAM         "sprites/laserbeam.vmt"
#define VMT_LASERBEAM_WHITE   "sprites/white.vmt"
#define VMT_LASERBEAM_CUSTOM  "sprites/bloodspray.vmt"

ConVar g_hCvarAlive;
#define ACCEPT_ALL   0 // accept all players
#define ACCEPT_ALIVE 1 // accept only alive players
#define ACCEPT_DEAD  2 // accept only non-alive players

// Data structure for guide points
enum struct Cell
{
	float flow;
    Address navArea;
	float center[3]; // cell position slightly above ground
}

// How are two nav areas connected?
enum ConnectionType {
    CONNECTED_NOT = 0,
    CONNECTED_ADJACENT = 1, // dir
    CONNECTED_LADDER = 2, // ladder
    CONNECTED_ELEVATOR = 3, // elevator
    CONNECTED_JUMP_UP = 4, // one-way jump up to higher nav area
    CONNECTED_JUMP_DOWN = 5, // one-way safe drop down
    CONNECTED_VAULT = 6, // mantle over waist-high obstacle
    CONNECTED_GAP_JUMP = 7, // horizontal running jump across gap
    CONNECTED_CROUCH = 8, // crouch-only passage
    CONNECTED_STEP_DOWN = 9, // small step down (pipe descent style)
    CONNECTED_BREAKABLE = 10, // blocked by breakable wall/door
    CONNECTED_CONDITIONAL = 11 // trigger/gate dependent
};

// Cost multiplier for each connection type, scaled by player capabilities.
// Lower = preferred. Costs encode: time, effort, risk of failure.
stock float GetConnectionCost(ConnectionType type)
{
    switch (type)
    {
        case CONNECTED_ADJACENT:   return 1.0;
        case CONNECTED_LADDER:     return 1.8;   // climb takes time
        case CONNECTED_ELEVATOR:   return 3.0;   // waiting time
        case CONNECTED_JUMP_UP:    return 3.0;   // jumping up is safe
        case CONNECTED_JUMP_DOWN:  return 1.5;   // dropping down is fast
        case CONNECTED_VAULT:      return 2.5;   // mantling takes effort
        case CONNECTED_GAP_JUMP:   return 5.0;   // running jump needs wind-up
        case CONNECTED_CROUCH:     return 2.0;   // crouch-walking is slow
        case CONNECTED_STEP_DOWN:  return 1.1;   // stepping down is easy
        case CONNECTED_BREAKABLE:  return 8.0;   // needs to be destroyed
        case CONNECTED_CONDITIONAL:return 25.0;   // needs trigger, uncertain
    }
    return 1.0;
}

// Connection to navArea
enum struct NavConnection
{
	Address navArea;
    ConnectionType connectiontype;
}

// Non-mesh edge: a player-traversable connection NOT present in the nav mesh
// Detected by spatial analysis during STAGE_PREP
enum struct NonMeshEdge
{
    int fromArea;          // navArea address (as int)
    int toArea;            // navArea address (as int)
    ConnectionType edgeType;
    float tpA[3];          // optional intermediate trace point A
    float tpB[3];          // optional intermediate trace point B
}

// ============================================================================
// Player capability model — defines what survivors can physically do.
// Replaces hardcoded constants scattered throughout jump/climb/vault detection.
// ============================================================================
enum struct PlayerCaps
{
    float max_walk_speed;      // 220.0 (survivor)
    float max_jump_height;     // 56.0 (crouch jump)
    float max_jump_distance;   // 200.0 (crouch jump at same height)
    float max_vault_height;    // 100.0 (mantle over obstacle)
    float max_safe_drop;       // 200.0 (no fall damage, matches DZ_TOO_LOW)
    float max_gap_jump;        // 280.0 (running jump across gap)
    float max_step_up;         // 18.0 (auto step-up)
    float max_crouch_height;   // 36.0 (crouch hull height)
    float gravity;             // 600.0
    float jump_velocity;       // 268.0
    bool can_swim;             // true
    bool can_ladder;           // true
    bool can_elevator;         // true
}
PlayerCaps g_Caps; // single global instance — all survivors share the same caps

void InitPlayerCaps()
{
    g_Caps.max_walk_speed    = 220.0;
    g_Caps.max_jump_height   = 56.0;
    g_Caps.max_jump_distance = 200.0;
    g_Caps.max_vault_height  = 100.0;
    g_Caps.max_safe_drop     = 200.0;  // matches DZ_TOO_LOW — no fall damage below this
    g_Caps.max_gap_jump      = 280.0;
    g_Caps.max_step_up       = 18.0;
    g_Caps.max_crouch_height = 36.0;
    g_Caps.gravity           = 600.0;
    g_Caps.jump_velocity     = 268.0;
    g_Caps.can_swim          = true;
    g_Caps.can_ladder        = true;
    g_Caps.can_elevator      = true;
}

// Portal between two adjacent nav areas — the shared boundary edge.
// Path waypoints should be portal centers, not area centers, so beams
// pass through actual doorways/corridor junctions instead of through walls.
enum struct PortalInfo
{
    float ep1[3];    // first endpoint of shared edge
    float ep2[3];    // second endpoint of shared edge
    float center[3]; // midpoint of shared edge (primary waypoint)
}

// Binary heap entry for A* priority queue
enum struct HeapEntry
{
    int nodeIndex;      // index into g_hAStarNodes
    float fScore;
    float gScore;
}

// ============================================================================
// A* State — persists across frames during distributed search
// ============================================================================
ArrayList g_hAStarNodes;       // all navArea addresses (int) — built once in STAGE_PREP
ArrayList g_hAStarCenters;     // parallel: float[3] center for each node
StringMap g_hAStarAreaToIndex; // "navAreaInt" → nodeIndex

// A* search state (indexed by nodeIndex)
ArrayList g_hAStarGScore;      // float per node
ArrayList g_hAStarCameFrom;    // int per node (parent nodeIndex, -1 = none)
ArrayList g_hAStarEdgeType;    // int per node (ConnectionType used)
ArrayList g_hAStarClosed;      // int per node (0 = open, 1 = closed)
ArrayList g_hAStarOpen;        // HeapEntry — binary heap priority queue

// A* targets and results
int g_aAStarGoal;              // goal navArea address (int)
int g_aAStarStart;             // start navArea address (int)
int g_iAStarGoalIndex;         // nodeIndex of goal
bool g_bAStarPathFound;        // true when goal reached
int g_iAStarBestIdx;           // best reachable node when goal unreachable (disconnected nav mesh)
float g_fAStarBestG;           // gScore of best reachable node
// int g_iAStarNodesThisFrame;    // unused
#define ASTAR_NODES_PER_FRAME 200

// v4.0 HPA* globals (declared here for single-pass compiler)
int g_iHPAClusterCount;

// v4.0 batched index building — prevents SIGALRM (stack/CPU overflow) on large maps
// by distributing AStar_BuildNodeIndex work across multiple frames.
int g_iBuildPhase;              // 0=basic index, 1=portals, 2=HPA, 3=bridges, 4=post-build init
int g_iPortalBatchIdx;          // current batch position in portal computation
#define PORTALS_PER_FRAME 250   // nav areas to process per frame for portal computation

// Spatial hash for fast nearby-area queries
StringMap g_hSpatialHash;      // "cx_cy_cz" → ArrayList of {navArea(int), center(float[3])}
#define SPATIAL_CELL_SIZE 256.0

// Non-mesh connection cache
ArrayList g_hNonMeshEdges;     // NonMeshEdge — all detected non-mesh connections

// Portal cache — shared-edge midpoints between adjacent nav areas
// Key: "minIdx_maxIdx" (canonical ordering), Value: PortalInfo
StringMap g_hPortalCache;

// GetNavConnections filter
#define CON_KEEP_ALL 0 // keep all adjacent connections
#define CON_KEEP_FORWARD 1 // keep only forward-going adjacent connections
#define CON_KEEP_BACKWARD 2 // keep only backwards-going adjacent connections

ArrayList g_GuideCells;
ArrayList g_bBeamWalkable; // hull trace validation: 1=walkable, 0=blocked by world geometry
ConVar g_hCvarMPGameMode, g_hCvarEnable, g_hCvarMax, g_hCvarSurvivors, g_hCvarInfected, g_hCvarSpec, g_hCvarBudget, g_hCvarDetourBudget, g_hCvarFinaleAuto, g_hCvarZM;
ConVar g_hCvarAutoEnable, g_hCvarAutoDuration, g_hCvarAutoInterval;
ConVar g_hCvarGapDzMax, g_hCvarGapXyRatio, g_hCvarBeamMinDist, g_hCvarGapVertical, g_hCvarStitchSteps, g_hCvarTraceHull, g_hCvarNonMesh;
// v4.0 new cvars
ConVar g_hCvarFunnel3D, g_hCvarFunnelZStep;
ConVar g_hCvarRepairEnable, g_hCvarRepairAttempts;
ConVar g_hCvarBeaconEnable;
ConVar g_hCvarThetaStar, g_hCvarThetaLosMax;
ConVar g_hCvarHpaEnable, g_hCvarHpaCellSize;
ConVar g_hCvarFlowWeight, g_hCvarZCostFactor;
Handle g_hAutoTimer = null;
Handle g_hAutoCheckTimer = null;
bool gamemode_guidable, guide_ready, guide_prep, map_started, nav_started, enable, g_bL4D2, finale, finale_rescue, finale_gauntlet;
bool g_bGlobalBeams = false; // When true, DrawBeam sends to all clients (auto-guide mode)

// Forward-declare optional newer left4dhooks natives (may not be in server's include)
enum NavCornerType {
    NAV_CORNER_NORTH_WEST = 0,
    NAV_CORNER_NORTH_EAST = 1,
    NAV_CORNER_SOUTH_EAST = 2,
    NAV_CORNER_SOUTH_WEST = 3
};
native float L4D_NavArea_GetZ(Address area, const float pos[3]);
native int L4D_NavArea_GetElevator(Address area);
native void L4D_NavArea_GetCorner(Address area, NavCornerType corner, float pos[3]);
native int L4D_NavArea_GetLadder(Address area, ArrayList ladderList);
int g_iLaser, g_iLaserCustom, g_iLaserWhite;
float t_nav = -1.0; // nav event gametime
Handle timer_nav;
//char mapName[PLATFORM_MAX_PATH];
char g_sCustomKeys[MAXPLAYERS+1][PLATFORM_MAX_PATH]; // customization keys -> modify DrawBeam
float g_BeamDelay[MAXPLAYERS+1];

DynamicDetour g_hRecomputeFlowDetour;
Handle g_hRecomputeFlow;
bool g_bFlowRecomputeHooked;

bool finale_stitched; // finale guide was drawn
bool finale_backwards; // rescue vehicle is not at max flow -> flow cannot be used for guiding

bool elevator_available, blocked_available; // check fi l4dhooks is up to date

ConVar g_hCvarFinale;
#define FINALE_ALWAYS 0 
#define FINALE_STARTED 1
#define FINALE_RESCUE 2
#define FINALE_NEVER 3
bool g_bFoundRescueVehicle;
float g_fMaxFlow, g_fFlowRescueVehicle;

int color_forward[4] = {25,255,25,255};
int color_backward[4] = {128,10,10,128};

//bool g_bHitLadder = false; // kill me
#if DEBUG
int g_iHitEntity, g_iHitSurfaceProps, g_iHitSurfaceFlags;
char g_sHitSurfaceName[64];
#endif

bool is_prep_cooldown() // Prevent Guide_Prep() from firing if navmesh just changed
{
    if (t_nav<=0.0 || finale_rescue) return false;
    if ((t_nav+NAV_COOLDOWN)>GetGameTime()) return true;
    return false;
}

void GetCvars()
{
    if (enable != g_hCvarEnable.BoolValue)
    {
        enable = g_hCvarEnable.BoolValue;
        if (!enable && guide_ready) Guide_Cleanup();
        beams_cooldown_reset(_,true); // reset all requests and cooldowns
    }
}

// Player cooldown
enum struct PlayerTime
{
	float t_engine;
    float t_game;
    float t_cooldown;
}
PlayerTime g_PlayerTime[MAXPLAYERS+1];

// Data structure for requests to draw beams
enum struct CellRequest
{
	float duration;
    bool backward;
	bool join_client;
}
CellRequest g_CellRequests[MAXPLAYERS+1];

// Check if any client has a request queued after nav cooldown has expired or guide is ready to draw beams.
Action Timer_CheckRequests(Handle timer = null)
{
    // If both handles are null, allow to pass. Otherwise only allow expected handle through.
    if ( (timer != null || timer_nav != null) &&  timer != timer_nav) return Plugin_Stop;
    float t_left = (t_nav+NAV_COOLDOWN) - GetGameTime();
    if (t_left>0.0)
    {
        if (t_left<0.1) t_left = 0.1;
        timer_nav = CreateTimer(t_left,Timer_CheckRequests,_,TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }
    timer_nav = null;
    #if DEBUG>1
    LogMessage("Timer_CheckRequests");
    #endif
    if (!enable || !map_started || !nav_started || !gamemode_guidable || g_iLaser==0 || guide_prep) return Plugin_Stop;

    for (int i = 1; i <= MaxClients; i++) // Draw beams immediately for pending clients
    {
        if (g_CellRequests[i].duration <= 0.0) continue;
        if (!IsValidClient(i) || IsFakeClient(i))
        {
            g_CellRequests[i].duration = -1.0;
            continue;
        }
        if (guide_ready)
        {
            static CellRequest request;
            request = g_CellRequests[i];
            RequestGuide(i,request.duration,request.backward,request.join_client);
        }
        else
        {
            Guide_Prep();
            break;
        }
    }
    return Plugin_Stop;
}

// Draw beams for all clients. Use client's last duration for RequestGuide if available, or override=true to force duration.
void Guide_All_Clients(float duration = 5.0, bool override = false)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_CellRequests[i].duration>=0.1) continue; // already requested
        if (!override && g_PlayerTime[i].t_cooldown>0.1) g_CellRequests[i].duration = g_PlayerTime[i].t_cooldown*2.0;
        else g_CellRequests[i].duration = duration;
    }
    Timer_CheckRequests(null);
}

Action Timer_Guide_All_Clients(Handle timer = null, float duration = 5.0)
{
    Guide_All_Clients(duration);
    return Plugin_Continue;
}

// Use Gauntlet-type logic for stitching escape route with rescue vehicle.
bool use_gauntlet_logic()
{
    if (!finale) return false;
    return finale_gauntlet || g_hCvarFinale.IntValue == FINALE_ALWAYS;
}

int g_iClosestFlow, g_iClosestDist, g_iStart; // closest cell by flow, by distance, and final determination.
float g_RequestFirstPos[3]; // for hint system
float g_fRequestFlow; // for hint system
int g_iForward, g_iBackward; // temporary cell position for green and red beams

// Draw survivor path for client, for duration in seconds
// backward: include backwards-going path.
// join_client: draw connection between client's origin and nearest point in survivor path.
// return true if beams were drawn
bool RequestGuide(int client, float duration = 5.0, bool backward = false, bool join_client = true)
{
    #if DEBUG
    float t = GetEngineTime();
    #endif
    if (!enable || !map_started || !nav_started || !gamemode_guidable || duration<=0.0 || g_iLaser==0 || !IsValidClient(client) || IsFakeClient(client)) return false;

    int team = GetClientTeam(client);
    bool alive = IsPlayerAlive(client);

    bool whitelist = false; // L4D2 Zombie Master whitelist
    if (g_bL4D2 && g_hCvarZM!=null && g_hCvarZM.BoolValue && team!=TEAM_SURVIVOR)
    {
        whitelist = team==TEAM_INFECTED;
        if (!whitelist)
        {
            static char targetName[16];
            GetEntPropString(client, Prop_Data, "m_iName", targetName, sizeof(targetName));
            whitelist = strncmp(targetName,"zm_client",9,false) == 0;
        }
    }

    if (!whitelist) // Check if player is blocked from drawing beams
    {
        switch (team) // Check team
        {
            case TEAM_SPECTATOR:
            {
                if (!g_hCvarSpec.BoolValue) return false;
            }
            case TEAM_SURVIVOR:
            {
                if (!g_hCvarSurvivors.BoolValue) return false;
            }
            case TEAM_INFECTED:
            {
                if (!g_hCvarInfected.BoolValue) return false;
            }
        }

        if (g_hCvarAlive.IntValue>0) // 0 -> all states allowed
        {
            switch (alive)
            {
                case true:
                {
                    if (g_hCvarAlive.IntValue == ACCEPT_DEAD) return false; // only accepts dead players
                }
                default:
                {
                    if (g_hCvarAlive.IntValue == ACCEPT_ALIVE) return false; // only accepts alive players
                }
            }
        }
    }

    if (beams_cooldown(client)) return false;
    if (duration < 0.1) duration = 0.1; // prevent beams with infinite lifetime
    beams_cooldown_update(client,duration);

    // Store info of latest request from client
    g_CellRequests[client].join_client = join_client;
    g_CellRequests[client].duration = duration;
    g_CellRequests[client].backward = backward;
    g_BeamDelay[client] = 0.0;

    if (!guide_ready)
    {
        Guide_Prep();
        if (!guide_ready || g_GuideCells==null) return false;
    }
    else if (g_GuideCells==null || g_GuideCells.Length<=0) return false;

    static float last_pos[3], origin[3];

    bool self_origin = true;
    int target = client;
    if (!alive) // Check who their chase camera is set to. Take that origin instead.
    {
        int observermode = GetEntProp(client, Prop_Send, "m_iObserverMode");
        if (observermode==4 || observermode==5)
        {
            target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
            if (IsValidEntity(target) && target!=INVALID_ENT_REFERENCE)
            {
                self_origin = false;
                if (IsValidClient(target)) alive = IsPlayerAlive(target);
            }
            else target = client;
        }
    }
    GetEntPropVector(target, Prop_Send, "m_vecOrigin", origin);
    float flow = L4D_GetFlowFromPoint(origin);

    g_iStart = -1;
    g_iClosestFlow = -1;
    g_iClosestDist = -1;

    Address navArea = L4D_GetNearestNavArea(origin,500.0,true,alive,false,TEAM_SURVIVOR);
    if (navArea != Address_Null)
    {
        g_iClosestFlow = g_GuideCells.FindValue(navArea,1);
        g_iStart = g_iClosestFlow;
        if (flow<=0.0)
        {
            L4D_GetNavAreaCenter(navArea,last_pos);
            flow = L4D_GetFlowFromPoint(last_pos);
        }
    }
    g_fRequestFlow = flow;

    last_pos = origin;
    if (alive || !self_origin) last_pos[2] += 16.0;
    if (alive)
    {
        switch (GetEntProp(target, Prop_Send, "m_nWaterLevel"))
        {
            case 1: last_pos[2] += 16.0;
            case 2: last_pos[2] += 32.0;
        }
    }
    else if (self_origin) last_pos[2] -= 16.0; // origin is client eye pos

    static Cell cell;

    bool use_flow = flow>0.0 && flow<=g_fMaxFlow && ( !finale_stitched || !finale_backwards || (use_gauntlet_logic() && flow<g_fFlowRescueVehicle) ); 

    if (g_iStart<0) // if we aren't standing on a guide cell, search all guide cells.
    {
        float min_dist = -1.0;
        float min_dist_flow = -1.0;
        float dist, dist_flow;
        for (int i = 0; i < g_GuideCells.Length; i++)
        {
            g_GuideCells.GetArray(i,cell,sizeof(Cell));
            bool end = true;
            //bool vecdist = false;
            if (min_dist<0.0 || min_dist>256.0) // end if very close cell already found
            {
                end = false;
                dist = GetVectorDistance(last_pos,cell.center,true);
                //vecdist = true;
                if (min_dist<0.0 || dist<min_dist)
                {
                    min_dist = dist;
                    g_iClosestDist = i;
                }
            }
            if (use_flow && min_dist_flow!=0.0) // exact flow match means we found the cell already
            {
                end = false;
                dist_flow = FloatAbs(cell.flow - flow);
                //if (vecdist && dist>(dist_flow*dist_flow)) continue;
                if (min_dist_flow<0.0 || dist_flow<min_dist_flow)
                {
                    min_dist_flow = dist_flow;
                    g_iClosestFlow = i;
                }
            }
            if (end) break;
        }
    }

    if (g_iClosestFlow==g_iClosestDist)
    {
        g_iClosestFlow = -1;
        g_iStart = g_iClosestDist;
    }
    else
    {
        g_iStart = (g_iClosestFlow>=0) ? g_iClosestFlow : g_iClosestDist;
    }
    g_iForward = g_iStart;
    g_iBackward = g_iStart;
    int i_draw = 0; // how many beams were drawn

    // Try cell splitting technique first. If it fails try usual LOS adjustments
    static float pos_split[3];
    bool LOS = false;
    bool found_split = try_guide_cellsplit(last_pos,pos_split,g_iForward) && twopos_traversable(last_pos,pos_split);
    if (found_split)
    {
        if (g_iForward>=g_GuideCells.Length) g_iForward = g_GuideCells.Length - 1;
        g_iBackward = g_iForward - 1;
        if (join_client) i_draw += DrawBeam(client,last_pos,pos_split,duration,color_forward,256.0);
        g_GuideCells.GetArray(g_iForward,cell,sizeof(Cell));
        i_draw += DrawBeam(client,pos_split,cell.center,duration,color_forward);
        if (backward && g_iBackward>=0)
        {
            g_GuideCells.GetArray(g_iBackward,cell,sizeof(Cell));
            i_draw += DrawBeam(client,cell.center,pos_split,duration,color_backward);
        }
        last_pos = pos_split;
        LOS = true;
        g_iStart = g_iForward;
    }

    if (!LOS) LOS = cell_traversable(g_iStart,last_pos);

    // Try starting at a more reasonable position with LOS
    if (!found_split)
    {
        if ( (join_client || !LOS) && (g_iStart+1)<g_GuideCells.Length && cell_traversable(g_iStart+1,last_pos,_,250.0))
        {
            g_iStart += 1; // Move forward
            LOS = true;
        }
        else if (g_iStart>0 && !LOS && cell_traversable(g_iStart-1,last_pos,_,250.0))
        {
            g_iStart -=1; // Move backward
            LOS = true;
        }
        g_iForward = g_iStart;
        g_iBackward = g_iStart;
    }

    g_GuideCells.GetArray(g_iForward,cell,sizeof(Cell));

    if (join_client) // Connect client to starting cell
    {
        int num_beams = (!LOS && navArea!=Address_Null) ? detour_join(client,navArea,last_pos,flow,duration,team) : 0;
        if (num_beams<=0)
        {
            if (!found_split && GetVectorDistance(last_pos,cell.center,true)>=256.0)
            {
                DrawBeam(client,last_pos,cell.center,duration,color_forward);
                i_draw += 1;
            }
            g_RequestFirstPos = cell.center;
        }
        else
        {
            g_GuideCells.GetArray(g_iForward,cell,sizeof(Cell)); // detour_join may have changed g_iForward
            i_draw += num_beams;
        }
    }
    if (i_draw<g_hCvarMax.IntValue) // detour_join may have hit beam limit
    {
        static float pos_forward[3], pos_backward[3];
        g_GuideCells.GetArray(g_iForward,pos_forward,3,2);
        g_GuideCells.GetArray(g_iBackward,pos_backward,3,2);
        bool end = false;
        while (!end && i_draw<g_hCvarMax.IntValue)
        {
            end = true;
            if ((g_iForward+1)<g_GuideCells.Length)
            {
                g_iForward += 1;
                g_GuideCells.GetArray(g_iForward,cell,sizeof(Cell));
                DrawBeam(client,pos_forward,cell.center,duration,color_forward);
                pos_forward = cell.center;
                end = false;
                i_draw += 1;
                if (i_draw>=g_hCvarMax.IntValue) break;
            }
            if (backward && g_iBackward>0)
            {
                g_iBackward -= 1;
                g_GuideCells.GetArray(g_iBackward,cell,sizeof(Cell));
                DrawBeam(client,cell.center,pos_backward,duration,color_backward);
                pos_backward = cell.center;
                end = false;
                i_draw += 1;
            }
        }
    }
    if (i_draw>0)
    {
        #if DEBUG
        LogMessage("RequestGuide: client %d flow %f cells %d g_iStart %d (%f ms)", client, flow, i_draw, g_iStart, (GetEngineTime()-t)*1000.0);
        #endif
        return true;
    }
    return false;
}

ArrayList i_candidates,i_explored;

// See if pos can be connected to a split inbetween two cells. return true on success
// Outputs pos_split, and sets correct i_forward (closest first green cell)
stock bool try_guide_cellsplit(float pos[3],float pos_split[3], int &i_forward)
{
    if (g_GuideCells.Length<=1) return false;
    if (i_candidates==null) i_candidates = new ArrayList();
    if (i_explored==null) i_explored = new ArrayList();
    i_candidates.Clear();
    i_explored.Clear();

    // Each index in i_candidates will be g_iBackward from which split is drawn towards i_forward
    if (g_iClosestFlow>=0)
    {
        if (g_iClosestFlow < (g_GuideCells.Length-1)) i_candidates.Push(g_iClosestFlow);
        if (g_iClosestFlow>0) i_candidates.Push(g_iClosestFlow-1);
        if (g_iClosestDist < 0) // search more
        {
            if (g_iClosestFlow < (g_GuideCells.Length-2)) i_candidates.Push(g_iClosestFlow+1);
            if (g_iClosestFlow>1) i_candidates.Push(g_iClosestFlow-2);
        }
    }
    if (g_iClosestDist>=0 && g_iClosestDist!=g_iClosestFlow)
    {
        if (g_iClosestDist < (g_GuideCells.Length-1)) i_candidates.Push(g_iClosestDist);
        if (g_iClosestDist>0) i_candidates.Push(g_iClosestDist-1);
        if (g_iClosestFlow < 0) // search more
        {
            if (g_iClosestDist < (g_GuideCells.Length-2)) i_candidates.Push(g_iClosestDist+1);
            if (g_iClosestDist>1) i_candidates.Push(g_iClosestDist-2);
        }
    }

    float dist;
    float best_dist = -1.0;
    static float pos_temp[3], pos_start[3], pos_end[3];
    int i_cell, i_forward_best;
    for (int i = 0; i < i_candidates.Length; i++)
    {
        i_cell = i_candidates.Get(i);
        if (i_explored.FindValue(i_cell)>=0) continue;
        i_explored.Push(i_cell);
        g_GuideCells.GetArray(i_cell,pos_start,3,2);
        dist = GetVectorDistance(pos,pos_start,true);
        if (best_dist<0.0 || dist<best_dist)
        {
            i_forward_best = i_cell+1; pos_split = pos_start;
            best_dist = dist; if (best_dist<=256.0) break; // if very close to client position, we found our answer
        }
        g_GuideCells.GetArray(i_cell+1,pos_end,3,2);
        dist = GetVectorDistance(pos,pos_end,true);
        if (best_dist<0.0 || dist<best_dist)
        {
            i_forward_best = i_cell+1+1; pos_split = pos_end;
            best_dist = dist; if (best_dist<=256.0) break; // if very close to client position, we found our answer
        }
        if (!project_forward(pos_start,pos_end,pos,pos_temp)) continue;
        dist = GetVectorDistance(pos,pos_temp,true);
        if (best_dist<0.0 || dist<best_dist)
        {
            i_forward_best = i_cell+1; pos_split = pos_temp;
            best_dist = dist; if (best_dist<=256.0) break; // if very close to client position, we found our answer
        }
    }
    if (best_dist>=0.0)
    {
        i_forward = i_forward_best;
        return true;
    }
    return false;
}

// Find closest guide cell for given flow value. 
// If check_LOS, wiggle cell forward/backward to improve LOS for given vector position
int get_flow_iStart(float flow, bool check_LOS = true, float pos[3])
{
    int i_start = 0;
    static Cell cell;
    for (int i = 0; i < g_GuideCells.Length; i++)
    {
        g_GuideCells.GetArray(i,cell,sizeof(Cell));
        if ( cell.flow >= flow )
        {
            i_start = i;
            break;
        }
    }
    if (check_LOS)
    {
        if ((i_start+1)<g_GuideCells.Length && cell_traversable(i_start+1,pos,_,250.0))
        {
            i_start += 1; // Move forward
        }
        else if (i_start>0 && !cell_traversable(i_start,pos) && cell_traversable(i_start-1,pos,_,250.0))
        {
            i_start -=1; // Move backward
        }
    }
    return i_start;
}

ArrayList ConAdj, AdjNN, queue;
ArrayList explored;

// detour client_join, return how many beams were drawn
int detour_join(int client, Address navArea, float pos[3], float flow, float duration, int team = TEAM_SURVIVOR)
{
    float t = GetEngineTime();
    #if DEBUG>1
    LogMessage("detour_join %f", flow);
    #endif

    float budget = g_hCvarDetourBudget.FloatValue;

    float flow_target = g_fMaxFlow;
    bool explore_backwards = false;
    if (finale && finale_stitched && finale_backwards)
    {
        explore_backwards = true;
        flow_target = g_fFlowRescueVehicle;
    }

    static float pos_curr[3], pos_last[3];
    float flow_curr = flow;
    float d_flow_curr = FloatAbs(flow-flow_target);
    pos_curr = pos;
    if (ConAdj==null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN==null) AdjNN = new ArrayList(); // nearest neighbor explore for dips in flow when about to climb a ladder
    if (queue==null) queue = new ArrayList(3);
    if (explored==null) explored = new ArrayList();
    explored.Clear();
    queue.Clear();
    queue.PushArray(pos);
        
    Address navArea_curr = navArea;
    float flow_temp, flow_best, dz, dz_best, d_flow_temp;
    static float pos_temp[3], pos_best[3], pos_split[3], pos_end[3];
    Address navArea_best;
    bool best_steep = false;
    float d_flow_best = d_flow_curr;
    int i;
    static Cell cell;
    int i_found;

    bool success = false;
    while (navArea_curr != Address_Null)
    {
        bool found = false;
        flow_best = flow_curr;
        d_flow_best = d_flow_curr;
        best_steep = false; 
        int count = GetNavConnections(navArea_curr,ConAdj,team,true,true,true,CON_KEEP_FORWARD);
        static NavConnection nav_connection;
        for (i = 0; i < count; i++)
        {
            ConAdj.GetArray(i,nav_connection,sizeof(NavConnection));
            if (nav_connection.navArea == Address_Null || nav_connection.connectiontype <= CONNECTED_NOT) continue;
            if (nav_connection.navArea == navArea_curr) continue;
            if (explored.FindValue(nav_connection.navArea)>=0) continue;
            explored.Push(nav_connection.navArea);
            if (blocked_available && L4D_NavArea_IsBlocked(nav_connection.navArea,team,true)) continue;
            flow_temp =  L4D2Direct_GetTerrorNavAreaFlow(nav_connection.navArea);
            d_flow_temp = FloatAbs(flow_temp-flow_target);
            #if DEBUG>1
                LogMessage("detour_join %d %.1f try %d %d %.1f", navArea_curr, flow_curr, nav_connection.connectiontype, nav_connection.navArea, flow_temp);
            #endif
            int count2 = navArea_ladder_navAreas(nav_connection.navArea,AdjNN,team); // ladder intervention. flow dips when stepping onto ladder navmeshes...
            for (int i2 = 0; i2 < count2; i2++)
            {
                Address adjArea = AdjNN.Get(i2);
                if (adjArea == Address_Null || adjArea == navArea_curr || adjArea == nav_connection.navArea) continue;
                float new_flow = L4D2Direct_GetTerrorNavAreaFlow(adjArea);
                float new_d_flow = FloatAbs(new_flow-flow_target);
                if (new_d_flow<d_flow_temp)
                {
                    #if DEBUG>1
                    LogMessage("Ladder intervention %.1f -> %.1f", flow_temp, new_flow);
                    #endif
                    d_flow_temp = new_d_flow;
                }
            }
            if (d_flow_temp>d_flow_curr) continue;
            L4D_GetNavAreaCenter(nav_connection.navArea,pos_temp); pos_temp[2] += 16.0;
            dz = pos_temp[2] - pos_curr[2];
            bool steep = nav_connection.connectiontype == CONNECTED_ADJACENT && nav_too_steep(navArea_curr,nav_connection.navArea);
            if (found && steep)
            {
                if (!best_steep || dz>dz_best)
                {
                    #if DEBUG>1
                    LogMessage("detour_join steep or dz skip");
                    #endif
                    continue; // prefer to go down than up
                }
            }
            else if (!steep)
            {
                int spawnAttrs = L4D_GetNavArea_SpawnAttributes(nav_connection.navArea);
                success = (!explore_backwards && spawnAttrs & NAV_SPAWN_ESCAPE_ROUTE) || (finale_stitched && spawnAttrs & NAV_SPAWN_RESCUE_VEHICLE);
            }
            if ( success || d_flow_temp<=d_flow_best || (best_steep && d_flow_temp<=d_flow_curr ) )
            {
                flow_best = flow_temp;
                d_flow_best = d_flow_temp;
                navArea_best = nav_connection.navArea;
                pos_best = pos_temp;
                found = true;
                best_steep = steep;
                dz_best = dz;
                if (success) break;
            }
        }

        if (!found) // Try searching for unconnected ladders in vicinity
        {
            if (try_ladder(flow_curr,pos_curr,cell))
            {
                found = true;
                flow_best = cell.flow;
                navArea_best = cell.navArea;
                pos_best = cell.center;
            }
        }

        if (found)
        {
            if (pos_underwater(pos_best))
            {
                pos_best[2] += 16.0;
                if (pos_underwater(pos_best)) pos_best[2] += 16.0;
            }
            bool LOS = twopos_traversable(pos_curr,pos_best);
            if (!LOS)
            {
                static float pos_lifted[3];
                pos_lifted = pos_best;
                pos_lifted[2] += 16.0;
                LOS = twopos_traversable(pos_curr,pos_lifted);
                if (LOS) pos_best = pos_lifted;
            }
            if (!LOS)
            {
                static float pos_mid[3];
                if (LOS_rescue_cheap(pos_curr,pos_best,pos_mid)) queue.PushArray(pos_mid);
                else if (queue.Length == 1) // Try nav center of client origin
                {
                    L4D_GetNavAreaCenter(navArea,pos_mid);
                    pos_mid[2] += 16.0;
                    if (pos_underwater(pos_mid)) pos_mid[2] += 32.0;
                    if (twopos_traversable(pos_curr,pos_mid) && twopos_traversable(pos_best,pos_mid)) queue.PushArray(pos_mid);
                }
                queue.PushArray(pos_best);
            }
            else if (queue.Length>1)
            {
                queue.GetArray(queue.Length-2,pos_last,3);
                if (twopos_traversable(pos_best,pos_last) && midpoint_valid_ground(pos_last,pos_best)) queue.SetArray(queue.Length-1,pos_best,3);
                else queue.PushArray(pos_best);
            }
            else queue.PushArray(pos_best);
            #if DEBUG>1
            LogMessage("detour_join found %d %.1f -> %d %.1f", navArea_curr, flow_curr, navArea_best, flow_best);
            #endif
            pos_curr = pos_best;
            navArea_curr = navArea_best;
            flow_curr = flow_best;
            d_flow_curr = d_flow_best;
            
            i_found = g_GuideCells.FindValue(navArea_best,1);
            if (!success)
            {
                success = i_found>=0;
                if (!success)
                {
                    success = !explore_backwards && queue.Length >= g_hCvarMax.IntValue;
                    if (!success)
                    {
                        int spawnAttrs = L4D_GetNavArea_SpawnAttributes(navArea_curr);
                        success = (!explore_backwards && spawnAttrs & NAV_SPAWN_ESCAPE_ROUTE) || (finale_stitched && spawnAttrs & NAV_SPAWN_RESCUE_VEHICLE);
                    }
                }
            }
            if (success)
            {
                g_iStart = (i_found>=0) ? i_found : get_flow_iStart(flow_curr,true,pos_curr);
                g_iClosestFlow = g_iStart;
                g_iClosestDist = g_iStart;
                if (i_found<0 && try_guide_cellsplit(pos_curr,pos_split,g_iForward) && twopos_traversable(pos_curr,pos_split))
                {
                    g_iBackward = g_iForward - 1;
                    g_iStart = g_iForward;
                }
                else
                {
                    g_iForward = g_iStart; g_iBackward = g_iStart;
                }
                #if DEBUG>1
                LogMessage("detour_join success flow %f i_forward %d i_backward %d", flow_curr, g_iForward, g_iBackward);
                #endif
                g_GuideCells.GetArray(g_iForward,cell,sizeof(Cell));
                if (g_iForward == g_iBackward) pos_end = cell.center;
                else pos_end = pos_split;
                if (queue.Length>1 && twopos_traversable(pos_curr,pos_end))
                {
                    queue.GetArray(queue.Length-2,pos_last,3);
                    if (twopos_traversable(pos_last,pos_end)) queue.Erase(queue.Length-1);
                }
                break;
            }
        }

        if (!found || success) break;

        if ( budget>0.0 && ((GetEngineTime()-t)*1000.0)>budget )
        {
            #if DEBUG
            LogMessage("detour_join exceeded budget");
            #endif
            break;
        }

    }

    int beams = 0; 
    if (success) // Path found, draw beams.
    {
        queue.GetArray(0,pos_curr,3);
        for (i = 1; i < queue.Length; i++)
		{
			queue.GetArray(i,pos_temp,3);
            beams += DrawBeam(client,pos_curr,pos_temp,duration,color_forward);
            pos_curr = pos_temp;
            if (beams==1) g_RequestFirstPos = pos_curr;
            if (beams>=g_hCvarMax.IntValue) break;
        }
        if (beams<g_hCvarMax.IntValue)
        {
            if (g_iForward==g_iBackward) beams += DrawBeam(client,pos_curr,pos_end,duration,color_forward);
            else
            {
                beams += DrawBeam(client,pos_curr,pos_split,duration,color_forward);
                beams += DrawBeam(client,pos_split,cell.center,duration,color_forward);
                if (g_CellRequests[client].backward && g_iBackward>=0)
                {
                    g_GuideCells.GetArray(g_iBackward,cell,sizeof(Cell));
                    beams += DrawBeam(client,cell.center,pos_split,duration,color_backward);
                }
            }
        }
    }

    #if DEBUG
    LogMessage("detour_join %f ms, %d beams", (GetEngineTime()-t)*1000.0, beams);
    #endif

    return beams;
}

// Data structure for beam client preferences
//enum struct GuidePref
//{
//	int ModelIndex;
//    int HaloIndex;
//    float duration;
//    float amp;
//    float start_width;
//    float end_width;
//    int color_forward[4];
//    int color_backward[4];
//    void Init()
//    {
//        this.ModelIndex = g_iLaser;
//        this.HaloIndex = 0;
//        this.duration = 5.0;
//        this.amp = 0.0;
//        this.start_width = 1.5;
//        this.end_width = 1.5;
//        this.color_forward = color_forward;
//        this.color_backward = color_backward;
//    }
//}

//GuidePref g_GuidePrefs[MAXPLAYERS+1];

// Draw beam with given color for client from pos_start to pos_end for duration. Don't draw if distance squared is below min_dist_sq.
// Return number of drawn beams.
int DrawBeam(int client, float pos_start[3], float pos_end[3], float duration = 5.0, int color[4] = {25,255,25,255}, float min_dist_sq = -1.0)
{
    if (g_iLaser==0) return 0;
    if (min_dist_sq>0.0 && GetVectorDistance(pos_start,pos_end,true)<min_dist_sq) return 0;
    if (duration<0.1) duration = 0.1;
    float start_width = 1.5;
    int fade_length = 10;
    float amp = 0.0;
    
    // Set .vmt to draw
    int laser = g_iLaser;
    if (g_sCustomKeys[client][0]!=0)
    {
        if (g_sCustomKeys[client][0]=='c' && g_iLaserCustom!=0) laser = g_iLaserCustom;
        else if (g_sCustomKeys[client][0]=='w' && g_iLaserWhite!=0) laser = g_iLaserWhite;
    }
    
    // Set "shake"
    if (g_sCustomKeys[client][1]=='s') amp = 1.0;
    
    // Set thickness
    if (g_sCustomKeys[client][2]!=0)
    {
        if (g_sCustomKeys[client][2]=='l') start_width *= 2.0; // large
        else if (g_sCustomKeys[client][2]=='s') start_width /= 2.0; // small
    }

    // Set "arrow"
    float end_width = start_width*1.05;
    if (g_sCustomKeys[client][3]=='a')
    {
        start_width /= 1.25;
        end_width = 1.5*start_width;
    }

    #if DEBUG>2
    LogMessage("client %d duration %f laser %d custom %s", client, duration, laser, g_sCustomKeys[client]);
    #endif
    TE_SetupBeamPoints(pos_start,pos_end,laser,0,0,0,duration,start_width,end_width,fade_length,amp,color,0);
    if (g_bGlobalBeams)
        TE_SendToAll();
    else
        TE_SendToClient(client,g_BeamDelay[client]);
    if (g_sCustomKeys[client][4]=='d') g_BeamDelay[client] += 0.05;
    return 1;
}

void Check_Guidable()
{
    gamemode_guidable = !L4D_IsSurvivalMode();
    if (gamemode_guidable && g_bL4D2) gamemode_guidable = !L4D2_IsScavengeMode();
    if (!map_started || !nav_started) return;
    if (guide_ready && !gamemode_guidable) Guide_Cleanup();
}

#define STAGE_NONE 0 // Prep not running
#define STAGE_PREP 1 // Initialize, get max flow, build node index, identify start/goal
#define STAGE_ASTAR 2 // A* search distributed across frames
#define STAGE_SMOOTH 3 // Reconstruct path, Theta* smooth, output to g_GuideCells
#define STAGE_JOIN 4 // Connect rescue vehicle to guide path
#define STAGE_VALIDATE 5 // Hull trace validation — 8-strategy checks against world geometry
#define STAGE_REPAIR 6 // v4.0: Auto-repair blocked beams (Z-step, offset, subdivide, local A*)
#define STAGE_END 7 // Guide ready.
// Legacy stages retained for backwards compat with old code paths (kept as aliases)
#define STAGE_COLLECT 99 // deprecated — was "collect ESCAPE_ROUTE areas"
#define STAGE_SORT 99    // deprecated — was "sort by flow"
#define STAGE_FIX 99     // deprecated — was "stitch gaps"
#define STAGE_BUILD 99   // deprecated — was "build guide cells"
#define STAGE_FINALE STAGE_JOIN // renumbered

int g_iPrepStage, g_iLoop;
float g_tFrameStart;
ArrayList RescueVehicleCells;
Address g_aNavRescueVehicle;
// Legacy pipeline vars (no longer used by A* pipeline, retained for compat)
// float g_fFlowStart, g_fFlowCheckpoint;
// ArrayList allAreas, all_cells;
// bool g_bMissingStart, g_bMissingCheckpoint, g_bFoundStart, g_bFoundCheckpoint;
// Address g_aNavStart, g_aNavCheckpoint;


#if DEBUG
float g_fPrepTotalTime;
int g_iPrepFrames, g_iErased, g_iNavBlocked, g_iTotalCollected, g_iTighten;
#endif

void Guide_Prep()
{
    if (!enable || !gamemode_guidable || !map_started || !nav_started || guide_prep || is_prep_cooldown()) return;
    #if DEBUG>1
    LogMessage("Guide_Prep");
    #endif
    guide_prep = true;
    g_iPrepStage = STAGE_PREP;
    #if DEBUG
    g_iPrepFrames = 0;
    #endif
    timer_nav = null;
    OnFramePrep(true);
}

void Guide_Cleanup()
{
    g_iPrepStage = STAGE_NONE; // tell guide prep to cancel
    if (guide_ready)
    {
        #if DEBUG>1
        LogMessage("Guide_Cleanup");
        #endif
        guide_ready = false;
        delete g_GuideCells;
        delete g_bBeamWalkable;
    }
}

// ==========================================================================================
// v2.2 Hull Trace Validation — Multi-strategy with edge-case fallbacks
//
// Simulates a player navigating between nav cells. Uses a cascading series of
// progressively more permissive hull traces to handle edge cases:
//
//   1. MID HULL  (44h,  lift 28) — default crouch-walk posture
//   2. MID HULL  (44h,  lift 48) — steeper lift for staircases
//   3. LOW HULL  (32h,  lift 28) — vent / crawlspace
//   4. LOW HULL  (32h,  lift 48) — crawl + stair combo
//   5. SIDE A    (44h,  lift 28, offset +18u right)
//   6. SIDE B    (44h,  lift 28, offset -18u left)
//   7. SUBDIVIDE — split into 3 shorter segments, trace mid hull each
//
// Only world BSP geometry (entity==0) blocks; doors/breakables pass through.
// First success = walkable. All seven fail = beam blocked (real wall).
//
// Performance: one-time computation when guide cells are built. Typical map
// of 75 beams × avg 2 traces = ~150 hull traces total (~3ms).
// ==========================================================================================

public bool TraceFilter_WorldOnly(int entity, int contentsMask, any data)
{
    return (entity == 0); // only collide with world BSP geometry
}

// Single hull test helper — returns true if walkable
bool TryHull(float start[3], float end[3], const float mins[3], const float maxs[3])
{
    TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, TraceFilter_WorldOnly);
    return !TR_DidHit();
}

// Offset a point perpendicular to the travel direction
void OffsetPerpendicular(float start[3], float end[3], float offset, float result[3])
{
    float dir[3], perp[3];
    dir[0] = end[0] - start[0];
    dir[1] = end[1] - start[1];
    dir[2] = 0.0;
    float len = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1]);
    if (len < 1.0) { result = start; return; }
    perp[0] = -dir[1] / len * offset;
    perp[1] =  dir[0] / len * offset;
    perp[2] = 0.0;
    result[0] = start[0] + perp[0];
    result[1] = start[1] + perp[1];
    result[2] = start[2];
}

// Async hull trace state — shared between Guide_ValidateWalkable and its frame callback.
// Processing in batches of BATCH_SIZE per frame avoids main-thread stalls on
// maps with thousands of nav cells (fallback path can collect 5000+ cells).
#define VALIDATE_BATCH 30
int g_vi;          // current beam index
int g_vBlocked;    // blocked count
int g_vStair;      // passed via stair-lift
int g_vLow;        // passed via vent/crawl hull
int g_vSide;       // passed via side offset
int g_vSubdiv;     // passed via subdivision
int g_vVault;      // passed via vault/climb

void Guide_ValidateWalkable()
{
    delete g_bBeamWalkable;
    if (g_GuideCells == null || g_GuideCells.Length < 2) return;
    if (g_hCvarTraceHull == null || !g_hCvarTraceHull.BoolValue) return;

    g_bBeamWalkable = new ArrayList(1);
    g_vi = 0;
    g_vBlocked = g_vStair = g_vLow = g_vSide = g_vSubdiv = g_vVault = 0;

    RequestFrame(Guide_ValidateWalkable_Frame, 0);
}

void Guide_ValidateWalkable_Frame(any unused)
{
    if (g_GuideCells == null || g_vi >= g_GuideCells.Length - 1)
    {
        int total = (g_GuideCells != null) ? (g_GuideCells.Length - 1) : 0;
        if (total > 0)
        {
            LogMessage("[PTG] Hull validation: %d/%d walkable — vault:%d stair:%d low:%d side:%d subdiv:%d — blocked:%d",
                total - g_vBlocked, total, g_vVault, g_vStair, g_vLow, g_vSide, g_vSubdiv, g_vBlocked);

            // v4.0: Chain into STAGE_REPAIR after validation completes
            if (g_vBlocked > 0 && g_hCvarRepairEnable != null && g_hCvarRepairEnable.BoolValue)
            {
                Guide_RepairBlocked();
            }
        }
        return;
    }

    int count = g_GuideCells.Length;

    // Hull definitions
    float midMins[3] = {-14.0, -14.0, 0.0};
    float midMaxs[3] = { 14.0,  14.0, 44.0};
    float lowMins[3] = {-10.0, -10.0, 0.0};
    float lowMaxs[3] = { 10.0,  10.0, 32.0};

    for (int batch = 0; batch < VALIDATE_BATCH && g_vi < count - 1; batch++, g_vi++)
    {
        int i = g_vi;
        Cell cell1, cell2;
        g_GuideCells.GetArray(i, cell1, sizeof(Cell));
        g_GuideCells.GetArray(i + 1, cell2, sizeof(Cell));

        bool walkable = false;

        float baseStart[3], baseEnd[3];
        baseStart = cell1.center;
        baseEnd   = cell2.center;

        float dz = FloatAbs(cell2.center[2] - cell1.center[2]);
        float dist = GetVectorDistance(cell1.center, cell2.center, false);
        float distXY = GetVectorDistance(cell1.center, cell2.center, true);

        // Strategy 0: Ladder / elevator / vertical drop
        if (dz > 80.0 && distXY < 40.0)
        {
            g_bBeamWalkable.Push(1);
            continue;
        }

        // Strategy 0.5: Vault / climb — moderate-height obstacle to jump over
        // Two cells close horizontally but with a box/crate/ledge between them.
        // The player can vault: step up onto the higher cell, walk across, drop down.
        // Trace at the higher cell's level (+10u clearance) with low hull.
        if (dz >= 30.0 && dz <= 100.0 && distXY < 120.0)
        {
            float vaultZ = (cell1.center[2] > cell2.center[2] ? cell1.center[2] : cell2.center[2]) + 10.0;
            float sv[3], ev[3];
            sv = baseStart; sv[2] = vaultZ;
            ev = baseEnd;   ev[2] = vaultZ;
            // Only the higher-level horizontal trace needs to clear — player steps up naturally
            if (TryHull(sv, ev, lowMins, lowMaxs))
            {
                g_vVault++;
                g_bBeamWalkable.Push(1);
                continue;
            }
        }

        // Strategy 1: Mid hull (44h), normal lift (28u)
        float s1[3], e1[3];
        s1 = baseStart; s1[2] += 28.0;
        e1 = baseEnd;   e1[2] += 28.0;
        walkable = TryHull(s1, e1, midMins, midMaxs);

        // Strategy 2: Mid hull, steep lift (48u) — stairs
        if (!walkable && dz > 30.0 && dist < 150.0)
        {
            float s2[3], e2[3];
            s2 = baseStart; s2[2] += 48.0;
            e2 = baseEnd;   e2[2] += 48.0;
            walkable = TryHull(s2, e2, midMins, midMaxs);
            if (walkable) g_vStair++;
        }

        // Strategy 3: Low hull (32h), normal lift — vent/crawl
        if (!walkable)
        {
            float s3[3], e3[3];
            s3 = baseStart; s3[2] += 28.0;
            e3 = baseEnd;   e3[2] += 28.0;
            walkable = TryHull(s3, e3, lowMins, lowMaxs);
            if (walkable) g_vLow++;
        }

        // Strategy 4: Low hull, steep lift — crawl + stair
        if (!walkable && dz > 30.0 && dist < 150.0)
        {
            float s4[3], e4[3];
            s4 = baseStart; s4[2] += 48.0;
            e4 = baseEnd;   e4[2] += 48.0;
            walkable = TryHull(s4, e4, lowMins, lowMaxs);
            if (walkable) { g_vLow++; g_vStair++; }
        }

        // Strategy 5+6: Offset left/right (±18u)
        if (!walkable)
        {
            for (int side = 0; side < 2 && !walkable; side++)
            {
                float so[3], eo[3];
                float offset = (side == 0) ? 18.0 : -18.0;
                OffsetPerpendicular(s1, e1, offset, so);
                OffsetPerpendicular(e1, s1, -offset, eo);
                so[2] = s1[2]; eo[2] = e1[2];
                walkable = TryHull(so, eo, midMins, midMaxs);
            }
            if (walkable) g_vSide++;
        }

        // Strategy 7: Subdivide (3 segments)
        if (!walkable && dist > 200.0)
        {
            float segStart[3], segEnd[3];
            bool allClear = true;
            for (int seg = 0; seg < 3 && allClear; seg++)
            {
                float t0 = float(seg) / 3.0;
                float t1 = float(seg + 1) / 3.0;
                for (int j = 0; j < 3; j++)
                {
                    segStart[j] = baseStart[j] + (baseEnd[j] - baseStart[j]) * t0;
                    segEnd[j]   = baseStart[j] + (baseEnd[j] - baseStart[j]) * t1;
                }
                segStart[2] += 28.0;
                segEnd[2]   += 28.0;
                if (!TryHull(segStart, segEnd, midMins, midMaxs))
                    allClear = false;
            }
            walkable = allClear;
            if (walkable) g_vSubdiv++;
        }

        // Strategy 8: Jump arc (parabolic, 60u apex)
        if (!walkable && dist < 250.0)
        {
            float sj[3], ej[3], mj[3];
            sj = baseStart; sj[2] += 28.0;
            ej = baseEnd;   ej[2] += 28.0;
            mj[0] = (sj[0] + ej[0]) / 2.0;
            mj[1] = (sj[1] + ej[1]) / 2.0;
            mj[2] = (sj[2] + ej[2]) / 2.0 + 60.0;
            walkable = TryHull(sj, mj, lowMins, lowMaxs)
                    && TryHull(mj, ej, lowMins, lowMaxs);
        }

        g_bBeamWalkable.Push(walkable ? 1 : 0);
        if (!walkable) g_vBlocked++;
    }

    RequestFrame(Guide_ValidateWalkable_Frame, 0);
}

bool frame_budget_exceeded()
{
    if (g_hCvarBudget.FloatValue <= 0.0) return false;
    float dt_ms = (GetEngineTime()-g_tFrameStart)*1000.0;
    bool exceeded = dt_ms >= g_hCvarBudget.FloatValue;
    return exceeded;
}

// ======================================================================
// v4.0 STAGE_REPAIR — Auto-repair blocked beams after hull validation
//
// For each beam marked as blocked (g_bBeamWalkable[i] == 0), attempts a
// cascade of repair strategies:
//   1. Z-step: lift cell center by ±48, ±96, ±144
//   2. Horizontal offset: shift ±32u perpendicular to beam direction
//   3. Segment subdivide: split beam into 3 parts, validate each
//   4. Local A* reroute: mini-search between the two cell areas
//   5. Beacon marker: if all repair fails, mark as beacon point
//
// Distributed across frames (REPAIR_BATCH per frame) to avoid stalls.
// ======================================================================

#define REPAIR_BATCH 4
int g_ri;               // current repair beam index
int g_rFixed;           // count of repaired beams
int g_rBeaconed;        // count of beacon-marked beams
int g_rAttempts;        // repair attempts for current beam
ArrayList g_hBeaconCells; // beacon positions for unreachable transitions

void Guide_RepairBlocked()
{
    if (!g_hCvarRepairEnable.BoolValue) return;
    if (g_bBeamWalkable == null || g_GuideCells == null || g_GuideCells.Length < 2) return;

    delete g_hBeaconCells;
    g_hBeaconCells = new ArrayList(3);

    g_ri = 0;
    g_rFixed = 0;
    g_rBeaconed = 0;
    g_rAttempts = 0;

    RequestFrame(Guide_RepairBlocked_Frame, 0);
}

void Guide_RepairBlocked_Frame(any unused)
{
    if (g_GuideCells == null || g_bBeamWalkable == null || g_ri >= g_bBeamWalkable.Length)
    {
        if (g_rFixed > 0 || g_rBeaconed > 0)
        {
            LogMessage("[PTG] STAGE_REPAIR: fixed=%d beaconed=%d / %d total beams",
                g_rFixed, g_rBeaconed, (g_GuideCells != null && g_GuideCells.Length > 1) ? g_GuideCells.Length - 1 : 0);
        }
        return;
    }

    int count = g_bBeamWalkable.Length;

    for (int batch = 0; batch < REPAIR_BATCH && g_ri < count; batch++, g_ri++)
    {
        if (g_bBeamWalkable.Get(g_ri) == 1) continue; // already walkable

        Cell cell1, cell2;
        g_GuideCells.GetArray(g_ri, cell1, sizeof(Cell));
        g_GuideCells.GetArray(g_ri + 1, cell2, sizeof(Cell));

        bool repaired = false;

        // Strategy 1: Z-stepping — lift the target cell center
        // Try progressively higher lifts to clear low obstacles
        if (!repaired)
        {
            float zOffsets[6] = {48.0, -48.0, 96.0, -96.0, 144.0, -144.0};
            for (int z = 0; z < 6 && !repaired; z++)
            {
                float test[3];
                test = cell2.center;
                test[2] += zOffsets[z];
                if (twopos_traversable(cell1.center, test))
                {
                    cell2.center = test;
                    g_GuideCells.SetArray(g_ri + 1, cell2, sizeof(Cell));
                    g_bBeamWalkable.Set(g_ri, 1);
                    repaired = true;
                    g_rFixed++;
                }
                // Also try lifting cell1
                if (!repaired)
                {
                    test = cell1.center;
                    test[2] += zOffsets[z];
                    if (twopos_traversable(test, cell2.center))
                    {
                        cell1.center = test;
                        g_GuideCells.SetArray(g_ri, cell1, sizeof(Cell));
                        g_bBeamWalkable.Set(g_ri, 1);
                        repaired = true;
                        g_rFixed++;
                    }
                }
            }
        }

        // Strategy 2: Horizontal offset perpendicular to beam
        if (!repaired)
        {
            float dir[3];
            dir[0] = cell2.center[0] - cell1.center[0];
            dir[1] = cell2.center[1] - cell1.center[1];
            float len = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1]);
            if (len > 1.0)
            {
                float perp[3];
                perp[0] = -dir[1] / len;
                perp[1] =  dir[0] / len;
                perp[2] = 0.0;

                float offsets[4] = {32.0, -32.0, 64.0, -64.0};
                for (int o = 0; o < 4 && !repaired; o++)
                {
                    float s1[3], e1[3];
                    s1[0] = cell1.center[0] + perp[0] * offsets[o];
                    s1[1] = cell1.center[1] + perp[1] * offsets[o];
                    s1[2] = cell1.center[2] + 28.0;
                    e1[0] = cell2.center[0] + perp[0] * offsets[o];
                    e1[1] = cell2.center[1] + perp[1] * offsets[o];
                    e1[2] = cell2.center[2] + 28.0;

                    float midMins[3] = {-14.0, -14.0, 0.0};
                    float midMaxs[3] = { 14.0,  14.0, 44.0};
                    TR_TraceHullFilter(s1, e1, midMins, midMaxs, MASK_PLAYERSOLID, TraceFilter_WorldOnly);
                    if (!TR_DidHit())
                    {
                        cell1.center = s1;
                        cell1.center[2] -= 28.0;
                        cell2.center = e1;
                        cell2.center[2] -= 28.0;
                        g_GuideCells.SetArray(g_ri, cell1, sizeof(Cell));
                        g_GuideCells.SetArray(g_ri + 1, cell2, sizeof(Cell));
                        g_bBeamWalkable.Set(g_ri, 1);
                        repaired = true;
                        g_rFixed++;
                    }
                }
            }
        }

        // Strategy 3: Segment subdivision — split long beam into 3 parts
        if (!repaired)
        {
            float dist = GetVectorDistance(cell1.center, cell2.center, false);
            if (dist > 120.0)
            {
                float segs[4][3];
                segs[0] = cell1.center;
                segs[3] = cell2.center;
                for (int s = 1; s < 3; s++)
                {
                    float t = float(s) / 3.0;
                    for (int j = 0; j < 3; j++)
                        segs[s][j] = cell1.center[j] + (cell2.center[j] - cell1.center[j]) * t;
                    segs[s][2] += 28.0;
                }
                segs[0][2] += 28.0;
                segs[3][2] += 28.0;

                float midMins[3] = {-14.0, -14.0, 0.0};
                float midMaxs[3] = { 14.0,  14.0, 44.0};
                bool allClear = true;
                for (int s = 0; s < 3 && allClear; s++)
                {
                    TR_TraceHullFilter(segs[s], segs[s+1], midMins, midMaxs, MASK_PLAYERSOLID, TraceFilter_WorldOnly);
                    if (TR_DidHit()) allClear = false;
                }

                if (allClear)
                {
                    // Insert intermediate waypoints to avoid the blocked direct beam
                    Cell midCell;
                    midCell.navArea = Address_Null;
                    midCell.flow = (cell1.flow + cell2.flow) / 2.0;
                    midCell.center[0] = segs[1][0];
                    midCell.center[1] = segs[1][1];
                    midCell.center[2] = segs[1][2] - 28.0;

                    // Insert new cell between g_ri and g_ri+1
                    g_GuideCells.ShiftUp(g_ri + 1);
                    g_GuideCells.SetArray(g_ri + 1, midCell, sizeof(Cell));
                    g_bBeamWalkable.ShiftUp(g_ri);
                    g_bBeamWalkable.Set(g_ri, 1);
                    g_bBeamWalkable.Set(g_ri + 1, 1);
                    repaired = true;
                    g_rFixed++;
                }
            }
        }

        // Strategy 4: Local A* reroute using nav area adjacency
        if (!repaired && cell1.navArea != Address_Null && cell2.navArea != Address_Null)
        {
            if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
            ConAdj.Clear();

            int connCount = GetNavConnections(cell1.navArea, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);
            NavConnection nc;
            bool foundAlt = false;
            float bestDist = -1.0;
            float bestPos[3];
            Address bestArea = Address_Null;

            for (int n = 0; n < connCount; n++)
            {
                ConAdj.GetArray(n, nc, sizeof(NavConnection));
                if (nc.navArea == Address_Null || nc.navArea == cell1.navArea) continue;
                if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true)) continue;

                float altCenter[3];
                L4D_GetNavAreaCenter(nc.navArea, altCenter);
                altCenter[2] += 16.0;

                if (twopos_traversable(cell1.center, altCenter) && twopos_traversable(altCenter, cell2.center))
                {
                    float d = GetVectorDistance(cell1.center, altCenter, true)
                            + GetVectorDistance(altCenter, cell2.center, true);
                    if (bestDist < 0.0 || d < bestDist)
                    {
                        bestDist = d;
                        bestPos = altCenter;
                        bestArea = nc.navArea;
                        foundAlt = true;
                    }
                }
            }

            if (foundAlt)
            {
                Cell altCell;
                altCell.navArea = bestArea;
                altCell.center = bestPos;
                altCell.flow = (cell1.flow + cell2.flow) / 2.0;
                g_GuideCells.ShiftUp(g_ri + 1);
                g_GuideCells.SetArray(g_ri + 1, altCell, sizeof(Cell));
                g_bBeamWalkable.ShiftUp(g_ri);
                g_bBeamWalkable.Set(g_ri, 1);
                g_bBeamWalkable.Set(g_ri + 1, 1);
                repaired = true;
                g_rFixed++;
            }
        }

        // Strategy 5: Beacon — mark unreachable transition
        if (!repaired && g_hCvarBeaconEnable.BoolValue)
        {
            float beaconPos[3];
            beaconPos = cell1.center;
            g_hBeaconCells.PushArray(beaconPos, 3);
            g_rBeaconed++;

            // Mark as walkable so we don't keep trying to repair
            g_bBeamWalkable.Set(g_ri, 1);
        }
        else if (!repaired)
        {
            // No beacon enabled, just mark as-is
            g_bBeamWalkable.Set(g_ri, 0);
        }
    }

    RequestFrame(Guide_RepairBlocked_Frame, 0);
}

// Draw beacon markers at positions stored in g_hBeaconCells
void Guide_DrawBeacons(int client = -1)
{
    if (g_hBeaconCells == null || g_hBeaconCells.Length == 0) return;
    if (!g_hCvarBeaconEnable.BoolValue) return;

    int laser = g_iLaserWhite;
    if (laser == 0) laser = g_iLaser;
    if (laser == 0) return;

    float duration = g_hCvarAutoDuration.FloatValue;
    if (duration < 1.0) duration = 5.0;

    // Bright red-orange beacon: "path continues here"
    int color_beacon[4] = {255, 100, 50, 255};

    for (int i = 0; i < g_hBeaconCells.Length; i++)
    {
        float pos[3], end[3];
        g_hBeaconCells.GetArray(i, pos, 3);
        end = pos;
        end[2] += 32.0; // tall vertical marker

        // Vertical pillar beam — visible from a distance
        TE_SetupBeamPoints(pos, end, laser, 0, 0, 0,
            duration, 4.0, 4.0, 0, 0.0, color_beacon, 0);
        if (client > 0) TE_SendToClient(client);
        else TE_SendToAll();

        // Ring at top — makes it recognizable as a beacon
        float ringCenter[3];
        ringCenter = end;
        int color_ring[4] = {255, 200, 100, 200};
        float ringRad = 20.0;
        float ringSteps[6][3];
        for (int s = 0; s < 6; s++)
        {
            float angle = float(s) * 3.14159 * 2.0 / 6.0;
            ringSteps[s][0] = ringCenter[0] + Cosine(angle) * ringRad;
            ringSteps[s][1] = ringCenter[1] + Sine(angle) * ringRad;
            ringSteps[s][2] = ringCenter[2];
        }
        for (int s = 0; s < 6; s++)
        {
            int sn = (s + 1) % 6;
            TE_SetupBeamPoints(ringSteps[s], ringSteps[sn], laser, 0, 0, 0,
                duration * 0.5, 1.5, 1.0, 0, 0.0, color_ring, 0);
            if (client > 0) TE_SendToClient(client);
            else TE_SendToAll();
        }
    }
}


ArrayList explored_finale;

void OnFramePrep(bool new_frame = true)
{
    if (!enable || guide_ready || !gamemode_guidable || !map_started || !nav_started || g_iPrepStage<=STAGE_NONE || g_iPrepStage>=STAGE_END)
    {
        guide_prep = false;
        g_iPrepStage = STAGE_NONE;
        timer_nav = null;
        return;
    }
    static float pos[3];
    static Cell cell, cell_before, cell_after;
    bool budget_spent = false; // same variable for all stages
    if (new_frame)
    {
        #if DEBUG
        g_iPrepFrames += 1;
        #if DEBUG>2
        LogMessage("OnFramePrep %d %d", g_iPrepFrames, g_iPrepStage);
        #endif
        #endif
        g_tFrameStart = GetEngineTime();
    }
    switch (g_iPrepStage)
    {
        case STAGE_PREP:
        {
            // v4.0: Batched index construction — spreads expensive operations
            // (portal computation, HPA clustering, bridge detection) across
            // multiple frames to avoid SIGALRM on 5K+ nav area maps.
            switch (g_iBuildPhase)
            {
                case 0:
                {
                    // --- Phase 0: Basic init + node index build ---
                    g_fMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
                    if (g_fMaxFlow <= 0.0)
                    {
                        guide_prep = false;
                        g_iPrepStage = STAGE_NONE;
                        #if DEBUG
                            LogMessage("WARNING: L4D2Direct_GetMapMaxFlowDistance returned <=0.0");
                        #endif
                        return;
                    }

                    // Build basic node index (nav areas, centers, spatial hash).
                    // Portals, HPA, and bridge detection run in later phases.
                    AStar_BuildNodeIndex();
                    if (g_hAStarNodes == null || g_hAStarNodes.Length <= 1)
                    {
                        guide_prep = false;
                        g_iPrepStage = STAGE_NONE;
                        LogMessage("[PTG] A* node index failed: too few nav areas");
                        return;
                    }

                    g_iBuildPhase = 1;
                    g_iPortalBatchIdx = 0;
                    budget_spent = true;
                    return;
                }
                case 1:
                {
                    // --- Phase 1: Batched portal computation ---
                    if (AStar_ComputePortalsBatch(g_iPortalBatchIdx, PORTALS_PER_FRAME))
                    {
                        g_iPortalBatchIdx += PORTALS_PER_FRAME;
                        budget_spent = true;
                        return;
                    }
                    g_iBuildPhase = 2;
                    budget_spent = true;
                    return;
                }
                case 2:
                {
                    // --- Phase 2: HPA* clusters ---
                    if (g_hCvarHpaEnable != null && g_hCvarHpaEnable.BoolValue)
                        HPA_BuildClusters();
                    g_iBuildPhase = 3;
                    budget_spent = true;
                    return;
                }
                case 3:
                {
                    // --- Phase 3: Nav mesh bridge detection ---
                    if (g_hCvarNonMesh != null && g_hCvarNonMesh.BoolValue)
                        DetectNavMeshBridges();
                    g_iBuildPhase = 4;
                    // Fall through to phase 4 (post-build init)
                }
                case 4:
                {
                    // Reset build phase for next map load
                    g_iBuildPhase = 0;
                    // Fall through to post-build initialization below
                }
            }

            // --- Post-build initialization (original STAGE_PREP logic) ---

            // Initialize guide cells
            delete g_GuideCells;
            g_GuideCells = new ArrayList(sizeof(Cell));

            delete RescueVehicleCells;
            RescueVehicleCells = new ArrayList(sizeof(Cell));

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

            // Populate RescueVehicleCells for STAGE_JOIN
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
                LogMessage("[PTG] A* cannot identify start (%d) or goal (%d) — falling back", startIdx, goalIdx);
                guide_prep = false;
                g_iPrepStage = STAGE_NONE;
                return;
            }

            g_aAStarStart = g_hAStarNodes.Get(startIdx);
            g_aAStarGoal = g_hAStarNodes.Get(goalIdx);
            g_iAStarGoalIndex = goalIdx;

            #if DEBUG
            float startC[3], goalC[3];
            g_hAStarCenters.GetArray(startIdx, startC, 3);
            g_hAStarCenters.GetArray(goalIdx, goalC, 3);
            LogMessage("[PTG] A* start=%d (%.0f,%.0f,%.0f) goal=%d (%.0f,%.0f,%.0f) navAreas=%d",
                startIdx, startC[0], startC[1], startC[2],
                goalIdx, goalC[0], goalC[1], goalC[2],
                g_hAStarNodes.Length);
            #endif

            // Initialize A* search state
            AStar_Init();
            AStar_SetStart(startIdx);

            // Start non-mesh connection detection (continues across frames, only if cvar enabled)
            if (g_hCvarNonMesh.BoolValue)
                DetectNonMeshConnections_Init();

            #if DEBUG
            g_fPrepTotalTime = 0.0;
            g_iErased = 0;
            g_iNavBlocked = 0;
            g_iTotalCollected = g_hAStarNodes.Length;
            g_iTighten = 0;
            #endif
            g_iLoop = 0;
        }
        case STAGE_ASTAR:
        {
            // Continue non-mesh detection in parallel with A* (only if cvar enabled)
            if (g_hCvarNonMesh.BoolValue)
                DetectNonMeshConnections_Frame();

            // Run A* search for this frame
            int result = AStar_SearchFrame(ASTAR_NODES_PER_FRAME);

            if (result == 1)
            {
                // Path found
                LogMessage("[PTG] A* path found — proceeding to smoothing");
                budget_spent = false; // proceed to next stage immediately
            }
            else if (result == -1)
            {
                // No path to pre-selected goal, and no reachable nodes found.
                // Extremely rare — only when the start area has zero connections.
                LogMessage("[PTG] A* failed: no reachable nodes from start.");
                guide_prep = false;
                g_iPrepStage = STAGE_NONE;
                return;
            }
            else
            {
                // Still searching — continue next frame
                budget_spent = true;
            }
        }
        case STAGE_SMOOTH:
        {
            // Reconstruct and smooth the A* path
            delete g_GuideCells;
            g_GuideCells = new ArrayList(sizeof(Cell));

            AStar_ReconstructPath(g_GuideCells);

            // v4.0: Insert 3D Z-transition waypoints for multi-floor maps
            Funnel3D_InsertZTransitions(g_GuideCells);

            #if DEBUG
            LogMessage("[PTG] Path reconstructed: %d cells after smoothing + 3D funnel", g_GuideCells.Length);
            #endif

            if (g_GuideCells.Length < 2)
            {
                LogMessage("[PTG] A* produced <2 guide cells — falling back");
                delete g_GuideCells;
                guide_prep = false;
                g_iPrepStage = STAGE_NONE;
                return;
            }

            // Clean up A* state to free memory
            delete g_hAStarOpen;
            delete g_hAStarGScore;
            delete g_hAStarCameFrom;
            delete g_hAStarEdgeType;
            delete g_hAStarClosed;

            // Track rescue vehicle relative to guide path
            if (g_bFoundRescueVehicle)
            {
                float maxGuideFlow = g_GuideCells.Get(g_GuideCells.Length - 1, 0);
                finale_backwards = g_fFlowRescueVehicle < maxGuideFlow;
                if (explored_finale == null) explored_finale = new ArrayList();
                explored_finale.Clear();
            }

            g_iLoop = 1;
        }
        case STAGE_JOIN:
        {
            // Connect rescue vehicle to guide path (existing logic)
            if (RescueVehicleCells == null || RescueVehicleCells.Length <= 0 || g_hCvarFinale.IntValue == FINALE_NEVER)
                g_bFoundRescueVehicle = false;

            if (g_bFoundRescueVehicle)
            {
                RescueVehicleCells.GetArray(RescueVehicleCells.Length-1, cell, sizeof(Cell));
                static float pos_curr[3];
                float flow_curr = cell.flow;
                pos_curr = cell.center;
                if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
                if (AdjNN == null) AdjNN = new ArrayList();

                Address navArea_curr = cell.navArea;
                float flow_temp, flow_best;
                static float pos_temp[3], pos_best[3];
                Address navArea_best;
                float dz, dz_best;

                while (navArea_curr != Address_Null)
                {
                    if (frame_budget_exceeded()) { budget_spent = true; break; }
                    bool found = false;
                    flow_best = flow_curr;
                    bool best_steep = false;
                    int count = GetNavConnections(navArea_curr, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);
                    static NavConnection nav_connection;
                    for (int i = 0; i < count; i++)
                    {
                        ConAdj.GetArray(i, nav_connection, sizeof(NavConnection));
                        if (nav_connection.navArea == Address_Null || nav_connection.connectiontype <= CONNECTED_NOT) continue;
                        if (nav_connection.navArea == navArea_curr) continue;
                        if (blocked_available && L4D_NavArea_IsBlocked(nav_connection.navArea, TEAM_SURVIVOR, true)) continue;
                        if (explored_finale.FindValue(nav_connection.navArea) >= 0) continue;
                        explored_finale.Push(nav_connection.navArea);
                        flow_temp = L4D2Direct_GetTerrorNavAreaFlow(nav_connection.navArea);
                        int count2 = navArea_ladder_navAreas(nav_connection.navArea, AdjNN, TEAM_SURVIVOR);
                        for (int i2 = 0; i2 < count2; i2++)
                        {
                            Address adjArea = AdjNN.Get(i2);
                            if (adjArea == Address_Null || adjArea == navArea_curr || adjArea == nav_connection.navArea) continue;
                            float new_flow = L4D2Direct_GetTerrorNavAreaFlow(adjArea);
                            if (flow_better(new_flow, flow_temp, finale_backwards))
                                flow_temp = new_flow;
                        }
                        if (!flow_better(flow_temp, flow_curr, finale_backwards)) continue;
                        L4D_GetNavAreaCenter(nav_connection.navArea, pos_temp);
                        pos_temp[2] += 16.0;
                        dz = pos_curr[2] - pos_temp[2];
                        bool steep = nav_connection.connectiontype == CONNECTED_ADJACENT && nav_too_steep(navArea_curr, nav_connection.navArea);
                        if (found && steep)
                        {
                            if (!best_steep || dz > dz_best) continue;
                        }
                        if (flow_better(flow_temp, flow_best, finale_backwards) || (best_steep && flow_better(flow_temp, flow_curr, finale_backwards)))
                        {
                            flow_best = flow_temp;
                            navArea_best = nav_connection.navArea;
                            pos_best = pos_temp;
                            found = true;
                            best_steep = steep;
                            dz_best = dz;
                        }
                    }

                    if (!found)
                    {
                        if (try_ladder(flow_curr, pos_curr, cell, finale_backwards))
                        {
                            found = true;
                            flow_best = cell.flow;
                            navArea_best = cell.navArea;
                            pos_best = cell.center;
                        }
                    }

                    if (found)
                    {
                        if (pos_underwater(pos_best)) pos_best[2] += 32.0;
                        pos_curr = pos_best;
                        navArea_curr = navArea_best;
                        flow_curr = flow_best;
                        cell.flow = flow_curr;
                        cell.navArea = navArea_curr;
                        cell.center = pos_curr;
                        guide_add_cell(RescueVehicleCells, cell);
                    }
                    else break;
                }
                if (!budget_spent)
                {
                    explored_finale.Clear();
                    #if DEBUG
                    LogMessage("Rescue vehicle cells %d", RescueVehicleCells.Length);
                    #endif
                    if (should_stitch_finale()) stitch_finale();
                }
            }
            g_iLoop = 1;
        }
        case STAGE_VALIDATE:
        {
            if (g_GuideCells != null && g_GuideCells.Length > 2)
            {
                while (g_iLoop < (g_GuideCells.Length - 1))
                {
                    if (frame_budget_exceeded()) { budget_spent = true; break; }
                    g_GuideCells.GetArray(g_iLoop+1, cell_after, sizeof(Cell));
                    g_GuideCells.GetArray(g_iLoop, cell, sizeof(Cell));
                    g_GuideCells.GetArray(g_iLoop-1, cell_before, sizeof(Cell));
                    if (triple_valid_ground(cell_before.center, cell_after.center) && twopos_traversable(cell_before.center, cell_after.center)
                        && FloatAbs(cell_before.center[2] - cell_after.center[2]) <= 50.0)
                    {
                        g_GuideCells.Erase(g_iLoop);
                        #if DEBUG
                        g_iErased += 1;
                        #endif
                        if (g_iLoop > 1) g_iLoop -= 1;
                        continue;
                    }

                    if (!vecdiff_too_steep(cell_before.center, cell.center))
                    {
                        if (project_forward(cell_before.center, cell.center, cell_after.center, pos) && valid_ground(pos) && twopos_traversable(pos, cell_before.center) && twopos_traversable(pos, cell_after.center))
                        {
                            cell.center = pos;
                            g_GuideCells.SetArray(g_iLoop, cell, sizeof(Cell));
                            #if DEBUG
                            g_iTighten += 1;
                            #endif
                            if (g_iLoop > 1) g_iLoop -= 1;
                            continue;
                        }
                        if (project_forward(cell.center, cell_after.center, cell_before.center, pos) && valid_ground(pos) && twopos_traversable(pos, cell_before.center) && twopos_traversable(pos, cell_after.center))
                        {
                            cell.center = pos;
                            g_GuideCells.SetArray(g_iLoop, cell, sizeof(Cell));
                            #if DEBUG
                            g_iTighten += 1;
                            #endif
                            if (g_iLoop > 1) g_iLoop -= 1;
                            continue;
                        }
                        else
                        {
                            get_midpoint(cell_before.center, cell.center, pos);
                            if (valid_ground(pos) && twopos_traversable(pos, cell_before.center) && twopos_traversable(pos, cell_after.center))
                            {
                                cell.center = pos;
                                g_GuideCells.SetArray(g_iLoop, cell, sizeof(Cell));
                                #if DEBUG
                                g_iTighten += 1;
                                #endif
                            }
                        }
                    }
                    #if DEBUG>2
                        LogMessage("%d %f", g_iLoop, cell.flow);
                    #endif
                    g_iLoop += 1;
                }
            }
        }
        case STAGE_REPAIR:
        {
            // v4.0: Repair is triggered asynchronously from Guide_ValidateWalkable_Frame
            // when validation completes. This stage is a pass-through to maintain
            // pipeline ordering (REPAIR runs after VALIDATE).
            g_iLoop = 1;
        }
        default:
        {
            // Pipeline stage dispatch complete.
        }
    }

    if (!budget_spent) g_iPrepStage += 1;

    if (g_iPrepStage>STAGE_NONE && g_iPrepStage<STAGE_END)
    {
        if (budget_spent || frame_budget_exceeded())
        {
            RequestFrame(OnFramePrep,true);
            #if DEBUG
            g_fPrepTotalTime += (GetEngineTime()-g_tFrameStart);
            #endif
            return;
        }
        else OnFramePrep(false);
    }
    else
    {
        guide_prep = false;
        guide_ready = true;
        Guide_ValidateWalkable(); // v2.2: hull-trace validate all beams against world geometry
        beams_cooldown_reset(); // reset cooldowns but not requests to draw
        #if DEBUG
        g_fPrepTotalTime += (GetEngineTime()-g_tFrameStart);
        LogMessage("[PTG] Guide ready: %d cells (%d nav areas) (%f ms %d frames)",
        g_GuideCells.Length, g_iTotalCollected, g_fPrepTotalTime*1000.0, g_iPrepFrames);
        #endif
        g_iPrepStage = STAGE_NONE;
        timer_nav = null;
        if (finale_stitched && finale_rescue && g_hCvarFinaleAuto.BoolValue) Guide_All_Clients();
        else Timer_CheckRequests(null); // Draw beams immediately for pending clients
    }

}

// Look for closest survivor ladder manually, quite expensive. Output cell_ladder
stock bool try_ladder(float flow_curr,float pos_curr[3],Cell cell_ladder,bool flow_increasing = true)
{
    int entity = INVALID_ENT_REFERENCE;
    int closest = -1;
    static float mins[3],maxs[3],pos_temp[3],pos_best[3];
    float best_dist = -1.0;
    float flow_best = -1.0;
    float flow_temp;
    bool found = false;
    Address navArea_best;
    while ((entity = FindEntityByClassname(entity, "func_simpleladder")) != INVALID_ENT_REFERENCE)
    {
        int team = GetEntProp(entity, Prop_Send, "m_iTeamNum");
        if (team!=0 && team!=TEAM_SURVIVOR) continue;
        GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
        float dist = GetVectorDistance(pos_curr,maxs,true);
        if (best_dist<0.0 || dist<best_dist)
        {
            closest = entity;
            best_dist = dist;
        }
        GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
        dist = GetVectorDistance(pos_curr,maxs,true);
        if (best_dist<0.0 || dist<best_dist)
        {
            closest = entity;
            best_dist = dist;
        }
    }
    if (closest>0 && best_dist<100000.0)
    {
        //LogMessage("Found survivor ladder %d %f", closest, best_dist);
        flow_best = flow_curr;
        for (int i_nav = 0; i_nav < 2; i_nav++)
        {
            if (i_nav==0) GetEntPropVector(closest, Prop_Send, "m_vecMaxs", pos_temp);
            else GetEntPropVector(closest, Prop_Send, "m_vecMins", pos_temp);
            Address adjArea = L4D_GetNearestNavArea(pos_temp,500.0,true,false,false,TEAM_SURVIVOR);
            if (adjArea == Address_Null) continue;
            flow_temp = L4D2Direct_GetTerrorNavAreaFlow(adjArea);
            switch (flow_increasing)
            {
                case true: { if (flow_temp<=flow_best) continue; }
                default: { if (flow_temp>=flow_best) continue; }
            }
            //L4D_GetNavAreaCenter(adjArea,pos_temp);
            pos_temp[2] += 16.0;
            flow_best = flow_temp;
            navArea_best = adjArea;
            pos_best = pos_temp;
            found = true;
        }
    }
    if (found)
    {
        cell_ladder.flow = flow_best;
        cell_ladder.navArea = navArea_best;
        cell_ladder.center = pos_best;
        return true;
    }
    return false;
}

// Check if escape vehicle should be connected to RequestGuide
bool should_stitch_finale()
{
    if (!enable || !map_started || !nav_started || finale_stitched || !g_bFoundRescueVehicle) return false;
    switch (g_hCvarFinale.IntValue)
    {
        case FINALE_NEVER: return false;
        case FINALE_RESCUE: return finale && finale_rescue;
        case FINALE_STARTED: return finale;
        default: return true;
    }
}

// Check if two cells are nearly identical. max_distance sets how far apart they can be.
bool cells_almost_identical(Cell cell1, Cell cell2, float max_distance = 250.0)
{
    if (cell1.navArea != Address_Null && cell1.navArea == cell2.navArea) return true;
    return GetVectorDistance(cell1.center,cell2.center)<=max_distance && twopos_traversable(cell1.center,cell2.center);
}

void stitch_finale()
{
    if (!enable || finale_stitched) return;
    if (g_GuideCells == null || RescueVehicleCells == null) return;
    static Cell cell, cell2;
    g_GuideCells.GetArray(g_GuideCells.Length-1,cell2,sizeof(Cell));

    #if DEBUG
    int erased = 0;
    #endif

    int i_finale_cut = -1; // which guide cell meets with rescue
    int i_finale_cut_rescue = -1; // which rescue cell meets with guide
    g_iLoop = 0;
    while (g_iLoop>=0 && g_iLoop<=(RescueVehicleCells.Length-1))
    {
        RescueVehicleCells.GetArray(g_iLoop,cell,sizeof(Cell));
        if ( g_iLoop==0 && cells_almost_identical(cell,cell2) )
        {
            g_GuideCells.PushArray(cell,sizeof(Cell));
            finale_backwards = false;
            finale_stitched = true;
            #if DEBUG
            LogMessage("Rescue zone is close to last guide cell. Added 1 cell.");
            #endif
            return;
        }
        if (cell.navArea != Address_Null)
        {
            i_finale_cut = g_GuideCells.FindValue(cell.navArea,1);
            if (i_finale_cut>=0)
            {
                i_finale_cut_rescue = g_iLoop;
                break;
            }
        }
        g_iLoop += 1;
    }

    if ( (!finale_backwards || use_gauntlet_logic()) && i_finale_cut_rescue>=0 && i_finale_cut>0)
    {
        // keep g_GuideCells up to i_finale_cut. keep i_finale_cut
        g_GuideCells.Resize(i_finale_cut+1);
        // keep RescueVehicleCells up to i_finale_cut_rescue. don't keep i_finale_cut_rescue
        RescueVehicleCells.Resize(i_finale_cut_rescue);
        #if DEBUG
        LogMessage("Finale resize g_GuideCells %d RescueVehicleCells %d", i_finale_cut+1, i_finale_cut_rescue);
        #endif
    }

    if (!finale_backwards) // simplest case. extend guide cells to escape vehicle
    {
        #if DEBUG
        LogMessage("Finale increasing in flow, erased %d cells, added %d cells", erased, RescueVehicleCells.Length);
        #endif
    }
    else
    {
        if (use_gauntlet_logic())
        {
            // Erase g_GuideCells after rescue flow
            g_iLoop = g_GuideCells.Length-1;
            while (g_iLoop>=0 && g_iLoop<=(g_GuideCells.Length-1))
            {
                if (g_GuideCells.Get(g_iLoop,0)>=g_fFlowRescueVehicle)
                {
                    g_GuideCells.Erase(g_iLoop);
                    #if DEBUG
                    erased += 1;
                    #endif
                }
                else g_iLoop -= 1;
            }
            #if DEBUG
            LogMessage("Gauntlet flow backwards, erased %d cells, added %d cells", erased, RescueVehicleCells.Length);
            #endif
        }
        else
        {
            // Keep only last guide cell, connect to rescue zone.
            #if DEBUG
            LogMessage("Finale flow backwards, guide from radio only. %d cells", RescueVehicleCells.Length);
            #endif
            g_GuideCells.GetArray(g_GuideCells.Length-1,cell,sizeof(Cell));
            g_GuideCells.Clear();
            g_GuideCells.PushArray(cell,sizeof(Cell));
        }
    }
    // Merge g_GuideCells with rescue vehicle cells
    // in RescueVehicleCells, the first cell is the rescue position (the very last point).
    g_iLoop = RescueVehicleCells.Length-1;
    while (g_iLoop>=0 && g_iLoop<=(RescueVehicleCells.Length-1))
    {
        RescueVehicleCells.GetArray(g_iLoop,cell,sizeof(Cell));
        g_GuideCells.PushArray(cell,sizeof(Cell));
        g_iLoop -= 1;
    }
    finale_stitched = true;
}

// i_start is where the disconnected navmesh is. i_start-1 should be a good navarea.
ArrayList cells_explore;
#define STITCH_GAP_OK 2 // how many cells ahead to check for further disjointed navAreas
stock bool explore_stitch(ArrayList cells, int &i_start, int max_steps = 50)
{
    int cvar_steps = g_hCvarStitchSteps.IntValue;
    if (cvar_steps > max_steps) max_steps = cvar_steps;

    if (i_start<=1 || i_start>=cells.Length) return false;
    static Cell cell, cell2;

    int stitch_gap = STITCH_GAP_OK;
    //if (strncmp(mapName,"c7m2",4,false)==0) stitch_gap = 20; // i just want to talk to the mapper

    // Determine i_min>=i_start, where i_min is the furthest away cell index where disconnection was detected
    int i_min = i_start;
    int num_good = 0;
    int i = i_start+1;
    cells.GetArray(i_start,cell,sizeof(Cell)); // i_start-1 is the cell already explored. i_start does not have LOS.
    while (num_good<=stitch_gap && i<(cells.Length))
    {
        cells.GetArray(i,cell2,sizeof(Cell));
        if ( !cell_connected(cell,cell2) || !twopos_traversable(cell.center,cell2.center) )
        {
            num_good = 0;
            i_min = i-1;
        }
        else num_good += 1;
        cell = cell2;
        i += 1;
    }
    
    #if DEBUG
    LogMessage("explore_stitch i_start %d i_min %d", i_start, i_min);
    #endif

    int num_delete;

    if (i_min>i_start) // Delete chain of bad navmeshes
    {
        num_delete = i_min-i_start+1;
        #if DEBUG
        LogMessage("explore_stitch deleted %d cells", num_delete);
        #endif
        while (num_delete>0 && i_start<(cells.Length-1))
        {
            cells.Erase(i_start);
            num_delete -= 1;
        }
    }
    else if (i_start>0 && i_start<(cells.Length-1)) // is i_start+1 connected to i_start-1?
    {
        cells.GetArray(i_start-1,cell,sizeof(Cell));
        cells.GetArray(i_start+1,cell2,sizeof(Cell));
        if (cell_connected(cell,cell2) && (twopos_traversable(cell.center,cell2.center) || LOS_rescue_cheap(cell.center,cell2.center,_) ))
        {
            cells.Erase(i_start);
            #if DEBUG
            LogMessage("explore_stitch %d deleted", i_start);
            #endif
            return true;
        }
    }

    if (cells.Length<=1) return false;

    if (cells_explore==null) cells_explore = new ArrayList(sizeof(Cell));
    if (ConAdj==null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN==null) AdjNN = new ArrayList(); // nearest neighbor explore for dips in flow when about to climb a ladder
    cells_explore.Clear();
    if (explored==null) explored = new ArrayList();
    explored.Clear();

    cells.GetArray(i_start-1,cell,sizeof(Cell));
    static float pos_curr[3], pos_temp[3], pos_best[3];
    pos_curr = cell.center;
    float flow_curr = cell.flow;
    bool success = false; // success when we hit a forward navArea in cells
    Address navArea_curr = cell.navArea;
    Address navArea_best = navArea_curr;
    pos_best = pos_curr;
    float flow_temp, dz, dz_best;

    int steps = 0;
    int i_end = -1;
    while (steps<max_steps)
    {
        bool found = false;
        bool best_steep = false;
        float flow_best = flow_curr;
        int count = GetNavConnections(navArea_curr,ConAdj,TEAM_SURVIVOR,true,true,true,CON_KEEP_FORWARD);
        static NavConnection nav_connection;
        for (i = 0; i < count; i++)
        {
            ConAdj.GetArray(i,nav_connection,sizeof(NavConnection));
            if (nav_connection.navArea == Address_Null || nav_connection.connectiontype <= CONNECTED_NOT) continue;
            if (nav_connection.navArea == navArea_curr) continue;
            if (explored.FindValue(nav_connection.navArea)>=0) continue;
            explored.Push(nav_connection.navArea);
            if (blocked_available && L4D_NavArea_IsBlocked(nav_connection.navArea,TEAM_SURVIVOR,true)) continue;
            flow_temp = L4D2Direct_GetTerrorNavAreaFlow(nav_connection.navArea);
            int count2 = navArea_ladder_navAreas(nav_connection.navArea,AdjNN,TEAM_SURVIVOR); // ladder intervention. flow dips when stepping onto ladder navmeshes...
            for (int i2 = 0; i2 < count2; i2++)
            {
                Address adjArea = AdjNN.Get(i2);
                if (adjArea == Address_Null || adjArea == navArea_curr || adjArea == nav_connection.navArea) continue;
                float new_flow = L4D2Direct_GetTerrorNavAreaFlow(adjArea);
                if (new_flow>flow_temp)
                {
                    #if DEBUG>1
                    LogMessage("Ladder intervention %.1f -> %.1f", flow_temp, new_flow);
                    #endif
                    flow_temp = new_flow;
                }
            }
            if (flow_temp<flow_curr) continue;
            L4D_GetNavAreaCenter(nav_connection.navArea,pos_temp); pos_temp[2] += 16.0;
            if (pos_underwater(pos_temp))
            {
                pos_temp[2] += 16.0;
                if (pos_underwater(pos_temp)) pos_temp[2] += 16.0;
            }
            dz = pos_temp[2] - pos_curr[2];
            bool steep = nav_connection.connectiontype == CONNECTED_ADJACENT && nav_too_steep(navArea_curr,nav_connection.navArea);
            if (found && steep)
            {
                if (!best_steep || dz>dz_best) continue; // prefer to go down than up
            }
            else if (!steep)
            {
                i_end = cells.FindValue(nav_connection.navArea,1);
                if (i_end>=i_start) success = true;
            }
            if ( success || flow_temp>=flow_best || (best_steep && flow_temp>=flow_curr) )
            {
                flow_best = flow_temp;
                navArea_best = nav_connection.navArea;
                pos_best = pos_temp;
                found = true;
                best_steep = steep;
                dz_best = dz;
                if (success) break;
            }
        }
        
        if (found)
        {
            cell.flow = flow_best;
            cell.navArea = navArea_best;
            cell.center = pos_best;
        }
        else found = try_ladder(flow_curr,pos_curr,cell);
        if (!found) break;

        pos_curr = cell.center;
        navArea_curr = cell.navArea;
        flow_curr = cell.flow;
        #if DEBUG>1
        LogMessage("explore_stitch %d found %f", i_start, flow_best);
        #endif
        cells_explore.PushArray(cell,sizeof(Cell));
        if (!success) i_end = cells.FindValue(navArea_curr,1);
        if (i_end>=0)
        {
            //if (i_end<i_start) break; // fail
            success = i_end>=i_start;
            if (success) break;
        } 
        steps += 1;
    }

    #if DEBUG
    LogMessage("explore_stitch %d %d %d", i_start, success, cells_explore.Length);
    #endif

    if (success)
    {
        cells_explore.GetArray(0,cell,sizeof(Cell));
        cells.SetArray(i_start,cell,sizeof(Cell));
        num_delete = i_end-i_start;
        int num_deleted = num_delete;
        while (num_delete>0 && i_start<(cells.Length-1))
        {
            cells.Erase(i_start+1);
            num_delete -= 1;
        }
        if (cells_explore.Length>1)
        {
            for (i = cells_explore.Length-1; i >= 1; i--)
            {
                cells_explore.GetArray(i,cell,sizeof(Cell));
                if ( i_start<(cells.Length-1) )
                {
                    cells.ShiftUp(i_start+1);
                    cells.SetArray(i_start+1,cell,sizeof(Cell));
                }
                else
                {
                    cells.PushArray(cell,sizeof(Cell));
                }
            }
        }
        i_start += num_deleted;
    }

    return success;
}

// Add cell to cells. If there is no LOS, attempt rescue. If check_ladder, add ladder mounting points.
void guide_add_cell(ArrayList cells, Cell cell, bool check_ladder = true)
{
    if (cells.Length<1) // no shortcuts available
    {
        cells.PushArray(cell);
        return;
    }
    static Cell cell_prev, cell_prev2;
    cells.GetArray(cells.Length-1,cell_prev,sizeof(Cell)); // last cell
    
    bool prev2 = cells.Length>=2;
    if (prev2) cells.GetArray(cells.Length-2,cell_prev2,sizeof(Cell));

    bool LOS = twopos_traversable(cell.center,cell_prev.center);
    if (!LOS) // Try lifting cells
    {
        static Cell cell_lifted;
        cell_lifted = cell; cell_lifted.center[2] += 16.0;
        LOS = twopos_traversable(cell_lifted.center,cell_prev.center);
        if (LOS) cell = cell_lifted;
        else
        {
            cell_lifted = cell_prev; cell_lifted.center[2] += 16.0;
            if (twopos_traversable(cell_lifted.center,cell.center) && ( !prev2 || twopos_traversable(cell_lifted.center,cell_prev2.center) ) )
            {
                cell_prev = cell_lifted;
                cells.SetArray(cells.Length-1,cell_prev,sizeof(Cell));
                LOS = true;
            }
        }
    }
    
    if (LOS)
    {
        if (prev2 && triple_valid_ground(cell_prev2.center,cell.center) && twopos_traversable(cell.center,cell_prev2.center))
            cells.SetArray(cells.Length-1,cell,sizeof(Cell));
        else 
            cells.PushArray(cell);
    }
    else if (!cell_rescue(cells,cell_prev,cell,cell_prev2,prev2))
    {
        if (check_ladder) // Add ladder attachment points
        {
            int ladder = ladder_from_to(cell_prev.navArea,cell.navArea);
            if (ladder>0 && !twopos_traversable(cell_prev.center,cell.center))
            {
                static float pos1[3],pos2[3];
                GetEntPropVector(ladder, Prop_Send, "m_vecMaxs", pos1);
                GetEntPropVector(ladder, Prop_Send, "m_vecMins", pos2);
                SortTwoVectorsClosest(cell_prev.center,pos1,pos2);
                if (!navmesh_xy_too_far(cell_prev.navArea,pos1) && !navmesh_xy_too_far(cell.navArea,pos2))
                {
                    pos1[2] = L4D_NavArea_GetZ(cell_prev.navArea,pos1); pos1[2] += 16.0;
                    pos2[2] = L4D_NavArea_GetZ(cell.navArea,pos2); pos2[2] += 16.0;
                    
                    static Cell cell_ladder;
                    
                    cell_ladder = cell_prev;
                    cell_ladder.center = pos1;
                    // wiggle pos1 around so it has LOS with cell_prev
                    //guide_add_cell(cells,cell_ladder,false);
                    cells.PushArray(cell_ladder);
                    
                    cell_ladder = cell;
                    cell_ladder.center = pos2;
                    // wiggle pos2 around so it has LOS with cell
                    //guide_add_cell(cells,cell_ladder,false);
                    cells.PushArray(cell_ladder);
                }
            }
        }
        cells.PushArray(cell);
    }
}

// Two cells cannot see each other. Attempt to remedy this. prev2 if cell before previous cell exists. return true on success
bool cell_rescue(ArrayList cells, Cell cell_old, Cell cell_new, Cell cell_prev2, bool prev2 = true)
{
    static Cell cell;
    static Address navAreas[2];
    static float diff[3], diff_candidate[3], diff_template[3], pos_candidate[3], pos_template[3];

    ArrayList pos_candidates = new ArrayList(3);
    SubtractVectors(cell_new.center,cell_old.center,diff);
    diff_candidate = diff;

    bool flat = FloatAbs(diff[2])<=1.0; // flat -> nothing to do in z direction
    int i_turns_flat = 1;
    if (!flat) i_turns_flat += 1; // two turns if not flat
    int i_turns_mid = 2; // one cycle at old cell, then one cycle at midpoint

    if (elevator_available)
    {
        
        if (cell_new.navArea!=Address_Null) // clip cell_old.center to cell_new.navArea
        {
            pos_candidate = cell_old.center;
            navmesh_clip(cell_new.navArea,pos_candidate);
            pos_candidate[2] += 16.0; pos_candidates.PushArray(pos_candidate);
        }
        if (cell_old.navArea!=Address_Null) // clip cell_new.center to cell_old.navArea
        {
            pos_candidate = cell_new.center;
            navmesh_clip(cell_old.navArea,pos_candidate);
            pos_candidate[2] += 16.0; pos_candidates.PushArray(pos_candidate);
        }
        
        for (int dir = 0; dir < 4; dir++) // Add all 4 corners of navmesh. These are usually in very good positions for LOS.
        {
            L4D_NavArea_GetCorner(cell_new.navArea,view_as<NavCornerType>(dir),pos_candidate); pos_candidate[2] += 16.0; pos_candidates.PushArray(pos_candidate);
            L4D_NavArea_GetCorner(cell_old.navArea,view_as<NavCornerType>(dir),pos_candidate); pos_candidate[2] += 16.0; pos_candidates.PushArray(pos_candidate);
        }
    }
    else
    {
        // Add known corners of navmesh - crappy method
        L4D_GetNavAreaPos(cell_new.navArea,pos_candidate); pos_candidate[2] += 16.0; pos_candidates.PushArray(pos_candidate);
        L4D_GetNavAreaPos(cell_old.navArea,pos_candidate); pos_candidate[2] += 16.0; pos_candidates.PushArray(pos_candidate);
    }

    for (int i_turn_flat = 0; i_turn_flat < i_turns_flat; i_turn_flat++)
    {
        diff_template = diff;
        if (i_turn_flat==1) diff_template[2] = 0.0;
        for (int i_turn_mid = 0; i_turn_mid < i_turns_mid; i_turn_mid++) 
        {
            if (i_turn_mid==1) // Try wiggling at midpoint
            {
                diff_candidate = diff; ScaleVector(diff_candidate,0.5);
                AddVectors(cell_old.center,diff_candidate,pos_template);
            }
            else pos_template = cell_old.center;

            if (i_turn_mid==0)
            {
                diff_candidate = diff_template; ScaleVector(diff_candidate,0.5); // half
                AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);
            }

            diff_candidate = diff_template; diff_candidate[0] = 0.0; // dy
            AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);
            diff_candidate[1] *= 0.5; // dy/2
            AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);
            
            diff_candidate = diff_template; diff_candidate[1] = 0.0; // dx
            AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);
            diff_candidate[0] *= 0.5; // dx/2
            AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);
            
            diff_candidate = diff_template; ScaleVector(diff_candidate,0.25); // quarter
            AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);

            if (diff_template[2] != 0.0) // z is not flat
            {
                diff_candidate = diff_template; diff_candidate[0] = 0.0; diff_candidate[1] = 0.0; // dz
                AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);
                diff_candidate[2] *= 0.5; // dz/2
                AddVectors(pos_template,diff_candidate,pos_candidate); pos_candidates.PushArray(pos_candidate);
            }

            // Try small static wiggles
            AddVectors(pos_template,{16.0,0.0,0.0},pos_candidate); pos_candidates.PushArray(pos_candidate);
            AddVectors(pos_template,{-16.0,0.0,0.0},pos_candidate); pos_candidates.PushArray(pos_candidate);
            AddVectors(pos_template,{0.0,16.0,0.0},pos_candidate); pos_candidates.PushArray(pos_candidate);
            AddVectors(pos_template,{0.0,-16.0,0.0},pos_candidate); pos_candidates.PushArray(pos_candidate);
            AddVectors(pos_template,{0.0,0.0,16.0},pos_candidate); pos_candidates.PushArray(pos_candidate);
        }
    }

    // --- Enhanced 3D terrain candidates (buildings, mountains, highlands) ---
    // For large elevation gaps, sample z-stepped positions along the path.
    // This helps navigate multi-floor buildings and steep outdoor terrain where
    // the simple linear candidates above all fail due to intermediate geometry.
    float dz_abs = FloatAbs(diff[2]);
    if (dz_abs > 50.0)
    {
        int z_steps = (dz_abs > 200.0) ? 6 : 3;
        float dz_frac = 1.0 / float(z_steps + 1);
        for (int zi = 1; zi <= z_steps; zi++)
        {
            float frac = zi * dz_frac;
            pos_candidate[0] = cell_old.center[0] + diff[0] * frac;
            pos_candidate[1] = cell_old.center[1] + diff[1] * frac;
            // Center z at proportional height
            pos_candidate[2] = cell_old.center[2] + diff[2] * frac;
            pos_candidates.PushArray(pos_candidate);
            // Try slightly above (next floor up)
            pos_candidate[2] += 32.0;
            pos_candidates.PushArray(pos_candidate);
            // Try slightly below (next floor down)
            pos_candidate[2] -= 64.0;
            pos_candidates.PushArray(pos_candidate);
        }

        // Also try intermediate xy positions with z projected from navmesh of either cell
        // This helps for sloped outdoor terrain where the ground curves
        if (cell_old.navArea != Address_Null || cell_new.navArea != Address_Null)
        {
            float frac_mid = 0.5;
            pos_candidate[0] = cell_old.center[0] + diff[0] * frac_mid;
            pos_candidate[1] = cell_old.center[1] + diff[1] * frac_mid;
            pos_candidate[2] = cell_old.center[2] + diff[2] * frac_mid;

            // Try projecting onto old cell's navmesh z
            if (cell_old.navArea != Address_Null)
            {
                float proj_z = L4D_NavArea_GetZ(cell_old.navArea, pos_candidate);
                if (proj_z > -9000.0)
                {
                    pos_candidate[2] = proj_z + 16.0;
                    pos_candidates.PushArray(pos_candidate);
                    pos_candidate[2] += 24.0;
                    pos_candidates.PushArray(pos_candidate);
                }
            }
            // Try projecting onto new cell's navmesh z
            if (cell_new.navArea != Address_Null)
            {
                float proj_z = L4D_NavArea_GetZ(cell_new.navArea, pos_candidate);
                if (proj_z > -9000.0)
                {
                    pos_candidate[2] = proj_z + 16.0;
                    pos_candidates.PushArray(pos_candidate);
                    pos_candidate[2] += 24.0;
                    pos_candidates.PushArray(pos_candidate);
                }
            }
            // Try average z (midway between the two cells' z, but at midpoint xy)
            pos_candidate[2] = (cell_old.center[2] + cell_new.center[2]) * 0.5;
            pos_candidates.PushArray(pos_candidate);
        }
    }

    // Priority: projected first, then stragglers.
    ArrayList pos_candidates2 = new ArrayList(3); // lower priority candidates

    bool success = false;
    bool priority = elevator_available;
    while (!success)
    {
        int length = (priority) ? pos_candidates.Length : pos_candidates2.Length;
        for (int i = 0; i<length; i++) 
        {
            bool projected = false;
            if (priority) pos_candidates.GetArray(i,pos_candidate,sizeof(pos_candidate));
            else pos_candidates2.GetArray(i,pos_candidate,sizeof(pos_candidate));
            pos_template = pos_candidate;
            if (priority && elevator_available) // try to project xy onto navmesh z
            {
                // Get appropriate z value for given xy position. Useful for slopes, stairs etc.
                projected = project_navmesh_xy(cell_new.navArea,pos_candidate);
                if (!projected) projected = project_navmesh_xy(cell_old.navArea,pos_candidate);
                if (projected)
                {
                    pos_candidate[2] += 16.0;
                    projected = GetVectorDistance(pos_template,pos_candidate,true)>5.0; // if we're in the exact same place, doesn't matter
                }
            }
            if (pos_underwater(pos_candidate))
            {
                pos_candidate[2] += 16.0;
                if (pos_underwater(pos_candidate)) pos_candidate[2] += 16.0;
            }
            bool traversable = twopos_traversable(cell_new.center,pos_candidate) && twopos_traversable(cell_old.center,pos_candidate);
            if (!traversable)
            {
                if (!projected) continue;
                pos_candidates2.PushArray(pos_template); // Try non-projected candidate later
                continue;
            }
            float d_flow = GetVectorDistance(cell_old.center,pos_candidate);
            cell.flow = cell_old.flow + d_flow;
            if (cell.flow>=cell_new.flow) cell.flow = (cell_old.flow + cell_new.flow)/2.0;
            cell.navArea = Address_Null;
            cell.center = pos_candidate;
            if (prev2 && triple_valid_ground(cell_prev2.center,cell.center) && twopos_traversable(cell.center,cell_prev2.center))
                cells.SetArray(cells.Length-1,cell,sizeof(Cell));
            else
                cells.PushArray(cell);
            success = true;
            break;
        }
        if (priority) priority = false; // try unprojected candidates now
        else break;
    }
    delete pos_candidates;
    delete pos_candidates2;
    if (success)
    {
        cells.PushArray(cell_new);
        return true;
    }
    
    navAreas[0] = cell_new.navArea;
    navAreas[1] = cell_old.navArea;
    ArrayList adjAreas = new ArrayList();
    for (int i_nav = 0; i_nav < sizeof(navAreas); i_nav++) // Check adjacent areas
    {
        Address navArea = navAreas[i_nav];
        if (navArea == Address_Null) continue;
        for (int dir = 0; dir < 4; dir++) // Enqueue adjacent nav areas (all 4 directions)
        {
            adjAreas.Clear();
            L4D_NavArea_GetAdjacentAreas(navArea, dir, adjAreas);
            for (int i = 0; i < adjAreas.Length; i++)
            {
                Address adjArea = adjAreas.Get(i);
                if (adjArea == Address_Null) continue;
                if (blocked_available && L4D_NavArea_IsBlocked(adjArea,TEAM_SURVIVOR,true)) continue;
                for (int i_try = 0; i_try < 2; i_try++)
                {
                    if (i_try == 0) L4D_GetNavAreaCenter(adjArea,pos_candidate);
                    else L4D_GetNavAreaPos(adjArea,pos_candidate);
                    pos_candidate[2] += 16.0;
                    if (pos_underwater(pos_candidate)) pos_candidate[2] += 16.0;
                    if (twopos_traversable(pos_candidate,cell_new.center) && twopos_traversable(pos_candidate,cell_old.center))
                    {
                        float d_flow = GetVectorDistance(cell_old.center,pos_candidate);
                        cell.flow = cell_old.flow + d_flow;
                        if (cell.flow>=cell_new.flow) cell.flow = (cell_old.flow + cell_new.flow)/2.0;
                        cell.navArea = adjArea;
                        cell.center = pos_candidate;
                        cells.PushArray(cell);
                        cells.PushArray(cell_new);
                        delete adjAreas;
                        return true;
                    }
                }
            }
        }
    }
    delete adjAreas;

    return success;
}

// Two vector positions do not have LOS. See if a vector position inbetween can fix it. Ground to accept only grounded positions.
// Result stored in pos_mid. Returns true on success.
bool LOS_rescue_cheap(float pos1[3], float pos2[3], float pos_mid[3] = {0.0,0.0,0.0}, bool ground = false)
{
    static float diff[3], diff_candidate[3];
    SubtractVectors(pos2,pos1,diff);
    
    // dx only
    if (FloatAbs(diff[0])>=5.0)
    {
        diff_candidate = diff; diff_candidate[1] = 0.0; diff_candidate[2] = 0.0;
        AddVectors(pos1,diff_candidate,pos_mid);
        if ( (!ground || valid_ground(pos_mid)) && twopos_traversable(pos_mid,pos1) && twopos_traversable(pos_mid,pos2) ) return true;
    }

    // dy only
    if (FloatAbs(diff[1])>=5.0)
    {
        diff_candidate = diff; diff_candidate[0] = 0.0; diff_candidate[2] = 0.0;
        AddVectors(pos1,diff_candidate,pos_mid);
        if ( (!ground || valid_ground(pos_mid)) && twopos_traversable(pos_mid,pos1) && twopos_traversable(pos_mid,pos2) ) return true;
    }

    // dz only
    if (FloatAbs(diff[2])>=5.0)
    {
        diff_candidate = diff; diff_candidate[0] = 0.0; diff_candidate[1] = 0.0;
        AddVectors(pos1,diff_candidate,pos_mid);
        if ( (!ground || valid_ground(pos_mid)) && twopos_traversable(pos_mid,pos1) && twopos_traversable(pos_mid,pos2) ) return true;
    }

    return false;
}

// Check if client is on cooldown for drawing beams
bool beams_cooldown(int client)
{
    //return false;
    //if (playertime.t_engine<0.0 && playertime.t_game<0.0) return false;
    if (g_PlayerTime[client].t_game<=0.0) return false;
    //if ( (playertime.t_engine+playertime.t_cooldown/2.0)>=GetEngineTime() ) return true;
    if ( (g_PlayerTime[client].t_game+g_PlayerTime[client].t_cooldown)>GetGameTime() ) return true;
    return false;
}

// Client just rendered beams for given duration. Set cooldown to half the duration.
void beams_cooldown_update(int client, float duration = -1.0)
{
    static PlayerTime playertime;
    playertime = g_PlayerTime[client];
    if (duration < 0.0)
    {
        duration = playertime.t_cooldown;
        if (duration < 0.0) return;
    }
    else duration /= 2.0;
    if (duration<0.1) duration = 0.1; // reduce server load
    //playertime.t_engine = GetEngineTime();
    playertime.t_game = GetGameTime();
    playertime.t_cooldown = duration;
    g_PlayerTime[client] = playertime;
    g_CellRequests[client].duration = -1.0;
}

// Reset all beam cooldowns. If client is specified, reset only for that client
// If request, reset beam requests too
void beams_cooldown_reset(int client = -1, bool request = false)
{
    if (!enable) return;
    static PlayerTime playertime;
    if (client>0)
    {
        playertime = g_PlayerTime[client];
        playertime.t_game = -1.0; playertime.t_engine = -1.0; playertime.t_cooldown = -1.0;
        g_PlayerTime[client] = playertime;
        if (request) g_CellRequests[client].duration = -1.0;
        return;
    }
    for (int i = 1; i <= MaxClients; i++)
    {
        playertime = g_PlayerTime[i];
        playertime.t_game = -1.0; playertime.t_engine = -1.0; playertime.t_cooldown = -1.0;
        g_PlayerTime[i] = playertime;
        if (request) g_CellRequests[i].duration = -1.0;
    }
}

// SortFlow removed — no longer needed with A* pipeline

// Test if it's possible to travel to cell position from given position
bool cell_traversable(int i, float pos[3], bool world_only = true, float max_distance = -1.0)
{
    static Cell cell;
    g_GuideCells.GetArray(i,cell,sizeof(Cell));
    return twopos_traversable(pos,cell.center,world_only,max_distance);
}

//static int MASK_PTG = MASK_PLAYERSOLID | MASK_VISIBLE | CONTENTS_DETAIL;
static int MASK_PTG = MASK_PLAYERSOLID;

#define DX_HULL 8.0
#define DZ_HULL 30.0

// Test if you can travel between two vector positions without an obstruction. world_only to hit only world and static props. ladder to accept traversability if ladder was hit
bool twopos_traversable(float pos1[3], float pos2[3], bool world_only = true, float max_distance = -1.0, bool hull = true)
//bool twopos_traversable(float pos1[3], float pos2[3], bool world_only = true, float max_distance = -1.0, bool hull = true, bool ladder = true)
{
    //g_bHitLadder = false;
    if (max_distance>0.0 && GetVectorDistance(pos1,pos2)>max_distance) return false;
    if (hull)
    {
        if (world_only) TR_TraceHullFilter(pos1,pos2,{-DX_HULL,-DX_HULL,1.0},{DX_HULL,DX_HULL,DZ_HULL},MASK_PTG,TraceFilterStatic);
        else            TR_TraceHullFilter(pos1,pos2,{-DX_HULL,-DX_HULL,1.0},{DX_HULL,DX_HULL,DZ_HULL},MASK_PTG,TraceFilterNoClients);
    }
    else
    {
       if (world_only) TR_TraceRayFilter(pos1,pos2,MASK_PTG,RayType_EndPoint,TraceFilterStatic);
       else TR_TraceRayFilter(pos1,pos2,MASK_PTG,RayType_EndPoint,TraceFilterNoClients);
    }
    //if (ladder && g_bHitLadder) return true;
    if (!TR_DidHit(INVALID_HANDLE)) return true;
    #if DEBUG
    g_iHitEntity = TR_GetEntityIndex(INVALID_HANDLE);
    g_iHitSurfaceProps = TR_GetSurfaceProps(INVALID_HANDLE);
    g_iHitSurfaceFlags = TR_GetSurfaceFlags(INVALID_HANDLE);
    TR_GetSurfaceName(INVALID_HANDLE,g_sHitSurfaceName,sizeof(g_sHitSurfaceName));
    #endif
    return false;
}

bool TraceFilterStatic(int entity, int contentsMask)
{
    if (entity == 0)
    {
        //LogMessage("TraceFilterStatic hit %d", entity);
        return true;
    }
    if (entity > 0 && entity <= MaxClients) return false;
    static char class[16];
    GetEntityClassname(entity,class,sizeof(class));
    //LogMessage("TraceFilterStatic hit %d %s", entity, class);
    switch (class[0])
    {
        case 'p':
        {
            if (strncmp(class,"prop_static",11,false)==0) return true;
        }
        case 'f':
        {
            if (strncmp(class,"func_brush",10,false)==0) return true;
            if (strncmp(class,"func_simpleladder",17,false)==0) return false;
            //g_bHitLadder = strncmp(class,"func_simpleladder",17,false)==0;
        }
    }
    return false;
}

bool TraceFilterNoClients(int entity, int contentsMask)
{
    if (entity > 0 && entity <= MaxClients) return false;
    return true;
}

stock bool pos_underwater(const float pos[3])
{
	static float top[3], bottom[3];
    bottom = pos;
    top = pos; top[2] += 64.0;
	TR_TraceRay(top,bottom,MASK_WATER,RayType_EndPoint);
	if (TR_DidHit(INVALID_HANDLE)) return true;
    return false;
}

// Get midpoint between pos1 and pos2.
stock void get_midpoint(float pos1[3], float pos2[3], float pos_mid[3])
{
    static float vDiff[3];
    MakeVectorFromPoints(pos1,pos2,vDiff);
    ScaleVector(vDiff,0.5);
    AddVectors(pos1,vDiff,pos_mid);
}

// Try to project pos onto line between pos_start and pos_end. Update pos_mid if success.
stock bool project_forward(float pos_start[3], float pos_end[3], float pos[3], float pos_mid[3])
{
    static float vDiff[3], vDiff2[3];
    MakeVectorFromPoints(pos_start,pos_end,vDiff);
    float mag_sq = GetVectorDotProduct(vDiff,vDiff);
    if (mag_sq<=0.0) return false;
    MakeVectorFromPoints(pos_start,pos,vDiff2);
    float dot = GetVectorDotProduct(vDiff,vDiff2);
    if (dot<=0.0) return false; // not pointing in the right direction
    float scale = dot/mag_sq;
    if (scale>=0.999 || scale<=0.001) return false; // projection is crappy
    ScaleVector(vDiff,scale);
    AddVectors(pos_start,vDiff,pos_mid);
    return true;
}

#define DZ_TOO_HIGH 50.0 // how high survivors can jump
#define DZ_TOO_LOW 200.0 // fall damage

// See if going from pos1 to pos2 is too steep (potentially dangerous, or obstacle too tall.)
// This is mostly useless.
stock bool vecdiff_too_steep(float pos1[3], float pos2[3])
{
    static float diff[3];
    SubtractVectors(pos2,pos1,diff); // how to move to go from from pos1 to pos2
    if (FloatAbs(diff[2])<=DZ_TOO_HIGH) return false;
    float length = GetVectorLength(diff);
    if (length<=DZ_TOO_HIGH) return false;
    float ratio = diff[2] / length;
    return FloatAbs(ratio)>=0.75;
}

stock bool cell_step_too_steep(Cell cell_before,Cell cell_after)
{
    if (cell_before.navArea != Address_Null && cell_after.navArea != Address_Null)
        return nav_too_steep(cell_before.navArea,cell_after.navArea);
    return vecdiff_too_steep(cell_before.center,cell_after.center);
    //float dz = FloatAbs(cell_before.center[2]-cell_after.center[2]);
    //return dz >= DZ_TOO_HIGH;
}

// See if from -> to is too steep
stock bool nav_too_steep(Address from, Address to)
{
    if (from==Address_Null || to==Address_Null) return false;
    static float pos1[3], pos2[3];
    L4D_GetNavAreaCenter(from,pos1);
    L4D_GetNavAreaCenter(to,pos2);
    float dz = pos2[2]-pos1[2];
    bool up = dz >= 0.0;
    dz = FloatAbs(dz);
    if (dz<DZ_TOO_HIGH) return false;
    static float size1[3], size2[3];
    L4D_GetNavAreaSize(from,size1);
    L4D_GetNavAreaSize(to,size2);
    dz -= FloatAbs(size1[2]/2.0);
    dz -= FloatAbs(size2[2]/2.0);
    if (up) return dz>=DZ_TOO_HIGH;
    else return dz>=DZ_TOO_LOW;
}

// Check if ground is valid at both positions and inbetween.
stock bool triple_valid_ground(float pos1[3], float pos2[3])
{
    if (!valid_ground(pos1)) return false;
    if (!valid_ground(pos2)) return false;
    return midpoint_valid_ground(pos1,pos2);
}

// Check if midpoint between two vector positions is reasonably close to the ground.
stock bool midpoint_valid_ground(float pos1[3], float pos2[3])
{
    static float diff[3], pos_mid[3];
    SubtractVectors(pos2,pos1,diff); // how to move to go from from pos1 to pos2
    if (GetVectorLength(diff,true)<=4096.0) return true;
    ScaleVector(diff,0.5);
    AddVectors(pos1,diff,pos_mid);
    return valid_ground(pos_mid);
}

#define GROUND_WIDTH 16.0

stock bool valid_ground(float pos[3])
{
    static float pos_down[3];
    pos_down = pos; pos_down[2] -= 48.0;
    TR_TraceHullFilter(pos,pos_down,{-GROUND_WIDTH,-GROUND_WIDTH,2.0},{GROUND_WIDTH,GROUND_WIDTH,5.0},MASK_PTG|MASK_WATER,TraceFilterStatic);
    return TR_DidHit(INVALID_HANDLE);
    //if (TR_DidHit(INVALID_HANDLE))
    //{
        //static float pos_hit[3],normal[3];
        //TR_GetPlaneNormal(INVALID_HANDLE,normal);
        //LogMessage("Ground hit %f %f %f", normal[0], normal[1], normal[2]);
    //    return true;
    //}
    // TR_GetEndPosition(float pos[3], Handle hndl)
    // TR_GetPlaneNormal(Handle hndl, float normal[3])
    //return false;
}

// Determine if entity is solid to players and zombies from m_CollisionGroup, m_nSolidType and m_usSolidFlags
stock bool entity_solid(int entity)
{
    if (GetEntProp(entity, Prop_Send, "m_nSolidType") == 0) return false;
    if (GetEntProp(entity, Prop_Send, "m_usSolidFlags") & 0x0004) return false; // FSOLID_NOT_SOLID 
    switch (GetEntProp(entity, Prop_Send, "m_CollisionGroup"))
    {
        case 1: return false; // COLLISION_GROUP_DEBRIS
        case 2: return false; // COLLISION_GROUP_DEBRIS_TRIGGER
    }
    return true;
}

///////////// Connections

// Fill conList with NavConnection (navArea+connection_type) to navArea. returns length of array
stock int GetNavConnections(Address navArea, ArrayList conList, int team = TEAM_SURVIVOR,
                            bool adjacent = true, bool elevator = true, bool ladder = true, int filter = CON_KEEP_FORWARD)
{
    if (navArea == Address_Null) return 0;
    conList.Clear();
    ArrayList tempList = new ArrayList();
    static NavConnection nav_connection;
    Address adjArea;
    int i;
    if (adjacent)
    {
        for (int dir = 0; dir < 4; dir++)
        {
            tempList.Clear();
            L4D_NavArea_GetAdjacentAreas(navArea, dir, tempList);
            for (i = 0; i < tempList.Length; i++)
            {
                adjArea = tempList.Get(i);
                if (adjArea == Address_Null || adjArea == navArea) continue;
                if (navmesh_adjacent_too_far(navArea,adjArea))
                {
                    #if DEBUG>1
                        LogMessage("navmesh_adjacent_too_far %d -> %d", navArea, adjArea);
                    #endif
                    continue;
                }
                switch (filter)
                {
                    case CON_KEEP_FORWARD:
                    {
                        if (!adjacent_connected(navArea,adjArea)) continue;
                    }
                    case CON_KEEP_BACKWARD:
                    {
                        if (!adjacent_connected(adjArea,navArea)) continue;
                    }
                    default: // CON_KEEP_ALL
                    {
                        if (!adjacent_connected(navArea,adjArea) && !adjacent_connected(adjArea,navArea)) continue;
                    }
                }
                nav_connection.navArea = adjArea;
                nav_connection.connectiontype = CONNECTED_ADJACENT;

                // Detect one-way drop-down connections in the nav mesh itself.
                // Source Engine nav mesh uses directed edges: a one-way edge from
                // higher→lower means "you can drop down" — correct for zombie AI
                // but wrong for a human player guide. Reclassify these as JUMP_DOWN.
                if (!adjacent_connected(adjArea, navArea))
                {
                    float cFrom[3], cTo[3];
                    L4D_GetNavAreaCenter(navArea, cFrom);
                    L4D_GetNavAreaCenter(adjArea, cTo);
                    if (cFrom[2] - cTo[2] > 48.0)
                    {
                        nav_connection.connectiontype = CONNECTED_JUMP_DOWN;
                    }
                }

                conList.PushArray(nav_connection);
            }
        }
    }
    if (elevator && team!=TEAM_INFECTED) // typically only survivors can use elevators
    {
        adjArea = navArea_elevator_navArea(navArea);
        if (adjArea != Address_Null)
        {
            nav_connection.navArea = adjArea;
            nav_connection.connectiontype = CONNECTED_ELEVATOR;
            conList.PushArray(nav_connection);
        }
    }
    if (ladder)
    {
        int count = navArea_ladder_navAreas(navArea,tempList,team);
        for (i = 0; i < count; i++)
        {
            adjArea = tempList.Get(i);
            nav_connection.navArea = adjArea;
            nav_connection.connectiontype = CONNECTED_LADDER;
            conList.PushArray(nav_connection);
        }                
    }
    delete tempList;
    return conList.Length;
}

// Check if connection from -> to can be made.
// check_ladder manually searches for nearby func_simpleladder
//stock bool cell_connected(Cell from, Cell to)
stock bool cell_connected(Cell from, Cell to, bool check_ladder = true)
{
    if (from.navArea != Address_Null && to.navArea != Address_Null)
    { 
        if (navArea_connected(from.navArea,to.navArea)) return true;
    }
    if (check_ladder) // manual ladder search, expensive
    {
        static Cell cell;
        if (try_ladder(from.flow,from.center,cell) && cell_connected(cell,to,false)) return true;
    }
    return false;
}

// Check if connection from -> to can be made.
stock bool navArea_connected(Address from, Address to, int team = TEAM_SURVIVOR)
{
    if (from == Address_Null || to == Address_Null) return false;
    if (from == to) return true;
    if (elevator_from_to(from,to)>0) return true;
    if (ladder_from_to(from,to,team)>0) return true;
    if (navmesh_adjacent_too_far(from,to))
    {
        #if DEBUG>1
            LogMessage("navmesh_adjacent_too_far %d -> %d", from, to);
        #endif
        return false;
    }
    return adjacent_connected(from,to);
}

// Check if from -> to is connected adjacently
stock bool adjacent_connected(Address from, Address to)
{
    for (int dir = 0; dir < 4; dir++)
    {
        if (L4D_NavArea_IsConnected(from,to,dir)) return true;
    }
    return false;
}

ArrayList ladders1, ladders2;

// Return func_simpleladder connecting from -> to. returns -1 on failure.
stock int ladder_from_to(Address from, Address to, int team = TEAM_SURVIVOR)
{
    if (from == Address_Null || to == Address_Null) return -1;
    if (ladders1 == null) ladders1 = new ArrayList();
    ladders1.Clear();
    int count1 = NavArea_GetLadders(from,ladders1);
    if (count1<=0) return -1;

    if (ladders2 == null) ladders2 = new ArrayList();
    ladders2.Clear();
    int count2 = NavArea_GetLadders(to,ladders2);
    if (count2<=0) return -1;

    for (int i1 = 0; i1 < ladders1.Length; i1++)
    {
        int ladder = ladders1.Get(i1);
        if (ladder<=0 || !IsValidEntity(ladder)) continue;
        for (int i2 = 0; i2 < ladders2.Length; i2++)
        {
            if (ladders2.Get(i2)==ladder)
            {
                int team_ladder = GetEntProp(ladder, Prop_Send, "m_iTeamNum");
                if (team_ladder==0 || team_ladder==team) return ladder;
            }
        }
    }
    return -1;
}

// Find other navAreas connected to navArea via ladder.
stock int navArea_ladder_navAreas(Address from, ArrayList navList, int team = TEAM_SURVIVOR)
{
    if (from==Address_Null || !elevator_available) return 0;
    if (ladders1 == null) ladders1 = new ArrayList();
    ladders1.Clear();
    int count = NavArea_GetLadders(from,ladders1);
    if (count<=0) return 0;
    navList.Clear();
    static float start[3];
    L4D_GetNavAreaCenter(from,start);
    for (int i = 0; i < ladders1.Length; i++)
    {
        int ladder = ladders1.Get(i);
        if (ladder<=0 || !IsValidEntity(ladder)) continue;
        int team_ladder = GetEntProp(ladder, Prop_Send, "m_iTeamNum");
        if (team_ladder!=0 && team_ladder!=team) continue;
        static float pos1[3],pos2[3];
        GetEntPropVector(ladder, Prop_Send, "m_vecMaxs", pos1);
        GetEntPropVector(ladder, Prop_Send, "m_vecMins", pos2);
        SortTwoVectorsClosest(start,pos1,pos2);
        if (navmesh_xy_too_far(from,pos1)) continue;
        Address to = L4D_GetNearestNavArea(pos2,500.0,true,false,false,TEAM_SURVIVOR);
        #if DEBUG>1
        LogMessage("navArea_ladder_navAreas %d -> %d", from, to);
        #endif
        if (to==Address_Null || to==from) continue;
        navList.Push(to);
    }
    return navList.Length;
}

// Fill ladderList with func_simpleladder connected to navArea.
stock int NavArea_GetLadders(Address navArea, ArrayList ladderList)
{
    if (!elevator_available || navArea == Address_Null) return 0;
    return L4D_NavArea_GetLadder(navArea,ladderList);
}

// Return func_elevator connecting from -> to. returns -1 on failure.
stock int elevator_from_to(Address from, Address to)
{
    if (!elevator_available || from == Address_Null || to == Address_Null) return -1;
    int elevator = L4D_NavArea_GetElevator(from);
    if (elevator<=0 || !IsValidEntity(elevator)) return -1;
    if (elevator == L4D_NavArea_GetElevator(to)) return elevator;
    return -1;
}

// Get other navArea connecting navArea via elevator
stock Address navArea_elevator_navArea(Address from)
{
    if (from==Address_Null || !elevator_available) return Address_Null;
    int elevator = L4D_NavArea_GetElevator(from);
    if (elevator<=0 || !IsValidEntity(elevator)) return Address_Null;
    static float start[3],pos[3],pos1[3],pos2[3];
    L4D_GetNavAreaCenter(from,start);
    GetEntPropVector(elevator, Prop_Send, "m_vecOrigin", pos);
    pos1 = pos; pos2 = pos;
    pos1[2] = GetEntPropFloat(elevator, Prop_Send, "m_movementStartZ");
    pos2[2] = GetEntPropFloat(elevator, Prop_Send, "m_destinationFloorPosition");
    SortTwoVectorsClosest(start,pos1,pos2);
    Address to = L4D_GetNearestNavArea(pos2,500.0,true,false,false,TEAM_SURVIVOR);
    if (to==Address_Null || to==from) return Address_Null;
    return to;
}

// Check if nav area is relevant to survivor escape path.
stock bool navArea_escape(Address navArea)
{
    if (navArea == Address_Null) return false;
    int spawnAttrs = L4D_GetNavArea_SpawnAttributes(navArea);
    if (spawnAttrs & NAV_SPAWN_ESCAPE_ROUTE) return true;
    if (spawnAttrs & NAV_SPAWN_CHECKPOINT) return true;
    if (spawnAttrs & NAV_SPAWN_PLAYER_START) return true;
    if (spawnAttrs & NAV_SPAWN_RESCUE_VEHICLE) return true;
    return false;
}

// Acknowledge navmesh change. Ptg must be recalculated after NAV_COOLDOWN. If recompute, recalculate without cooldown.
// Check if a nav area is on the current guide path.
// Used by dynamic re-planning to decide if a nav_blocked event affects us.
stock bool IsAreaOnPath(Address navArea)
{
    if (g_GuideCells == null || navArea == Address_Null) return false;
    int len = g_GuideCells.Length;
    Cell cell;
    for (int i = 0; i < len; i++)
    {
        g_GuideCells.GetArray(i, cell, sizeof(Cell));
        if (cell.navArea == navArea) return true;
    }
    return false;
}

// Periodic path integrity check — polls g_GuideCells for newly blocked areas.
// Handles cases where nav_blocked events don't fire (prop physics, dynamic obstacles).
// Returns true if path is still valid, false if re-planning was triggered.
stock bool PathIntegrityCheck()
{
    if (!guide_ready || g_GuideCells == null || !blocked_available) return true;

    int len = g_GuideCells.Length;
    if (len < 2) return true;

    // Check ~25% of cells each call (strided sampling, 5s interval)
    // Over ~20s, every cell gets checked at least once
    static int checkOffset = 0;
    int stride = 4;
    if (stride < 1) stride = 1;

    Cell cell;
    int checked = 0;
    int blocked = 0;

    for (int i = checkOffset; i < len; i += stride)
    {
        g_GuideCells.GetArray(i, cell, sizeof(Cell));
        if (cell.navArea != Address_Null && L4D_NavArea_IsBlocked(cell.navArea, TEAM_SURVIVOR, true))
            blocked++;
        checked++;
        if (checked >= 8) break; // limit per-frame work
    }

    checkOffset = (checkOffset + 1) % stride;

    if (blocked > 0)
    {
        LogMessage("[PTG] Path integrity check: %d/%d sampled cells blocked — re-planning", blocked, checked);
        NavChanged(true);
        return false;
    }

    return true;
}

stock void NavChanged(bool recompute = false)
{
    Guide_Cleanup();
    t_nav = GetGameTime();
    if (recompute) t_nav = t_nav - NAV_COOLDOWN + 0.1;
    if (!enable || !gamemode_guidable || !map_started || !nav_started || timer_nav != null) return;
    if (finale && finale_rescue && finale_stitched && g_hCvarFinaleAuto.BoolValue) Guide_All_Clients();
    else timer_nav = CreateTimer( (recompute) ? 0.1 : NAV_COOLDOWN , Timer_CheckRequests, _, TIMER_FLAG_NO_MAPCHANGE );
}

// return true if given flow value is better than old value. increasing=true if better is bigger.
stock bool flow_better(const float flow_new, const float flow_old, const bool increasing = true)
{
    if (increasing) return (flow_new)>=flow_old;
    else return (flow_new)<=flow_old;
}

stock bool IsValidClient(int client, bool replaycheck = true)
{
	if (client<1 || client>MaxClients) return false;
	if (!IsClientInGame(client)) return false;
	if (replaycheck)
	{
		if (IsClientSourceTV(client) || IsClientReplay(client)) return false;
	}
	return true;
}

// ============================================================================
// Binary Heap (Min-Heap) for A* Priority Queue
// Ordered by fScore. Lazy deletion: stale entries are skipped on pop.
// ============================================================================

// Bubble up from index i
stock void Heap_BubbleUp(ArrayList heap, int i)
{
    if (i <= 0) return;
    HeapEntry current, parent;
    while (i > 0)
    {
        int pi = (i - 1) / 2;
        heap.GetArray(i, current, sizeof(HeapEntry));
        heap.GetArray(pi, parent, sizeof(HeapEntry));
        if (current.fScore >= parent.fScore) break;
        // swap
        heap.SetArray(i, parent, sizeof(HeapEntry));
        heap.SetArray(pi, current, sizeof(HeapEntry));
        i = pi;
    }
}

// Bubble down from index i
stock void Heap_BubbleDown(ArrayList heap, int i)
{
    int size = heap.Length;
    if (size <= 1) return;
    HeapEntry current, child, temp;
    while (true)
    {
        int left = 2 * i + 1;
        int right = 2 * i + 2;
        int smallest = i;

        heap.GetArray(i, current, sizeof(HeapEntry));

        if (left < size)
        {
            heap.GetArray(left, child, sizeof(HeapEntry));
            if (child.fScore < current.fScore) smallest = left;
        }
        if (right < size)
        {
            heap.GetArray(right, child, sizeof(HeapEntry));
            heap.GetArray(smallest, temp, sizeof(HeapEntry));
            if (child.fScore < temp.fScore) smallest = right;
        }
        if (smallest == i) break;

        // swap
        heap.GetArray(smallest, child, sizeof(HeapEntry));
        heap.SetArray(i, child, sizeof(HeapEntry));
        heap.SetArray(smallest, current, sizeof(HeapEntry));
        i = smallest;
    }
}

stock void Heap_Push(ArrayList heap, int nodeIndex, float fScore, float gScore)
{
    HeapEntry entry;
    entry.nodeIndex = nodeIndex;
    entry.fScore = fScore;
    entry.gScore = gScore;
    heap.PushArray(entry, sizeof(HeapEntry));
    Heap_BubbleUp(heap, heap.Length - 1);
}

// Pop the entry with lowest fScore. Returns false if heap is empty.
stock bool Heap_Pop(ArrayList heap, HeapEntry outEntry)
{
    if (heap.Length == 0) return false;

    // Get root
    heap.GetArray(0, outEntry, sizeof(HeapEntry));

    // Move last to root
    int last = heap.Length - 1;
    if (last > 0)
    {
        HeapEntry lastEntry;
        heap.GetArray(last, lastEntry, sizeof(HeapEntry));
        heap.SetArray(0, lastEntry, sizeof(HeapEntry));
    }
    heap.Resize(last);

    if (heap.Length > 0)
        Heap_BubbleDown(heap, 0);

    return true;
}

// ============================================================================
// Spatial Hash — fast O(k) nearby-nav-area queries
// ============================================================================

stock void SpatialHash_Insert(float center[3], int navAreaInt)
{
    int cx = RoundToFloor(center[0] / SPATIAL_CELL_SIZE);
    int cy = RoundToFloor(center[1] / SPATIAL_CELL_SIZE);
    int cz = RoundToFloor(center[2] / SPATIAL_CELL_SIZE);

    char key[32];
    Format(key, sizeof(key), "%d_%d_%d", cx, cy, cz);

    ArrayList cellList;
    if (!g_hSpatialHash.GetValue(key, cellList))
    {
        cellList = new ArrayList(2); // entry: {navArea(int), float[3] center}
        g_hSpatialHash.SetValue(key, cellList);
    }

    // Cap cell size to prevent perf issues on dense nav meshes
    if (cellList.Length >= 64) return;

    cellList.Push(navAreaInt);
    cellList.PushArray(center, 3);
}

// Query: fill result with navArea addresses (as int) within range of pos
// checkRange: how many spatial cells to check in each axis (1 = 3x3x3, 2 = 5x5x5)
stock void SpatialHash_Query(float pos[3], ArrayList result, float maxDist = 512.0, int checkRange = 1)
{
    result.Clear();
    int cx = RoundToFloor(pos[0] / SPATIAL_CELL_SIZE);
    int cy = RoundToFloor(pos[1] / SPATIAL_CELL_SIZE);
    int cz = RoundToFloor(pos[2] / SPATIAL_CELL_SIZE);

    float maxDistSq = maxDist * maxDist;

    for (int dx = -checkRange; dx <= checkRange; dx++)
    {
        for (int dy = -checkRange; dy <= checkRange; dy++)
        {
            for (int dz = -checkRange; dz <= checkRange; dz++)
            {
                char key[32];
                Format(key, sizeof(key), "%d_%d_%d", cx + dx, cy + dy, cz + dz);

                ArrayList cellList;
                if (!g_hSpatialHash.GetValue(key, cellList)) continue;

                int count = cellList.Length;
                for (int i = 0; i < count; i += 2) // stride 2: {int, float[3]}
                {
                    int areaInt = cellList.Get(i);
                    float areaCenter[3];
                    cellList.GetArray(i + 1, areaCenter, 3);

                    float distSq = GetVectorDistance(pos, areaCenter, true);
                    if (distSq <= maxDistSq)
                        result.Push(areaInt);
                }
            }
        }
    }
}

// ============================================================================
// Physics-based Jump Validation — replaces hardcoded thresholds with actual
// trajectory traces using the PlayerCaps capability model.
// ============================================================================

// Validate a jump arc between two points by tracing a parabolic trajectory.
// Uses 10-sample hull trace to verify the path is clear for a crouching player.
stock bool ValidateJumpArc(const float from[3], const float to[3], PlayerCaps caps)
{
    float dx = to[0] - from[0];
    float dy = to[1] - from[1];
    float dz = to[2] - from[2];
    float distXY = SquareRoot(dx * dx + dy * dy);
    if (distXY < 1.0) return true;

    // Parabola bulge: how much the arc rises above the straight line at midpoint
    float midZ = (from[2] + to[2]) / 2.0;
    float apexZ = ((from[2] > to[2]) ? from[2] : to[2]) + caps.max_jump_height * 0.6;
    float h = apexZ - midZ;
    if (h < caps.max_step_up) h = caps.max_jump_height * 0.3;

    float lowMins[3] = {-10.0, -10.0, 0.0};
    float lowMaxs[3] = { 10.0,  10.0, 32.0};

    float prev[3], curr[3];
    prev = from;
    prev[2] += 28.0; // standing height

    int samples = 10;
    for (int i = 1; i <= samples; i++)
    {
        float s = float(i) / float(samples);
        curr[0] = from[0] + dx * s;
        curr[1] = from[1] + dy * s;
        curr[2] = from[2] + dz * s + 4.0 * h * s * (1.0 - s) + 28.0;

        if (!TryHull(prev, curr, lowMins, lowMaxs))
            return false;
        prev = curr;
    }
    return true;
}

// Validate a drop-down connection by tracing vertically from the higher point.
// Verifies the drop is within safe height and landing area is clear.
stock bool ValidateDropArc(const float from[3], const float to[3], PlayerCaps caps)
{
    float dz = to[2] - from[2];
    if (dz > 0.0 || FloatAbs(dz) > caps.max_safe_drop) return false;
    if (FloatAbs(dz) < caps.max_step_up) return true; // small step, no validation needed

    float dropStart[3], dropEnd[3];
    dropStart = from;
    dropStart[2] -= 4.0; // start slightly below feet
    dropEnd[0] = from[0];
    dropEnd[1] = from[1];
    dropEnd[2] = to[2] + 8.0; // land slightly above target

    float slimMins[3] = {-8.0, -8.0, 1.0};
    float slimMaxs[3] = { 8.0,  8.0, 36.0};

    return TryHull(dropStart, dropEnd, slimMins, slimMaxs);
}

// ============================================================================
// Non-Mesh Connection Detection
// ============================================================================

// Detect all non-mesh connections between nav areas. Called once per map load.
// Uses spatial hash + nav area attributes (CROUCH, JUMP, BREAKABLEWALL, etc.)
// Distributed across frames via OnFramePrep for large maps.
int g_iNonMeshI;               // current scan index for frame distribution
ArrayList g_hNonMeshNearby;    // reusable nearby query result

stock void DetectNonMeshConnections_Init()
{
    delete g_hNonMeshEdges;
    g_hNonMeshEdges = new ArrayList(sizeof(NonMeshEdge));
    g_iNonMeshI = 0;
    if (g_hNonMeshNearby == null)
        g_hNonMeshNearby = new ArrayList();
}

// Returns true when detection is complete
stock bool DetectNonMeshConnections_Frame()
{
    if (g_hAStarNodes == null || g_hAStarCenters == null)
    {
        LogMessage("[PTG] DetectNonMesh: nodes not built yet");
        return true;
    }

    float t = GetEngineTime();
    int nodeCount = g_hAStarNodes.Length;
    int processed = 0;

    while (g_iNonMeshI < nodeCount)
    {
        if (processed >= 150 && ((GetEngineTime() - t) * 1000.0) > g_hCvarBudget.FloatValue)
            return false; // continue next frame

        int areaInt = g_hAStarNodes.Get(g_iNonMeshI);
        float center[3];
        g_hAStarCenters.GetArray(g_iNonMeshI, center, 3);

        // Query nearby areas via spatial hash
        SpatialHash_Query(center, g_hNonMeshNearby, 320.0, 1);

        // Track area attributes (for crouch/jump/breakable detection)
        Address areaAddr = view_as<Address>(areaInt);
        int attrs = (elevator_available) ? L4D_GetNavArea_AttributeFlags(areaAddr) : 0;
        bool crouchArea = (attrs & NAV_BASE_CROUCH) != 0;
        bool noJumpArea = (attrs & NAV_BASE_NO_JUMP) != 0;
        bool breakableArea = (attrs & NAV_BASE_BREAKABLEWALL) != 0;

        for (int j = 0; j < g_hNonMeshNearby.Length; j++)
        {
            int otherInt = g_hNonMeshNearby.Get(j);
            if (otherInt == areaInt) continue;

            // Skip if already connected via nav mesh
            if (navArea_connected(areaAddr, view_as<Address>(otherInt))) continue;

            // Find other area's node index
            char key[16];
            IntToString(otherInt, key, sizeof(key));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(key, otherIdx)) continue;

            float otherCenter[3];
            g_hAStarCenters.GetArray(otherIdx, otherCenter, 3);

            float dz = otherCenter[2] - center[2];
            float dzAbs = FloatAbs(dz);
            float xyDist = GetVectorDistance(center, otherCenter, false);

            Address otherAddr = view_as<Address>(otherInt);
            int otherAttrs = (elevator_available) ? L4D_GetNavArea_AttributeFlags(otherAddr) : 0;
            bool otherCrouch = (otherAttrs & NAV_BASE_CROUCH) != 0;
            bool otherNoJump = (otherAttrs & NAV_BASE_NO_JUMP) != 0;
            bool otherBreakable = (otherAttrs & NAV_BASE_BREAKABLEWALL) != 0;

            NonMeshEdge edge;
            edge.fromArea = areaInt;
            edge.toArea = otherInt;
            bool detected = false;

            // --- JUMP_UP: jump from lower to higher (PlayerCaps validated) ---
            if (!detected && !noJumpArea && !otherNoJump
                && dz >= g_Caps.max_step_up && dz <= g_Caps.max_jump_height
                && xyDist < 80.0)
            {
                if (ValidateJumpArc(center, otherCenter, g_Caps))
                {
                    edge.edgeType = CONNECTED_JUMP_UP;
                    detected = true;
                }
            }

            // --- JUMP_DOWN: safe drop from higher to lower (PlayerCaps validated) ---
            if (!detected && !noJumpArea && !otherNoJump
                && dz <= -g_Caps.max_step_up && dz >= -g_Caps.max_safe_drop
                && xyDist < 150.0)
            {
                if (ValidateDropArc(center, otherCenter, g_Caps))
                {
                    edge.edgeType = CONNECTED_JUMP_DOWN;
                    detected = true;
                }
            }

            // --- STEP_DOWN: small step down ---
            if (!detected && dz >= -72.0 && dz <= -32.0 && xyDist < 80.0)
            {
                float sdStart[3], sdEnd[3];
                sdStart = center; sdStart[2] -= 2.0;
                sdEnd = center; sdEnd[2] = otherCenter[2] + 8.0;

                float slimMins[3] = {-8.0, -8.0, 1.0};
                float slimMaxs[3] = { 8.0,  8.0, 36.0};
                if (TryHull(sdStart, sdEnd, slimMins, slimMaxs))
                {
                    edge.edgeType = CONNECTED_STEP_DOWN;
                    detected = true;
                }
            }

            // --- VAULT: mantle over waist-high obstacle (PlayerCaps validated) ---
            if (!detected && dzAbs >= 40.0 && dzAbs <= g_Caps.max_vault_height && xyDist < 72.0)
            {
                float vaultZ = (center[2] > otherCenter[2] ? center[2] : otherCenter[2]) + 10.0;
                float vs[3], ve[3];
                vs = center; vs[2] = vaultZ;
                ve = otherCenter; ve[2] = vaultZ;

                float lowMins[3] = {-10.0, -10.0, 0.0};
                float lowMaxs[3] = { 10.0,  10.0, 32.0};
                if (TryHull(vs, ve, lowMins, lowMaxs))
                {
                    edge.edgeType = CONNECTED_VAULT;
                    detected = true;
                }
            }

            // --- GAP_JUMP: horizontal running jump across a gap (PlayerCaps validated) ---
            if (!detected && dzAbs < g_Caps.max_step_up * 2.0
                && xyDist >= 80.0 && xyDist <= g_Caps.max_gap_jump
                && !noJumpArea && !otherNoJump)
            {
                // Verify it's a real gap (no ground at midpoint)
                float mid[3];
                mid[0] = (center[0] + otherCenter[0]) / 2.0;
                mid[1] = (center[1] + otherCenter[1]) / 2.0;
                mid[2] = (center[2] + otherCenter[2]) / 2.0;

                float midDown[3];
                midDown = mid; midDown[2] -= 200.0;
                TR_TraceRayFilter(mid, midDown, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                bool noGround = !TR_DidHit();

                if (noGround && ValidateJumpArc(center, otherCenter, g_Caps))
                {
                    edge.edgeType = CONNECTED_GAP_JUMP;
                    detected = true;
                }
            }

            // --- CROUCH: passage that requires crouching ---
            if (!detected && dzAbs < 40.0 && xyDist < 256.0 && (crouchArea || otherCrouch))
            {
                float cs[3], ce[3];
                cs = center; cs[2] += 16.0;
                ce = otherCenter; ce[2] += 16.0;

                float lowMins[3] = {-10.0, -10.0, 0.0};
                float lowMaxs[3] = { 10.0,  10.0, 36.0};
                if (TryHull(cs, ce, lowMins, lowMaxs))
                {
                    edge.edgeType = CONNECTED_CROUCH;
                    detected = true;
                }
            }

            // --- BREAKABLE: wall that can be destroyed ---
            if (!detected && (breakableArea || otherBreakable))
            {
                edge.edgeType = CONNECTED_BREAKABLE;
                detected = true;
            }

            if (detected)
            {
                g_hNonMeshEdges.PushArray(edge, sizeof(NonMeshEdge));
            }
        }

        g_iNonMeshI++;
        processed++;
    }

    return true; // all done
}

// Get non-mesh connections FROM a given nav area. Fills conList with NavConnection.
stock int GetNonMeshConnections(int areaInt, ArrayList conList)
{
    conList.Clear();
    if (!g_hCvarNonMesh.BoolValue) return 0;
    if (g_hNonMeshEdges == null) return 0;

    int count = g_hNonMeshEdges.Length;
    NavConnection nc;
    for (int i = 0; i < count; i++)
    {
        NonMeshEdge edge;
        g_hNonMeshEdges.GetArray(i, edge, sizeof(NonMeshEdge));
        if (edge.fromArea == areaInt)
        {
            nc.navArea = view_as<Address>(edge.toArea);
            nc.connectiontype = edge.edgeType;
            conList.PushArray(nc, sizeof(NavConnection));
        }
        else if (edge.edgeType != CONNECTED_JUMP_UP
              && edge.edgeType != CONNECTED_JUMP_DOWN
              && edge.edgeType != CONNECTED_STEP_DOWN
              && edge.fromArea != areaInt
              && edge.toArea == areaInt)
        {
            // Bidirectional non-mesh edge: add reverse direction
            nc.navArea = view_as<Address>(edge.fromArea);
            nc.connectiontype = edge.edgeType;
            conList.PushArray(nc, sizeof(NavConnection));
        }
    }
    return conList.Length;
}

// ============================================================================
// A* Pathfinding Engine
// ============================================================================

// v4.0 Heuristic — Euclidean dominant, flow as tie-breaker.
//
// Previous versions (v3.0) used flow as the dominant heuristic term (80% weight).
// This worked well on official maps but broke on third-party maps where:
//   - Flow is non-monotonic (U-shaped paths, spiral staircases)
//   - Flow overestimates due to nav mesh gaps/overlaps
//   - The goal area is in a disconnected nav mesh component
//
// v4.0 formula: h = euclidean * 1.15 + flow_tiebreaker * flow_weight
// where flow_weight defaults to 0.25 (configurable via l4d_path_to_goal_flow_weight).
// Flow is now a tie-breaker — it helps A* prefer the escape direction without
// overcommitting to flow-optimal-but-geometrically-wrong paths.
//
// The 1.15× Euclidean is still admissible: the shortest path between two points
// in an irregular nav mesh is at most ~1.08× Euclidean in the worst case
// (8-direction grid), and 1.15 gives a safety margin while staying tight enough
// to avoid excessive node expansion.
stock float AStar_Heuristic(int nodeIndex)
{
    float center[3], goalCenter[3];
    g_hAStarCenters.GetArray(nodeIndex, center, 3);
    g_hAStarCenters.GetArray(g_iAStarGoalIndex, goalCenter, 3);

    float euclidean = GetVectorDistance(center, goalCenter, false);

    // Base heuristic: tight Euclidean bound (admissible, consistent)
    float h = euclidean * 1.15;

    // Flow tie-breaker: only when flow data is valid and weight is positive
    float flowWeight = (g_hCvarFlowWeight != null) ? g_hCvarFlowWeight.FloatValue : 0.25;

    if (g_fMaxFlow > 0.0 && flowWeight > 0.001)
    {
        int areaInt = g_hAStarNodes.Get(nodeIndex);
        float areaFlow = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(areaInt));
        float goalFlow = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(g_hAStarNodes.Get(g_iAStarGoalIndex)));

        if (areaFlow > 0.0 && goalFlow > 0.0)
        {
            float flowRemaining = goalFlow - areaFlow;
            if (flowRemaining < 0.0) flowRemaining = 0.0;

            // Flow tie-breaker: clamp to avoid overriding Euclidean.
            // The tie-breaker should be at most half of Euclidean so it
            // only discriminates between cells at similar Euclidean distances.
            float tiebreaker = flowRemaining;
            if (tiebreaker > euclidean * 0.5)
                tiebreaker = euclidean * 0.5;

            // Weighted blend: Euclidean base + flow tie-breaker
            // At default flowWeight=0.25, flow contributes ~11% of total h
            // This is enough to guide A* toward the escape without overcommitting
            h += tiebreaker * flowWeight;
        }
    }

    // v4.0: HPA* cluster heuristic boost for large maps
    if (g_iHPAClusterCount > 0 && g_hCvarHpaEnable != null && g_hCvarHpaEnable.BoolValue)
        h += HPA_ClusterHeuristic(nodeIndex, g_iAStarGoalIndex);

    return h;
}

// Edge cost: Euclidean distance weighted by connection type + vertical penalty.
// Without the Z penalty, A* treats climbing stairs the same as walking on flat
// ground (both have similar 3D distance ~90u), leading to paths that zigzag
// up/down through multi-floor buildings instead of following level ground.
// v4.0: Z_COST_FACTOR is now configurable via l4d_path_to_goal_z_cost_factor (default 4.0).
stock float AStar_EdgeCost(int fromIndex, int toIndex, ConnectionType conType)
{
    float c1[3], c2[3];
    g_hAStarCenters.GetArray(fromIndex, c1, 3);
    g_hAStarCenters.GetArray(toIndex, c2, 3);
    float dx = c2[0] - c1[0];
    float dy = c2[1] - c1[1];
    float dz = c2[2] - c1[2];
    float flatDist = SquareRoot(dx * dx + dy * dy);
    float absDz = FloatAbs(dz);
    // Horizontal cost (flat) + vertical cost (penalized) — keeps A* preferring
    // level paths and only climbing when geometrically necessary.
    float zFactor = (g_hCvarZCostFactor != null) ? g_hCvarZCostFactor.FloatValue : 4.0;
    float effectiveDist = flatDist + absDz * zFactor;
    return effectiveDist * GetConnectionCost(conType);
}

// Initialize A* state. Call once before starting search.
stock void AStar_Init()
{
    delete g_hAStarOpen;
    g_hAStarOpen = new ArrayList(sizeof(HeapEntry));

    int nodeCount = g_hAStarNodes.Length;

    delete g_hAStarGScore;
    g_hAStarGScore = new ArrayList(1);
    delete g_hAStarCameFrom;
    g_hAStarCameFrom = new ArrayList(1);
    delete g_hAStarEdgeType;
    g_hAStarEdgeType = new ArrayList(1);
    delete g_hAStarClosed;
    g_hAStarClosed = new ArrayList(1);

    float inf = 99999999.0; // large finite sentinel — SourcePawn view_as<float>(0x7F800000) yields 0
    for (int i = 0; i < nodeCount; i++)
    {
        g_hAStarGScore.Push(inf);
        g_hAStarCameFrom.Push(-1);
        g_hAStarEdgeType.Push(CONNECTED_NOT);
        g_hAStarClosed.Push(0);
    }

    g_bAStarPathFound = false;
    g_iAStarBestIdx = -1;
    g_fAStarBestG = -1.0;
}

// Set the start node. Call after AStar_Init.
stock void AStar_SetStart(int startIndex)
{
    g_hAStarGScore.Set(startIndex, 0.0);
    g_hAStarClosed.Set(startIndex, 0);
    float fScore = AStar_Heuristic(startIndex);
    Heap_Push(g_hAStarOpen, startIndex, fScore, 0.0);
}

// Process up to maxNodes nodes of A*. Returns:
//   1 = path found (reconstruct from cameFrom)
//   0 = still searching (continue next frame)
//  -1 = no path exists (open set empty)
stock int AStar_SearchFrame(int maxNodes)
{
    // Open set empty — all reachable nodes explored. If we have a best node
    // (always true after at least one frame of search), use it as effective goal.
    // This handles maps with disconnected nav mesh components.
    if (g_hAStarOpen.Length == 0)
    {
        if (g_iAStarBestIdx >= 0 && g_iAStarBestIdx != g_iAStarGoalIndex)
        {
            LogMessage("[PTG] A* exhausted open set. Using best reachable node %d (g=%.0f) as effective goal.",
                g_iAStarBestIdx, g_fAStarBestG);
            g_iAStarGoalIndex = g_iAStarBestIdx;
            g_bAStarPathFound = true;
            return 1;
        }
        return -1;
    }

    int processed = 0;
    HeapEntry entry;

    // Reusable arrays for connections
    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN == null) AdjNN = new ArrayList();

    while (processed < maxNodes && g_hAStarOpen.Length > 0)
    {
        // Pop best node, skip stale entries
        if (!Heap_Pop(g_hAStarOpen, entry))
            return -1;

        int currentIdx = entry.nodeIndex;

        // Skip if already closed
        if (g_hAStarClosed.Get(currentIdx) == 1)
            continue;

        // Skip stale entries (gScore changed since push)
        float currentG = g_hAStarGScore.Get(currentIdx);
        if (FloatAbs(entry.gScore - currentG) > 0.1)
            continue;

        // Goal reached?
        if (currentIdx == g_iAStarGoalIndex)
        {
            g_bAStarPathFound = true;
            g_hAStarClosed.Set(currentIdx, 1);
            return 1;
        }

        // Mark as closed
        g_hAStarClosed.Set(currentIdx, 1);

        // Track best reachable node (in case goal is in a disconnected nav mesh component)
        // Use gScore as the quality metric — higher gScore = farther from start along
        // the search direction (flow heuristic guides expansion toward the escape).
        if (currentG > g_fAStarBestG)
        {
            g_fAStarBestG = currentG;
            g_iAStarBestIdx = currentIdx;
        }

        // Get current area
        int areaInt = g_hAStarNodes.Get(currentIdx);
        Address areaAddr = view_as<Address>(areaInt);

        // --- Expand neighbors ---
        // CON_KEEP_ALL: explore connections in all directions. The flow-based
        // heuristic (fix #3) naturally prioritizes forward-going nodes, so we
        // don't need CON_KEEP_FORWARD to restrict the search — the heuristic
        // does the same job without risking pathfinding failures on nav meshes
        // where flow isn't perfectly monotonic.
        GetNavConnections(areaAddr, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

        // Non-mesh connections
        GetNonMeshConnections(areaInt, AdjNN);
        // Merge AdjNN into ConAdj
        NavConnection nc;
        for (int i = 0; i < AdjNN.Length; i++)
        {
            AdjNN.GetArray(i, nc, sizeof(NavConnection));
            ConAdj.PushArray(nc, sizeof(NavConnection));
        }

        for (int i = 0; i < ConAdj.Length; i++)
        {
            ConAdj.GetArray(i, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;

            int neighborInt = view_as<int>(nc.navArea);

            // Find neighbor's nodeIndex
            char key[16];
            IntToString(neighborInt, key, sizeof(key));
            int neighborIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(key, neighborIdx)) continue;

            // Skip if closed
            if (g_hAStarClosed.Get(neighborIdx) == 1) continue;

            // Check if blocked (unless breakable or conditional)
            if (nc.connectiontype != CONNECTED_BREAKABLE && nc.connectiontype != CONNECTED_CONDITIONAL)
            {
                if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true))
                    continue;
            }

            // v4.0 Theta*: check parent-LOS for any-angle shortcuts during search.
            // If parent(current) has LOS to neighbor AND the direct path is shorter,
            // bypass current entirely — produces smoother paths with fewer waypoints.
            bool thetaUsed = false;
            int cameFrom = currentIdx;
            float tentativeG;
            if (g_hCvarThetaStar != null && g_hCvarThetaStar.BoolValue)
            {
                int parentIdx = g_hAStarCameFrom.Get(currentIdx);
                if (parentIdx >= 0 && parentIdx < g_hAStarNodes.Length)
                {
                    float pCenter[3], nCenter[3];
                    g_hAStarCenters.GetArray(parentIdx, pCenter, 3);
                    g_hAStarCenters.GetArray(neighborIdx, nCenter, 3);
                    float losDist = GetVectorDistance(pCenter, nCenter, false);
                    float losMax = (g_hCvarThetaLosMax != null) ? g_hCvarThetaLosMax.FloatValue : 1500.0;
                    if (losDist <= losMax && twopos_traversable(pCenter, nCenter))
                    {
                        float parentGScore = g_hAStarGScore.Get(parentIdx);
                        float directG = parentGScore + AStar_EdgeCost(parentIdx, neighborIdx, CONNECTED_ADJACENT);
                        float viaCurrentG = currentG + AStar_EdgeCost(currentIdx, neighborIdx, nc.connectiontype);
                        if (directG < viaCurrentG)
                        {
                            tentativeG = directG;
                            cameFrom = parentIdx;
                            thetaUsed = true;
                        }
                    }
                }
            }
            if (!thetaUsed)
            {
                tentativeG = currentG + AStar_EdgeCost(currentIdx, neighborIdx, nc.connectiontype);
                cameFrom = currentIdx;
            }

            float neighborG = g_hAStarGScore.Get(neighborIdx);
            if (tentativeG < neighborG)
            {
                g_hAStarGScore.Set(neighborIdx, tentativeG);
                g_hAStarCameFrom.Set(neighborIdx, cameFrom);
                g_hAStarEdgeType.Set(neighborIdx, view_as<int>(nc.connectiontype));

                float fScore = tentativeG + AStar_Heuristic(neighborIdx);
                Heap_Push(g_hAStarOpen, neighborIdx, fScore, tentativeG);

                // Goal reached — will be popped and detected next frame
            }
        }

        processed++;
    }

    if (g_hAStarOpen.Length == 0)
    {
        // Goal unreachable — nav mesh is in disconnected components.
        // Use the best reachable node (farthest along the search direction)
        // as the effective goal. The path will guide players as far as
        // possible toward the escape direction.
        if (g_iAStarBestIdx >= 0 && g_iAStarBestIdx != g_iAStarGoalIndex)
        {
            LogMessage("[PTG] A* goal unreachable (disconnected nav mesh). Using best reachable node %d (g=%.0f) as effective goal.",
                g_iAStarBestIdx, g_fAStarBestG);
            g_iAStarGoalIndex = g_iAStarBestIdx;
            g_bAStarPathFound = true;
            return 1;
        }
        return -1;
    }

    return 0;
}

// 2D triangle signed area. Used by funnel algorithm for left/right checks.
// Returns: >0 if p is left of directed line a→b, <0 if right, 0 if collinear.
stock float TriArea2D(const float a[3], const float b[3], const float p[3])
{
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}

// Reconstruct path from cameFrom chain, output portal-centered waypoints.
// v4.0: portal-based waypoints + funnel string pulling (replaces LOS smoothing)
stock void AStar_ReconstructPath(ArrayList outCells)
{
    outCells.Clear();
    if (!g_bAStarPathFound) return;

    // Walk backwards from goal to start
    ArrayList reversePath = new ArrayList(2);
    int maxSteps = g_hAStarNodes.Length + 1;
    int currentIdx = g_iAStarGoalIndex;
    int steps = 0;
    while (currentIdx >= 0 && steps < maxSteps)
    {
        if (currentIdx >= g_hAStarNodes.Length) break;
        int edgeType = g_hAStarEdgeType.Get(currentIdx);
        reversePath.Push(currentIdx);
        reversePath.Push(edgeType);
        currentIdx = g_hAStarCameFrom.Get(currentIdx);
        steps++;
    }
    if (steps >= maxSteps)
    {
        LogMessage("[PTG] A* reconstruct aborted: path too long (cycle detected)");
        delete reversePath;
        return;
    }

    // Build forward-order nodeIndex list (start → goal)
    ArrayList nodePath = new ArrayList();
    for (int i = reversePath.Length - 2; i >= 0; i -= 2)
        nodePath.Push(reversePath.Get(i));
    delete reversePath;

    int pathLen = nodePath.Length;
    if (pathLen < 2)
    {
        delete nodePath;
        return;
    }

    // --- Build portal endpoint sequence from nodePath ---
    // Each portal is the shared edge between consecutive nav areas in the path.
    // The funnel algorithm uses the left/right endpoints to find the shortest
    // path through this sequence — mathematically optimal string pulling.
    int portalCount = pathLen - 1;
    ArrayList portalEps = new ArrayList(6); // each portal: float[3] left, float[3] right
    bool[] portalDegenerate = new bool[portalCount];

    for (int i = 0; i < portalCount; i++)
    {
        int ni = nodePath.Get(i);
        int nj = nodePath.Get(i + 1);
        int minI = (ni < nj) ? ni : nj;
        int maxI = (ni < nj) ? nj : ni;
        char key[32];
        Format(key, sizeof(key), "%d_%d", minI, maxI);

        PortalInfo portal;
        float left[3], right[3];
        bool gotPortal = false;

        if (g_hPortalCache != null && g_hPortalCache.GetArray(key, portal, sizeof(PortalInfo)))
        {
            left = portal.ep1;
            right = portal.ep2;
            gotPortal = true;
        }

        if (!gotPortal)
        {
            // Fallback: use centers of the two areas as degenerate portal
            g_hAStarCenters.GetArray(ni, left, 3);
            g_hAStarCenters.GetArray(nj, right, 3);
            portalDegenerate[i] = true;
        }
        else
        {
            // Check if portal is effectively a point (endpoints very close)
            portalDegenerate[i] = (GetVectorDistance(left, right, true) < 64.0);
        }

        portalEps.PushArray(left, 3);
        portalEps.PushArray(right, 3);
    }

    // --- Funnel String Pulling ---
    // Operates in 2D (XY plane) over the portal endpoint sequence.
    // Produces the optimal shortest path through the portals.

    // 2D triangle area (signed). >0 = p is left of ab, <0 = right, 0 = collinear.
    // Used for all left/right orientation checks in the funnel.

    ArrayList funnelResult = new ArrayList(sizeof(Cell));

    // Start cell
    Cell startCell;
    int firstNodeIdx = nodePath.Get(0);
    int firstAreaInt = g_hAStarNodes.Get(firstNodeIdx);
    startCell.navArea = view_as<Address>(firstAreaInt);
    g_hAStarCenters.GetArray(firstNodeIdx, startCell.center, 3);
    startCell.flow = L4D2Direct_GetTerrorNavAreaFlow(startCell.navArea);
    if (startCell.flow <= 0.0 && g_fMaxFlow > 0.0)
        startCell.flow = 0.0;

    // Funnel state
    Cell apex;
    apex.navArea = startCell.navArea;
    apex.center = startCell.center;
    apex.flow = startCell.flow;
    int leftPortalIdx = -1;   // which portal supplies the left funnel boundary
    int rightPortalIdx = -1;  // which portal supplies the right funnel boundary

    for (int i = 0; i < portalCount; i++)
    {
        float portalLeft[3], portalRight[3];
        portalEps.GetArray(i * 2, portalLeft, 3);
        portalEps.GetArray(i * 2 + 1, portalRight, 3);

        // Ensure consistent orientation: portalLeft should be left of portalRight
        // from the perspective of the path direction (apex → portal)
        if (TriArea2D(apex.center, portalLeft, portalRight) < 0.0)
        {
            // Swap: portalLeft is actually to the right of portalRight
            float tmp[3]; tmp = portalLeft; portalLeft = portalRight; portalRight = tmp;
        }

        if (portalDegenerate[i])
        {
            // Degenerate portal (single point or nearly so) — can't narrow the funnel.
            // Just check if this point forces a waypoint (if it's outside the funnel).
            if (leftPortalIdx >= 0 && rightPortalIdx >= 0)
            {
                float leftEp[3], rightEp[3];
                portalEps.GetArray(leftPortalIdx * 2, leftEp, 3);
                portalEps.GetArray(rightPortalIdx * 2 + 1, rightEp, 3);

                // If the degenerate portal's center is outside the funnel, we need to add a waypoint
                if (TriArea2D(apex.center, leftEp, portalLeft) < 0.0 ||
                    TriArea2D(apex.center, rightEp, portalLeft) > 0.0)
                {
                    // Funnel collapsed: add current apex to result and reset
                    funnelResult.PushArray(apex, sizeof(Cell));
                    // New apex at the previous portal
                    int nj = nodePath.Get(i + 1);
                    int currAreaInt = g_hAStarNodes.Get(nj);
                    apex.navArea = view_as<Address>(currAreaInt);
                    g_hAStarCenters.GetArray(nj, apex.center, 3);
                    apex.flow = L4D2Direct_GetTerrorNavAreaFlow(apex.navArea);
                    if (apex.flow <= 0.0 && g_fMaxFlow > 0.0)
                        apex.flow = (float(i + 1) / float(pathLen - 1)) * g_fMaxFlow;
                    leftPortalIdx = -1;
                    rightPortalIdx = -1;
                    continue;
                }
            }
            // Degenerate portal doesn't change funnel — skip
            continue;
        }

        // First valid portal initializes the funnel
        if (leftPortalIdx < 0)
        {
            leftPortalIdx = i;
            rightPortalIdx = i;
            continue;
        }

        float leftEp[3], rightEp[3];
        portalEps.GetArray(leftPortalIdx * 2, leftEp, 3);
        portalEps.GetArray(rightPortalIdx * 2 + 1, rightEp, 3);

        bool leftInside  = TriArea2D(apex.center, leftEp, portalLeft) >= 0.0;
        bool rightInside = TriArea2D(apex.center, rightEp, portalRight) <= 0.0;

        if (leftInside && rightInside)
        {
            // Both endpoints inside funnel — narrow it
            if (TriArea2D(apex.center, rightEp, portalRight) < 0.0)
                rightPortalIdx = i;
            if (TriArea2D(apex.center, leftEp, portalLeft) > 0.0)
                leftPortalIdx = i;
        }
        else if (!rightInside)
        {
            // Portal right endpoint is to the RIGHT of right boundary
            // OR portal left endpoint is to the LEFT of left boundary
            // → funnel collapsed on the right side
            // Output the right boundary endpoint as a waypoint
            Cell waypoint;
            waypoint.center = rightEp;
            waypoint.navArea = Address_Null; // waypoint, not a nav area center
            waypoint.flow = apex.flow; // approximate
            funnelResult.PushArray(waypoint, sizeof(Cell));

            apex.navArea = waypoint.navArea;
            apex.center = waypoint.center;
            apex.flow = waypoint.flow;
            // Reset funnel with the previous portal
            leftPortalIdx = i - 1;
            rightPortalIdx = i - 1;
            i--; // re-process this portal with new apex
        }
        else // !leftInside
        {
            // Funnel collapsed on the left side
            Cell waypoint;
            waypoint.center = leftEp;
            waypoint.navArea = Address_Null;
            waypoint.flow = apex.flow;
            funnelResult.PushArray(waypoint, sizeof(Cell));

            apex = waypoint;
            leftPortalIdx = i - 1;
            rightPortalIdx = i - 1;
            i--;
        }
    }

    // Output the final result
    // Start with the start cell
    outCells.PushArray(startCell, sizeof(Cell));

    // Add funnel waypoints
    for (int i = 0; i < funnelResult.Length; i++)
    {
        Cell wp;
        funnelResult.GetArray(i, wp, sizeof(Cell));
        outCells.PushArray(wp, sizeof(Cell));
    }

    // Add goal cell
    Cell goalCell;
    int lastNodeIdx = nodePath.Get(pathLen - 1);
    int lastAreaInt = g_hAStarNodes.Get(lastNodeIdx);
    goalCell.navArea = view_as<Address>(lastAreaInt);
    g_hAStarCenters.GetArray(lastNodeIdx, goalCell.center, 3);
    goalCell.flow = L4D2Direct_GetTerrorNavAreaFlow(goalCell.navArea);
    if (goalCell.flow <= 0.0 && g_fMaxFlow > 0.0)
        goalCell.flow = g_fMaxFlow;
    outCells.PushArray(goalCell, sizeof(Cell));

    delete nodePath;
    delete portalEps;
    delete funnelResult;

    // --- Validation pass: hull trace every edge ---
    // Funnel waypoints are geometrically optimal but may cross geometry
    // in rare edge cases (thin walls, complex 3D terrain). Validate and fix.
    if (outCells.Length >= 2)
    {
        for (int i = 1; i < outCells.Length; i++)
        {
            Cell c1, c2;
            outCells.GetArray(i - 1, c1, sizeof(Cell));
            outCells.GetArray(i, c2, sizeof(Cell));

            if (!twopos_traversable(c1.center, c2.center))
            {
                // Edge blocked — try stepping Z up
                float lifted[3];
                lifted = c2.center;
                lifted[2] += 24.0;
                if (twopos_traversable(c1.center, lifted))
                {
                    c2.center = lifted;
                    outCells.SetArray(i, c2, sizeof(Cell));
                }
                // If still blocked, keep as-is — hull validation pass will mark it
            }
        }
    }
}

// ============================================================================
// Start/Goal Identification (multi-strategy fallback)
// ============================================================================

// Identify the START nav area for the escape path.
// Returns nodeIndex, or -1 if not found.
stock int AStar_IdentifyStart()
{
    if (g_hAStarNodes == null || g_hAStarNodes.Length == 0) return -1;

    int bestIdx = -1;
    float bestFlow = g_fMaxFlow + 1.0;
    bool foundPlayerStart = false;

    for (int i = 0; i < g_hAStarNodes.Length; i++)
    {
        int areaInt = g_hAStarNodes.Get(i);
        Address area = view_as<Address>(areaInt);

        float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
        if (flow < 0.0 || flow > g_fMaxFlow) continue;

        int spawnAttrs = L4D_GetNavArea_SpawnAttributes(area);
        bool isPlayerStart = (spawnAttrs & NAV_SPAWN_PLAYER_START) != 0;

        if (isPlayerStart && flow < bestFlow)
        {
            bestFlow = flow;
            bestIdx = i;
            foundPlayerStart = true;
        }
        else if (!foundPlayerStart && flow < bestFlow)
        {
            bestFlow = flow;
            bestIdx = i;
        }
    }

    return bestIdx;
}

// Identify the GOAL nav area for the escape path.
// Priority: RESCUE_VEHICLE > farthest Euclidean from start > max flow
//
// Farthest Euclidean is preferred over max-flow because it's always in the same
// connected component as start (you can't be "farthest" if you're unreachable).
// Max-flow areas can be in disconnected nav mesh components (behind locked doors,
// finale-only areas) making them unreachable and causing A* to fail.
//
// The flow-based heuristic (#3 fix) still guides the search toward high-flow
// areas, so the path naturally follows the escape direction even with a
// Euclidean goal.
stock int AStar_IdentifyGoal(int startIndex)
{
    if (g_hAStarNodes == null || g_hAStarNodes.Length == 0) return -1;

    float startCenter[3];
    if (startIndex >= 0)
        g_hAStarCenters.GetArray(startIndex, startCenter, 3);

    // Strategy 1: RESCUE_VEHICLE area (unambiguous, always correct if present)
    for (int i = 0; i < g_hAStarNodes.Length; i++)
    {
        int areaInt = g_hAStarNodes.Get(i);
        Address area = view_as<Address>(areaInt);
        int spawnAttrs = L4D_GetNavArea_SpawnAttributes(area);
        if ((spawnAttrs & NAV_SPAWN_RESCUE_VEHICLE) && g_hCvarFinale.IntValue < FINALE_NEVER)
        {
            LogMessage("[PTG] A* goal: RESCUE_VEHICLE at index %d", i);
            return i;
        }
    }

    // Strategy 2: farthest Euclidean from start — always reachable.
    // Combined with the flow-based heuristic, this produces paths that follow
    // the escape direction without the risk of picking an unreachable max-flow target.
    if (startIndex >= 0)
    {
        int farIdx = -1;
        float maxDist = -1.0;
        for (int i = 0; i < g_hAStarNodes.Length; i++)
        {
            float center[3];
            g_hAStarCenters.GetArray(i, center, 3);
            float dist = GetVectorDistance(startCenter, center, true); // sq dist
            if (dist > maxDist)
            {
                maxDist = dist;
                farIdx = i;
            }
        }
        if (farIdx >= 0)
        {
            LogMessage("[PTG] A* goal: farthest Euclidean index %d (dist=%.0f)", farIdx, SquareRoot(maxDist));
            return farIdx;
        }
    }

    // Strategy 3: max flow (fallback — may be unreachable on some maps)
    if (g_fMaxFlow > 0.0)
    {
        int bestIdx = -1;
        float bestFlow = -1.0;
        for (int i = 0; i < g_hAStarNodes.Length; i++)
        {
            float flow = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(g_hAStarNodes.Get(i)));
            if (flow > bestFlow && flow <= g_fMaxFlow)
            {
                bestFlow = flow;
                bestIdx = i;
            }
        }
        if (bestIdx >= 0)
        {
            LogMessage("[PTG] A* goal: max-flow index %d (flow=%.1f) [fallback]", bestIdx, bestFlow);
            return bestIdx;
        }
    }

    return -1;
}

// ============================================================================
// Portal Computation — finds shared boundary edges between adjacent nav areas.
// Portal centers replace area centers as path waypoints, so beams pass through
// actual doorways and corridor junctions instead of diagonally through walls.
// ============================================================================

stock void AStar_ComputePortals()
{
    delete g_hPortalCache;
    g_hPortalCache = new StringMap();

    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN == null) AdjNN = new ArrayList();

    int nodeCount = g_hAStarNodes.Length;
    char key[32];
    float cornersA[4][3], cornersB[4][3];

    for (int i = 0; i < nodeCount; i++)
    {
        int areaIntA = g_hAStarNodes.Get(i);
        Address areaA = view_as<Address>(areaIntA);
        if (areaA == Address_Null) continue;

        // Get corners of area A — required for accurate portal detection
        if (!elevator_available) continue; // corner API unavailable, skip portals

        for (int c = 0; c < 4; c++)
            L4D_NavArea_GetCorner(areaA, view_as<NavCornerType>(c), cornersA[c]);

        // Get adjacent areas
        GetNavConnections(areaA, ConAdj, TEAM_SURVIVOR, true, false, false, CON_KEEP_ALL);

        for (int n = 0; n < ConAdj.Length; n++)
        {
            NavConnection nc;
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null || nc.navArea == areaA) continue;

            int areaIntB = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(areaIntB, keyB, sizeof(keyB));
            int j = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, j)) continue;

            // Canonical key: smaller index first (portal is symmetric)
            int minI = (i < j) ? i : j;
            int maxI = (i < j) ? j : i;
            Format(key, sizeof(key), "%d_%d", minI, maxI);

            if (g_hPortalCache.ContainsKey(key)) continue; // already computed

            // Get corners of area B
            Address areaB = nc.navArea;
            for (int c = 0; c < 4; c++)
                L4D_NavArea_GetCorner(areaB, view_as<NavCornerType>(c), cornersB[c]);

            // Find shared corners (within 32u XY and 48u Z)
            float sharedEps[2][3];
            int sharedCount = 0;

            for (int ca = 0; ca < 4 && sharedCount < 2; ca++)
            {
                for (int cb = 0; cb < 4 && sharedCount < 2; cb++)
                {
                    float dxy = GetVectorDistance(cornersA[ca], cornersB[cb], true);
                    float dz = FloatAbs(cornersA[ca][2] - cornersB[cb][2]);
                    if (dxy < 1024.0 && dz < 48.0) // 32u XY, 48u Z tolerance
                    {
                        // Check for duplicate
                        bool duplicate = false;
                        for (int s = 0; s < sharedCount; s++)
                        {
                            if (GetVectorDistance(sharedEps[s], cornersA[ca], true) < 64.0)
                            { duplicate = true; break; }
                        }
                        if (!duplicate)
                        {
                            sharedEps[sharedCount][0] = (cornersA[ca][0] + cornersB[cb][0]) / 2.0;
                            sharedEps[sharedCount][1] = (cornersA[ca][1] + cornersB[cb][1]) / 2.0;
                            sharedEps[sharedCount][2] = (cornersA[ca][2] + cornersB[cb][2]) / 2.0;
                            sharedCount++;
                        }
                    }
                }
            }

            PortalInfo portal;
            if (sharedCount >= 2)
            {
                portal.ep1 = sharedEps[0];
                portal.ep2 = sharedEps[1];
                portal.center[0] = (sharedEps[0][0] + sharedEps[1][0]) / 2.0;
                portal.center[1] = (sharedEps[0][1] + sharedEps[1][1]) / 2.0;
                portal.center[2] = (sharedEps[0][2] + sharedEps[1][2]) / 2.0;
            }
            else
            {
                // Degenerate portal: use center midpoint as fallback
                float cA[3], cB[3];
                g_hAStarCenters.GetArray(i, cA, 3);
                g_hAStarCenters.GetArray(j, cB, 3);
                portal.ep1 = cA;
                portal.ep2 = cB;
                portal.center[0] = (cA[0] + cB[0]) / 2.0;
                portal.center[1] = (cA[1] + cB[1]) / 2.0;
                portal.center[2] = (cA[2] + cB[2]) / 2.0;
            }

            // Snap portal Z to ground
            float zA = L4D_NavArea_GetZ(areaA, portal.center);
            float zB = L4D_NavArea_GetZ(areaB, portal.center);
            float groundZ = (zA > zB) ? zA : zB;
            if (groundZ > -9000.0)
                portal.center[2] = groundZ + 16.0;
            if (sharedCount >= 2)
            {
                zA = L4D_NavArea_GetZ(areaA, portal.ep1);
                zB = L4D_NavArea_GetZ(areaB, portal.ep1);
                groundZ = (zA > zB) ? zA : zB;
                if (groundZ > -9000.0) portal.ep1[2] = groundZ + 4.0;
                zA = L4D_NavArea_GetZ(areaA, portal.ep2);
                zB = L4D_NavArea_GetZ(areaB, portal.ep2);
                groundZ = (zA > zB) ? zA : zB;
                if (groundZ > -9000.0) portal.ep2[2] = groundZ + 4.0;
            }

            g_hPortalCache.SetArray(key, portal, sizeof(PortalInfo));
        }
    }

    #if DEBUG
    StringMapSnapshot snap = g_hPortalCache.Snapshot();
    LogMessage("[PTG] Portal cache built: %d portals for %d nav areas", snap.Length, nodeCount);
    delete snap;
    #endif
}

// v4.0: Batched portal computation — processes count nav areas per call,
// starting from startIdx. Returns true if more areas remain.
// Called from STAGE_PREP phase 1 to avoid SIGALRM on large maps.
stock bool AStar_ComputePortalsBatch(int startIdx, int count)
{
    int nodeCount = g_hAStarNodes.Length;

    // First call: initialize the portal cache
    if (startIdx == 0)
    {
        delete g_hPortalCache;
        g_hPortalCache = new StringMap();
    }

    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN == null) AdjNN = new ArrayList();

    char key[32];
    float cornersA[4][3], cornersB[4][3];
    int endIdx = startIdx + count;
    if (endIdx > nodeCount) endIdx = nodeCount;

    for (int i = startIdx; i < endIdx; i++)
    {
        int areaIntA = g_hAStarNodes.Get(i);
        Address areaA = view_as<Address>(areaIntA);
        if (areaA == Address_Null) continue;

        if (!elevator_available) continue;

        for (int c = 0; c < 4; c++)
            L4D_NavArea_GetCorner(areaA, view_as<NavCornerType>(c), cornersA[c]);

        GetNavConnections(areaA, ConAdj, TEAM_SURVIVOR, true, false, false, CON_KEEP_ALL);

        for (int n = 0; n < ConAdj.Length; n++)
        {
            NavConnection nc;
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null || nc.navArea == areaA) continue;

            int areaIntB = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(areaIntB, keyB, sizeof(keyB));
            int j = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, j)) continue;

            int minI = (i < j) ? i : j;
            int maxI = (i < j) ? j : i;
            Format(key, sizeof(key), "%d_%d", minI, maxI);

            if (g_hPortalCache.ContainsKey(key)) continue;

            Address areaB = nc.navArea;
            for (int c = 0; c < 4; c++)
                L4D_NavArea_GetCorner(areaB, view_as<NavCornerType>(c), cornersB[c]);

            float sharedEps[2][3];
            int sharedCount = 0;

            for (int ca = 0; ca < 4 && sharedCount < 2; ca++)
            {
                for (int cb = 0; cb < 4 && sharedCount < 2; cb++)
                {
                    float dxy = GetVectorDistance(cornersA[ca], cornersB[cb], true);
                    float dz = FloatAbs(cornersA[ca][2] - cornersB[cb][2]);
                    if (dxy < 1024.0 && dz < 48.0)
                    {
                        bool duplicate = false;
                        for (int s = 0; s < sharedCount; s++)
                        {
                            if (GetVectorDistance(sharedEps[s], cornersA[ca], true) < 64.0)
                            { duplicate = true; break; }
                        }
                        if (!duplicate)
                        {
                            sharedEps[sharedCount][0] = (cornersA[ca][0] + cornersB[cb][0]) / 2.0;
                            sharedEps[sharedCount][1] = (cornersA[ca][1] + cornersB[cb][1]) / 2.0;
                            sharedEps[sharedCount][2] = (cornersA[ca][2] + cornersB[cb][2]) / 2.0;
                            sharedCount++;
                        }
                    }
                }
            }

            PortalInfo portal;
            if (sharedCount >= 2)
            {
                portal.ep1 = sharedEps[0];
                portal.ep2 = sharedEps[1];
                portal.center[0] = (sharedEps[0][0] + sharedEps[1][0]) / 2.0;
                portal.center[1] = (sharedEps[0][1] + sharedEps[1][1]) / 2.0;
                portal.center[2] = (sharedEps[0][2] + sharedEps[1][2]) / 2.0;
            }
            else
            {
                float cA[3], cB[3];
                g_hAStarCenters.GetArray(i, cA, 3);
                g_hAStarCenters.GetArray(j, cB, 3);
                portal.ep1 = cA;
                portal.ep2 = cB;
                portal.center[0] = (cA[0] + cB[0]) / 2.0;
                portal.center[1] = (cA[1] + cB[1]) / 2.0;
                portal.center[2] = (cA[2] + cB[2]) / 2.0;
            }

            float zA = L4D_NavArea_GetZ(areaA, portal.center);
            float zB = L4D_NavArea_GetZ(areaB, portal.center);
            float groundZ = (zA > zB) ? zA : zB;
            if (groundZ > -9000.0)
                portal.center[2] = groundZ + 16.0;
            if (sharedCount >= 2)
            {
                zA = L4D_NavArea_GetZ(areaA, portal.ep1);
                zB = L4D_NavArea_GetZ(areaB, portal.ep1);
                groundZ = (zA > zB) ? zA : zB;
                if (groundZ > -9000.0) portal.ep1[2] = groundZ + 4.0;
                zA = L4D_NavArea_GetZ(areaA, portal.ep2);
                zB = L4D_NavArea_GetZ(areaB, portal.ep2);
                groundZ = (zA > zB) ? zA : zB;
                if (groundZ > -9000.0) portal.ep2[2] = groundZ + 4.0;
            }

            g_hPortalCache.SetArray(key, portal, sizeof(PortalInfo));
        }
    }

    if (endIdx >= nodeCount)
    {
        #if DEBUG
        StringMapSnapshot snap = g_hPortalCache.Snapshot();
        LogMessage("[PTG] Portal cache built: %d portals for %d nav areas (batched)", snap.Length, nodeCount);
        delete snap;
        #endif
        return false; // done
    }
    return true; // more areas remain
}

// Build the node index from all nav areas. Call once per map load.
stock void AStar_BuildNodeIndex()
{
    delete g_hAStarNodes;
    delete g_hAStarCenters;
    delete g_hAStarAreaToIndex;
    delete g_hSpatialHash;

    ArrayList areaList = new ArrayList();
    L4D_GetAllNavAreas(areaList);

    int count = areaList.Length;
    g_hAStarNodes = new ArrayList(1);
    g_hAStarCenters = new ArrayList(3);
    g_hAStarAreaToIndex = new StringMap();
    g_hSpatialHash = new StringMap();

    float center[3];
    char key[16];

    for (int i = 0; i < count; i++)
    {
        Address area = areaList.Get(i);
        if (area == Address_Null) continue;

        L4D_GetNavAreaCenter(area, center);
        center[2] += 16.0;
        if (pos_underwater(center))
        {
            center[2] += 16.0;
            if (pos_underwater(center)) center[2] += 16.0;
        }

        int areaInt = view_as<int>(area);
        g_hAStarNodes.Push(areaInt);
        g_hAStarCenters.PushArray(center, 3);

        IntToString(areaInt, key, sizeof(key));
        g_hAStarAreaToIndex.SetValue(key, i);

        // Spatial hash
        SpatialHash_Insert(center, areaInt);
    }

    delete areaList;

    // Compute portal waypoints (shared-edge midpoints between adjacent areas)
    AStar_ComputePortals();

    #if DEBUG
    LogMessage("[PTG] A* node index built: %d nav areas in spatial hash", count);
    #endif

    // v4.0: HPA* clusters and bridge detection are now batched across
    // frames via OnFramePrep sub-phases (g_iBuildPhase 1-3).
    // AStar_ComputePortals is also deferred to AStar_ComputePortalsBatch.
}

// ============================================================================
// v4.0 HPA* — Hierarchical Pathfinding Acceleration
//
// Clusters nav areas by spatial hash at a coarser resolution (default 1024u).
// Computes cluster-level connectivity. The cluster-level distance is used as a
// secondary heuristic boost for maps with 5000+ nav areas where the A* open
// set can grow very large before converging.
// ============================================================================

StringMap g_hHPAClusters;       // "cx_cy_cz" → ArrayList of nodeIndices
ArrayList g_hHPAClusterCenters; // float[3] center for each cluster
ArrayList g_hHPAClusterNodes;   // ArrayList of nodeIndices per cluster
StringMap g_hHPAClusterAdj;     // "ci_cj" → 1 if clusters i and j are adjacent

stock void HPA_BuildClusters()
{
    delete g_hHPAClusters;
    delete g_hHPAClusterCenters;
    delete g_hHPAClusterNodes;
    delete g_hHPAClusterAdj;

    g_hHPAClusters = new StringMap();
    g_hHPAClusterCenters = new ArrayList(3);
    g_hHPAClusterNodes = new ArrayList();
    g_hHPAClusterAdj = new StringMap();

    float cellSize = g_hCvarHpaCellSize != null ? g_hCvarHpaCellSize.FloatValue : 1024.0;
    int nodeCount = g_hAStarNodes.Length;
    StringMap clusterMap = new StringMap(); // key → clusterIndex

    // Pass 1: assign nodes to clusters
    for (int i = 0; i < nodeCount; i++)
    {
        float center[3];
        g_hAStarCenters.GetArray(i, center, 3);

        int cx = RoundToFloor(center[0] / cellSize);
        int cy = RoundToFloor(center[1] / cellSize);
        int cz = RoundToFloor(center[2] / cellSize);

        char key[32];
        Format(key, sizeof(key), "%d_%d_%d", cx, cy, cz);

        int clusterIdx = -1;
        if (!clusterMap.GetValue(key, clusterIdx))
        {
            clusterIdx = g_hHPAClusterCenters.Length / 3;
            g_hHPAClusterCenters.PushArray(center, 3);
            // Store nodeList handle as int inside g_hHPAClusterNodes
            ArrayList nodeList = new ArrayList();
            g_hHPAClusterNodes.Push(view_as<int>(nodeList));
            nodeList.Push(i);

            clusterMap.SetValue(key, clusterIdx);

            // Update cluster center as average
            float avg[3]; avg = center;
            g_hHPAClusterCenters.SetArray(clusterIdx, avg, 3);
        }
        else
        {
            int handle = g_hHPAClusterNodes.Get(clusterIdx);
            ArrayList nodeList = view_as<ArrayList>(handle);
            nodeList.Push(i);

            // Update running average for center
            float curCenter[3];
            g_hHPAClusterCenters.GetArray(clusterIdx, curCenter, 3);
            int n = nodeList.Length;
            curCenter[0] = (curCenter[0] * (n - 1) + center[0]) / n;
            curCenter[1] = (curCenter[1] * (n - 1) + center[1]) / n;
            curCenter[2] = (curCenter[2] * (n - 1) + center[2]) / n;
            g_hHPAClusterCenters.SetArray(clusterIdx, curCenter, 3);
        }
    }

    g_iHPAClusterCount = g_hHPAClusterCenters.Length / 3;

    // Pass 2: compute cluster adjacency by checking nav area connections
    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    for (int ci = 0; ci < g_iHPAClusterCount; ci++)
    {
        int nhandle = g_hHPAClusterNodes.Get(ci);
        ArrayList nodes = view_as<ArrayList>(nhandle);

        for (int ni = 0; ni < nodes.Length; ni++)
        {
            int nodeIdx = nodes.Get(ni);
            int areaInt = g_hAStarNodes.Get(nodeIdx);
            Address area = view_as<Address>(areaInt);

            GetNavConnections(area, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

            for (int c = 0; c < ConAdj.Length; c++)
            {
                NavConnection nc;
                ConAdj.GetArray(c, nc, sizeof(NavConnection));
                if (nc.navArea == Address_Null) continue;

                int otherInt = view_as<int>(nc.navArea);
                char keyB[16];
                IntToString(otherInt, keyB, sizeof(keyB));
                int otherIdx = -1;
                if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;

                // Find which cluster otherIdx belongs to
                float otherCenter[3];
                g_hAStarCenters.GetArray(otherIdx, otherCenter, 3);
                int ocx = RoundToFloor(otherCenter[0] / cellSize);
                int ocy = RoundToFloor(otherCenter[1] / cellSize);
                int ocz = RoundToFloor(otherCenter[2] / cellSize);

                char okey[32];
                Format(okey, sizeof(okey), "%d_%d_%d", ocx, ocy, ocz);

                int cj = -1;
                if (clusterMap.GetValue(okey, cj) && cj != ci)
                {
                    char adjKey[16];
                    int minC = (ci < cj) ? ci : cj;
                    int maxC = (ci < cj) ? cj : ci;
                    Format(adjKey, sizeof(adjKey), "%d_%d", minC, maxC);
                    g_hHPAClusterAdj.SetValue(adjKey, 1);
                }
            }
        }
    }

    delete clusterMap;

    #if DEBUG
    LogMessage("[PTG] HPA*: %d clusters (cell=%.0f) for %d nav areas",
        g_iHPAClusterCount, cellSize, nodeCount);
    #endif
}

// HPA* heuristic boost: Euclidean distance between cluster centers.
// Used as a cheap upper-bound check: if two nodes are in clusters far apart,
// their direct connection is unlikely and A* should explore alternatives first.
stock float HPA_ClusterHeuristic(int fromIdx, int toIdx)
{
    if (g_iHPAClusterCount < 2) return 0.0;

    float fromCenter[3], toCenter[3];
    g_hAStarCenters.GetArray(fromIdx, fromCenter, 3);
    g_hAStarCenters.GetArray(toIdx, toCenter, 3);

    float cellSize = g_hCvarHpaCellSize != null ? g_hCvarHpaCellSize.FloatValue : 1024.0;
    int fcx = RoundToFloor(fromCenter[0] / cellSize);
    int fcy = RoundToFloor(fromCenter[1] / cellSize);
    int fcz = RoundToFloor(fromCenter[2] / cellSize);

    int tcx = RoundToFloor(toCenter[0] / cellSize);
    int tcy = RoundToFloor(toCenter[1] / cellSize);
    int tcz = RoundToFloor(toCenter[2] / cellSize);

    // Same cluster: no boost needed
    if (fcx == tcx && fcy == tcy && fcz == tcz) return 0.0;

    // Different clusters: add cluster-center distance as a mild boost
    // This helps A* prefer paths that make progress between clusters
    float fc[3], tc[3];
    fc[0] = (fcx + 0.5) * cellSize;
    fc[1] = (fcy + 0.5) * cellSize;
    fc[2] = (fcz + 0.5) * cellSize;
    tc[0] = (tcx + 0.5) * cellSize;
    tc[1] = (tcy + 0.5) * cellSize;
    tc[2] = (tcz + 0.5) * cellSize;

    return GetVectorDistance(fc, tc, false) * 0.05; // 5% boost — very mild
}

// ============================================================================
// v4.0 Nav Mesh Bridge Detection — cross-component connectivity
//
// On maps with disconnected nav mesh components (common in third-party maps),
// finds nearby but unconnected nav areas that a human player could traverse
// between (by jumping, dropping, or walking through an unmarked passage).
// These bridges are added as non-mesh edges so A* can find paths across
// component boundaries.
// ============================================================================

stock void DetectNavMeshBridges()
{
    if (g_hAStarNodes == null || g_hAStarNodes.Length < 2) return;

    int nodeCount = g_hAStarNodes.Length;
    int bridgesFound = 0;

    // Use a simple flood-fill from start to identify the primary component
    // Then for any area NOT in the primary component, look for nearby areas
    // in the primary component that a player could physically reach.

    // v4.0: Nav mesh bridge detection uses a StringMap-based reachability set
    // to avoid stack overflow on maps with 10K+ nav areas.
    // Key = nodeIndex as string, Value = 1 if reachable.
    int startIdx = AStar_IdentifyStart();
    if (startIdx < 0) return;

    // Use StringMap for O(1) lookup without stack allocation
    StringMap reachableMap = new StringMap();
    ArrayList bfsQueue = new ArrayList();
    bfsQueue.Push(startIdx);

    char rkey[16];
    IntToString(startIdx, rkey, sizeof(rkey));
    reachableMap.SetValue(rkey, 1);
    int reachableCount = 1;

    // Cap BFS at 5000 nodes to prevent excessive iteration
    int bfsLimit = 5000;
    while (bfsQueue.Length > 0 && reachableCount < bfsLimit)
    {
        int current = bfsQueue.Get(0);
        bfsQueue.Erase(0);

        int areaInt = g_hAStarNodes.Get(current);
        Address area = view_as<Address>(areaInt);

        if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
        GetNavConnections(area, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

        for (int n = 0; n < ConAdj.Length && reachableCount < bfsLimit; n++)
        {
            NavConnection nc;
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;

            int otherInt = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(otherInt, keyB, sizeof(keyB));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;

            IntToString(otherIdx, rkey, sizeof(rkey));
            if (reachableMap.ContainsKey(rkey)) continue;

            reachableMap.SetValue(rkey, 1);
            bfsQueue.Push(otherIdx);
            reachableCount++;
        }
    }

    delete bfsQueue;

    #if DEBUG
    LogMessage("[PTG] Bridge detection: %d/%d nodes reachable from start (%.1f%%)",
        reachableCount, nodeCount, (float(reachableCount) / nodeCount) * 100.0);
    #endif

    // If most nodes are reachable, bridges aren't needed
    if (reachableCount > nodeCount * 0.9 || reachableCount >= bfsLimit)
    {
        delete reachableMap;
        return;
    }

    // For each UNREACHABLE node, look for nearby REACHABLE nodes within
    // spatial proximity that could be traversed (jump/drop/walk gap).
    float bridgeMaxDist = 256.0; // max distance to search for bridge
    int unreachableScanned = 0;
    int unreachableLimit = 2000; // cap to avoid excessive processing

    for (int i = 0; i < nodeCount && unreachableScanned < unreachableLimit; i++)
    {
        IntToString(i, rkey, sizeof(rkey));
        if (reachableMap.ContainsKey(rkey)) continue;
        unreachableScanned++;

        float center[3];
        g_hAStarCenters.GetArray(i, center, 3);

        // Query spatial hash for nearby reachable nodes
        if (g_hNonMeshNearby == null) g_hNonMeshNearby = new ArrayList();
        SpatialHash_Query(center, g_hNonMeshNearby, bridgeMaxDist, 2);

        float bestDist = bridgeMaxDist * bridgeMaxDist + 1.0;
        int bestReachable = -1;
        ConnectionType bestType = CONNECTED_NOT;

        for (int j = 0; j < g_hNonMeshNearby.Length; j++)
        {
            int otherInt = g_hNonMeshNearby.Get(j);
            char keyB[16];
            IntToString(otherInt, keyB, sizeof(keyB));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;
            IntToString(otherIdx, rkey, sizeof(rkey));
            if (!reachableMap.ContainsKey(rkey)) continue;

            float otherCenter[3];
            g_hAStarCenters.GetArray(otherIdx, otherCenter, 3);

            float dz = otherCenter[2] - center[2];
            float dzAbs = FloatAbs(dz);
            float xyDist = GetVectorDistance(center, otherCenter, false);

            // Check if a player could traverse between these positions
            ConnectionType bridgeType = CONNECTED_NOT;

            // Drop down: unreachable is LOWER than reachable
            if (dz >= -g_Caps.max_safe_drop && dz <= -g_Caps.max_step_up && xyDist < 120.0)
            {
                if (ValidateDropArc(center, otherCenter, g_Caps))
                    bridgeType = CONNECTED_JUMP_DOWN;
            }
            // Jump up: unreachable is HIGHER than reachable
            else if (dz >= g_Caps.max_step_up && dz <= g_Caps.max_jump_height && xyDist < 80.0)
            {
                if (ValidateJumpArc(center, otherCenter, g_Caps))
                    bridgeType = CONNECTED_JUMP_UP;
            }
            // Horizontal gap jump
            else if (dzAbs < g_Caps.max_step_up * 2.0 && xyDist >= 80.0 && xyDist <= g_Caps.max_gap_jump)
            {
                float mid[3];
                mid[0] = (center[0] + otherCenter[0]) / 2.0;
                mid[1] = (center[1] + otherCenter[1]) / 2.0;
                mid[2] = (center[2] + otherCenter[2]) / 2.0;

                float midDown[3];
                midDown = mid; midDown[2] -= 200.0;
                TR_TraceRayFilter(mid, midDown, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                if (!TR_DidHit() && ValidateJumpArc(center, otherCenter, g_Caps))
                    bridgeType = CONNECTED_GAP_JUMP;
            }
            // Same level but close (nav mesh gap in floor)
            else if (dzAbs < 32.0 && xyDist < 64.0)
            {
                bridgeType = CONNECTED_ADJACENT;
            }

            if (bridgeType != CONNECTED_NOT)
            {
                float distSq = GetVectorDistance(center, otherCenter, true);
                if (distSq < bestDist)
                {
                    bestDist = distSq;
                    bestReachable = otherIdx;
                    bestType = bridgeType;
                }
            }
        }

        // Add bridge as non-mesh edge
        if (bestReachable >= 0 && bestType != CONNECTED_NOT)
        {
            int areaInt = g_hAStarNodes.Get(i);
            int otherAreaInt = g_hAStarNodes.Get(bestReachable);

            NonMeshEdge bridge;
            bridge.fromArea = areaInt;       // unreachable → reachable
            bridge.toArea = otherAreaInt;
            bridge.edgeType = bestType;

            if (g_hNonMeshEdges == null)
                g_hNonMeshEdges = new ArrayList(sizeof(NonMeshEdge));
            g_hNonMeshEdges.PushArray(bridge, sizeof(NonMeshEdge));

            // Also add reverse for bidirectional types
            if (bestType != CONNECTED_JUMP_UP && bestType != CONNECTED_JUMP_DOWN)
            {
                bridge.fromArea = otherAreaInt;
                bridge.toArea = areaInt;
                g_hNonMeshEdges.PushArray(bridge, sizeof(NonMeshEdge));
            }

            bridgesFound++;
        }
    }

    if (bridgesFound > 0)
    {
        LogMessage("[PTG] NavMeshBridge: %d cross-component bridges found (%d/%d nodes unreachable)",
            bridgesFound, nodeCount - reachableCount, nodeCount);
    }
    delete reachableMap;
}

// ============================================================================
// v4.0 3D Funnel Enhancement — Z-layer awareness
//
// Post-processes funnel waypoints to handle multi-floor transitions.
// When consecutive funnel waypoints have a large Z gap (> funnel_z_step),
// this function inserts intermediate guiding waypoints that trace a valid
// 3D path (vertical transitions, stair landings, elevator stops).
//
// Called from AStar_ReconstructPath after the 2D funnel completes.
// ============================================================================

stock void Funnel3D_InsertZTransitions(ArrayList cells)
{
    if (cells == null || cells.Length < 2) return;
    if (g_hCvarFunnel3D == null || !g_hCvarFunnel3D.BoolValue) return;

    float zStep = g_hCvarFunnelZStep != null ? g_hCvarFunnelZStep.FloatValue : 80.0;

    // Build new cell list with Z transitions inserted
    ArrayList result = new ArrayList(sizeof(Cell));
    Cell prev; cells.GetArray(0, prev, sizeof(Cell));
    result.PushArray(prev, sizeof(Cell));

    for (int i = 1; i < cells.Length; i++)
    {
        Cell curr;
        cells.GetArray(i, curr, sizeof(Cell));

        float dz = curr.center[2] - prev.center[2];
        float dzAbs = FloatAbs(dz);

        if (dzAbs > zStep)
        {
            // Large Z gap — insert intermediate transition waypoints
            int steps = RoundToCeil(dzAbs / zStep);
            if (steps > 8) steps = 8; // cap to prevent excessive waypoints

            for (int s = 1; s < steps; s++)
            {
                float t = float(s) / float(steps);
                Cell mid;
                mid.navArea = Address_Null;
                mid.flow = prev.flow + (curr.flow - prev.flow) * t;
                mid.center[0] = prev.center[0] + (curr.center[0] - prev.center[0]) * t;
                mid.center[1] = prev.center[1] + (curr.center[1] - prev.center[1]) * t;
                mid.center[2] = prev.center[2] + (curr.center[2] - prev.center[2]) * t;

                // Try to snap intermediate Z to ground via trace
                float groundCheck[3];
                groundCheck = mid.center;
                groundCheck[2] -= 500.0;
                TR_TraceRayFilter(mid.center, groundCheck, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                if (TR_DidHit())
                {
                    float groundPos[3];
                    TR_GetEndPosition(groundPos);
                    mid.center[2] = groundPos[2] + 16.0;
                }

                result.PushArray(mid, sizeof(Cell));
            }
        }

        result.PushArray(curr, sizeof(Cell));
        prev = curr;
    }

    // Replace original cells with enhanced version
    cells.Clear();
    for (int i = 0; i < result.Length; i++)
    {
        Cell c;
        result.GetArray(i, c, sizeof(Cell));
        cells.PushArray(c, sizeof(Cell));
    }
    delete result;
}

///////////// SDK

void LoadSDK()
{
    g_bFlowRecomputeHooked = false;
    g_hRecomputeFlow = null;
    g_hRecomputeFlowDetour = null;
    Handle gd = LoadGameConfigFile(PLUGIN_NAME);
    if (gd == null)
    {
        LogMessage("Missing gamedata file: %s.txt", PLUGIN_NAME);
        delete gd;
        return;
    }

    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "TerrorNavMesh::RecomputeFlowDistances"))
    {
        LogMessage("RecomputeFlowDistances PrepSDKCall_SetFromConf failed");
    }
    g_hRecomputeFlow = EndPrepSDKCall();
    if (g_hRecomputeFlow == null)
    {
        LogMessage("RecomputeFlowDistances SDKCall setup failed");
    }

    g_hRecomputeFlowDetour = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
    if (g_hRecomputeFlowDetour == null)
    {
        LogMessage("RecomputeFlowDistances DHookCreateDetour failed");
    }
    if (!DHookSetFromConf(g_hRecomputeFlowDetour, gd, SDKConf_Signature, "TerrorNavMesh::RecomputeFlowDistances"))
    {
        LogMessage("RecomputeFlowDistances failed");
        g_hRecomputeFlowDetour = null;
    }
    if (g_hRecomputeFlowDetour != null)
    {
        g_bFlowRecomputeHooked = g_hRecomputeFlowDetour.Enable(Hook_Post, Hook_RecomputeFlowPost);
    }
    delete gd;
}

public MRESReturn Hook_RecomputeFlowPost(Address pThis)
{
    #if DEBUG>1
    LogMessage("RecomputeFlowDistances");
    #endif
    NavChanged(true);
    return MRES_Ignored;
}