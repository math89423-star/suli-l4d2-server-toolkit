// PTG Module: ptg_pipeline — Stage pipeline, Guide_Prep, OnFramePrep, Check_Guidable, Guide_Cleanup
// Extracted from l4d_path_to_goal.inc (backup)

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

float g_fPrepStartTime;

void Guide_Prep()
{
    // v4.6: Old 30s total-time watchdog removed. It killed SLOW pipelines on big
    // maps (unbounded build time → infinite fallback retry loop → permanent path
    // loss). Progress-based watchdog lives in Timer_AutoCheck + OnFramePrep:
    // it only resets a pipeline whose frame chain has fully stalled.
    // g_fPrepStartTime kept as a diagnostic field.

    if (!enable || !gamemode_guidable || !map_started || !nav_started || guide_prep || is_prep_cooldown()) return;
    // v4.6: any real build request (player command, dirty rebuild, fallback
    // recovery) consumes the large-map lazy-build gate — only the background
    // prebuild in Timer_AutoCheck is gated.
    g_bLazyBuildRequested = true;
    #if DEBUG>1
    LogMessage("Guide_Prep");
    #endif
    guide_prep = true;
    g_fPrepStartTime = GetEngineTime();
    g_iPrepMapGen = g_iMapGeneration;
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
    guide_prep = false;
    g_bPathDirty = false;
    g_bGuideCellsBusy = false; // v4.6: REPAIR chain died with the pipeline — unblock draws/requests
    g_iBuildPhase = 0;
    g_iPortalBatchIdx = 0;
    g_iHPAClusterCount = 0;
    g_fPrepStartTime = 0.0;
    g_fLastPrepProgressTime = 0.0;

    // v4.6: release distributed sub-state machine resources (IdentifyGoal BFS
    // + SMOOTH chunks). Must happen on every cleanup — the mapgen guard now
    // actually fires, so stale async frames from the previous map abort here.
    g_iIGStage = 0;
    delete g_hIGQueue;
    g_hIGQueue = null;
    delete g_hIGReachable;
    g_hIGReachable = null;
    delete g_hSmoothNodePath;
    g_hSmoothNodePath = null;
    delete g_hFunnelResult;
    g_hFunnelResult = null;
    delete g_hPartialBeacon; // v4.6: partial-path dead-end beacon
    g_hPartialBeacon = null;
    g_bAStarPartialPath = false;

    if (guide_ready)
    {
        #if DEBUG>1
        LogMessage("Guide_Cleanup");
        #endif
        guide_ready = false;
    }
    delete g_GuideCells;
    delete g_bBeamWalkable;

    // Clean A* search state (may still be open if map changed mid-search)
    delete g_hAStarOpen;
    delete g_hAStarGScore;
    delete g_hAStarCameFrom;
    delete g_hAStarEdgeType;
    delete g_hAStarClosed;

    // Clean A* node index for current map
    delete g_hAStarNodes;
    delete g_hAStarCenters;
    delete g_hAStarAreaToIndex;
    delete g_hSpatialHash;
    delete g_hPortalCache;

    // Clean non-mesh edges
    delete g_hNonMeshEdges;

    // Reset globals to clean state
    g_bAStarPathFound = false;
    g_iAStarGoalIndex = -1;
    g_iAStarBestIdx = -1;
    g_fAStarBestG = -1.0;
    g_aAStarStart = 0;
    g_aAStarGoal = 0;
    g_bFoundRescueVehicle = false;
    g_aNavRescueVehicle = Address_Null;
    g_fFlowRescueVehicle = -1.0;
    g_fMaxFlow = -1.0;
    finale_stitched = false;
    finale_backwards = false;

    delete RescueVehicleCells;

    // NOTE: g_hBeaconCells, HPA* cluster variables, and late-declared globals
    // are cleaned in OnMapEnd (l4d_path_to_goal.sp) since they are declared
    // after Guide_Cleanup in this file (SourcePawn single-pass compiler).
}


void OnFramePrep(bool new_frame = true)
{
    // Abort if map changed since Guide_Prep started (RequestFrame may survive OnMapEnd)
    if (g_iPrepMapGen != g_iMapGeneration)
    {
        guide_prep = false;
        g_iPrepStage = STAGE_NONE;
        timer_nav = null;
        // v4.6: release distributed sub-state machine resources
        g_iIGStage = 0;
        delete g_hIGQueue; g_hIGQueue = null;
        delete g_hIGReachable; g_hIGReachable = null;
        delete g_hSmoothNodePath; g_hSmoothNodePath = null;
        delete g_hFunnelResult; g_hFunnelResult = null;
        return;
    }
    if (!enable || guide_ready || !gamemode_guidable || !map_started || !nav_started || g_iPrepStage<=STAGE_NONE || g_iPrepStage>=STAGE_END)
    {
        guide_prep = false;
        g_iPrepStage = STAGE_NONE;
        timer_nav = null;
        // v4.6: release distributed sub-state machine resources
        g_iIGStage = 0;
        delete g_hIGQueue; g_hIGQueue = null;
        delete g_hIGReachable; g_hIGReachable = null;
        delete g_hSmoothNodePath; g_hSmoothNodePath = null;
        delete g_hFunnelResult; g_hFunnelResult = null;
        return;
    }
    static float pos[3];
    static Cell cell, cell_before, cell_after;
    bool budget_spent = false; // same variable for all stages
    // v4.6 watchdog: every OnFramePrep call (new frame or recursive) is pipeline
    // progress. Must be AFTER the abort guards — a guard reset should not refresh
    // the timestamp (the stalled chain we're detecting is the one that never
    // reaches this point).
    g_fLastPrepProgressTime = GetEngineTime();
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
            LogMessage("[PTG] STAGE_PREP entered, buildPhase=%d budget_spent=%d", g_iBuildPhase, budget_spent);
            // v4.0: Batched index construction — spreads expensive operations
            // (portal computation, HPA clustering, bridge detection) across
            // multiple frames to avoid SIGALRM on 5K+ nav area maps.
            // IMPORTANT: use break (not return) to exit inner switch so the
            // post-switch RequestFrame scheduling code still executes.
            // --- Phase 0: Basic init + node index build ---
            // Each phase is guarded by !budget_spent to prevent running
            // multiple phases in one frame (which would cause an infinite
            // build loop when g_iBuildPhase wraps back to 0).
            if (!budget_spent && g_iBuildPhase == 0)
            {
                LogMessage("[PTG] Build phase 0: node index");
                g_fMaxFlow = L4D2Direct_GetMapMaxFlowDistance();

                // Build node index FIRST — we may need it to compute max flow ourselves
                // if the engine's MapMaxFlowDistance is 0 (common on custom maps without nav_analyze).
                AStar_BuildNodeIndex();
                if (g_hAStarNodes == null || g_hAStarNodes.Length <= 1)
                {
                    guide_prep = false;
                    g_iPrepStage = STAGE_NONE;
                    LogMessage("[PTG] A* node index failed: too few nav areas");
                    return;
                }

                // If engine didn't compute MapMaxFlowDistance (common on custom/maze maps),
                // compute it ourselves from per-area flow values.
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
                        LogMessage("[PTG] Engine MapMaxFlowDistance was 0, computed from nav areas: %.1f", g_fMaxFlow);
                    }
                    else
                    {
                        // No valid flow data at all — keep g_fMaxFlow=0 as sentinel.
                        // AStar_IdentifyStart will skip flow filtering,
                        // AStar_IdentifyGoal will fall through to Euclidean distance strategies.
                        LogMessage("[PTG] No flow data available — using spatial-only A* (no nav_analyze on this map)");
                    }
                }

                g_iBuildPhase = 1;
                g_iPortalBatchIdx = 0;
                budget_spent = true;
            }

            // --- Phase 1: Batched portal computation ---
            if (!budget_spent && g_iBuildPhase == 1)
            {
                LogMessage("[PTG] Build phase 1: portal batch idx=%d", g_iPortalBatchIdx);
                if (AStar_ComputePortalsBatch(g_iPortalBatchIdx, PORTALS_PER_FRAME))
                {
                    g_iPortalBatchIdx += PORTALS_PER_FRAME;
                    budget_spent = true;
                }
                else
                {
                    g_iBuildPhase = 2;
                }
            }

            // --- Phase 2: HPA* clusters ---
            if (!budget_spent && g_iBuildPhase == 2)
            {
                if (g_hCvarHpaEnable != null && g_hCvarHpaEnable.BoolValue)
                {
                    // v4.6: skip HPA on very large maps. Pass 2 is ~30-60ms of
                    // single-frame work (2× Format + 2× StringMap ops per edge)
                    // and reliably triggers SIGALRM at 5K+ areas. HPA is only a
                    // 5% heuristic boost — skipping changes nothing about
                    // correctness, only A* convergence speed.
                    if (g_hAStarNodes != null && g_hAStarNodes.Length > HPA_SKIP_THRESHOLD)
                    {
                        g_iHPAClusterCount = 0;
                        LogMessage("[PTG] HPA skipped: %d nav areas > threshold %d", g_hAStarNodes.Length, HPA_SKIP_THRESHOLD);
                    }
                    else
                    {
                        HPA_BuildClusters();
                    }
                }
                g_iBuildPhase = 3;
                budget_spent = true;
            }

            // --- Phase 3: Nav mesh bridge detection ---
            if (!budget_spent && g_iBuildPhase == 3)
            {
                if (g_hCvarNonMesh != null && g_hCvarNonMesh.BoolValue)
                    DetectNavMeshBridges();
                g_iBuildPhase = -1; // skip directly to post-build sentinel
                g_iPostStep = 0;    // v4.6: reset post-build sub-state machine
                budget_spent = true; // defer post-build to NEXT frame
                // DetectNavMeshBridges does a BFS flood-fill + bridge scan across
                // nav areas. Running it AND post-build init (rescue vehicle scan
                // + IdentifyStart/Goal + AStar_Init + non-mesh init) in ONE frame
                // exceeds the Source engine CPU budget → SIGALRM. Splitting them
                // across frames prevents this without losing functionality.
            }

            // --- Post-build initialization (original STAGE_PREP logic) ---
            // Only run when all batch phases are done (budget_spent is false
            // and g_iBuildPhase is the sentinel -1).
            // v4.6: sub-state machine (g_iPostStep 0-4). IdentifyGoal's BFS was
            // the single-frame killer here (20K nodes, O(V²) queue) — now
            // distributed via AStar_IdentifyGoal_Frame. AStar_Init (4×n pushes)
            // also gets its own step.
            if (!budget_spent && g_iBuildPhase == -1)
            {
            switch (g_iPostStep)
            {
                case 0: // rescue vehicle scan + IdentifyStart (O(n) — safe single frame)
                {
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

                    g_iPostStartIdx = AStar_IdentifyStart();
                    g_iPostStep = 1;
                    budget_spent = true;
                }
                case 1: // IdentifyGoal init (strategy 1 O(n); BFS state setup)
                {
                    AStar_IdentifyGoal_Init(g_iPostStartIdx);
                    if (g_iIGStage == 1)
                        g_iPostStep = 2; // BFS running — process in frames
                    else
                        g_iPostStep = 3; // done (rescue vehicle hit or no BFS)
                    budget_spent = true;
                }
                case 2: // IdentifyGoal BFS frames
                {
                    if (AStar_IdentifyGoal_Frame(BFS_NODES_PER_FRAME))
                        g_iPostStep = 3; // BFS complete — finish next frame
                    // v4.6 FIX: budget_spent must be set in BOTH branches.
                    // Missing it here advanced g_iPrepStage to STAGE_ASTAR with
                    // case 3 (goal) and case 4 (AStar_Init+SetStart) never run
                    // → null open set → "A* failed: no reachable nodes".
                    // (First build after map load failed, retry succeeded only
                    //  by racing the frame-budget check.)
                    budget_spent = true;
                }
                case 3: // IdentifyGoal finish + validate start/goal
                {
                    int startIdx = g_iPostStartIdx;
                    int goalIdx = AStar_IdentifyGoal_Finish();

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

                    g_iPostStep = 4;
                    budget_spent = true;
                }
                case 4: // A* state init + non-mesh detection start
                {
                    int startIdx = g_iPostStartIdx;

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
                    g_iBuildPhase = -2; // mark post-build as done: prevents re-entry
                    // (g_iBuildPhase==-1 would re-enter post-build every frame;
                    //  -2 ensures no phase matches, so g_iPrepStage advances to STAGE_ASTAR)
                    budget_spent = true; // defer A* search to next frame.
                    // Post-build init (IdentifyStart/Goal + AStar_Init + non-mesh init)
                    // is already expensive on large maps. Running STAGE_ASTAR in the
                    // same frame triggers SIGALRM on 11K+ nav area maps.
                }
            } // switch (g_iPostStep)
            } // if (!budget_spent)
        }
        case STAGE_ASTAR:
        {
            if (!budget_spent)
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
            } // if (!budget_spent)
        }
        case STAGE_SMOOTH:
        {
            // v4.6: sub-state machine (g_iSmoothStep 0-4). The old single-frame
            // block (portal compute + full ReconstructPath + funnel) crashed
            // large maps via SIGALRM. Portal computation is skipped entirely:
            // g_hPortalCache has no consumers (AStar_ReconstructPath uses nav
            // area centers — accurate portals need L4D_NavArea_GetCorner which
            // left4dhooks lacks), so the fallback path's synchronous
            // AStar_ComputePortals() was pure dead work + crash risk.
            switch (g_iSmoothStep)
            {
                case 0: // rebuild cell list + reconstruct init
                {
                    delete g_GuideCells;
                    g_GuideCells = new ArrayList(sizeof(Cell));

                    if (!AStar_ReconstructPath_Init(g_GuideCells))
                    {
                        LogMessage("[PTG] A* produced <2 guide cells — falling back");
                        delete g_GuideCells;
                        guide_prep = false;
                        g_iPrepStage = STAGE_NONE;
                        return;
                    }
                    g_iSmoothStep = 1;
                    budget_spent = true;
                }
                case 1: // convert nav areas → guide cells (frame-budgeted)
                {
                    if (AStar_ReconstructPath_ConvertFrame(g_GuideCells, CELLS_PER_FRAME))
                    {
                        g_iSmoothIdx = 1; // validation starts at edge 1
                        g_iSmoothStep = 2;
                    }
                    budget_spent = true;
                }
                case 2: // validation cascade (frame-budgeted)
                {
                    if (AStar_ReconstructPath_ValidateFrame(g_GuideCells, EDGES_PER_FRAME))
                        g_iSmoothStep = 3;
                    budget_spent = true;
                }
                case 3: // 3D funnel Z-transitions (frame-budgeted)
                {
                    if (g_hFunnelResult != null)
                    {
                        // funnel in progress — keep pushing
                        if (Funnel3D_InsertZTransitions_Frame(g_GuideCells))
                            g_iSmoothStep = 4;
                        else
                            budget_spent = true;
                    }
                    else
                    {
                        // funnel not started — init it (no-op when cvar off / too short)
                        Funnel3D_InsertZTransitions_Init(g_GuideCells);
                        if (g_hFunnelResult == null)
                            g_iSmoothStep = 4; // nothing to do
                        else
                            budget_spent = true; // work started — continue next frame
                    }
                }
                case 4: // finish
                {
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
                    delete g_hSmoothNodePath;
                    g_hSmoothNodePath = null;

                    // Track rescue vehicle relative to guide path
                    if (g_bFoundRescueVehicle)
                    {
                        float maxGuideFlow = g_GuideCells.Get(g_GuideCells.Length - 1, 0);
                        finale_backwards = g_fFlowRescueVehicle < maxGuideFlow;
                        if (explored_finale == null) explored_finale = new ArrayList();
                        explored_finale.Clear();
                    }

                    // v4.6: partial path (A* open set exhausted — disconnected
                    // nav mesh): beacon the dead end. Separate from
                    // g_hBeaconCells so REPAIR's rebuild can't wipe it.
                    if (g_bAStarPartialPath && g_hCvarBeaconEnable != null && g_hCvarBeaconEnable.BoolValue)
                    {
                        delete g_hPartialBeacon;
                        g_hPartialBeacon = new ArrayList(3);
                        Cell lastCell;
                        g_GuideCells.GetArray(g_GuideCells.Length - 1, lastCell, sizeof(Cell));
                        g_hPartialBeacon.PushArray(lastCell.center, 3);
                    }

                    g_iLoop = 1;
                    g_iSmoothStep = 0; // reset for next build
                    budget_spent = true;
                }
            } // switch (g_iSmoothStep)
        }
        case STAGE_JOIN:
        {
            if (!budget_spent)
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
            } // if (!budget_spent)
        }
        case STAGE_VALIDATE:
        {
            if (!budget_spent)
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
            } // if (!budget_spent)
        }
        case STAGE_REPAIR:
        {
            if (!budget_spent)
            {
            // v4.0: Repair is triggered asynchronously from Guide_ValidateWalkable_Frame
            // when validation completes. This stage is a pass-through to maintain
            // pipeline ordering (REPAIR runs after VALIDATE).
            g_iLoop = 1;
            } // if (!budget_spent)
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
        g_bPathDirty = false; // v4.6: fresh path supersedes any pending dirty rebuild
        LogMessage("[PTG] Pipeline done: %d guide cells ready%s", g_GuideCells != null ? g_GuideCells.Length : -1,
            g_bAStarPartialPath ? " — PARTIAL path (disconnected nav mesh, dead-end beacon placed)" : "");
        Guide_ValidateWalkable(); // v2.2: hull-trace validate all beams against world geometry
        // v4.5: Immediately redraw for all toggled clients — no 0.3s gap
        Guide_RedrawAllToggled();
        beams_cooldown_reset(); // reset cooldowns but not requests to draw
        #if DEBUG
        g_fPrepTotalTime += (GetEngineTime()-g_tFrameStart);
        LogMessage("[PTG] Guide ready: %d cells (%d nav areas) (%f ms %d frames)",
        g_GuideCells.Length, g_iTotalCollected, g_fPrepTotalTime*1000.0, g_iPrepFrames);
        #endif
        g_iPrepStage = STAGE_NONE;
        timer_nav = null;
        if (finale_stitched && finale_rescue && g_hCvarFinaleAuto.BoolValue) Guide_All_Clients();
        else if (g_bDetourQueued && !g_bDetourActive)
        {
            // v4.6: a nav_blocked detour was deferred while the pipeline ran
            Address queued = g_aDetourQueuedArea;
            g_bDetourQueued = false;
            g_aDetourQueuedArea = Address_Null;
            Guide_TryLocalDetour(queued);
        }
        else Timer_CheckRequests(null); // Draw beams immediately for pending clients
    }

}

// Look for closest survivor ladder manually, quite expensive. Output cell_ladder
