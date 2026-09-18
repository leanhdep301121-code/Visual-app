#!/usr/bin/env python3
"""自动标注飞行球(运动法,无需逐帧人眼/LLM)。

思路(利用 DTL 先验):飞行球在画面里近竖直上升(cx~常数、cy 单调减、步长有界)。
- 3 帧差分(bitwise_and 两个相邻 absdiff)把球定位在中间帧,压掉拖影;
- 候选:小面积亮 blob;
- 弹道链:贪心连成"cy 递减、cx 抖动小、最长"的链,杆头/背景孤点被丢;
- 方向门:选中链必须净上升 >= MIN_RISE 且 cx 展开 < MAX_XSPREAD,否则判该 clip 无可信球;
- address 球:把飞行链线性反推回起飞点,在 impact 帧放 1 个静止球(链干净时)。

输出:staging json(含新 ball + 原 club) + 每 clip 一张 montage + 文本诊断。
用法: python3 ball_autolabel.py            # 跑全部 30 个非 1eefda clip
       python3 ball_autolabel.py <clip前缀> # 只跑匹配的
"""
import cv2, os, sys, json, glob
import numpy as np

VID_DIR = "/Users/soda/Swi-app/tools/annotator/videos"
ANN_DIR = "/Users/soda/Downloads/annotation"
OUT_DIR = "/private/tmp/claude-501/-Users-soda-Swi-app-Annotation/a70428f0-f5e9-4b81-8741-ff7e1c8e8d25/scratchpad/ball_auto"
STAGE = os.path.join(OUT_DIR, "json")
MONT = os.path.join(OUT_DIR, "montage")

# 检测参数
PRE, POST = 2, 17          # 窗口: impact-PRE .. impact+POST
AREA_MIN, AREA_MAX = 3, 900
MAX_STEP = 0.16            # 相邻帧最大归一位移(链约束)
MAX_DX_STEP = 0.05        # 相邻帧最大水平位移(DTL 近竖直)
MIN_RISE = 0.14           # 选中链净上升(cy 减少)阈值
MAX_XSPREAD = 0.18        # 选中链 cx 展开上限
MIN_CHAIN = 4             # 最短可信链帧数
TOPN = 6                  # 每帧保留候选数


def read_gray_color(vid, a, b):
    cap = cv2.VideoCapture(vid)
    cap.set(cv2.CAP_PROP_POS_FRAMES, max(0, a))
    grays, colors, idxs = [], [], []
    i = max(0, a)
    while i <= b:
        ok, im = cap.read()
        if not ok:
            break
        g = cv2.GaussianBlur(cv2.cvtColor(im, cv2.COLOR_BGR2GRAY), (3, 3), 0)
        grays.append(g); colors.append(im); idxs.append(i); i += 1
    cap.release()
    return idxs, grays, colors


def candidates(grays, W, H):
    """3 帧差分,返回 per (中间帧局部下标) 的候选 [cx,cy,area,peak]。"""
    per = [[] for _ in grays]
    for k in range(1, len(grays) - 1):
        d1 = cv2.absdiff(grays[k], grays[k - 1])
        d2 = cv2.absdiff(grays[k + 1], grays[k])
        # 自适应阈值:噪声地板之上
        t1 = max(12, int(d1.mean() + 3 * d1.std()))
        t2 = max(12, int(d2.mean() + 3 * d2.std()))
        m = cv2.bitwise_and((d1 > t1).astype(np.uint8), (d2 > t2).astype(np.uint8))
        m = cv2.dilate(m, np.ones((3, 3), np.uint8), 1)
        n, lab, stats, cent = cv2.connectedComponentsWithStats(m, 8)
        cand = []
        for i in range(1, n):
            x, y, w, h, area = stats[i]
            if not (AREA_MIN <= area <= AREA_MAX):
                continue
            if max(w, h) > 40 or min(w, h) < 1:   # 太长条 = 杆/拖影
                continue
            if w > 3 * h or h > 3 * w:
                continue
            cx, cy = cent[i]
            peak = float(d1[lab == i].max())
            cand.append([cx / W, cy / H, int(area), peak])
        cand.sort(key=lambda c: -c[3])
        per[k] = cand[:TOPN]
    return per


def chain(per, imp_local):
    """贪心弹道链,DTL 方向先验:飞行球只升不降(cy 非增)、cx 抖动小。
    imp_local: impact 帧在 per 里的局部下标;只从 impact-1 起链(飞行段)。"""
    chains = []
    for i, bs in enumerate(per):
        if i < imp_local - 1:          # 只在飞行段找链(丢掉下杆club下降)
            continue
        for cx, cy, a, p in bs:
            best = None
            for ch in chains:
                li, lx, ly = ch[-1][:3]
                dt = i - li
                if dt <= 0 or dt > 3:
                    continue
                dx = abs(cx - lx); dy = cy - ly
                step = np.hypot(cx - lx, cy - ly) / dt
                if step > MAX_STEP or dx > MAX_DX_STEP * dt:
                    continue
                if dy > 0.02 * dt:      # 飞行球不下降(允许微抖)
                    continue
                score = step + 5 * dx   # 偏好小步、小水平抖
                if best is None or score < best[1]:
                    best = (ch, score)
            if best:
                best[0].append([i, cx, cy, a])
            else:
                chains.append([[i, cx, cy, a]])
    chains = [c for c in chains if len(c) >= MIN_CHAIN]
    if not chains:
        return None
    def rise(c):
        return c[0][2] - c[-1][2]
    def xspread(c):
        xs = [p[1] for p in c]
        return max(xs) - min(xs)
    ok = [c for c in chains if rise(c) >= MIN_RISE and xspread(c) <= MAX_XSPREAD]
    if not ok:
        return None
    ok.sort(key=lambda c: (len(c), rise(c)), reverse=True)
    return trim_outliers(ok[0])


def photometric_ok(ch, grays, a, W, H):
    """光度门:真飞行球是平滑背景(天空)上的高对比亮点。
    对每点在原灰度帧取环形邻域:背景应低纹理(ring_std 小)且中心有对比。
    杆/身/地(纹理杂)被拒。返回 (通过, ball_like 比例)。"""
    good = 0
    for k, cx, cy, ar in ch:
        g = grays[k]
        px, py = int(cx * W), int(cy * H)
        r_out, r_in = 22, 12
        y0, y1 = max(0, py - r_out), min(H, py + r_out)
        x0, x1 = max(0, px - r_out), min(W, px + r_out)
        patch = g[y0:y1, x0:x1].astype(np.float32)
        if patch.size < 100:
            continue
        yy, xx = np.mgrid[y0:y1, x0:x1]
        d = np.hypot(xx - px, yy - py)
        ring = patch[(d >= r_in) & (d <= r_out)]
        center = patch[d <= 4]
        if ring.size < 20 or center.size < 1:
            continue
        ring_std = float(ring.std())
        contrast = abs(float(center.mean()) - float(ring.mean()))
        if ring_std < 26 and contrast > 16:      # 平滑背景 + 可见对比 = 球
            good += 1
    frac = good / max(1, len(ch))
    return (good >= MIN_CHAIN and frac >= 0.55), frac


def trim_outliers(ch):
    """DTL 球近竖直:锁定主导 cx 竖线(最长的 cx 相近连续段),
    只留贴着这条竖线的点,砍掉起手身体/杆的偏离点。"""
    n = len(ch)
    BAND = 0.035
    # 找最长的 cx 相近连续段(以每个点 cx 为参照)
    best = (0, 0, ch[0][1])
    for i in range(n):
        ref = ch[i][1]
        j = i
        while j < n and abs(ch[j][1] - ref) <= BAND:
            j += 1
        if j - i > best[0]:
            best = (j - i, i, float(np.median([ch[k][1] for k in range(i, j)])))
    ref = best[2]
    kept = [p for p in ch if abs(p[1] - ref) <= 0.05]
    return kept if len(kept) >= MIN_CHAIN else ch


def process(vid, meta_path, ann_path):
    meta = json.load(open(meta_path))
    imp = meta["events"].get("impact")
    nfr = meta["frames"]; W = meta["width"]; H = meta["height"]
    if imp is None:
        return {"clip": os.path.basename(vid), "status": "no-impact"}
    a = max(0, imp - PRE); b = min(nfr - 1, imp + POST)
    idxs, grays, colors = read_gray_color(vid, a, b)
    if len(grays) < 5:
        return {"clip": os.path.basename(vid), "status": "too-short"}
    per = candidates(grays, W, H)
    ch = chain(per, imp - a)
    photo_frac = None
    if ch is not None:
        ok_photo, photo_frac = photometric_ok(ch, grays, a, W, H)
        if not ok_photo and not os.environ.get("BALL_NOGATE"):
            ch = None
    ann = json.load(open(ann_path))
    by_idx = {f["index"]: f for f in ann["frames"]}
    side = 26.0
    bw, bh = side / W, side / H

    result = {"clip": os.path.basename(vid), "impact": imp, "window": [a, b],
              "photo_frac": round(photo_frac, 2) if photo_frac is not None else None}
    ball_frames = []
    if ch is None:
        result["status"] = "no-ball"
    else:
        # 局部下标 -> 全局帧号 = a + k
        pts = [(a + k, cx, cy) for k, cx, cy, ar in ch]
        # 只保留 impact 起(飞行段),丢掉 impact 之前的杂点
        pts = [(fi, cx, cy) for fi, cx, cy in pts if fi >= imp - 1]
        for fi, cx, cy in pts:
            f = by_idx.get(fi)
            box = {"cls": "ball", "cx": round(float(cx), 4), "cy": round(float(cy), 4),
                   "w": round(bw, 4), "h": round(bh, 4)}
            if f is None:
                f = {"index": fi, "boxes": [box]}
                ann["frames"].append(f); by_idx[fi] = f
            else:
                f["boxes"] = [x for x in f["boxes"] if x["cls"] != "ball"] + [box]
            ball_frames.append((fi, round(float(cx), 3), round(float(cy), 3)))
        # 不做 address 反推(无法核对,易错;只留可见的飞行球,保精度)
        result["status"] = "ok"
        result["ball_frames"] = ball_frames
        ann["frames"].sort(key=lambda f: f["index"])
        os.makedirs(STAGE, exist_ok=True)
        json.dump(ann, open(os.path.join(STAGE, os.path.basename(ann_path)), "w"),
                  ensure_ascii=False, indent=1)

    # montage: 窗口内每帧小图,画上 ball 框
    make_montage(os.path.basename(vid), idxs, colors, ann if ch else None, W, H)
    return result


def make_montage(name, idxs, colors, ann, W, H):
    os.makedirs(MONT, exist_ok=True)
    ball_map = {}
    if ann:
        for f in ann["frames"]:
            for bx in f["boxes"]:
                if bx["cls"] == "ball":
                    ball_map[f["index"]] = bx
    thumbs = []
    tw = 220
    for fi, im in zip(idxs, colors):
        th = int(tw * im.shape[0] / im.shape[1])
        small = cv2.resize(im, (tw, th))
        if fi in ball_map:
            bx = ball_map[fi]
            px, py = int(bx["cx"] * tw), int(bx["cy"] * th)
            cv2.circle(small, (px, py), 8, (0, 0, 255), 2)
        cv2.putText(small, f"f{fi}", (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
        thumbs.append(small)
    if not thumbs:
        return
    cols = 5
    rows = (len(thumbs) + cols - 1) // cols
    th = thumbs[0].shape[0]
    grid = np.zeros((rows * th, cols * tw, 3), np.uint8)
    for i, t in enumerate(thumbs):
        r, c = divmod(i, cols)
        grid[r * th:(r + 1) * th, c * tw:(c + 1) * tw] = t
    cv2.imwrite(os.path.join(MONT, name + ".png"), grid)


def main():
    filt = sys.argv[1] if len(sys.argv) > 1 else ""
    vids = sorted(glob.glob(os.path.join(VID_DIR, "*.mp4")))
    vids = [v for v in vids if not os.path.basename(v).startswith("1eefda")]
    if filt:
        vids = [v for v in vids if filt in os.path.basename(v)]
    results = []
    for v in vids:
        base = os.path.basename(v)
        meta = v[:-4] + ".meta.json"
        ann = os.path.join(ANN_DIR, base + ".json")
        if not (os.path.exists(meta) and os.path.exists(ann)):
            results.append({"clip": base, "status": "missing-meta-or-ann"}); continue
        try:
            results.append(process(v, meta, ann))
        except Exception as e:
            results.append({"clip": base, "status": "error", "err": str(e)})
    # 汇总
    print(json.dumps(results, ensure_ascii=False, indent=1))
    ok = sum(1 for r in results if r.get("status") == "ok")
    nob = sum(1 for r in results if r.get("status") == "no-ball")
    print(f"\n== {ok} clip 标到球, {nob} clip 无可信球, 共 {len(results)} ==")
    print(f"staging json -> {STAGE}\nmontage -> {MONT}")


if __name__ == "__main__":
    main()
