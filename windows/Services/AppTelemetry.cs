using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Sentry;

namespace BurrowWin.Services;

/// Static telemetry facade for the Windows app — crash reporting (Sentry) plus
/// minimal, anonymous product analytics (PostHog over plain HTTP). It mirrors
/// the macOS app's privacy posture (opt-out, no PII, IP stripped, anonymous
/// random id) but reports to SEPARATE Windows-only projects, so nothing on the
/// macOS side changes and no platform discriminator flag is required.
///
/// Two independent gates guard every call:
///   1. the user's opt-out preference (`BurrowSettings.TelemetryEnabled`), and
///   2. whether a DSN / API key is actually configured (see TelemetryConfig).
/// Local/dev builds configure neither, so this is wholly inert there.
///
/// PostHog is intentionally hand-rolled over HTTP rather than via a NuGet
/// client: it keeps the capture payload — and thus the privacy guarantees —
/// fully under our control, and adds no package whose API could drift.
public static class AppTelemetry
{
    private static readonly object Sync = new();
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

    private static bool _enabled;
    private static bool _sentryStarted;
    private static string _distinctId = string.Empty;

    /// Keys that must never leave the device, dropped from any event payload.
    private static readonly HashSet<string> BlockedKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "api_key", "token", "authorization", "password", "secret",
        "file_path", "path", "url", "home", "home_dir", "username",
        "user", "email", "clipboard", "file_name", "contents",
    };

    /// Bring telemetry up at launch with the user's stored preference. Safe to
    /// call once; subsequent preference changes go through <see cref="SetEnabled"/>.
    public static void Initialize(bool enabled)
    {
        lock (Sync)
        {
            _distinctId = ResolveDistinctId();
            ApplyEnabled(enabled, coldStart: true);
        }
    }

    /// React to the user flipping the opt-out toggle: start or tear down both
    /// SDKs immediately so the preference takes effect without a relaunch.
    public static void SetEnabled(bool enabled)
    {
        lock (Sync)
        {
            if (enabled == _enabled)
            {
                return;
            }

            ApplyEnabled(enabled, coldStart: false);
        }
    }

    /// Report an unhandled exception (no-op unless enabled + Sentry configured).
    public static void CaptureException(Exception exception, string phase)
    {
        lock (Sync)
        {
            if (!_enabled || !_sentryStarted)
            {
                return;
            }
        }

        try
        {
            SentrySdk.CaptureException(exception);
        }
        catch
        {
            // Crash reporting must never itself crash the app.
        }
    }

    /// Capture a product-analytics event (no-op unless enabled + PostHog
    /// configured). Properties are sanitized and merged with anonymous device
    /// context before send. Fire-and-forget; never throws.
    public static void Capture(string eventName, Dictionary<string, object>? properties = null)
    {
        string apiKey, host, distinctId;
        lock (Sync)
        {
            if (!_enabled || !TelemetryConfig.IsPostHogConfigured)
            {
                return;
            }

            apiKey = TelemetryConfig.PostHogApiKey;
            host = TelemetryConfig.PostHogHost;
            distinctId = _distinctId;
        }

        var payload = new Dictionary<string, object?>
        {
            ["api_key"] = apiKey,
            ["event"] = eventName,
            ["distinct_id"] = distinctId,
            ["timestamp"] = DateTime.UtcNow.ToString("o"),
            ["properties"] = BuildProperties(properties),
        };

        _ = PostAsync(host, payload);
    }

    private static void ApplyEnabled(bool enabled, bool coldStart)
    {
        _enabled = enabled;
        if (enabled)
        {
            StartSentry();
            Capture(coldStart ? "app_opened" : "telemetry_opt_in_changed",
                    coldStart ? new Dictionary<string, object> { ["cold_start"] = true }
                              : new Dictionary<string, object> { ["enabled"] = true });
        }
        else
        {
            // Record the opt-out itself before muting (matches macOS), then close.
            Capture("telemetry_opt_in_changed", new Dictionary<string, object> { ["enabled"] = false });
            StopSentry();
        }
    }

    private static void StartSentry()
    {
        if (_sentryStarted || !TelemetryConfig.IsSentryConfigured)
        {
            return;
        }

        SentrySdk.Init(options =>
        {
            options.Dsn = TelemetryConfig.SentryDsn;
            options.Environment = "production";
            options.Release = $"burrow-win@{AppInfo.Version}";
            // Crash/error events only — no performance tracing, no PII, no
            // per-launch session beacon, no auto breadcrumbs.
            options.TracesSampleRate = 0.0;
            options.SendDefaultPii = false;
            options.AutoSessionTracking = false;
            options.IsGlobalModeEnabled = true;
            options.SetBeforeSend(static (SentryEvent sentryEvent, SentryHint _) =>
            {
                // The machine name can embed a real user name; never ship it.
                sentryEvent.ServerName = null;
                return sentryEvent;
            });
        });
        _sentryStarted = true;
    }

    private static void StopSentry()
    {
        if (!_sentryStarted)
        {
            return;
        }

        try
        {
            SentrySdk.Close();
        }
        catch
        {
            // Best effort.
        }

        _sentryStarted = false;
    }

    private static Dictionary<string, object?> BuildProperties(Dictionary<string, object>? user)
    {
        var props = new Dictionary<string, object?>
        {
            // PostHog uses this in place of the connection IP, so no real IP is
            // stored and GeoIP is skipped (belt-and-suspenders with the project's
            // "Discard client IP data").
            ["$ip"] = "0",
            ["$lib"] = "burrow-win",
            // Explicit discriminator: the Windows app shares the macOS PostHog
            // project (free-plan 1-project limit), so dashboards filter on this.
            ["platform"] = "windows",
            ["app_version"] = AppInfo.Version,
            ["os_version"] = AppInfo.OsVersion,
            ["arch"] = AppInfo.Arch,
        };

        if (user is not null)
        {
            foreach (var (key, value) in Sanitize(user))
            {
                props[key] = value;
            }
        }

        return props;
    }

    /// Defense in depth: drop known-sensitive keys, anything non-primitive, and
    /// any string that looks like a user path.
    private static Dictionary<string, object> Sanitize(Dictionary<string, object> input)
    {
        var output = new Dictionary<string, object>();
        foreach (var (key, value) in input)
        {
            if (BlockedKeys.Contains(key))
            {
                continue;
            }

            switch (value)
            {
                case bool or int or long or double or float:
                    output[key] = value;
                    break;
                case string text when !LooksLikeUserPath(text):
                    output[key] = text;
                    break;
                // Everything else (objects, arrays, sensitive strings) is dropped.
            }
        }

        return output;
    }

    private static bool LooksLikeUserPath(string value) =>
        value.Contains(@"\Users\", StringComparison.OrdinalIgnoreCase) ||
        value.Contains(":\\Users", StringComparison.OrdinalIgnoreCase);

    private static async Task PostAsync(string host, Dictionary<string, object?> payload)
    {
        try
        {
            var url = host.TrimEnd('/') + "/capture/";
            var json = JsonSerializer.Serialize(payload);
            using var content = new StringContent(json, Encoding.UTF8, "application/json");
            using var response = await Http.PostAsync(url, content).ConfigureAwait(false);
        }
        catch
        {
            // Analytics is best-effort and must never surface an error.
        }
    }

    /// A stable, anonymous per-install id — a random GUID persisted next to the
    /// settings file. Never derived from hardware, serial, or account.
    private static string ResolveDistinctId()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "BurrowWin");
            var path = Path.Combine(dir, "telemetry-id");

            if (File.Exists(path))
            {
                var existing = File.ReadAllText(path).Trim();
                if (Guid.TryParse(existing, out _))
                {
                    return existing;
                }
            }

            Directory.CreateDirectory(dir);
            var id = Guid.NewGuid().ToString();
            File.WriteAllText(path, id);
            return id;
        }
        catch
        {
            // A fresh per-session id is an acceptable fallback if disk is unwritable.
            return Guid.NewGuid().ToString();
        }
    }
}

/// Anonymous device/app context attached to telemetry events.
internal static class AppInfo
{
    public static string Version =>
        Environment.GetEnvironmentVariable("BURROWWIN_VERSION")
        ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString()
        ?? "0.0.0";

    public static string OsVersion => $"Windows {Environment.OSVersion.Version}";

    public static string Arch => RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant();
}
