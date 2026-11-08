#!/bin/bash
# delta-vision 一键启动: 中继服务 + (可选) 模拟推流
# 用法: ./start.sh         只起中继
#       ./start.sh sim     中继 + 模拟A机(测试用)
cd "$(dirname "$0")"
LAN_IP=$(hostname -I | awk '{print $1}')
[ -z "$LAN_IP" ] && LAN_IP=127.0.0.1

echo "======================================"
echo " delta-vision 中继已就绪"
echo " 本机局域网IP: $LAN_IP"
echo " B机(副机手机/电脑)浏览器打开:"
echo "   本副机: http://127.0.0.1:8900/"
echo "   其他设备: http://$LAN_IP:8900/"
echo " iPad(A机)推流地址:"
echo "   ws://$LAN_IP:8900/stream?role=streamer"
echo "======================================"

cd server
if [ "$1" = "sim" ]; then
  node server.js &
  sleep 1
  cd ../simulator && python3 streamer.py "ws://127.0.0.1:8900/stream?role=streamer"
else
  exec node server.js
fi
