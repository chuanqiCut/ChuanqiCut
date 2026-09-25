// ChuanqiCut — PAL 文件系统抽象接口（CORE-006 / PALD-040）
//
// 职责：文件访问抽象，含 Android Scoped Storage / MediaStore 差异吸收。
// 下游 PALD-040（Scoped Storage / MediaStore）依赖。
//
// 设计：路径用本项目自己的抽象（UTF-8 字符串 + 命名空间标志），不出现 jobject /
// ContentResolver 等平台类型。Android 的 Scoped Storage / MediaStore 差异由 PAL 在
// ResolveMediaStoreUri 内吸收，core 层无感。
//
// 生命周期契约（与 GFX/Audio/Inference 等资源一致）：文件句柄即 `IFile`，继承
// `IPalResource`，由 `PalPtr<IFile>` 管理（析构自动 Destroy() 关闭文件）。
// 不再使用裸指针句柄 —— 与全接口生命周期约定统一，避免文件句柄泄漏。
//
// 红线：零平台类型、零 FFmpeg 类型。

#ifndef CQ_PAL_FS_H_
#define CQ_PAL_FS_H_

#include <cstdint>

#include "cq/base/status.h"
#include "cq/pal/common.h"

namespace cq {

// 路径命名空间（区分访问语义，尤其是 Android 分区存储）。
enum class PathNamespace : int32_t {
    kAppSpecific = 0,   // 应用私有目录（无需权限）
    kSharedDocuments,   // 共享文档（可能需要权限）
    kMediaStore,        // 媒体库（Android MediaStore / iOS 相册）
    kTemp,              // 临时目录
};

// 路径抽象（UTF-8）。uri 对 MediaStore 可能是 content URI 字符串。
struct Path {
    const char* uri = nullptr;
    size_t uri_len = 0;
    PathNamespace ns = PathNamespace::kAppSpecific;
};

// 文件访问模式。
enum class FileAccessMode : int32_t {
    kRead = 0,
    kWrite,        // 截断写
    kReadWrite,
    kCreate,       // 不存在则创建
};

// 文件元信息。
struct FileStat {
    bool exists = false;
    bool is_directory = false;
    int64_t size_bytes = 0;
};

// 文件对象（资源接口）。生命周期由 PalPtr<IFile> 管理：析构 Destroy() 即关闭文件。
// 不再使用裸 opaque 指针 —— 与全接口「PalPtr + Destroy()」约定统一（评审要求）。
class IFile : public IPalResource {
public:
    virtual Status Read(void* buf, size_t len, size_t& out_read) = 0;
    virtual Status Write(const void* buf, size_t len, size_t& out_written) = 0;
    // Destroy()（继承自 IPalResource）关闭并释放本文件。
};

class IFileSystem : public IPalResource {
public:
    // 打开文件，返回 PalPtr<IFile>（RAII，析构自动关闭）。
    virtual Status Open(const Path& path, FileAccessMode mode, PalPtr<IFile>& out_file) = 0;

    virtual Status Stat(const Path& path, FileStat& out_stat) = 0;
    virtual Status ListDir(const Path& path, char* out_entries, size_t max_entries,
                           size_t entry_stride, int32_t& out_count) = 0;
    virtual Status Delete(const Path& path) = 0;
    virtual Status Rename(const Path& from, const Path& to) = 0;
    virtual Status CreateDir(const Path& path) = 0;

    // Android：把 MediaStore URI / 相册资源映射为可打开的 Path（吸收 Scoped Storage 差异）。
    // 非 Android 平台可直接回显输入或返回 kUnsupported。
    virtual Status ResolveMediaStoreUri(const char* media_uri, size_t uri_len, Path& out_path) = 0;
};

// 工厂（由 PAL 平台实现）。返回 PalPtr。
Status CreateFileSystem(PalPtr<IFileSystem>& out_fs);

}  // namespace cq

#endif  // CQ_PAL_FS_H_
