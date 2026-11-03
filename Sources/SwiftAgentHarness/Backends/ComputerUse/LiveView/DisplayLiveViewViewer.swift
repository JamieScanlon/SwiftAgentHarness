/// The page a live-view link opens. It reads the token from the URL fragment, which browsers never send, clears it
/// from the address bar, and presents it as the stream's first message.
enum DisplayLiveViewViewer {
    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <title>Live view</title>
    <style>
    :root { color-scheme: light dark; --bg: #f4f4f2; --fg: #1d1d1b; --bar: #e6e5e0; --accent: #b4441e; }
    @media (prefers-color-scheme: dark) { :root { --bg: #141413; --fg: #ecebe6; --bar: #262624; --accent: #e07a52; } }
    html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, sans-serif; }
    body { display: flex; flex-direction: column; }
    #bar { display: flex; gap: 12px; align-items: center; padding: 8px 16px; background: var(--bar); }
    #bar[data-control="true"] #state { color: var(--accent); font-weight: 600; }
    #stage { flex: 1; display: flex; align-items: center; justify-content: center; min-height: 0; padding: 8px; }
    #screen { max-width: 100%; max-height: 100%; object-fit: contain; user-select: none; -webkit-user-select: none; outline: none; }
    #bar[data-control="true"] + #stage #screen { cursor: crosshair; box-shadow: 0 0 0 2px var(--accent); }
    </style>
    </head>
    <body>
    <div id="bar" data-control="false"><span id="label"></span><span id="state">Connecting…</span></div>
    <div id="stage"><img id="screen" alt="Live view of the agent's screen" draggable="false" tabindex="0"></div>
    <script src="viewer.js"></script>
    </body>
    </html>
    """

    static let script = """
    (() => {
      const token = location.hash.slice(1);
      history.replaceState(null, "", location.pathname);
      const bar = document.getElementById("bar");
      const label = document.getElementById("label");
      const state = document.getElementById("state");
      const screen = document.getElementById("screen");
      let control = false, observer = false, width = 0, height = 0, shown = null, ended = false, pendingMove = null;

      const streamURL = new URL("stream", location.href);
      streamURL.protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(streamURL);
      socket.binaryType = "arraybuffer";
      socket.onopen = () => socket.send(JSON.stringify({ type: "auth", token }));
      socket.onclose = () => { if (!ended) state.textContent = "Disconnected. Ask for a new link to watch again."; };

      function setControl(on) {
        if (on === control && state.textContent !== "Connecting…") return;
        control = on;
        bar.dataset.control = String(on);
        state.textContent = on ? "You have control. The agent is paused." : "Watching. View only.";
        if (on) screen.focus();
      }

      function setPaused(paused) {
        state.textContent = paused ? "The user has control. The view is paused until they hand back." : "Watching. View only.";
        if (paused && shown) {
          screen.removeAttribute("src");
          URL.revokeObjectURL(shown);
          shown = null;
        }
      }

      socket.onmessage = (event) => {
        if (typeof event.data === "string") {
          const message = JSON.parse(event.data);
          if (message.type === "status") {
            label.textContent = message.label;
            observer = message.observer === true;
            if (observer) setPaused(message.paused === true); else setControl(message.control);
          }
          if (message.type === "ended") { ended = true; state.textContent = "The session ended."; }
          return;
        }
        const view = new DataView(event.data);
        width = view.getUint32(0);
        height = view.getUint32(4);
        if (!observer) setControl(view.getUint8(8) === 1);
        const next = URL.createObjectURL(new Blob([new Uint8Array(event.data, 9)], { type: "image/jpeg" }));
        const previous = shown;
        shown = next;
        screen.onload = () => { if (previous) URL.revokeObjectURL(previous); };
        screen.src = next;
      };

      function send(message) {
        if (control && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
      }
      function modifiers(event) {
        const list = [];
        if (event.shiftKey) list.push("shift");
        if (event.ctrlKey) list.push("ctrl");
        if (event.altKey) list.push("alt");
        if (event.metaKey) list.push("meta");
        return list;
      }
      function point(event) {
        const rect = screen.getBoundingClientRect();
        return { x: (event.clientX - rect.left) / rect.width * width, y: (event.clientY - rect.top) / rect.height * height };
      }
      const buttons = ["left", "middle", "right"];

      screen.addEventListener("mousedown", (event) => {
        if (!control) return;
        event.preventDefault();
        screen.focus();
        send({ type: "mouse", action: "down", ...point(event), button: buttons[event.button], clickCount: event.detail || 1, modifiers: modifiers(event) });
      });
      screen.addEventListener("mouseup", (event) => {
        if (!control) return;
        event.preventDefault();
        send({ type: "mouse", action: "up", ...point(event), button: buttons[event.button], clickCount: event.detail || 1, modifiers: modifiers(event) });
      });
      screen.addEventListener("mousemove", (event) => {
        if (!control) return;
        const queued = pendingMove !== null;
        pendingMove = { type: "mouse", action: "move", ...point(event), button: event.buttons & 1 ? "left" : undefined, modifiers: modifiers(event) };
        if (!queued) requestAnimationFrame(() => { send(pendingMove); pendingMove = null; });
      });
      screen.addEventListener("wheel", (event) => {
        if (!control) return;
        event.preventDefault();
        send({ type: "wheel", ...point(event), dx: event.deltaX, dy: event.deltaY, modifiers: modifiers(event) });
      }, { passive: false });
      screen.addEventListener("contextmenu", (event) => { if (control) event.preventDefault(); });

      function key(event, action) {
        if (!control) return;
        if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "v") return;
        event.preventDefault();
        let text = null;
        if (action === "down" && !event.ctrlKey && !event.metaKey) {
          if (event.key.length === 1) text = event.key;
          else if (event.key === "Enter") text = "\\r";
        }
        send({ type: "key", action, key: event.key, code: event.code, keyCode: event.keyCode, text, modifiers: modifiers(event) });
      }
      document.addEventListener("keydown", (event) => key(event, "down"));
      document.addEventListener("keyup", (event) => key(event, "up"));
      document.addEventListener("paste", (event) => {
        if (!control) return;
        event.preventDefault();
        const text = event.clipboardData.getData("text/plain");
        if (text) send({ type: "text", text });
      });
    })();
    """
}
