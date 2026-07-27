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

#include <sourcemod>
#include <left4dhooks>
#include <dhooks>
#include <gvazdas_navmesh_utils>

// ────────────────────────────────────────────────────────────────────
// Modular includes — split by responsibility domain.
// Order matters: types first (globals), then utilities, then features.
// ────────────────────────────────────────────────────────────────────

// 1. Types + global state (~275 lines)
//    All structs, enums, ConnectionType, PlayerCaps, global variables.
#include "ptg/ptg_types.inc"

// 2. Utilities — physics, nav mesh, geometry (~680 lines)
//    TryHull, GetNavConnections, valid_ground, ValidateJumpArc, etc.
#include "ptg/ptg_utils.inc"

// 3. A* engine — pathfinding kernel (~1930 lines)
//    Heuristic, EdgeCost, SearchFrame, portals, HPA*, non-mesh detection,
//    bridge detection, Funnel3D smoothing, ReconstructPath.
#include "ptg/ptg_astar.inc"

// 4. Validation — hull trace validation + auto-repair + beacons (~460 lines)
//    Guide_ValidateWalkable, Guide_RepairBlocked, Guide_DrawBeacons.
#include "ptg/ptg_validate.inc"

// 5. Guide system — beam drawing + client request handling (~850 lines)
//    RequestGuide, detour_join, DrawBeam, client request timers.
#include "ptg/ptg_guide.inc"

// 6. Finale — finale/rescue vehicle stitching (~760 lines)
//    try_ladder, stitch_finale, explore_stitch, guide_add_cell, cell_rescue.
#include "ptg/ptg_finale.inc"

// 7. Pipeline — stage orchestration (~570 lines)
//    Guide_Prep, OnFramePrep, Check_Guidable, Guide_Cleanup.
#include "ptg/ptg_pipeline.inc"

// 8. SDK — detour hooks + RecomputeFlowDistances (~50 lines)
//    LoadSDK, Hook_RecomputeFlowPost.
#include "ptg/ptg_sdk.inc"
