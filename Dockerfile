# =============================================================================
# Combined Dockerfile — React frontend + ASP.NET backend in a single container
# =============================================================================
# Production build (default target = runtime):
#   docker build --target runtime -t eklee-keyvault .
#
# Run (production — pass auth config as environment variables at runtime):
#   docker run -p 8080:8080 \
#     -e VITE_AZURE_AD_CLIENT_ID=<client-id> \
#     -e VITE_AZURE_AD_AUTHORITY=https://login.microsoftonline.com/<tenant-id> \
#     -e VITE_AZURE_AD_REDIRECT_URI=https://your-app-url \
#     eklee-keyvault
#
# Local development build (includes Azure CLI for AzureCliCredential):
#   docker build --target local -t eklee-keyvault-local .
#
# Run (local — mount Azure CLI credentials):
#   docker run --rm -p 8080:8080 \
#     -v "$HOME/.azure:/home/app/.azure:ro" \
#     -e AuthenticationMode=azcli \
#     -e ASPNETCORE_ENVIRONMENT=Development \
#     -e VITE_AZURE_AD_CLIENT_ID=<client-id> \
#     -e VITE_AZURE_AD_AUTHORITY=https://login.microsoftonline.com/<tenant-id> \
#     -e VITE_AZURE_AD_REDIRECT_URI=http://localhost:8080 \
#     eklee-keyvault-local
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build the React frontend
# ---------------------------------------------------------------------------
FROM node:22-alpine AS frontend-build
WORKDIR /app

COPY Eklee.KeyVault.UI/package.json Eklee.KeyVault.UI/package-lock.json* ./
RUN npm ci

COPY Eklee.KeyVault.UI/ .

RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2: Build the ASP.NET backend
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS backend-build
WORKDIR /src

COPY Eklee.KeyVault.Api/Eklee.KeyVault.Api.csproj Eklee.KeyVault.Api/
RUN dotnet restore Eklee.KeyVault.Api/Eklee.KeyVault.Api.csproj

COPY Eklee.KeyVault.Api/ Eklee.KeyVault.Api/
WORKDIR /src/Eklee.KeyVault.Api
RUN dotnet publish -c Release -o /app/publish

# ---------------------------------------------------------------------------
# Stage 3: Runtime — ASP.NET serves the API and the React SPA from wwwroot/
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
EXPOSE 8080

# Copy the published ASP.NET application
COPY --from=backend-build /app/publish .

# Copy the React build output into wwwroot/ so ASP.NET serves it as static files
COPY --from=frontend-build /app/dist ./wwwroot/

# Entrypoint script generates wwwroot/config.js from env vars at startup
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN sed -i 's/\r$//' /app/docker-entrypoint.sh && chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

# ---------------------------------------------------------------------------
# Stage 4: Local development — lightweight az wrapper for AzureCliCredential
# ---------------------------------------------------------------------------
# Instead of installing the full Azure CLI (~200 MB) and dealing with
# DPAPI-encrypted token caches or device-code login, this stage adds a
# lightweight `az` wrapper script. The run-local.ps1 script pre-fetches
# access tokens on the host (where you are already authenticated) and
# mounts them as JSON files at /tmp/az-tokens/. The wrapper intercepts
# `az account get-access-token` calls from AzureCliCredential and returns
# the pre-fetched tokens.
# Build with: docker build --target local ...
FROM runtime AS local

# Install the lightweight az wrapper at /usr/local/bin/az
COPY az-wrapper.sh /usr/local/bin/az
RUN sed -i 's/\r$//' /usr/local/bin/az && chmod +x /usr/local/bin/az

# Pre-create the token mount point
RUN mkdir -p /tmp/az-tokens
