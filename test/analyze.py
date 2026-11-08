#!/usr/bin/env python3
"""连接中继, 抓取 N 秒实时帧做质量分析:
分辨率/帧率/单帧大小/红像素统计/红点聚类, 并保存一张标注样图
用法: python3 analyze.py [ws地址] [秒数默认4]"""
import asyncio, io, sys, time
import numpy as np
from PIL import Image, ImageDraw
import websockets

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:8900/stream?role=viewer"
SECS = float(sys.argv[2] if len(sys.argv) > 2 else 4)

# 与网页面板一致的检测参数
R_MIN, G_MAX, B_MAX, CELL, MIN_CNT, SCALE = 140, 90, 90, 16, 6, 0.4

def analyze(img: Image.Image):
    w, h = img.size
    small = img.resize((max(64, int(w*SCALE)), max(36, int(h*SCALE))))
    a = np.asarray(small)
    r, g, b = a[...,0].astype(int), a[...,1].astype(int), a[...,2].astype(int)
    red_mask = (r >= R_MIN) & (g <= G_MAX) & (b <= B_MAX)
    n_red = int(red_mask.sum())
    # 网格聚类
    sw, sh = small.size
    cw, ch = sw // CELL + 1, sh // CELL + 1
    grid = np.zeros((ch, cw), int)
    ys, xs = np.where(red_mask)
    if len(xs):
        np.add.at(grid, (ys // CELL, xs // CELL), 1)
    cells = set(map(tuple, np.argwhere(grid >= MIN_CNT)))
    seen, clusters = set(), []
    for c0 in cells:
        if c0 in seen: continue
        q, seen = [c0], seen | {c0}
        pts = []
        while q:
            cur = q.pop(); pts.append(cur)
            cy, cx = cur
            for dy in (-1,0,1):
                for dx in (-1,0,1):
                    nb = (cy+dy, cx+dx)
                    if nb in cells and nb not in seen:
                        seen.add(nb); q.append(nb)
        clusters.append(pts)
    return n_red, clusters, small

async def main():
    frames = []
    t0 = time.time()
    async with websockets.connect(URL, max_size=8*1024*1024,
                                  ping_interval=None, ping_timeout=None) as ws:
        while time.time() - t0 < SECS and len(frames) < 150:
            data = await asyncio.wait_for(ws.recv(), timeout=2)
            if isinstance(data, (bytes, bytearray)):
                frames.append((time.time(), bytes(data)))
    if not frames:
        print("没有收到任何帧, 检查 A 机推流是否开启"); return
    dt = frames[-1][0] - frames[0][0]
    sizes = [len(d) for _, d in frames]
    reds, clu_cnts, last = [], [], None
    for _, d in frames:
        img = Image.open(io.BytesIO(d)).convert("RGB")
        nr, clusters, small = analyze(img)
        reds.append(nr); clu_cnts.append(len(clusters)); last = (img, clusters, small)
    print(f"帧数 {len(frames)}  |  时长 {dt:.1f}s  |  实际 {len(frames)/dt:.1f} fps")
    print(f"分辨率 {frames and Image.open(io.BytesIO(frames[0][1])).size}  |  单帧 {np.mean(sizes)/1024:.0f} KB ({min(sizes)/1024:.0f}-{max(sizes)/1024:.0f})")
    print(f"红像素/帧: 平均 {np.mean(reds):.0f}, 范围 {min(reds)}-{max(reds)}")
    print(f"红点聚类数/帧: 平均 {np.mean(clu_cnts):.1f}, 最多 {max(clu_cnts)}")
    # 保存标注样图
    img, clusters, small = last
    d = ImageDraw.Draw(img)
    sx, sy = img.width / small.width, img.height / small.height
    for pts in clusters:
        cy = np.mean([p[0] for p in pts]); cx = np.mean([p[1] for p in pts])
        rad = max(10, np.sqrt(len(pts)) * CELL * sx * 0.6)
        x, y = cx * CELL * sx, cy * CELL * sy
        d.ellipse([x-rad, y-rad, x+rad, y+rad], outline=(255,59,48), width=6)
    out = "/sdcard/Download/DSH-Go/delta_sample.png"
    import os
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    print(f"标注样图已存: {out}")

asyncio.run(main())
