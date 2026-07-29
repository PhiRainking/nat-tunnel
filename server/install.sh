#!/bin/bash
# ============================================
#  NatTunnel Server 一键安装脚本 v1.2
#  支持: Ubuntu / Debian / CentOS / RHEL / Fedora / Arch / Alpine
#  用法: curl -sSL <url> | sudo bash
#  自定义: PORT=7000 ADMIN_PORT=9000 TOKEN=xxx ADMIN_PWD=xxx sudo bash install.sh
# ============================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }

# ---------- 检测系统 ----------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
  OS_LIKE="${ID_LIKE:-$ID}"
else
  OS="unknown"
fi

PKG_MGR=""
case "$OS" in
  ubuntu|debian)           PKG_MGR="apt-get"; INSTALL_CMD="apt-get install -y" ;;
  centos|rhel|fedora|rocky|almalinux|ol)
    if command -v dnf &>/dev/null; then PKG_MGR="dnf"; INSTALL_CMD="dnf install -y"
    else PKG_MGR="yum"; INSTALL_CMD="yum install -y"; fi ;;
  arch|manjaro)            PKG_MGR="pacman"; INSTALL_CMD="pacman -S --noconfirm" ;;
  alpine)                  PKG_MGR="apk"; INSTALL_CMD="apk add --no-cache" ;;
  opensuse*|sles)          PKG_MGR="zypper"; INSTALL_CMD="zypper install -y" ;;
  *)                       PKG_MGR="unknown" ;;
esac

log "检测到系统: $OS ($PKG_MGR)"

# ---------- 配置 ----------
CONTROL_PORT=${PORT:-7000}
ADMIN_PORT=${ADMIN_PORT:-9000}
AUTH_TOKEN=${TOKEN:-rainking-tunnel-2024}
ADMIN_PWD=${ADMIN_PWD:-admin123}
APP_DIR="/opt/nat-tunnel-server"

echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║   NatTunnel Server v1.2 一键安装     ║"
echo "  ║   支持 Ubuntu/Debian/CentOS/Arch...  ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${NC}"

# ---------- 安装 Node.js ----------
if command -v node &>/dev/null; then
  log "Node.js $(node -v) 已安装"
else
  log "安装 Node.js 20.x..."
  case "$PKG_MGR" in
    apt-get)
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs ;;
    dnf|yum)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      $INSTALL_CMD nodejs ;;
    pacman)
      pacman -S --noconfirm nodejs npm ;;
    apk)
      apk add --no-cache nodejs npm ;;
    zypper)
      zypper --non-interactive install nodejs20 || zypper --non-interactive install nodejs ;;
    *)
      log "未知包管理器，尝试使用 nvm 安装 Node.js..."
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install 20
      ;;
  esac
  log "Node.js $(node -v) 安装完成"
fi

# ---------- 创建目录 ----------
mkdir -p "$APP_DIR"

# ---------- 写入 server.js ----------
log "写入服务端代码..."
cat > "$APP_DIR/server.js" << 'SERVEREOF'
'use strict';

const net = require('net');
const dgram = require('dgram');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// ── 加载配置 ──────────────────────────────────────────
const CONFIG_FILE = path.join(__dirname, 'config.json');
let config = {
  controlPort: 7000,
  adminPort: 9000,
  adminToken: 'admin123',
  authToken: 'rainking-tunnel-2024',
  clientTimeout: 30000,
};
try {
  if (fs.existsSync(CONFIG_FILE)) {
    config = { ...config, ...JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')) };
  }
} catch (_) {}

function saveConfig() {
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
}

// ── 全局状态 ──────────────────────────────────────────
const portMappings = new Map(); // remotePort -> { controlSocket, localHost, localPort, protocol }
const tunnels      = new Map(); // tunnelId   -> { visitorSocket, controlSocket, remotePort, isUdp }
const listeners    = new Map(); // remotePort -> net.Server | dgram.Socket
const udpTunnels   = new Map(); // tunnelId   -> { address, port, remotePort }  (for routing UDP replies)

// ── 日志 ──────────────────────────────────────────────
function log(level, msg) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  console.log(`[${ts}] [${level.toUpperCase()}] ${msg}`);
}

// ── 协议帧封装 ────────────────────────────────────────
// 'C' = 控制 JSON    'D' = TCP 数据    'U' = UDP 数据
function createFrame(type, payload) {
  const typeByte = Buffer.from([type.charCodeAt(0)]);
  const payloadBuf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(payloadBuf.length, 0);
  return Buffer.concat([typeByte, lenBuf, payloadBuf]);
}

function sendControl(socket, obj) {
  if (socket.destroyed) return;
  try { socket.write(createFrame('C', JSON.stringify(obj))); } catch (_) {}
}

function sendDataFrame(socket, tunnelId, data) {
  if (socket.destroyed) return;
  try {
    socket.write(createFrame('D', Buffer.concat([Buffer.from(tunnelId, 'ascii'), data])));
  } catch (_) {}
}

function sendUdpDataFrame(socket, tunnelId, data) {
  if (socket.destroyed) return;
  try {
    socket.write(createFrame('U', Buffer.concat([Buffer.from(tunnelId, 'ascii'), data])));
  } catch (_) {}
}

// ── TCP 监听器 ────────────────────────────────────────
function createTcpListener(remotePort, callback) {
  if (listeners.has(remotePort)) {
    if (callback) callback(null);
    return listeners.get(remotePort);
  }
  const srv = net.createServer((visitorSocket) => {
    handleVisitor(visitorSocket, remotePort);
  });
  srv.on('error', (err) => {
    log('error', `TCP 端口 ${remotePort} 监听失败: ${err.message}`);
    listeners.delete(remotePort);
    if (callback) callback(err);
  });
  srv.listen(remotePort, '0.0.0.0', () => {
    log('info', `TCP 端口 ${remotePort} 已开放`);
    listeners.set(remotePort, { type: 'tcp', server: srv });
    if (callback) callback(null);
  });
  return srv;
}

// ── UDP 监听器 ────────────────────────────────────────
function createUdpListener(remotePort, callback) {
  if (listeners.has(remotePort)) {
    if (callback) callback(null);
    return listeners.get(remotePort);
  }
  const sock = dgram.createSocket('udp4');
  sock.on('error', (err) => {
    log('error', `UDP 端口 ${remotePort} 监听失败: ${err.message}`);
    listeners.delete(remotePort);
    if (callback) callback(err);
  });
  sock.on('message', (data, rinfo) => {
    const mapping = portMappings.get(remotePort);
    if (!mapping || mapping.controlSocket.destroyed) return;

    const key = `${rinfo.address}:${rinfo.port}`;
    let tunnelId = [...udpTunnels.entries()].find(([, v]) => v.address === rinfo.address && v.port === rinfo.port && v.remotePort === remotePort)?.[0];
    if (!tunnelId) {
      tunnelId = crypto.randomUUID();
      udpTunnels.set(tunnelId, { address: rinfo.address, port: rinfo.port, remotePort });
      // Notify client to open local UDP socket
      sendControl(mapping.controlSocket, {
        cmd: 'new_udp_connection',
        tunnelId,
        remotePort,
        senderAddress: rinfo.address,
        senderPort: rinfo.port,
      });
    }
    // Update last active time
    const t = udpTunnels.get(tunnelId);
    if (t) t.lastActive = Date.now();
    tunnels.set(tunnelId, { controlSocket: mapping.controlSocket, remotePort, isUdp: true, createdAt: Date.now() });
    sendUdpDataFrame(mapping.controlSocket, tunnelId, data);
  });
  sock.bind(remotePort, '0.0.0.0', () => {
    log('info', `UDP 端口 ${remotePort} 已开放`);
    listeners.set(remotePort, { type: 'udp', socket: sock });
    if (callback) callback(null);
  });
  return sock;
}

// ── 统一监听器创建 ────────────────────────────────────
function createListener(remotePort, protocol, callback) {
  if (protocol === 'udp') {
    return createUdpListener(remotePort, callback);
  }
  return createTcpListener(remotePort, callback);
}

function removeListener(remotePort) {
  const entry = listeners.get(remotePort);
  if (!entry) return;
  if (entry.type === 'udp') {
    entry.socket.close();
  } else {
    entry.server.close();
  }
  listeners.delete(remotePort);
  log('info', `端口 ${remotePort} 已关闭`);
}

// ── TCP 访客连接处理 ──────────────────────────────────
function handleVisitor(visitorSocket, remotePort) {
  const mapping = portMappings.get(remotePort);
  if (!mapping || mapping.controlSocket.destroyed) { visitorSocket.destroy(); return; }

  const tunnelId = crypto.randomUUID();
  const { controlSocket } = mapping;

  tunnels.set(tunnelId, { visitorSocket, controlSocket, remotePort, isUdp: false, createdAt: Date.now() });
  log('info', `TCP 隧道 ${tunnelId.slice(0,8)}: 外部访客 → 端口 ${remotePort}`);
  sendControl(controlSocket, { cmd: 'new_connection', tunnelId, remotePort });

  visitorSocket.on('data', (data) => sendDataFrame(controlSocket, tunnelId, data));
  visitorSocket.on('close', () => {
    sendControl(controlSocket, { cmd: 'close_connection', tunnelId });
    tunnels.delete(tunnelId);
  });
  visitorSocket.on('error', () => tunnels.delete(tunnelId));
  visitorSocket.setTimeout(300000, () => visitorSocket.destroy());
}

// ── 客户端断开清理 ────────────────────────────────────
function cleanupClient(controlSocket) {
  let count = 0;
  for (const [rp, m] of portMappings) {
    if (m.controlSocket === controlSocket) { portMappings.delete(rp); removeListener(rp); count++; }
  }
  for (const [tid, t] of tunnels) {
    if (t.controlSocket === controlSocket) { t.visitorSocket?.destroy(); tunnels.delete(tid); }
  }
  for (const [tid] of udpTunnels) {
    const t = tunnels.get(tid);
    if (t?.controlSocket === controlSocket) { udpTunnels.delete(tid); tunnels.delete(tid); }
  }
  if (count > 0) log('info', `客户端断开，清理了 ${count} 个端口映射`);
}

// ── UDP 超时清理 ──────────────────────────────────────
setInterval(() => {
  const now = Date.now();
  for (const [tid, t] of udpTunnels) {
    if (now - (t.lastActive || 0) > 60000) {
      udpTunnels.delete(tid);
      tunnels.delete(tid);
    }
  }
}, 30000);

// ── 控制连接处理 ──────────────────────────────────────
function handleControl(socket) {
  let authenticated = false;
  let buffer = Buffer.alloc(0);
  const remote = `${socket.remoteAddress}:${socket.remotePort}`;
  socket.setKeepAlive(true, 10000);

  const authTimeout = setTimeout(() => {
    if (!authenticated) { log('warn', `${remote} 认证超时`); socket.destroy(); }
  }, config.clientTimeout);

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 5) {
      const type = String.fromCharCode(buffer[0]);
      const payloadLen = buffer.readUInt32BE(1);
      if (buffer.length < 5 + payloadLen) break;
      const payload = buffer.slice(5, 5 + payloadLen);
      buffer = buffer.slice(5 + payloadLen);
      if (type === 'C') {
        try { handleMessage(JSON.parse(payload.toString())); } catch (_) {}
      } else if (type === 'D' && payload.length >= 36) {
        // TCP data from client local service → visitor
        const tid = payload.slice(0, 36).toString('ascii');
        const t = tunnels.get(tid);
        if (t && !t.isUdp) t.visitorSocket?.write(payload.slice(36));
      } else if (type === 'U' && payload.length >= 36) {
        // UDP data from client local service → sender
        const tid = payload.slice(0, 36).toString('ascii');
        const ut = udpTunnels.get(tid);
        if (ut) {
          const entry = listeners.get(ut.remotePort);
          if (entry?.type === 'udp') {
            entry.socket.send(payload.slice(36), ut.port, ut.address);
          }
        }
      }
    }
  });

  function handleMessage(msg) {
    if (!authenticated && msg.cmd !== 'auth') return;
    switch (msg.cmd) {
      case 'auth':
        if (msg.token === config.authToken) {
          authenticated = true; clearTimeout(authTimeout);
          sendControl(socket, { cmd: 'auth_ok' });
          log('info', `客户端 ${remote} 认证成功`);
        } else {
          sendControl(socket, { cmd: 'auth_fail', reason: '令牌无效' });
          setTimeout(() => socket.destroy(), 500);
        }
        break;
      case 'register': {
        const { remotePort, localHost, localPort, protocol } = msg;
        const proto = protocol === 'udp' ? 'udp' : 'tcp';
        if (portMappings.has(remotePort)) {
          sendControl(socket, { cmd: 'register_fail', remotePort, reason: '端口已被占用' });
          return;
        }
        portMappings.set(remotePort, { controlSocket: socket, localHost, localPort, protocol: proto });
        createListener(remotePort, proto, (err) => {
          if (err) {
            portMappings.delete(remotePort);
            sendControl(socket, { cmd: 'register_fail', remotePort, reason: `端口监听失败: ${err.message}` });
          } else {
            sendControl(socket, { cmd: 'registered', remotePort });
            log('info', `映射 [${proto.toUpperCase()}]: :${remotePort} → ${localHost}:${localPort}`);
          }
        });
        break;
      }
      case 'unregister': {
        const { remotePort } = msg;
        if (portMappings.get(remotePort)?.controlSocket === socket) {
          portMappings.delete(remotePort); removeListener(remotePort);
          sendControl(socket, { cmd: 'unregistered', remotePort });
        }
        break;
      }
    }
  }

  socket.on('close', () => { log('info', `客户端 ${remote} 断开`); cleanupClient(socket); });
  socket.on('error', () => cleanupClient(socket));
}

// ═══════════════════════════════════════════════════
//  管理面板 (HTTP)
// ═══════════════════════════════════════════════════

function respondJSON(res, data, code = 200) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(data));
}

function getStats() {
  const mappings = [];
  for (const [rp, m] of portMappings) {
    mappings.push({ remotePort: rp, localHost: m.localHost, localPort: m.localPort, protocol: m.protocol || 'tcp' });
  }
  return {
    controlPort: config.controlPort,
    authToken: config.authToken,
    adminPort: config.adminPort,
    activeClients: new Set([...portMappings.values()].map(m => m.controlSocket)).size,
    mappings,
    activeTunnels: tunnels.size,
    uptime: Math.floor(process.uptime()),
  };
}

const ADMIN_HTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>NatTunnel 管理面板</title>
<style>
:root{--bg:#fafafa;--card:#fff;--border:#e5e5e5;--text:#1a1a1a;--text2:#888;--green:#22c55e;--red:#ef4444;--radius:6px}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Inter','Microsoft YaHei',sans-serif;background:var(--bg);color:var(--text);font-size:13px;line-height:1.5}
.app{max-width:600px;margin:0 auto;padding:24px 20px}
.header{display:flex;align-items:baseline;gap:10px;margin-bottom:20px}
.header h1{font-size:22px;font-weight:600}
.header span{color:var(--text2);font-size:12px;margin-left:auto}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:16px;margin-bottom:12px}
.card-title{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;color:var(--text2);margin-bottom:12px}
.row{display:flex;align-items:center;padding:8px 0;border-bottom:1px solid var(--border)}
.row:last-child{border-bottom:none}
.row .label{color:var(--text2);width:100px;flex-shrink:0}
.row .value{font-weight:500;flex:1}
.badge{font-size:11px;padding:2px 10px;border-radius:10px;border:1px solid var(--border)}
.badge.online{color:var(--green);border-color:var(--green)}
.form-row{display:flex;align-items:center;gap:8px;margin-top:8px}
.form-row label{font-size:12px;color:var(--text2);min-width:70px}
input[type=text],input[type=number],input[type=password],select{flex:1;padding:6px 10px;border:1px solid var(--border);border-radius:var(--radius);font-size:13px;font-family:inherit;background:var(--bg);outline:none}
input:focus,select:focus{border-color:var(--text)}
.btn{padding:6px 14px;border:1px solid var(--border);border-radius:var(--radius);font-size:12px;font-family:inherit;cursor:pointer;background:var(--card);color:var(--text)}
.btn-primary{background:var(--text);color:#fff;border-color:var(--text)}
.btn-primary:hover{background:#333}
.btn-danger{color:var(--red);border-color:var(--red)}
.btn-danger:hover{background:#fef2f2}
.toast{position:fixed;top:16px;right:16px;padding:10px 18px;border-radius:var(--radius);font-size:12px;background:var(--text);color:#fff;opacity:0;transition:opacity .3s;z-index:100}
.toast.show{opacity:1}
.toast.error{background:var(--red)}
.mapping-item{display:flex;align-items:center;padding:6px 10px;background:var(--bg);border-radius:var(--radius);margin-bottom:4px;font-size:12px;gap:8px}
.mapping-item .arrow{color:var(--text2)}
.proto-tag{font-size:10px;padding:1px 6px;border-radius:3px;border:1px solid var(--border);color:var(--text2);text-transform:uppercase}
</style>
</head>
<body>
<div class="app">
<div class="header"><h1>NatTunnel</h1><span>管理面板</span><span id="uptime" style="color:var(--text2);font-size:11px"></span></div>

<div class="card">
<div class="card-title">服务器状态</div>
<div class="row"><span class="label">控制端口</span><span class="value" id="s-controlPort">-</span></div>
<div class="row"><span class="label">在线客户端</span><span class="value"><span class="badge" id="s-clients">0</span></span></div>
<div class="row"><span class="label">活跃映射</span><span class="value" id="s-mappings">0</span></div>
<div class="row"><span class="label">活跃隧道</span><span class="value" id="s-tunnels">0</span></div>
</div>

<div class="card">
<div class="card-title">端口映射列表</div>
<div id="mappingList" style="color:var(--text2);font-size:12px;text-align:center;padding:12px 0">暂无映射</div>
</div>

<div class="card">
<div class="card-title">修改认证令牌</div>
<div class="form-row"><label>新令牌</label><input id="newToken" type="text" placeholder="输入新的认证令牌"><button class="btn btn-primary" onclick="updateToken()">保存</button></div>
<p style="color:var(--text2);font-size:11px;margin-top:6px">客户端连接时需使用此令牌，修改后即时生效</p>
</div>

<div class="card">
<div class="card-title">修改管理密码</div>
<div class="form-row"><label>新密码</label><input id="newAdminPwd" type="password" placeholder="输入新的管理密码"><button class="btn btn-primary" onclick="updateAdmin()">保存</button></div>
<p style="color:var(--text2);font-size:11px;margin-top:6px">用于登录此管理面板</p>
</div>

<div class="card">
<div class="card-title">重启服务</div>
<p style="color:var(--text2);font-size:12px;margin-bottom:10px">修改控制端口后需要重启才能生效</p>
<button class="btn btn-danger" onclick="restart()">重启服务</button>
</div>
</div>
<div id="toast" class="toast"></div>

<script>
let TOKEN = '';
function toast(msg, err) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.className = 'toast' + (err ? ' error' : '') + ' show';
  setTimeout(() => t.className = 'toast', 2000);
}
async function api(method, path, body) {
  const opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (TOKEN) opts.headers['X-Admin-Token'] = TOKEN;
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error((await r.json()).error || r.statusText);
  return r.json();
}
async function refresh() {
  try {
    const s = await api('GET', '/api/stats');
    document.getElementById('s-controlPort').textContent = s.controlPort;
    document.getElementById('s-clients').textContent = s.activeClients;
    document.getElementById('s-clients').className = 'badge ' + (s.activeClients > 0 ? 'online' : '');
    document.getElementById('s-mappings').textContent = s.mappings.length;
    document.getElementById('s-tunnels').textContent = s.activeTunnels;
    document.getElementById('uptime').textContent = '运行 ' + Math.floor(s.uptime / 60) + ' 分钟';
    const list = document.getElementById('mappingList');
    if (s.mappings.length === 0) {
      list.innerHTML = '<div style="color:var(--text2);font-size:12px;text-align:center;padding:12px 0">暂无映射</div>';
    } else {
      list.innerHTML = s.mappings.map(m =>
        '<div class="mapping-item"><span class="proto-tag">' + (m.protocol||'tcp').toUpperCase() + '</span><span>:' + m.remotePort + '</span><span class="arrow">→</span><span style="color:var(--text2)">' + m.localHost + ':' + m.localPort + '</span></div>'
      ).join('');
    }
  } catch (e) { if (e.message.includes('401')) location.reload(); }
}
async function updateToken() {
  const v = document.getElementById('newToken').value.trim();
  if (!v) return toast('请输入新令牌', true);
  try { await api('POST', '/api/config', { authToken: v }); toast('令牌已更新'); document.getElementById('newToken').value = ''; refresh(); }
  catch (e) { toast(e.message, true); }
}
async function updateAdmin() {
  const v = document.getElementById('newAdminPwd').value.trim();
  if (!v) return toast('请输入新密码', true);
  try { await api('POST', '/api/config', { adminToken: v }); toast('管理密码已更新'); document.getElementById('newAdminPwd').value = ''; }
  catch (e) { toast(e.message, true); }
}
async function restart() {
  if (!confirm('确定要重启服务吗？所有客户端将断开。')) return;
  try { await api('POST', '/api/restart'); toast('正在重启...'); }
  catch (e) { toast(e.message, true); }
}
(async () => {
  TOKEN = sessionStorage.getItem('admin_token') || '';
  if (!TOKEN) {
    TOKEN = prompt('请输入管理密码');
    if (!TOKEN) { document.body.innerHTML = '<div style="text-align:center;padding:40px;color:#888">需要管理密码</div>'; return; }
  }
  try {
    await api('GET', '/api/stats');
    sessionStorage.setItem('admin_token', TOKEN);
  } catch (e) {
    sessionStorage.removeItem('admin_token');
    if (e.message.includes('401')) { alert('密码错误'); location.reload(); }
    else document.body.innerHTML = '<div style="text-align:center;padding:40px;color:#888">连接失败</div>';
    return;
  }
  refresh();
  setInterval(refresh, 5000);
})();
</script>
</body>
</html>`;

function startAdminServer() {
  const adminServer = http.createServer((req, res) => {
    const token = req.headers['x-admin-token'] || '';
    const isAuth = token === config.adminToken && config.adminToken.length > 0;

    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Admin-Token');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

    const url = new URL(req.url, 'http://localhost');

    if (url.pathname.startsWith('/api/') && !isAuth) {
      return respondJSON(res, { error: '未授权' }, 401);
    }

    try {
      if (req.method === 'GET' && url.pathname === '/api/stats') {
        return respondJSON(res, getStats());
      }
      if (req.method === 'GET' && url.pathname === '/api/config') {
        return respondJSON(res, { controlPort: config.controlPort, authToken: config.authToken, adminPort: config.adminPort });
      }
      if (req.method === 'POST' && url.pathname === '/api/config') {
        let body = '';
        req.on('data', d => body += d);
        req.on('end', () => {
          try {
            const update = JSON.parse(body);
            let changed = false;
            if (update.authToken !== undefined) { config.authToken = String(update.authToken); log('info', '管理面板: 令牌已更新'); changed = true; }
            if (update.adminToken !== undefined) { config.adminToken = String(update.adminToken); log('info', '管理面板: 管理密码已更新'); changed = true; }
            if (update.controlPort !== undefined) { config.controlPort = parseInt(update.controlPort); log('info', '管理面板: 控制端口更改为 ' + config.controlPort); changed = true; }
            if (changed) saveConfig();
            respondJSON(res, { ok: true });
          } catch (e) { respondJSON(res, { error: '无效的 JSON' }, 400); }
        });
        return;
      }
      if (req.method === 'POST' && url.pathname === '/api/restart') {
        respondJSON(res, { ok: true, message: '正在重启...' });
        log('info', '管理面板触发重启');
        setTimeout(() => process.exit(0), 500);
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(ADMIN_HTML);
    } catch (e) { respondJSON(res, { error: e.message }, 500); }
  });

  adminServer.listen(config.adminPort, '0.0.0.0', () => {
    log('info', '管理面板: http://0.0.0.0:' + config.adminPort);
    log('info', '管理密码: ' + config.adminToken);
  });
}

// ═══════════════════════════════════════════════════
//  启动
// ═══════════════════════════════════════════════════

const controlServer = net.createServer(handleControl);

controlServer.listen(config.controlPort, '0.0.0.0', () => {
  console.log('');
  console.log('  ╔══════════════════════════════════════╗');
  console.log('  ║   NatTunnel Server v1.2.0           ║');
  console.log('  ║   支持 TCP / UDP 隧道               ║');
  console.log('  ║   控制端口: ' + String(config.controlPort).padEnd(25) + '║');
  console.log('  ║   管理面板: ' + String(config.adminPort).padEnd(25) + '║');
  console.log('  ║   认证令牌: ' + config.authToken.slice(0, 10) + '...' + ' '.repeat(14) + '║');
  console.log('  ╚══════════════════════════════════════╝');
  console.log('');
  startAdminServer();
});

controlServer.on('error', (err) => {
  log('error', '服务启动失败: ' + err.message);
  process.exit(1);
});

process.on('SIGINT', () => {
  for (const [, entry] of listeners) {
    if (entry.type === 'udp') entry.socket.close();
    else entry.server.close();
  }
  controlServer.close(() => process.exit(0));
});

SERVEREOF

# ---------- 写入 config.json ----------
cat > "$APP_DIR/config.json" << EOF
{
  "controlPort": ${CONTROL_PORT},
  "adminPort": ${ADMIN_PORT},
  "adminToken": "${ADMIN_PWD}",
  "authToken": "${AUTH_TOKEN}",
  "clientTimeout": 30000
}
EOF

# ---------- 写入 package.json ----------
cat > "$APP_DIR/package.json" << 'EOF'
{ "name": "nat-tunnel-server", "version": "1.1.0", "main": "server.js" }
EOF

# ---------- 配置 systemd ----------
log "配置 systemd 服务..."
cat > /etc/systemd/system/nat-tunnel.service << EOF
[Unit]
Description=NatTunnel Server - 内网穿透
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/node ${APP_DIR}/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nat-tunnel
systemctl restart nat-tunnel

# ---------- 防火墙 ----------
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
  log "配置 ufw 防火墙..."
  ufw allow ${CONTROL_PORT}/tcp 2>/dev/null || true
  ufw allow ${ADMIN_PORT}/tcp 2>/dev/null || true
  ufw allow 10000:20000/tcp 2>/dev/null || true
  ufw allow 10000:20000/udp 2>/dev/null || true
elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
  log "配置 firewalld 防火墙..."
  firewall-cmd --permanent --add-port=${CONTROL_PORT}/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=${ADMIN_PORT}/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=10000-20000/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=10000-20000/udp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
elif command -v iptables &>/dev/null; then
  log "配置 iptables 防火墙..."
  iptables -I INPUT -p tcp --dport ${CONTROL_PORT} -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport ${ADMIN_PORT} -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 10000:20000 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p udp --dport 10000:20000 -j ACCEPT 2>/dev/null || true
  if command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
else
  log "未检测到防火墙，请手动开放端口: ${CONTROL_PORT}, ${ADMIN_PORT}, 10000-20000"
fi

# ---------- 卸载脚本 ----------
cat > "$APP_DIR/uninstall.sh" << 'UNEOF'
#!/bin/bash
set -e
echo "正在卸载 NatTunnel Server..."
systemctl stop nat-tunnel 2>/dev/null || true
systemctl disable nat-tunnel 2>/dev/null || true
rm -f /etc/systemd/system/nat-tunnel.service
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/nat-tunnel-server
echo "卸载完成。"
UNEOF
chmod +x "$APP_DIR/uninstall.sh"

# ---------- 完成 ----------
sleep 1
IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         安装完成！                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}>>> 请打开浏览器访问管理面板进行配置 <<<${NC}"
echo ""
echo -e "  ${GREEN}管理面板:${NC}  http://${IP}:${ADMIN_PORT}"
echo -e "  ${GREEN}管理密码:${NC}  ${ADMIN_PWD}"
echo ""
echo "  ─────────────────────────────────"
echo "  控制端口:   ${CONTROL_PORT}        (客户端连接)"
echo "  认证令牌:   ${AUTH_TOKEN}     (客户端认证)"
echo "  映射端口:   10000-20000    (可在面板中配置)"
echo ""
echo "  ─────────────────────────────────"
echo -e "  ${CYAN}面板功能:${NC}"
echo "    - 在线修改认证令牌"
echo "    - 在线修改管理密码"
echo "    - 查看在线客户端和映射列表"
echo "    - 重启服务"
echo ""
echo "  ─────────────────────────────────"
echo "  管理命令:"
echo "    systemctl status nat-tunnel     # 查看状态"
echo "    systemctl restart nat-tunnel    # 重启"
echo "    journalctl -u nat-tunnel -f     # 查看日志"
echo "    bash $APP_DIR/uninstall.sh      # 卸载"
