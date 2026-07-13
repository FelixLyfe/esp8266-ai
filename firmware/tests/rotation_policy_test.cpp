#include <cassert>
#include "rotation_policy.h"

int main() {
  bool e[3] = {false, false, false};
  bool w[3] = {false, false, false};
  bool n[3] = {false, false, false};
  assert(RotationPolicy::choose(e, w, n, -1, 3, false) == 3);

  e[1] = true;
  assert(RotationPolicy::choose(e, w, n, -1, 3, false) == 1);

  e[0] = e[2] = true;
  assert(RotationPolicy::choose(e, w, n, -1, 0, true) == 1);
  assert(RotationPolicy::choose(e, w, n, -1, 1, true) == 2);
  assert(RotationPolicy::choose(e, w, n, -1, 2, true) == 0);

  w[2] = true;
  assert(RotationPolicy::choose(e, w, n, -1, 0, false) == 2);
  w[0] = true;
  assert(RotationPolicy::choose(e, w, n, -1, 0, true) == 2);

  n[1] = true;
  assert(RotationPolicy::choose(e, w, n, -1, 2, false) == 1);
  n[1] = false;
  assert(RotationPolicy::choose(e, w, n, 0, 2, false) == 0);

  e[0] = false;
  assert(RotationPolicy::choose(e, w, n, 0, 2, false) == 2);
  return 0;
}
