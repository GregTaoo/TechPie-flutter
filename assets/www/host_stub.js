// Fake Flutter host: emulates the TechPie bridge (file picking, host actions)
// and blocks the network, so a page can be exercised in DevTools / CDP without
// building the app. Analysis only: uploads are recorded, never sent.
(() => {
  const PNG_1x1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

  window.__hostLog = [];

  // `?engineDate=1` makes this stub report no date picker, so the page opens
  // the webview engine's own chooser instead of the fake host's fixed value.
  const engineDate = /[?&]engineDate=1/.test(location.search);
  const hostLog = window.__hostLog;

  const respond = (payload) => {
    const text = JSON.stringify(payload);
    setTimeout(() => {
      if (typeof window.__techPieHandleBhMobileSdkResponse === 'function') {
        window.__techPieHandleBhMobileSdkResponse(text);
      } else {
        hostLog.push({ kind: 'response-dropped', because: 'no __techPieHandleBhMobileSdkResponse', payload });
      }
    }, 5);
  };

  // The files the host picker would hand back, in the shape the Dart host sends.
  window.__hostPicked = (limit) => {
    const count = Math.max(1, Math.min(Number(limit) || 1, 3));
    return Array.from({ length: count }, (_, index) => ({
      url: '/fake/pick_' + index + '.png',
      path: '/fake/pick_' + index + '.png',
      name: 'pick_' + index + '.png',
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
        msg = { parseError: String(error), raw: String(raw) };
      }
      hostLog.push({ kind: 'toHost', msg });
      if (!msg || msg.type !== 'bh_mobile_sdk') return;
      if (msg.action === 'capabilities') {
        respond({ requestId: msg.requestId, datePicker: !engineDate });
        return;
      }
      if (msg.action === 'pickDate') {
        if (engineDate) {
          respond({ requestId: msg.requestId, unsupported: true });
          return;
        }
        const values = { date: '2026-09-18', time: '08:30', datetime: '2026-09-18 08:30' };
        respond({ requestId: msg.requestId, value: values[msg.mode] || '2026-09-18' });
        return;
      }
      if (msg.action === 'takePhoto') {
        respond({ requestId: msg.requestId, result: window.__hostPicked(msg.limit) });
        return;
      }
      hostLog.push({ kind: 'host-action', action: msg.action });
    },
  };

  // Intercept network so nothing is actually written to campus systems.
  const realFetch = window.fetch.bind(window);
  window.__netLog = [];
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    if (/uploadTempFile|submit|save|do$|\.do/.test(url)) {
      const body = init && init.body;
      window.__netLog.push({
        url,
        method: (init && init.method) || 'GET',
        credentials: init && init.credentials,
        bodyKind: body instanceof FormData ? 'FormData' : typeof body,
        form: body instanceof FormData ? Array.from(body.entries()).map(([k, v]) => [k, v instanceof Blob ? `Blob(${v.type},${v.size}b,name=${v.name})` : String(v).slice(0, 60)]) : String(body || '').slice(0, 300),
      });
      window.__netLog.push({ blocked: true, note: 'NOT SENT (analysis-only)' });
      return Promise.resolve(new Response(JSON.stringify({ success: true, token: '99999999991', datas: {} }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }));
    }
    return realFetch(input, init);
  };
})();
