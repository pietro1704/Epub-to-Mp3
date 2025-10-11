/**
 * Cloudflare Function: GET /api/outputs/[job_id]/[filename]
 * Proxies file download requests to the Python backend
 */

interface Env {
  BACKEND_URL: string;
}

export async function onRequestGet(context: {
  request: Request;
  env: Env;
  params: { job_id: string; filename: string };
}) {
  const { env, params } = context;

  // Get backend URL from environment variable or use default
  const backendUrl = env.BACKEND_URL || 'http://localhost:8000';
  const { job_id, filename } = params;

  try {
    // Forward the request to the backend
    const response = await fetch(
      `${backendUrl}/api/outputs/${job_id}/${filename}`,
      {
        method: 'GET',
      }
    );

    // Determine content type from filename
    const contentType = filename.endsWith('.mp3')
      ? 'audio/mpeg'
      : filename.endsWith('.zip')
      ? 'application/zip'
      : 'application/octet-stream';

    // Return the backend response with appropriate headers
    return new Response(response.body, {
      status: response.status,
      headers: {
        'Content-Type': contentType,
        'Content-Disposition': `attachment; filename="${filename}"`,
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
