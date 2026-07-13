# TODO

## AI token 额度展示优化（macOS / Windows / 固件已完成）
- [x] 增加 Cursor：外圈 Total，底部 Auto / API，全部展示剩余百分比。
- [x] Claude、Codex、Cursor 无凭据、鉴权失效或首次获取额度失败时不进入设备轮播。
- [x] 三家独立每 2 分钟刷新；15 分钟标记 STALE，6 小时未成功则移出轮播。
- [x] Claude、Codex、Cursor 分别支持手动立即重试，并避免同一家重复并发请求。
- [x] Cursor 仅监测额度，不安装 hooks、不检测工作状态。


## USB 有线直连（macOS / Windows / 固件已完成）
- [x] Windows 桥接接入 v1 二进制帧协议：COM 口扫描/选择、`460800`、状态与控制、CPU/网速数据、桌宠资源分块、刷机串口让渡。
- [x] macOS / Windows 均默认 USB，连续失联后使用现有 WiFi/HTTP 回退。
