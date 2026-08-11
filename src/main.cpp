#include <SDL.h>
#include <SDL_opengl.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <iterator>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_opengl3.h"
#include "portable-file-dialogs.h"

#include "caption_service.hpp"
#include "jobs.hpp"
#include "media_engine.hpp"
#include "state_store.hpp"

namespace fs = std::filesystem;

namespace {

ImVec4 gAccent{0.06f, 0.48f, 0.43f, 1.0f};
bool gDarkTheme = false;

PFNGLGENFRAMEBUFFERSPROC glGenFramebuffersWam = nullptr;
PFNGLBINDFRAMEBUFFERPROC glBindFramebufferWam = nullptr;
PFNGLFRAMEBUFFERTEXTURE2DPROC glFramebufferTexture2DWam = nullptr;
PFNGLCHECKFRAMEBUFFERSTATUSPROC glCheckFramebufferStatusWam = nullptr;
PFNGLDELETEFRAMEBUFFERSPROC glDeleteFramebuffersWam = nullptr;

bool loadFramebufferFunctions() {
  glGenFramebuffersWam = reinterpret_cast<PFNGLGENFRAMEBUFFERSPROC>(SDL_GL_GetProcAddress("glGenFramebuffers"));
  glBindFramebufferWam = reinterpret_cast<PFNGLBINDFRAMEBUFFERPROC>(SDL_GL_GetProcAddress("glBindFramebuffer"));
  glFramebufferTexture2DWam = reinterpret_cast<PFNGLFRAMEBUFFERTEXTURE2DPROC>(SDL_GL_GetProcAddress("glFramebufferTexture2D"));
  glCheckFramebufferStatusWam = reinterpret_cast<PFNGLCHECKFRAMEBUFFERSTATUSPROC>(SDL_GL_GetProcAddress("glCheckFramebufferStatus"));
  glDeleteFramebuffersWam = reinterpret_cast<PFNGLDELETEFRAMEBUFFERSPROC>(SDL_GL_GetProcAddress("glDeleteFramebuffers"));
  return glGenFramebuffersWam && glBindFramebufferWam && glFramebufferTexture2DWam &&
         glCheckFramebufferStatusWam && glDeleteFramebuffersWam;
}

bool resizeVideoTarget(GLuint& framebuffer, GLuint& texture, int& current_width,
                       int& current_height, int width, int height) {
  width = std::max(1, width);
  height = std::max(1, height);
  if (framebuffer && texture && width == current_width && height == current_height) return false;
  if (framebuffer) glDeleteFramebuffersWam(1, &framebuffer);
  if (texture) glDeleteTextures(1, &texture);
  framebuffer = texture = 0;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, nullptr);
  glGenFramebuffersWam(1, &framebuffer);
  glBindFramebufferWam(GL_FRAMEBUFFER, framebuffer);
  glFramebufferTexture2DWam(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                            texture, 0);
  const bool complete = glCheckFramebufferStatusWam(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  glViewport(0, 0, width, height);
  glClearColor(0.015f, 0.017f, 0.024f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glBindFramebufferWam(GL_FRAMEBUFFER, 0);
  current_width = width;
  current_height = height;
  return complete;
}

std::string timeLabel(double seconds) {
  if (!std::isfinite(seconds) || seconds < 0) seconds = 0;
  const int total = static_cast<int>(seconds);
  const int hours = total / 3600;
  const int minutes = (total / 60) % 60;
  const int secs = total % 60;
  char text[32];
  if (hours > 0)
    std::snprintf(text, sizeof(text), "%d:%02d:%02d", hours, minutes, secs);
  else
    std::snprintf(text, sizeof(text), "%02d:%02d", minutes, secs);
  return text;
}

bool systemPrefersDark() {
#ifdef __APPLE__
  CFPropertyListRef value =
      CFPreferencesCopyAppValue(CFSTR("AppleInterfaceStyle"),
                                CFSTR(".GlobalPreferences"));
  const bool dark = value && CFGetTypeID(value) == CFStringGetTypeID() &&
                    CFStringCompare(static_cast<CFStringRef>(value), CFSTR("Dark"),
                                    kCFCompareCaseInsensitive) == kCFCompareEqualTo;
  if (value) CFRelease(value);
  return dark;
#elif defined(_WIN32)
  HKEY key = nullptr;
  DWORD apps_use_light = 1;
  DWORD size = sizeof(apps_use_light);
  DWORD type = REG_DWORD;
  if (RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          0, KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
    const auto result = RegQueryValueExW(
        key, L"AppsUseLightTheme", nullptr, &type,
        reinterpret_cast<LPBYTE>(&apps_use_light), &size);
    RegCloseKey(key);
    if (result == ERROR_SUCCESS && type == REG_DWORD) return apps_use_light == 0;
  }
  return false;
#else
  const char* raw = std::getenv("GTK_THEME");
  if (!raw) raw = std::getenv("WAM_SYSTEM_THEME");
  if (!raw) return false;
  std::string theme(raw);
  std::transform(theme.begin(), theme.end(), theme.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return theme.find("dark") != std::string::npos;
#endif
}

bool resolveDarkTheme(wam::AppearanceTheme appearance) {
  if (appearance == wam::AppearanceTheme::Dark) return true;
  if (appearance == wam::AppearanceTheme::Light) return false;
  return systemPrefersDark();
}

void applyTheme(bool dark) {
  gDarkTheme = dark;
  gAccent = dark ? ImVec4(0.37f, 0.86f, 0.76f, 1.0f)
                 : ImVec4(0.035f, 0.43f, 0.39f, 1.0f);
  if (dark)
    ImGui::StyleColorsDark();
  else
    ImGui::StyleColorsLight();

  ImGuiStyle& style = ImGui::GetStyle();
  style.Alpha = 1.0f;
  style.DisabledAlpha = 0.42f;
  style.WindowRounding = 10.0f;
  style.ChildRounding = 9.0f;
  style.FrameRounding = 7.0f;
  style.PopupRounding = 9.0f;
  style.ScrollbarRounding = 9.0f;
  style.GrabRounding = 8.0f;
  style.TabRounding = 7.0f;
  style.FramePadding = ImVec2(10, 6);
  style.ItemSpacing = ImVec2(8, 7);
  style.ItemInnerSpacing = ImVec2(7, 5);
  style.WindowPadding = ImVec2(12, 10);
  style.ScrollbarSize = 12.0f;
  style.GrabMinSize = 10.0f;
  style.ChildBorderSize = 0.0f;
  style.WindowBorderSize = 0.0f;
  style.PopupBorderSize = 0.0f;
  style.FrameBorderSize = 0.0f;
  auto& c = style.Colors;
  if (dark) {
    c[ImGuiCol_WindowBg] = ImVec4(0.090f, 0.094f, 0.106f, 1.0f);
    c[ImGuiCol_ChildBg] = ImVec4(0.125f, 0.130f, 0.145f, 1.0f);
    c[ImGuiCol_PopupBg] = ImVec4(0.115f, 0.120f, 0.135f, 0.985f);
    c[ImGuiCol_MenuBarBg] = ImVec4(0.105f, 0.109f, 0.120f, 1.0f);
    c[ImGuiCol_FrameBg] = ImVec4(0.180f, 0.188f, 0.208f, 1.0f);
    c[ImGuiCol_FrameBgHovered] = ImVec4(0.235f, 0.245f, 0.270f, 1.0f);
    c[ImGuiCol_FrameBgActive] = ImVec4(0.275f, 0.288f, 0.315f, 1.0f);
    c[ImGuiCol_Button] = ImVec4(0.180f, 0.188f, 0.208f, 1.0f);
    c[ImGuiCol_ButtonHovered] = ImVec4(0.235f, 0.245f, 0.270f, 1.0f);
    c[ImGuiCol_ButtonActive] = ImVec4(0.285f, 0.298f, 0.325f, 1.0f);
    c[ImGuiCol_Header] = ImVec4(0.16f, 0.31f, 0.29f, 1.0f);
    c[ImGuiCol_HeaderHovered] = ImVec4(0.18f, 0.40f, 0.36f, 1.0f);
    c[ImGuiCol_HeaderActive] = ImVec4(0.20f, 0.47f, 0.41f, 1.0f);
    c[ImGuiCol_Border] = ImVec4(0.250f, 0.260f, 0.285f, 0.72f);
    c[ImGuiCol_Separator] = ImVec4(0.245f, 0.255f, 0.280f, 0.72f);
    c[ImGuiCol_Text] = ImVec4(0.955f, 0.960f, 0.970f, 1.0f);
    c[ImGuiCol_TextDisabled] = ImVec4(0.610f, 0.630f, 0.675f, 1.0f);
  } else {
    c[ImGuiCol_WindowBg] = ImVec4(0.961f, 0.965f, 0.973f, 1.0f);
    c[ImGuiCol_ChildBg] = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
    c[ImGuiCol_PopupBg] = ImVec4(0.995f, 0.995f, 0.998f, 0.985f);
    c[ImGuiCol_MenuBarBg] = ImVec4(0.985f, 0.987f, 0.991f, 1.0f);
    c[ImGuiCol_FrameBg] = ImVec4(0.925f, 0.933f, 0.945f, 1.0f);
    c[ImGuiCol_FrameBgHovered] = ImVec4(0.875f, 0.890f, 0.910f, 1.0f);
    c[ImGuiCol_FrameBgActive] = ImVec4(0.825f, 0.845f, 0.875f, 1.0f);
    c[ImGuiCol_Button] = ImVec4(0.925f, 0.933f, 0.945f, 1.0f);
    c[ImGuiCol_ButtonHovered] = ImVec4(0.870f, 0.885f, 0.905f, 1.0f);
    c[ImGuiCol_ButtonActive] = ImVec4(0.815f, 0.840f, 0.870f, 1.0f);
    c[ImGuiCol_Header] = ImVec4(0.835f, 0.925f, 0.905f, 1.0f);
    c[ImGuiCol_HeaderHovered] = ImVec4(0.760f, 0.885f, 0.855f, 1.0f);
    c[ImGuiCol_HeaderActive] = ImVec4(0.685f, 0.840f, 0.805f, 1.0f);
    c[ImGuiCol_Border] = ImVec4(0.835f, 0.850f, 0.875f, 1.0f);
    c[ImGuiCol_Separator] = ImVec4(0.840f, 0.855f, 0.875f, 1.0f);
    c[ImGuiCol_Text] = ImVec4(0.090f, 0.100f, 0.115f, 1.0f);
    c[ImGuiCol_TextDisabled] = ImVec4(0.390f, 0.420f, 0.470f, 1.0f);
  }
  c[ImGuiCol_SliderGrab] = gAccent;
  c[ImGuiCol_SliderGrabActive] = gAccent;
  c[ImGuiCol_CheckMark] = gAccent;
  c[ImGuiCol_ResizeGrip] = ImVec4(gAccent.x, gAccent.y, gAccent.z, 0.30f);
  c[ImGuiCol_ResizeGripHovered] = ImVec4(gAccent.x, gAccent.y, gAccent.z, 0.65f);
  c[ImGuiCol_ResizeGripActive] = gAccent;
  c[ImGuiCol_NavCursor] = gAccent;
}

ImU32 colorWithAlpha(const ImVec4& color, float alpha) {
  ImVec4 adjusted = color;
  adjusted.w *= std::clamp(alpha, 0.0f, 1.0f);
  return ImGui::ColorConvertFloat4ToU32(adjusted);
}

void itemTooltip(const char* text) {
  if (!text || !ImGui::IsItemHovered(ImGuiHoveredFlags_DelayNormal)) return;
  ImGui::BeginTooltip();
  ImGui::TextUnformatted(text);
  ImGui::EndTooltip();
}

enum class TransportIcon {
  Back,
  Play,
  Pause,
  Forward,
  Volume,
  Muted,
  Captions,
  Edit,
  More,
  Fullscreen,
};

bool transportButton(const char* id, TransportIcon icon, float size, float alpha,
                     bool primary, const char* tooltip) {
  const bool clicked = ImGui::InvisibleButton(id, ImVec2(size, size));
  const bool hovered = ImGui::IsItemHovered();
  const bool active = ImGui::IsItemActive();
  const bool focused = ImGui::IsItemFocused();
  const ImVec2 min = ImGui::GetItemRectMin();
  const ImVec2 max = ImGui::GetItemRectMax();
  const ImVec2 center((min.x + max.x) * 0.5f, (min.y + max.y) * 0.5f);
  ImDrawList* draw = ImGui::GetWindowDrawList();

  if (primary) {
    draw->AddCircleFilled(ImVec2(center.x, center.y + 2.0f), size * 0.47f,
                          IM_COL32(0, 0, 0, static_cast<int>(50 * alpha)));
    const int value = static_cast<int>((active ? 215 : hovered ? 248 : 232) * alpha);
    draw->AddCircleFilled(center, size * 0.46f, IM_COL32(value, value, value, value));
  } else if (hovered || active || focused) {
    const int value = static_cast<int>((active ? 54 : 34) * alpha);
    draw->AddCircleFilled(center, size * 0.46f, IM_COL32(255, 255, 255, value));
  }
  if (focused) {
    draw->AddCircle(center, size * 0.48f,
                    IM_COL32(110, 235, 214, static_cast<int>(230 * alpha)), 0,
                    2.0f);
  }

  const ImU32 icon_color = primary
                               ? IM_COL32(18, 20, 23, static_cast<int>(255 * alpha))
                               : IM_COL32(255, 255, 255, static_cast<int>(238 * alpha));
  const float thickness = primary ? 2.4f : 2.0f;
  switch (icon) {
    case TransportIcon::Play: {
      const float r = size * 0.18f;
      draw->AddTriangleFilled(ImVec2(center.x - r * 0.58f, center.y - r),
                              ImVec2(center.x - r * 0.58f, center.y + r),
                              ImVec2(center.x + r, center.y), icon_color);
      break;
    }
    case TransportIcon::Pause: {
      const float h = size * 0.18f;
      const float w = std::max(2.0f, size * 0.055f);
      draw->AddRectFilled(ImVec2(center.x - w * 2.0f, center.y - h),
                          ImVec2(center.x - w * 0.35f, center.y + h), icon_color,
                          1.0f);
      draw->AddRectFilled(ImVec2(center.x + w * 0.35f, center.y - h),
                          ImVec2(center.x + w * 2.0f, center.y + h), icon_color,
                          1.0f);
      break;
    }
    case TransportIcon::Back:
    case TransportIcon::Forward: {
      const float direction = icon == TransportIcon::Back ? -1.0f : 1.0f;
      const float x0 = center.x - direction * 6.0f;
      const float x1 = center.x + direction * 7.0f;
      draw->AddLine(ImVec2(x0, center.y), ImVec2(x1, center.y), icon_color,
                    thickness);
      draw->AddLine(ImVec2(x1, center.y),
                    ImVec2(x1 - direction * 5.0f, center.y - 4.5f), icon_color,
                    thickness);
      draw->AddLine(ImVec2(x1, center.y),
                    ImVec2(x1 - direction * 5.0f, center.y + 4.5f), icon_color,
                    thickness);
      const char* five = "5";
      const ImVec2 text_size = ImGui::CalcTextSize(five);
      draw->AddText(ImVec2(center.x - direction * 8.0f - text_size.x * 0.5f,
                           center.y - text_size.y * 0.5f),
                    icon_color, five);
      break;
    }
    case TransportIcon::Volume:
    case TransportIcon::Muted: {
      draw->AddRectFilled(ImVec2(center.x - 9, center.y - 3),
                          ImVec2(center.x - 5, center.y + 3), icon_color, 1.0f);
      draw->AddTriangleFilled(ImVec2(center.x - 5, center.y - 3),
                              ImVec2(center.x + 1, center.y - 8),
                              ImVec2(center.x + 1, center.y + 8), icon_color);
      if (icon == TransportIcon::Muted) {
        draw->AddLine(ImVec2(center.x + 5, center.y - 5),
                      ImVec2(center.x + 11, center.y + 5), icon_color, thickness);
        draw->AddLine(ImVec2(center.x + 11, center.y - 5),
                      ImVec2(center.x + 5, center.y + 5), icon_color, thickness);
      } else {
        draw->PathArcTo(center, 8.0f, -0.72f, 0.72f, 10);
        draw->PathStroke(icon_color, 0, thickness);
        draw->PathArcTo(center, 12.0f, -0.68f, 0.68f, 12);
        draw->PathStroke(icon_color, 0, thickness);
      }
      break;
    }
    case TransportIcon::Captions: {
      draw->AddRect(ImVec2(center.x - 10, center.y - 7),
                    ImVec2(center.x + 10, center.y + 7), icon_color, 2.5f, 0,
                    thickness);
      const char* cc = "CC";
      const ImVec2 text_size = ImGui::CalcTextSize(cc);
      draw->AddText(ImVec2(center.x - text_size.x * 0.5f,
                           center.y - text_size.y * 0.5f), icon_color, cc);
      break;
    }
    case TransportIcon::Edit: {
      draw->AddLine(ImVec2(center.x - 7, center.y + 7),
                    ImVec2(center.x + 6, center.y - 6), icon_color, 3.0f);
      draw->AddTriangleFilled(ImVec2(center.x - 9, center.y + 9),
                              ImVec2(center.x - 5, center.y + 8),
                              ImVec2(center.x - 8, center.y + 5), icon_color);
      draw->AddLine(ImVec2(center.x + 4, center.y - 7),
                    ImVec2(center.x + 8, center.y - 3), icon_color, 3.0f);
      break;
    }
    case TransportIcon::More: {
      draw->AddCircleFilled(ImVec2(center.x - 7.0f, center.y), 1.8f, icon_color);
      draw->AddCircleFilled(center, 1.8f, icon_color);
      draw->AddCircleFilled(ImVec2(center.x + 7.0f, center.y), 1.8f, icon_color);
      break;
    }
    case TransportIcon::Fullscreen: {
      const float a = 9.0f, b = 3.0f;
      draw->AddLine(ImVec2(center.x - a, center.y - b),
                    ImVec2(center.x - a, center.y - a), icon_color, thickness);
      draw->AddLine(ImVec2(center.x - a, center.y - a),
                    ImVec2(center.x - b, center.y - a), icon_color, thickness);
      draw->AddLine(ImVec2(center.x + a, center.y - b),
                    ImVec2(center.x + a, center.y - a), icon_color, thickness);
      draw->AddLine(ImVec2(center.x + a, center.y - a),
                    ImVec2(center.x + b, center.y - a), icon_color, thickness);
      draw->AddLine(ImVec2(center.x - a, center.y + b),
                    ImVec2(center.x - a, center.y + a), icon_color, thickness);
      draw->AddLine(ImVec2(center.x - a, center.y + a),
                    ImVec2(center.x - b, center.y + a), icon_color, thickness);
      draw->AddLine(ImVec2(center.x + a, center.y + b),
                    ImVec2(center.x + a, center.y + a), icon_color, thickness);
      draw->AddLine(ImVec2(center.x + a, center.y + a),
                    ImVec2(center.x + b, center.y + a), icon_color, thickness);
      break;
    }
  }
  itemTooltip(tooltip);
  return clicked;
}

bool overlayPillButton(const char* id, const char* label, ImVec2 size,
                       float alpha, const char* tooltip) {
  ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, size.y * 0.5f);
  ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(10, 4));
  ImGui::PushStyleColor(ImGuiCol_Text,
                        ImVec4(1.0f, 1.0f, 1.0f, 0.94f * alpha));
  ImGui::PushStyleColor(ImGuiCol_Button,
                        ImVec4(1.0f, 1.0f, 1.0f, 0.075f * alpha));
  ImGui::PushStyleColor(ImGuiCol_ButtonHovered,
                        ImVec4(1.0f, 1.0f, 1.0f, 0.15f * alpha));
  ImGui::PushStyleColor(ImGuiCol_ButtonActive,
                        ImVec4(1.0f, 1.0f, 1.0f, 0.22f * alpha));
  const bool clicked = ImGui::Button((std::string(label) + "##" + id).c_str(), size);
  itemTooltip(tooltip);
  ImGui::PopStyleColor(4);
  ImGui::PopStyleVar(2);
  return clicked;
}

bool seekBar(const char* id, float& position, float width, float alpha,
             double duration, double trim_in, double trim_out,
             const std::vector<wam::ChapterItem>& chapters) {
  const float hit_height = 18.0f;
  ImGui::InvisibleButton(id, ImVec2(width, hit_height));
  const bool hovered = ImGui::IsItemHovered();
  const bool active = ImGui::IsItemActive();
  bool changed = false;
  const ImVec2 min = ImGui::GetItemRectMin();
  const ImVec2 max = ImGui::GetItemRectMax();
  if ((hovered && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) || active) {
    position = std::clamp((ImGui::GetIO().MousePos.x - min.x) /
                              std::max(1.0f, max.x - min.x),
                          0.0f, 1.0f);
    changed = true;
  }

  ImDrawList* draw = ImGui::GetWindowDrawList();
  const float track_height = (hovered || active) ? 5.0f : 3.0f;
  const float y = (min.y + max.y) * 0.5f;
  const float radius = track_height * 0.5f;
  draw->AddRectFilled(ImVec2(min.x, y - radius), ImVec2(max.x, y + radius),
                      IM_COL32(255, 255, 255, static_cast<int>(62 * alpha)),
                      radius);
  if (duration > 0.0 && trim_out > trim_in) {
    const float x1 = min.x + width * std::clamp(trim_in / duration, 0.0, 1.0);
    const float x2 = min.x + width * std::clamp(trim_out / duration, 0.0, 1.0);
    draw->AddRectFilled(ImVec2(x1, y - 5), ImVec2(x2, y + 5),
                        IM_COL32(94, 224, 201, static_cast<int>(52 * alpha)),
                        4.0f);
  }
  const float played_x = min.x + width * std::clamp(position, 0.0f, 1.0f);
  draw->AddRectFilled(ImVec2(min.x, y - radius),
                      ImVec2(std::max(min.x + radius, played_x), y + radius),
                      IM_COL32(88, 222, 198, static_cast<int>(245 * alpha)),
                      radius);
  if (duration > 0.0) {
    for (const auto& chapter : chapters) {
      const float x = min.x + width *
                                  static_cast<float>(std::clamp(chapter.time / duration,
                                                                 0.0, 1.0));
      draw->AddLine(ImVec2(x, y - 5), ImVec2(x, y + 5),
                    IM_COL32(255, 255, 255, static_cast<int>(120 * alpha)), 1.0f);
    }
  }
  if (hovered || active) {
    draw->AddCircleFilled(ImVec2(played_x, y), active ? 6.0f : 5.0f,
                          IM_COL32(255, 255, 255, static_cast<int>(255 * alpha)));
  }
  if (hovered && duration > 0.0) {
    const double hover_time = duration * std::clamp(
        (ImGui::GetIO().MousePos.x - min.x) / std::max(1.0f, width), 0.0f, 1.0f);
    ImGui::BeginTooltip();
    ImGui::TextUnformatted(timeLabel(hover_time).c_str());
    ImGui::EndTooltip();
  }
  return changed;
}

bool valueBar(const char* id, float& value, float minimum, float maximum,
              float width, float alpha, const char* tooltip_prefix) {
  ImGui::InvisibleButton(id, ImVec2(width, 20.0f));
  const bool hovered = ImGui::IsItemHovered();
  const bool active = ImGui::IsItemActive();
  const ImVec2 min = ImGui::GetItemRectMin();
  const ImVec2 max = ImGui::GetItemRectMax();
  bool changed = false;
  if ((hovered && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) || active) {
    const float fraction = std::clamp(
        (ImGui::GetIO().MousePos.x - min.x) / std::max(1.0f, max.x - min.x),
        0.0f, 1.0f);
    value = minimum + (maximum - minimum) * fraction;
    changed = true;
  }
  const float fraction = std::clamp((value - minimum) /
                                        std::max(0.001f, maximum - minimum),
                                    0.0f, 1.0f);
  const float y = (min.y + max.y) * 0.5f;
  ImDrawList* draw = ImGui::GetWindowDrawList();
  draw->AddRectFilled(ImVec2(min.x, y - 1.5f), ImVec2(max.x, y + 1.5f),
                      IM_COL32(255, 255, 255, static_cast<int>(62 * alpha)),
                      2.0f);
  const float x = min.x + width * fraction;
  draw->AddRectFilled(ImVec2(min.x, y - 1.5f), ImVec2(x, y + 1.5f),
                      IM_COL32(255, 255, 255, static_cast<int>(220 * alpha)),
                      2.0f);
  draw->AddCircleFilled(ImVec2(x, y), hovered || active ? 5.0f : 4.0f,
                        IM_COL32(255, 255, 255, static_cast<int>(245 * alpha)));
  if (hovered && tooltip_prefix) {
    ImGui::BeginTooltip();
    ImGui::Text("%s %.0f%%", tooltip_prefix, value);
    ImGui::EndTooltip();
  }
  return changed;
}

bool closeButton(const char* id, const char* tooltip) {
  constexpr float size = 28.0f;
  const bool clicked = ImGui::InvisibleButton(id, ImVec2(size, size));
  const bool hovered = ImGui::IsItemHovered();
  const bool active = ImGui::IsItemActive();
  const bool focused = ImGui::IsItemFocused();
  const ImVec2 min = ImGui::GetItemRectMin();
  const ImVec2 max = ImGui::GetItemRectMax();
  const ImVec2 center((min.x + max.x) * 0.5f, (min.y + max.y) * 0.5f);
  ImDrawList* draw = ImGui::GetWindowDrawList();
  if (hovered || active)
    draw->AddCircleFilled(center, 13.0f,
                          ImGui::GetColorU32(active ? ImGuiCol_ButtonActive
                                                   : ImGuiCol_ButtonHovered));
  if (focused)
    draw->AddCircle(center, 13.0f, colorWithAlpha(gAccent, 1.0f), 0, 2.0f);
  const ImU32 color = ImGui::GetColorU32(ImGuiCol_TextDisabled);
  draw->AddLine(ImVec2(center.x - 4.5f, center.y - 4.5f),
                ImVec2(center.x + 4.5f, center.y + 4.5f), color, 1.8f);
  draw->AddLine(ImVec2(center.x + 4.5f, center.y - 4.5f),
                ImVec2(center.x - 4.5f, center.y + 4.5f), color, 1.8f);
  itemTooltip(tooltip);
  return clicked;
}

bool primaryButton(const char* label, ImVec2 size) {
  const ImVec4 hovered(std::max(0.0f, gAccent.x - 0.045f),
                       std::max(0.0f, gAccent.y - 0.045f),
                       std::max(0.0f, gAccent.z - 0.045f), 1.0f);
  const ImVec4 active(std::max(0.0f, gAccent.x - 0.09f),
                      std::max(0.0f, gAccent.y - 0.09f),
                      std::max(0.0f, gAccent.z - 0.09f), 1.0f);
  ImGui::PushStyleColor(ImGuiCol_Button, gAccent);
  ImGui::PushStyleColor(ImGuiCol_ButtonHovered, hovered);
  ImGui::PushStyleColor(ImGuiCol_ButtonActive, active);
  ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1, 1, 1, 1));
  const bool clicked = ImGui::Button(label, size);
  ImGui::PopStyleColor(4);
  return clicked;
}

void loadUiFont(ImGuiIO& io, SDL_Window* window) {
  int window_width = 0, window_height = 0;
  int drawable_width = 0, drawable_height = 0;
  SDL_GetWindowSize(window, &window_width, &window_height);
  SDL_GL_GetDrawableSize(window, &drawable_width, &drawable_height);
  const float backing_scale = window_width > 0
                                  ? std::max(1.0f, static_cast<float>(drawable_width) / window_width)
                                  : 1.0f;

#ifdef __APPLE__
  const char* candidates[] = {
      "/System/Library/Fonts/SFNS.ttf",
      "/System/Library/Fonts/Helvetica.ttc",
  };
#elif defined(_WIN32)
  const char* candidates[] = {
      "C:/Windows/Fonts/segoeui.ttf",
      "C:/Windows/Fonts/arial.ttf",
  };
#else
  const char* candidates[] = {
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
      "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
  };
#endif

  ImFontConfig config;
  config.OversampleH = 2;
  config.OversampleV = 2;
  config.RasterizerMultiply = 1.05f;
  for (const char* candidate : candidates) {
    if (!fs::exists(candidate)) continue;
    if (ImFont* font = io.Fonts->AddFontFromFileTTF(candidate, 15.0f * backing_scale,
                                                   &config, io.Fonts->GetGlyphRangesDefault())) {
      io.FontDefault = font;
      io.FontGlobalScale = 1.0f / backing_scale;
      return;
    }
  }
  io.Fonts->AddFontDefault();
}

void openFile(wam::MediaEngine& media, const fs::path& path,
              double& edit_in, double& edit_out, std::string& notice,
              const wam::StateStore* state = nullptr,
              double* pending_resume = nullptr) {
  if (path.empty()) return;
  if (media.open(path.string())) {
    edit_in = 0;
    edit_out = 0;
    if (pending_resume)
      *pending_resume = state ? state->positionFor(path.string()) : 0.0;
    notice = "Opened " + path.filename().string();
  } else {
    notice = "Could not open that media source.";
  }
}

std::vector<std::string> mediaFilters() {
  return {"Media files", "*.mp4 *.mkv *.mov *.avi *.webm *.m4v *.mp3 *.m4a *.wav *.flac *.ogg *.opus *.aac *.ts *.m2ts *.wmv *.flv",
          "All files", "*"};
}

}  // namespace

int main(int argc, char** argv) {
  SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
  SDL_SetHint(SDL_HINT_MAC_CTRL_CLICK_EMULATE_RIGHT_CLICK, "1");
  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER) != 0) return 1;

  SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
  SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 0);
  SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 0);

  SDL_Window* window = SDL_CreateWindow(
      "WAM", SDL_WINDOWPOS_CENTERED,
      SDL_WINDOWPOS_CENTERED, 1280, 780,
      SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
  if (!window) {
    SDL_Quit();
    return 2;
  }
  SDL_GLContext gl_context = SDL_GL_CreateContext(window);
  if (!gl_context || !loadFramebufferFunctions()) {
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 3;
  }
  SDL_GL_MakeCurrent(window, gl_context);
  SDL_GL_SetSwapInterval(1);

  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO& io = ImGui::GetIO();
  io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
  io.IniFilename = nullptr;
  applyTheme(false);
  loadUiFont(io, window);
  ImGui_ImplSDL2_InitForOpenGL(window, gl_context);
  ImGui_ImplOpenGL3_Init("#version 150");

  wam::MediaEngine media;
  if (!media.valid()) {
    pfd::message("WAM could not start", "WAM needs its bundled GPU playback engine.",
                 pfd::choice::ok, pfd::icon::error);
    return 4;
  }

  wam::StateStore state_store;
  const bool restored_state = state_store.load();
  auto appearance_theme = state_store.state().appearance_theme;
  bool dark_theme = resolveDarkTheme(appearance_theme);
  applyTheme(dark_theme);
  auto last_system_theme_check = std::chrono::steady_clock::now();
  int initial_profile = std::clamp(state_store.state().performance_profile, 0, 2);
  int battery_seconds = -1;
  int battery_percent = -1;
  if (!restored_state &&
      SDL_GetPowerInfo(&battery_seconds, &battery_percent) ==
          SDL_POWERSTATE_ON_BATTERY) {
    initial_profile = 0;
    state_store.state().performance_profile = 0;
  }
  const auto saved_profile =
      static_cast<wam::PerformanceProfile>(initial_profile);
  media.setPerformanceProfile(saved_profile);
  media.setVolume(state_store.state().volume);

  GLuint video_texture = 0;
  GLuint video_framebuffer = 0;
  int texture_width = 0, texture_height = 0;
  bool running = true;
  bool show_editor = false;
  bool show_stats = false;
  bool show_queue = false;
  bool show_video_adjustments = false;
  bool show_url_popup = false;
  bool menu_bar_pinned = false;
  bool fullscreen = false;
  bool always_on_top = false;
  bool mini_player = false;
  float controls_alpha = 1.0f;
  bool controls_hovered = false;
  auto last_controls_activity = std::chrono::steady_clock::now();
  auto last_controls_frame = last_controls_activity;
  std::string titled_source;
  int regular_window_width = 1280;
  int regular_window_height = 780;
  float playback_rate = 1.0f;
  int volume = state_store.state().volume;
  double edit_in = 0.0;
  double edit_out = 0.0;
  double loop_a = -1.0;
  double loop_b = -1.0;
  float export_speed = 1.0f;
  bool preserve_pitch = true;
  bool restore_positions = state_store.state().restore_positions;
  double pending_resume = 0.0;
  float brightness = 0.0f;
  float contrast = 0.0f;
  float saturation = 0.0f;
  float gamma = 0.0f;
  char url_buffer[2048]{};
  std::string notice = "Drop any media file here, or choose Open.";
  bool job_handled = true;
  bool export_cancel_requested = false;
  bool caption_handled = true;
  wam::BackgroundJob job;
  wam::CaptionService caption_service;
  auto caption_tools = wam::findCaptionTools(argv[0]);
  const auto ffmpeg = caption_tools.ffmpeg;

  if (argc > 1)
    openFile(media, argv[1], edit_in, edit_out, notice, &state_store,
             &pending_resume);

  auto chooseMedia = [&] {
    auto selection = pfd::open_file("Open media", "", mediaFilters(), pfd::opt::none).result();
    if (!selection.empty())
      openFile(media, selection.front(), edit_in, edit_out, notice, &state_store,
               &pending_resume);
  };

  auto toggleFullscreen = [&] {
    fullscreen = !fullscreen;
    SDL_SetWindowFullscreen(window, fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
  };

  auto toggleMiniPlayer = [&] {
    mini_player = !mini_player;
    if (mini_player) {
      if (fullscreen) toggleFullscreen();
      SDL_GetWindowSize(window, &regular_window_width, &regular_window_height);
      SDL_SetWindowSize(window, 560, 360);
      SDL_SetWindowAlwaysOnTop(window, SDL_TRUE);
    } else {
      SDL_SetWindowSize(window, regular_window_width, regular_window_height);
      SDL_SetWindowAlwaysOnTop(window, always_on_top ? SDL_TRUE : SDL_FALSE);
    }
  };

  auto generateCaptions = [&] {
    if (media.source().empty() || media.source().find("://") != std::string::npos) {
      notice = "Open a local media file before generating captions.";
      return;
    }
    if (job.running() || caption_service.running()) {
      notice = "Another media task is already running.";
      return;
    }
    if (!fs::exists(caption_tools.model)) {
      auto model = pfd::open_file("Choose a whisper.cpp model", "",
                                  {"Whisper model", "*.bin", "All files", "*"}).result();
      if (!model.empty()) caption_tools.model = model.front();
    }
    if (!fs::exists(caption_tools.model)) {
      notice = "Caption model not found. Choose a ggml Whisper model.";
      return;
    }
    const fs::path input(media.source());
    auto output = pfd::save_file("Save captions", input.stem().string() + ".srt",
                                 {"SubRip captions", "*.srt"}).result();
    if (output.empty()) return;
    wam::CaptionRequest request;
    request.input = input;
    request.output_srt = output;
    request.tools = caption_tools;
    request.options.use_gpu = false;
    if (caption_service.start(std::move(request))) {
      caption_handled = false;
      notice = "Preparing on-device captions…";
    }
  };

  auto last_state_save = std::chrono::steady_clock::now();

  while (running) {
    SDL_Event event;
    bool had_event = false;
    while (SDL_PollEvent(&event)) {
      had_event = true;
      bool handled_shortcut = false;
      if (event.type == SDL_MOUSEMOTION || event.type == SDL_MOUSEBUTTONDOWN ||
          event.type == SDL_MOUSEWHEEL || event.type == SDL_KEYDOWN) {
        last_controls_activity = std::chrono::steady_clock::now();
        controls_alpha = 1.0f;
      }
      if (event.type == SDL_QUIT) running = false;
      if (event.type == SDL_DROPFILE) {
        openFile(media, event.drop.file, edit_in, edit_out, notice, &state_store,
                 &pending_resume);
        SDL_free(event.drop.file);
      }
      if (event.type == SDL_KEYDOWN) {
        const auto key = event.key.keysym.sym;
        const auto modifiers = event.key.keysym.mod;
        const bool plain_shortcut =
            (modifiers & (KMOD_CTRL | KMOD_GUI | KMOD_ALT)) == 0;
        const bool popup_open =
            ImGui::IsPopupOpen(nullptr, ImGuiPopupFlags_AnyPopupId);
        const bool text_editing = io.WantTextInput || SDL_IsTextInputActive();
        const bool media_shortcut = plain_shortcut && !popup_open && !text_editing;
        const bool repeat = event.key.repeat != 0;
        if (media_shortcut && key == SDLK_LEFT) {
          media.seekSeconds(media.timeSeconds() - 5);
          notice = "Back 5 seconds";
          handled_shortcut = true;
        } else if (media_shortcut && key == SDLK_RIGHT) {
          media.seekSeconds(media.timeSeconds() + 5);
          notice = "Forward 5 seconds";
          handled_shortcut = true;
        } else if (media_shortcut && key == SDLK_UP) {
          volume = std::min(200, volume + 5);
          media.setVolume(volume);
          handled_shortcut = true;
        } else if (media_shortcut && key == SDLK_DOWN) {
          volume = std::max(0, volume - 5);
          media.setVolume(volume);
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_SPACE) {
          media.togglePause();
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_f) {
          toggleFullscreen();
          handled_shortcut = true;
        } else if (media_shortcut && key == SDLK_PERIOD) {
          media.frameStep();
          handled_shortcut = true;
        } else if (media_shortcut && key == SDLK_COMMA) {
          media.frameBackStep();
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_n) {
          media.next();
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_p) {
          media.previous();
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_m) {
          media.toggleMute();
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_e) {
          show_editor = !show_editor;
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_i) {
          show_stats = !show_stats;
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_q) {
          show_queue = !show_queue;
          handled_shortcut = true;
        } else if (media_shortcut && !repeat && key == SDLK_0) {
          playback_rate = 1.0f;
          media.setRate(playback_rate);
          handled_shortcut = true;
        } else if (media_shortcut && key == SDLK_LEFTBRACKET) {
          playback_rate = std::max(0.25f, playback_rate - 0.1f);
          media.setRate(playback_rate);
          handled_shortcut = true;
        } else if (media_shortcut && key == SDLK_RIGHTBRACKET) {
          playback_rate = std::min(4.0f, playback_rate + 0.1f);
          media.setRate(playback_rate);
          handled_shortcut = true;
        } else if (!repeat && key == SDLK_o &&
                   (modifiers & (KMOD_CTRL | KMOD_GUI))) {
          chooseMedia();
          handled_shortcut = true;
        }
      }
      if (!handled_shortcut) ImGui_ImplSDL2_ProcessEvent(&event);
    }
    media.processEvents();
    if (media.source() != titled_source) {
      titled_source = media.source();
      std::string title = "WAM";
      if (!titled_source.empty()) {
        std::string item = titled_source.find("://") != std::string::npos
                               ? "Network stream"
                               : fs::path(titled_source).filename().string();
        if (item.empty()) item = "Media";
        if (item.size() > 72) item = item.substr(0, 69) + "…";
        title = item + " — WAM";
      }
      SDL_SetWindowTitle(window, title.c_str());
    }
    const bool mpv_frame_requested = media.needsRender();
    bool asynchronous_change = false;

    if (pending_resume >= 5.0 && media.durationSeconds() > 0.0) {
      if (pending_resume < media.durationSeconds() - 5.0) {
        media.seekSeconds(pending_resume);
        notice = "Resumed at " + timeLabel(pending_resume) + ".";
      }
      pending_resume = 0.0;
      asynchronous_change = true;
    }

    if (job.finished() && !job_handled) {
      if (job.succeeded()) {
        notice = job.label() + " finished.";
      } else if (export_cancel_requested) {
        notice = job.label() + " cancelled.";
      } else {
        notice = job.label() + " failed. Check that the bundled media tools are available.";
      }
      job_handled = true;
      export_cancel_requested = false;
      asynchronous_change = true;
    }
    const auto caption_status = caption_service.status();
    if (caption_status.finished && !caption_handled) {
      if (caption_status.succeeded) {
        notice = media.addSubtitle(caption_status.output_srt)
                     ? "Captions generated and enabled."
                     : "Captions were generated, but could not be attached.";
      } else if (caption_status.cancelled) {
        notice = "Caption generation cancelled.";
      } else {
        notice = caption_status.error.empty() ? "Caption generation failed."
                                              : caption_status.error;
      }
      caption_handled = true;
      asynchronous_change = true;
    }

    const auto animation_now = std::chrono::steady_clock::now();
    if (appearance_theme == wam::AppearanceTheme::System &&
        animation_now - last_system_theme_check >= std::chrono::seconds(2)) {
      const bool system_dark = systemPrefersDark();
      if (system_dark != dark_theme) {
        dark_theme = system_dark;
        applyTheme(dark_theme);
        asynchronous_change = true;
      }
      last_system_theme_check = animation_now;
    }
    const bool video_loaded = !media.source().empty() &&
                              media.infoInt("video-params/w") > 0 &&
                              media.infoInt("video-params/h") > 0;
    const bool controls_should_show =
        !video_loaded || !media.isPlaying() || controls_hovered ||
        ImGui::IsPopupOpen(nullptr, ImGuiPopupFlags_AnyPopupId) ||
        animation_now - last_controls_activity < std::chrono::milliseconds(2250);
    const float controls_target = controls_should_show ? 1.0f : 0.0f;
    const float controls_delta = std::clamp(
        std::chrono::duration<float>(animation_now - last_controls_frame).count(),
        0.0f, 0.05f);
    last_controls_frame = animation_now;
    const float fade_speed = controls_target > controls_alpha ? 12.0f : 6.0f;
    controls_alpha += (controls_target - controls_alpha) *
                      std::min(1.0f, controls_delta * fade_speed);
    if (controls_target == 0.0f && controls_alpha < 0.01f) controls_alpha = 0.0f;
    const bool overlay_animating =
        std::abs(controls_target - controls_alpha) > 0.01f;

    if (running && !had_event && !asynchronous_change && !mpv_frame_requested &&
        !job.running() && !caption_service.running() &&
        !overlay_animating &&
        (media.source().empty() || !media.isPlaying())) {
      SDL_Event waited_event;
      if (SDL_WaitEventTimeout(&waited_event, 1000))
        SDL_PushEvent(&waited_event);
      continue;
    }

    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL2_NewFrame();
    ImGui::NewFrame();

    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(viewport->WorkPos);
    ImGui::SetNextWindowSize(viewport->WorkSize);
    const bool show_window_menu = media.source().empty() || menu_bar_pinned;
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGui::Begin("WAM", nullptr,
                 ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                     ImGuiWindowFlags_NoSavedSettings |
                     (show_window_menu ? ImGuiWindowFlags_MenuBar : 0));
    ImGui::PopStyleVar(3);

    if (show_window_menu && ImGui::BeginMenuBar()) {
      if (ImGui::BeginMenu("File")) {
        if (ImGui::MenuItem("Open media…", "Ctrl+O")) chooseMedia();
        if (ImGui::MenuItem("Add files to queue…")) {
          auto queued = pfd::open_file("Add media to queue", "", mediaFilters(), pfd::opt::multiselect).result();
          for (const auto& item : queued) media.enqueue(item);
          if (!queued.empty()) notice = std::to_string(queued.size()) + " item(s) added to the queue.";
        }
        if (ImGui::MenuItem("Open network stream…")) show_url_popup = true;
        if (ImGui::MenuItem("Add subtitle…")) {
          auto s = pfd::open_file("Add subtitle", "", {"Subtitles", "*.srt *.vtt *.ass *.ssa", "All files", "*"}).result();
          if (!s.empty()) notice = media.addSubtitle(s.front()) ? "Subtitle added." : "Could not add subtitle.";
        }
        if (ImGui::MenuItem("Take snapshot…", nullptr, false, !media.source().empty())) {
          auto path = pfd::save_file("Save snapshot", "wam-snapshot.png", {"PNG image", "*.png"}).result();
          if (!path.empty()) notice = media.snapshot(path) ? "Snapshot saved." : "Snapshot failed.";
        }
        if (!media.recording()) {
          if (ImGui::MenuItem("Record playing stream…", nullptr, false,
                              !media.source().empty())) {
            auto output = pfd::save_file("Record stream", "wam-recording.mkv",
                                         {"Matroska video", "*.mkv"}).result();
            if (!output.empty()) {
              if (fs::path(output).extension().empty()) output += ".mkv";
              notice = media.startRecording(output)
                           ? "Recording the original stream without re-encoding."
                           : "Could not start recording this source.";
            }
          }
        } else if (ImGui::MenuItem("Stop recording")) {
          media.stopRecording();
          notice = "Recording saved.";
        }
        ImGui::Separator();
        if (ImGui::MenuItem("Quit")) running = false;
        ImGui::EndMenu();
      }
      if (ImGui::BeginMenu("Playback")) {
        if (ImGui::MenuItem(media.isPlaying() ? "Pause" : "Play", "Space")) media.togglePause();
        if (ImGui::MenuItem("Stop")) media.stop();
        if (ImGui::MenuItem("Back 5 seconds", "Left")) media.seekSeconds(media.timeSeconds() - 5);
        if (ImGui::MenuItem("Forward 5 seconds", "Right")) media.seekSeconds(media.timeSeconds() + 5);
        if (ImGui::MenuItem("Previous item", "P")) media.previous();
        if (ImGui::MenuItem("Next item", "N")) media.next();
        if (ImGui::BeginMenu("Chapters")) {
          const auto chapters = media.chapters();
          if (chapters.empty()) ImGui::TextDisabled("No chapters");
          for (const auto& chapter : chapters) {
            const auto label = timeLabel(chapter.time) + "  " + chapter.title;
            if (ImGui::MenuItem(label.c_str())) media.seekChapter(chapter.index);
          }
          ImGui::EndMenu();
        }
        ImGui::Separator();
        if (ImGui::MenuItem("Previous frame", ",")) media.frameBackStep();
        if (ImGui::MenuItem("Next frame", ".")) media.frameStep();
        ImGui::Separator();
        if (ImGui::MenuItem("Set loop start here")) loop_a = media.timeSeconds();
        if (ImGui::MenuItem("Set loop end here", nullptr, false, loop_a >= 0)) {
          loop_b = media.timeSeconds();
          if (loop_b > loop_a) media.setABLoop(loop_a, loop_b);
        }
        if (ImGui::MenuItem("Clear A–B loop", nullptr, false, loop_a >= 0)) {
          loop_a = loop_b = -1;
          media.clearABLoop();
        }
        bool loop_file = media.fileLoop();
        if (ImGui::MenuItem("Repeat current item", nullptr, loop_file))
          media.setFileLoop(!loop_file);
        if (ImGui::MenuItem("Fullscreen", "F", fullscreen)) toggleFullscreen();
        ImGui::EndMenu();
      }
      if (ImGui::BeginMenu("Audio")) {
        bool muted = media.muted();
        if (ImGui::MenuItem("Mute", "M", muted)) media.toggleMute();
        ImGui::Separator();
        for (const auto& [id, name] : media.audioTracks())
          if (ImGui::MenuItem(name.c_str(), nullptr, id == media.currentAudioTrack())) media.setAudioTrack(id);
        if (ImGui::BeginMenu("Output device")) {
          const auto current_device = media.currentAudioDevice();
          if (ImGui::MenuItem("Automatic", nullptr, current_device == "auto"))
            media.setAudioDevice("auto");
          for (const auto& device : media.audioDevices())
            if (ImGui::MenuItem(device.description.c_str(), nullptr,
                                current_device == device.name))
              media.setAudioDevice(device.name);
          ImGui::EndMenu();
        }
        ImGui::Separator();
        float delay = static_cast<float>(media.audioDelay());
        ImGui::SetNextItemWidth(180);
        if (ImGui::SliderFloat("Audio sync", &delay, -10.0f, 10.0f, "%+.2f s")) media.setAudioDelay(delay);
        ImGui::EndMenu();
      }
      if (ImGui::BeginMenu("Subtitles")) {
        bool subtitles_visible = media.subtitleVisible();
        if (ImGui::MenuItem("Show subtitles", nullptr, subtitles_visible))
          media.setSubtitleVisible(!subtitles_visible);
        if (ImGui::MenuItem("Generate captions on device…", nullptr, false,
                            !media.source().empty() && !caption_service.running()))
          generateCaptions();
        if (caption_service.running() && ImGui::MenuItem("Cancel caption generation"))
          caption_service.cancel();
        ImGui::Separator();
        for (const auto& [id, name] : media.subtitleTracks())
          if (ImGui::MenuItem(name.c_str(), nullptr, id == media.currentSubtitleTrack())) media.setSubtitleTrack(id);
        ImGui::Separator();
        float delay = static_cast<float>(media.subtitleDelay());
        ImGui::SetNextItemWidth(180);
        if (ImGui::SliderFloat("Subtitle sync", &delay, -30.0f, 30.0f, "%+.2f s")) media.setSubtitleDelay(delay);
        float scale = static_cast<float>(media.subtitleScale());
        ImGui::SetNextItemWidth(180);
        if (ImGui::SliderFloat("Subtitle size", &scale, 0.5f, 2.5f, "%.2fx"))
          media.setSubtitleScale(scale);
        ImGui::EndMenu();
      }
      if (ImGui::BeginMenu("Video")) {
        if (ImGui::BeginMenu("Aspect ratio")) {
          if (ImGui::MenuItem("Automatic")) media.setAspect("no");
          if (ImGui::MenuItem("16:9")) media.setAspect("16:9");
          if (ImGui::MenuItem("4:3")) media.setAspect("4:3");
          if (ImGui::MenuItem("21:9")) media.setAspect("21:9");
          if (ImGui::MenuItem("1:1")) media.setAspect("1:1");
          ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("Rotate")) {
          if (ImGui::MenuItem("0°")) media.setRotation(0);
          if (ImGui::MenuItem("90°")) media.setRotation(90);
          if (ImGui::MenuItem("180°")) media.setRotation(180);
          if (ImGui::MenuItem("270°")) media.setRotation(270);
          ImGui::EndMenu();
        }
        bool deinterlace = media.deinterlace();
        if (ImGui::MenuItem("Deinterlace", nullptr, deinterlace)) media.setDeinterlace(!deinterlace);
        ImGui::MenuItem("Picture adjustments…", nullptr, &show_video_adjustments);
        ImGui::EndMenu();
      }
      if (ImGui::BeginMenu("View")) {
        if (ImGui::BeginMenu("Appearance")) {
          if (ImGui::MenuItem("Light", nullptr,
                              appearance_theme == wam::AppearanceTheme::Light)) {
            appearance_theme = wam::AppearanceTheme::Light;
            state_store.state().appearance_theme = appearance_theme;
            dark_theme = false;
            applyTheme(false);
          }
          if (ImGui::MenuItem("Dark", nullptr,
                              appearance_theme == wam::AppearanceTheme::Dark)) {
            appearance_theme = wam::AppearanceTheme::Dark;
            state_store.state().appearance_theme = appearance_theme;
            dark_theme = true;
            applyTheme(true);
          }
          if (ImGui::MenuItem("System", nullptr,
                              appearance_theme == wam::AppearanceTheme::System)) {
            appearance_theme = wam::AppearanceTheme::System;
            state_store.state().appearance_theme = appearance_theme;
            dark_theme = systemPrefersDark();
            applyTheme(dark_theme);
          }
          ImGui::EndMenu();
        }
        ImGui::Separator();
        if (ImGui::MenuItem("Keep menu bar visible during playback", nullptr,
                            menu_bar_pinned))
          menu_bar_pinned = !menu_bar_pinned;
        ImGui::Separator();
        ImGui::MenuItem("Quick editor", "E", &show_editor);
        ImGui::MenuItem("Queue", "Q", &show_queue);
        ImGui::MenuItem("Playback inspector", "I", &show_stats);
        if (ImGui::MenuItem("Mini player", nullptr, mini_player))
          toggleMiniPlayer();
        if (ImGui::MenuItem("Always on top", nullptr, always_on_top)) {
          always_on_top = !always_on_top;
          SDL_SetWindowAlwaysOnTop(window,
                                   (always_on_top || mini_player) ? SDL_TRUE
                                                                   : SDL_FALSE);
        }
        ImGui::Separator();
        if (ImGui::BeginMenu("Performance profile")) {
          const auto profile = media.performanceProfile();
          if (ImGui::MenuItem("Efficiency", nullptr,
                              profile == wam::PerformanceProfile::Efficiency)) {
            media.setPerformanceProfile(wam::PerformanceProfile::Efficiency);
            state_store.state().performance_profile = 0;
          }
          if (ImGui::MenuItem("Balanced", nullptr,
                              profile == wam::PerformanceProfile::Balanced)) {
            media.setPerformanceProfile(wam::PerformanceProfile::Balanced);
            state_store.state().performance_profile = 1;
          }
          if (ImGui::MenuItem("Maximum quality", nullptr,
                              profile == wam::PerformanceProfile::Quality)) {
            media.setPerformanceProfile(wam::PerformanceProfile::Quality);
            state_store.state().performance_profile = 2;
          }
          ImGui::EndMenu();
        }
        if (ImGui::MenuItem("Resume previous position", nullptr,
                            restore_positions)) {
          restore_positions = !restore_positions;
          state_store.state().restore_positions = restore_positions;
        }
        ImGui::EndMenu();
      }
      ImGui::EndMenuBar();
    }

    if (show_url_popup) {
      ImGui::OpenPopup("Open network stream");
      show_url_popup = false;
    }
    if (ImGui::BeginPopupModal("Open network stream", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
      ImGui::TextUnformatted("Paste an HTTP, RTSP, HLS, YouTube, or other media URL.");
      ImGui::SetNextItemWidth(540);
      const bool enter = ImGui::InputText("##url", url_buffer, sizeof(url_buffer), ImGuiInputTextFlags_EnterReturnsTrue);
      if (enter || ImGui::Button("Open", ImVec2(100, 0))) {
        openFile(media, url_buffer, edit_in, edit_out, notice, &state_store,
                 &pending_resume);
        ImGui::CloseCurrentPopup();
      }
      ImGui::SameLine();
      if (ImGui::Button("Cancel", ImVec2(100, 0))) ImGui::CloseCurrentPopup();
      ImGui::EndPopup();
    }

    const bool layout_has_editor = show_editor;
    const float content_width = ImGui::GetContentRegionAvail().x;
    const float editor_width = layout_has_editor
                                   ? std::min(324.0f, std::max(280.0f, content_width * 0.30f))
                                   : 0.0f;
    const float panel_gap = layout_has_editor ? 8.0f : 0.0f;
    const float player_width = std::max(1.0f, content_width - editor_width - panel_gap);
    bool video_render_requested = false;
    const bool has_video = !media.source().empty() &&
                           media.infoInt("video-params/w") > 0 &&
                           media.infoInt("video-params/h") > 0;
    const ImVec4 player_background =
        has_video ? ImVec4(0.008f, 0.009f, 0.012f, 1.0f)
                  : dark_theme ? ImVec4(0.105f, 0.110f, 0.123f, 1.0f)
                               : ImVec4(0.950f, 0.956f, 0.966f, 1.0f);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, player_background);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::BeginChild("Player", ImVec2(player_width, 0), false);
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    ImVec2 available = ImGui::GetContentRegionAvail();
    ImVec2 video_area(available.x, std::max(120.0f, available.y));
    const ImVec2 top_left = ImGui::GetCursorScreenPos();
    ImGui::GetWindowDrawList()->AddRectFilled(
        top_left, ImVec2(top_left.x + video_area.x, top_left.y + video_area.y),
        ImGui::ColorConvertFloat4ToU32(player_background));
    if (has_video) {
      // A full Retina/HiDPI intermediate costs 4x the pixels and then gets
      // composited a second time. Balanced and Efficiency render at logical
      // resolution (normally close to the source); Maximum Quality opts into
      // native backing resolution for pixel-critical viewing.
      const bool native_hidpi =
          media.performanceProfile() == wam::PerformanceProfile::Quality;
      const float render_scale_x = native_hidpi ? io.DisplayFramebufferScale.x : 1.0f;
      const float render_scale_y = native_hidpi ? io.DisplayFramebufferScale.y : 1.0f;
      const int render_width = static_cast<int>(video_area.x * render_scale_x);
      const int render_height = static_cast<int>(video_area.y * render_scale_y);
      const bool resized = resizeVideoTarget(video_framebuffer, video_texture,
                                             texture_width, texture_height,
                                             render_width, render_height);
      const bool needs_render = mpv_frame_requested;
      video_render_requested = resized || needs_render;
      if (video_render_requested) media.render(video_framebuffer, texture_width, texture_height);
      ImGui::SetCursorScreenPos(top_left);
      ImGui::Image(static_cast<ImTextureID>(video_texture), video_area, ImVec2(0, 1), ImVec2(1, 0));
      if (show_stats) {
        ImGui::SetCursorScreenPos(ImVec2(top_left.x + 12, top_left.y + 12));
        ImGui::SetNextWindowBgAlpha(0.82f);
        ImGui::BeginChild("Playback inspector", ImVec2(290, 132), true,
                          ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
        const auto width = media.infoInt("video-params/w");
        const auto height = media.infoInt("video-params/h");
        const auto fps = media.infoDouble("estimated-vf-fps");
        auto hw = media.infoString("hwdec-current", "software");
        if (hw.empty() || hw == "no") hw = "software";
        ImGui::Text("%s · %s", media.infoString("file-format", "media").c_str(),
                    media.infoString("video-codec", "audio only").c_str());
        ImGui::Text("%lld × %lld · %.2f fps", static_cast<long long>(width),
                    static_cast<long long>(height), fps);
        ImGui::Text("Decoder: %s", hw.c_str());
        ImGui::Text("Dropped: %lld", static_cast<long long>(media.infoInt("decoder-frame-drop-count")));
        ImGui::Text("Cache: %.1f s", media.infoDouble("demuxer-cache-duration"));
        ImGui::EndChild();
      }
    } else {
      const bool has_source = !media.source().empty();
      const char* title = has_source ? "Playing audio" : "No media open";
      const char* supporting = has_source ? "Video controls remain available below."
                                          : "Drop a file here, or choose one from your computer.";
      const ImVec2 title_size = ImGui::CalcTextSize(title);
      const ImVec2 supporting_size = ImGui::CalcTextSize(supporting);
      const float button_width = 128.0f;
      const float center_y = top_left.y + video_area.y * 0.5f - 42.0f;
      ImGui::SetCursorScreenPos(
          ImVec2(top_left.x + (video_area.x - title_size.x) * 0.5f, center_y));
      ImGui::TextUnformatted(title);
      ImGui::SetCursorScreenPos(ImVec2(
          top_left.x + (video_area.x - supporting_size.x) * 0.5f, center_y + 25.0f));
      ImGui::TextDisabled("%s", supporting);
      if (!has_source) {
        ImGui::SetCursorScreenPos(ImVec2(
            top_left.x + (video_area.x - button_width) * 0.5f, center_y + 58.0f));
        ImGui::PushStyleColor(ImGuiCol_Button, gAccent);
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered,
                              ImVec4(gAccent.x * 0.88f, gAccent.y * 0.88f,
                                     gAccent.z * 0.88f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive,
                              ImVec4(gAccent.x * 0.76f, gAccent.y * 0.76f,
                                     gAccent.z * 0.76f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1, 1, 1, 1));
        if (ImGui::Button("Open media…", ImVec2(button_width, 36))) chooseMedia();
        ImGui::PopStyleColor(4);
      }
    }

    controls_hovered = false;
    const bool has_source = !media.source().empty();
    if (has_source && controls_alpha > 0.01f) {
      const float overlay_width =
          std::max(1.0f, std::min(760.0f, video_area.x - 24.0f));
      const float overlay_height = 96.0f;
      const ImVec2 overlay_min(
          top_left.x + (video_area.x - overlay_width) * 0.5f,
          std::max(top_left.y + 10.0f,
                   top_left.y + video_area.y - overlay_height - 18.0f));
      const ImVec2 overlay_max(overlay_min.x + overlay_width,
                               overlay_min.y + overlay_height);
      controls_hovered = ImGui::IsMouseHoveringRect(overlay_min, overlay_max, false);
      if (controls_hovered) {
        controls_alpha = 1.0f;
        last_controls_activity = std::chrono::steady_clock::now();
      }
      const float alpha = controls_alpha;
      ImDrawList* draw = ImGui::GetWindowDrawList();
      draw->AddRectFilled(ImVec2(overlay_min.x, overlay_min.y + 4.0f),
                          ImVec2(overlay_max.x, overlay_max.y + 4.0f),
                          IM_COL32(0, 0, 0, static_cast<int>(42 * alpha)), 15.0f);
      draw->AddRectFilled(overlay_min, overlay_max,
                          IM_COL32(24, 26, 30, static_cast<int>(218 * alpha)),
                          15.0f);
      draw->AddRect(overlay_min, overlay_max,
                    IM_COL32(255, 255, 255, static_cast<int>(35 * alpha)), 15.0f,
                    0, 1.0f);

      float position = media.position();
      const double now = media.timeSeconds();
      const double duration = media.durationSeconds();
      const auto chapters = media.chapters();
      ImGui::SetCursorScreenPos(ImVec2(overlay_min.x + 18.0f, overlay_min.y + 8.0f));
      if (seekBar("##transport-timeline", position, overlay_width - 36.0f, alpha,
                  duration, show_editor ? edit_in : 0.0,
                  show_editor ? edit_out : 0.0, chapters)) {
        media.setPosition(position);
        last_controls_activity = std::chrono::steady_clock::now();
      }

      const ImU32 secondary_text =
          IM_COL32(255, 255, 255, static_cast<int>(178 * alpha));
      const std::string now_text = timeLabel(now);
      const std::string duration_text = timeLabel(duration);
      draw->AddText(ImVec2(overlay_min.x + 18.0f, overlay_min.y + 29.0f),
                    secondary_text, now_text.c_str());
      const ImVec2 duration_size = ImGui::CalcTextSize(duration_text.c_str());
      draw->AddText(ImVec2(overlay_max.x - 18.0f - duration_size.x,
                           overlay_min.y + 29.0f),
                    secondary_text, duration_text.c_str());

      const float row_y = overlay_min.y + 45.0f;
      const float center_group_width = 126.0f;
      float control_x = overlay_min.x + (overlay_width - center_group_width) * 0.5f;
      ImGui::SetCursorScreenPos(ImVec2(control_x, row_y + 4.0f));
      if (transportButton("##back-five", TransportIcon::Back, 36.0f, alpha,
                          false, "Back 5 seconds  ·  Left Arrow")) {
        media.seekSeconds(now - 5.0);
        notice = "Back 5 seconds";
      }
      control_x += 41.0f;
      ImGui::SetCursorScreenPos(ImVec2(control_x, row_y));
      if (transportButton("##play-pause",
                          media.isPlaying() ? TransportIcon::Pause
                                            : TransportIcon::Play,
                          44.0f, alpha, true,
                          media.isPlaying() ? "Pause  ·  Space" : "Play  ·  Space"))
        media.togglePause();
      control_x += 49.0f;
      ImGui::SetCursorScreenPos(ImVec2(control_x, row_y + 4.0f));
      if (transportButton("##forward-five", TransportIcon::Forward, 36.0f,
                          alpha, false, "Forward 5 seconds  ·  Right Arrow")) {
        media.seekSeconds(now + 5.0);
        notice = "Forward 5 seconds";
      }

      if (overlay_width >= 430.0f) {
        ImGui::SetCursorScreenPos(ImVec2(overlay_min.x + 14.0f, row_y + 5.0f));
        if (transportButton("##mute", media.muted() ? TransportIcon::Muted
                                                     : TransportIcon::Volume,
                            34.0f, alpha, false,
                            media.muted() ? "Unmute  ·  M" : "Mute  ·  M"))
          media.toggleMute();
      }
      if (overlay_width >= 640.0f) {
        float volume_value = static_cast<float>(volume);
        ImGui::SetCursorScreenPos(ImVec2(overlay_min.x + 50.0f, row_y + 12.0f));
        if (valueBar("##overlay-volume", volume_value, 0.0f, 200.0f, 72.0f,
                     alpha, "Volume")) {
          volume = static_cast<int>(std::round(volume_value));
          media.setVolume(volume);
        }
      }

      float right_x = overlay_max.x - 48.0f;
      ImGui::SetCursorScreenPos(ImVec2(right_x, row_y + 5.0f));
      if (transportButton("##fullscreen", TransportIcon::Fullscreen, 34.0f,
                          alpha, false, "Fullscreen  ·  F"))
        toggleFullscreen();
      right_x -= 38.0f;
      ImGui::SetCursorScreenPos(ImVec2(right_x, row_y + 5.0f));
      if (transportButton("##more-controls", TransportIcon::More, 34.0f, alpha,
                          false, "More controls"))
        ImGui::OpenPopup("More controls");
      if (ImGui::BeginPopup("More controls")) {
        if (ImGui::MenuItem("Open media…", "Ctrl+O")) chooseMedia();
        if (ImGui::MenuItem("Add subtitle…")) {
          auto subtitles = pfd::open_file(
              "Add subtitle", "",
              {"Subtitles", "*.srt *.vtt *.ass *.ssa", "All files", "*"})
                               .result();
          if (!subtitles.empty())
            notice = media.addSubtitle(subtitles.front()) ? "Subtitle added."
                                                          : "Could not add subtitle.";
        }
        if (ImGui::MenuItem("Generate captions…", nullptr, false,
                            !caption_service.running()))
          generateCaptions();
        if (ImGui::MenuItem("Take snapshot…")) {
          auto path = pfd::save_file("Save snapshot", "wam-snapshot.png",
                                     {"PNG image", "*.png"})
                          .result();
          if (!path.empty())
            notice = media.snapshot(path) ? "Snapshot saved." : "Snapshot failed.";
        }
        ImGui::Separator();
        ImGui::MenuItem("Quick Edit", "E", &show_editor);
        ImGui::MenuItem("Queue", "Q", &show_queue);
        ImGui::MenuItem("Playback inspector", "I", &show_stats);
        ImGui::MenuItem("Picture adjustments…", nullptr,
                        &show_video_adjustments);
        ImGui::Separator();
        bool repeat_item = media.fileLoop();
        if (ImGui::MenuItem("Repeat current item", nullptr, repeat_item))
          media.setFileLoop(!repeat_item);
        if (ImGui::MenuItem("Mini player", nullptr, mini_player))
          toggleMiniPlayer();
        if (ImGui::MenuItem("Show full menu bar", nullptr, menu_bar_pinned))
          menu_bar_pinned = !menu_bar_pinned;
        if (ImGui::BeginMenu("Appearance")) {
          if (ImGui::MenuItem("Light", nullptr,
                              appearance_theme == wam::AppearanceTheme::Light)) {
            appearance_theme = wam::AppearanceTheme::Light;
            state_store.state().appearance_theme = appearance_theme;
            dark_theme = false;
            applyTheme(false);
          }
          if (ImGui::MenuItem("Dark", nullptr,
                              appearance_theme == wam::AppearanceTheme::Dark)) {
            appearance_theme = wam::AppearanceTheme::Dark;
            state_store.state().appearance_theme = appearance_theme;
            dark_theme = true;
            applyTheme(true);
          }
          if (ImGui::MenuItem("System", nullptr,
                              appearance_theme == wam::AppearanceTheme::System)) {
            appearance_theme = wam::AppearanceTheme::System;
            state_store.state().appearance_theme = appearance_theme;
            dark_theme = systemPrefersDark();
            applyTheme(dark_theme);
          }
          ImGui::EndMenu();
        }
        ImGui::EndPopup();
      }
      if (overlay_width >= 560.0f) {
        right_x -= 38.0f;
        ImGui::SetCursorScreenPos(ImVec2(right_x, row_y + 5.0f));
        if (transportButton("##quick-edit", TransportIcon::Edit, 34.0f, alpha,
                            false, show_editor ? "Close Quick Edit  ·  E"
                                               : "Open Quick Edit  ·  E"))
          show_editor = !show_editor;
      }
      if (overlay_width >= 650.0f) {
        right_x -= 38.0f;
        ImGui::SetCursorScreenPos(ImVec2(right_x, row_y + 5.0f));
        if (transportButton("##captions", TransportIcon::Captions, 34.0f, alpha,
                            false, media.subtitleVisible() ? "Hide captions"
                                                           : "Show captions"))
          media.setSubtitleVisible(!media.subtitleVisible());
      }
      if (overlay_width >= 500.0f) {
        right_x -= 62.0f;
        char rate_label[24];
        if (std::abs(playback_rate - std::round(playback_rate)) < 0.005f)
          std::snprintf(rate_label, sizeof(rate_label), "%.0fx", playback_rate);
        else
          std::snprintf(rate_label, sizeof(rate_label), "%.2gx", playback_rate);
        ImGui::SetCursorScreenPos(ImVec2(right_x, row_y + 7.0f));
        if (overlayPillButton("rate", rate_label, ImVec2(54.0f, 30.0f), alpha,
                              "Playback speed  ·  [ and ]"))
          ImGui::OpenPopup("Playback speed");
      }
      if (ImGui::BeginPopup("Playback speed")) {
        ImGui::TextUnformatted("Playback speed");
        ImGui::Separator();
        constexpr float presets[] = {0.5f, 0.75f, 1.0f, 1.25f,
                                     1.5f, 1.75f, 2.0f};
        for (float preset : presets) {
          char label[24];
          std::snprintf(label, sizeof(label), "%.2gx", preset);
          if (ImGui::MenuItem(label, nullptr,
                              std::abs(playback_rate - preset) < 0.005f)) {
            playback_rate = preset;
            media.setRate(playback_rate);
          }
        }
        ImGui::Separator();
        ImGui::SetNextItemWidth(190.0f);
        if (ImGui::SliderFloat("Fine adjustment", &playback_rate, 0.25f, 4.0f,
                               "%.2fx", ImGuiSliderFlags_Logarithmic))
          media.setRate(playback_rate);
        ImGui::EndPopup();
      }
    }
    ImGui::EndChild();

    if (layout_has_editor) {
      ImGui::SameLine();
      ImGui::BeginChild("Quick editor", ImVec2(editor_width, 0), true);
      ImGui::TextUnformatted("Quick Edit");
      ImGui::SameLine();
      ImGui::SetCursorPosX(ImGui::GetWindowWidth() -
                           ImGui::GetStyle().WindowPadding.x - 28.0f);
      if (closeButton("##close-editor", "Close Quick Edit  ·  E"))
        show_editor = false;
      ImGui::TextDisabled("Trim, retime, caption, and export.");
      ImGui::Spacing();

      const ImVec4 card_background =
          dark_theme ? ImVec4(0.155f, 0.162f, 0.180f, 1.0f)
                     : ImVec4(0.955f, 0.962f, 0.972f, 1.0f);
      ImGui::PushStyleColor(ImGuiCol_ChildBg, card_background);
      ImGui::BeginChild("Trim card", ImVec2(-1, 142.0f), true,
                        ImGuiWindowFlags_NoScrollbar);
      ImGui::PopStyleColor();
      ImGui::TextUnformatted("Trim");
      ImGui::TextDisabled("Set a clean start and end around the playhead.");
      ImGui::Spacing();
      ImGui::AlignTextToFramePadding();
      ImGui::TextDisabled("IN");
      ImGui::SameLine(34.0f);
      ImGui::TextUnformatted(timeLabel(edit_in).c_str());
      ImGui::SameLine();
      ImGui::SetCursorPosX(std::max(ImGui::GetCursorPosX(),
                                    ImGui::GetWindowWidth() - 126.0f));
      if (ImGui::Button("Use playhead##trim-in", ImVec2(112, 0)))
        edit_in = media.timeSeconds();
      ImGui::AlignTextToFramePadding();
      ImGui::TextDisabled("OUT");
      ImGui::SameLine(34.0f);
      ImGui::TextUnformatted(edit_out > 0 ? timeLabel(edit_out).c_str() : "End");
      ImGui::SameLine();
      ImGui::SetCursorPosX(std::max(ImGui::GetCursorPosX(),
                                    ImGui::GetWindowWidth() - 126.0f));
      if (ImGui::Button("Use playhead##trim-out", ImVec2(112, 0)))
        edit_out = media.timeSeconds();
      if (edit_in > 0.0 || edit_out > 0.0) {
        if (ImGui::SmallButton("Clear trim")) {
          edit_in = 0.0;
          edit_out = 0.0;
        }
      }
      ImGui::EndChild();

      ImGui::Spacing();
      ImGui::PushStyleColor(ImGuiCol_ChildBg, card_background);
      ImGui::BeginChild("Speed card", ImVec2(-1, 156.0f), true,
                        ImGuiWindowFlags_NoScrollbar);
      ImGui::PopStyleColor();
      ImGui::TextUnformatted("Speed");
      ImGui::TextDisabled("Choose a preset or fine-tune the export speed.");
      ImGui::Spacing();
      constexpr float editor_speed_presets[] = {0.5f, 1.0f, 1.5f, 2.0f};
      for (size_t i = 0; i < std::size(editor_speed_presets); ++i) {
        const float preset = editor_speed_presets[i];
        char label[24];
        std::snprintf(label, sizeof(label), "%.2gx", preset);
        const bool selected = std::abs(export_speed - preset) < 0.005f;
        if (selected) {
          ImGui::PushStyleColor(ImGuiCol_Button,
                                ImVec4(gAccent.x, gAccent.y, gAccent.z, 0.22f));
          ImGui::PushStyleColor(ImGuiCol_Text, gAccent);
        }
        if (ImGui::Button((std::string(label) + "##export-preset").c_str(),
                          ImVec2(52, 30)))
          export_speed = preset;
        if (selected) ImGui::PopStyleColor(2);
        if (i + 1 < std::size(editor_speed_presets)) ImGui::SameLine();
      }
      ImGui::SetNextItemWidth(-1);
      ImGui::SliderFloat("##export-speed", &export_speed, 0.25f, 4.0f, "%.2fx",
                         ImGuiSliderFlags_Logarithmic);
      ImGui::Checkbox("Preserve voice pitch", &preserve_pitch);
      itemTooltip("Keeps speech and music at their natural pitch when speed changes.");
      ImGui::EndChild();

      const bool local_source = !media.source().empty() &&
                                media.source().find("://") == std::string::npos;
      const bool can_run = local_source && !job.running() &&
                           !caption_service.running();
      ImGui::Spacing();
      ImGui::PushStyleColor(ImGuiCol_ChildBg, card_background);
      ImGui::BeginChild("Caption card", ImVec2(-1, 112.0f), true,
                        ImGuiWindowFlags_NoScrollbar);
      ImGui::PopStyleColor();
      ImGui::TextUnformatted("Captions");
      ImGui::TextDisabled("Create an offline subtitle track on this device.");
      ImGui::Spacing();
      if (caption_service.running()) {
        const auto status = caption_service.status();
        ImGui::ProgressBar(status.progress, ImVec2(-1, 0),
                           wam::captionStageName(status.stage));
        if (ImGui::Button("Cancel captioning", ImVec2(-1, 0)))
          caption_service.cancel();
      } else {
        ImGui::BeginDisabled(!can_run);
        if (ImGui::Button("Generate captions…", ImVec2(-1, 34)))
          generateCaptions();
        ImGui::EndDisabled();
      }
      ImGui::EndChild();

      ImGui::Spacing();
      if (job.running()) {
        const float phase = static_cast<float>(SDL_GetTicks() % 1200) / 1200.0f;
        ImGui::ProgressBar(phase, ImVec2(-1, 0), job.label().c_str());
        if (ImGui::Button("Cancel export", ImVec2(-1, 0))) {
          export_cancel_requested = true;
          job.cancel();
        }
      } else {
        ImGui::BeginDisabled(!can_run);
        if (primaryButton("Export video…", ImVec2(-1, 38))) {
          fs::path input(media.source());
          auto suggested = input.stem().string() + "-wam.mp4";
          auto output = pfd::save_file("Export edited video", suggested,
                                       {"MP4 video", "*.mp4"})
                            .result();
          if (!output.empty()) {
            if (fs::path(output).extension().empty()) output += ".mp4";
            wam::EditOptions options{input, output, edit_in, edit_out,
                                     export_speed, preserve_pitch};
            job.reset();
            job.start("Video export", wam::buildExportCommand(ffmpeg, options));
            job_handled = false;
            export_cancel_requested = false;
            notice = "Exporting in the background…";
          }
        }
        ImGui::EndDisabled();
      }
      if (!local_source && !media.source().empty())
        ImGui::TextDisabled("Save network media locally before editing.");
      else if (!notice.empty())
        ImGui::TextWrapped("%s", notice.c_str());
      ImGui::EndChild();
    }

    ImGui::End();

    if (show_queue) {
      ImGui::SetNextWindowSize(ImVec2(390, 360), ImGuiCond_FirstUseEver);
      if (ImGui::Begin("Queue", &show_queue)) {
        const auto playlist = media.playlist();
        int remove_index = -1;
        for (const auto& item : playlist) {
          const std::string title = item.title.empty()
                                        ? fs::path(item.filename).filename().string()
                                        : item.title;
          if (item.current) ImGui::PushStyleColor(ImGuiCol_Text, gAccent);
          if (ImGui::Selectable((title + "##queue-" + std::to_string(item.index)).c_str(),
                                item.current, 0, ImVec2(-32, 0)))
            media.playPlaylistItem(item.index);
          if (item.current) ImGui::PopStyleColor();
          ImGui::SameLine();
          if (ImGui::SmallButton(("X##remove-" + std::to_string(item.index)).c_str()))
            remove_index = item.index;
        }
        if (remove_index >= 0) media.removePlaylistItem(remove_index);
        if (playlist.empty()) ImGui::TextDisabled("Add media from File → Add files to queue.");
        if (!playlist.empty() && ImGui::Button("Shuffle")) media.shufflePlaylist();
        if (!playlist.empty()) ImGui::SameLine();
        if (!playlist.empty() && ImGui::Button("Clear queue")) media.clearPlaylist();
      }
      ImGui::End();
    }

    if (show_video_adjustments) {
      ImGui::SetNextWindowSize(ImVec2(360, 250), ImGuiCond_FirstUseEver);
      if (ImGui::Begin("Picture", &show_video_adjustments,
                       ImGuiWindowFlags_NoCollapse)) {
        if (ImGui::SliderFloat("Brightness", &brightness, -100.0f, 100.0f, "%+.0f"))
          media.setBrightness(brightness);
        if (ImGui::SliderFloat("Contrast", &contrast, -100.0f, 100.0f, "%+.0f"))
          media.setContrast(contrast);
        if (ImGui::SliderFloat("Saturation", &saturation, -100.0f, 100.0f, "%+.0f"))
          media.setSaturation(saturation);
        if (ImGui::SliderFloat("Gamma", &gamma, -100.0f, 100.0f, "%+.0f"))
          media.setGamma(gamma);
        if (ImGui::Button("Reset")) {
          brightness = contrast = saturation = gamma = 0.0f;
          media.setBrightness(0);
          media.setContrast(0);
          media.setSaturation(0);
          media.setGamma(0);
        }
      }
      ImGui::End();
    }

    const auto state_now = std::chrono::steady_clock::now();
    if (state_now - last_state_save >= std::chrono::seconds(10)) {
      state_store.state().volume = volume;
      state_store.remember(media.source(), media.timeSeconds());
      state_store.save();
      last_state_save = state_now;
    }

    ImGui::Render();
    int drawable_width = 0, drawable_height = 0;
    SDL_GL_GetDrawableSize(window, &drawable_width, &drawable_height);
    glBindFramebufferWam(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, drawable_width, drawable_height);
    if (dark_theme)
      glClearColor(0.090f, 0.094f, 0.106f, 1.0f);
    else
      glClearColor(0.961f, 0.965f, 0.973f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    SDL_GL_SwapWindow(window);
    media.reportSwap();
  }

  caption_service.cancel();
  caption_service.wait();
  job.cancel();
  state_store.state().volume = volume;
  state_store.remember(media.source(), media.timeSeconds());
  state_store.save();
  job.reset();
  if (video_framebuffer) glDeleteFramebuffersWam(1, &video_framebuffer);
  if (video_texture) glDeleteTextures(1, &video_texture);
  ImGui_ImplOpenGL3_Shutdown();
  ImGui_ImplSDL2_Shutdown();
  ImGui::DestroyContext();
  SDL_GL_DeleteContext(gl_context);
  SDL_DestroyWindow(window);
  SDL_Quit();
  return 0;
}
