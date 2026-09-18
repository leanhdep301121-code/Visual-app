#!/usr/bin/env python3
"""白天球轨迹过滤器:全分辨率运动候选 → 多假设链 → 选最平滑的抛物线链(=球)。

夜间球清晰 TrackNet 直接能追;白天球飞进杂乱球场,帧差候选噪声多。核心:
1. pose 框出球员(排除杆头+身体运动)+ 遮网带；
2. 全分辨率帧差 → 球大小的小 blob 全留作候选（不做单峰）；
3. 多假设链（每帧步长合理）；
4. 选择：对每条链拟合 x(t)、y(t) 二次，取"够长 + 残差最小"的 = 平滑弹道 = 球。
   跳变噪声连不成平滑抛物线，残差大被淘汰。

用法: python3 daytime_ball_filter.py <video> [impact_frame] [out.mp4]
"""
import cv2, sys, os, numpy as np

# 固定掩码(球场走廊)：排球员/网/近地。生产版应改成 pose 框球员，这里验证过滤逻辑。
# (x0,x1,y0,y1) 归一化，保留区
KEEP = (0.40, 1.00, 0.12, 0.60)


def main():
    vid = sys.argv[1]
    cap = cv2.VideoCapture(vid)
    fr = []
    while True:
        ok, im = cap.read()
        if not ok:
            break
        fr.append(im)
    cap.release()
    H, W = fr[0].shape[:2]
    N = len(fr)
    impact = int(sys.argv[2]) if len(sys.argv) > 2 else N // 2
    lo, hi = max(1, impact - 2), min(N, impact + 22)   # 飞行窗口

    # 每帧候选（球大小小 blob，固定掩码只留球场走廊）
    per_frame = {}
    kx0, kx1, ky0, ky1 = int(KEEP[0] * W), int(KEEP[1] * W), int(KEEP[2] * H), int(KEEP[3] * H)
    for i in range(lo, hi):
        d = cv2.absdiff(fr[i], fr[i - 1]).mean(2)
        keep = np.zeros_like(d); keep[ky0:ky1, kx0:kx1] = d[ky0:ky1, kx0:kx1]
        d = keep
        mask = (cv2.GaussianBlur(d, (0, 0), 1.2) > 16).astype(np.uint8)
        n, lab, stats, cent = cv2.connectedComponentsWithStats(mask, 8)
        cands = [(cent[c][0] / W, cent[c][1] / H)
                 for c in range(1, n) if 3 <= stats[c, 4] <= 150]
        per_frame[i] = cands

    # 多假设链
    chains = []
    for i in sorted(per_frame):
        for (x, y) in per_frame[i]:
            best = None
            for ch in chains:
                li, lx, ly = ch[-1]
                dt = i - li
                if dt <= 0 or dt > 3:
                    continue
                step = np.hypot(x - lx, y - ly) / dt
                if step < 0.06 and (best is None or step < best[1]):
                    best = (ch, step)
            (best[0].append((i, x, y)) if best else chains.append([(i, x, y)]))

    # 选：够长 + 二次拟合残差最小 + 有位移
    def score(ch):
        if len(ch) < 5:
            return None
        I = np.array([p[0] for p in ch], float)
        X = np.array([p[1] for p in ch]); Y = np.array([p[2] for p in ch])
        rx = np.polyfit(I, X, 2); ry = np.polyfit(I, Y, 2)
        res = np.sqrt(np.mean((np.polyval(rx, I) - X) ** 2 + (np.polyval(ry, I) - Y) ** 2))
        disp = np.hypot(X[-1] - X[0], Y[-1] - Y[0])
        if disp < 0.08:
            return None
        return res
    scored = [(score(c), c) for c in chains]
    scored = [(s, c) for s, c in scored if s is not None]
    if not scored:
        print("没找到平滑弹道链"); return
    scored.sort(key=lambda t: (t[0] / max(len(t[1]), 1)))   # 残差/长度 越小越好
    track = scored[0][1]
    # 链内离群剔除:拟合抛物线,丢掉偏离平滑弧的单点(那个下探的"V"点)
    for _ in range(2):
        if len(track) < 6:
            break
        I = np.array([p[0] for p in track], float)
        X = np.array([p[1] for p in track]); Y = np.array([p[2] for p in track])
        rx = np.polyfit(I, X, 2); ry = np.polyfit(I, Y, 2)
        resid = np.hypot(np.polyval(rx, I) - X, np.polyval(ry, I) - Y)
        thr = max(0.018, 2.5 * np.median(resid))
        kept = [track[k] for k in range(len(track)) if resid[k] < thr]
        if len(kept) == len(track):
            break
        track = kept
    print(f"选中球迹 {len(track)} 点 (残差 {scored[0][0]:.4f}):",
          " ".join(f"f{i}({x:.2f},{y:.2f})" for i, x, y in track))

    out = sys.argv[3] if len(sys.argv) > 3 else "/Users/soda/Downloads/tn_diag/daytime_ball.mp4"
    vw = cv2.VideoWriter(out, cv2.VideoWriter_fourcc(*"avc1"), 6, (W, H))
    tset = {i: (x, y) for i, x, y in track}
    for i in range(lo, hi):
        im = fr[i].copy()
        for (x, y) in per_frame.get(i, []):
            cv2.circle(im, (int(x * W), int(y * H)), 10, (0, 255, 255), 2)   # 黄=候选
        pts = [(int(x * W), int(y * H)) for k, x, y in track if k <= i]
        for a in range(1, len(pts)):
            cv2.line(im, pts[a - 1], pts[a], (0, 0, 255), 4)
        if i in tset:
            cv2.circle(im, (int(tset[i][0] * W), int(tset[i][1] * H)), 16, (0, 255, 0), -1)
        cv2.putText(im, f"f{i}", (20, 50), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (255, 255, 255), 3)
        vw.write(im)
    vw.release()
    print("→", out)


if __name__ == "__main__":
    main()
