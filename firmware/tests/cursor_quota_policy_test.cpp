#include <cassert>

#include "cursor_quota_policy.h"

int main() {
  assert(CursorQuotaPolicy::shouldShowAutoOnly(100.0f, 40.0f));
  assert(CursorQuotaPolicy::shouldShowAutoOnly(99.51f, 40.0f));
  assert(!CursorQuotaPolicy::shouldShowAutoOnly(99.50f, 40.0f));
  assert(!CursorQuotaPolicy::shouldShowAutoOnly(99.0f, 40.0f));
  assert(!CursorQuotaPolicy::shouldShowAutoOnly(100.0f, -1.0f));
  assert(!CursorQuotaPolicy::shouldShowAutoOnly(-1.0f, 40.0f));

  assert(CursorQuotaPolicy::ringUsedPercent(100.0f, 40.0f, 100.0f) == 40.0f);
  assert(CursorQuotaPolicy::ringUsedPercent(75.0f, 40.0f, 99.0f) == 75.0f);
  assert(CursorQuotaPolicy::ringUsedPercent(100.0f, -1.0f, 100.0f) == 100.0f);
  assert(CursorQuotaPolicy::ringIsExhausted(99.9f));
  assert(!CursorQuotaPolicy::ringIsExhausted(99.89f));
  return 0;
}
