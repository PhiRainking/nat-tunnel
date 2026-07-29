'use strict';

const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const TunnelClient = require('./tunnel.js');

let mainWindow = null;
let tunnel = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 520,
    height: 620,
    minWidth: 460,
    minHeight: 500,
    title: 'NatTunnel',
    resizable: true,
    frame: true,
    backgroundColor: '#fafafa',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  mainWindow.setMenuBarVisibility(false);
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// ── 初始化隧道客户端 ──
function initTunnel() {
  tunnel = new TunnelClient();

  // 转发事件到渲染进程
  tunnel.on('status', (state) => {
    if (mainWindow) mainWindow.webContents.send('tunnel:status', state);
  });

  tunnel.on('mapping', (action, info) => {
    if (mainWindow) mainWindow.webContents.send('tunnel:mapping', action, info);
  });

  tunnel.on('connection', (tunnelId, remotePort) => {
    if (mainWindow) mainWindow.webContents.send('tunnel:connection', tunnelId, remotePort);
  });

  tunnel.on('log', (message) => {
    if (mainWindow) mainWindow.webContents.send('tunnel:log', message);
  });
}

// ── IPC 处理 ──
ipcMain.handle('tunnel:connect', (_event, host, port, token) => {
  if (!tunnel) initTunnel();
  tunnel.connect(host, port, token);
  return true;
});

ipcMain.handle('tunnel:disconnect', () => {
  if (tunnel) tunnel.disconnect();
  return true;
});

ipcMain.handle('tunnel:register', (_event, remotePort, localHost, localPort, protocol) => {
  if (!tunnel) return { error: '未连接' };
  tunnel.mappings.set(remotePort, { localHost, localPort, protocol: protocol || 'tcp' });
  tunnel.registerMapping(remotePort, localHost, localPort, protocol || 'tcp');
  return true;
});

ipcMain.handle('tunnel:unregister', (_event, remotePort) => {
  if (!tunnel) return { error: '未连接' };
  tunnel.unregisterMapping(remotePort);
  return true;
});

ipcMain.handle('tunnel:getState', () => {
  if (!tunnel) return 'disconnected';
  return tunnel.state;
});

ipcMain.handle('tunnel:getMappings', () => {
  if (!tunnel) return [];
  const result = [];
  for (const [rp, m] of tunnel.mappings.entries()) {
    result.push({ remotePort: rp, localHost: m.localHost, localPort: m.localPort, protocol: m.protocol || 'tcp' });
  }
  return result;
});

// ── 应用生命周期 ──
app.whenReady().then(() => {
  initTunnel();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (tunnel) tunnel.disconnect();
  if (process.platform !== 'darwin') app.quit();
});
