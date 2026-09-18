"""BallFlightSolver 的忠实 Python 移植（对齐 Swin/Analysis/BallFlight.swift）。

只为离线诊断可视化用我们自己的 3D 弹道引擎（不是屏幕空间外推）。
solveBoundedState 网格搜 + integrateFlight（Cd 0.25 + Cl 0.08 @1/240）+ projectedFlight。
"""
import numpy as np


def _norm(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


class Camera:
    def __init__(self, fx, fy, cx, cy, gravity=(0, 1, 0)):
        self.fx, self.fy, self.cx, self.cy = fx, fy, cx, cy
        self.g = np.array(gravity, float)


def solve_bounded_state(obs, cam, anchorZ, tee=None, t0_hint=None):
    """obs: [(u,v,t)] 像素。返回 (p0, v, err, t0) 或 None。"""
    if len(obs) < 5 or not (1 < anchorZ < 15):
        return None
    g = _norm(cam.g) * 9.8
    au, av = tee if tee is not None else (obs[0][0], obs[0][1])
    d0 = _norm(np.array([(au - cam.cx) / cam.fx, (av - cam.cy) / cam.fy, 1.0]))
    p0 = d0 * (anchorZ / max(d0[2], 0.1))
    if t0_hint is not None:
        t0_grid = [min(0, t0_hint - 0.033), min(0, t0_hint), min(0, t0_hint + 0.033)]
    else:
        t0_grid = [-0.30, -0.225, -0.15, -0.075, 0.0] if tee is not None else [0.0]
    up = -_norm(cam.g)
    fwd = _norm(np.array([0, 0, 1.0]) - np.dot(np.array([0, 0, 1.0]), up) * up)
    right = _norm(np.cross(fwd, up))
    O = np.array([[o[0], o[1]] for o in obs], float)
    T = np.array([o[2] for o in obs], float)

    def rms(v, t0):
        dt = T - t0
        P = p0[None, :] + v[None, :] * dt[:, None] + 0.5 * g[None, :] * (dt * dt)[:, None]
        z = np.maximum(P[:, 2], 0.05)
        du = cam.fx * P[:, 0] / z + cam.cx - O[:, 0]
        dv = cam.fy * P[:, 1] / z + cam.cy - O[:, 1]
        return np.sqrt(np.mean(du * du + dv * dv))

    def velocity(sp, la, az):
        vh = sp * np.cos(la)
        return up * (sp * np.sin(la)) + fwd * (vh * np.cos(az)) + right * (vh * np.sin(az))

    sGrid = [28, 36, 44, 52, 60, 68]
    laGrid = list(np.deg2rad(np.arange(10, 43, 6)))
    # ±16 太窄(背后机位球侧飞方位~23°被卡, err 47px)；±40 太宽(真机出现平飞退化解)。
    # ±28 覆盖侧飞又不放进退化解 —— 与端上 BallFlight.swift 一致。
    azGrid = list(np.deg2rad(np.arange(-28, 29, 7)))
    tGrid = list(t0_grid)
    best = None
    for _ in range(3):
        top = None
        for sp in sGrid:
            for la in laGrid:
                for az in azGrid:
                    for t0 in tGrid:
                        e = rms(velocity(sp, la, az), t0)
                        if top is None or e < top[4]:
                            top = (sp, la, az, t0, e)
        if top is None:
            return None
        best = (velocity(top[0], top[1], top[2]), top[4], top[3])
        sGrid = [max(22, top[0] - 5), top[0], min(75, top[0] + 5)]
        laGrid = [max(np.deg2rad(8), top[1] - 0.05), top[1], min(np.deg2rad(45), top[1] + 0.05)]
        azGrid = [top[2] - 0.04, top[2], top[2] + 0.04]
        tGrid = (t0_grid if t0_hint is not None
                 else ([min(0, top[3] - 0.03), top[3], min(0, top[3] + 0.03)] if len(t0_grid) > 1 else [0.0]))
    return (p0, best[0], best[1], best[2])


_AERO = [(10.9, 0.21, 0.16),   # PGA 驱杆 2686rpm
         (16.3, 0.35, 0.37),   # PGA 7铁 7100rpm
         (20.0, 0.33, 0.31)]   # 业余 7铁


def aero_for_launch(launch_deg):
    """自旋先验:发射角代理 loft/自旋 → (Cd, Cl)。不进拟合自由度。
    实测基准锚点 + 线性插值(对齐 BallFlight.swift aeroForLaunch)。

    是【等效】系数——为让这个简化模型(无自旋衰减、无雷诺数依赖)复现真实
    carry/顶高/滞空而拟合出来的，不是实测气动量。Cd 0.35 对真球偏高，它在
    替模型没建的那部分买单。

    旧版 Cd 钉死 0.25 + Cl 挡位 0.18/0.22/0.27 → 球普遍升不够:顶高低 14–26%
    (7铁 23.8m vs 真实 32m)而 carry 只差 9% → 弧线扁、早下落。自旋同时驱动
    Cd 和 Cl，且驱杆↔7铁差 2.6 倍，光靠 Cl 1.2 倍的跨度表达不了；Cd 钉死则
    让升力和距离无法同时满足。调小 g 也能抬顶高，但会把本已正确的 carry 一起
    抬飞，且 g 是这里唯一精确已知的量。"""
    if launch_deg <= _AERO[0][0]:
        return _AERO[0][1], _AERO[0][2]
    if launch_deg >= _AERO[-1][0]:
        return _AERO[-1][1], _AERO[-1][2]
    for a, b in zip(_AERO, _AERO[1:]):
        if a[0] <= launch_deg <= b[0]:
            u = (launch_deg - a[0]) / (b[0] - a[0])
            return a[1] + u * (b[1] - a[1]), a[2] + u * (b[2] - a[2])
    return _AERO[0][1], _AERO[0][2]


def cl_for_launch(launch_deg):
    """兼容旧调用点(诊断打印用)。"""
    return aero_for_launch(launch_deg)[1]


def integrate_flight(p0, v0, cam, step=1.0 / 30, cl=None):
    g = _norm(cam.g) * 9.8
    up = -_norm(cam.g)
    h0 = np.dot(p0, up)
    kAir = 0.5 * 1.2 * 1.432e-3 / 0.0459
    sp = np.linalg.norm(v0)
    la = np.degrees(np.arcsin(np.clip(np.dot(v0, up) / max(sp, 1e-6), -1, 1)))
    cd, cl_prior = aero_for_launch(la)
    if cl is None:           # 未指定 → 按发射角先验
        cl = cl_prior
    P, V = p0.astype(float).copy(), v0.astype(float).copy()
    t, dt, nxt = 0.0, 1.0 / 240, 0.0
    out = []
    while t < 10:
        if t >= nxt:
            out.append((P.copy(), t))
            nxt += step
            if t > 0.5 and np.dot(P, up) < h0:
                break
        sp = np.linalg.norm(V)
        a = g - kAir * cd * sp * V
        if sp > 1:
            vh = V / sp
            l = up - np.dot(up, vh) * vh
            ln = np.linalg.norm(l)
            if ln > 1e-3:
                a += kAir * cl * sp * sp * (l / ln)
        V = V + a * dt
        P = P + V * dt
        t += dt
    return out


def projected_flight(state, cam, step=1.0 / 30):
    """返回 [(u,v,t)]，t 以观测时基（发射 = state.t0 ≤ 0）。"""
    p0, v, err, t0 = state
    out = []
    for P, t in integrate_flight(p0, v, cam, step):
        z = max(P[2], 0.05)
        out.append((cam.fx * P[0] / z + cam.cx, cam.fy * P[1] / z + cam.cy, t + t0))
    return out


def metrics(state, cam):
    p0, v, err, t0 = state
    up = -_norm(cam.g)
    speed = float(np.linalg.norm(v))
    launch = float(np.degrees(np.arcsin(np.clip(np.dot(v, up) / speed, -1, 1))))
    path = integrate_flight(p0, v, cam)
    d = (path[-1][0] if path else p0) - p0
    carry = float(np.linalg.norm(d - np.dot(d, up) * up))
    return speed, launch, carry, float(err)
