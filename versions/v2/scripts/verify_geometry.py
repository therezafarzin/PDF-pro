#!/usr/bin/env python3
"""Independent check of the rotation math used by PageGeometry (Sources/Core/Geometry.swift).
Rotates a real raster-like grid clockwise and confirms the formulas place points where an
actual 90-degree clockwise rotation of the page image would."""
import itertools, sys
W, H = 600.0, 800.0
def to_p(x, y): return (x, H - y)                      # page (y-up) -> P-space (y-down)
def p_to_display(u, v, rot):
    a,b,c,d,tx,ty = {0:(1,0,0,1,0,0), 90:(0,1,-1,0,H,0), 180:(-1,0,0,-1,W,H), 270:(0,-1,1,0,0,W)}[rot]
    return (a*u + c*v + tx, b*u + d*v + ty)
def truth(u, v, rot):
    cw, ch = W, H
    for _ in range(rot // 90):
        u, v = ch - v, u          # clockwise 90 on a cw x ch image
        cw, ch = ch, cw
    return u, v
fails = 0
for rot in (0, 90, 180, 270):
    for (x, y) in [(0,0),(W,H),(100,700),(300,400),(W,0),(0,H)]:
        u, v = to_p(x, y)
        got = p_to_display(u, v, rot); want = truth(u, v, rot)
        ok = abs(got[0]-want[0]) < 1e-9 and abs(got[1]-want[1]) < 1e-9
        if not ok: fails += 1; print("FAIL", rot, (x,y), got, want)
    # inverse round trip
    a,b,c,d,tx,ty = {0:(1,0,0,1,0,0), 90:(0,1,-1,0,H,0), 180:(-1,0,0,-1,W,H), 270:(0,-1,1,0,0,W)}[rot]
    det = a*d - b*c
    for (u,v) in [(10,20),(500,700)]:
        X, Y = p_to_display(u, v, rot)
        # inverse affine
        ia, ib, ic, id_ = d/det, -b/det, -c/det, a/det
        itx = -(ia*tx + ic*ty); ity = -(ib*tx + id_*ty)
        u2, v2 = ia*X + ic*Y + itx, ib*X + id_*Y + ity
        if abs(u2-u) > 1e-9 or abs(v2-v) > 1e-9: fails += 1; print("FAIL inverse", rot)
print("geometry mirror checks:", "ALL PASS" if not fails else f"{fails} FAILURES"); sys.exit(1 if fails else 0)
