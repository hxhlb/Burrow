using BurrowWin.Models;

namespace BurrowWin.Services;

public enum HttpServerSettingsAction
{
    None,
    Start,
    Stop,
    Restart
}

public static class HttpServerSettingsPlanner
{
    public static HttpServerSettingsAction Plan(
        bool activeHttpEnabled,
        int activePort,
        BurrowSettings settings)
    {
        var normalized = BurrowSettings.Normalize(settings);
        if (!activeHttpEnabled)
        {
            return HttpServerSettingsAction.Start;
        }

        return activePort == normalized.HttpServerPort
            ? HttpServerSettingsAction.None
            : HttpServerSettingsAction.Restart;
    }
}
