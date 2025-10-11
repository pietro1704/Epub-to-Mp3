/**
 * Cloudflare Function: POST /api/convert
 * Proxies conversion requests to the Python backend
 */

interface Env {
  BACKEND_URL: string;
}

export async function onRequestPost(context: { request: Request; env: Env }) {
  const { request, env } = context;

  // Get backend URL from environment variable or use default
  const backendUrl = env.BACKEND_URL || 'http://localhost:8000';

  try {
    // Forward the entire request to the backend
    const response = await fetch(`${backendUrl}/api/convert`, {
      method: 'POST',
      headers: request.headers,
      body: request.body,
    });

    // Return the backend response
    return new Response(response.body, {
      status: response.status,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
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
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    },
  });
}
