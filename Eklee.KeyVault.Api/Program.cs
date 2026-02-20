using Azure.Core;
using Azure.Identity;
using Eklee.KeyVault.Api.Services;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);

// Authentication — JWT Bearer validation via Microsoft Entra ID
// Accept both "api://<clientId>" and the bare "<clientId>" as valid audiences,
// because Azure AD may stamp tokens with either form.
var azureAdSection = builder.Configuration.GetSection("AzureAd");
var clientId = azureAdSection["ClientId"]!;
builder.Services.AddMicrosoftIdentityWebApiAuthentication(builder.Configuration, "AzureAd")
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

builder.Services.Configure<Microsoft.AspNetCore.Authentication.JwtBearer.JwtBearerOptions>(
    Microsoft.AspNetCore.Authentication.JwtBearer.JwtBearerDefaults.AuthenticationScheme,
    options =>
    {
        options.TokenValidationParameters.ValidAudiences = new[]
        {
            $"api://{clientId}",
            clientId
        };
    });

builder.Services.AddAuthorization();

// Application services
builder.Services.AddSingleton<Config>();

// Register a TokenCredential based on the AuthenticationMode setting.
// "azcli" uses Azure CLI credentials for local development;
// "mi" uses Managed Identity for production workloads.
builder.Services.AddSingleton<TokenCredential>(sp =>
{
    var config = sp.GetRequiredService<Config>();
    return config.AuthenticationMode.ToLowerInvariant() switch
    {
        "azcli" => new AzureCliCredential(new AzureCliCredentialOptions
        {
            ProcessTimeout = TimeSpan.FromSeconds(30)
        }),
        "mi" => new ManagedIdentityCredential(),
        _ => throw new InvalidOperationException(
            $"Unsupported AuthenticationMode '{config.AuthenticationMode}'. Use 'azcli' or 'mi'.")
    };
});

builder.Services.AddScoped<BlobService>();
builder.Services.AddScoped<KeyVaultService>();
builder.Services.AddScoped<UserAccessService>();
builder.Services.AddScoped<Microsoft.AspNetCore.Authentication.IClaimsTransformation, UserAccessClaimsTransformation>();

// Controllers with JSON serialization and Problem Details for error responses
builder.Services.AddControllers()
    .AddJsonOptions(options =>
    {
        options.JsonSerializerOptions.Converters.Add(
            new System.Text.Json.Serialization.JsonStringEnumConverter());
    });
builder.Services.AddProblemDetails();

// OpenAPI / Swagger
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new Microsoft.OpenApi.Models.OpenApiInfo
    {
        Title = "Eklee KeyVault API",
        Version = "v1",
        Description = "REST API for managing Key Vault secrets and display metadata."
    });

    // Add Bearer token input to the Swagger UI
    options.AddSecurityDefinition("Bearer", new Microsoft.OpenApi.Models.OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = Microsoft.OpenApi.Models.SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = Microsoft.OpenApi.Models.ParameterLocation.Header,
        Description = "Enter your JWT token (without the 'Bearer ' prefix)."
    });

    options.AddSecurityRequirement(new Microsoft.OpenApi.Models.OpenApiSecurityRequirement
    {
        {
            new Microsoft.OpenApi.Models.OpenApiSecurityScheme
            {
                Reference = new Microsoft.OpenApi.Models.OpenApiReference
                {
                    Type = Microsoft.OpenApi.Models.ReferenceType.SecurityScheme,
                    Id = "Bearer"
                }
            },
            Array.Empty<string>()
        }
    });
});

// CORS — allow the React dev server and production origins
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowFrontend", policy =>
    {
        var allowedOrigins = builder.Configuration.GetSection("AllowedOrigins").Get<string[]>()
            ?? ["http://localhost:5173"];

        policy.WithOrigins(allowedOrigins)
              .AllowAnyHeader()
              .AllowAnyMethod()
              .AllowCredentials();
    });
});

// Health checks
builder.Services.AddHealthChecks();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseCors("AllowFrontend");

// Serve the React SPA from wwwroot/ (combined container deployment)
app.UseDefaultFiles();
app.UseStaticFiles();

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();
app.MapHealthChecks("/healthz");

// SPA fallback — unmatched routes serve index.html so React Router handles client-side routing.
// API routes (/api/*) and health checks (/healthz) are matched above and won't hit this fallback.
app.MapFallbackToFile("index.html");

app.Run();
