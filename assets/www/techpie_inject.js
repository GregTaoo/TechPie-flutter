
(() => {
  window.__techPieBridgeReady = true;
  window.__techPieResolve = window.__techPieResolve || ((value) => value);

  const pending = window.__bhMobileSdkCallbacks =
      window.__bhMobileSdkCallbacks || {};
  let requestSequence = 0;

  // Transport to the Flutter host. WebView2 and WKWebView publish their own,
  // and a plain browser has none — there every host call reports itself
  // unsupported, which is what makes the page-side fallbacks below kick in.
  const nativeTechPieBridge = window.TechPieBridge &&
      typeof window.TechPieBridge.postMessage === 'function'
    ? window.TechPieBridge
    : null;

  if (!nativeTechPieBridge) {
    window.TechPieBridge = window.TechPieBridge || {
      postMessage(message) {
        let messageText;
        try {
          messageText = typeof message === 'string' ? message : JSON.stringify(message);
          if (typeof messageText !== 'string') messageText = String(message);
        } catch (_) {
          messageText = String(message);
        }
        if (window.chrome && window.chrome.webview &&
            typeof window.chrome.webview.postMessage === 'function') {
          return window.chrome.webview.postMessage(messageText);
        }
        if (window.webkit && window.webkit.messageHandlers &&
            window.webkit.messageHandlers.TechPieBridge &&
            typeof window.webkit.messageHandlers.TechPieBridge.postMessage === 'function') {
          return window.webkit.messageHandlers.TechPieBridge.postMessage(messageText);
        }
        throw new Error('TechPieBridge native transport unavailable');
      },
    };
  }

  const postToHost = (payload) => {
    try {
      window.TechPieBridge.postMessage(JSON.stringify(payload));
      return true;
    } catch (_) {
      return false;
    }
  };

  const askHost = (action, payload, options) => new Promise((resolve) => {
    const settings = options || {};
    const requestId = 'bh-' + (++requestSequence);
    pending[requestId] = resolve;
    if (settings.warnAfterMs) {
      setTimeout(() => {
        if (pending[requestId]) {
          console.warn('techpie: ' + action + ' still unanswered (' + requestId + ')');
        }
      }, settings.warnAfterMs);
    }
    if (settings.timeoutMs) {
      setTimeout(() => {
        if (!pending[requestId]) return;
        delete pending[requestId];
        resolve({ unsupported: true, timedOut: true });
      }, settings.timeoutMs);
    }
    const request = Object.assign({ type: 'bh_mobile_sdk', action, requestId }, payload);
    if (!postToHost(request)) {
      delete pending[requestId];
      resolve({ unsupported: true });
    }
  });

  const tellHost = (action, payload) =>
      postToHost(Object.assign({ type: 'bh_mobile_sdk', action }, payload));

  // Whether the page has a host to hand file picks to. Asked once: a plain
  // browser throws inside postMessage, which is the whole answer.
  let hostSupported = null;
  const hostAnswers = () => {
    if (hostSupported === null) {
      hostSupported = postToHost({ type: 'bh_mobile_sdk', action: 'probe' });
    }
    return hostSupported;
  };

  // Some engines — Android WebView and OHOS ArkWeb — do not open their own
  // `<input type=date>` chooser when a script asks, so pages there need the
  // host's picker. Ask once at load: a page that only learns that from a
  // round-trip has already lost the activation its own picker would need.
  const capabilities = { datePicker: null };
  askHost('capabilities', {}, { timeoutMs: 5000 }).then((response) => {
    capabilities.datePicker =
        !!(response && !response.unsupported && response.datePicker !== false);
  });

  window.__techPieHandleBhMobileSdkResponse = (message) => {
    let response;
    try {
      response = typeof message === 'string' ? JSON.parse(message) : message;
    } catch (_) {
      return;
    }
    if (!response || !response.requestId) return;
    const callback = pending[response.requestId];
    if (!callback) return;
    delete pending[response.requestId];
    callback(response);
  };

  const resumeHandlers = [];
  window.__techPieHandleWebviewResume = () => {
    resumeHandlers.slice().forEach((handler) => {
      try {
        handler();
      } catch (_) {
        // a page handler that throws must not stop the others
      }
    });
  };

  // Every file a pick produced, keyed by the URL handed to the page. The
  // upload runs after an async round-trip — by then the native handle is gone
  // and the browser refuses to open a second picker — so the bytes have to be
  // reachable from the page for as long as the page may still upload them.
  const fileStore = new Map();

  const keepFile = (file, aliases) => {
    const url = URL.createObjectURL(file);
    fileStore.set(url, file);
    (aliases || []).forEach((alias) => {
      if (alias) fileStore.set(String(alias), file);
    });
    return url;
  };

  const fileFromBase64 = (base64, name, mime) => {
    const binary = atob(base64 || '');
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return new File([bytes], name, { type: mime });
  };

  const fileFromHostItem = (item) => {
    try {
      return fileFromBase64(
          item.base64,
          item.name || 'upload.bin',
          item.mime || 'application/octet-stream');
    } catch (_) {
      return null;
    }
  };

  // The shape the campus pages read: a handle they can preview and hand back
  // to the upload, plus the byte size they validate against their own limit.
  const entryFromHost = (item) => {
    const file = fileFromHostItem(item);
    if (!file) return null;
    return {
      url: keepFile(file, [item.url, item.path]),
      name: file.name,
      mime: file.type,
      size: file.size,
    };
  };

  const entryFromFile = (file) => ({
    url: keepFile(file),
    name: file.name,
    mime: file.type || 'application/octet-stream',
    size: file.size,
  });

  // Browser-native file chooser, used when no host picker is available: a
  // plain browser, or a platform whose picker the app cannot reach. Resolves
  // with the picked File objects, or an empty array when the user cancels —
  // cancellation arrives as the `cancel` event where supported, and as the
  // window regaining focus without a selection everywhere else.
  const pickFiles = (multiple) => new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.multiple = !!multiple;
    // The adoption listener below must leave this one alone: routing it back
    // through the host would call this function again, forever.
    input.__techPieOwnPicker = true;
    input.style.cssText =
        'position:fixed;left:-10000px;top:0;width:1px;height:1px;opacity:0;';
    let settled = false;
    const settle = (files) => {
      if (settled) return;
      settled = true;
      window.removeEventListener('focus', onFocus);
      if (input.parentNode) input.parentNode.removeChild(input);
      resolve(files);
    };
    const onFocus = () => {
      setTimeout(() => {
        if (!input.files || input.files.length === 0) settle([]);
      }, 1000);
    };
    input.addEventListener('change', () => settle(Array.from(input.files || [])));
    input.addEventListener('cancel', () => settle([]));
    window.addEventListener('focus', onFocus);
    (document.body || document.documentElement).appendChild(input);
    input.click();
  });

  const choose = (source, callback, limit) => {
    const slots = typeof limit === 'number' && limit > 0 ? Math.floor(limit) : 1;
    const finish = (entries) => {
      if (typeof callback === 'function') callback(entries);
    };
    askHost('takePhoto', { source, limit: slots }).then((response) => {
      if (response && !response.unsupported) {
        const result = Array.isArray(response.result) ? response.result : [];
        const entries = [];
        result.forEach((item) => {
          const entry = entryFromHost(item);
          if (entry) entries.push(entry);
        });
        finish(entries);
        return;
      }
      pickFiles(slots > 1).then((files) => finish(files.map(entryFromFile)));
    });
  };

  const takePhoto = (callback, limit) => choose('gallery', callback, limit);
  const takeCamera = (callback, limit) => choose('camera', callback, limit);

  // Dates: the host's picker where the engine has none (Android WebView, OHOS
  // ArkWeb), the engine's own `<input type=date>` chooser everywhere else —
  // WebKitGTK, WebView2 and plain browsers all open theirs, and opening it
  // inside the tap is what keeps the user activation it requires.
  const lastFunction = (args) => {
    for (let index = args.length - 1; index >= 0; index -= 1) {
      if (typeof args[index] === 'function') return args[index];
    }
    return null;
  };

  const dateHints = (args) => {
    const hints = { value: '', min: '', max: '', format: '' };
    args.forEach((arg) => {
      if (typeof arg === 'string') {
        if (!hints.value) hints.value = arg;
        return;
      }
      if (!arg || typeof arg !== 'object') return;
      ['value', 'date', 'current', 'start', 'startDate'].forEach((key) => {
        if (!hints.value && typeof arg[key] === 'string') hints.value = arg[key];
      });
      ['min', 'minDate', 'start'].forEach((key) => {
        if (!hints.min && typeof arg[key] === 'string') hints.min = arg[key];
      });
      ['max', 'maxDate', 'end'].forEach((key) => {
        if (!hints.max && typeof arg[key] === 'string') hints.max = arg[key];
      });
      if (!hints.format && typeof arg.format === 'string') hints.format = arg.format;
    });
    return hints;
  };

  const dateMode = (fallback, hints) => {
    const format = hints.format || '';
    if (/h{1,2}:m{1,2}/i.test(format)) {
      return /y{1,4}/i.test(format) ? 'datetime' : 'time';
    }
    const value = hints.value || '';
    if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(value)) return 'datetime';
    if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return 'date';
    if (/^\d{1,2}:\d{2}/.test(value)) return 'time';
    return fallback;
  };

  const INPUT_TYPES = { date: 'date', time: 'time', datetime: 'datetime-local' };

  const formatPickedValue = (mode, raw) => {
    // `<input type=date>` hands back `yyyy-MM-dd`, `time` back `HH:mm`
    // (optionally with seconds), and `datetime-local` back `yyyy-MM-ddTHH:mm`.
    const match = /^(\d{4}-\d{2}-\d{2})(?:T(\d{2}:\d{2}))?$/.exec(raw || '');
    if (mode === 'time') {
      const time = /(\d{2}:\d{2})/.exec(raw || '');
      return time ? time[1] : '';
    }
    if (!match) return raw || '';
    if (mode === 'datetime') {
      const time = match[2] || '00:00';
      return match[1] + ' ' + time;
    }
    return match[1];
  };

  const pickDateInPage = (mode, hints) => new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = INPUT_TYPES[mode] || 'date';
    if (hints.value) input.value = formatPickedValue(mode, hints.value).replace(' ', 'T');
    if (hints.min) input.min = formatPickedValue(mode, hints.min).replace(' ', 'T');
    if (hints.max) input.max = formatPickedValue(mode, hints.max).replace(' ', 'T');
    input.style.cssText =
        'position:fixed;left:50%;bottom:0;width:1px;height:1px;opacity:0;';
    const settle = (value) => {
      if (input.parentNode) input.parentNode.removeChild(input);
      resolve(value ? formatPickedValue(mode, value) : null);
    };
    input.addEventListener('change', () => settle(input.value));
    input.addEventListener('blur', () => setTimeout(() => settle(input.value), 300));
    (document.body || document.documentElement).appendChild(input);
    if (typeof input.showPicker === 'function') {
      try {
        input.showPicker();
        return;
      } catch (_) {
        // Some engines refuse showPicker without a live gesture; click instead.
      }
    }
    input.click();
  });

  const openPicker = (fallbackMode, args) => {
    const callback = lastFunction(args);
    const hints = dateHints(args);
    const mode = dateMode(fallbackMode, hints);
    const finish = (value) => {
      if (value && typeof callback === 'function') callback(value);
    };
    if (capabilities.datePicker === false) {
      // Known at load: the tap is still live, so the engine's picker can open.
      pickDateInPage(mode, hints).then(finish);
      return;
    }
    askHost('pickDate', {
      mode,
      value: hints.value,
      min: hints.min,
      max: hints.max,
    }, { warnAfterMs: 4000 }).then((response) => {
      if (response && !response.unsupported) {
        finish(response.value);
        return;
      }
      capabilities.datePicker = false;
      pickDateInPage(mode, hints).then(finish);
    });
  };

  const datePicker = (...args) => openPicker('date', args);
  const dateTimePicker = (...args) => openPicker('datetime', args);

  // Pages with their own H5 uploader open the browser's chooser with an
  // <input type=file>. Route that through the host picker as well: the browser
  // chooser needs an activation the page may have lost, and hosts without one
  // leave the input inert, which is a dead upload button. Only inputs that
  // take images are taken over — the host picker is an image picker.
  const IMAGE_EXTENSION = /\.(jpe?g|png|gif|webp|bmp|heic|heif)$/;
  const acceptsOnlyImages = (input) => {
    const accept = String(input.getAttribute('accept') || '').trim();
    if (!accept) return true;
    return accept.split(',').every((token) => {
      const value = token.trim().toLowerCase();
      if (!value || value.startsWith('image/')) return true;
      return IMAGE_EXTENSION.test(value);
    });
  };

  const fillFileInput = (input, files) => {
    try {
      const transfer = new DataTransfer();
      files.forEach((file) => transfer.items.add(file));
      input.files = transfer.files;
    } catch (_) {
      return false;
    }
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };

  const adoptFileInputs = () => {
    document.addEventListener('click', (event) => {
      const input = event.target;
      if (!input || input.tagName !== 'INPUT' || input.type !== 'file') return;
      if (input.__techPieOwnPicker) return;
      if (!hostAnswers() || !acceptsOnlyImages(input)) return;
      event.preventDefault();
      const slots = input.multiple ? 9 : 1;
      askHost('takePhoto', { source: 'gallery', limit: slots }).then((response) => {
        const result = response && !response.unsupported && Array.isArray(response.result)
          ? response.result
          : [];
        const files = result.map(fileFromHostItem).filter(Boolean);
        if (files.length) {
          fillFileInput(input, files);
          return;
        }
        if (response && !response.unsupported) return; // the user cancelled
        pickFiles(slots > 1).then((picked) => fillFileInput(input, picked));
      });
    }, true);
  };

  const appendParams = (form, params) => {
    Object.keys(params || {}).forEach((key) => {
      const value = params[key];
      if (value === undefined || value === null) return;
      if (typeof value === 'object') return;
      form.append(key, String(value));
    });
  };

  // Resolves whatever a page hands the upload back to real bytes: the File
  // objects of a page-side pick, a `blob:`/`data:` handle, or the URL this
  // script gave the page when the host did the picking.
  const resolveEntry = (entry) => {
    const fromHandle = (handle) => {
      const known = fileStore.get(String(handle));
      if (known) return Promise.resolve(known);
      return fetch(String(handle), { credentials: 'include' })
          .then((response) => (response.ok ? response.blob() : null))
          .catch(() => null);
    };

    let source;
    try {
      if (entry instanceof Blob) {
        source = Promise.resolve(entry);
      } else if (typeof entry === 'string' || typeof entry === 'number') {
        source = fromHandle(entry);
      } else if (entry && typeof entry === 'object') {
        if (entry.base64) {
          source = Promise.resolve(fileFromBase64(
              entry.base64,
              entry.name || 'upload.bin',
              entry.mime || 'application/octet-stream'));
        } else if (entry.url || entry.path) {
          source = fromHandle(entry.url || entry.path);
        } else {
          source = Promise.resolve(null);
        }
      } else {
        source = Promise.resolve(null);
      }
    } catch (_) {
      source = Promise.resolve(null);
    }

    return source.then((blob) => {
      if (!blob) return null;
      const name = (blob instanceof File && blob.name) ||
          (entry && entry.name) || '';
      return { blob, name };
    });
  };

  const resolveEntries = (filePaths) => {
    const entries = Array.isArray(filePaths) ? filePaths : [filePaths];
    return Promise.all(entries.map(resolveEntry))
        .then((resolved) => resolved.filter(Boolean));
  };

  const upload = (server, entries, params, callback) => {
    resolveEntries(entries).then((files) => {
      // One `{code, response}` per upload, the shape the campus SDK reads.
      const fail = (error) => {
        if (typeof callback === 'function') {
          callback([{ code: 0, response: JSON.stringify({ success: false, error }) }]);
        }
      };
      if (!server) return fail('server 地址未指定');
      if (!files.length) return fail('没有可供上传的文件');

      const form = new FormData();
      appendParams(form, params);
      files.forEach((item, index) => {
        form.append('files[]', item.blob, item.name || ('upload_' + index + '.bin'));
      });
      return fetch(server, {
        method: 'POST',
        body: form,
        credentials: 'include',
        headers: {
          Accept: 'application/json, text/javascript, */*; q=0.01',
          'X-Requested-With': 'XMLHttpRequest',
        },
      }).then((response) => response.text().then((text) => {
        if (typeof callback === 'function') {
          callback([{ code: response.status, response: text }]);
        }
      })).catch((error) => fail(String(error)));
    });
  };

  // The host API delivers its callback before the extra options, and callers
  // nest the body fields under `params` — see bh-mobile-sdk's own upload
  // bridge. Both shapes end up as form fields of the same request.
  const uploadToServer = (server, filePaths, callback, config) => {
    const options = config || {};
    const params = options.params && typeof options.params === 'object'
      ? options.params
      : options;
    upload(server, filePaths, params, callback);
  };

  const makeFileToken = () => {
    const S4 = () => (((1 + Math.random()) * 0x10000) | 0).toString(32);
    const scope = S4() + S4() + S4() + S4() + S4() + S4() + S4() + S4() +
        String(parseInt(Math.random() * 100, 10));
    return { scope, token: scope + 1 };
  };

  // Mirrors the campus SDK's own implementation: the attachment endpoint is
  // what makes the upload show up under the file token, which is how the
  // campus pages render their thumbnails and read the final token back for
  // submission.
  const uploadToEMAP = (server, files, config) => {
    const options = config || {};
    if (!server) return Promise.reject('server 地址未指定');
    const list = Array.isArray(files) ? files : [files];
    if (!list.length) return Promise.reject('没有可供上传的文件');

    const generated = options.token
      ? { scope: options.token.substring(0, options.token.length - 1), token: options.token }
      : makeFileToken();
    const params = Object.assign({}, options, {
      scope: generated.scope,
      fileToken: generated.token,
      storeId: 'image',
    });
    delete params.token;

    return new Promise((resolve, reject) => {
      uploadToServer(
        server + '/sys/emapcomponent/file/uploadTempFileAsAttachment.do',
        list,
        (results) => {
          const responses = [];
          for (let index = 0; index < results.length; index += 1) {
            const item = results[index];
            if (item.code !== 200) return reject(results);
            let response;
            try {
              response = typeof item.response === 'string'
                ? JSON.parse(item.response)
                : item.response;
            } catch (_) {
              return reject(results);
            }
            if (!response || !response.success) return reject(results);
            responses.push(response);
          }
          return resolve({ success: true, token: generated.token, data: responses });
        },
        { params },
      );
    });
  };

  const openUrl = (url) => {
    if (!url) return;
    tellHost('openUrl', { url: String(url) });
  };

  // Fully page-side image viewer: no host round-trip, so it works in every
  // browser engine the webviews run on. Same-origin attachment URLs keep the
  // existing session cookies, so no extra credentials are needed.
  const preViewImages = (items, startIndex) => {
    const list = (Array.isArray(items) ? items : [items])
      .map((entry) => (typeof entry === 'string' ? { url: entry } : entry))
      .filter((entry) => entry && entry.url);
    if (!list.length) return;

    const existing = document.querySelector('.techpie-image-viewer');
    if (existing && existing.parentNode) existing.parentNode.removeChild(existing);

    let current = Number(startIndex);
    if (!Number.isFinite(current) || current < 0 || current >= list.length) current = 0;

    const root = document.createElement('div');
    root.className = 'techpie-image-viewer';
    root.style.cssText =
        'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,.92);' +
        'display:flex;align-items:center;justify-content:center;touch-action:none;' +
        '-webkit-user-select:none;user-select:none;';

    const image = document.createElement('img');
    image.style.cssText = 'max-width:100%;max-height:100%;object-fit:contain;';

    const makeLabel = (cssText) => {
      const node = document.createElement('div');
      node.style.cssText = cssText;
      return node;
    };
    const counter = makeLabel(
        'position:absolute;top:14px;left:16px;color:#f5f5f5;font-size:13px;' +
        'opacity:.85;pointer-events:none;');
    const caption = makeLabel(
        'position:absolute;left:0;right:0;bottom:0;padding:18px 56px;color:#f5f5f5;' +
        'font-size:13px;line-height:1.5;text-align:center;pointer-events:none;' +
        'text-shadow:0 1px 3px rgba(0,0,0,.8);');

    const closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.textContent = '\u00d7';
    closeButton.style.cssText =
        'position:absolute;top:8px;right:8px;width:40px;height:40px;border:0;' +
        'border-radius:50%;background:rgba(255,255,255,.16);color:#fff;font-size:26px;' +
        'line-height:1;padding:0;cursor:pointer;';

    const makeArrow = (glyph, side, delta) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = glyph;
      button.style.cssText =
          'position:absolute;top:50%;transform:translateY(-50%);' +
          (side === 'left' ? 'left:8px;' : 'right:8px;') +
          'width:44px;height:44px;border:0;border-radius:50%;' +
          'background:rgba(255,255,255,.16);color:#fff;font-size:24px;line-height:1;' +
          'padding:0;cursor:pointer;';
      button.addEventListener('click', (event) => {
        event.stopPropagation();
        step(delta);
      });
      return button;
    };

    function render() {
      const entry = list[current];
      image.alt = entry.desc || '';
      image.src = entry.url;
      caption.textContent = entry.desc || '';
      counter.textContent = list.length > 1 ? (current + 1) + ' / ' + list.length : '';
    }

    function step(delta) {
      current = (current + delta + list.length) % list.length;
      render();
    }

    function close() {
      document.removeEventListener('keydown', onKeyDown, true);
      if (root.parentNode) root.parentNode.removeChild(root);
    }

    function onKeyDown(event) {
      if (event.key === 'Escape') close();
      else if (event.key === 'ArrowLeft' && list.length > 1) step(-1);
      else if (event.key === 'ArrowRight' && list.length > 1) step(1);
    }

    image.addEventListener('error', () => {
      caption.textContent = '图片加载失败';
    });
    closeButton.addEventListener('click', (event) => {
      event.stopPropagation();
      close();
    });
    root.addEventListener('click', (event) => {
      if (event.target === root) close();
    });

    let pointerStart = null;
    if (window.PointerEvent) {
      root.addEventListener('pointerdown', (event) => {
        pointerStart = event.clientX;
      });
      root.addEventListener('pointerup', (event) => {
        if (pointerStart === null) return;
        const delta = event.clientX - pointerStart;
        pointerStart = null;
        if (Math.abs(delta) > 40 && list.length > 1) step(delta < 0 ? 1 : -1);
      });
    }

    root.appendChild(image);
    root.appendChild(counter);
    root.appendChild(caption);
    root.appendChild(closeButton);
    if (list.length > 1) {
      root.appendChild(makeArrow('\u2039', 'left', -1));
      root.appendChild(makeArrow('\u203a', 'right', 1));
    }
    document.addEventListener('keydown', onKeyDown, true);
    (document.body || document.documentElement).appendChild(root);
    render();
  };

  // The campus pages render several radio fields that all hardcode
  // name="leave" and never bind `checked`, so the browser's native grouping is
  // the only thing driving their visual state. A shared name collapses every
  // field into one group, so picking an option in one field silently clears
  // the selection in another; give each field its own name so they behave as
  // the independent groups the markup intends.
  const radioGroupNames = new WeakMap();
  let radioGroupSequence = 0;
  const repairRadioGroups = () => {
    const radios = Array.from(document.querySelectorAll('input[type=radio][name]'));
    if (radios.length < 2) return;
    const byName = new Map();
    radios.forEach((radio) => {
      const container = radio.closest('.mint-field, form') || document.body;
      const name = radio.getAttribute('name');
      if (!byName.has(name)) byName.set(name, new Map());
      const byContainer = byName.get(name);
      if (!byContainer.has(container)) byContainer.set(container, []);
      byContainer.get(container).push(radio);
    });
    byName.forEach((byContainer, name) => {
      if (byContainer.size < 2) return;
      byContainer.forEach((members, container) => {
        let suffix = radioGroupNames.get(container);
        if (suffix === undefined) {
          suffix = ++radioGroupSequence;
          radioGroupNames.set(container, suffix);
        }
        const scoped = name + '__techpie_' + suffix;
        members.forEach((radio) => {
          if (radio.getAttribute('name') !== scoped) {
            radio.setAttribute('name', scoped);
          }
        });
      });
    });
  };
  const scheduleRadioRepair = () => {
    if (window.__techPieRadioRepairQueued) return;
    window.__techPieRadioRepairQueued = true;
    setTimeout(() => {
      window.__techPieRadioRepairQueued = false;
      repairRadioGroups();
    }, 0);
  };
  const installRadioRepair = () => {
    repairRadioGroups();
    if (!document.documentElement) return;
    new MutationObserver(scheduleRadioRepair).observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', installRadioRepair, { once: true });
  } else {
    installRadioRepair();
  }

  const mamp = window.mamp || {};
  const systemAbility = mamp.systemAbility || {};
  systemAbility.takePhoto = takePhoto;
  systemAbility.takeCamera = takeCamera;
  mamp.systemAbility = systemAbility;
  const file = mamp.file || {};
  file.uploadToServer = uploadToServer;
  file.filePreview = (url) => openUrl(url);
  mamp.file = file;
  const wisedu = mamp.wisedu || {};
  wisedu.uploadToEMAP = uploadToEMAP;
  mamp.wisedu = wisedu;
  const ui = mamp.UI || {};
  ui.preViewImages = preViewImages;
  ui.datePicker = datePicker;
  ui.dateTimePicker = dateTimePicker;
  ui.openWebView = (url) => openUrl(url);
  ui.closeWebView = () => tellHost('close');
  ui.setTitleText = (title) => tellHost('setTitle', { title: String(title || '') });
  ui.setNavHeader = (visible) => tellHost('setNavBar', { visible: visible !== false });
  ui.toggleNavBar = (visible) => tellHost('setNavBar', { visible: visible !== false });
  ui.webviewOnResume = (handler) => {
    if (typeof handler === 'function') resumeHandlers.push(handler);
  };
  mamp.UI = ui;
  try {
    Object.defineProperty(window, 'mamp', {
      configurable: true,
      get: () => mamp,
      set: (value) => Object.assign(mamp, value || {}),
    });
  } catch (_) {
    window.mamp = mamp;
  }

  adoptFileInputs();

  window.BH_MOBILE_SDK = window.BH_MOBILE_SDK || {};
  window.BH_MOBILE_SDK.systemAbility =
      window.BH_MOBILE_SDK.systemAbility || {};
  window.BH_MOBILE_SDK.systemAbility.takePhoto = takePhoto;
  window.BH_MOBILE_SDK.systemAbility.takeCamera = takeCamera;
  window.BH_MOBILE_SDK.UI = window.BH_MOBILE_SDK.UI || {};
  window.BH_MOBILE_SDK.UI.preViewImages = preViewImages;
  window.BH_MOBILE_SDK.UI.datePicker = datePicker;
  window.BH_MOBILE_SDK.UI.dateTimePicker = dateTimePicker;
  window.BH_MOBILE_SDK.file = file;
  window.BH_MOBILE_SDK.wisedu = wisedu;
  window.BH_MOBILE_SDK.bridge = window.TechPieBridge;
})();
