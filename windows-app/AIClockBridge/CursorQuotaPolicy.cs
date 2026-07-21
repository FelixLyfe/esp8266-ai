namespace AIClockBridge;

static class CursorQuotaPolicy
{
    public static double? RemainingPercent(double? usedPct) => usedPct.HasValue && usedPct.Value >= 0
        ? Math.Clamp(100 - usedPct.Value, 0, 100) : null;

    public static int? DisplayPercent(double? remainingPct) => remainingPct.HasValue
        ? (int)Math.Round(remainingPct.Value, MidpointRounding.AwayFromZero) : null;

    public static bool ShouldShowAutoOnly(double? apiUsedPct, double? autoUsedPct) =>
        RemainingPercent(autoUsedPct).HasValue
        && DisplayPercent(RemainingPercent(apiUsedPct)) == 0;

    public static double? RingRemainingPercent(double? totalUsedPct, double? autoUsedPct,
                                               double? apiUsedPct) =>
        RemainingPercent(ShouldShowAutoOnly(apiUsedPct, autoUsedPct) ? autoUsedPct : totalUsedPct);

    public static bool IsRingExhausted(double remainingPct) => remainingPct <= 0.1;
}
