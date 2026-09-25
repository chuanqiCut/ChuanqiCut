# Golden Frame 测试样本库（QA-001）

预览渲染与最终导出必须走同一张 RenderGraph（ARCH-001 §9 / ARCH-003 §9）。
本库是 **PSNR/SSIM 比对的基准素材**，由 QA-002 的比对工具与 QA-003 的端到端用例消费。

> 本任务只负责「样本库骨架 + 合成素材 + 清单 + 校验脚本」。
> 不实现比对算法（QA-002）、不写端到端用例（QA-003）、不改任何构建配置。

---

## 1. 目录结构

```
tests/golden/
├── README.md            # 本文件：规范、复现、局限
├── manifest.toml        # 真源清单：每段素材的参数/用途/状态（generate.py 与 verify.py 都读它）
├── generate.py          # 合成生成器（纯标准库，无 ffmpeg/numpy/Pillow 依赖）
├── verify.py            # 校验脚本：齐备性 + 参数一致性 + 体积统计
└── frames/              # 生成的素材（按 id 分目录）
    └── <sample_id>/
        └── frame_0001.png ... frame_NNNN.png
```

## 2. 命名规范

**样本 ID**：`gf_<RES>_<CATEGORY>_<VARIANT>`
- `<RES>`：`720p` / `1080p` / `4k`（逻辑分辨率标签）
- `<CATEGORY>`：`solid`(纯色) / `colorref`(色彩参考) / `extreme`(极端场景) / `motion`(运动) / `codec`(编码类)
- `<VARIANT>`：具体变体，如 `black` `white` `smptebars` `stripes_hd` `texture_fine` `mandelbrot` `gradient` `motion_block` `h264` `hevc` `vfr` `rot90` `with_audio`

**帧文件**：`frame_%04d.png`（零填充 4 位，从 1 开始），与 `ffmpeg -f image2` 的 `frame_%04d.png` 约定一致，便于后续用 ffmpeg 直接串流比对。

**清单字段**（见 `manifest.toml` 顶部注释）：`id / category / resolution / width / height / fps / frame_count / duration_s / pattern / codec / gop_size / bframes / vfr / rotation / audio / use_case / file_glob / requires / status / note`。

## 3. 复现命令

```bash
# 生成（本机走 python-png 路径；无需 ffmpeg）
python3 tests/golden/generate.py

# 校验（等价 ffprobe：解码 PNG 头核对真实 w/h/位深/帧数 + 体积统计）
python3 tests/golden/verify.py --json
```

`verify.py` 退出码：所有 `built` 样本一致为 0，任一不符为 1；`requires=ffmpeg` 的缺口只报告不计入失败。

## 4. 本机使用的生成路径（重要）

任务要求：若机器无 `ffmpeg`，确认后用 **Python 合成 PNG 序列**并在报告中明说路径。

- 已执行 `which ffmpeg ffprobe` → **均不存在**。
- 因此全部 `built` 样本用 **纯标准库 PNG 合成**（`tests/golden/generate.py`，仅依赖 `zlib/struct/tomllib`，无 numpy/Pillow）。
- `generate.py` 内置可选 `ffmpeg` 分支（`python3 generate.py --ffmpeg`）：安装 ffmpeg 后可为 `requires=ffmpeg` 的样本编码真实 H.264/HEVC（含 B 帧、VFR、旋转、音轨）。**本机未执行该分支。**

## 5. 覆盖维度与验收重点

| 验收维度 | 状态 | 说明 |
|---|---|---|
| 720p / 1080p / 4K 分辨率 | ✅ 已覆盖 | 每档含纯黑/纯白基线 |
| 极端：纯黑 / 纯白 | ✅ 已覆盖 | 三档分辨率 |
| 极端：高动态条纹 | ✅ 已覆盖 | 1080p + 4K，最大局部对比 |
| 极端：细密纹理（棋盘格） | ✅ 已覆盖 | 1080p + 4K |
| 极端：分形 / 平滑渐变 | ✅ 已覆盖 | mandelbrot + gradient |
| 色彩参考：SMPTE 75% 彩条 | ✅ 已覆盖 | 720p + 1080p |
| 运动 / 多帧 seek | ✅ 已覆盖 | `motion_block` 16 帧红块横移 |
| H.264 / HEVC 编码 | ⚠️ 待补 | 需 ffmpeg（见缺口） |
| 长 GOP + B 帧 | ⚠️ 待补 | 容器+编码属性，PNG 无法表达 |
| 可变帧率 (VFR) | ⚠️ 待补 | pts/duration 属性，PNG 无法表达 |
| 旋转 metadata | ⚠️ 待补 | 容器侧属性，PNG 无法表达 |
| 带音轨 | ⚠️ 待补 | 需 ffmpeg 合成音轨 |

## 6. 局限与缺口（合成素材覆盖不了的，需用户提供真实授权素材）

**编码/容器类维度**（H.264/HEVC、B 帧长 GOP、VFR、旋转、音轨）无法用 PNG 序列表达，
已在 `manifest.toml` 的 `uncovered_by_synthesis` 与 6 个 `requires=ffmpeg` 样本中标注。
补全方式二选一：
1. 安装 ffmpeg 后 `python3 generate.py --ffmpeg`（脚本已内置 lavfi 源 + 编码参数）；或
2. 由用户提供**授权**的真实素材放入 `frames/<id>/` 并修订清单（本任务禁止下载网络素材或从用户机器抓取现成视频）。

**合成素材无法替代的真实行为**（需在 README 明确，对应 QA-002/003 后续验收）：
- 真实相机噪声 / 传感器特性（合成帧无噪声模型）
- 真实 VFR 录像的抖动与丢帧模式
- 真实旋转手机拍摄的显示矩阵与裁剪行为
- 真实 HDR/EDR 与 10-bit 素材（需授权 HDR 样片）
- 真实绿幕 / 人像 / 文字场景（合成棋盘格 / 彩条只能近似）
- 真实音频波形与唇形同步（需授权音视频）
- 真实长片（体积与码率波动，需授权或网络下载——本任务禁止）

## 7. 仓库提交策略（已决策）

决策结论（team-lead 拍板，见 `AGENTS.root.md` 例外条款）：
**golden 测试夹具属于「基准/测试资产」，不属于 AGENTS.md 禁止提交的「生成媒体」产物，允许提交。**

- 登记在 `tests/golden/manifest.toml` 中的夹具（含 `frames/`）随仓库提交，CI 通过 `generate.py` + `verify.py` 重建与校验。
- **总体积保持在 10MB 以内**；超过此阈值再讨论是否引入 Git LFS。
- 本库当前实际体积见 verify.py 输出（约 585KB，远低于 10MB 上限），无需 LFS。
