'use strict';

// ── DOM 引用 ──────────────────────────
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

const dom = {
  serverHost:    $('#serverHost'),
  serverPort:    $('#serverPort'),
  authToken:     $('#authToken'),
  btnConnect:    $('#btnConnect'),
  btnDisconnect: $('#btnDisconnect'),
  btnAddMapping: $('#btnAddMapping'),
  statusBadge:   $('#statusBadge'),
  mappingList:   $('#mappingList'),
  logArea:       $('#logArea'),
  modalOverlay:  $('#modalOverlay'),
  modalRemotePort: $('#modalRemotePort'),
  modalProtocol:   $('#modalProtocol'),
  modalLocalHost:  $('#modalLocalHost'),
  modalLocalPort:  $('#modalLocalPort'),
  btnModalConfirm: $('#btnModalConfirm'),
  btnModalCancel:  $('#btnModalCancel'),
};

const API = window.tunnelAPI;

// ── 日志 ──────────────────────────────
const MAX_LOG = 200;
let logLines = [];

function addLog(msg) {
  logLines.push(msg);
  if (logLines.length > MAX_LOG) logLines = logLines.slice(-MAX_LOG);
  dom.logArea.innerHTML = logLines.map(l => `<div class="log-line">${escHtml(l)}</div>`).join('');
  dom.logArea.scrollTop = dom.logArea.scrollHeight;
}

function escHtml(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

// ── 状态徽章 ──────────────────────────
function setStatus(state) {
  dom.statusBadge.className = 'badge ' + state;
  const labels = {
    connected:    '已连接',
    connecting:   '连接中...',
    disconnected: '未连接',
    error:        '错误',
  };
  dom.statusBadge.textContent = labels[state] || state;

  const isConnected = state === 'connected';
  dom.btnConnect.disabled = isConnected || state === 'connecting';
  dom.btnDisconnect.disabled = !isConnected && state !== 'connecting';
  dom.btnAddMapping.disabled = !isConnected;
  dom.serverHost.disabled = isConnected;
  dom.serverPort.disabled = isConnected;
  dom.authToken.disabled = isConnected;
}

// ── 映射列表渲染 ──────────────────────
const mappingRegistry = new Map(); // remotePort -> { localHost, localPort, status }

function renderMappings() {
  if (mappingRegistry.size === 0) {
    dom.mappingList.innerHTML = '<div class="empty-hint">暂无映射，点击「添加」创建</div>';
    return;
  }
  let html = '';
  for (const [rp, m] of mappingRegistry.entries()) {
    const proto = (m.protocol || 'tcp').toUpperCase();
    const statusCls = m.status === 'active' ? 'active' : 'pending';
    html += `
      <div class="mapping-item" data-port="${rp}">
        <span class="status-dot ${statusCls}"></span>
        <span class="proto-tag">${proto}</span>
        <span class="remote">:${rp}</span>
        <span class="arrow">&rarr;</span>
        <span class="local">${escHtml(m.localHost)}:${m.localPort}</span>
        <button class="remove-btn" data-action="remove" data-port="${rp}">&times;</button>
      </div>`;
  }
  dom.mappingList.innerHTML = html;

  // 删除按钮事件
  dom.mappingList.querySelectorAll('[data-action="remove"]').forEach(btn => {
    btn.addEventListener('click', () => {
      const port = parseInt(btn.dataset.port);
      API.unregister(port);
      mappingRegistry.delete(port);
      renderMappings();
      addLog(`注销端口 ${port} 映射`);
    });
  });
}

// ── 弹窗 ──────────────────────────────
function showModal() {
  dom.modalRemotePort.value = '';
  dom.modalLocalHost.value = '127.0.0.1';
  dom.modalLocalPort.value = '';
  dom.modalOverlay.classList.remove('hidden');
  dom.modalRemotePort.focus();
}

function hideModal() {
  dom.modalOverlay.classList.add('hidden');
}

dom.btnAddMapping.addEventListener('click', showModal);
dom.btnModalCancel.addEventListener('click', hideModal);
dom.modalOverlay.addEventListener('click', (e) => {
  if (e.target === dom.modalOverlay) hideModal();
});

dom.btnModalConfirm.addEventListener('click', () => {
  const remotePort = parseInt(dom.modalRemotePort.value);
  const protocol   = dom.modalProtocol.value;
  const localHost  = dom.modalLocalHost.value.trim();
  const localPort  = parseInt(dom.modalLocalPort.value);

  if (!remotePort || !localHost || !localPort) {
    addLog('请填写完整的映射信息');
    return;
  }
  if (remotePort < 1 || remotePort > 65535 || localPort < 1 || localPort > 65535) {
    addLog('端口号范围: 1-65535');
    return;
  }
  if (mappingRegistry.has(remotePort)) {
    addLog(`端口 ${remotePort} 已存在映射`);
    return;
  }

  mappingRegistry.set(remotePort, { localHost, localPort, protocol, status: 'pending' });
  renderMappings();
  API.register(remotePort, localHost, localPort, protocol);
  addLog(`注册映射 [${protocol.toUpperCase()}]: :${remotePort} → ${localHost}:${localPort}`);
  hideModal();
});

// ── 连接/断开 ─────────────────────────
dom.btnConnect.addEventListener('click', () => {
  const host  = dom.serverHost.value.trim();
  const port  = parseInt(dom.serverPort.value) || 7000;
  const token = dom.authToken.value.trim() || 'rainking-tunnel-2024';

  if (!host) {
    addLog('请输入服务器地址');
    return;
  }

  dom.serverHost.value = host;
  dom.serverPort.value = port;
  dom.authToken.value  = token;

  API.connect(host, port, token);
});

dom.btnDisconnect.addEventListener('click', () => {
  API.disconnect();
});

// ── 事件监听 ──────────────────────────
API.onStatus((state) => {
  setStatus(state);
  if (state === 'connected') {
    addLog('已成功连接到服务器');
  } else if (state === 'disconnected') {
    addLog('已断开连接');
    // 标记所有映射为 pending
    for (const [, m] of mappingRegistry) m.status = 'pending';
    renderMappings();
  } else if (state === 'error') {
    addLog('连接出错');
  }
});

API.onMapping((action, info) => {
  if (action === 'registered') {
    const m = mappingRegistry.get(info.remotePort);
    if (m) m.status = 'active';
    else mappingRegistry.set(info.remotePort, { localHost: '?', localPort: '?', status: 'active' });
    renderMappings();
    addLog(`端口 ${info.remotePort} 映射成功`);
  } else if (action === 'failed') {
    mappingRegistry.delete(info.remotePort);
    renderMappings();
    addLog(`端口 ${info.remotePort} 映射失败: ${info.reason}`);
    alert(`端口映射失败\n\n远程端口 ${info.remotePort}\n原因: ${info.reason}`);
  } else if (action === 'unregistered') {
    mappingRegistry.delete(info.remotePort);
    renderMappings();
    addLog(`端口 ${info.remotePort} 已注销`);
  }
});

API.onConnection((tunnelId, remotePort) => {
  addLog(`隧道 ${tunnelId.slice(0,8)}: 新连接 → 端口 ${remotePort}`);
});

API.onLog((msg) => {
  addLog(msg);
});

// ── 键盘快捷键 ────────────────────────
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') hideModal();
  if (e.key === 'Enter' && !dom.modalOverlay.classList.contains('hidden')) {
    dom.btnModalConfirm.click();
  }
});

// ── 初始状态 ──────────────────────────
setStatus('disconnected');
addLog('NatTunnel 客户端已启动');
