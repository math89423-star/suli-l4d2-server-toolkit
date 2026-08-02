// PTG Module: ptg_types — Types, enums, structs, global state
// Extracted from l4d_path_to_goal.inc (backup)

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
	bool jumpFlag;   // v4.7: beam INTO this cell was validated as a jump/vault
	                 // (parabolic path) — the drawer renders an arc, not a line
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
        case CONNECTED_JUMP_DOWN:  return 3.0;   // v4.1: same as JUMP_UP — dropping through windows shouldn't be preferred
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
// v4.7: now carries the human-capability classification (see ptg_portal.inc).
enum struct PortalInfo
{
    float ep1[3];    // first endpoint of shared edge
    float ep2[3];    // second endpoint of shared edge
    float center[3]; // midpoint of shared edge (primary waypoint)
    float dz;        // v4.7: Z delta across the portal (fromArea - toArea, + = drop)
    ConnectionType connectiontype; // v4.7: ADJACENT / VAULT / JUMP_DOWN (human-traversable)
    bool walkable;   // v4.7: false = excluded (cjump / gap / deadly drop)
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
#define ASTAR_NODES_PER_FRAME 100 // v4.6: halved — each edge now does a snapped-space LOS trace

// v4.0 HPA* globals (declared here for single-pass compiler)
int g_iHPAClusterCount;
// v4.6.1: HPA build is distributed across frames (single-frame build was
// 30-60ms at 5K+ areas → SIGALRM). Cursors live here so the pipeline can
// resume Pass 1/Pass 2 across frames.
int g_iHPABuildStage;          // 0=idle 1=pass1(assign) 2=pass2(adjacency)
int g_iHPABuildNode;           // pass1 cursor over g_hAStarNodes
int g_iHPABuildCluster;        // pass2 cursor over clusters
int g_iHPABuildNodeInCluster;  // pass2 cursor within current cluster

// v4.0 batched index building — prevents SIGALRM (stack/CPU overflow) on large maps
// by distributing AStar_BuildNodeIndex work across multiple frames.
int g_iBuildPhase;              // 0=basic index, 1=portals, 2=HPA, 3=bridges, 4=post-build init
int g_iPortalBatchIdx;          // current batch position in portal computation
#define PORTALS_PER_FRAME 100   // v4.7: was 250 — corner-based build calls 4 GetCorner natives
                                // per area + GetZ per pair; 250/frame blew the 0.5ms budget

// Spatial hash for fast nearby-area queries
StringMap g_hSpatialHash;      // "cx_cy_cz" → ArrayList of {navArea(int), center(float[3])}
#define SPATIAL_CELL_SIZE 256.0

// Non-mesh connection cache
ArrayList g_hNonMeshEdges;     // NonMeshEdge — all detected non-mesh connections

// Portal cache — shared-edge midpoints between adjacent nav areas
// Key: "minIdx_maxIdx" (canonical ordering), Value: PortalInfo
StringMap g_hPortalCache;

// ── v4.7 portal geometry (ptg_portal.inc) ──
StringMap g_hPortalExcluded;      // "minIdx_maxIdx" → 1 — pairs classified NOT human-traversable
ArrayList g_hCornerCache;         // per node: float[12] (4 corners × 3) — built during portal phase
bool g_bPortalReady = false;      // portal classification finished for this build (Portal_Active gate)
bool g_bPortalBuildFailed = false;// portal build skipped (corner API unavailable / cvar off)
int g_iPathGen = 0;               // path generation counter — redraw dedup key
bool g_bCoarseDrawn = false;      // coarse (unvalidated) line already drawn for this build
int g_iAStarNodesPerFrame = 300;  // v4.7: adaptive A* nodes/frame (clamped 50..800)
float g_fLastDrawPos[MAXPLAYERS+1][3]; // v4.7: per-client last draw anchor (redraw dedup)
int g_iLastDrawGen[MAXPLAYERS+1];      // v4.7: per-client path generation at last draw
float g_fLastDrawTime[MAXPLAYERS+1];   // v4.7: per-client last draw engine time

// ── v4.7 string-pull / SSFA state (ptg_portal.inc) ──
ArrayList g_hPullResult = null;   // string-pull result (Cell) being built
int g_iPullJ = 0;                 // string-pull source cursor
int g_iPullAnchor = 0;            // string-pull index into g_hPullResult (current anchor)
int g_iPullLastSrc = 0;           // string-pull source index of the last committed cell
ArrayList g_hSSFAPortals = null;  // SSFA: PortalInfo chain between consecutive cells
ArrayList g_hSSFAPath = null;     // SSFA: output waypoints (float[3])

// v4.7.1: portal build diagnostics (temporary counters — see FinishBuild log)
int g_iPortalDiagNeighbors = 0;   // raw adjacent areas enumerated
int g_iPortalDiagLookupMiss = 0;  // areaToIndex lookups that missed
int g_iPortalDiagClassified = 0;  // pairs actually classified

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
ConVar g_hCvarLazyLargeMaps; // v4.6: 1=skip background prebuild on maps over LAZY_MAP_THRESHOLD nav areas
ConVar g_hCvarBeaconEnable;
ConVar g_hCvarThetaStar, g_hCvarThetaLosMax;
ConVar g_hCvarHpaEnable, g_hCvarHpaCellSize;
ConVar g_hCvarFlowWeight, g_hCvarZCostFactor;
ConVar g_hCvarGeomPenalty; // v4.6: penalize A* edges whose straight line is blocked by world geometry
// ── v4.7 portal + performance cvars ──
ConVar g_hCvarPortals, g_hCvarPortalMinOverlap, g_hCvarPortalMaxDz, g_hCvarHumanJump;
ConVar g_hCvarAstarCheap, g_hCvarAstarBudgetMs, g_hCvarAstarNodes;
ConVar g_hCvarCoarseFirst, g_hCvarStringPull, g_hCvarFunnelSSFA, g_hCvarRedrawMinMove;
// v4.6: blocked-edge feedback — hull validation records beam pairs that fail,
// A* re-runs with those nav edges heavily penalized. Iterated up to
// GEOM_ITER_MAX times. Cleared per map (nav areas change with the map).
StringMap g_hBlockedEdges;
#define GEOM_ITER_MAX 1 // v4.7: was 3 — each rebuild rewrites the whole path
                        // (visible oscillation) and the penalty pushed A* onto
                        // roofs (cross-level edges were unconditionally legal).
                        // One iteration handles isolated wall-clipping edges.
#define GEOM_ITER_EDGE_PENALTY 5.0
int g_iGeomIter;
ConVar g_hCvarAccuracy;
bool g_bAccuracyEnabled = true; // v4.5: master switch for accuracy improvements (Fix 1/2/4/5/8)
ConVar g_hCvarLegacyMode;
Handle g_hAutoTimer = null;
Handle g_hAutoCheckTimer = null;
bool gamemode_guidable, guide_ready, guide_prep, map_started, nav_started, enable, g_bL4D2, finale, finale_rescue, finale_gauntlet;
bool g_bGlobalBeams = false; // When true, DrawBeam sends to all clients (auto-guide mode)
int g_iMapGeneration = 0; // incremented on each map start; async frame callbacks abort if stale

// v4.6 watchdog: stage-level progress detection — kills only STUCK pipelines,
// never slow ones. OnFramePrep refreshes this timestamp every frame; if the
// frame chain stops advancing for PREP_STALL_SECONDS (lost RequestFrame,
// event race), Timer_AutoCheck resets the pipeline and it restarts.
float g_fLastPrepProgressTime = 0.0;
#define PREP_STALL_SECONDS 10.0

// ── v4.6 post-build init sub-state machine (IdentifyGoal BFS distributed) ──
int g_iPostStep;              // 0=rescue scan+IdentifyStart, 1=IG init, 2=IG BFS, 3=IG finish, 4=AStar init
int g_iPostStartIdx;          // IdentifyStart result, consumed by IG init
int g_iIGStage;               // 0=idle, 1=BFS running, 2=done
int g_iIGResult;              // goal nodeIndex from strategy 1 (rescue vehicle), else -1
int g_iIGStartIndex;          // start nodeIndex for Euclidean fallback strategies
float g_fIGStartCenter[3];    // start center for farthest-distance tracking
ArrayList g_hIGQueue;         // BFS queue (nodeIndex); head cursor replaces Erase(0) → O(V²) killer
int g_iIGQueueHead;
StringMap g_hIGReachable;     // "nodeIdx" → 1
int g_iIGBfsLimit;            // = 20000
int g_iIGBestFlowIdx;         // max-flow reachable accumulator
float g_fIGBestFlow;
int g_iIGBestDistIdx;         // farthest-spatial reachable accumulator
float g_fIGBestDistSq;
#define BFS_NODES_PER_FRAME 2000
#define BFS_FRAGMENTED_THRESHOLD 100

// ── v4.6 STAGE_SMOOTH sub-state machine ──
int g_iSmoothStep;            // 0=init, 1=convert, 2=validate, 3=funnel, 4=finish
int g_iSmoothIdx;             // cursor into g_hSmoothNodePath / edge list
ArrayList g_hSmoothNodePath;  // forward nodeIndex list (start → goal)
float g_fSmoothStartFlow, g_fSmoothGoalFlow; // flow interpolation endpoints
ArrayList g_hFunnelResult;    // funnel intermediate result (null = funnel inactive)
int g_iFunnelIdx;
#define CELLS_PER_FRAME 150
#define EDGES_PER_FRAME 60
#define FUNNEL_CELLS_PER_FRAME 20

// ── v4.6 HPA large-map degradation ──
#define HPA_SKIP_THRESHOLD 12000 // v4.6.1: HPA build is now frame-distributed; only truly
                                  // huge maps skip it. Below the old 5000 no change; c2m3-class
                                  // maps (5951) now get the cluster heuristic (was: 30-60ms
                                  // single-frame build → SIGALRM → skipped at >5000).
#define HPA_CLUSTER_NODES_PER_FRAME 2500 // v4.6.1: pass-1 cluster-assign nodes per frame
#define HPA_ADJ_NODES_PER_FRAME 700      // v4.6.1: pass-2 adjacency nodes per frame

// ── v4.6 partial-path dead-end beacon ──
// A* open set exhausted (disconnected nav mesh) — the path stops at the best
// reachable node. Separate from g_hBeaconCells so REPAIR's lifecycle
// (delete/rebuild per pipeline run) can't wipe it.
bool g_bAStarPartialPath = false;
ArrayList g_hPartialBeacon; // 1 entry: dead-end position (float[3])

// ── v4.6 lazy build for large maps ──
int g_iNavAreaCount = -1;     // -1 = unknown; counted via L4D_GetAllNavAreas once nav_started
bool g_bLazyBuildRequested = false; // true once any real build request consumed the gate
#define LAZY_MAP_THRESHOLD 8000

// ── v4.6 local detour (ptg_detour.inc) ──
// forward so ptg_utils.inc (PathIntegrityCheck) and l4d_path_to_goal.sp
// (evtNavBlocked) can call the entry point before its include is inlined.
// Globals live here (not in ptg_detour.inc) because ptg_validate.inc's REPAIR
// completion branch reads them and validate is inlined BEFORE detour.
forward void Guide_TryLocalDetour(Address blockedArea);

#define DETOUR_WINDOW 12            // half-width of the window around the blocked cell
#define DETOUR_NODES_PER_FRAME 300  // local A* nodes expanded per frame
#define DETOUR_COLLECT_PER_FRAME 2000 // window BFS nodes per frame
#define DETOUR_NODE_LIMIT 4000      // hard cap on local node table
#define DETOUR_BOX_PADDING 400.0    // AABB expansion beyond window cell centers
#define DETOUR_CONVERT_PER_FRAME 150
// v4.6.1: detour chain frame budget (ms). The shared pipeline budget (0.5ms,
// l4d_path_to_goal_budget) made a windowed detour — BFS collect + local A*
// + convert + splice — take 40-100s per attempt (c2m3, 2026-08-01: splice
// failed at 22:22:14 and 22:23:54, ~44s and ~100s after chain start).
// 2ms/frame keeps a detour at 2-5s while holding server fps during it.
#define DETOUR_BUDGET_MS 2.0

bool g_bDetourActive = false;     // a detour frame chain is running
bool g_bDetourQueued = false;     // trigger arrived while busy — run after current chain
float g_fLastBuildDoneTime;       // v4.6.1: last full pipeline build finish time — detour/rebuild backoff gate
Address g_aDetourQueuedArea = Address_Null;
bool g_bDetourQueuedDirty = false;// NavChanged(true) arrived while detouring — rebuild after
int g_iDetourStage = 0;           // 0=idle, 1=collect, 2=local A*, 3=convert, 4=splice
int g_iDetourD = DETOUR_WINDOW;   // window half-width (grows on retry)
int g_iDetourBlockedIdx = -1;     // cell index of the blocked area on the path
int g_iDetourWinStart, g_iDetourWinEnd; // window cell range (anchors)
int g_iDetourStartIdx = -1, g_iDetourGoalIdx = -1; // anchor node indices
float g_fDetourMin[3], g_fDetourMax[3]; // AABB constraint for node collection

// local node table (window BFS result)
ArrayList g_hDetourNodes = null;  // nodeIndex list
StringMap g_hDetourNodeMap = null;// "nodeIdx" → local index
ArrayList g_hDetourG = null;      // float per local node
ArrayList g_hDetourCameFrom = null; // int per local node
ArrayList g_hDetourEdge = null;   // int per local node (ConnectionType)
ArrayList g_hDetourClosed = null; // int per local node
ArrayList g_hDetourOpen = null;   // HeapEntry priority queue
int g_iDetourCollectHead = 0;     // window BFS head cursor
ArrayList g_hDetourPath = null;   // forward nodeIndex list (local path result)
ArrayList g_hDetourCells = null;  // converted detour waypoints (Cell)
int g_iDetourConvIdx = 0;         // convert cursor

// ── v4.6 finale radio goal ──
bool g_bRadioGoalActive = false;   // finale radio (prop_finale_machine) needs operating
Address g_aRadioNavArea = Address_Null;
ArrayList g_hRadioBeacon = null;   // 1 entry: radio operation point (float[3])
ConVar g_hCvarRadioGoal;           // l4d_path_to_goal_radio_goal

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

bool g_bPathDirty; // path needs rebuild (blocked cells detected) but old path is still active for toggled clients
bool g_bGuideCellsBusy; // v4.6: REPAIR frame chain is mutating g_GuideCells/g_bBeamWalkable — draws snapshot, requests defer
bool finale_stitched; // finale guide was drawn
bool finale_backwards; // rescue vehicle is not at max flow -> flow cannot be used for guiding

bool elevator_available, corner_available, blocked_available; // check if l4dhooks is up to date

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

    // v4.5: Sync accuracy + legacy globals from ConVars
    if (g_hCvarAccuracy != null)
        g_bAccuracyEnabled = g_hCvarAccuracy.BoolValue;

    if (g_hCvarLegacyMode != null && g_hCvarLegacyMode.BoolValue)
    {
        g_bAccuracyEnabled = false;
        if (g_hCvarThetaStar != null) g_hCvarThetaStar.SetBool(false);
        if (g_hCvarHpaEnable != null) g_hCvarHpaEnable.SetBool(false);
        if (g_hCvarFunnel3D != null) g_hCvarFunnel3D.SetBool(false);
        if (g_hCvarRepairEnable != null) g_hCvarRepairEnable.SetBool(false);
        if (g_hCvarBeaconEnable != null) g_hCvarBeaconEnable.SetBool(false);
        if (g_hCvarGeomPenalty != null) g_hCvarGeomPenalty.SetBool(false);
        // v4.7: portal pipeline + perf features off in legacy mode
        if (g_hCvarPortals != null) g_hCvarPortals.SetBool(false);
        if (g_hCvarStringPull != null) g_hCvarStringPull.SetBool(false);
        if (g_hCvarFunnelSSFA != null) g_hCvarFunnelSSFA.SetBool(false);
        if (g_hCvarCoarseFirst != null) g_hCvarCoarseFirst.SetBool(false);
    }
    }

    // v4.7: L4D2 human players cannot jump (no jump key — only bots use nav
    // jump links). Zero the jump caps so no code path builds jump edges for
    // the human guide; vault/drop remain (mantle + falling are real mechanics).
    if (g_hCvarHumanJump != null && !g_hCvarHumanJump.BoolValue)
    {
        g_Caps.max_jump_height = 0.0;
        g_Caps.max_jump_distance = 0.0;
        g_Caps.max_gap_jump = 0.0;
    }

    // v4.7: adaptive A* cursor base (the search loop re-adapts it per frame)
    if (g_hCvarAstarNodes != null)
    {
        int baseNodes = view_as<int>(g_hCvarAstarNodes.FloatValue + 0.5);
        if (g_iAStarNodesPerFrame != baseNodes)
            g_iAStarNodesPerFrame = baseNodes;
    }
}

// ── Cross-module globals (originally declared after types) ──

ArrayList ConAdj, AdjNN, queue;

int g_iPrepStage, g_iLoop;
float g_tFrameStart;
ArrayList RescueVehicleCells;

int g_iPrepMapGen = -1;

ArrayList explored_finale;
