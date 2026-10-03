#include "../windows/runner/hud_placement.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <iostream>
#include <limits>

bool near(double a, double b) { return std::abs(a - b) < .000001; }
int main() {
  HudPlacement layout;
  const HudArea work{-1920, -200, 1920, 1080};
  auto point = layout.Origin(work, 372, 52);
  assert(near(point.x, -1146) && near(point.y, 736));
  point = layout.Snap({-1140, 309}, work, 372, 52);
  assert(near(point.x, -1146) && near(point.y, 314));
  point = layout.Snap({-1120, 285}, work, 372, 52);
  assert(near(point.x, -1120) && near(point.y, 285));
  point = layout.Clamp({-5000, 5000}, work, 372, 52);
  assert(near(point.x, work.left) && near(point.y, 828));
  point = layout.Clamp({9999, 9999}, {20, 30, 100, 20}, 372, 52);
  assert(near(point.x, 20) && near(point.y, 30));
  layout.Capture({-1146, 314}, work, 372, 52);
  assert(layout.positioned && near(layout.x, .5) && near(layout.y, .5));
  point = layout.Origin({100, 50, 2560, 1440}, 744, 104);
  assert(near(point.x + 372, 1380) && near(point.y + 52, 770));
  assert(near(HudPlacement::ValidScale(.1), .8));
  assert(near(HudPlacement::ValidScale(20), 1.6));
  assert(near(HudPlacement::ValidScale(std::numeric_limits<double>::quiet_NaN()), 1));
  assert(near(HudPlacement::ValidScale(std::numeric_limits<double>::infinity()), 1));
  for (int i = 0; i <= 100; i++) {
    auto p = layout.Clamp({work.left + i * 19.2, work.top + i * 10.8}, work, 372, 52);
    layout.Capture(p, work, 372, 52);
    auto restored = layout.Origin(work, 372, 52);
    assert(near(restored.x, p.x) && near(restored.y, p.y));
  }
  const auto before = layout;
  auto draft = layout;
  draft.Capture({-1500, 500}, work, 372, 52);
  draft.scale = 1.4;
  draft = before;  // Cancel restores both coordinates and scale.
  assert(draft.x == before.x && draft.y == before.y && draft.scale == before.scale);
  draft = HudPlacement(); // Reset restores default alignment and scale.
  assert(!draft.positioned && draft.scale == 1);
  std::cout << "Windows HUD geometry: all checks passed\n";
}
