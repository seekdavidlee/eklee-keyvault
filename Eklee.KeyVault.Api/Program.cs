using Eklee.KeyVault.Api.Services;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);

// Authentication — JWT Bearer validation via Microsoft Entra ID
builder.Services.AddMicrosoftIdentityWebApiAuthentication(builder.Configuration, "AzureAd");

builder.Services.AddAuthorization();

// Application services
builder.Services.AddSingleton<Config>();
builder.Services.AddScoped<BlobService>();
builder.Services.AddScoped<KeyVaultService>();

// Controllers with JSON serialization and Problem Details for error responses
builder.Services.AddControllers();
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
