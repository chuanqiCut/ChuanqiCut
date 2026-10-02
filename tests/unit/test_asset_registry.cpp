// ChuanqiCut — 素材表单测（BIND-003 子步骤 1）
//
// 重点验证**指针稳定性**：MediaSource 只存 `const char*` 裸指针，
// 若实现把路径放在 Entry 内部（而非堆上），unordered_map 重哈希搬家时
// 短字符串的 SSO 缓冲区会换地址 → 之前发出去的 MediaSource.path 全部悬垂。
// 这个 bug 在只注册两三条时不会暴露，必须**插入足够多触发重哈希**才能测出来。

#include <cstdio>
#include <string>
#include <vector>

#include "cq/base/status.h"
#include "cq/media/asset_registry.h"

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

}  // namespace

int main() {
    std::printf("=== 素材表 AssetRegistry ===\n");
    cq::AssetRegistry reg;

    // ---- 基本注册 / 查询 ----
    Check(reg.Register(1, "/tmp/a.mp4").IsOk(), "注册 asset 1");
    Check(reg.Count() == 1, "表中一条");

    const cq::MediaSource* src = reg.Find(1);
    Check(src != nullptr, "可按 id 取回");
    Check(src != nullptr && std::string(src->path, src->path_len) == "/tmp/a.mp4",
          "路径内容正确");
    Check(reg.Find(999) == nullptr, "未注册的 id 返回 nullptr");

    // ---- 参数校验 ----
    Check(!reg.Register(2, "").IsOk(), "空路径被拒绝");

    // ---- 重复注册：整体替换 ----
    Check(reg.Register(1, "/tmp/b.mov").IsOk(), "重复注册同一 id");
    Check(reg.Count() == 1, "重复注册不增加条目");
    src = reg.Find(1);
    Check(src != nullptr && std::string(src->path, src->path_len) == "/tmp/b.mov",
          "重复注册后是新的路径");

    // ---- ★ 指针稳定性：插入大量条目触发重哈希 ----
    // 先在表中保留若干短路径（会走 SSO），再灌入足够多的条目迫使 map 重哈希，
    // 最后回头检查先前那些 path 是否仍然可读。
    std::printf("\n[关键] 重哈希后指针稳定性\n");
    reg.Clear();
    const int kShortCount = 8;
    std::vector<uint64_t> kept_ids;
    std::vector<std::string> expected;
    for (int i = 0; i < kShortCount; ++i) {
        uint64_t id = 1000 + static_cast<uint64_t>(i);
        std::string p = "/s/" + std::string(1, static_cast<char>('a' + i));  // 极短，必走 SSO
        reg.Register(id, p);
        kept_ids.push_back(id);
        expected.push_back(p);
    }
    // 灌入大量条目触发多次重哈希
    for (int i = 0; i < 2000; ++i) {
        reg.Register(100000 + static_cast<uint64_t>(i),
                     "/some/much/longer/path/to/force/heap/alloc/" + std::to_string(i));
    }
    bool all_stable = true;
    for (int i = 0; i < kShortCount; ++i) {
        const cq::MediaSource* s = reg.Find(kept_ids[static_cast<std::size_t>(i)]);
        if (s == nullptr || std::string(s->path, s->path_len) != expected[static_cast<std::size_t>(i)]) {
            all_stable = false;
            std::printf("    条目 %d 内容已损坏\n", i);
        }
    }
    Check(all_stable, "重哈希（2000+ 条）后先前注册的短路径仍有效且不损坏");
    Check(reg.Count() == static_cast<std::size_t>(kShortCount) + 2000, "条目总数正确");

    // ---- 反注册 / 清空 ----
    Check(reg.Unregister(1000).IsOk(), "反注册存在的 id");
    Check(!reg.Unregister(999999).IsOk(), "反注册不存在的 id 返回错误");
    Check(reg.Find(1000) == nullptr, "反注册后查不到");

    reg.Clear();
    Check(reg.Count() == 0, "清空后为空");
    Check(reg.Find(1001) == nullptr, "清空后查不到");

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
