// 端到端验证: 以 viewer 身份连中继, 统计收到的帧
// 用法: node frame_check.js [ws://127.0.0.1:8900/stream?role=viewer] [秒数默认5]
const WebSocket = require(process.env.NODE_PATH ? 'ws' : '/root/workspace/delta-vision/server/node_modules/ws');
const URL0 = process.argv[2] || 'ws://127.0.0.1:8900/stream?role=viewer';
const SECS = Number(process.argv[3] || 5);

const ws = new WebSocket(URL0, { maxPayload: 8 * 1024 * 1024 });
let n = 0, bytes = 0, t0;
ws.on('open', () => { t0 = Date.now(); console.log('已连接, 开始统计...'); });
ws.on('message', (d, isBinary) => { if (isBinary) { n++; bytes += d.length; } });
setTimeout(() => {
  const dt = (Date.now() - t0) / 1000;
  console.log(`收到 ${n} 帧, ${(bytes/1024/1024).toFixed(1)} MB, 平均 ${(n/dt).toFixed(1)} fps, 单帧 ${(bytes/n/1024).toFixed(0)} KB`);
  ws.close();
  process.exit(n > 0 ? 0 : 1);
}, SECS * 1000);
