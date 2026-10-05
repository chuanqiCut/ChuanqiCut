# TASK-AIEDIT-004：PAL 网络传输 + LLM 客户端（URLSession / SSE）

```yaml
id:          AIEDIT-004
layer:       SDK
goal:        实现 INetTransport 的 Apple 端传输（JSON POST + SSE 流式）与 ILlmClient 的 OpenAI-compatible 客户端
input:       [AIEDIT-001 契约（ILlmClient/INetTransport 头）, ADR-0016 决策 2/5, SPEC §8]
output:      [pal/apple/net 实现, LLM 客户端实现, 单测（含假服务器）, baselines 回填位]
write_set:   pal/apple/net/*(新: net_transport_apple.{h,mm}, sse_parser.{h,cpp})、
             core/src/ai/llm/openai_client.{h,cpp}(新)、core/tests/test_llm_client.cpp(新)、
             pal/apple/CMakeLists.txt(登记)
read_set:    core/include/cq/ai/llm_client.h, core/include/cq/pal/net.h, .ai/modules/pal-apple.md
deps:        [AIEDIT-001]
acceptance:
  - 假服务器（本地 loopback 测试服）下：非流式 Complete 往返成功；SSE 流式逐 chunk 回调顺序正确、终帧 [DONE] 处理正确；断流/半包/非 200/超时四类异常路径返回明确 status
  - 超时（连接 10s/总 60s [E]）与取消（CancelToken → 立即断连）行为有断言
  - 上行 payload 组装含且仅含：FeatureReport JSON + 消息历史 + 配置；无原始素材路径/内容外泄（断言 payload 快照）
  - 零第三方依赖（仅 URLSession/Foundation）；pal 头零平台类型泄漏
  - ctest -R llm_client 全绿；build_core.sh -Werror 通过
verification:
  - ctest --test-dir build -R llm_client
  - tools/build/build_core.sh --platform=apple
risk:        SSE 解析边界（跨 chunk 的 event 分割）是经典坑 → sse_parser 独立成纯函数 + 模糊测试样例集
parallel:    true（批次 2）
```

## 背景

ADR-0016 决策 2/5：传输在 PAL（Apple 用 URLSession 原生），客户端协议收敛 OpenAI-compatible。core 内的 `openai_client` 是纯 C++（组装/解析/重试），与传输解耦——换供应商不动传输，换平台不动客户端。

## 实现要点

1. `sse_parser` 纯 C++（core 侧可测）：按 `\n\n` 分割 event、`data:` 剥离、跨 chunk 缓冲。
2. 重试策略：网络层错误重试 1 次、HTTP 429 遵循 Retry-After、5xx 不重试直接上抛（由 005 决定降级）。
3. api_key 以 `cq_ai_llm_config` 传入（句柄/引用），实现层不落盘不打印日志（日志脱敏断言）。
4. Objective-C++ 文件（.mm）仅存在于 pal/apple/net/，core 侧零感知。

## 回写

baselines：RTT/首 token 延迟 [E]→实测；pitfalls：SSE/URLSession 后台策略坑。
