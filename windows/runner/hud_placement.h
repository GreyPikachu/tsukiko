#pragma once
#include <algorithm>
#include <cmath>

// Work-area fractions, measured from the top left; independent of DPI.
struct HudArea { double left, top, width, height; };
struct HudPoint { double x, y; };
struct HudPlacement {
  double x = .5, y = .5, scale = 1;
  bool positioned = false;
  static double ValidScale(double value) {
    return std::isfinite(value) ? std::clamp(value, .8, 1.6) : 1;
  }
  HudPoint Clamp(HudPoint p, HudArea work, double width, double height) const {
    return {std::clamp(p.x, work.left, work.left + std::max(0.0, work.width - width)),
            std::clamp(p.y, work.top, work.top + std::max(0.0, work.height - height))};
  }
  HudPoint Origin(HudArea work, double width, double height, double bottom_gap = 92) const {
    return Clamp({work.left + (positioned ? x : .5) * work.width - width / 2,
                  positioned ? work.top + y * work.height - height / 2
                             : work.top + work.height - height - bottom_gap}, work, width, height);
  }
  HudPoint Snap(HudPoint p, HudArea work, double width, double height, double threshold = 12) const {
    if (std::abs(p.x + width / 2 - work.left - work.width / 2) <= threshold)
      p.x = work.left + (work.width - width) / 2;
    if (std::abs(p.y + height / 2 - work.top - work.height / 2) <= threshold)
      p.y = work.top + (work.height - height) / 2;
    return Clamp(p, work, width, height);
  }
  void Capture(HudPoint p, HudArea work, double width, double height) {
    if (work.width <= 0 || work.height <= 0) return;
    x = std::clamp((p.x + width / 2 - work.left) / work.width, 0.0, 1.0);
    y = std::clamp((p.y + height / 2 - work.top) / work.height, 0.0, 1.0);
    positioned = true;
  }
};
