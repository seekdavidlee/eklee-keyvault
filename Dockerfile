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
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build the React frontend
# ---------------------------------------------------------------------------
FROM node:22-alpine AS frontend-build
WORKDIR /app

COPY Eklee.KeyVault.UI/package.json Eklee.KeyVault.UI/package-lock.json* Eklee.KeyVault.UI/.npmrc ./
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
ARG RELEASE_VERSION
ARG SOURCE_REVISION_ID
RUN if [ -n "$RELEASE_VERSION" ] && [ -n "$SOURCE_REVISION_ID" ]; then \
			dotnet publish -c Release -o /app/publish \
				-p:Version="$RELEASE_VERSION" \
				-p:SourceRevisionId="$SOURCE_REVISION_ID"; \
		else \
			dotnet publish -c Release -o /app/publish; \
		fi

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
