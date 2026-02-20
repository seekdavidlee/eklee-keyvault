# =============================================================================
# Combined Dockerfile — React frontend + ASP.NET backend in a single container
# =============================================================================
# Build:
#   docker build -t eklee-keyvault \
#     --build-arg VITE_AZURE_AD_CLIENT_ID=<client-id> \
#     --build-arg VITE_AZURE_AD_AUTHORITY=https://login.microsoftonline.com/<tenant-id> \
#     --build-arg VITE_AZURE_AD_REDIRECT_URI=https://your-app-url \
#     .
#
# Run:
#   docker run -p 8080:8080 eklee-keyvault
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build the React frontend
# ---------------------------------------------------------------------------
FROM node:22-alpine AS frontend-build
WORKDIR /app

COPY Eklee.KeyVault.UI/package.json Eklee.KeyVault.UI/package-lock.json* ./
RUN npm ci

COPY Eklee.KeyVault.UI/ .

# Vite inlines VITE_* env vars at build time, so they must be set here.
# VITE_API_BASE_URL is intentionally empty — the frontend uses relative /api
# paths which resolve to the same origin served by ASP.NET.
ARG VITE_API_BASE_URL=""
ARG VITE_AZURE_AD_CLIENT_ID
ARG VITE_AZURE_AD_AUTHORITY
ARG VITE_AZURE_AD_REDIRECT_URI

ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
ENV VITE_AZURE_AD_CLIENT_ID=${VITE_AZURE_AD_CLIENT_ID}
ENV VITE_AZURE_AD_AUTHORITY=${VITE_AZURE_AD_AUTHORITY}
ENV VITE_AZURE_AD_REDIRECT_URI=${VITE_AZURE_AD_REDIRECT_URI}

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

ENTRYPOINT ["dotnet", "Eklee.KeyVault.Api.dll"]
