script "lib_raycast"
######################################################################################
## lib_raycast (LIB_RAYCAST, 11 23 2026): a GRID RAYCASTER in plain xTalk, drawn as vectors.
##
## In memory of Scott McDonald (The LiveCode Lab), whose LiveCode raycaster (public domain,
## written for LiveCode 6.1.3, after Andrew Burch's Corona engine and the permadi.com and
## lodev.org tutorials) showed the trick this library keeps: rays that hit the same wall are
## joined into ONE polygon, so a frame is a few dozen polygons, not hundreds of strips.
##
## What is new here:
##   - lodev's DDA walk (one cell boundary a step) instead of separate horizontal/vertical rays
##   - walls in the same plane are joined across cells (a corridor wall is one face, the Lean idea)
##   - face edges are exact: a wall's real corner is projected, not rounded to a ray column, and
##     each face says which of its two ends are real corners (for outline drawing)
##   - a depth for every column, to clip sprites behind walls (Ray.Visible, Ray.ClipX)
##   - a floor grid in perspective (Ray.FloorGrid) for the Vibecode3D look
##   - wall sliding for movement (Ray.Move) and line of sight (Ray.Sees)
##
## The map is a text grid: one line a row, one character a cell. Characters in the solid set
## (Ray.SetSolid, default "#") are walls; anything else is open. The world is in CELLS: cell
## (col,row) covers x col-1..col, y row-1..row (x east along a row, y south down the rows).
## Angles in degrees, 0 = east, 90 = south (the map's y runs down).
##
##   Ray.SetMap pText             the grid
##   Ray.SetSolid pChars          which characters stop rays and feet
##   Ray.SetCell pCol,pRow,pChar  change one cell (a door opening)
##   Ray.Cell(pCol,pRow)          the character there (empty off the map)
##   Ray.SolidAt(pX,pY)           is the world point inside a wall
##   Ray.Camera pX,pY,pAngle,pFOV,pW,pH,pColumns,pEye   cast the view (pEye 0..1, the eye's height)
##   Ray.Faces()                  the faces of the last Ray.Camera, far first, one a line:
##        depth|xL|xR|topL|botL|topR|botR|char|realL|realR|side|col,row
##        (screen pixels from the view's top left; depth = the face's nearest perpendicular distance)
##   Ray.Project(pX,pY,pZ)        screen x,y,depth of a world point (pZ 0 floor, 1 ceiling), empty behind
##   Ray.Scale(pDepth)            pixels a cell is tall at that depth
##   Ray.DepthAt(pSX)             the wall's depth at a screen x
##   Ray.Visible(pXL,pXR,pDepth)  the widest span of pXL..pXR where nothing nearer stands: "xl,xr" or empty
##   Ray.ClipX(pPoints,pXL,pXR)   a closed polygon's points cut to a vertical band
##   Ray.FloorGrid(pRadius)       the floor's cell lines near the camera, as line-graphic points
##   Ray.Cast(pX,pY,pAngle,pMax)  the first wall along a ray: "dist,col,row,side,char" or empty
##   Ray.Sees(pX1,pY1,pX2,pY2)    true when no wall stands between the two points
##   Ray.Move @pX,@pY,pDX,pDY,pR  walk a circle of radius pR, sliding along walls
##   Ray.Stats()                  columns, faces, steps of the last frame
## Test: LIB_RAYCAST/tests/lc_raycast_test.txt (OXT-BEYOND/tests/oxt_headless.py).
######################################################################################

local sRow, sCols, sRows, sSolid
local sPX, sPY, sDX, sDY, sPLX, sPLY, sK, sW, sH, sCols2, sColW, sFocal, sHor, sEye
local sDepth, sFaces, sSteps

constant kFar = 64          -- cells a ray may walk
constant kNear = 0.02       -- nearest depth a face is drawn at

---------------------------------------------------------------- the map

command Ray.SetMap pText
   local tLine, tR
   put empty into sRow
   put 0 into sCols
   put 0 into tR
   replace numToChar(13) with empty in pText
   repeat for each line tLine in pText
      add 1 to tR
      put tLine into sRow[tR]
      put max(sCols, the number of chars of tLine) into sCols
   end repeat
   put tR into sRows
   if sSolid is empty then put "#" into sSolid
end Ray.SetMap

command Ray.SetSolid pChars
   put pChars into sSolid
end Ray.SetSolid

function Ray.Solid
   return sSolid
end Ray.Solid

command Ray.SetCell pCol, pRow, pChar
   if pRow < 1 or pRow > sRows or pCol < 1 then exit Ray.SetCell
   repeat while the number of chars of sRow[pRow] < pCol
      put space after sRow[pRow]
   end repeat
   put pChar into char pCol of sRow[pRow]
end Ray.SetCell

function Ray.Cell pCol, pRow
   if pRow < 1 or pRow > sRows or pCol < 1 or pCol > sCols then return empty
   return char pCol of sRow[pRow]
end Ray.Cell

function Ray.Size
   return sCols & comma & sRows
end Ray.Size

-- off the map counts as solid, so nothing walks or looks out of it
function Ray.SolidCell pCol, pRow
   local tCh
   if pRow < 1 or pRow > sRows or pCol < 1 or pCol > sCols then return true
   put char pCol of sRow[pRow] into tCh
   if tCh is empty or tCh is space then return false
   return (tCh is in sSolid)
end Ray.SolidCell

function Ray.SolidAt pX, pY
   return Ray.SolidCell(trunc(pX) + 1, trunc(pY) + 1)
end Ray.SolidAt

---------------------------------------------------------------- one ray

-- the DDA walk from (pX,pY) along (pRX,pRY); answers "dist,col,row,side,char" (dist along the ray
-- in units of its length, the perpendicular depth when the ray is dir + plane * cameraX)
function Ray.Walk pX, pY, pRX, pRY, pMax
   local tMX, tMY, tDDX, tDDY, tSX, tSY, tStepX, tStepY, tSide, tN, tCh, tDist
   put trunc(pX) into tMX
   put trunc(pY) into tMY
   if pRX = 0 then
      put 1e30 into tDDX
   else
      put abs(1 / pRX) into tDDX
   end if
   if pRY = 0 then
      put 1e30 into tDDY
   else
      put abs(1 / pRY) into tDDY
   end if
   if pRX < 0 then
      put -1 into tStepX
      put (pX - tMX) * tDDX into tSX
   else
      put 1 into tStepX
      put (tMX + 1 - pX) * tDDX into tSX
   end if
   if pRY < 0 then
      put -1 into tStepY
      put (pY - tMY) * tDDY into tSY
   else
      put 1 into tStepY
      put (tMY + 1 - pY) * tDDY into tSY
   end if
   put 0 into tN
   repeat
      if tSX < tSY then
         add tDDX to tSX
         add tStepX to tMX
         put 0 into tSide
      else
         add tDDY to tSY
         add tStepY to tMY
         put 1 into tSide
      end if
      add 1 to tN
      if tMY < 0 or tMY >= sRows or tMX < 0 or tMX >= sCols then
         put "#" into tCh
         exit repeat
      end if
      put char tMX + 1 of sRow[tMY + 1] into tCh
      if tCh is not empty and tCh is not space and tCh is in sSolid then exit repeat
      if tN > pMax then return empty
   end repeat
   add tN to sSteps
   if tSide = 0 then
      put tSX - tDDX into tDist
   else
      put tSY - tDDY into tDist
   end if
   return tDist & comma & (tMX + 1) & comma & (tMY + 1) & comma & tSide & comma & tCh
end Ray.Walk

function Ray.Cast pX, pY, pAngle, pMax
   local tA
   if pMax is not a number then put kFar into pMax
   put pAngle * pi / 180 into tA
   return Ray.Walk(pX, pY, cos(tA), sin(tA), pMax)
end Ray.Cast

function Ray.Sees pX1, pY1, pX2, pY2
   local tDX, tDY, tLen, tHit
   put pX2 - pX1 into tDX
   put pY2 - pY1 into tDY
   put sqrt(tDX * tDX + tDY * tDY) into tLen
   if tLen < 0.001 then return true
   put Ray.Walk(pX1, pY1, tDX / tLen, tDY / tLen, trunc(tLen) + 2) into tHit
   if tHit is empty then return true
   return (item 1 of tHit >= tLen)
end Ray.Sees

---------------------------------------------------------------- the view

-- pW,pH the view in pixels; pColumns rays across it (fewer = faster, the edges stay exact)
command Ray.Camera pX, pY, pAngle, pFOV, pW, pH, pColumns, pEye
   local tA, tI, tCX, tRX, tRY, tHit, tKey, tRun, tPrevKey, tA2, tN
   if pFOV is not a number then put 66 into pFOV
   if pColumns is not a number then put 160 into pColumns
   if pEye is not a number then put 0.5 into pEye
   put pX into sPX
   put pY into sPY
   put pAngle * pi / 180 into tA
   put cos(tA) into sDX
   put sin(tA) into sDY
   put tan(pFOV * pi / 360) into sK
   put -sDY * sK into sPLX
   put sDX * sK into sPLY
   put pW into sW
   put pH into sH
   put pColumns into sCols2
   put pW / pColumns into sColW
   put (pW / 2) / sK into sFocal
   put pH / 2 into sHor
   put pEye into sEye
   put 0 into sSteps
   put empty into sDepth
   put empty into sFaces
   put empty into tRun
   put empty into tPrevKey
   put 0 into tN
   repeat with tI = 0 to pColumns - 1
      put 2 * (tI + 0.5) / pColumns - 1 into tCX
      put sDX + sPLX * tCX into tRX
      put sDY + sPLY * tCX into tRY
      put Ray.Walk(pX, pY, tRX, tRY, kFar) into tHit
      if tHit is empty then
         put 1e9 into sDepth[tI]
         if tRun is not empty then
            Ray.CloseRun tRun
            put empty into tRun
         end if
         put empty into tPrevKey
         next repeat
      end if
      put max(kNear, item 1 of tHit) into sDepth[tI]
      -- the face's plane: side, the plane's coordinate, the character
      if item 4 of tHit = 0 then
         if tRX > 0 then
            put item 2 of tHit - 1 into tA2
         else
            put item 2 of tHit into tA2
         end if
         put "0:" & tA2 & ":" & item 5 of tHit & ":" & Ray.Sgn(tRX) into tKey
         put item 3 of tHit into tA2           -- the cell along the face (its row)
      else
         if tRY > 0 then
            put item 3 of tHit - 1 into tA2
         else
            put item 3 of tHit into tA2
         end if
         put "1:" & tA2 & ":" & item 5 of tHit & ":" & Ray.Sgn(tRY) into tKey
         put item 2 of tHit into tA2           -- the cell along the face (its column)
      end if
      if tKey is tPrevKey and abs(tA2 - tRun["last"]) <= 1 then
         put tI into tRun["i1"]
         put min(tRun["amin"], tA2) into tRun["amin"]
         put max(tRun["amax"], tA2) into tRun["amax"]
         put tA2 into tRun["last"]
         put min(tRun["depth"], item 1 of tHit) into tRun["depth"]
      else
         if tRun is not empty then Ray.CloseRun tRun
         put empty into tRun
         put tKey into tRun["key"]
         put tI into tRun["i0"]
         put tI into tRun["i1"]
         put tA2 into tRun["amin"]
         put tA2 into tRun["amax"]
         put tA2 into tRun["last"]
         put item 1 of tHit into tRun["depth"]
         put item 2 of tHit & comma & item 3 of tHit into tRun["cell"]
         put tKey into tPrevKey
      end if
   end repeat
   if tRun is not empty then Ray.CloseRun tRun
   set the itemDelimiter to "|"
   sort lines of sFaces numeric descending by item 1 of each
end Ray.Camera

private function Ray.Sgn pN
   if pN < 0 then return -1
   return 1
end Ray.Sgn

-- a run of columns on one plane becomes one face with exact ends
private command Ray.CloseRun pRun
   local tSide, tPlane, tCh, tDir, tXL, tXR, tE1, tE2, tS1, tS2, tLo, tHi, tRealL, tRealR
   local tTL, tBL, tTR, tBR, tDL, tDR, tLoEnd, tHiEnd
   set the itemDelimiter to ":"
   put item 1 of pRun["key"] into tSide
   put item 2 of pRun["key"] into tPlane
   put item 3 of pRun["key"] into tCh
   put item 4 of pRun["key"] into tDir
   set the itemDelimiter to comma
   put pRun["i0"] * sColW into tXL
   put (pRun["i1"] + 1) * sColW into tXR
   -- the face's two ends in the world, and where they land on the screen
   if tSide = 0 then
      put Ray.ScreenX(tPlane, pRun["amin"] - 1) into tS1
      put Ray.ScreenX(tPlane, pRun["amax"]) into tS2
   else
      put Ray.ScreenX(pRun["amin"] - 1, tPlane) into tS1
      put Ray.ScreenX(pRun["amax"], tPlane) into tS2
   end if
   -- which end is a real corner: the wall does not go on in the same plane past it
   -- an end behind the eye has no screen x: the face runs off the screen on that side, and the end
   -- that can be seen is the edge nearer to it (23 Nov fix: the owner saw a wall close on the right
   -- vanish at 1-15 degrees of turn, because that end was taken as the wrong edge)
   if tS1 is empty or tS2 is empty then
      if tS1 is empty then
         put tS2 into tS1
         put "max" into tLoEnd
      else
         put "min" into tLoEnd
      end if
      put empty into tS2
      if tS1 is not empty and (tS1 - tXL) <= (tXR - tS1) then
         put tS1 into tLo
         put empty into tHi
         put tLoEnd into tHiEnd
      else
         put empty into tLo
         put tS1 into tHi
         put tLoEnd into tHiEnd
      end if
   else if tS1 <= tS2 then
      put tS1 into tLo
      put tS2 into tHi
      put "min" into tLoEnd
      put "max" into tHiEnd
   else
      put tS2 into tLo
      put tS1 into tHi
      put "max" into tLoEnd
      put "min" into tHiEnd
   end if
   put false into tRealL
   put false into tRealR
   if tLo is a number and tLo >= tXL - 0.5 and tLo <= tXR then
      put tLo into tXL
      put Ray.EndIsCorner(tSide, tPlane, tCh, tDir, pRun, tLoEnd) into tRealL
   else
      put max(0, tXL - sColW) into tXL        -- behind something nearer: overlap, the nearer covers it
   end if
   if tHi is a number and tHi <= tXR + 0.5 and tHi >= tXL then
      put tHi into tXR
      put Ray.EndIsCorner(tSide, tPlane, tCh, tDir, pRun, tHiEnd) into tRealR
   else
      put min(sW, tXR + sColW) into tXR
   end if
   put Ray.PlaneDepth(tSide, tPlane, tXL) into tDL
   put Ray.PlaneDepth(tSide, tPlane, tXR) into tDR
   put round(sHor - sFocal * (1 - sEye) / tDL, 1) into tTL
   put round(sHor + sFocal * sEye / tDL, 1) into tBL
   put round(sHor - sFocal * (1 - sEye) / tDR, 1) into tTR
   put round(sHor + sFocal * sEye / tDR, 1) into tBR
   put min(tDL, tDR) & "|" & round(tXL, 1) & "|" & round(tXR, 1) & "|" & tTL & "|" & tBL & "|" & tTR & "|" & tBR & "|" & tCh & "|" & tRealL & "|" & tRealR & "|" & tSide & "|" & pRun["cell"] & return after sFaces
end Ray.CloseRun

-- the screen x of a floor point (empty when it is behind the eye)
private function Ray.ScreenX pX, pY
   local tRX, tRY, tDepth, tLat
   put pX - sPX into tRX
   put pY - sPY into tRY
   put tRX * sDX + tRY * sDY into tDepth
   if tDepth < kNear then return empty
   put (tRX * sPLX + tRY * sPLY) / (sK * sK) into tLat
   return (tLat / tDepth + 1) * sW / 2
end Ray.ScreenX

-- depth of a face's plane under screen x
private function Ray.PlaneDepth pSide, pPlane, pSX
   local tCX, tRX, tRY, tT
   put 2 * pSX / sW - 1 into tCX
   put sDX + sPLX * tCX into tRX
   put sDY + sPLY * tCX into tRY
   if pSide = 0 then
      if abs(tRX) < 1e-9 then return 1e9
      put (pPlane - sPX) / tRX into tT
   else
      if abs(tRY) < 1e-9 then return 1e9
      put (pPlane - sPY) / tRY into tT
   end if
   return max(kNear, tT)
end Ray.PlaneDepth

-- does the wall stop at this end (a corner), or run on in the same plane, hidden?
private function Ray.EndIsCorner pSide, pPlane, pCh, pDir, pRun, pEnd
   local tA, tWall, tFront
   if pEnd is "min" then
      put pRun["amin"] - 1 into tA
   else
      put pRun["amax"] + 1 into tA
   end if
   -- the wall's cells are on the far side of the plane (seen along pDir), the open ones in front
   if pDir > 0 then
      put pPlane + 1 into tWall
      put pPlane into tFront
   else
      put pPlane into tWall
      put pPlane + 1 into tFront
   end if
   if pSide = 0 then
      return not (Ray.Cell(tWall, tA) is pCh and not Ray.SolidCell(tFront, tA))
   end if
   return not (Ray.Cell(tA, tWall) is pCh and not Ray.SolidCell(tA, tFront))
end Ray.EndIsCorner

function Ray.Faces
   return sFaces
end Ray.Faces

function Ray.Stats
   return sCols2 & " columns, " & the number of lines of sFaces & " faces, " & sSteps & " steps"
end Ray.Stats

---------------------------------------------------------------- things in the view

-- screen x,y and depth of a world point; pZ 0 = floor, 1 = ceiling
function Ray.Project pX, pY, pZ
   local tRX, tRY, tDepth, tLat
   put pX - sPX into tRX
   put pY - sPY into tRY
   put tRX * sDX + tRY * sDY into tDepth
   if tDepth < 0.05 then return empty
   put (tRX * sPLX + tRY * sPLY) / (sK * sK) into tLat
   return round((tLat / tDepth + 1) * sW / 2, 1) & comma & round(sHor + sFocal * (sEye - pZ) / tDepth, 1) & comma & tDepth
end Ray.Project

function Ray.Scale pDepth
   if pDepth < kNear then put kNear into pDepth
   return sFocal / pDepth
end Ray.Scale

function Ray.DepthAt pSX
   local tI
   put trunc(pSX / sColW) into tI
   if tI < 0 or tI >= sCols2 then return 0
   return sDepth[tI]
end Ray.DepthAt

-- the widest stretch of pXL..pXR where the walls stand farther than pDepth
function Ray.Visible pXL, pXR, pDepth
   local tI, tI0, tI1, tStart, tBest, tBestW, tX0, tX1
   put max(0, trunc(pXL / sColW)) into tI0
   put min(sCols2 - 1, trunc(pXR / sColW)) into tI1
   if tI1 < tI0 then return empty
   put empty into tStart
   put empty into tBest
   put -1 into tBestW
   repeat with tI = tI0 to tI1 + 1
      if tI <= tI1 and sDepth[tI] > pDepth then
         if tStart is empty then
            put tI into tStart
         end if
      else if tStart is not empty then
         if tI - tStart > tBestW then
            put tI - tStart into tBestW
            put tStart & comma & (tI - 1) into tBest
         end if
         put empty into tStart
      end if
   end repeat
   if tBest is empty then return empty
   put max(pXL, item 1 of tBest * sColW) into tX0
   put min(pXR, (item 2 of tBest + 1) * sColW) into tX1
   if tX1 <= tX0 then return empty
   return round(tX0, 1) & comma & round(tX1, 1)
end Ray.Visible

-- a closed polygon (points, one "x,y" a line) cut to pXL <= x <= pXR (Sutherland-Hodgman, two edges)
function Ray.ClipX pPoints, pXL, pXR
   local tOut
   put Ray.ClipEdge(pPoints, pXL, 1) into tOut
   put Ray.ClipEdge(tOut, pXR, -1) into tOut
   return tOut
end Ray.ClipX

private function Ray.ClipEdge pPoints, pX, pKeep
   local tOut, tPrev, tP, tInP, tIn, tT, tY, tLast
   repeat for each line tP in pPoints
      if tP is not empty then put tP into tLast
   end repeat
   if tLast is empty then return empty
   put tLast into tPrev
   put (pKeep * (item 1 of tPrev - pX) >= 0) into tInP
   repeat for each line tP in pPoints
      if tP is empty then next repeat
      put (pKeep * (item 1 of tP - pX) >= 0) into tIn
      if tIn is not tInP then
         put (pX - item 1 of tPrev) / (item 1 of tP - item 1 of tPrev) into tT
         put item 2 of tPrev + tT * (item 2 of tP - item 2 of tPrev) into tY
         put round(pX, 1) & comma & round(tY, 1) & return after tOut
      end if
      if tIn then put tP & return after tOut
      put tP into tPrev
      put tIn into tInP
   end repeat
   return tOut
end Ray.ClipEdge

-- the floor's cell lines within pRadius cells, cut at the eye, as points for one line graphic
-- (an empty line between segments)
function Ray.FloorGrid pRadius
   local tOut, tN, tX0, tX1, tY0, tY1, tSeg
   if pRadius is not a number then put 6 into pRadius
   put max(0, trunc(sPX - pRadius)) into tX0
   put min(sCols, trunc(sPX + pRadius) + 1) into tX1
   put max(0, trunc(sPY - pRadius)) into tY0
   put min(sRows, trunc(sPY + pRadius) + 1) into tY1
   repeat with tN = tX0 to tX1
      put Ray.FloorSeg(tN, tY0, tN, tY1) into tSeg
      if tSeg is not empty then put tSeg & return & return after tOut
   end repeat
   repeat with tN = tY0 to tY1
      put Ray.FloorSeg(tX0, tN, tX1, tN) into tSeg
      if tSeg is not empty then put tSeg & return & return after tOut
   end repeat
   return tOut
end Ray.FloorGrid

-- one floor segment cut at the near plane, as two screen points
private function Ray.FloorSeg pX1, pY1, pX2, pY2
   local tD1, tD2, tT, tNear, tA, tB
   put 0.1 into tNear
   put (pX1 - sPX) * sDX + (pY1 - sPY) * sDY into tD1
   put (pX2 - sPX) * sDX + (pY2 - sPY) * sDY into tD2
   if tD1 < tNear and tD2 < tNear then return empty
   if tD1 < tNear then
      put (tNear - tD1) / (tD2 - tD1) into tT
      put pX1 + (pX2 - pX1) * tT into pX1
      put pY1 + (pY2 - pY1) * tT into pY1
   else if tD2 < tNear then
      put (tNear - tD2) / (tD1 - tD2) into tT
      put pX2 + (pX1 - pX2) * tT into pX2
      put pY2 + (pY1 - pY2) * tT into pY2
   end if
   put Ray.Project(pX1, pY1, 0) into tA
   put Ray.Project(pX2, pY2, 0) into tB
   if tA is empty or tB is empty then return empty
   return item 1 to 2 of tA & return & item 1 to 2 of tB
end Ray.FloorSeg

---------------------------------------------------------------- moving

-- move a circle of radius pR by (pDX,pDY): each axis on its own, so it slides along walls
command Ray.Move @pX, @pY, pDX, pDY, pR
   local tNX, tNY
   if pR is not a number then put 0.25 into pR
   put pX + pDX into tNX
   if not Ray.CircleHits(tNX, pY, pR) then put tNX into pX
   put pY + pDY into tNY
   if not Ray.CircleHits(pX, tNY, pR) then put tNY into pY
end Ray.Move

function Ray.CircleHits pX, pY, pR
   if Ray.SolidAt(pX - pR, pY - pR) then return true
   if Ray.SolidAt(pX + pR, pY - pR) then return true
   if Ray.SolidAt(pX - pR, pY + pR) then return true
   if Ray.SolidAt(pX + pR, pY + pR) then return true
   return false
end Ray.CircleHits
