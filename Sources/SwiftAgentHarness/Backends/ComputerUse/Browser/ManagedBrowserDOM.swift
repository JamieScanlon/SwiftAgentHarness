import Foundation

/// What the page script reports. It runs in an isolated world: page scripts share the DOM but can't reach its
/// functions or state, or patch the built-ins it calls.
struct ManagedBrowserPageSnapshot: Codable, Sendable, Hashable {
    struct Element: Codable, Sendable, Hashable {
        var id: String
        var role: String
        var name: String?
        var value: String?
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var depth: Int
        var focused: Bool?
        var disabled: Bool?
        var checked: Bool?
        var secure: Bool?
        var autocomplete: String?
        var href: String?
        var level: Int?
        var offscreen: Bool?

        var frame: DisplayRect { DisplayRect(x: x, y: y, width: w, height: h) }
    }

    var url: String
    var title: String?
    var scrollX: Double
    var scrollY: Double
    var viewportWidth: Double
    var viewportHeight: Double
    /// DOM mutations seen since the script was installed in this document.
    var mutations: Int
    var focused: String?
    var readyState: String?
    /// Identifies the document; element ids mean nothing in another one.
    var doc: String?
    var elements: [Element]?
    /// Elements found past the cap, and left out.
    var omitted: Int?
}

/// The live state of one element, looked up again before an action on its ref.
struct ManagedBrowserResolvedElement: Codable, Sendable, Hashable {
    var role: String?
    var name: String?
    var x: Double?
    var y: Double?
    var w: Double?
    var h: Double?
    /// The element on top at the element's center is something else.
    var covered: Bool?
    var coveredBy: String?
    var error: String?
    /// For set-value: what the element holds afterwards.
    var value: String?

    var frame: DisplayRect? {
        guard let x, let y, let w, let h else { return nil }
        return DisplayRect(x: x, y: y, width: w, height: h)
    }
}

enum ManagedBrowserDOM {
    static let worldName = "computer-use"

    /// Installs the library once per document in the isolated world. Element ids are stable for the life of the
    /// document, so the same element keeps its ref across observations.
    static let library = #"""
    (() => {
    if (window.__cu) return window.__cu;
    const S = { next: 1, ids: new WeakMap(), els: new Map(), mutations: 0, doc: Math.random().toString(36).slice(2) + Date.now().toString(36) };
    const root = document.documentElement || document;
    new MutationObserver(r => { S.mutations += r.length; })
      .observe(root, { subtree: true, childList: true, attributes: true, characterData: true });
    const TEXT = new Set(['P','LI','TD','TH','DT','DD','BLOCKQUOTE','PRE','CAPTION','FIGCAPTION','LEGEND','LABEL','SPAN','DIV','STRONG','EM','B','I','SMALL','CODE']);
    const clean = s => (s || '').replace(/\s+/g, ' ').trim();
    const idOf = el => {
      let id = S.ids.get(el);
      if (!id) { id = 'e' + (S.next++); S.ids.set(el, id); }
      S.els.set(id, new WeakRef(el));
      return id;
    };
    const ownText = el => Array.from(el.childNodes).some(n => n.nodeType === 3 && n.textContent.trim());
    const roleOf = el => {
      const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
      if (explicit && !['presentation', 'none', 'generic'].includes(explicit)) return explicit;
      const tag = el.tagName;
      switch (tag) {
        case 'A': return el.hasAttribute('href') ? 'link' : null;
        case 'BUTTON': case 'SUMMARY': return 'button';
        case 'INPUT': {
          const t = (el.type || 'text').toLowerCase();
          if (t === 'hidden') return null;
          if (['button', 'submit', 'reset', 'image', 'file', 'color'].includes(t)) return 'button';
          if (t === 'checkbox') return 'checkbox';
          if (t === 'radio') return 'radio';
          if (t === 'range') return 'slider';
          if (t === 'number') return 'spinbutton';
          if (t === 'search') return 'searchbox';
          return 'textbox';
        }
        case 'SELECT': return el.multiple ? 'listbox' : 'combobox';
        case 'TEXTAREA': return 'textbox';
        case 'IMG': return clean(el.alt) ? 'img' : null;
        case 'IFRAME': case 'FRAME': return 'iframe';
        case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
      }
      if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
      if (el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.tabIndex >= 0)) return 'clickable';
      if (TEXT.has(tag) && ownText(el)) return 'text';
      return null;
    };
    const nameOf = el => {
      const aria = clean(el.getAttribute('aria-label'));
      if (aria) return aria;
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const text = clean(by.split(/\s+/).map(id => { const n = el.ownerDocument.getElementById(id); return n ? n.innerText || n.textContent : ''; }).join(' '));
        if (text) return text;
      }
      const tag = el.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
        if (['submit', 'button', 'reset'].includes((el.type || '').toLowerCase())) return clean(el.value) || el.type;
        if (el.labels && el.labels.length) {
          const text = clean(Array.from(el.labels).map(l => l.innerText).join(' '));
          if (text) return text;
        }
        return clean(el.placeholder) || clean(el.title) || clean(el.getAttribute('name'));
      }
      if (tag === 'IMG') return clean(el.alt);
      if (tag === 'IFRAME' || tag === 'FRAME') return clean(el.title);
      const text = clean(el.innerText || el.textContent);
      if (text) return text.length > 160 ? text.slice(0, 160) + '…' : text;
      const img = el.querySelector && el.querySelector('img[alt]');
      return clean(el.title) || (img ? clean(img.alt) : '');
    };
    const valueOf = el => {
      const tag = el.tagName;
      if (tag === 'INPUT') {
        const t = (el.type || 'text').toLowerCase();
        if (t === 'password') return el.value ? '(' + el.value.length + ' characters)' : '';
        if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file'].includes(t)) return null;
        return el.value;
      }
      if (tag === 'TEXTAREA') return el.value;
      if (tag === 'SELECT') return Array.from(el.selectedOptions).map(o => clean(o.text)).join(', ');
      if (el.isContentEditable) return clean(el.innerText);
      return null;
    };
    const offsetOf = el => {
      let x = 0, y = 0, win = el.ownerDocument.defaultView;
      while (win && win.frameElement) {
        const f = win.frameElement, r = f.getBoundingClientRect();
        x += r.left + f.clientLeft; y += r.top + f.clientTop;
        win = f.ownerDocument.defaultView;
      }
      return [x, y];
    };
    const deepActive = () => {
      let a = document.activeElement;
      while (a) {
        if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
        if ((a.tagName === 'IFRAME' || a.tagName === 'FRAME')) {
          let d = null; try { d = a.contentDocument; } catch (e) {}
          if (d && d.activeElement && d.activeElement !== d.body) { a = d.activeElement; continue; }
        }
        break;
      }
      return a;
    };
    const deepAt = (x, y) => {
      let doc = document, ox = 0, oy = 0, top = doc.elementFromPoint(x, y);
      while (top) {
        if (top.shadowRoot) {
          const inner = top.shadowRoot.elementFromPoint(x - ox, y - oy);
          if (inner && inner !== top) { top = inner; continue; }
        }
        if (top.tagName === 'IFRAME' || top.tagName === 'FRAME') {
          let d = null; try { d = top.contentDocument; } catch (e) {}
          if (d) {
            const r = top.getBoundingClientRect();
            ox += r.left + top.clientLeft; oy += r.top + top.clientTop;
            const inner = d.elementFromPoint(x - ox, y - oy);
            if (inner) { doc = d; top = inner; continue; }
          }
        }
        break;
      }
      return top;
    };
    const parentOf = n => {
      const p = n.parentNode;
      if (!p) return null;
      if (p.nodeType === 11) return p.host || null;
      if (p.nodeType === 9) return p.defaultView ? p.defaultView.frameElement : null;
      return p;
    };
    const within = (node, el) => {
      for (let n = node; n; n = parentOf(n)) if (n === el) return true;
      return false;
    };
    const page = () => {
      const vv = window.visualViewport;
      const active = deepActive();
      return {
        url: location.href, title: document.title,
        scrollX: vv ? vv.pageLeft : window.scrollX, scrollY: vv ? vv.pageTop : window.scrollY,
        viewportWidth: window.innerWidth, viewportHeight: window.innerHeight,
        mutations: S.mutations, readyState: document.readyState, doc: S.doc,
        focused: active && active !== document.body && active !== document.documentElement ? S.ids.get(active) || null : null,
      };
    };
    const snapshot = max => {
      const out = [], vw = window.innerWidth, vh = window.innerHeight;
      let omitted = 0;
      const active = deepActive();
      const visit = (el, depth, ox, oy) => {
        const style = el.ownerDocument.defaultView.getComputedStyle(el);
        if (style.display === 'none') return;
        let next = depth;
        const role = roleOf(el);
        if (role && style.visibility !== 'hidden' && Number(style.opacity) !== 0) {
          const r = el.getBoundingClientRect();
          if (r.width >= 1 && r.height >= 1) {
            if (out.length >= max) { omitted++; }
            else {
              const x = r.left + ox, y = r.top + oy;
              const e = { id: idOf(el), role, name: nameOf(el), x, y, w: r.width, h: r.height, depth };
              const value = valueOf(el);
              if (value) e.value = value.length > 200 ? value.slice(0, 200) + '…' : value;
              if (el === active) e.focused = true;
              if (el.disabled || el.getAttribute('aria-disabled') === 'true') e.disabled = true;
              if (role === 'checkbox' || role === 'radio' || role === 'switch') e.checked = !!el.checked || el.getAttribute('aria-checked') === 'true';
              if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') e.secure = true;
              const ac = clean(el.getAttribute('autocomplete'));
              if (ac) e.autocomplete = ac.split(' ').pop();
              if (role === 'link' && el.href) e.href = el.href.length > 120 ? el.href.slice(0, 120) + '…' : el.href;
              if (role === 'heading') e.level = Number(el.tagName.slice(1)) || Number(el.getAttribute('aria-level')) || undefined;
              if (y + r.height <= 0 || y >= vh || x + r.width <= 0 || x >= vw) e.offscreen = true;
              out.push(e);
            }
            next = depth + 1;
          }
        }
        if (el.shadowRoot) for (const c of el.shadowRoot.children) visit(c, next, ox, oy);
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          let d = null; try { d = el.contentDocument; } catch (e) {}
          if (d && d.body) {
            const r = el.getBoundingClientRect();
            visit(d.body, next, ox + r.left + el.clientLeft, oy + r.top + el.clientTop);
          }
          return;
        }
        if (el.tagName === 'SELECT' || role === 'img') return;
        for (const c of el.children) visit(c, next, ox, oy);
      };
      if (document.body) visit(document.body, 0, 0, 0);
      const result = page();
      result.elements = out;
      if (omitted) result.omitted = omitted;
      return result;
    };
    const lookup = (id, doc) => {
      if (doc !== S.doc) return null;
      const ref = S.els.get(id), el = ref && ref.deref();
      return el && el.isConnected ? el : null;
    };
    const resolve = (id, doc, scroll) => {
      const el = lookup(id, doc);
      if (!el) return { error: 'gone' };
      if (scroll) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect(), [ox, oy] = offsetOf(el);
      const x = r.left + ox, y = r.top + oy;
      const result = { role: roleOf(el), name: nameOf(el), x, y, w: r.width, h: r.height };
      const top = deepAt(x + r.width / 2, y + r.height / 2);
      if (top && !within(top, el) && !within(el, top)) { result.covered = true; result.coveredBy = roleOf(top) || top.tagName.toLowerCase(); }
      return result;
    };
    const press = (id, doc) => {
      const el = lookup(id, doc);
      if (!el) return { error: 'gone' };
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      el.click();
      return { role: roleOf(el) };
    };
    const focus = (id, doc) => {
      const el = lookup(id, doc);
      if (!el) return { error: 'gone' };
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      el.focus();
      return { role: roleOf(el) };
    };
    const setValue = (id, doc, value) => {
      const el = lookup(id, doc);
      if (!el) return { error: 'gone' };
      const fire = () => {
        el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      el.focus();
      const tag = el.tagName;
      if (tag === 'SELECT') {
        const option = Array.from(el.options).find(o => o.value === value || clean(o.text) === clean(value));
        if (!option) return { error: 'no option ' + JSON.stringify(value) };
        el.value = option.value; fire();
        return { value: clean(option.text) };
      }
      if (tag === 'INPUT' && ['checkbox', 'radio'].includes((el.type || '').toLowerCase())) {
        const want = ['true', 'on', 'yes', '1', 'checked'].includes(value.toLowerCase());
        if (el.checked !== want) el.click();
        return { value: String(el.checked) };
      }
      if (tag === 'INPUT' || tag === 'TEXTAREA') {
        const proto = tag === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        fire();
        return { value: (el.type || '').toLowerCase() === 'password' ? (el.value === value ? value : '') : el.value };
      }
      if (el.isContentEditable) { el.textContent = value; fire(); return { value: el.textContent }; }
      return { error: 'element ' + id + ' does not hold a value' };
    };
    window.__cu = { page, snapshot, resolve, press, focus, setValue };
    return window.__cu;
    })()
    """#

    /// An expression calling one library function with JSON-encoded arguments, returning a JSON string.
    static func call(_ function: String, _ arguments: [String] = []) -> String {
        "JSON.stringify((\(library)).\(function)(\(arguments.joined(separator: ", "))))"
    }

    static func literal(_ string: String) -> String {
        let data = (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The compact text the model reads. Frames stay in the side table.
    static func render(_ snapshot: ManagedBrowserPageSnapshot, observationID: ObservationID) -> String {
        var header = "page"
        if let title = snapshot.title, !title.isEmpty { header += " \(quoted(title))" }
        header += " url=\(snapshot.url) obs=\(observationID)"
        var lines = [header]
        for element in snapshot.elements ?? [] {
            var line = String(repeating: "  ", count: min(element.depth, 12)) + "[\(element.id)] \(element.role)"
            if let level = element.level { line += " \(level)" }
            if let name = element.name, !name.isEmpty { line += " \(quoted(name))" }
            if let value = element.value, !value.isEmpty { line += " value=\(quoted(value))" }
            if let checked = element.checked { line += checked ? " checked" : " unchecked" }
            if element.focused == true { line += " focused" }
            if element.disabled == true { line += " disabled" }
            if let href = element.href { line += " href=\(href)" }
            if element.offscreen == true { line += " offscreen" }
            lines.append(line)
        }
        if let omitted = snapshot.omitted, omitted > 0 {
            lines.append("(\(omitted) more elements not listed; scroll and observe again to see them)")
        }
        return lines.joined(separator: "\n")
    }

    static func elements(_ snapshot: ManagedBrowserPageSnapshot, url: String) -> [String: ElementRef] {
        var elements: [String: ElementRef] = [:]
        for element in snapshot.elements ?? [] {
            elements[element.id] = ElementRef(
                id: element.id,
                role: element.role,
                label: element.name.flatMap { $0.isEmpty ? nil : $0 },
                frame: element.frame,
                url: url,
                isSecureInput: element.secure == true,
                inputPurpose: element.autocomplete,
                depth: element.depth,
                isFocused: element.focused == true
            )
        }
        return elements
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped.replacingOccurrences(of: "\n", with: " "))\""
    }
}
