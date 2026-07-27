// PTG Module: ptg_finale — Finale stitching, try_ladder, explore_stitch, guide_add_cell, cell_rescue
// Extracted from l4d_path_to_goal.inc (backup)

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
