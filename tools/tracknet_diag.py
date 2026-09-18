#!/usr/bin/env python3
"""TrackNet 离线诊断 + 弹道链验证。

- 跑 mlpackage，每帧提取所有 >0.5 的 blob（候选缓存到 json，重跑跳过推理）
- 弹道多假设链：保留每帧多候选，挑连成平滑轨迹的那条（丢掉杆头孤点）
- 渲染：黄=所有候选，红=每帧最大面积（端侧当前选它），绿线=链选中的球迹

用法: python3 tracknet_diag.py <video> [out_dir] [impact_frame]
"""
import cv2, sys, os, json, numpy as np
import coremltools as ct

W, H, SEQ, INCH = 512, 288, 8, 27
MODEL = "/Users/soda/Swi-app/Models/TrackNet.mlpackage"


def blobs(heat):
    mask = (heat > 0.5).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    out = []
    for i in range(1, n):
        x, y, w, h, _ = stats[i]
        out.append([float(x + w / 2) / W, float(y + h / 2) / H, int(w * h),
                    float(heat[lab == i].max())])
    return out


def compute_candidates(vid, cache):
    if os.path.exists(cache):
        d = json.load(open(cache))
        return d["per_frame"], d["times"], d["size"]
    cap = cv2.VideoCapture(vid)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    small, times = [], []
    while True:
        ok, im = cap.read()
        if not ok:
            break
        small.append(cv2.cvtColor(cv2.resize(im, (W, H)), cv2.COLOR_BGR2RGB).astype(np.float32))
        times.append(len(times) / fps)
    cap.release()
    n = len(small)
    med = np.median(np.stack(small[::max(1, n // 9)]), axis=0)
    tcn = ct.models.MLModel(MODEL)
    starts = list(range(0, n - SEQ + 1, SEQ))
    if starts and starts[-1] + SEQ < n:
        starts.append(n - SEQ)
    per_frame = [[] for _ in range(n)]
    for s in starts:
        arr = np.zeros((1, INCH, H, W), np.float32)
        arr[0, 0:3] = np.transpose(med, (2, 0, 1)) / 255
        for f in range(SEQ):
            arr[0, 3 + f * 3:6 + f * 3] = np.transpose(small[s + f], (2, 0, 1)) / 255
        heat = tcn.predict({"frames": arr})["heatmap"][0]
        for f in range(SEQ):
            per_frame[s + f] = blobs(heat[f])
    json.dump({"per_frame": per_frame, "times": times, "size": [W, H]}, open(cache, "w"))
    return per_frame, times, [W, H]


def chain_ball(per_frame):
    """弹道贪心链：挑连成平滑轨迹的那条，杆头孤点因步长/连不上被丢。"""
    chains = []
    for i, bs in enumerate(per_frame):
        for cx, cy, a, p in bs:
            best = None
            for ch in chains:
                li, lx, ly = ch[-1]
                dt = i - li
                if dt <= 0 or dt > 5:
                    continue
                step = np.hypot(cx - lx, cy - ly) / dt
                if step < 0.14 and (best is None or step < best[1]):
                    best = (ch, step)
            (best[0].append([i, cx, cy]) if best else chains.append([[i, cx, cy]]))
    disp = lambda c: np.hypot(c[-1][1] - c[0][1], c[-1][2] - c[0][2])
    # 必须弹道运动：净位移够大 → 排除静止假阳性(全分辨率 TrackNet 会死钉背景物)
    chains = [c for c in chains if len(c) >= 3 and disp(c) > 0.12]
    if not chains:
        return []
    # 飞行球:位移大 + 链长。位移优先(静止链已被上面滤掉)
    chains.sort(key=lambda c: (disp(c), len(c)), reverse=True)
    return chains[0]


def anchor_z(vid, fy):
    """返回 (anchorZ, groundY_norm)。anchorZ = fy·1.62/躯干跨度（身体尺子，
    对齐 VideoAnalyzer）；groundY = 踝的图像 y（地平面 = 球员脚下）。swipose-n。"""
    try:
        from ultralytics import YOLO
        pm = YOLO("/Users/soda/Downloads/swipose-n.pt")
        cap = cv2.VideoCapture(vid)
        H = cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 1280
        W = cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 720
        spans, grounds, ankxs = [], [], []
        for _ in range(60):
            ok, im = cap.read()
            if not ok:
                break
            r = pm.predict(im, imgsz=320, verbose=False, device="cpu")[0]
            if r.keypoints is None or len(r.keypoints) == 0:
                continue
            k = r.keypoints.data[0].cpu().numpy()
            ys = [p[1] for p in k if p[2] > 0.35]
            if ys and max(ys) - min(ys) > 0.15 * H:
                spans.append(max(ys) - min(ys))
            ankj = [j for j in (15, 16) if k[j, 2] > 0.35]
            if ankj:
                grounds.append(max(k[j, 1] for j in ankj) / H)
                ankxs.append(np.mean([k[j, 0] for j in ankj]) / W)
        cap.release()
        az = float(fy * 1.62 / np.median(spans)) if spans else 2.5
        gy = float(np.median(grounds)) if grounds else 0.9
        gx = float(np.median(ankxs)) if ankxs else 0.5
        return az, gy, gx
    except Exception as e:
        print("anchor_z 失败, 用默认:", e)
        return 2.5, 0.9, 0.5


def pose_tee(vid, frame_idx, W, H):
    """pose 锚定 tee：架球/触球帧的 腕中点x + 踝地面y（swipose-n，golf 蒸馏）。
    不依赖杆头/夜间静止球。返回 (u,v) 像素 或 None。"""
    try:
        from ultralytics import YOLO
        m = YOLO("/Users/soda/Downloads/swipose-n.pt")
        cap = cv2.VideoCapture(vid)
        cap.set(cv2.CAP_PROP_POS_FRAMES, max(0, frame_idx))
        ok, im = cap.read(); cap.release()
        if not ok:
            return None
        r = m.predict(im, imgsz=320, verbose=False, device="cpu")[0]
        if r.keypoints is None or len(r.keypoints) == 0:
            return None
        k = r.keypoints.data[0].cpu().numpy()
        lw, rw = k[9], k[10]
        ws = [w for w in (lw, rw) if w[2] > 0.3]
        wx = np.mean([w[0] for w in ws]) if ws else (lw[0] + rw[0]) / 2
        ank = max(k[15, 1], k[16, 1])                       # 双踝最低 = 地面
        print(f"pose-tee f{frame_idx}: wristX {wx/W:.3f}, ankleY {ank/H:.3f}")
        return (float(wx), float(ank))
    except Exception as e:
        print("pose-tee 失败:", e); return None


def impact_gate(track, impact):
    """丢掉 impact 之前的半空点——球在 impact 前不可能在飞，那些点是杆身拖影
    （TrackNet 对高速模糊照样 fire）。它们高度几乎不变 → vy≈0 → 反投除零。
    实测 314c3679(1264×720 夜间)：含杆身 vy=-0.0017/帧 → back=-83帧 →
    tee x=-7229px；剔除后 vy=-0.0764 → back=-3.6帧 → tee x=811px，真球 802px。
    链首若已在地面(=address 球，和飞行段同一物体)则保留，它就是 tee。"""
    if impact is None:
        return track
    keep = [p for p in track if p[0] >= impact]
    dropped = len(track) - len(keep)
    if dropped:
        print(f"impact 门(f{impact}): 丢掉 {dropped} 个 pre-impact 点(杆身) → {len(keep)} 点")
    return keep if len(keep) >= 3 else track


def predict_track(track, W, H, vid, tee_frame):
    """用 BallFlightSolver 3D 引擎。拟合用平地重力，投影用 GeoCalib 俯仰重力
    （否则落点提早下落，栽向前景）。返回 (投影弧[(i,cx,cy)], (speed,launch,carry))。"""
    import ballflight as bf
    import geocalib as gc
    if len(track) < 5:
        return [], None
    # GeoCalib：焦距 + 俯仰（对齐 VideoAnalyzer 的 imported 路径）
    focal, pitch = H * 0.72, 0.0
    try:
        r = gc.calibrate(tee_frame, W, H)
        if r:
            _, pitch, focal = r
            print(f"GeoCalib: pitch {np.degrees(pitch):.1f}°, focal {focal:.0f}")
    except Exception as e:
        print("GeoCalib 失败, 用默认:", e)
    fx = fy = focal
    cam = bf.Camera(fx, fy, W / 2, H / 2, gravity=(0, 1, 0))                 # 拟合：平地重力
    camF = bf.Camera(fx, fy, W / 2, H / 2,
                     gravity=(0, np.cos(pitch), np.sin(pitch)))             # 投影：俯仰重力
    az, groundY, groundX = anchor_z(vid, fy)   # 身体尺子 + 脚点(地平面上一点)
    # 剔除 receding 平台尾点（球往里飞，图像位移趋零、无 3D 信息、主导拟合）
    fit_track = list(track)
    steps = [np.hypot(track[k + 1][1] - track[k][1], track[k + 1][2] - track[k][2])
             for k in range(len(track) - 1)]
    if len(steps) >= 4:
        thr = max(0.008, 0.35 * np.median(steps))
        cut, low = len(track), 0
        for k, s in enumerate(steps):
            low = low + 1 if s < thr else 0
            if low >= 2:
                cut = k; break
        if 4 <= cut < len(track):
            fit_track = track[:cut]
            print(f"平台剔除: {len(track)} → {len(fit_track)} 帧拟合")
    i0 = fit_track[0][0]
    obs = [(cx * W, cy * H, (i - i0) / 30.0) for i, cx, cy in fit_track]
    # tee：链首若已在地面附近（TrackNet 抓到 mat 球，V1）→ 直接用；
    # 若在半空/远处（V2 链从飞行中起）→ 飞行线反投到地平面（球员脚下球座）。
    # 两种都让 tee 落在球员脚下深度 → pose 尺子的 anchorZ 成立。
    p0n, p1n = fit_track[0], fit_track[1]
    if p0n[2] >= groundY - 0.05:                # 链首已在地面 → 就是 mat 球
        tee = (p0n[1] * W, p0n[2] * H)
        print(f"tee = 链首(已在地面) ({p0n[1]:.3f},{p0n[2]:.3f})  anchorZ {az:.1f}m")
    else:
        dx = p1n[1] - p0n[1]
        vx = dx / (p1n[0] - p0n[0] + 1e-6)
        vy = (p1n[2] - p0n[2]) / (p1n[0] - p0n[0] + 1e-6)
        back = (groundY - p0n[2]) / (vy if abs(vy) > 1e-4 else -1e-4)
        teeX = p0n[1] + vx * back
        tee = (teeX * W, groundY * H)
        print(f"tee 反投地平面 → ({teeX:.3f},{groundY:.3f})  anchorZ {az:.1f}m")
    # 地面 tee 深度试过：与身体尺子同源(pose+身高)，没引入新信息，V1 反而变差、
    # V2 一样 → 回退用身体尺子。绝对尺度 ±20% 是不用杆头/帧率的物理下限。
    st = bf.solve_bounded_state(obs, cam, az, tee=tee)
    if st is None:
        print("引擎: 拟合失败"); return [], None
    sp, la, carry, err = bf.metrics(st, camF)
    cl = bf.cl_for_launch(la)
    # 合理性边界:超界的解不可信
    plausible = (20 <= sp <= 80) and (6 <= la <= 35) and (10 <= carry <= 320)
    receding = len(fit_track) < len(track) - 2          # 平台剔除掉很多 = 球往里飞
    # 置信度:拟合残差 + 点数 + 是否 receding + 是否越界
    conf = "high"
    if err > 14 or len(fit_track) < 5 or not plausible:
        conf = "low"
    elif receding:
        conf = "mid"                                    # 方向可靠，尺度存疑
    band = 0.20 if conf == "high" else (0.35 if conf == "mid" else 0.6)
    print(f"引擎: {sp:.0f} m/s, 发射 {la:.0f}°, Cl {cl}, carry {carry:.0f} m "
          f"[{carry*(1-band):.0f}–{carry*(1+band):.0f}], err {err:.1f}px, "
          f"置信 {conf}{'(receding:只可靠方向)' if receding else ''}")
    path = bf.projected_flight(st, camF)                                    # 用俯仰投影
    return [[int(round(i0 + t * 30)), u / W, v / H] for u, v, t in path], (sp, la, carry, conf, band)


def main():
    vid = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "tracknet_diag_out"
    # 端上 impact 由 PoseTCN 给（很干净）；这里是诊断工具，没跑 PoseTCN，
    # 所以第 3 个参数手给。不给则不设门，等同旧行为。
    impact = int(sys.argv[3]) if len(sys.argv) > 3 else None
    os.makedirs(f"{out}/frames", exist_ok=True)
    per_frame, times, _ = compute_candidates(vid, f"{out}/cands.json")
    track = chain_ball(per_frame)
    print(f"链选中球迹 {len(track)} 点: " + " ".join(f"f{i}({cx:.2f},{cy:.2f})" for i, cx, cy in track))
    track = impact_gate(track, impact)

    cap = cv2.VideoCapture(vid)
    raw = []
    while True:
        ok, im = cap.read()
        if not ok:
            break
        raw.append(im)
    cap.release()
    oh, ow = raw[0].shape[:2]
    tee_frame = raw[track[0][0]] if track else raw[0]  # 架球帧给 GeoCalib
    pred, info = predict_track(track, ow, oh, vid, tee_frame)   # BallFlightSolver + GeoCalib 俯仰
    tset = {i: (cx, cy) for i, cx, cy in track}
    vw = cv2.VideoWriter(f"{out}/overlay.mp4", cv2.VideoWriter_fourcc(*"avc1"), 10, (ow, oh))
    for i in range(len(raw)):
        im = raw[i].copy()
        for rank, (cx, cy, area, peak) in enumerate(sorted(per_frame[i], key=lambda b: -b[2])):
            px, py = int(cx * ow), int(cy * oh)
            col = (0, 0, 255) if rank == 0 else (0, 255, 255)
            cv2.circle(im, (px, py), 10, col, 2)
        # 绿线：链选中的球迹（到当前帧为止）
        pts = [(int(cx * ow), int(cy * oh)) for j, cx, cy in track if j <= i]
        for k in range(1, len(pts)):
            cv2.line(im, pts[k - 1], pts[k], (0, 255, 0), 2)
        if i in tset:
            cv2.circle(im, (int(tset[i][0] * ow), int(tset[i][1] * oh)), 7, (0, 255, 0), -1)
        # 橙线：BallFlightSolver 3D 投影弧（物理弧，随帧画出）
        pp = [(int(cx * ow), int(cy * oh)) for j, cx, cy in pred if j <= i]
        for k in range(1, len(pp)):
            cv2.line(im, pp[k - 1], pp[k], (0, 140, 255), 3)
        if info:
            sp, la, ca, conf, band = info
            txt = (f"{sp:.0f}m/s {la:.0f}deg  carry {ca*(1-band):.0f}-{ca*(1+band):.0f}m ({conf})"
                   if conf != "low" else f"{la:.0f}deg dir-only (low conf)")
            col = (0, 200, 0) if conf == "high" else ((0, 200, 255) if conf == "mid" else (0, 120, 255))
            cv2.putText(im, txt, (10, oh - 20), cv2.FONT_HERSHEY_SIMPLEX, 0.65, col, 2)
        cv2.putText(im, f"f{i}", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
        vw.write(im)
    vw.release()
    print(f"overlay → {out}/overlay.mp4")


if __name__ == "__main__":
    main()
