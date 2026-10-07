# pal/ — 平台适配层（INFRA-001 占位骨架）
#
# 各平台子目录分别声明 cq_pal_<platform> 占位 target。
# 真实实现见 PAL 系列任务（Apple: Metal/VT/AVAudioEngine/CoreML/PhotoKit 等）。

add_subdirectory(apple)
add_subdirectory(android)
add_subdirectory(ohos)
