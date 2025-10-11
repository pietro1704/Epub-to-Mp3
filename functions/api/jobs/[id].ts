/**
 * Cloudflare Function: GET /api/jobs/[id]
 * Proxies job status requests to the Python backend
 */

interface Env {
  BACKEND_URL: string;
}

export async function onRequestGet(context: {
  request: Request;
  env: Env;
  params: { id: string };
}) {
  const { env, params } = context;

  // Get backend URL from environment variable or use default
  const backendUrl = env.BACKEND_URL || 'http://localhost:8000';
  const jobId = params.id;

  try {
    // Forward the request to the backend
    const response = await fetch(`${backendUrl}/api/jobs/${jobId}`, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
      },
    });

    // Return the backend response
    return new Response(response.body, {
      status: response.status,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
      },
    });
  } catch (error) {
    return new Response(
      JSON.stringify({
        error: 'Backend connection failed',
        details: error instanceof Error ? error.message : 'Unknown error'
      }),
      {
        status: 502,
        headers: { 'Content-Type': 'application/json' },
      }
    );
  }
}

export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    },
  });
}
