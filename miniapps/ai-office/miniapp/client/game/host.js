// 让 Godot 客户端能请求切换到 MiniApp 的另一个路由。
//
// 关键点：不能直接用 window.top。在 MiniMax 宿主面板里，本页可能嵌在跨源的宿主外壳中，
// 给 window.top.location 赋值既不报错也不生效——页面看起来像"点了没反应"。
// 所以这里向上找最近的**同源**祖先窗口来导航；同源判定失败就退回自己。
(() => {
  const sameOriginAncestor = () => {
    let win = window;
    for (let i = 0; i < 8; i++) {
      let parent;
      try {
        parent = win.parent;
      } catch {
        break;
      }
      if (!parent || parent === win) break;
      let origin;
      try {
        origin = parent.location.origin;
      } catch {
        break; // 跨源：再往上也是跨源，就用当前这一层。
      }
      if (origin !== window.location.origin) break;
      win = parent;
    }
    return win;
  };

  const open = (path) => {
    const target = String(path ?? '');
    if (!target.startsWith('/')) return false;
    try {
      sameOriginAncestor().location.href = target;
    } catch {
      try {
        window.location.href = target;
      } catch {
        return false;
      }
    }
    return true;
  };

  /**
   * 在顶层同源页面打开对话抽屉。游戏跑在 iframe 里，抽屉属于父页面；
   * 父页面没有提供 AIOfficeChat（例如直接打开导出的游戏页）就返回 false，
   * 调用方据此退回游戏自绘的对话面板。
   */
  const openChat = (botId) => {
    const id = String(botId ?? '').trim();
    if (!id) return false;
    let target;
    try {
      target = sameOriginAncestor();
    } catch {
      return false;
    }
    const api = target.AIOfficeChat;
    if (!api || typeof api.open !== 'function') return false;
    try {
      return api.open(id) === true;
    } catch {
      return false;
    }
  };

  window.AIOfficeHost = { open, openChat };
})();
