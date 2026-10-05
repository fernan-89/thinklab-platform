// TEST DOUBLE, never part of a real deployment: a Jira and a ServiceNow in one process (Node built-ins only), for the
// connector smoke (external-ticketing-smoke). It speaks just what the connector uses.
//
//   Jira       /jira/rest/api/2/...            create issue, read status, list and make transitions, comment, myself
//   ServiceNow /snow/api/now/table/...         create a row, patch state or comments, read one user
//
// Every call needs the Authorization header the double was started with (MOCK_TICKETING_JIRA_AUTH / _SNOW_AUTH); otherwise 401.
//
// Like a real provider, once a webhook is registered the double CALLS it for what an API call changes, naming the account that
// made the call (that is how the connector's own pushes come back as events, and why it must ignore them):
//
//   POST /__mock/register  {product, webhookUrl, token, actor}           where to send events, with which token, as which account
//   POST /__mock/event     {product, id, status?, comment?, actor, repeat?}   a PERSON changes a ticket: apply it, then deliver it
//   POST /__mock/fail      {count, status, echo?}                        the next N API calls fail (echo: the body repeats the Authorization header)
//   GET  /__mock/state                                                   everything the double holds and was asked
//   POST /__mock/reset
//
// The double never logs a header or a body.
import http from 'node:http';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.MOCK_TICKETING_PORT || 9100);
const AUTH = {
  jira: process.env.MOCK_TICKETING_JIRA_AUTH || 'Basic bW9jay1qaXJhOm1vY2s=',
  snow: process.env.MOCK_TICKETING_SNOW_AUTH || 'Basic bW9jay1zbm93Om1vY2s=',
};
const JIRA_STATUSES = ['To Do', 'In Progress', 'Done', 'Cancelled'];

let state;
let clock;
let failure;
function reset() {
  state = { jira: { seq: 0, issues: {} }, snow: { seq: 0, records: {} }, calls: [], deliveries: [], registrations: {} };
  clock = Date.now();
  failure = { count: 0, status: 500, echo: false };
}
reset();

function send(res, status, body) {
  const text = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text) });
  res.end(text);
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}

async function deliver(product, payload) {
  const registration = state.registrations[product];
  if (!registration) return null;
  try {
    const response = await fetch(registration.webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Webhook-Token': registration.token },
      body: JSON.stringify(payload),
    });
    const text = await response.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = null; }
    const delivery = { product, status: response.status, outcome: body && body.outcome ? body.outcome : null, detail: body && body.detail ? body.detail : null };
    state.deliveries.push(delivery);
    return delivery;
  } catch (error) {
    const delivery = { product, status: 0, outcome: 'UNREACHABLE', detail: String(error.cause?.code || error.message) };
    state.deliveries.push(delivery);
    return delivery;
  }
}

// ---- Jira ----------------------------------------------------------------------------------------------------------------------

function jiraStatusEvent(issue, actor) {
  return { webhookEvent: 'jira:issue_updated', timestamp: ++clock, issue: { key: issue.key }, user: { accountId: actor },
    changelog: { items: [{ field: 'status', toString: issue.status }] } };
}

function jiraCommentEvent(issue, comment, actor) {
  return { webhookEvent: 'comment_created', timestamp: ++clock, issue: { key: issue.key }, user: { accountId: actor },
    comment: { id: comment.id, body: comment.body } };
}

async function jira(req, res, path, body) {
  const registration = state.registrations.jira;
  const actor = registration ? registration.actor : 'unregistered';
  let match;
  if (req.method === 'GET' && path === '/rest/api/2/myself') return send(res, 200, { accountId: actor });
  if (req.method === 'POST' && path === '/rest/api/2/issue') {
    const fields = body.fields || {};
    const key = `${(fields.project || {}).key || 'PRJ'}-${++state.jira.seq}`;
    state.jira.issues[key] = { key, project: (fields.project || {}).key, type: (fields.issuetype || {}).name, summary: fields.summary, description: fields.description,
      status: 'To Do', comments: [], transitions: 0 };
    return send(res, 201, { id: String(state.jira.seq), key, self: `/jira/rest/api/2/issue/${key}` });
  }
  if ((match = path.match(/^\/rest\/api\/2\/issue\/([A-Z0-9_-]+)(\/transitions|\/comment)?$/))) {
    const issue = state.jira.issues[match[1]];
    if (!issue) return send(res, 404, { errorMessages: ['Issue does not exist'] });
    if (req.method === 'GET' && !match[2]) return send(res, 200, { key: issue.key, fields: { status: { name: issue.status } } });
    if (req.method === 'GET' && match[2] === '/transitions') {
      return send(res, 200, { transitions: JIRA_STATUSES.filter((s) => s !== issue.status).map((s) => ({ id: `t-${s}`, name: `Move to ${s}`, to: { name: s } })) });
    }
    if (req.method === 'POST' && match[2] === '/transitions') {
      const target = String(((body.transition || {}).id) || '').replace(/^t-/, '');
      if (!JIRA_STATUSES.includes(target)) return send(res, 400, { errorMessages: ['Transition is not valid'] });
      issue.status = target;
      issue.transitions += 1;
      send(res, 204);
      await deliver('jira', jiraStatusEvent(issue, actor));
      return;
    }
    if (req.method === 'POST' && match[2] === '/comment') {
      const comment = { id: String(10000 + issue.comments.length + 1), body: body.body, author: 'integration' };
      issue.comments.push(comment);
      send(res, 201, { id: comment.id });
      await deliver('jira', jiraCommentEvent(issue, comment, actor));
      return;
    }
  }
  return send(res, 404, { errorMessages: ['Not found'] });
}

// ---- ServiceNow ----------------------------------------------------------------------------------------------------------------

function snowEvent(table, record, comment, actor) {
  return { table, sys_id: record.sys_id, number: record.number, state: record.state, comment: comment || null, updated_by: actor, event_id: `evt-${++clock}` };
}

async function snow(req, res, path, body) {
  const registration = state.registrations.snow;
  const actor = registration ? registration.actor : 'unregistered';
  let match;
  if (req.method === 'GET' && path === '/api/now/table/sys_user') return send(res, 200, { result: [{ user_name: actor }] });
  if (req.method === 'POST' && (match = path.match(/^\/api\/now\/table\/(incident|sc_request|problem)$/))) {
    const sysId = randomUUID().replace(/-/g, '');
    const record = { table: match[1], sys_id: sysId, number: `REC${String(++state.snow.seq).padStart(7, '0')}`, short_description: body.short_description,
      description: body.description, correlation_id: body.correlation_id, state: body.state || '1', comments: [], patches: 0 };
    state.snow.records[`${match[1]}/${sysId}`] = record;
    return send(res, 201, { result: { sys_id: sysId, number: record.number, state: record.state } });
  }
  if (req.method === 'PATCH' && (match = path.match(/^\/api\/now\/table\/(incident|sc_request|problem)\/([0-9a-f]{32})$/))) {
    const record = state.snow.records[`${match[1]}/${match[2]}`];
    if (!record) return send(res, 404, { error: { message: 'No Record found' } });
    record.patches += 1;
    if (body.state !== undefined) record.state = String(body.state);
    if (body.comments !== undefined) record.comments.push({ body: body.comments, author: 'integration' });
    send(res, 200, { result: { sys_id: record.sys_id, state: record.state } });
    await deliver('snow', snowEvent(match[1], record, body.comments, actor));
    return;
  }
  return send(res, 404, { error: { message: 'Not found' } });
}

// ---- Control -------------------------------------------------------------------------------------------------------------------

async function control(req, res, path, body) {
  if (req.method === 'GET' && path === '/__mock/state') return send(res, 200, state);
  if (req.method === 'POST' && path === '/__mock/reset') { reset(); return send(res, 200, { ok: true }); }
  if (req.method === 'POST' && path === '/__mock/register') {
    state.registrations[body.product] = { webhookUrl: body.webhookUrl, token: body.token, actor: body.actor };
    return send(res, 200, { ok: true });
  }
  if (req.method === 'POST' && path === '/__mock/fail') {
    failure = { count: body.count || 1, status: body.status || 500, echo: !!body.echo };
    return send(res, 200, { ok: true });
  }
  if (req.method === 'POST' && path === '/__mock/event') {
    const repeat = body.repeat || 1;
    const actor = body.actor || 'a-person';
    let payload;
    if (body.product === 'jira') {
      const issue = state.jira.issues[body.id];
      if (!issue) return send(res, 404, { error: 'unknown issue' });
      if (body.status) issue.status = body.status;
      if (body.comment) {
        const comment = { id: String(10000 + issue.comments.length + 1), body: body.comment, author: actor };
        issue.comments.push(comment);
        payload = jiraCommentEvent(issue, comment, actor);
      } else {
        payload = jiraStatusEvent(issue, actor);
      }
    } else {
      const record = state.snow.records[body.id];
      if (!record) return send(res, 404, { error: 'unknown record' });
      if (body.status !== undefined) record.state = String(body.status);
      payload = snowEvent(record.table, record, body.comment, actor);
    }
    const deliveries = [];
    for (let i = 0; i < repeat; i += 1) deliveries.push(await deliver(body.product, payload));
    return send(res, 200, { deliveries });
  }
  return send(res, 404, { error: 'not a control route' });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://mock');
    const body = req.method === 'GET' ? {} : await readJson(req);
    if (url.pathname.startsWith('/__mock/')) return await control(req, res, url.pathname, body);
    const product = url.pathname.startsWith('/jira/') ? 'jira' : url.pathname.startsWith('/snow/') ? 'snow' : null;
    if (!product) return send(res, 404, { error: 'unknown product' });
    const path = url.pathname.slice(product.length + 1);
    const authorised = req.headers.authorization === AUTH[product];
    state.calls.push({ product, method: req.method, path, authorised });
    if (!authorised) return send(res, 401, { error: 'unauthorised' });
    if (failure.count > 0) {
      failure.count -= 1;
      return send(res, failure.status, failure.echo ? { echoed: req.headers.authorization, request: body } : { error: 'forced failure' });
    }
    return await (product === 'jira' ? jira : snow)(req, res, path, body);
  } catch (error) {
    return send(res, 500, { error: 'mock failure' });
  }
});

server.listen(PORT, () => console.log(`mock-ticketing listening on ${PORT}`));
