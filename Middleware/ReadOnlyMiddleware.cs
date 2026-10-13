using System.Text.Json;

namespace TagReaderApi.Middleware;

/// <summary>
/// 書き込み API のゲート。
/// 1) API_READ_ONLY=true → すべての変更系メソッドを 403（個別 Writes より優先）
/// 2) API_READ_ONLY=false → Writes:ProductUpdates / TagLedger / LinkTags を確認（未設定・不正は false）
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
    private readonly bool _apiReadOnly;
    private readonly bool _writesProductUpdates;
    private readonly bool _writesTagLedger;
    private readonly bool _writesLinkTags;

    public ReadOnlyMiddleware(RequestDelegate next, IConfiguration configuration)
    {
        _next = next;
        // 既存挙動維持: 未設定は false（グローバル read-only オフ）
        _apiReadOnly = ReadBool(configuration, "API_READ_ONLY", defaultValue: false);
        // 個別 Writes は fail-closed（未設定・不正は false）
        _writesProductUpdates = ReadBool(configuration, "Writes:ProductUpdates", defaultValue: false);
        _writesTagLedger = ReadBool(configuration, "Writes:TagLedger", defaultValue: false);
        _writesLinkTags = ReadBool(configuration, "Writes:LinkTags", defaultValue: false);
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (!BlockedMethods.Contains(context.Request.Method))
        {
            await _next(context);
            return;
        }

        if (_apiReadOnly)
        {
            await WriteForbiddenAsync(context, "This API is running in read-only mode.");
            return;
        }

        var path = context.Request.Path.Value ?? string.Empty;
        if (IsProductUpdatesWrite(context.Request.Method, path) && !_writesProductUpdates)
        {
            await WriteForbiddenAsync(context, "Write API is disabled: product-updates.");
            return;
        }

        if (IsTagLedgerWrite(context.Request.Method, path) && !_writesTagLedger)
        {
            await WriteForbiddenAsync(context, "Write API is disabled: tag-ledger.");
            return;
        }

        if (IsLinkTagsWrite(context.Request.Method, path) && !_writesLinkTags)
        {
            await WriteForbiddenAsync(context, "Write API is disabled: link-tags.");
            return;
        }

        await _next(context);
    }

    /// <summary>
    /// bool として解釈できない／未設定のときは defaultValue。fail-open にしない。
    /// </summary>
    internal static bool ReadBool(IConfiguration configuration, string key, bool defaultValue)
    {
        var raw = configuration[key];
        if (string.IsNullOrWhiteSpace(raw))
            return defaultValue;
        if (bool.TryParse(raw.Trim(), out var parsed))
            return parsed;
        return defaultValue;
    }

    private static bool IsProductUpdatesWrite(string method, string path)
        => HttpMethods.IsPost(method) && PathEquals(path, "/api/product-updates");

    private static bool IsTagLedgerWrite(string method, string path)
        => HttpMethods.IsPost(method) && PathEquals(path, "/api/products/tag-ledger");

    private static bool IsLinkTagsWrite(string method, string path)
    {
        if (!HttpMethods.IsPost(method))
            return false;
        // /api/reception-slips/{receptionNo}/link-tags
        const string prefix = "/api/reception-slips/";
        const string suffix = "/link-tags";
        if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            return false;
        if (!path.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            return false;
        var mid = path.Substring(prefix.Length, path.Length - prefix.Length - suffix.Length);
        return mid.Length > 0 && mid.IndexOf('/') < 0;
    }

    private static bool PathEquals(string path, string expected)
    {
        if (string.Equals(path, expected, StringComparison.OrdinalIgnoreCase))
            return true;
        // trailing slash 許容
        return string.Equals(path.TrimEnd('/'), expected, StringComparison.OrdinalIgnoreCase);
    }

    private static async Task WriteForbiddenAsync(HttpContext context, string error)
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        context.Response.ContentType = "application/json";
        await context.Response.WriteAsync(
            JsonSerializer.Serialize(new { error }, JsonOptions));
    }
}
