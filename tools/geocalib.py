"""GeoCalib 离线推理（对齐 Swin/Analysis/GeoCalibService.swift）。
单帧 → 地平线 / 俯仰 / 焦距。用于让 diag 的弹道投影用真实俯仰（否则落点提早下落）。
"""
import cv2, numpy as np
import coremltools as ct

_W, _H = 320, 576
MODEL = "/Users/soda/Swi-app/Models/GeoCalibNet.mlpackage"
_m = None


def _fit(frame_bgr):
    """中心裁剪到模型的 320:576 宽高比，再缩放。不能直接 resize 整帧：
    竖屏源(1080×1920=0.5625)和模型框(0.5555)几乎同比，硬拉无损，所以一直没暴露；
    但横屏源(1264×720=1.76)硬拉进去 = 横压 3.95×、纵拉 0.8×，总畸变 4.9×，
    GeoCalib 看到一张捏扁的图 → focal 302(FOV 128°，手机不可能) → anchorZ 1.1m
    → 尺度整体缩水 ~2.2× → 22 m/s。
    裁剪保住【垂直视场】，focalPx = fField*(ch/_H) 那步才继续成立。

    返回 (crop, y0, ch)：y0/ch 用于把地平线行映射回原帧。"""
    h, w = frame_bgr.shape[:2]
    want = _W / _H                       # 0.5555
    if w / h > want:                     # 太宽(横屏) → 裁两侧，垂直视场不变
        cw = int(round(h * want))
        x0 = (w - cw) // 2
        return frame_bgr[:, x0:x0 + cw], 0, h
    ch = int(round(w / want))            # 太高 → 裁上下，垂直视场缩小
    y0 = (h - ch) // 2
    return frame_bgr[y0:y0 + ch, :], y0, ch


def calibrate(frame_bgr, orig_w, orig_h):
    """返回 (horizonY_norm, pitchRad, focalPx)（原帧像素空间）。"""
    global _m
    if _m is None:
        _m = ct.models.MLModel(MODEL)
    crop, y0, ch = _fit(frame_bgr)       # ch = 送进模型的垂直视场(原帧像素)
    rgb = cv2.cvtColor(cv2.resize(crop, (_W, _H)), cv2.COLOR_BGR2RGB).astype(np.float32) / 255
    arr = np.transpose(rgb, (2, 0, 1))[None]                 # (1,3,576,320)
    lat = _m.predict({"image": arr})["latitude"][0, 0]       # (576,320) tanh≈lat/(π/2)
    col = lat[:, _W // 2]
    # 零交叉行 = 地平线
    hr = -1.0
    for y in range(_H - 1):
        a, b = col[y], col[y + 1]
        if a == 0:
            hr = y; break
        if a * b < 0:
            hr = y + a / (a - b); break
    if hr < 0:
        return None
    # 地平线行在【裁剪】里 → 映射回原帧
    horizonY = (y0 + hr / _H * ch) / orig_h
    cy = orig_h / 2
    # 焦距：latitude 斜率。取地平线下方 25% 处一行
    refY = min(_H - 2, int(hr) + _H // 4)
    latRef = col[refY] * (np.pi / 2)
    dyField = refY - hr
    focalPx = orig_h * 0.72
    if abs(latRef) > 0.02 and abs(np.tan(latRef)) > 1e-3:
        fField = abs(dyField / np.tan(latRef))
        focalPx = fField * (ch / _H)      # 模型看到的是 ch 高的视场，不是 orig_h
    pitch = float(np.arctan((cy - horizonY * orig_h) / focalPx))
    return float(horizonY), pitch, float(focalPx)
