// A minimal OpenID Connect provider for the federation smoke test (Node built-ins only, no dependencies).
//
// It is a TEST DOUBLE, deliberately small: discovery, a signing key (ES256, generated at start), an authorize endpoint that signs the
// "current person" in without asking for a password, and a token endpoint that checks the client, the code and the PKCE verifier and
// answers a signed ID token. The person who "signs in" is set with POST /__mock/identity, so a test can play several people.
//
//   node mock-oidc-provider.mjs            (env: MOCK_OIDC_PORT=9000, MOCK_OIDC_ISSUER=http://localhost:9000,
//                                                MOCK_OIDC_CLIENT_ID=thinklab-mock, MOCK_OIDC_CLIENT_SECRET=mock-client-secret)
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { createServer } from 'node:http';

const port = Number(process.env.MOCK_OIDC_PORT ?? 9000);
const issuer = process.env.MOCK_OIDC_ISSUER ?? `http://localhost:${port}`;
const clientId = process.env.MOCK_OIDC_CLIENT_ID ?? 'thinklab-mock';
const clientSecret = process.env.MOCK_OIDC_CLIENT_SECRET ?? 'mock-client-secret';

const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'mock-1', alg: 'ES256', use: 'sig' };
const codes = new Map();
let identity = { sub: 'mock-user-1', email: 'mock.user@example.com', email_verified: true, name: 'Mock User' };

const b64 = (value) => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');

function idToken(claims) {
  const data = `${b64({ alg: 'ES256', typ: 'JWT', kid: 'mock-1' })}.${b64(claims)}`;
  const signature = sign('sha256', Buffer.from(data), { key: privateKey, dsaEncoding: 'ieee-p1363' });
  return `${data}.${signature.toString('base64url')}`;
}

function send(response, status, body, headers = {}) {
  response.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  response.end(body === undefined ? undefined : JSON.stringify(body));
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

createServer(async (request, response) => {
  const url = new URL(request.url, issuer);
  if (url.pathname === '/.well-known/openid-configuration') {
    return send(response, 200, {
      issuer, authorization_endpoint: `${issuer}/authorize`, token_endpoint: `${issuer}/token`, jwks_uri: `${issuer}/jwks`,
      response_types_supported: ['code'], id_token_signing_alg_values_supported: ['ES256'], code_challenge_methods_supported: ['S256'],
    });
  }
  if (url.pathname === '/jwks') return send(response, 200, { keys: [jwk] });

  if (url.pathname === '/__mock/identity' && request.method === 'POST') {
    identity = JSON.parse(await readBody(request));
    return send(response, 204);
  }

  if (url.pathname === '/authorize') {
    const redirectUri = url.searchParams.get('redirect_uri');
    if (url.searchParams.get('client_id') !== clientId || !redirectUri || url.searchParams.get('code_challenge_method') !== 'S256') {
      return send(response, 400, { error: 'invalid_request' });
    }
    const code = randomBytes(16).toString('hex');
    codes.set(code, { identity, nonce: url.searchParams.get('nonce'), challenge: url.searchParams.get('code_challenge'), redirectUri });
    const back = new URL(redirectUri);
    back.searchParams.set('code', code);
    back.searchParams.set('state', url.searchParams.get('state'));
    return send(response, 302, undefined, { Location: back.toString() });
  }

  if (url.pathname === '/token' && request.method === 'POST') {
    const form = new URLSearchParams(await readBody(request));
    const entry = codes.get(form.get('code'));
    codes.delete(form.get('code'));
    const verifierOk = entry && createHash('sha256').update(form.get('code_verifier') ?? '').digest('base64url') === entry.challenge;
    if (form.get('grant_type') !== 'authorization_code' || form.get('client_id') !== clientId || form.get('client_secret') !== clientSecret
        || !entry || !verifierOk || form.get('redirect_uri') !== entry.redirectUri) {
      return send(response, 400, { error: 'invalid_grant' });
    }
    const now = Math.floor(Date.now() / 1000);
    return send(response, 200, {
      token_type: 'Bearer', access_token: randomBytes(16).toString('hex'), expires_in: 300,
      id_token: idToken({ iss: issuer, aud: clientId, iat: now, exp: now + 300, nonce: entry.nonce, ...entry.identity }),
    });
  }
  return send(response, 404, { error: 'not_found' });
}).listen(port, () => console.log(`mock OIDC provider on ${issuer} (client ${clientId})`));
