#!/usr/bin/env python3
"""模拟 A 机推流端：
合成一张对局画面(暗色地图 + 移动红点敌人 + 绿色血条 + 噪声)，
按 30fps 压缩成 JPEG，通过 WS 推给中继服务。
有 cv2 且给了视频文件参数时，改为推真实视频帧(方便测试真实画面)。

用法:
  python3 streamer.py [ws://127.0.0.1:8900/stream?role=streamer] [视频文件(可选)]
"""
import asyncio, json, math, os, sys, time
from io import BytesIO

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:8900/stream?role=streamer"
VIDEO = sys.argv[2] if len(sys.argv) > 2 else None

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import websockets

W, H = 960, 540
JPEG_Q = 55
FPS = 30

def synth_frame(t: float) -> Image.Image:
    """模拟三角洲对局画面: 左上小地图红点 + 视野内敌人红标 + 血条 + 噪声"""
    img = Image.new("RGB", (W, H), (18, 26, 22))
    d = ImageDraw.Draw(img)
    # 地面纹理噪声
    noise = (np.random.rand(H // 4, W // 4, 3) * 22).astype(np.uint8)
    img.paste(Image.fromarray(noise, "RGB").resize((W, H)), (0, 0))
    # 小地图框(左上)
    d.rectangle([16, 16, 216, 216], outline=(120, 140, 120), width=3)
    # 敌人红点: 3个, 圆周运动
    for i in range(3):
        a = t * (0.5 + 0.2 * i) + i * 2.1
        x = 116 + int(70 * math.cos(a))
        y = 116 + int(70 * math.sin(a))
        d.ellipse([x - 6, y - 6, x + 6, y + 6], fill=(235, 40, 30))
    # 视野内敌人红标(玩家头顶): 一个稳定 + 一个横向移动
    for i in range(2):
        x = 420 + i * 260 + int(60 * math.sin(t * 1.3 + i))
        y = 200 + i * 80
        d.ellipse([x - 5, y - 5, x + 5, y + 5], fill=(230, 45, 30))
        d.text((x - 14, y - 24), "ID_%d" % (100 + i), fill=(255, 255, 255))
    # 血条(绿色) + 弹药数字
    d.rectangle([40, 470, 240, 490], outline=(60, 60, 60), width=2)
    hp_w = int(198 * (0.5 + 0.5 * math.sin(t * 0.7)))
    d.rectangle([41, 471, 41 + hp_w, 489], fill=(60, 200, 70))
    d.text((250, 466), "HP %d  30/45" % int(hp_w / 198 * 100), fill=(220, 255, 220))
    return img

async def main():
    use_cv2 = False
    cap = None
    if VIDEO:
        try:
            import cv2
            cap = cv2.VideoCapture(VIDEO)
            use_cv2 = cap.isOpened()
        except ImportError:
            print("[!] 未装 cv2，回退合成画面 (pip install opencv-python-headless)")
    print(f"[streamer] 推流地址 {URL}  {'视频源:' + VIDEO if use_cv2 else '合成画面'}")
    while True:  # 断线自动重连(手机休眠/网络抖动不中断)
        try:
            # ping_interval=None: 关掉保活超时, 避免休眠后误判断线
            async with websockets.connect(URL, max_size=8 * 1024 * 1024,
                                          ping_interval=None, ping_timeout=None) as ws:
                await push_loop(ws, cap, use_cv2)
        except Exception as e:
            print(f"[streamer] 连接断开: {type(e).__name__}, 3秒后重连...")
            await asyncio.sleep(3)

async def push_loop(ws, cap, use_cv2):
    t0 = time.time(); n = 0
    interval = 1.0 / FPS
    while True:
        t = time.time() - t0
        if use_cv2:
            ok, frame = cap.read()
            if not ok:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0); continue
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            img = Image.fromarray(rgb)
        else:
            img = synth_frame(t)
        buf = BytesIO()
        img.save(buf, "JPEG", quality=JPEG_Q)
        await ws.send(buf.getvalue())
        n += 1
        if n % 150 == 0:
            print(f"[streamer] 已推 {n} 帧, 平均 {n/(t+1e-9):.1f} fps")
        await asyncio.sleep(max(0, interval - (time.time() - (t0 + n * interval))))

if __name__ == "__main__":
    asyncio.run(main())
