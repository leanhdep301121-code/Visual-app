#!/usr/bin/env python3
"""放大核对:对每个 ball 检测,裁 detection 周围一小块放大平铺,肉眼确认是否真有球。
用法: python3 ball_verify_crop.py <clip前缀>"""
import cv2, os, sys, json, glob
import numpy as np

VID_DIR = "/Users/soda/Swi-app/tools/annotator/videos"
STAGE = "/private/tmp/claude-501/-Users-soda-Swi-app-Annotation/a70428f0-f5e9-4b81-8741-ff7e1c8e8d25/scratchpad/ball_auto/json"
OUT = "/private/tmp/claude-501/-Users-soda-Swi-app-Annotation/a70428f0-f5e9-4b81-8741-ff7e1c8e8d25/scratchpad/ball_auto/crops"

CROP = 70   # 原图裁剪半径(像素)
ZOOM = 3

filt = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
for jp in sorted(glob.glob(STAGE + f"/*{filt}*.json")):
    d = json.load(open(jp))
    name = d["video"]
    balls = sorted((f["index"], b["cx"], b["cy"]) for f in d["frames"] for b in f["boxes"] if b["cls"] == "ball")
    if not balls:
        continue
    vid = os.path.join(VID_DIR, name)
    cap = cv2.VideoCapture(vid)
    W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    tiles = []
    for fi, cx, cy in balls:
        cap.set(cv2.CAP_PROP_POS_FRAMES, fi)
        ok, im = cap.read()
        if not ok:
            continue
        px, py = int(cx * W), int(cy * H)
        x0, y0 = max(0, px - CROP), max(0, py - CROP)
        x1, y1 = min(W, px + CROP), min(H, py + CROP)
        crop = im[y0:y1, x0:x1]
        crop = cv2.resize(crop, (crop.shape[1] * ZOOM, crop.shape[0] * ZOOM), interpolation=cv2.INTER_NEAREST)
        # 画准星:检测中心
        ccx, ccy = (px - x0) * ZOOM, (py - y0) * ZOOM
        cv2.line(crop, (ccx - 12, ccy), (ccx - 4, ccy), (0, 0, 255), 1)
        cv2.line(crop, (ccx + 4, ccy), (ccx + 12, ccy), (0, 0, 255), 1)
        cv2.line(crop, (ccx, ccy - 12), (ccx, ccy - 4), (0, 0, 255), 1)
        cv2.line(crop, (ccx, ccy + 4), (ccx, ccy + 12), (0, 0, 255), 1)
        cv2.putText(crop, f"f{fi}", (3, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
        tiles.append(crop)
    cap.release()
    if not tiles:
        continue
    tw = tiles[0].shape[1]; th = max(t.shape[0] for t in tiles)
    cols = 6
    rows = (len(tiles) + cols - 1) // cols
    grid = np.zeros((rows * th, cols * tw, 3), np.uint8)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        grid[r * th:r * th + t.shape[0], c * tw:c * tw + t.shape[1]] = t
    out = os.path.join(OUT, name + ".crop.png")
    cv2.imwrite(out, grid)
    print("wrote", out, f"({len(tiles)} tiles)")
