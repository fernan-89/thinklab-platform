// TEST DOUBLE, never part of a real deployment: what scripts/connectors/netdata-sync.sh reads from a Netdata agent (Node built-ins only),
// used by the Netdata connector smoke.
//
//   GET /api/v1/info                      the agent's id, host name and a few facts about the machine
//   GET /api/v1/data?chart=...&...        one row, the shape Netdata answers with format=json:
//                                         {labels: ["time", dimension...], data: [[time, value...]]}
//                                         charts: system.ram (MiB: free 1000, used 2000, cached 300, buffers 50), disk_space./ (GiB: avail 10, used 20)
//                                         any other chart answers 404, as Netdata does
//
// MOCK_NETDATA_PORT (default 19998). MOCK_NETDATA_TOKEN: when set, every request needs "Authorization: Bearer <token>" or answers 401.
// The double never logs a header or a body.
import http from 'node:http';

const PORT = Number(process.env.MOCK_NETDATA_PORT || 19998);
const TOKEN = process.env.MOCK_NETDATA_TOKEN || '';

const info = {
  version: 'v2.12.1',
  uid: '2b9e0e5c-f39f-4abc-817e-5fd811d021e1',
  mirrored_hosts: ['smoke-node'],
  os_name: 'unknown',
  kernel_name: 'Linux',
  kernel_version: '7.0.0-test',
  architecture: 'x86_64',
  virtualization: 'none',
  cores_total: '12',
  ram_total: '65880317952',
  total_disk_space: '256060514304',
};

const charts = {
  'system.ram': { labels: ['time', 'free', 'used', 'cached', 'buffers'], row: [1000, 2000, 300, 50] },
  'disk_space./': { labels: ['time', 'avail', 'used', 'reservedforroot'], row: [10, 20, 1] },
};

function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (TOKEN && req.headers.authorization !== `Bearer ${TOKEN}`) return send(res, 401, { error: 'unauthorized' });
  if (url.pathname === '/api/v1/info') return send(res, 200, info);
  if (url.pathname === '/api/v1/data') {
    const chart = charts[url.searchParams.get('chart')];
    if (!chart) return send(res, 404, { error: 'no such chart' });
    return send(res, 200, { labels: chart.labels, data: [[Math.floor(Date.now() / 1000), ...chart.row]] });
  }
  return send(res, 404, { error: 'not found' });
}).listen(PORT, () => console.log(`mock netdata on ${PORT}`));
