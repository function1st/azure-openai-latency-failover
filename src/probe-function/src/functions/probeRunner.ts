import { app, type Timer, type InvocationContext } from '@azure/functions';
import { DefaultAzureCredential } from '@azure/identity';
import { createAzure } from '@ai-sdk/azure';
import { streamText } from 'ai';
import * as appInsights from 'applicationinsights';

appInsights.setup().start();
const telemetry = appInsights.defaultClient;

const credential = new DefaultAzureCredential();

interface ProbeResult {
  region: string;
  ttft: number;
  success: boolean;
  error?: string;
}

async function probeRegion(
  apimEndpoint: string,
  token: string,
  region: string,
  deploymentName: string,
): Promise<ProbeResult> {
  const azure = createAzure({
    baseURL: `${apimEndpoint}/openai/deployments`,
    apiKey: 'unused',
  });

  const start = performance.now();

  try {
    const result = streamText({
      model: azure(deploymentName),
      messages: [{ role: 'user', content: 'Reply with one word.' }],
      maxTokens: 5,
      headers: {
        Authorization: `Bearer ${token}`,
        'X-Probe-Target': region,
      },
    });

    for await (const _chunk of result.textStream) {
      const ttft = performance.now() - start;
      return { region, ttft, success: true };
    }

    return { region, ttft: performance.now() - start, success: false, error: 'no tokens received' };
  } catch (err) {
    return {
      region,
      ttft: performance.now() - start,
      success: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

app.timer('probeRunner', {
  schedule: '0 */15 * * * *',
  handler: async (_timer: Timer, context: InvocationContext) => {
    const apimEndpoint = process.env.APIM_ENDPOINT!;
    const aadAppClientId = process.env.AAD_APP_CLIENT_ID!;
    const deploymentName = process.env.DEPLOYMENT_NAME ?? 'gpt-4.1-nano';
    const regions: string[] = JSON.parse(process.env.PROBE_REGIONS ?? '[]');

    if (!apimEndpoint || !aadAppClientId || regions.length === 0) {
      context.error('Missing required env vars: APIM_ENDPOINT, AAD_APP_CLIENT_ID, PROBE_REGIONS');
      return;
    }

    const tokenResponse = await credential.getToken(`api://${aadAppClientId}/.default`);
    const token = tokenResponse.token;

    context.log(`Probing ${regions.length} regions (3 requests each) with deployment '${deploymentName}'...`);

    const allProbes = regions.flatMap((region) =>
      Array.from({ length: 3 }, () => probeRegion(apimEndpoint, token, region, deploymentName)),
    );

    const results = await Promise.allSettled(allProbes);

    for (const settled of results) {
      if (settled.status === 'rejected') {
        context.error(`Probe failed unexpectedly: ${settled.reason}`);
        continue;
      }

      const r = settled.value;

      telemetry.trackMetric({
        name: 'ProbeResult',
        value: r.ttft,
        properties: {
          region: r.region,
          success: String(r.success),
          ...(r.error ? { error: r.error } : {}),
        },
      });

      context.log(`  ${r.region}: ${r.success ? `${r.ttft.toFixed(0)}ms` : `FAIL - ${r.error}`}`);
    }

    telemetry.flush();
  },
});
