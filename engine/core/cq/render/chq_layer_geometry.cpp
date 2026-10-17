// ChuanqiCut — 变换层的顶点烘焙实现（RENDER-010）

#include "cq/render/chq_layer_geometry.h"

#include <cmath>

#include "cq/base/chq_logging.h"
#include "cq/render/chq_fit_viewport.h"

namespace cq {
namespace {

constexpr double kPi = 3.14159265358979323846;

// 像素平面上的仿射：p' = (a·x + b·y + e, c·x + d·y + f)。
struct Affine {
    double a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0;
};

Affine Compose(const Affine& outer, const Affine& inner) {
    Affine r;
    r.a = outer.a * inner.a + outer.b * inner.c;
    r.b = outer.a * inner.b + outer.b * inner.d;
    r.c = outer.c * inner.a + outer.d * inner.c;
    r.d = outer.c * inner.b + outer.d * inner.d;
    r.e = outer.a * inner.e + outer.b * inner.f + outer.e;
    r.f = outer.c * inner.e + outer.d * inner.f + outer.f;
    return r;
}

void Apply(const Affine& m, double x, double y, double& out_x, double& out_y) {
    out_x = m.a * x + m.b * y + m.e;
    out_y = m.c * x + m.d * y + m.f;
}

// 一个 ChqTransform → 像素平面仿射：p' = R(θ)·diag(rel·scale)·(p − K) + C。
//   * K = 画布中心（缩放与旋转都绕它，恒等时该映射就是恒等）；
//   * C = ((0.5+tx)·W, (0.5+ty)·H)：位移是**相对画布**的归一化偏移（chq_transform.h）；
//   * θ 用像素平面的标准旋转（+x 转向 +y，y 向下 ⇒ 屏幕观感顺时针），与模型口径一致。
//     在归一化空间里转会让非正方画布上的 45° 变成斜切，故先换成像素再转。
Affine MakeMap(const ChqTransform& t, double w, double h) {
    const double rad = static_cast<double>(t.rotation_degrees) * kPi / 180.0;
    const double cos_v = std::cos(rad);
    const double sin_v = std::sin(rad);
    const double fx = static_cast<double>(t.relative_width) * static_cast<double>(t.scale_x);
    const double fy = static_cast<double>(t.relative_height) * static_cast<double>(t.scale_y);
    const double kx = w / 2.0;
    const double ky = h / 2.0;
    const double cx = (0.5 + static_cast<double>(t.translate_x)) * w;
    const double cy = (0.5 + static_cast<double>(t.translate_y)) * h;
    const double rs00 = cos_v * fx;
    const double rs01 = -sin_v * fy;
    const double rs10 = sin_v * fx;
    const double rs11 = cos_v * fy;
    Affine m;
    m.a = rs00;
    m.b = rs01;
    m.c = rs10;
    m.d = rs11;
    m.e = cx - rs00 * kx - rs01 * ky;
    m.f = cy - rs10 * kx - rs11 * ky;
    return m;
}

// #21 显示旋转的**逆**作用在单位 uv 帧上（与 blit_pass.mm 的 RotateUv 同一公式，
// 差别只在这里先经镜像与裁剪矩形，见 transform.vert 头部「朝向只在一处定义」）。
void RotateUvUnit(uint16_t rot, double& u, double& v) {
    switch (rot % 360) {
        case 90: {
            const double nu = 1.0 - v;
            const double nv = u;
            u = nu;
            v = nv;
        } break;
        case 180: {
            u = 1.0 - u;
            v = 1.0 - v;
        } break;
        case 270: {
            const double nu = v;
            const double nv = 1.0 - u;
            u = nu;
            v = nv;
        } break;
        default:
            break;  // 0°
    }
}

bool Finite(const ChqTransform& t) {
    const float vals[] = {t.translate_x, t.translate_y, t.scale_x,
                          t.scale_y, t.rotation_degrees, t.relative_width,
                          t.relative_height, t.opacity};
    for (float v : vals) {
        if (!std::isfinite(v)) return false;  // NaN 与 ±inf 一起拦（x==x 判定不可靠）
    }
    return true;
}

}  // namespace

ChqStatus BakeLayerQuad(const ChqLayerInput& in, float* out, uint32_t out_float_capacity) {
    if (out == nullptr || out_float_capacity < kLayerFloatCapacity) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (in.canvas_width == 0 || in.canvas_height == 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    // 语义域 + 有限性两份都要查：Validate 管"能不能画"（正 scale、opacity ≤1、
    // mirror 取值），isfinite 管"算得出不算得出"（NaN 过不了 == 比较，能骗过范围比较）。
    if (!in.clip.Validate().IsOk() || !in.track.Validate().IsOk()) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (!Finite(in.clip) || !Finite(in.track)) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "变换层含非有限浮点，拒绝烘焙");
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    const double w = static_cast<double>(in.canvas_width);
    const double h = static_cast<double>(in.canvas_height);

    // 1) 内容矩形：按 fit_mode 把源宽高比内切/外接进画布（与 blit 共用同一个
    //    ComputeFitViewport，两份实现必然漂移 —— ADR-0034）。源尺寸未知时它返回整画布。
    //    90/270 显示旋转要先交换宽高，否则竖屏源被当横屏裁。
    const uint16_t rot = static_cast<uint16_t>(in.source_rotation % 360);
    const bool swap = (rot == 90 || rot == 270);
    const uint32_t eff_w = swap ? in.source_height : in.source_width;
    const uint32_t eff_h = swap ? in.source_width : in.source_height;
    float vp[4] = {};
    ComputeFitViewport(in.fit_mode, eff_w, eff_h, in.canvas_width, in.canvas_height, vp);

    // 2) 四角：内容局部 (sx,sy) ∈ {−1,1}²（+x 向右、+y 向下），uv 由同一对局部量导出。
    //    轨级 = 父级，叠加顺序 M(轨) ∘ M(片段)（MODEL-004 让给本卡定；轨恒等时合成恒等）。
    const Affine m_clip = MakeMap(in.clip, w, h);
    const Affine m_track = MakeMap(in.track, w, h);
    const Affine m = Compose(m_track, m_clip);
    const uint16_t uv_rot = static_cast<uint16_t>((360 - rot) % 360);
    const double alpha = static_cast<double>(in.clip.opacity) * static_cast<double>(in.track.opacity);

    // 两个三角形覆盖同一个矩形（索引缓冲在本契约里无处可绑，故展开成 6 顶点）。
    static constexpr double kCorner[6][2] = {
        {-1.0, -1.0},
        {1.0, -1.0},
        {-1.0, 1.0},
        {1.0, -1.0},
        {1.0, 1.0},
        {-1.0, 1.0},
    };
    const double half_w = static_cast<double>(vp[2]) / 2.0;
    const double half_h = static_cast<double>(vp[3]) / 2.0;
    const double rect_cx = static_cast<double>(vp[0]) + half_w;
    const double rect_cy = static_cast<double>(vp[1]) + half_h;

    for (uint32_t i = 0; i < kLayerVertexCount; ++i) {
        const double sx = kCorner[i][0];
        const double sy = kCorner[i][1];
        double px = 0.0;
        double py = 0.0;
        Apply(m, rect_cx + sx * half_w, rect_cy + sy * half_h, px, py);

        double u = (sx + 1.0) / 2.0;
        double v = (sy + 1.0) / 2.0;
        // 镜像在**显示帧**里做（先镜像再还原编码朝向），水平 = 左右反 = 翻 u。
        if (in.clip.mirror == ChqMirrorKind::kHorizontal) u = 1.0 - u;
        if (in.clip.mirror == ChqMirrorKind::kVertical) v = 1.0 - v;
        RotateUvUnit(uv_rot, u, v);

        out[i * kLayerVertexFloats + 0] = static_cast<float>(2.0 * px / w - 1.0);
        out[i * kLayerVertexFloats + 1] = static_cast<float>(1.0 - 2.0 * py / h);
        out[i * kLayerVertexFloats + 2] = static_cast<float>(u);
        out[i * kLayerVertexFloats + 3] = static_cast<float>(v);
        out[i * kLayerVertexFloats + 4] = static_cast<float>(alpha);
    }
    return ChqStatus::Ok();
}

}  // namespace cq
