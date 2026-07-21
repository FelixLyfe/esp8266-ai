#pragma once

#include <math.h>

namespace CursorQuotaPolicy {

inline float remainingPercent(float usedPct) {
  if (usedPct < 0) return -1.0f;
  float remaining = 100.0f - usedPct;
  if (remaining < 0) return 0.0f;
  if (remaining > 100) return 100.0f;
  return remaining;
}

inline bool shouldShowAutoOnly(float apiUsedPct, float autoUsedPct) {
  if (apiUsedPct < 0 || autoUsedPct < 0) return false;
  return lroundf(remainingPercent(apiUsedPct)) == 0;
}

inline float ringUsedPercent(float totalUsedPct, float autoUsedPct, float apiUsedPct) {
  return shouldShowAutoOnly(apiUsedPct, autoUsedPct) ? autoUsedPct : totalUsedPct;
}

inline bool ringIsExhausted(float usedPct) {
  return usedPct >= 99.9f;
}

}  // namespace CursorQuotaPolicy
