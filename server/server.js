// delta-vision 中继服务
// 角色: streamer(A机, 推JPEG帧) -> 服务端广播 -> viewer(B机网页, 收帧+红点检测)
// 用法: node server.js  [端口默认8900]
const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = Number(process.env.PORT || 8900);
const WEB_DIR = path.join(__dirname, '..', 'web');
const MAX_PAYLOAD = 8 * 1024 * 1024; // 8MB 足够单帧JPEG

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let filePath = path.join(WEB_DIR, urlPath === '/' ? 'index.html' : urlPath);
  if (!filePath.startsWith(WEB_DIR)) { res.writeHead(403); return res.end(); }
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    filePath = path.join(WEB_DIR, 'index.html'); // SPA 兜底
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
  fs.createReadStream(filePath).pipe(res);
});

const wss = new WebSocketServer({ server, path: '/stream', maxPayload: MAX_PAYLOAD });
const streamers = new Set();
const viewers = new Set();

function stats() { return { streamers: streamers.size, viewers: viewers.size }; }

function broadcast(roleSet, data, isBinary, from) {
  for (const s of roleSet) {
    if (s === from || s.readyState !== 1) continue;
    try { s.send(data, { binary: isBinary }); } catch (_) {}
  }
}

wss.on('connection', (ws, req) => {
  const role = new URL(req.url, 'http://x').searchParams.get('role') || 'viewer';
  const ip = req.socket.remoteAddress;
  if (role === 'streamer') {
    streamers.add(ws);
    // 握手确认: 服务端主动发 hello, 客户端收到后开始推帧(绕开 iOS sendPing 兼容问题)
    try { ws.send(JSON.stringify({ type: 'hello' })); } catch (_) {}
  } else viewers.add(ws);
  console.log(`[+] ${role} 接入 ${ip}  当前 ${JSON.stringify(stats())}`);

  // 通知 streamer 有几个观众
  broadcast(streamers, JSON.stringify({ type: 'stats', viewers: viewers.size }), false, null);

  let frames = 0;
  ws.on('message', (data, isBinary) => {
    if (role !== 'streamer') return; // viewer 不给服务端推数据
    if (isBinary && ++frames % 120 === 0) console.log(`[帧流] ${ip} 已推 ${frames} 帧`);
    broadcast(viewers, data, isBinary, null); // 转发给所有 B 机
  });

  ws.on('close', (code) => {
    if (role === 'streamer') streamers.delete(ws); else viewers.delete(ws);
    console.log(`[-] ${role} 断开 ${ip} close=${code} 已推帧=${frames} 当前 ${JSON.stringify(stats())}`);
    broadcast(streamers, JSON.stringify({ type: 'stats', viewers: viewers.size }), false, null);
  });

  ws.on('error', () => {});
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`delta-vision 中继已启动: http://0.0.0.0:${PORT}`);
  console.log(`B机打开: http://<本机IP>:${PORT}/   (A机推流地址: ws://<本机IP>:${PORT}/stream?role=streamer)`);
});
