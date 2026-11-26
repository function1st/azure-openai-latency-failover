// Usage:
//   npx tsx scripts/demo.ts
//   npx tsx scripts/demo.ts --count 10
//   npx tsx scripts/demo.ts --probe eastus2
//
// Required env vars: APIM_ENDPOINT, AAD_APP_CLIENT_ID
// Optional: DEPLOYMENT_NAME (default: gpt-4.1-nano)

import { DefaultAzureCredential } from '@azure/identity';

interface RequestResult {
  index: number;
  backend: string;
  ttft: number;
  status: number;
  error?: string;
}

function parseArgs(): { count: number; probe?: string } {
  const args = process.argv.slice(2);
  let count = 5;
  let probe: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--count' && args[i + 1]) count = parseInt(args[i + 1], 10);
    if (args[i] === '--probe' && args[i + 1]) probe = args[i + 1];
  }

  return { count, probe };
}

async function sendRequest(
  endpoint: string,
  deployment: string,
  token: string,
  index: number,
  probeRegion?: string,
): Promise<RequestResult> {
  const url = `${endpoint}/openai/deployments/${deployment}/chat/completions?api-version=2024-12-01-preview`;

  const start = performance.now();

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        ...(probeRegion ? { 'X-Probe-Target': probeRegion } : {}),
      },
      body: JSON.stringify({
        messages: [{ role: 'user', content: 'Reply with one short sentence about the weather.' }],
        stream: true,
        max_tokens: 50,
      }),
    });

    const backend = response.headers.get('X-Routed-Backend') ?? 'unknown';

    if (!response.ok || !response.body) {
      const body = await response.text();
      return { index, backend, ttft: -1, status: response.status, error: body.slice(0, 200) };
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let ttft = -1;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      const text = decoder.decode(value, { stream: true });
      if (text.includes('data:') && !text.includes('[DONE]')) {
        ttft = performance.now() - start;
        reader.cancel();
        break;
      }
    }

    return { index, backend, ttft, status: response.status };
  } catch (err) {
    return {
      index,
      backend: 'unknown',
      ttft: -1,
      status: 0,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

async function main() {
  const endpoint = process.env.APIM_ENDPOINT;
  const aadAppClientId = process.env.AAD_APP_CLIENT_ID;
  const deployment = process.env.DEPLOYMENT_NAME ?? 'gpt-4.1-nano';

  if (!endpoint || !aadAppClientId) {
    console.error('Missing required env vars: APIM_ENDPOINT, AAD_APP_CLIENT_ID');
    process.exit(1);
  }

  const { count, probe } = parseArgs();

  console.log(`\nEndpoint:   ${endpoint}`);
  console.log(`Deployment: ${deployment}`);
  console.log(`Requests:   ${count}`);
  if (probe) console.log(`Probe:      ${probe}`);
  console.log();

  const credential = new DefaultAzureCredential();
  const tokenResponse = await credential.getToken(`api://${aadAppClientId}/.default`);
  const token = tokenResponse.token;

  const promises = Array.from({ length: count }, (_, i) =>
    sendRequest(endpoint, deployment, token, i + 1, probe),
  );

  const results = await Promise.all(promises);
  results.sort((a, b) => a.index - b.index);

  const col = { idx: 3, backend: 28, ttft: 12, status: 8 };
  const header = [
    '#'.padEnd(col.idx),
    'Backend'.padEnd(col.backend),
    'TTFT (ms)'.padStart(col.ttft),
    'Status'.padEnd(col.status),
  ].join('  ');

  console.log(header);
  console.log('-'.repeat(header.length));

  for (const r of results) {
    const ttftStr = r.ttft >= 0 ? r.ttft.toFixed(0) : 'ERR';
    const line = [
      String(r.index).padEnd(col.idx),
      r.backend.padEnd(col.backend),
      ttftStr.padStart(col.ttft),
      (r.error ? `${r.status} !` : String(r.status)).padEnd(col.status),
    ].join('  ');
    console.log(line);
  }

  const successful = results.filter((r) => r.ttft >= 0);
  const avgTtft = successful.length > 0
    ? successful.reduce((sum, r) => sum + r.ttft, 0) / successful.length
    : 0;

  const backendCounts = new Map<string, number>();
  for (const r of results) {
    backendCounts.set(r.backend, (backendCounts.get(r.backend) ?? 0) + 1);
  }

  console.log(`\n--- Summary ---`);
  console.log(`Total:     ${results.length} requests`);
  console.log(`Success:   ${successful.length}/${results.length}`);
  console.log(`Avg TTFT:  ${avgTtft.toFixed(0)} ms`);
  console.log(`Backends:`);
  for (const [backend, n] of backendCounts) {
    console.log(`  ${backend}: ${n}`);
  }
  console.log();
}

main();
