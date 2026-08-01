// PTG Module: ptg_guide — RequestGuide, detour_join, DrawBeam, client beam management
// Extracted from l4d_path_to_goal.inc (backup)

// ── Client request handling ──
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


// ── RequestGuide + detour_join + DrawBeam ──
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

    // v4.6: REPAIR is rewriting g_GuideCells in place — the request is already
    // queued above and will be flushed by Timer_CheckRequests(null) when the
    // REPAIR chain completes. Drawing now would read mid-mutation arrays.
    if (g_bGuideCellsBusy) return false;

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
                // v4.6 FIX: skip beams that failed hull validation and repair
                // (blocked → beaconed). Drawing them puts the guide line
                // through walls/floors — restart the beam at the dead-end cell
                // instead, leaving a visible gap where the beacon pillar marks.
                if (g_bBeamWalkable != null && (g_iForward - 1) < g_bBeamWalkable.Length
                    && g_bBeamWalkable.Get(g_iForward - 1) == 0)
                {
                    g_GuideCells.GetArray(g_iForward, cell, sizeof(Cell));
                    pos_forward = cell.center; // restart at the dead-end cell
                    end = false;
                    continue;
                }
                g_GuideCells.GetArray(g_iForward,cell,sizeof(Cell));
                // v4.7: jump-validated beams (vault/jump arc) render as a
                // parabola — a straight line would clip through the ledge or
                // barrier the jump cleared.
                if (cell.jumpFlag)
                {
                    float apex[3];
                    apex[0] = (pos_forward[0] + cell.center[0]) * 0.5;
                    apex[1] = (pos_forward[1] + cell.center[1]) * 0.5;
                    apex[2] = (pos_forward[2] + cell.center[2]) * 0.5 + 60.0;
                    float maxZ = (pos_forward[2] > cell.center[2]) ? pos_forward[2] : cell.center[2];
                    if (apex[2] > maxZ + 40.0) apex[2] = maxZ + 40.0;
                    DrawBeam(client,pos_forward,apex,duration,color_forward);
                    DrawBeam(client,apex,cell.center,duration,color_forward);
                    i_draw += 2;
                }
                else
                {
                    DrawBeam(client,pos_forward,cell.center,duration,color_forward);
                    i_draw += 1;
                }
                pos_forward = cell.center;
                end = false;
                if (i_draw>=g_hCvarMax.IntValue) break;
            }
            if (backward && g_iBackward>0)
            {
                g_iBackward -= 1;
                if (g_bBeamWalkable != null && g_iBackward < g_bBeamWalkable.Length
                    && g_bBeamWalkable.Get(g_iBackward) == 0)
                {
                    g_GuideCells.GetArray(g_iBackward, cell, sizeof(Cell));
                    pos_backward = cell.center; // restart at the dead-end cell
                    end = false;
                    continue;
                }
                g_GuideCells.GetArray(g_iBackward,cell,sizeof(Cell));
                // v4.7: jump arc (backward leg) — the flag sits on the cell the
                // beam ENTERS, which in backward direction is g_iBackward+1
                // (this beam runs cell[g_iBackward] → cell[g_iBackward+1]).
                Cell jumpCell;
                g_GuideCells.GetArray(g_iBackward + 1, jumpCell, sizeof(Cell));
                if (jumpCell.jumpFlag)
                {
                    float apex[3];
                    apex[0] = (cell.center[0] + pos_backward[0]) * 0.5;
                    apex[1] = (cell.center[1] + pos_backward[1]) * 0.5;
                    apex[2] = (cell.center[2] + pos_backward[2]) * 0.5 + 60.0;
                    float maxZ = (cell.center[2] > pos_backward[2]) ? cell.center[2] : pos_backward[2];
                    if (apex[2] > maxZ + 40.0) apex[2] = maxZ + 40.0;
                    DrawBeam(client,cell.center,apex,duration,color_backward);
                    DrawBeam(client,apex,pos_backward,duration,color_backward);
                    i_draw += 2;
                }
                else
                {
                    DrawBeam(client,cell.center,pos_backward,duration,color_backward);
                    i_draw += 1;
                }
                pos_backward = cell.center;
                end = false;
            }
        }
    }
    if (i_draw>0)
    {
        LogMessage("[PTG] Beams drawn: client %d flow %.1f cells %d start %d", client, flow, i_draw, g_iStart);
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


// ── Beam cooldown management ──
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
