'use strict';

const net = require('net');
const dgram = require('dgram');
const { EventEmitter } = require('events');

class TunnelClient extends EventEmitter {
  constructor() {
    super();
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.mappings = new Map();      // remotePort -> { localHost, localPort, protocol }
    this.localSockets = new Map();  // tunnelId -> net.Socket
    this.udpSockets = new Map();    // tunnelId -> dgram.Socket
    this.tunnelMap = new Map();     // tunnelId -> remotePort (for UDP routing)
    this.state = 'disconnected';
    this.reconnectTimer = null;
    this.serverHost = '';
    this.serverPort = 7000;
    this.authToken = '';
  }

  // ── 帧协议 ──
  _createFrame(type, payload) {
    const typeByte = Buffer.from([type.charCodeAt(0)]);
    const payloadBuf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');
    const lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32BE(payloadBuf.length, 0);
    return Buffer.concat([typeByte, lenBuf, payloadBuf]);
  }

  _sendControl(obj) {
    if (!this.socket || this.socket.destroyed) return;
    try { this.socket.write(this._createFrame('C', JSON.stringify(obj))); } catch (_) {}
  }

  _sendTcpData(tunnelId, data) {
    if (!this.socket || this.socket.destroyed) return;
    try {
      this.socket.write(this._createFrame('D', Buffer.concat([Buffer.from(tunnelId, 'ascii'), data])));
    } catch (_) {}
  }

  _sendUdpData(tunnelId, data) {
    if (!this.socket || this.socket.destroyed) return;
    try {
      this.socket.write(this._createFrame('U', Buffer.concat([Buffer.from(tunnelId, 'ascii'), data])));
    } catch (_) {}
  }

  _log(msg) {
    const ts = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    const full = `[${ts}] ${msg}`;
    this.emit('log', full);
    console.log(full);
  }

  _setState(state) {
    this.state = state;
    this.emit('status', state);
  }

  // ── 连接服务器 ──
  connect(host, port, token) {
    this.serverHost = host;
    this.serverPort = port || 7000;
    this.authToken = token || 'rainking-tunnel-2024';
    this._setState('connecting');
    this._log(`正在连接 ${host}:${this.serverPort}...`);

    this.socket = new net.Socket();
    this.socket.setKeepAlive(true, 10000);
    this.buffer = Buffer.alloc(0);

    this.socket.connect(this.serverPort, host, () => {
      this._log('TCP 连接已建立，正在认证...');
      this._sendControl({ cmd: 'auth', token: this.authToken });
    });

    this.socket.on('data', (chunk) => this._onData(chunk));

    this.socket.on('close', () => {
      this._log('与服务器的连接已断开');
      this._cleanup();
      this._setState('disconnected');
      this._scheduleReconnect();
    });

    this.socket.on('error', (err) => {
      this._log(`连接错误: ${err.message}`);
      this._cleanup();
      this._setState('error');
      this._scheduleReconnect();
    });
  }

  disconnect() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this._cleanup();
    if (this.socket) { this.socket.destroy(); this.socket = null; }
    this._setState('disconnected');
    this._log('已主动断开连接');
  }

  // ── 注册/注销映射 ──
  registerMapping(remotePort, localHost, localPort, protocol) {
    if (this.state !== 'connected') {
      this._log('未连接到服务器，无法注册映射');
      this.emit('mapping', 'failed', { remotePort, reason: '未连接' });
      return;
    }
    const proto = protocol === 'udp' ? 'udp' : 'tcp';
    this._sendControl({ cmd: 'register', remotePort, localHost, localPort, protocol: proto });
  }

  unregisterMapping(remotePort) {
    this._sendControl({ cmd: 'unregister', remotePort });
    this.mappings.delete(remotePort);
  }

  // ── 数据接收与帧解析 ──
  _onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 5) {
      const type = String.fromCharCode(this.buffer[0]);
      const payloadLen = this.buffer.readUInt32BE(1);
      if (this.buffer.length < 5 + payloadLen) break;
      const payload = this.buffer.slice(5, 5 + payloadLen);
      this.buffer = this.buffer.slice(5 + payloadLen);

      if (type === 'C') {
        try { this._handleControl(JSON.parse(payload.toString('utf8'))); } catch (_) {}
      } else if (type === 'D' && payload.length >= 36) {
        this._handleTcpData(payload);
      } else if (type === 'U' && payload.length >= 36) {
        this._handleUdpData(payload);
      }
    }
  }

  // ── 控制消息处理 ──
  _handleControl(msg) {
    switch (msg.cmd) {
      case 'auth_ok':
        this._setState('connected');
        this._log('认证成功，已连接到服务器');
        for (const [rp, m] of this.mappings.entries()) {
          this._sendControl({
            cmd: 'register', remotePort: rp,
            localHost: m.localHost, localPort: m.localPort, protocol: m.protocol || 'tcp',
          });
        }
        break;

      case 'auth_fail':
        this._log(`认证失败: ${msg.reason}`);
        this.disconnect();
        break;

      case 'registered':
        this._log(`端口 ${msg.remotePort} 映射成功`);
        this.emit('mapping', 'registered', { remotePort: msg.remotePort });
        break;

      case 'register_fail':
        this._log(`端口 ${msg.remotePort} 映射失败: ${msg.reason}`);
        this.mappings.delete(msg.remotePort);
        this.emit('mapping', 'failed', { remotePort: msg.remotePort, reason: msg.reason });
        break;

      case 'unregistered':
        this._log(`端口 ${msg.remotePort} 映射已注销`);
        this.emit('mapping', 'unregistered', { remotePort: msg.remotePort });
        break;

      case 'new_connection':
        this._handleNewTcpConnection(msg.tunnelId, msg.remotePort);
        break;

      case 'new_udp_connection':
        this._handleNewUdpConnection(msg.tunnelId, msg.remotePort);
        break;

      case 'close_connection':
        this._closeLocalTcpConnection(msg.tunnelId);
        break;

      case 'error':
        this._log(`服务器错误: ${msg.reason}`);
        break;
    }
  }

  // ── TCP 隧道处理 ──
  _handleNewTcpConnection(tunnelId, remotePort) {
    const mapping = this.mappings.get(remotePort);
    if (!mapping) { this._log(`收到 TCP 隧道请求但端口 ${remotePort} 未映射`); return; }

    this._log(`TCP 隧道 ${tunnelId.slice(0,8)}: 外部请求 → 本地 ${mapping.localHost}:${mapping.localPort}`);

    const localSocket = new net.Socket();
    localSocket.connect(mapping.localPort, mapping.localHost, () => {
      this.localSockets.set(tunnelId, localSocket);
      this.emit('connection', tunnelId, remotePort);
      localSocket.on('data', (data) => this._sendTcpData(tunnelId, data));
      localSocket.on('close', () => this.localSockets.delete(tunnelId));
      localSocket.on('error', (err) => {
        this._log(`本地 TCP 错误 (${mapping.localHost}:${mapping.localPort}): ${err.message}`);
        this.localSockets.delete(tunnelId);
      });
    });
    localSocket.on('error', (err) => {
      this._log(`无法连接本地 TCP ${mapping.localHost}:${mapping.localPort}: ${err.message}`);
      this._sendControl({ cmd: 'close_connection', tunnelId });
    });
  }

  _closeLocalTcpConnection(tunnelId) {
    const sock = this.localSockets.get(tunnelId);
    if (sock) { sock.destroy(); this.localSockets.delete(tunnelId); }
  }

  _handleTcpData(payload) {
    const tunnelId = payload.slice(0, 36).toString('ascii');
    const data = payload.slice(36);
    const sock = this.localSockets.get(tunnelId);
    if (sock && !sock.destroyed) sock.write(data);
  }

  // ── UDP 隧道处理 ──
  _handleNewUdpConnection(tunnelId, remotePort) {
    const mapping = this.mappings.get(remotePort);
    if (!mapping) { this._log(`收到 UDP 隧道请求但端口 ${remotePort} 未映射`); return; }
    if (this.udpSockets.has(tunnelId)) return; // already established

    this._log(`UDP 隧道 ${tunnelId.slice(0,8)}: 外部请求 → 本地 ${mapping.localHost}:${mapping.localPort}`);

    const udpSocket = dgram.createSocket('udp4');
    this.udpSockets.set(tunnelId, udpSocket);
    this.tunnelMap.set(tunnelId, remotePort);

    udpSocket.on('message', (data) => {
      // Response from local service → forward to server
      this._sendUdpData(tunnelId, data);
    });

    udpSocket.on('error', (err) => {
      this._log(`本地 UDP 错误: ${err.message}`);
      this.udpSockets.delete(tunnelId);
      this.tunnelMap.delete(tunnelId);
    });

    udpSocket.bind(0, () => {
      this.emit('connection', tunnelId, remotePort);
    });
  }

  _handleUdpData(payload) {
    const tunnelId = payload.slice(0, 36).toString('ascii');
    const data = payload.slice(36);
    const udpSock = this.udpSockets.get(tunnelId);
    if (!udpSock) return;

    const remotePort = this.tunnelMap.get(tunnelId);
    const mapping = remotePort ? this.mappings.get(remotePort) : null;
    if (mapping && data.length > 0) {
      udpSock.send(data, mapping.localPort, mapping.localHost);
    }
  }

  // ── 清理 ──
  _cleanup() {
    for (const [, sock] of this.localSockets) {
      if (!sock.destroyed) sock.destroy();
    }
    this.localSockets.clear();
    for (const [, sock] of this.udpSockets) {
      try { sock.close(); } catch (_) {}
    }
    this.udpSockets.clear();
    this.tunnelMap.clear();
  }

  // ── 自动重连 ──
  _scheduleReconnect() {
    if (this.reconnectTimer) return;
    this._log('将在 5 秒后自动重连...');
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.state !== 'connected') {
        this.connect(this.serverHost, this.serverPort, this.authToken);
      }
    }, 5000);
  }
}

module.exports = TunnelClient;
