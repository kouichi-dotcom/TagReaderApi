using System.Text.Json;

namespace TagReaderApi.Middleware;

/// <summary>
/// API_READ_ONLY=true のとき、変更系 HTTP メソッドをコントローラ到達前に 403 で拒否する。
/// </summary>
public sealed class ReadOnlyMiddleware
{
    private static readonly HashSet<string> BlockedMethods = new(StringComparer.OrdinalIgnoreCase)
    {
        HttpMethods.Post,
        HttpMethods.Put,
        HttpMethods.Patch,
        HttpMethods.Delete,
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly RequestDelegate _next;
    private readonly bool _readOnly;

    public ReadOnlyMiddleware(RequestDelegate next, IConfiguration configuration)
    {
        _next = next;
        _readOnly = configuration.GetValue("API_READ_ONLY", false);
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (_readOnly && BlockedMethods.Contains(context.Request.Method))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            context.Response.ContentType = "application/json";
            await context.Response.WriteAsync(
                JsonSerializer.Serialize(
                    new { error = "This API is running in read-only mode." },
                    JsonOptions));
            return;
        }

        await _next(context);
    }
}
