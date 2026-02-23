/**
 * Runtime configuration module.
 *
 * In production (Docker), the entrypoint script generates a config.js that sets
 * window.__RUNTIME_CONFIG__ from environment variables. This allows the same
 * Docker image to be configured at runtime without rebuilding.
 *
 * In local development (Vite dev server), falls back to import.meta.env so
 * .env files and VITE_* variables continue to work as usual.
 */

interface RuntimeConfig {
  AZURE_AD_CLIENT_ID: string;
  AZURE_AD_AUTHORITY: string;
  AZURE_AD_REDIRECT_URI: string;
  API_BASE_URL: string;
}

declare global {
  interface Window {
    __RUNTIME_CONFIG__?: Partial<RuntimeConfig>;
  }
}

function getConfig(): RuntimeConfig {
  const rc = window.__RUNTIME_CONFIG__ ?? {};
  return {
    AZURE_AD_CLIENT_ID: rc.AZURE_AD_CLIENT_ID || import.meta.env.VITE_AZURE_AD_CLIENT_ID || '',
    AZURE_AD_AUTHORITY: rc.AZURE_AD_AUTHORITY || import.meta.env.VITE_AZURE_AD_AUTHORITY || '',
    AZURE_AD_REDIRECT_URI: rc.AZURE_AD_REDIRECT_URI || import.meta.env.VITE_AZURE_AD_REDIRECT_URI || '',
    API_BASE_URL: rc.API_BASE_URL || import.meta.env.VITE_API_BASE_URL || '',
  };
}

export const config = getConfig();
