// Minimal Flutter-host stand-in for the TechPie bridge: answers file picks the
// way the Dart host does, and records host actions. Network is NOT blocked, so
// the real upload path can be exercised against a live (or stub) server.
(() => {
  const PNG_1x1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

  window.__hostLog = [];

  // `?engineDate=1` makes this stub report no date picker, so the page opens
  // the webview engine's own chooser instead of the fake host's fixed value.
  const engineDate = /[?&]engineDate=1/.test(location.search);
  window.__hostRespond = (requestId, result, extra) => {
    const text = JSON.stringify(Object.assign({ requestId, result }, extra || {}));
    setTimeout(() => {
      if (typeof window.__techPieHandleBhMobileSdkResponse === 'function') {
        window.__techPieHandleBhMobileSdkResponse(text);
      }
    }, 5);
  };

  window.__hostPicked = (limit) => {
    const count = Math.max(1, Math.min(Number(limit) || 1, 3));
    return Array.from({ length: count }, (_, index) => ({
      url: '/fake/host_pick_' + index + '.png',
      path: '/fake/host_pick_' + index + '.png',
      name: 'host_pick_' + index + '.png',
      mime: 'image/png',
      size: atob(PNG_1x1).length,
      base64: PNG_1x1,
    }));
  };

  window.TechPieBridge = {
    postMessage(raw) {
      let msg;
      try {
        msg = typeof raw === 'string' ? JSON.parse(raw) : raw;
      } catch (error) {
        msg = { parseError: String(error) };
      }
      window.__hostLog.push(msg);
      if (!msg || msg.type !== 'bh_mobile_sdk') return;
      if (msg.action === 'capabilities') {
        // Emulates the in-app host, which shows its own date picker.
        window.__hostRespond(msg.requestId, null, { datePicker: !engineDate });
        return;
      }
      if (msg.action === 'pickDate') {
        if (engineDate) {
          window.__hostRespond(msg.requestId, null, { unsupported: true });
          return;
        }
        const values = { date: '2026-09-18', time: '08:30', datetime: '2026-09-18 08:30' };
        window.__hostRespond(msg.requestId, null, { value: values[msg.mode] || '2026-09-18' });
        return;
      }
      if (msg.action === 'takePhoto') {
        window.__hostRespond(msg.requestId, window.__hostPicked(msg.limit));
        return;
      }
    },
  };

  // Record (never block) requests so the real upload can be observed.
  window.__netLog = [];
  const realFetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    const body = init && init.body;
    if (body instanceof FormData) {
      window.__netLog.push({
        url,
        method: (init && init.method) || 'GET',
        credentials: init && init.credentials,
        form: Array.from(body.entries()).map(([k, v]) => [
          k, v instanceof Blob ? `Blob(${v.type || '?'},${v.size}b,name=${v.name})` : String(v).slice(0, 40),
        ]),
      });
    }
    const pending = realFetch(input, init);
    if (body instanceof FormData) {
      pending.then((response) => window.__netLog.push({ url, status: response.status })).catch(() => {});
    }
    return pending;
  };
})();
