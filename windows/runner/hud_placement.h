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


struct HudControlsPlacement {
  static HudArea Rect(HudArea work, double width, double height, int corner, double dpi = 1) {
    double left = work.left + 24 * dpi;
    double top = work.top + 24 * dpi;
    double right = std::max(left, work.left + work.width - width - 24 * dpi);
    double bottom = std::max(top, work.top + work.height - height - 24 * dpi);
    return {corner % 2 == 0 ? left : right, corner < 2 ? top : bottom, width, height};
  }
  static bool Overlaps(HudArea a, HudArea b, double margin = 0) {
    return a.left < b.left + b.width + margin && a.left + a.width > b.left - margin &&
           a.top < b.top + b.height + margin && a.top + a.height > b.top - margin;
  }
  static int Corner(HudArea work, double width, double height, HudArea preview, int current, double dpi = 1) {
    if (preview.width <= 0 || !Overlaps(Rect(work, width, height, current, dpi), preview, 32 * dpi)) return current;
    int selected = current;
    double farthest = -1;
    bool found_free = false;
    for (int i = 0; i < 4; ++i) {
      auto r = Rect(work, width, height, i, dpi);
      bool free = !Overlaps(r, preview, 32 * dpi);
      double distance = std::hypot(r.left + width / 2 - preview.left - preview.width / 2,
                                   r.top + height / 2 - preview.top - preview.height / 2);
      if ((free && !found_free) || (free == found_free && distance > farthest)) {
        selected = i; farthest = distance; found_free = free;
      }
    }
    return selected;
  }
};
