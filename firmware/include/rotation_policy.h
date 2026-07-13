#pragma once

// Pure state machine shared by firmware and host-side tests.
// Provider indexes are fixed: 0 Claude, 1 Codex, 2 Cursor, 3 none.
namespace RotationPolicy {
constexpr int None = 3;

inline int choose(const bool eligible[3], const bool working[3], const bool needsInput[3],
                  int pinned, int current, bool rotateNow) {
  if (pinned >= 0 && pinned < 3 && eligible[pinned]) return pinned;

  int eligibleCount = 0, workingCount = 0;
  int onlyEligible = None, onlyWorking = None;
  for (int i = 0; i < 3; i++) {
    if (eligible[i]) { eligibleCount++; onlyEligible = i; }
    if (eligible[i] && working[i]) { workingCount++; onlyWorking = i; }
  }
  if (eligibleCount == 0) return None;
  if (eligible[0] && needsInput[0] && !(eligible[1] && needsInput[1])) return 0;
  if (eligible[1] && needsInput[1] && !(eligible[0] && needsInput[0])) return 1;
  if (workingCount == 1) return onlyWorking;
  if (eligibleCount == 1) return onlyEligible;

  const bool workingRotation = workingCount > 1;
  const bool currentAllowed = current >= 0 && current < 3 && eligible[current]
      && (!workingRotation || working[current]);
  if (currentAllowed && !rotateNow) return current;
  int currentIndex = current >= 0 && current < 3 ? current : -1;
  for (int step = 1; step <= 3; step++) {
    int candidate = (currentIndex + step + 3) % 3;
    if (eligible[candidate] && (!workingRotation || working[candidate])) return candidate;
  }
  return onlyEligible;
}
} // namespace RotationPolicy
