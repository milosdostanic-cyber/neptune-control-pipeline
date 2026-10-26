// Runs only inside Neptune Control's own signed-in Neptune web view.
// Credentials remain in WebKit and are never sent through the native bridge.
(() => {
  if (location.origin !== 'https://app.neptune.spaceinch.tech') return;
  const month = '__NEPTUNE_MONTH__', start = '__NEPTUNE_START__', end = '__NEPTUNE_END__';
  const apiOrigin = 'https://api.neptune.spaceinch.tech';
  const native = body => window.webkit.messageHandlers.neptuneStats.postMessage(body);
  let account = null, fetching = false, generation = 0, lastCollected = 0;
  const rawFetch = window.fetch.bind(window);
  const numeric = v => typeof v === 'number' && Number.isFinite(v) && v >= 0;
  const safeURL = value => { try { return new URL(value, location.href); } catch { return null; } };
  const headersForStats = headers => {
    const result = {};
    new Headers(headers || {}).forEach((value, key) => {
      if (['authorization', 'x-organization-id'].includes(key.toLowerCase())) result[key] = value;
    });
    return result;
  };
  async function collect(url, headers) {
    if (fetching || !account || !headers.authorization || Date.now() - lastCollected < 30_000) return;
    if (url.origin !== apiOrigin || url.pathname !== `/employees/${account}/coding-sessions`) return;
    fetching = true;
    const requestAccount = account, requestGeneration = generation;
    try {
      const request = new URL(url.origin + url.pathname);
      request.search = new URLSearchParams({date_from: start, date_to: end, limit: '100', sort_by: 'last_activity', sort_order: 'desc'}).toString();
      const apps = {'claude-code': {tokens: 0, scores: [], sessions: 0}, cursor: {tokens: 0, scores: [], sessions: 0}};
      const seenRows = new Set(), seenCursors = new Set();
      let finished = false, total = null, received = 0;
      for (let page = 0; page < 100; page++) {
        const response = await rawFetch(request.href, {method: 'GET', headers, credentials: 'omit'});
        if (!response.ok) throw new Error(response.status === 401 ? 'auth' : 'unavailable');
        const body = await response.json();
        if (!Array.isArray(body.data) || !body.pageInfo || !numeric(body.meta?.total)) throw new Error('format');
        if (total === null) total = body.meta.total;
        if (total !== body.meta.total) throw new Error('changed');
        for (const row of body.data) {
          const key = `${row.source}:${row.sessionId}`;
          if (!row.sessionId || seenRows.has(key)) throw new Error('duplicate');
          seenRows.add(key); received++;
          const item = apps[row.source];
          if (!item) continue;
          const counts = [row.totalTokensInput, row.totalTokensOutput, row.totalTokensCacheRead, row.totalTokensCacheWrite];
          if (!counts.every(v => numeric(v) && Number.isSafeInteger(v))) throw new Error('format');
          item.tokens += counts.reduce((a, b) => a + b, 0);
          if (!Number.isSafeInteger(item.tokens)) throw new Error('overflow');
          item.sessions++;
          if (numeric(row.sessionScore) && row.sessionScore <= 100) item.scores.push(row.sessionScore);
        }
        const cursor = body.pageInfo.nextCursor;
        if (!cursor) { finished = true; break; }
        if (typeof cursor !== 'string' || seenCursors.has(cursor)) throw new Error('cursor');
        seenCursors.add(cursor); request.searchParams.set('cursor', cursor);
      }
      if (!finished || received !== total) throw new Error('incomplete');
      if (account !== requestAccount || generation !== requestGeneration) throw new Error('auth');
      lastCollected = Date.now();
      native({kind: 'stats', month, periodStart: start, periodEnd: end, apps: Object.entries(apps).map(([source, item]) => ({
        source, tokens: item.tokens, sessions: item.sessions,
        score: item.scores.length ? item.scores.reduce((a, b) => a + b, 0) / item.scores.length : null
      }))});
    } catch (error) { native({kind: 'unavailable', reason: ['auth','unavailable','format','changed','duplicate','overflow','cursor','incomplete'].includes(error.message) ? error.message : 'unavailable'}); }
    finally { fetching = false; }
  }
  function observe(url, status, body, headers) {
    if (!url || url.origin !== apiOrigin) return;
    if (url.pathname === '/me') {
      if (status !== 200) { account = null; generation++; lastCollected = 0; native({kind: 'signIn'}); return; }
      if (typeof body.email !== 'string' || !/^[^@\s]+@spaceinch\.com$/i.test(body.email) || typeof body.employeeId !== 'string') {
        account = null; generation++; lastCollected = 0; native({kind: 'wrongAccount'}); return;
      }
      if (account !== body.employeeId) { generation++; lastCollected = 0; }
      account = body.employeeId;
      native({kind: 'connected', email: body.email.trim().toLowerCase()});
      void collect(new URL(`${apiOrigin}/employees/${encodeURIComponent(account)}/coding-sessions`), headersForStats(headers));
      return;
    }
    if (status === 200 && account) void collect(url, headersForStats(headers));
  }
  native({kind: 'loading'});
  window.fetch = async function(input, init) {
    const result = await rawFetch(input, init);
    const url = safeURL(typeof input === 'string' ? input : input.url);
    if (url?.origin === apiOrigin && (url.pathname === '/me' || url.pathname.endsWith('/coding-sessions'))) {
      result.clone().json().then(body => observe(url, result.status, body, init?.headers || input?.headers)).catch(() => {});
    }
    return result;
  };
  const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send, header = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this.__neptuneURL = safeURL(url); this.__neptuneMethod = method; this.__neptuneHeaders = {};
    return open.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.setRequestHeader = function(key, value) {
    this.__neptuneHeaders[key.toLowerCase()] = value;
    return header.call(this, key, value);
  };
  XMLHttpRequest.prototype.send = function(...args) {
    const url = this.__neptuneURL;
    if (this.__neptuneMethod?.toUpperCase() === 'GET' && url?.origin === apiOrigin && (url.pathname === '/me' || url.pathname.endsWith('/coding-sessions'))) {
      this.addEventListener('load', () => {
        try { observe(url, this.status, this.responseType === 'json' ? this.response : JSON.parse(this.responseText), this.__neptuneHeaders); } catch (_) {}
      }, {once: true});
    }
    return send.apply(this, args);
  };
})();
