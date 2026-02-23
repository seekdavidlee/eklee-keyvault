#!/bin/sh
# Generate runtime config for the React SPA from environment variables.
# This runs at container startup, writing to wwwroot/config.js so the
# browser picks up the real values without a rebuild.

CONFIG_PATH="/app/wwwroot/config.js"

cat > "$CONFIG_PATH" <<EOF
window.__RUNTIME_CONFIG__ = {
  AZURE_AD_CLIENT_ID: "${VITE_AZURE_AD_CLIENT_ID:-}",
  AZURE_AD_AUTHORITY: "${VITE_AZURE_AD_AUTHORITY:-}",
  AZURE_AD_REDIRECT_URI: "${VITE_AZURE_AD_REDIRECT_URI:-}",
  API_BASE_URL: "${VITE_API_BASE_URL:-}"
};
EOF

echo "Generated $CONFIG_PATH"

exec dotnet Eklee.KeyVault.Api.dll "$@"
