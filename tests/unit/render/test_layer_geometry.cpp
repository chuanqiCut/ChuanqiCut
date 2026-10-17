// ChuanqiCut — 变换层顶点烘焙单测（RENDER-010）
//
// 纯 CPU 断言（不碰 Metal）：三端一致与恒等回归的口径就在这份文件里锁 ——
// 像素比对只能证明"这台机器这一端对了"，而顶点是 core 算出来的，逐位比才有意义。
// GPU 侧的恒等回归由 test_layer_identity.cpp（heavy）守另一件事：MSL 管线真的画得出来。
//
// 覆盖：恒等对齐 blit 的 uv 约定 / 位移=归一化×画布像素 / 缩放 / 45° 在非正方画布不斜切 /
//       镜像 / 90° 显示旋转交换适配宽高 / 轨级合成 / alpha 相乘 / 非法输入拒绝

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>

#include "cq/base/chq_status.h"
#include "cq/model/chq_transform.h"
#include "cq/render/chq_fit_viewport.h"
#include "cq/render/chq_layer_geometry.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        std::printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

bool Near(float a, float b, float eps = 1e-3f) { return std::fabs(a - b) <= eps; }

// NDC → 像素平面（原点左上、+y 向下）。旋转与"斜不斜切"只能在像素平面判：
// 非正方画布上 NDC 的长度是被各向异性拉伸过的。
float Px(const float* v, uint32_t i, uint32_t w, uint32_t h, int comp) {
    return comp == 0 ? (v[i * cq::kLayerVertexFloats + 0] + 1.0f) * 0.5f * static_cast<float>(w)
                     : (1.0f - v[i * cq::kLayerVertexFloats + 1]) * 0.5f * static_cast<float>(h);
}

// 6 个顶点 = 两个三角形，前 3 个就是矩形的三个角（第 4 个角重复）。
struct Corner {
    float x;
    float y;
    float u;
    float v;
};

Corner Get(const float* verts, uint32_t i, uint32_t w, uint32_t h) {
    Corner c;
    c.x = Px(verts, i, w, h, 0);
    c.y = Px(verts, i, w, h, 1);
    c.u = verts[i * cq::kLayerVertexFloats + 2];
    c.v = verts[i * cq::kLayerVertexFloats + 3];
    return c;
}

cq::ChqLayerInput Make(uint32_t cw, uint32_t ch, uint32_t sw, uint32_t sh) {
    cq::ChqLayerInput in;
    in.canvas_width = cw;
    in.canvas_height = ch;
    in.source_width = sw;
    in.source_height = sh;
    return in;
}

constexpr uint32_t kW = 1080;
constexpr uint32_t kH = 1920;

}  // namespace

int main() {
    std::printf("== 变换层顶点烘焙单测（RENDER-010）==\n");

    // ---------- 1. 恒等档：与现有 blit 同一批像素 ----------
    std::printf("\n[1] 恒等 = 整画布 + uv(0,0)=图像左上\n");
    {
        const cq::ChqLayerInput in = Make(kW, kH, 0, 0);  // 源尺寸未知 → 整画布
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(in, verts, cq::kLayerFloatCapacity).IsOk(), "恒等烘焙成功");
        Check(Get(verts, 0, kW, kH).u == 0.0f && Near(Get(verts, 0, kW, kH).x, 0.0f) &&
                  Near(Get(verts, 0, kW, kH).y, 0.0f),
              "uv(0,0) 落在像素左上（与 blit_pass 的 kBlitVerts 同一约定）");
        Check(Near(Get(verts, 1, kW, kH).x, static_cast<float>(kW)) &&
                  Near(Get(verts, 2, kW, kH).y, static_cast<float>(kH)),
              "矩形铺满画布（右下 = 1080,1920）");
        Check(verts[4] == 1.0f, "alpha = 1");
    }
    {
        // contain 恒等：烘焙进顶点的矩形必须与 blit 路径的视口矩形数值相同
        // （同一份 ComputeFitViewport，两份实现在这里逐值对撞）。
        const cq::ChqLayerInput in = Make(kW, kH, 1920, 1080);
        cq::ChqLayerInput contain = in;
        contain.fit_mode = cq::ChqFitMode::kContain;
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(contain, verts, cq::kLayerFloatCapacity).IsOk(),
              "contain 恒等烘焙成功");
        float vp[4] = {};
        cq::ComputeFitViewport(cq::ChqFitMode::kContain, 1920, 1080, kW, kH, vp);
        Check(Near(Get(verts, 0, kW, kH).x, vp[0], 0.02f) &&
                  Near(Get(verts, 0, kW, kH).y, vp[1], 0.02f),
              "contain 左上 = 视口左上");
        const Corner br = Get(verts, 1, kW, kH);
        const Corner bl = Get(verts, 2, kW, kH);
        Check(Near(br.x - vp[0], vp[2], 0.02f) && Near(bl.y - vp[1], vp[3], 0.02f),
              "contain 宽高 = 视口宽高（16:9 内切 1080x607.5）");
    }

    // ---------- 2. 位移与缩放 ----------
    std::printf("\n[2] 位移=归一化×画布像素，缩放绕画布中心\n");
    {
        cq::ChqLayerInput in = Make(kW, kH, 0, 0);
        in.clip.translate_x = 0.1f;
        in.clip.translate_y = -0.25f;
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(in, verts, cq::kLayerFloatCapacity).IsOk(), "位移烘焙成功");
        // 整幅平移：三个角的偏移量相同
        const float dx = Get(verts, 0, kW, kH).x;
        const float dy = Get(verts, 0, kW, kH).y;
        Check(Near(dx, 0.1f * static_cast<float>(kW), 0.5f), "translate_x=0.1 → 右移 108 px");
        Check(Near(dy, -0.25f * static_cast<float>(kH), 0.5f), "translate_y=-0.25 → 上移 480 px");
        Check(Near(Get(verts, 1, kW, kH).x - static_cast<float>(kW), dx, 0.5f) &&
                  Near(Get(verts, 2, kW, kH).y - static_cast<float>(kH), dy, 0.5f),
              "每个角位移一致（是平移，不是透视/斜切）");
    }
    {
        cq::ChqLayerInput in = Make(kW, kH, 0, 0);
        in.clip.scale_x = 0.5f;
        in.clip.scale_y = 0.5f;
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(in, verts, cq::kLayerFloatCapacity).IsOk(), "缩放烘焙成功");
        Check(Near(Get(verts, 1, kW, kH).x - Get(verts, 0, kW, kH).x, static_cast<float>(kW) * 0.5f,
                   1.0f),
              "scale 0.5 → 宽变一半");
        Check(Near((Get(verts, 0, kW, kH).x + Get(verts, 1, kW, kH).x) * 0.5f,
                   static_cast<float>(kW) * 0.5f, 1.0f),
              "缩放绕画布中心（左右仍对称）");
    }

    // ---------- 3. 旋转在像素平面：45° 不斜切 ----------
    std::printf("\n[3] 45° 旋转保边长与直角（非正方画布不斜切）\n");
    {
        cq::ChqLayerInput in = Make(kW, kH, 0, 0);
        in.clip.rotation_degrees = 45.0f;
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(in, verts, cq::kLayerFloatCapacity).IsOk(), "45° 烘焙成功");
        const Corner c0 = Get(verts, 0, kW, kH);
        const Corner c1 = Get(verts, 1, kW, kH);
        const Corner c2 = Get(verts, 2, kW, kH);
        const float e1x = c1.x - c0.x, e1y = c1.y - c0.y;
        const float e2x = c2.x - c0.x, e2y = c2.y - c0.y;
        const float len1 = std::sqrt(e1x * e1x + e1y * e1y);
        const float len2 = std::sqrt(e2x * e2x + e2y * e2y);
        Check(Near(len1, static_cast<float>(kW), 2.0f), "上边仍 = 1080 px（旋转不伸长）");
        Check(Near(len2, static_cast<float>(kH), 2.0f), "左边仍 = 1920 px");
        const float dot = e1x * e2x + e1y * e2y;
        Check(std::fabs(dot) < 2000.0f, "两邻边仍垂直（点积≈0；斜切会立刻偏离）");
    }

    // ---------- 4. 镜像与 #21 显示旋转 ----------
    std::printf("\n[4] 镜像翻 uv，90° 显示旋转交换适配宽高\n");
    {
        cq::ChqLayerInput in = Make(kW, kH, 0, 0);
        in.clip.mirror = cq::ChqMirrorKind::kHorizontal;
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(in, verts, cq::kLayerFloatCapacity).IsOk(), "水平镜像烘焙成功");
        Check(Near(Get(verts, 0, kW, kH).u, 1.0f) && Near(Get(verts, 0, kW, kH).v, 0.0f),
              "水平镜像 = 翻 u（左上角采到 uv(1,0)）");

        cq::ChqLayerInput flip = in;
        flip.clip.mirror = cq::ChqMirrorKind::kVertical;
        Check(cq::BakeLayerQuad(flip, verts, cq::kLayerFloatCapacity).IsOk(), "垂直镜像烘焙成功");
        Check(Near(Get(verts, 0, kW, kH).v, 1.0f), "垂直镜像 = 翻 v");
    }
    {
        // 竖屏 16:9 编码 + 90° 显示旋转 → 显示为 9:16，contain 应铺满 1080x1920；
        // 若旋转只在 uv 层而没交换适配宽高，会被当成横屏裁出上下 bar。
        const cq::ChqLayerInput rot = [] {
            cq::ChqLayerInput in = Make(kW, kH, 1920, 1080);
            in.source_rotation = 90;
            in.fit_mode = cq::ChqFitMode::kContain;
            return in;
        }();
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(rot, verts, cq::kLayerFloatCapacity).IsOk(), "90° 烘焙成功");
        Check(Near(Get(verts, 0, kW, kH).x, 0.0f, 0.02f) &&
                  Near(Get(verts, 1, kW, kH).x, static_cast<float>(kW), 0.02f),
              "90° 竖屏 contain 铺满宽度（旋转角换过宽高）");
        Check(Near(Get(verts, 0, kW, kH).y, 0.0f, 0.02f) &&
                  Near(Get(verts, 2, kW, kH).y, static_cast<float>(kH), 0.02f),
              "90° 竖屏 contain 铺满高度（无上下 bar）");
        // 朝向还原在 uv 层做（color-safe 直通，与 blit 同一公式）
        Check(!Near(Get(verts, 0, kW, kH).u, 0.0f) || !Near(Get(verts, 0, kW, kH).v, 0.0f),
              "90° 时采样 uv 已还原（不等于未旋转的 uv）");
    }

    // ---------- 5. 轨级 = 父级，叠加顺序 M(轨) ∘ M(片段) ----------
    std::printf("\n[5] 轨级合成\n");
    {
        float only_clip[cq::kLayerFloatCapacity] = {};
        float both[cq::kLayerFloatCapacity] = {};
        cq::ChqLayerInput a = Make(kW, kH, 0, 0);
        a.clip.translate_x = 0.1f;
        Check(cq::BakeLayerQuad(a, only_clip, cq::kLayerFloatCapacity).IsOk(), "仅片段位移");
        cq::ChqLayerInput b = a;
        b.track.translate_x = 0.1f;
        Check(cq::BakeLayerQuad(b, both, cq::kLayerFloatCapacity).IsOk(), "轨+片段位移");
        Check(Near(both[0] - only_clip[0], 0.2f, 1e-3f),
              "两级位移相加（再 0.1 画布宽 = NDC 再偏移 0.2）");

        cq::ChqLayerInput identity_track = a;
        identity_track.track = cq::ChqTransform();
        float tri[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(identity_track, tri, cq::kLayerFloatCapacity).IsOk(),
              "轨级恒等烘焙");
        bool same = true;
        for (uint32_t i = 0; i < cq::kLayerFloatCapacity; ++i) {
            if (tri[i] != only_clip[i]) same = false;
        }
        Check(same, "轨级恒等 → 与只给片段变换逐位相同（MODEL-004 让给本卡的合成序）");

        cq::ChqLayerInput alpha_in = a;
        alpha_in.clip.opacity = 0.5f;
        alpha_in.track.opacity = 0.5f;
        float av[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(alpha_in, av, cq::kLayerFloatCapacity).IsOk(), "两级 alpha 烘焙");
        Check(Near(av[4], 0.25f), "alpha = 片段 0.5 × 轨 0.5 = 0.25");
    }

    // ---------- 6. 非法输入：拒绝且不写 out ----------
    std::printf("\n[6] 拒绝非法输入\n");
    {
        float verts[cq::kLayerFloatCapacity] = {};
        for (uint32_t i = 0; i < cq::kLayerFloatCapacity; ++i) verts[i] = -777.0f;

        cq::ChqLayerInput nan = Make(kW, kH, 0, 0);
        nan.clip.scale_x = std::nanf("");
        Check(!cq::BakeLayerQuad(nan, verts, cq::kLayerFloatCapacity).IsOk(), "NaN scale → 拒绝");

        cq::ChqLayerInput neg = Make(kW, kH, 0, 0);
        neg.clip.scale_x = -1.0f;
        Check(!cq::BakeLayerQuad(neg, verts, cq::kLayerFloatCapacity).IsOk(), "负 scale → 拒绝");

        cq::ChqLayerInput op = Make(kW, kH, 0, 0);
        op.track.opacity = 1.5f;
        Check(!cq::BakeLayerQuad(op, verts, cq::kLayerFloatCapacity).IsOk(), "opacity>1 → 拒绝");

        cq::ChqLayerInput zero = Make(0, kH, 0, 0);
        Check(!cq::BakeLayerQuad(zero, verts, cq::kLayerFloatCapacity).IsOk(), "画布宽 0 → 拒绝");

        Check(!cq::BakeLayerQuad(Make(kW, kH, 0, 0), nullptr, cq::kLayerFloatCapacity).IsOk(),
              "out 空 → 拒绝");
        float small[10] = {};
        Check(!cq::BakeLayerQuad(Make(kW, kH, 0, 0), small, 10).IsOk(), "容量不足 → 拒绝");

        bool untouched = true;
        for (uint32_t i = 0; i < cq::kLayerFloatCapacity; ++i) {
            if (verts[i] != -777.0f) untouched = false;
        }
        Check(untouched, "拒绝路径不写 out（调用方拿不到半份顶点）");
    }

    // [7] 单层烘焙成本 —— RENDER-011 的叠合层数直接乘在这个数上，先有基线才好判断"够用"。
    //     阈值放得极松（只抓"烘焙里混进逐帧磁盘/锁"这类灾难），不当性能门禁；数字进 baselines。
    std::printf("\n[7] 烘焙成本（本机 CPU，不是设备 GPU 成本）\n");
    {
        float v[cq::kLayerFloatCapacity] = {};
        const int kIters = 200000;
        auto* sink = new float[kIters];  // 防止编译器把整条循环优化掉
        const auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < kIters; ++i) {
            if (!cq::BakeLayerQuad(Make(kW, kH, 0, 0), v, cq::kLayerFloatCapacity).IsOk()) sink[i] = -1.0f;
            sink[i] = v[0];
        }
        const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now() - t0)
                            .count();
        const double per = static_cast<double>(ns) / kIters;
        std::printf("  实测：BakeLayerQuad 单次 = %.0f ns（%d 次，含读回 sink）\n", per, kIters);
        Check(per < 20000.0, "单次烘焙 < 20µs（松阈值：只抓灾难级回归，不当性能门禁）");
        delete[] sink;
    }

    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
