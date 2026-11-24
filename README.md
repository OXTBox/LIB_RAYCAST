# LIB_RAYCAST

A grid raycaster in plain xTalk, drawn as vectors (polygons and lines, no pixels).

**In memory of Scott McDonald** (The LiveCode Lab). His LiveCode raycaster, which he dedicated
to the public domain, joined the rays that hit one wall into one polygon. This library keeps that
idea. It gave the first walls and the first map of the game that uses it.

- `livecode/lib_raycast.livecodescript`: the library (`Ray.*`); the API is in its header.
- `tests/lc_raycast_test.txt`: headless checks (`OXT-BEYOND/tests/oxt_headless.py`).
- First game: LIB_GAMES `Vibecode3D_Play_CorridorLab` (level 1 is Scott's own map).

Engine: none of its own. It is maths that answers polygons and depths; the game draws them.
That works over Engine 1 (Vibecode3D, pure xTalk) and over the xRay bench picture.

Sources of the method: Scott McDonald's raycaster for LiveCode 6.1.3 (after Andrew Burch's
Corona raycasting engine), permadi.com's raycasting tutorial, lodev.org's DDA tutorial.

## Licence

GPL-3.0 (see `LICENSE`), because the xTalk work here is built on the GPL-licensed LiveCode Community 9 engine. Copyright (c) 2026 xAction.
Scott McDonald's raycaster, whose method this library follows, was dedicated by him to the public domain.
