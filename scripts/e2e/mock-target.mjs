// TEST DOUBLE, never part of a real deployment: something for the health monitor to watch (Node built-ins only), used by the
// health-monitoring smoke. One process, two listeners:
//
//   HTTP  (MOCK_TARGET_HTTP_PORT, default 9200)
//     GET  /health                    answers the status set below, after the delay set below
//     GET  /redirect                  answers 302 to /health (to prove the monitor does not follow redirects)
//     POST /__mock/status {status}    what /health answers from now on
//     POST /__mock/delay  {ms}        how long /health waits before answering
//     POST /__mock/tcp    {open}      opens or closes the TCP listener
//     GET  /__mock/state              {status, delayMs, tcpOpen, hits}
//   TCP   (MOCK_TARGET_TCP_PORT, default 9201)   accepts a connection and closes it; refuses while closed
//
// The double never logs a header or a body.
import http from 'node:http';
import net from 'node:net';

const HTTP_PORT = Number(process.env.MOCK_TARGET_HTTP_PORT || 9200);
const TCP_PORT = Number(process.env.MOCK_TARGET_TCP_PORT || 9201);

const state = { status: 200, delayMs: 0, tcpOpen: true, hits: 0 };
let tcpServer = null;

function openTcp() {
  if (tcpServer) return Promise.resolve();
  return new Promise((resolve) => {
    tcpServer = net.createServer((socket) => socket.end());
    tcpServer.listen(TCP_PORT, resolve);
  });
}

function closeTcp() {
  if (!tcpServer) return Promise.resolve();
  const server = tcpServer;
  tcpServer = null;
  return new Promise((resolve) => server.close(resolve));
}

function send(res, status, body, headers = {}) {
  const text = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text), ...headers });
  res.end(text);
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}

const server = http.createServer(async (req, res) => {
  try {
    const path = new URL(req.url, 'http://mock').pathname;
    if (req.method === 'GET' && path === '/health') {
      state.hits += 1;
      setTimeout(() => send(res, state.status, { status: state.status }), state.delayMs);
      return;
    }
    if (req.method === 'GET' && path === '/redirect') {
      state.hits += 1;
      return send(res, 302, undefined, { Location: '/health' });
    }
    if (req.method === 'GET' && path === '/__mock/state') return send(res, 200, state);
    if (req.method === 'POST' && path === '/__mock/status') {
      state.status = Number((await readJson(req)).status);
      return send(res, 200, state);
    }
    if (req.method === 'POST' && path === '/__mock/delay') {
      state.delayMs = Number((await readJson(req)).ms);
      return send(res, 200, state);
    }
    if (req.method === 'POST' && path === '/__mock/tcp') {
      const open = Boolean((await readJson(req)).open);
      await (open ? openTcp() : closeTcp());
      state.tcpOpen = open;
      return send(res, 200, state);
    }
    return send(res, 404, { error: 'not found' });
  } catch (error) {
    return send(res, 500, { error: 'mock failure' });
  }
});

await openTcp();
server.listen(HTTP_PORT, () => console.log(`mock-target listening on ${HTTP_PORT} (http) and ${TCP_PORT} (tcp)`));
