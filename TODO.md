# TODO

## 股票显示页
- 数据源已调研并实测（2026-07-13）：**腾讯行情接口**（主）`http://qt.gtimg.cn/q=sh600519,hk00700,usAAPL` —— 免 key、A股实时、支持 A股/港股/美股批量查询、GBK 编码、`~` 分隔字段；**新浪**（备）`http://hq.sinajs.cn/list=...`（必须带 `Referer: https://finance.sina.com.cn`）；东方财富 `push2.eastmoney.com/api/qt/stock/get` 返回 JSON。故障切换设计可参考 [Ashare](https://github.com/mpquant/Ashare)。
- 方案：桥接端 2s 轮询自选股 → `/stock` 端点或并入 `/status`；设备新增股票页（复用网速页局部刷新套路），涨红跌绿大字 + 名称（中文需 Mac 渲染位图下发，同音乐文字条）；右键菜单/设备网页配置自选股列表。

## USB 有线直连（本轮做了 Mac + 固件，遗留项）
- Windows 桥接串口支持（System.IO.Ports，扫 COM 口 + 同款 #HELLO/#STATUS/#NET 协议）
- 有线模式下的控制通道：镜像/菜单的亮度、屏幕切换走 `#CMD`（固件已支持 display/brightness，桥接端未接）
- 有线模式下音乐页数据（封面/文字条是二进制位图，需分帧或 base64，暂不支持，AUTO 不会自动切音乐页）
- 镜像弹窗在设备无 WiFi 时拉不到精灵图（GET /sprite/*/raw 走 HTTP），显示占位
