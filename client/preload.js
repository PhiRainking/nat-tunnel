'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('tunnelAPI', {
  // 连接 / 断开
  connect:     (host, port, token) => ipcRenderer.invoke('tunnel:connect', host, port, token),
  disconnect:  ()                   => ipcRenderer.invoke('tunnel:disconnect'),

  // 端口映射
  register:    (remotePort, localHost, localPort, protocol) =>
    ipcRenderer.invoke('tunnel:register', remotePort, localHost, localPort, protocol),
  unregister:  (remotePort)          => ipcRenderer.invoke('tunnel:unregister', remotePort),

  // 查询状态
  getState:    ()                   => ipcRenderer.invoke('tunnel:getState'),
  getMappings: ()                   => ipcRenderer.invoke('tunnel:getMappings'),

  // 事件监听
  onStatus:     (cb) => ipcRenderer.on('tunnel:status',     (_e, s)   => cb(s)),
  onMapping:    (cb) => ipcRenderer.on('tunnel:mapping',    (_e, a,i) => cb(a,i)),
  onConnection: (cb) => ipcRenderer.on('tunnel:connection', (_e, id,p) => cb(id,p)),
  onLog:        (cb) => ipcRenderer.on('tunnel:log',        (_e, m)   => cb(m)),
});
