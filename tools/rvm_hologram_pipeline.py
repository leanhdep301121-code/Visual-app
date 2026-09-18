"""管线 v2:RVM 高分抠人 + 脚部锚定稳定 + 时序中位数背景差分找回球杆。

用法: python rvm_pipeline2.py <源视频> <前缀> <输出目录> [ss=0] [t=0(全长)] [outH=640] [fps=0(源)]
输出: <输出目录>/<前缀>_%04d.png + stdout CONST 行 + <前缀>_debug.png(6帧拼图目检)
杆恢复原理: 三脚架静止机位下,逐像素时序中位数≈背景+静止人体;快速掠过的杆/球
只在少数帧占据某像素 → |帧-中位| 大 → 在"人物走廊"内且非人区域的高差分=杆。
"""
import sys, os, subprocess, tempfile
import numpy as np
import torch
from PIL import Image
from scipy import ndimage

SRC, PREFIX, OUTDIR = sys.argv[1], sys.argv[2], sys.argv[3]
SS   = float(sys.argv[4]) if len(sys.argv) > 4 else 0
T    = float(sys.argv[5]) if len(sys.argv) > 5 else 0
OUTH = int(sys.argv[6]) if len(sys.argv) > 6 else 640
FPS  = float(sys.argv[7]) if len(sys.argv) > 7 else 0
STAB = int(sys.argv[8]) if len(sys.argv) > 8 else 1   # 静止三脚架源传 0(稳定反而破坏背景对齐)
WM   = sys.argv[9] if len(sys.argv) > 9 else ""        # 水印抹除区 "x0,y0,x1,y1"(源坐标)
CLUB = int(sys.argv[10]) if len(sys.argv) > 10 else 1  # 杆恢复只适用静止机位;摇摄源传 0
D = os.path.dirname(os.path.abspath(__file__))

dev = "mps" if torch.backends.mps.is_available() else "cpu"
model = torch.jit.load(f"{D}/rvm_resnet50.torchscript", map_location=dev).eval()

# 1) 抽帧
tmp = tempfile.mkdtemp()
cmd = ["ffmpeg","-y","-hide_banner","-loglevel","error"]
if SS: cmd += ["-ss", str(SS)]
cmd += ["-i", SRC]
if T: cmd += ["-t", str(T)]
if FPS: cmd += ["-vf", f"fps={FPS}"]
cmd += [f"{tmp}/f_%05d.png"]
subprocess.run(cmd, check=True)
frames = sorted(f for f in os.listdir(tmp) if f.endswith(".png"))
rgb0 = np.asarray(Image.open(f"{tmp}/{frames[0]}").convert("RGB"))
H0, W0 = rgb0.shape[:2]
print(f"[1] 帧 {len(frames)} @{W0}x{H0}")

# 2) RVM(高内部分辨率)
rgbs, phas, fgrs = [], [], []
rec = [None]*4
ds = min(1.0, 1024 / max(W0, H0))
with torch.no_grad():
    for f in frames:
        img = np.asarray(Image.open(f"{tmp}/{f}").convert("RGB"))
        rgbs.append(img)
        src = torch.from_numpy(img.copy()).float().div(255).permute(2,0,1).unsqueeze(0).to(dev)
        fgr, pha, *rec = model(src, *rec, downsample_ratio=float(ds))
        phas.append((pha[0,0].cpu().numpy()*255).astype(np.uint8))
        fgrs.append((fgr[0].permute(1,2,0).cpu().numpy()*255).astype(np.uint8))
print(f"[2] RVM 完成 ds={ds:.2f}")

# 3) 脚部锚点稳定(整数平移 rgb/pha/fgr 一起)
anchors = []
for pha in phas:
    ys, xs = np.where(pha > 128)
    if len(ys)==0: anchors.append((np.nan,np.nan)); continue
    bottom = np.percentile(ys, 99.5)
    band = ys > bottom - 0.06*H0
    anchors.append((xs[band].mean(), bottom))
ax = np.array([a[0] for a in anchors]); ay = np.array([a[1] for a in anchors])
from scipy.ndimage import median_filter
tx = median_filter(np.nan_to_num(np.nanmedian(ax)-ax), 5)
ty = median_filter(np.nan_to_num(np.nanmedian(ay)-ay), 5)
def shift(a, dx, dy, fill=0):
    M = np.full_like(a, fill)
    xs0,xs1 = max(0,dx), min(W0, W0+dx); ys0,ys1 = max(0,dy), min(H0, H0+dy)
    M[ys0:ys1, xs0:xs1] = a[ys0-dy:ys1-dy, xs0-dx:xs1-dx]
    return M
if STAB:
    for i in range(len(frames)):
        dx, dy = int(round(tx[i])), int(round(ty[i]))
        rgbs[i] = shift(rgbs[i], dx, dy); phas[i] = shift(phas[i], dx, dy); fgrs[i] = shift(fgrs[i], dx, dy)
print(f"[3] 稳定{'ON' if STAB else 'OFF(静止机位)'}: 锚点std x={np.nanstd(ax):.1f} y={np.nanstd(ay):.1f}, 最大平移 {np.abs(tx).max():.0f},{np.abs(ty).max():.0f}")

# 4) 时序中位数背景 → 差分找杆
stack = np.stack(rgbs[::max(1,len(rgbs)//100)])           # ≤100帧算中位,省内存
med = np.median(stack, axis=0).astype(np.int16)
club_add = 0
cands = []
for i in range(len(frames)):
    rgb = rgbs[i].astype(np.int16); pha = phas[i]
    mask = pha > 100
    holes = ndimage.binary_fill_holes(mask) & ~mask
    hl, hn = ndimage.label(holes)
    if hn:
        hsizes = ndimage.sum(np.ones_like(hl), hl, index=range(1, hn+1))
        small = np.isin(hl, [j+1 for j,sz in enumerate(hsizes) if sz < 150])
        pha = np.maximum(pha, (small*230).astype(np.uint8))
        phas[i] = pha
    diff = np.abs(rgb - med).max(axis=2)
    person = pha > 100
    persond = ndimage.binary_dilation(person, iterations=9)
    dist_person = ndimage.distance_transform_edt(~person)
    corridor = ndimage.binary_dilation(person, iterations=int(0.35*H0/10)*10 and 60)
    cand = (diff > 24) & corridor & ~persond if CLUB else np.zeros_like(person)
    if CLUB:
        # 颜色否决:天空蓝/草地绿 = 人体挪开后露出的背景,不是杆(杆=深色/钢色,球=白)
        R = rgbs[i][...,0].astype(np.int16); G = rgbs[i][...,1].astype(np.int16); B = rgbs[i][...,2].astype(np.int16)
        skyish = (B > 130) & (B - R > 15)
        grassish = (G > 55) & (G - R > 10) & (G - B > 10)
        cand &= ~(skyish | grassish)
    cand = ndimage.binary_closing(cand, structure=np.ones((3,3)))
    # 形状过滤:杆=细长(厚度小),球=小圆;团状杂物(树叶/影子)剔除
    lbl, n = ndimage.label(cand)
    if n:
        keep = set()
        for j in range(1, n+1):
            comp = lbl == j
            area = comp.sum()
            if area < 40: continue
            er = ndimage.binary_erosion(comp)
            perim = (comp & ~er).sum()
            thick = 2*area/max(perim,1)
            if not (thick < 13 or area < 90):   # 细长杆身/杆头拖影 或 小球
                continue
            # 贴边过滤:残渣贴着人形轮廓短距伸展;杆从手向外伸得远
            dmax = dist_person[comp].max()
            if dmax < 28: continue
            keep.add(j)
        cand = np.isin(lbl, list(keep)) if keep else np.zeros_like(cand)
    cands.append(cand)
# 时序一致性:候选出现频率>25% 的像素=静止背景残差(广告牌/人群),不是扫过的杆
freq = np.mean(np.stack(cands), axis=0)
static_junk = ndimage.binary_dilation(freq > 0.25, iterations=2)
cands = [c & ~static_junk for c in cands]
outs = []
for i in range(len(frames)):
    pha = phas[i]; cand = cands[i]
    club_add += cand.sum()
    # alpha 并集;杆区颜色用原始帧(fgr 在杆处可能是幻色)
    a = np.maximum(pha, (ndimage.gaussian_filter(cand.astype(np.float32), 1)*255).astype(np.uint8))
    out_rgb = np.where((cand & (pha < 80))[...,None], rgbs[i], fgrs[i])
    if WM:
        wx0,wy0,wx1,wy1 = map(int, WM.split(","))
        a[wy0:wy1, wx0:wx1] = 0
    outs.append(np.dstack([out_rgb.astype(np.uint8), a]))
print(f"[4] 杆恢复: 平均新增 {club_add/len(frames):.0f}px/帧")

# 5) 并集bbox → 裁剪 → 缩放 → 输出
x0s,y0s,x1s,y1s=[],[],[],[]
for o in outs:
    ys,xs = np.where(o[...,3] > 12)
    if len(xs): x0s.append(xs.min()); x1s.append(xs.max()); y0s.append(ys.min()); y1s.append(ys.max())
m=10
x0=max(0,min(x0s)-m); x1=min(W0,max(x1s)+m); y0=max(0,min(y0s)-m); y1=min(H0,max(y1s)+m)
cw,ch = x1-x0, y1-y0
sc = OUTH/ch; tw=int(round(cw*sc/2))*2; th=int(round(OUTH/2))*2
for i,o in enumerate(outs):
    Image.fromarray(o[y0:y1, x0:x1]).resize((tw,th), Image.LANCZOS).save(f"{OUTDIR}/{PREFIX}_{i:04d}.png")
# debug 拼图(6帧,黑底合成)
idxs = np.linspace(0, len(outs)-1, 6).astype(int)
tiles=[]
for j in idxs:
    o = outs[j][y0:y1, x0:x1]
    comp = (o[...,:3].astype(np.float32)*(o[...,3:4]/255.0)).astype(np.uint8)
    tiles.append(np.array(Image.fromarray(comp).resize((tw//2, th//2))))
Image.fromarray(np.hstack(tiles)).save(f"{OUTDIR}/{PREFIX}_debug.png")
print(f"[5] 输出 {len(outs)}帧 {tw}x{th}")
print(f"CONST {PREFIX} frameCount={len(outs)} aspect={tw}.0/{th}.0")
