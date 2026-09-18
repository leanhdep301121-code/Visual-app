#!/usr/bin/env python3
"""全分辨率 TrackNet:不缩全图,把画面切成 512x288 原生 tile,每个 tile 喂 8 帧
时序 → 保住小球像素 + 保住 TrackNet 运动检测。tile 结果映射回全图,弹道链挑飞行球。
用法: python3 tracknet_tiled.py <video> [out_dir]"""
import cv2, sys, os, numpy as np
import coremltools as ct
import tracknet_diag as td   # 复用 chain_ball

TW, TH, SEQ, INCH = 512, 288, 8, 27
MODEL = "/Users/soda/Swi-app/Models/TrackNet.mlpackage"


def blobs(heat):
    mask = (heat > 0.5).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    out = []
    for i in range(1, n):
        x, y, w, h, _ = stats[i]
        out.append((x + w / 2, y + h / 2, int(w * h), float(heat[lab == i].max())))
    return out


def main():
    vid = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "tn_tiled_out"
    fr = []
    cap = cv2.VideoCapture(vid)
    while True:
        ok, im = cap.read()
        if not ok: break
        fr.append(im)
    cap.release()
    H, W = fr[0].shape[:2]
    N = len(fr)
    print(f"帧 {N}, {W}x{H}, 原生 tile {TW}x{TH}")

    # 全分辨率中位背景(子采样)
    med = np.median(np.stack(fr[::max(1, N // 9)]), axis=0)

    # tile 网格(50% 重叠),覆盖上 70%(球走廊),跳过最底部球员
    xs = list(range(0, max(1, W - TW) + 1, TW // 2)) or [0]
    if xs[-1] != W - TW: xs.append(max(0, W - TW))
    ys = list(range(0, int(H * 0.70) - TH + 1, TH // 2)) or [0]
    print(f"tile 网格 {len(xs)}x{len(ys)} = {len(xs)*len(ys)} 个/窗口")

    import json
    cache = os.path.join("/private/tmp", "s005_tntiled_cands.json")
    if os.path.exists(cache):
        per_frame = json.load(open(cache))
        print("(用缓存候选)")
    else:
        tcn = ct.models.MLModel(MODEL)
        def rgbf(img, x, y):
            c = img[y:y+TH, x:x+TW]
            return cv2.cvtColor(c, cv2.COLOR_BGR2RGB).astype(np.float32) / 255
        per_frame = [[] for _ in range(N)]
        starts = list(range(0, N - SEQ + 1, SEQ))
        if starts and starts[-1] + SEQ < N: starts.append(N - SEQ)
        for s in starts:
            for tx in xs:
                for ty in ys:
                    arr = np.zeros((1, INCH, TH, TW), np.float32)
                    arr[0, 0:3] = np.transpose(rgbf(med.astype(np.uint8), tx, ty), (2, 0, 1))
                    for f in range(SEQ):
                        arr[0, 3+f*3:6+f*3] = np.transpose(rgbf(fr[s+f], tx, ty), (2, 0, 1))
                    heat = tcn.predict({"frames": arr})["heatmap"][0]
                    for f in range(SEQ):
                        for bx, by, a, p in blobs(heat[f]):
                            per_frame[s+f].append([(tx+bx)/W, (ty+by)/H, a, p])
        json.dump(per_frame, open(cache, "w"))
    for i in range(N):
        if per_frame[i]:
            print(f"  f{i}: "+" ".join(f"({b[0]:.2f},{b[1]:.2f} p{b[3]:.2f})" for b in sorted(per_frame[i],key=lambda z:-z[3])[:6]))

    track = td.chain_ball(per_frame)
    print("\n弹道链选中飞行球:", " ".join(f"f{i}({x:.2f},{y:.2f})" for i, x, y in track))

    os.makedirs("/Users/soda/Downloads/tn_diag", exist_ok=True)
    vw = cv2.VideoWriter("/Users/soda/Downloads/tn_diag/s005_tntiled.mp4",
                         cv2.VideoWriter_fourcc(*"avc1"), 6, (W, H))
    tset = {i: (x, y) for i, x, y in track}
    for i in range(N):
        im = fr[i].copy()
        for b in per_frame[i]:
            cv2.circle(im, (int(b[0]*W), int(b[1]*H)), 12, (0, 255, 255), 2)
        pts = [(int(x*W), int(y*H)) for k, x, y in track if k <= i]
        for a in range(1, len(pts)): cv2.line(im, pts[a-1], pts[a], (0, 0, 255), 3)
        if i in tset: cv2.circle(im, (int(tset[i][0]*W), int(tset[i][1]*H)), 16, (0, 255, 0), -1)
        cv2.putText(im, f"f{i}", (20, 50), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (255, 255, 255), 3)
        vw.write(im)
    vw.release(); print("→ ~/Downloads/tn_diag/s005_tntiled.mp4")


if __name__ == "__main__":
    main()
