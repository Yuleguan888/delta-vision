# Delta Vision —— A机推流 / B机雷达 最小闭环

```
A机(游戏机, 免越狱)         中继(Node)           B机(任意浏览器)
ReplayKit录屏  ──WS推JPEG──► server.js ──转发──► 网页雷达 + 红点聚类
模拟端 streamer.py 可代替 A 机做测试
```

## 快速跑通（本机三步）

```bash
# 1. 装依赖
cd server && npm install
pip3 install pillow websockets numpy        # 模拟推流端依赖

# 2. 起中继(后台)
node server.js &

# 3. 起模拟推流端
cd ../simulator && python3 streamer.py &

# 4. 验证帧流
cd ../test && node frame_check.js
# 期望输出: 收到 ~150 帧, ~30 fps

# 5. B机打开
# 手机/平板/电脑浏览器访问 http://<本机IP>:8900/
# 勾选"红点检测"即可看到敌方红点被圆圈标出
```

## 真机联调（iPhone 14 Pro Max / iOS 16.3.1 + 巨魔）

A机已装巨魔 = 永久签名，**不需要 Mac**，云构建出 ipa 直装：

1. 把本目录推到 GitHub 仓库 → Actions 手动触发 `Build IPA`
2. 下载 `DeltaVision-ipa` 制品 → AirDrop/网盘发到 iPhone
3. 巨魔(TrollStore)里点 `+` 导入 ipa 安装 → 打开 DeltaVision
4. 点「模式2 · 应用内推流」→ 系统弹窗允许录屏 + 本地网络
5. 切到游戏 → 副机浏览器开 `http://<中继IP>:8900/` 看雷达
6. 「模式1 · 扩展推流」是备选：若巨魔下扩展能被控制中心识别就用它(后台更稳)

注意事项：
- `serverURL` 默认指向副机手机(192.168.0.254:8900)，副机用电脑时改 `ios/App/App.swift` 和 `ios/StreamExt/SampleHandler.swift` 里的地址
- iPhone 录屏帧率约 30fps，做红点/血条识别够用；游戏内高帧率不受影响
- 手机与中继机需同一 WiFi；异地则中继放 VPS

## 参数调优

- 网页面板滑杆: R/G/B 阈值调红点筛选，格子/每格红点数调聚类灵敏度
- 局域网直连延迟 ~50ms；异地走 VPS 中继 + CF 防护（见防护方案）
- iPad 推流帧率受 ReplayKit 限制约 30fps，识别类辅助（红点/血条/OCR）够用

## 目录

| 路径 | 说明 |
|---|---|
| server/server.js | WS 中继 + 静态面板托管 |
| web/index.html | B机雷达面板(帧显示+红点聚类) |
| simulator/streamer.py | 模拟 A 机(合成对局画面/可推视频文件) |
| ios/SampleHandler.swift | iPad 真机 ReplayKit 推流骨架 |
| test/frame_check.js | 端到端帧流验证 |
