param(
    [string]$ProjectPath = "Eklee.KeyVault.Api/Eklee.KeyVault.Api.csproj"
)

$packages = @(
    "Azure.Identity",
    "Azure.Security.KeyVault.Secrets",
    "Azure.Storage.Blobs",
    "Microsoft.AspNetCore.Authentication.JwtBearer",
    "Microsoft.Identity.Web",
    "Swashbuckle.AspNetCore"
)

foreach ($package in $packages) {
    Write-Host "Updating $package..." -ForegroundColor Cyan
    dotnet add $ProjectPath package $package
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to update $package" -ForegroundColor Red
    }
    else {
        Write-Host "Updated $package successfully" -ForegroundColor Green
    }
    Write-Host ""
}

Write-Host "All packages processed. Building..." -ForegroundColor Yellow
dotnet build $ProjectPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}

Write-Host "Build succeeded. Verifying..." -ForegroundColor Green
dotnet list $ProjectPath package --outdated
