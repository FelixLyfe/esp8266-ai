// ESP8266 AI clock: shows live Claude Code / Codex CLI / Cursor status
// working status and usage quota, polled from a small bridge service that
// runs on the developer's Mac (see ../bridge/bridge.py).
//
// Display: 240x240 SPI ST7789 (TFT_eSPI). Pin mapping is set via build_flags
// in platformio.ini - edit those if your wiring differs.

#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClient.h>
#include <WiFiManager.h>
#include <LittleFS.h>
#include <ArduinoJson.h>
#include <TFT_eSPI.h>
#include <AnimatedGIF.h>

#include "config.h"
#include "rotation_policy.h"
#include "img/claude_sprite.h"
#include "img/codex_sprite.h"
#include "img/cursor_sprite.h"
#include "img/claude_logo.h"
#include "img/codex_logo.h"

TFT_eSPI tft = TFT_eSPI();
ESP8266WebServer webServer(80);

// ---------- custom sprite storage (LittleFS) ----------
// Custom uploads replace the compiled-in default animation without needing a
// firmware rebuild. You POST a raw .gif straight to /sprite/claude or
// /sprite/codex (the device serves its own upload page at "/"); the ESP8266
// decodes and rescales the GIF *on-device* (AnimatedGIF, line-by-line so it
// never needs a full-canvas buffer) into the wire format below, which the
// display path then reads back frame-by-frame:
//   [1 byte frame count][frame0 bytes][frame1 bytes]...
// Each frame is exactly CLAUDE_SPRITE_W x H (or CODEX_SPRITE_W x H) RGB565
// pixels, byte order matching tools/convert_sprites.py's to_rgb565() so the
// compiled-in defaults and custom uploads share one draw path.
const char *CLAUDE_SPRITE_FILE = "/c.bin";
const char *CODEX_SPRITE_FILE = "/x.bin";
const char *CLAUDE_GIF_FILE = "/c.gif"; // raw upload, decoded then removed
const char *CODEX_GIF_FILE = "/x.gif";
const char *USB_TRANSFER_FILE = "/usb.tmp";
const int MAX_CUSTOM_FRAMES = 8;
const size_t CLAUDE_FRAME_BYTES = (size_t)CLAUDE_SPRITE_W * CLAUDE_SPRITE_H * 2;
const size_t CODEX_FRAME_BYTES = (size_t)CODEX_SPRITE_W * CODEX_SPRITE_H * 2;
const size_t CURSOR_FRAME_BYTES = (size_t)CURSOR_SPRITE_W * CURSOR_SPRITE_H * 2;

// We never hold a whole sprite frame in RAM. Decoding a GIF needs ~24KB of
// heap for AnimatedGIF's own buffers, which wouldn't fit alongside a static
// full-frame buffer (a 120x120 frame is ~28KB) on the ESP8266's ~80KB. So both
// the display path and the decoder work one screen-row at a time through these
// two small scratch rows (SCREEN_W is the widest we ever need).
uint16_t rowBuf[SCREEN_W];     // current row being drawn / decoded
uint16_t prevRowBuf[SCREEN_W]; // decode only: same row from the previous frame

bool claudeCustom = false;
int claudeCustomFrames = 0;
bool codexCustom = false;
int codexCustomFrames = 0;
uint32_t spriteRev = 2026071401UL; // default asset revision; bumped again on upload/reset

const int SCREEN_CX = 120, SCREEN_CY = 120;
const int RING_MARGIN = 4;      // inset from screen edge
const int RING_THICKNESS = 10;  // ring bar thickness
const unsigned long ANIM_INTERVAL_MS = 120;  // sprite frame advance
const unsigned long FLASH_INTERVAL_MS = 400; // "urgent" flash speed
const unsigned long SWITCH_BOTH_MS = 2000;   // both apps working: alternate fast
const unsigned long SWITCH_IDLE_MS = 6000;   // neither working: alternate slow

enum ActiveApp { APP_CLAUDE, APP_CODEX, APP_CURSOR, APP_NONE };
ActiveApp currentApp = APP_NONE;
unsigned long lastSwitchMs = 0;

// Display override, settable from the Mac app via POST /api/display:
// auto = follow working status, claude/codex = pin that app on screen,
// clock = show the host computer's local time instead of the pet.
enum DisplayMode { MODE_AUTO, MODE_CLAUDE, MODE_CODEX, MODE_CURSOR, MODE_CLOCK };
DisplayMode displayMode = MODE_AUTO;
DisplayMode lastEffectiveMode = MODE_AUTO;

// ---------- clock mode state ----------
const unsigned long CLOCK_POLL_INTERVAL_MS = 1000;
String clockTime = "--:--:--";
String clockDate = "---- -- --";
String clockWeekday = "---";
String clockLastTime, clockLastDate, clockLastWeekday;
unsigned long lastClockPollMs = 0;
bool clockChromeDrawn = false;

int claudeFrame = 0;
int codexFrame = 0;
int cursorFrame = 0;
unsigned long lastAnimMs = 0;

bool flashOn = true;
unsigned long lastFlashMs = 0;

// Bridge host is not asked for during first-time WiFi setup: the Mac/Windows
// bridge discovers the device and pairs automatically (or set via /api/bridge).
String bridgeHost;

struct ClaudeStatus {
  String status = "unknown";
  long tokensToday = 0;
  int sessionMin = 0;
  int sessionWindowMin = 300;
  float fiveHourPct = -1; // real OAuth quota from the bridge, -1 = unknown
  int fiveHourResetMin = -1; // minutes until the 5h window resets
  float sevenDayPct = -1;
  int sevenDayResetMin = -1; // minutes until the 7-day window resets
  bool needsInput = false; // waiting on a permission/approval prompt
  bool eligible = false;
  bool stale = false;
};

struct CodexStatus {
  String status = "unknown";
  long tokensToday = 0;
  float primaryPct = -1;
  int primaryResetMin = -1;
  float weeklyPct = -1;
  int weeklyResetMin = -1;
  bool needsInput = false;
  bool eligible = false;
  bool stale = false;
};

struct CursorStatus {
  float totalPct = -1;
  float autoPct = -1;
  float apiPct = -1;
  int billingResetMin = -1;
  bool eligible = false;
  bool stale = false;
};

ClaudeStatus claudeStatus;
CodexStatus codexStatus;
CursorStatus cursorStatus;
bool accountsChecked = false;

unsigned long lastPollMs = 0;
unsigned long lastSuccessMs = 0;
bool everPolled = false;
bool mainUiShown = false;      // false while the config-portal screen is up
bool webServerStarted = false; // deferred: port 80 clashes with the portal
bool webServerConfigured = false;

bool wiredActive();
String buildDeviceInfoJson();
bool decodeGifToBin(const char *gifPath, const char *binPath, int targetW, int targetH);
void setupWebServer();
void showMainUiIfNeeded();

// ---------- backlight brightness ----------
// The panel backlight (TFT_BL, active LOW) is PWM-dimmable — the vendor's own
// firmware does the same. 0 = off, 100 = full. Persisted so it survives reboot.

int brightness = BRIGHTNESS_DEFAULT; // 0-100

void applyBrightness() {
  // analogWriteRange(100) is set in setup(), so the duty value is just the
  // inverted percentage (active LOW: 0 duty = always LOW = full on).
  analogWrite(TFT_BL, 100 - brightness);
}

void loadBrightness() {
  if (!LittleFS.exists(BRIGHTNESS_FILE)) return;
  File f = LittleFS.open(BRIGHTNESS_FILE, "r");
  if (!f) return;
  int v = f.readStringUntil('\n').toInt();
  f.close();
  if (v >= 0 && v <= 100) brightness = v;
}

void saveBrightness() {
  File f = LittleFS.open(BRIGHTNESS_FILE, "w");
  if (!f) return;
  f.println(brightness);
  f.close();
}

// ---------- persistence for the bridge host ----------

void loadBridgeHost() {
  if (LittleFS.exists(WIFI_CONFIG_FILE)) {
    File f = LittleFS.open(WIFI_CONFIG_FILE, "r");
    bridgeHost = f.readStringUntil('\n');
    bridgeHost.trim();
    f.close();
  }
}

void saveBridgeHost(const String &host) {
  File f = LittleFS.open(WIFI_CONFIG_FILE, "w");
  f.println(host);
  f.close();
}

// ---------- custom sprite loading ----------

// Checks LittleFS for a previously-uploaded custom sprite and validates its
// size before trusting it (frame count byte + exact expected byte length).
void loadCustomSpriteState() {
  claudeCustom = false;
  if (LittleFS.exists(CLAUDE_SPRITE_FILE)) {
    File f = LittleFS.open(CLAUDE_SPRITE_FILE, "r");
    if (f && f.size() >= 1) {
      uint8_t cnt = f.read();
      size_t expected = 1 + (size_t)cnt * CLAUDE_FRAME_BYTES;
      if (cnt > 0 && cnt <= MAX_CUSTOM_FRAMES && (size_t)f.size() == expected) {
        claudeCustom = true;
        claudeCustomFrames = cnt;
      }
    }
    if (f) f.close();
  }

  codexCustom = false;
  if (LittleFS.exists(CODEX_SPRITE_FILE)) {
    File f = LittleFS.open(CODEX_SPRITE_FILE, "r");
    if (f && f.size() >= 1) {
      uint8_t cnt = f.read();
      size_t expected = 1 + (size_t)cnt * CODEX_FRAME_BYTES;
      if (cnt > 0 && cnt <= MAX_CUSTOM_FRAMES && (size_t)f.size() == expected) {
        codexCustom = true;
        codexCustomFrames = cnt;
      }
    }
    if (f) f.close();
  }

  Serial.printf("[sprite] claude custom=%d frames=%d | codex custom=%d frames=%d\n", claudeCustom,
                claudeCustomFrames, codexCustom, codexCustomFrames);
}

int claudeFrameCount() { return claudeCustom ? claudeCustomFrames : CLAUDE_SPRITE_FRAMES; }
int codexFrameCount() { return codexCustom ? codexCustomFrames : CODEX_SPRITE_FRAMES; }

// Draws one sprite frame centered on screen, one row at a time so we never
// need a full-frame buffer: each row comes either from the custom LittleFS
// file (streamed) or the compiled-in PROGMEM default (copied row-by-row).
void drawSpriteFrame(bool custom, const char *file, const uint16_t *const *progmemFrames, int frameIdx, int w,
                     int h, size_t frameBytes) {
  int x0 = SCREEN_CX - w / 2, y0 = SCREEN_CY - h / 2;
  size_t rowBytes = (size_t)w * 2;
  if (custom) {
    File f = LittleFS.open(file, "r");
    if (!f) return;
    f.seek(1 + (size_t)frameIdx * frameBytes);
    for (int r = 0; r < h; r++) {
      f.read((uint8_t *)rowBuf, rowBytes);
      tft.pushImage(x0, y0 + r, w, 1, rowBuf);
    }
    f.close();
  } else {
    const uint16_t *frame = progmemFrames[frameIdx];
    for (int r = 0; r < h; r++) {
      memcpy_P(rowBuf, frame + (size_t)r * w, rowBytes);
      tft.pushImage(x0, y0 + r, w, 1, rowBuf);
    }
  }
}

// ---------- helpers ----------

String formatTokens(long tokens) {
  if (tokens >= 1000000) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%.1fM", tokens / 1000000.0);
    return String(buf);
  }
  if (tokens >= 1000) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%.1fk", tokens / 1000.0);
    return String(buf);
  }
  return String(tokens);
}

// ---------- drawing ----------

void drawStaticChrome() {
  tft.fillScreen(TFT_BLACK);
}

// Bridge unreachable / data stale -> flashing red overrides everything else,
// matches the "urgent, look now" state from the reference signal-light design.
bool bridgeStale() {
  if (!everPolled) return true;
  return (millis() - lastSuccessMs) >= 2UL * BRIDGE_POLL_INTERVAL_MS;
}

// True when the app currently on screen is waiting on a permission/approval
// prompt — drives the red "look now, act" border flash.
bool currentAppNeedsInput() {
  if (currentApp == APP_CLAUDE) return claudeStatus.needsInput;
  if (currentApp == APP_CODEX) return codexStatus.needsInput;
  return false;
}

bool appEligible(ActiveApp app) {
  if (app == APP_CLAUDE) return claudeStatus.eligible;
  if (app == APP_CODEX) return codexStatus.eligible;
  if (app == APP_CURSOR) return cursorStatus.eligible;
  return false;
}

bool appWorking(ActiveApp app) {
  if (app == APP_CLAUDE) return claudeStatus.status == "working";
  if (app == APP_CODEX) return codexStatus.status == "working";
  if (app == APP_CURSOR) return false; // Cursor is quota-only; no work-state monitoring.
  return false;
}

bool appStale(ActiveApp app) {
  if (app == APP_CLAUDE) return claudeStatus.stale;
  if (app == APP_CODEX) return codexStatus.stale;
  if (app == APP_CURSOR) return cursorStatus.stale;
  return false;
}

// Claude/Codex working vs idle is conveyed by motion vs a still first frame;
// Cursor is quota-only and keeps its idle pet looping. The ring stays steady
// green, except bridge-stale which flashes red and overrides everything.
uint16_t currentStatusColor() {
  if (bridgeStale()) return flashOn ? TFT_RED : TFT_BLACK;
  if (currentApp == APP_CURSOR && cursorStatus.totalPct >= 99.9f) return TFT_RED;
  return TFT_GREEN;
}

// The ring is skipped when nothing changed (see drawSquareRing) so the 5s
// poll doesn't visibly blank-and-repaint it. Anything that paints over the
// ring area must invalidate this cache.
float ringLastPct = -1000;
uint16_t ringLastColor = 1;
int lastNoAIState = -1;

// Paints the full square border in one color (all four sides), used for the
// attention flash so the whole edge blinks, not just the filled quota arc.
void drawFullBorder(uint16_t color) {
  ringLastPct = -1000; // ring got painted over; next ring draw must repaint
  int x0 = RING_MARGIN, y0 = RING_MARGIN;
  int side = SCREEN_W - 2 * RING_MARGIN;
  tft.fillRect(x0, y0, side, RING_THICKNESS, color);                              // top
  tft.fillRect(x0, SCREEN_H - RING_MARGIN - RING_THICKNESS, side, RING_THICKNESS, color); // bottom
  tft.fillRect(x0, y0, RING_THICKNESS, side, color);                              // left
  tft.fillRect(SCREEN_W - RING_MARGIN - RING_THICKNESS, y0, RING_THICKNESS, side, color); // right
}

// Square progress ring hugging the screen edge. `pct` of the perimeter
// (clockwise from top-left) is drawn in `color`, the rest in dark grey.
void drawSquareRing(float pct, uint16_t color) {
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  if (pct == ringLastPct && color == ringLastColor) return; // nothing changed
  ringLastPct = pct;
  ringLastColor = color;

  int x0 = RING_MARGIN, y0 = RING_MARGIN;
  int x1 = SCREEN_W - RING_MARGIN, y1 = SCREEN_H - RING_MARGIN;
  int side = x1 - x0;
  float perimeter = side * 4.0;

  // Unfilled track is drawn black (not grey) so it blends into the background
  // and only the active quota portion is visible - still needs to be actively
  // repainted each time though, to erase a previously longer fill if the
  // percentage drops (e.g. a quota window reset).
  tft.fillRect(x0, y0, side, RING_THICKNESS, TFT_BLACK);                  // top
  tft.fillRect(x1 - RING_THICKNESS, y0, RING_THICKNESS, side, TFT_BLACK); // right
  tft.fillRect(x0, y1 - RING_THICKNESS, side, RING_THICKNESS, TFT_BLACK); // bottom
  tft.fillRect(x0, y0, RING_THICKNESS, side, TFT_BLACK);                  // left

  // filled portion, clockwise: top -> right -> bottom -> left
  float remaining = perimeter * (pct / 100.0);
  if (remaining <= 0) return;

  float seg = min(remaining, (float)side);
  tft.fillRect(x0, y0, (int)seg, RING_THICKNESS, color);
  remaining -= side;
  if (remaining <= 0) return;

  seg = min(remaining, (float)side);
  tft.fillRect(x1 - RING_THICKNESS, y0, RING_THICKNESS, (int)seg, color);
  remaining -= side;
  if (remaining <= 0) return;

  seg = min(remaining, (float)side);
  tft.fillRect(x1 - (int)seg, y1 - RING_THICKNESS, (int)seg, RING_THICKNESS, color);
  remaining -= side;
  if (remaining <= 0) return;

  seg = min(remaining, (float)side);
  tft.fillRect(x0, y1 - (int)seg, RING_THICKNESS, (int)seg, color);
}

void drawClaudeSprite(int frameIdx) {
  drawSpriteFrame(claudeCustom, CLAUDE_SPRITE_FILE, claude_sprite_frames, frameIdx, CLAUDE_SPRITE_W,
                  CLAUDE_SPRITE_H, CLAUDE_FRAME_BYTES);
}

void drawCodexSprite(int frameIdx) {
  drawSpriteFrame(codexCustom, CODEX_SPRITE_FILE, codex_sprite_frames, frameIdx, CODEX_SPRITE_W, CODEX_SPRITE_H,
                  CODEX_FRAME_BYTES);
}

void drawCursorSprite(int frameIdx) {
  drawSpriteFrame(false, nullptr, cursor_sprite_frames, frameIdx, CURSOR_SPRITE_W, CURSOR_SPRITE_H,
                  CURSOR_FRAME_BYTES);
}

String pctText(float pct) {
  return pct >= 0 ? String((int)lroundf(constrain(pct, 0.0f, 100.0f))) + "%" : "-";
}

float remainingPct(float usedPct) {
  return usedPct >= 0 ? constrain(100.0f - usedPct, 0.0f, 100.0f) : -1.0f;
}

// Quota readout below the sprite: two remaining-quota columns, small grey label
// over a big font-4 percentage. Values repaint only when their text changes
// (force = after a full-screen clear), so the 5s poll never flashes them.
const int QUOTA_LABEL_Y = 183, QUOTA_VALUE_Y = 199;
const int QUOTA_COL1_X = 70, QUOTA_COL2_X = 170;
String lastQuota5h, lastQuotaWk, lastQuotaLabel1, lastQuotaLabel2;

// Faux-bold: the packed TFT_eSPI fonts have no bold face, so draw twice with
// a 1px x offset. Transparent draws - the caller must have cleared the region.
void drawBoldString(const String &s, int x, int y, int font, uint16_t color) {
  tft.setTextColor(color);
  tft.drawString(s, x, y, font);
  tft.drawString(s, x + 1, y, font);
}

void drawQuotaTextWithLabels(const String &label1, float pct1, const String &label2, float pct2, bool force) {
  tft.setTextDatum(TC_DATUM);
  String v1 = pctText(pct1), v2 = pctText(pct2);
  bool has1 = pct1 >= 0, has2 = pct2 >= 0;
  bool changed = force || v1 != lastQuota5h || v2 != lastQuotaWk
      || label1 != lastQuotaLabel1 || label2 != lastQuotaLabel2;
  if (!changed) return;
  lastQuota5h = v1; lastQuotaWk = v2;
  lastQuotaLabel1 = label1; lastQuotaLabel2 = label2;
  tft.fillRect(12, QUOTA_LABEL_Y, 216, 44, TFT_BLACK);
  if (has1 && has2) {
    drawBoldString(label1, QUOTA_COL1_X, QUOTA_LABEL_Y, 2, TFT_LIGHTGREY);
    drawBoldString(label2, QUOTA_COL2_X, QUOTA_LABEL_Y, 2, TFT_LIGHTGREY);
    drawBoldString(v1, QUOTA_COL1_X, QUOTA_VALUE_Y, 4, TFT_WHITE);
    drawBoldString(v2, QUOTA_COL2_X, QUOTA_VALUE_Y, 4, TFT_WHITE);
  } else if (has1 || has2) {
    drawBoldString(has1 ? label1 : label2, SCREEN_CX, QUOTA_LABEL_Y, 2, TFT_LIGHTGREY);
    drawBoldString(has1 ? v1 : v2, SCREEN_CX, QUOTA_VALUE_Y, 4, TFT_WHITE);
  }
}

void drawQuotaText(float hourPct, float weekPct, bool force) {
  drawQuotaTextWithLabels("5h LEFT", hourPct, "Wk LEFT", weekPct, force);
}

// ---------- quota-exhausted countdown ----------
// When the current app's 5h or weekly window is used up, the pet is replaced
// by a countdown to that window's reset (bridge sends minutes-until-reset).
// A spent weekly window blocks usage even after the 5h one resets, so the
// weekly countdown takes priority when both are exhausted.

enum CdType { CD_NONE, CD_5H, CD_WEEK };

float currentHourPct() {
  if (currentApp == APP_CLAUDE) return claudeStatus.fiveHourPct;
  if (currentApp == APP_CODEX) return codexStatus.primaryPct;
  return -1;
}

int currentHourResetMin() {
  if (currentApp == APP_CLAUDE) return claudeStatus.fiveHourResetMin;
  if (currentApp == APP_CODEX) return codexStatus.primaryResetMin;
  return -1;
}

float currentWeekPct() {
  if (currentApp == APP_CLAUDE) return claudeStatus.sevenDayPct;
  if (currentApp == APP_CODEX) return codexStatus.weeklyPct;
  return -1;
}

int currentWeekResetMin() {
  if (currentApp == APP_CLAUDE) return claudeStatus.sevenDayResetMin;
  if (currentApp == APP_CODEX) return codexStatus.weeklyResetMin;
  return -1;
}

CdType desiredCountdown() {
  if (currentApp == APP_CURSOR || currentApp == APP_NONE) return CD_NONE;
  if (currentWeekPct() >= 99.9f && currentWeekResetMin() >= 0) return CD_WEEK;
  if (currentHourPct() >= 99.9f && currentHourResetMin() >= 0) return CD_5H;
  return CD_NONE;
}

CdType showingCd = CD_NONE; // what's on screen now (vs desiredCountdown())
String lastCountdown;

// The bridge only reports whole minutes, so the seconds tick locally against
// a deadline anchored at millis(). Re-anchor only when the bridge disagrees
// by more than ~a minute (new window, big clock drift), otherwise a poll
// landing mid-minute would make the seconds jump around.
unsigned long cdDeadlineMs = 0; // 0 = not anchored
ActiveApp cdApp = APP_CLAUDE;   // which app/window the anchor belongs to
CdType cdAnchorType = CD_NONE;

void syncCountdownDeadline() {
  int m = showingCd == CD_WEEK ? currentWeekResetMin() : currentHourResetMin();
  if (m < 0) {
    cdDeadlineMs = 0;
    return;
  }
  long bridgeSec = (long)m * 60 + 30; // bridge floors to minutes: assume mid-minute
  long ourSec = (long)(cdDeadlineMs - millis()) / 1000;
  if (cdDeadlineMs == 0 || cdApp != currentApp || cdAnchorType != showingCd || ourSec < 0 ||
      labs(ourSec - bridgeSec) > 90) {
    cdDeadlineMs = millis() + (unsigned long)bridgeSec * 1000UL;
    cdApp = currentApp;
    cdAnchorType = showingCd;
  }
}

void drawCountdown(bool force) {
  long remain = cdDeadlineMs ? (long)(cdDeadlineMs - millis()) / 1000
                             : (long)(showingCd == CD_WEEK ? currentWeekResetMin() : currentHourResetMin()) * 60;
  if (remain < 0) remain = 0;
  char buf[16];
  long hours = remain / 3600;
  if (hours >= 100) // weekly can be up to 168h: h:mm:ss wouldn't fit the ring
    snprintf(buf, sizeof(buf), "%ld:%02ld", hours, (remain % 3600) / 60);
  else
    snprintf(buf, sizeof(buf), "%ld:%02ld:%02ld", hours, (remain % 3600) / 60, remain % 60);
  String t(buf);
  if (!force && t == lastCountdown) return;
  // in-place glyph overwrite can't erase a shrinking string (h:mm:ss width is
  // constant, but 100:00 -> 99:59:59 changes layout once) - clear on any
  // length change
  if (t.length() != lastCountdown.length()) force = true;
  lastCountdown = t;
  tft.setTextDatum(TC_DATUM);
  if (force) {
    tft.fillRect(SCREEN_CX - 99, 66, 198, 84, TFT_BLACK);
    drawBoldString(showingCd == CD_WEEK ? "Wk RESET IN" : "5h RESET IN", SCREEN_CX, 72, 2, TFT_LIGHTGREY);
  }
  // Background-color draw overwrites glyphs in place (no clear-then-draw
  // flash between seconds).
  tft.setTextColor(TFT_ORANGE, TFT_BLACK);
  tft.drawString(t, SCREEN_CX, 102, 6);
}

// App logo in the top-left corner (inside the quota ring) so a glance tells
// which app the screen is currently showing. Drawn row-by-row from PROGMEM
// through rowBuf, same as the sprite path.
const int LOGO_X = 14, LOGO_Y = 18;

// 49x56 one-bit mask rasterized from Cursor's SVG path. Keeping the source
// aspect ratio makes the 40x40 top-left slot match Claude/Codex without
// pulling a floating-point polygon rasterizer into the ESP8266 firmware.
static const uint8_t cursorLogoBits[] = {
  0x00,0x00,0x01,0xC0,0x00,0x00,0x00,0x00,0x03,0xF8,0x00,0x00,0x00,0x00,0x03,0xFE,
  0x00,0x00,0x00,0x00,0x07,0xFF,0xC0,0x00,0x00,0x00,0x0F,0xFF,0xF8,0x00,0x00,0x00,
  0x1F,0xFF,0xFF,0x00,0x00,0x00,0x1F,0xFF,0xFF,0xC0,0x00,0x00,0x3F,0xFF,0xFF,0xF8,
  0x00,0x00,0x7F,0xFF,0xFF,0xFF,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0xE0,0x00,0xFF,0xFF,
  0xFF,0xFF,0xF8,0x01,0xFF,0xFF,0xFF,0xFF,0xFF,0x03,0xFF,0xFF,0xFF,0xFF,0xFF,0xE3,
  0xFF,0xFF,0xFF,0xFF,0xFF,0xFB,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xC0,0x00,0x00,0x00,
  0x00,0x07,0xF8,0x00,0x00,0x00,0x00,0x03,0xFE,0x00,0x00,0x00,0x00,0x01,0xFF,0xC0,
  0x00,0x00,0x00,0x01,0xFF,0xF8,0x00,0x00,0x00,0x00,0xFF,0xFF,0x00,0x00,0x00,0x00,
  0xFF,0xFF,0xC0,0x00,0x00,0x00,0xFF,0xFF,0xF8,0x00,0x00,0x00,0x7F,0xFF,0xFF,0x00,
  0x00,0x00,0x7F,0xFF,0xFF,0xC0,0x00,0x00,0x3F,0xFF,0xFF,0xF8,0x00,0x00,0x3F,0xFF,
  0xFF,0xFF,0x00,0x00,0x1F,0xFF,0xFF,0xFF,0xE0,0x00,0x1F,0xFF,0xFF,0xFF,0xF0,0x00,
  0x1F,0xFF,0xFF,0xFF,0xF8,0x00,0x0F,0xFF,0xFF,0xFF,0xFC,0x00,0x0F,0xFF,0xFF,0xFF,
  0xFE,0x00,0x07,0xFF,0xFF,0xFF,0xFF,0x00,0x07,0xFF,0xFF,0xFF,0xFF,0x80,0x03,0xFF,
  0xFF,0xFF,0xFF,0xC0,0x03,0xFF,0xFF,0xFF,0xFF,0xE0,0x03,0xFF,0xFF,0xFF,0xFF,0xF0,
  0x01,0xFF,0xFF,0xFF,0xFF,0xF8,0x01,0xFF,0xFF,0xFF,0xFF,0xFC,0x00,0xFF,0xFF,0xFF,
  0xFF,0xFE,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x7F,0xFF,0xFF,0xFF,0xFF,0x80,0x7F,
  0xFF,0xDF,0xFF,0xFF,0xC0,0x7F,0xFF,0xC7,0xFF,0xFF,0xE0,0x3F,0xFF,0xC0,0xFF,0xFF,
  0xF0,0x3F,0xFF,0x80,0x1F,0xFF,0xF8,0x1F,0xFF,0x00,0x07,0xFF,0xFC,0x1F,0xFF,0x00,
  0x00,0xFF,0xFE,0x1F,0xFE,0x00,0x00,0x1F,0xFF,0x0F,0xFC,0x00,0x00,0x03,0xFF,0x8F,
  0xF8,0x00,0x00,0x00,0xFF,0xC7,0xF8,0x00,0x00,0x00,0x1F,0xE7,0xF0,0x00,0x00,0x00,
  0x03,0xF3,0xE0,0x00,0x00,0x00,0x00,0x7F,0xC0,0x00,0x00,0x00,0x00,0x1F,0xC0,0x00,
  0x00,0x00,0x00,0x03,0x80,0x00,0x00
};
static_assert(sizeof(cursorLogoBits) == 343, "Cursor logo mask must be 49x56 bits");

void drawCursorMark(int cx, int cy, int size) {
  const int width = (size * 49 + 28) / 56;
  const int left = cx - width / 2;
  const int top = cy - size / 2;
  for (int y = 0; y < size; y++) {
    int sourceY = y * 56 / size;
    int runStart = -1;
    for (int x = 0; x <= width; x++) {
      bool on = false;
      if (x < width) {
        int sourceX = x * 49 / width;
        int bit = sourceY * 49 + sourceX;
        on = (cursorLogoBits[bit / 8] & (0x80 >> (bit & 7))) != 0;
      }
      if (on && runStart < 0) runStart = x;
      if (!on && runStart >= 0) {
        tft.fillRect(left + runStart, top + y, x - runStart, 1, TFT_WHITE);
        runStart = -1;
      }
    }
  }
}

void drawStaleTag() {
  tft.fillRect(174, 16, 52, 16, TFT_BLACK);
  if (!appStale(currentApp)) return;
  tft.setTextDatum(TR_DATUM);
  drawBoldString("STALE", 224, 17, 1, TFT_ORANGE);
}

void drawNoAIState(bool force = false) {
  int state = accountsChecked ? 1 : 0;
  if (!force && state == lastNoAIState) return;
  lastNoAIState = state;
  tft.fillScreen(TFT_BLACK);
  ringLastPct = -1000;
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(accountsChecked ? TFT_ORANGE : TFT_CYAN, TFT_BLACK);
  tft.drawString(accountsChecked ? "NO AI LOGIN" : "CHECKING ACCOUNTS...", SCREEN_CX, 112, 2);
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString("USB CONNECTED", SCREEN_CX, 139, 1);
}

void drawAppLogo() {
  if (currentApp == APP_NONE) return;
  if (currentApp == APP_CURSOR) {
    drawCursorMark(LOGO_X + 20, LOGO_Y + 20, 40);
    return;
  }
  const uint16_t *logo = (currentApp == APP_CLAUDE) ? claude_logo_0 : codex_logo_0;
  int w = (currentApp == APP_CLAUDE) ? CLAUDE_LOGO_W : CODEX_LOGO_W;
  int h = (currentApp == APP_CLAUDE) ? CLAUDE_LOGO_H : CODEX_LOGO_H;
  for (int r = 0; r < h; r++) {
    memcpy_P(rowBuf, logo + (size_t)r * w, (size_t)w * 2);
    tft.pushImage(LOGO_X, LOGO_Y + r, w, 1, rowBuf);
  }
}

// Claude's ring percentage: real 5h OAuth quota from the bridge when known,
// otherwise fall back to elapsed session time as a rough stand-in.
float claudeRingPct() {
  if (claudeStatus.fiveHourPct >= 0) return claudeStatus.fiveHourPct;
  return claudeStatus.sessionWindowMin > 0
             ? (100.0 * claudeStatus.sessionMin / claudeStatus.sessionWindowMin)
             : 0;
}

// Redraws whichever app is currently active, full screen: quota ring +
// sprite (or the reset countdown while the 5h window is exhausted).
// Full clear + repaint - only for real transitions (app switch, mode return,
// sprite change); steady-state data updates go through refreshActiveApp().
void drawActiveApp() {
  if (currentApp == APP_NONE) { drawNoAIState(true); return; }
  lastNoAIState = -1;
  tft.fillScreen(TFT_BLACK);
  ringLastPct = -1000; // screen was cleared: force the ring repaint
  showingCd = desiredCountdown();
  if (showingCd != CD_NONE) syncCountdownDeadline();
  else cdDeadlineMs = 0;
  if (currentApp == APP_CLAUDE) {
    drawSquareRing(remainingPct(claudeRingPct()), currentStatusColor());
    if (showingCd == CD_NONE) drawClaudeSprite(claudeFrame);
    drawQuotaText(remainingPct(claudeRingPct()), remainingPct(claudeStatus.sevenDayPct), true);
  } else if (currentApp == APP_CODEX) {
    float ringUsedPct = codexStatus.primaryPct >= 0 ? codexStatus.primaryPct : codexStatus.weeklyPct;
    drawSquareRing(max(remainingPct(ringUsedPct), 0.0f), currentStatusColor());
    if (showingCd == CD_NONE) drawCodexSprite(codexFrame);
    drawQuotaText(remainingPct(codexStatus.primaryPct), remainingPct(codexStatus.weeklyPct), true);
  } else {
    drawSquareRing(remainingPct(cursorStatus.totalPct), currentStatusColor());
    drawCursorSprite(cursorFrame);
    drawQuotaTextWithLabels("AUTO LEFT", remainingPct(cursorStatus.autoPct),
                            "API LEFT", remainingPct(cursorStatus.apiPct), true);
  }
  if (showingCd != CD_NONE) drawCountdown(true);
  drawAppLogo();
  drawStaleTag();
}

// In-place refresh after a bridge poll: ring repaint + only the text that
// actually changed. No fillScreen, so the 5s poll doesn't blank the screen.
void refreshActiveApp() {
  if (currentApp == APP_NONE) { drawNoAIState(); return; }
  if (desiredCountdown() != showingCd) { // pet <-> countdown (or 5h <-> weekly) swap
    drawActiveApp();
    return;
  }
  if (currentApp == APP_CLAUDE) {
    drawSquareRing(remainingPct(claudeRingPct()), currentStatusColor());
    drawQuotaText(remainingPct(claudeRingPct()), remainingPct(claudeStatus.sevenDayPct), false);
  } else if (currentApp == APP_CODEX) {
    float ringUsedPct = codexStatus.primaryPct >= 0 ? codexStatus.primaryPct : codexStatus.weeklyPct;
    drawSquareRing(max(remainingPct(ringUsedPct), 0.0f), currentStatusColor());
    drawQuotaText(remainingPct(codexStatus.primaryPct), remainingPct(codexStatus.weeklyPct), false);
  } else {
    drawSquareRing(remainingPct(cursorStatus.totalPct), currentStatusColor());
    drawQuotaTextWithLabels("AUTO LEFT", remainingPct(cursorStatus.autoPct),
                            "API LEFT", remainingPct(cursorStatus.apiPct), false);
  }
  if (showingCd != CD_NONE) {
    syncCountdownDeadline();
    drawCountdown(false);
  }
  drawStaleTag();
}

// Redraws just the ring (cheap) - used for status color animation ticks
// between full redraws.
void redrawRingOnly() {
  if (currentApp == APP_NONE) return;
  if (currentApp == APP_CLAUDE) {
    drawSquareRing(remainingPct(claudeRingPct()), currentStatusColor());
  } else if (currentApp == APP_CODEX) {
    float ringUsedPct = codexStatus.primaryPct >= 0 ? codexStatus.primaryPct : codexStatus.weeklyPct;
    drawSquareRing(max(remainingPct(ringUsedPct), 0.0f), currentStatusColor());
  } else {
    drawSquareRing(remainingPct(cursorStatus.totalPct), currentStatusColor());
  }
}

// Who gets the screen:
//   - display mode pinned (Mac app) -> that app, always
//   - exactly one app working       -> that app, immediately
//   - both working                  -> alternate every SWITCH_BOTH_MS (2s)
//   - neither working               -> alternate slowly (SWITCH_IDLE_MS)
bool updateActiveApp() {
  ActiveApp order[3] = {APP_CLAUDE, APP_CODEX, APP_CURSOR};
  if ((displayMode == MODE_CLAUDE && !appEligible(APP_CLAUDE))
      || (displayMode == MODE_CODEX && !appEligible(APP_CODEX))
      || (displayMode == MODE_CURSOR && !appEligible(APP_CURSOR))) displayMode = MODE_AUTO;
  bool eligible[3], working[3], needsInput[3] = {
      claudeStatus.needsInput, codexStatus.needsInput, false};
  int workingCount = 0;
  for (int i = 0; i < 3; i++) {
    eligible[i] = appEligible(order[i]);
    working[i] = appWorking(order[i]);
    if (eligible[i] && working[i]) workingCount++;
  }
  int pinned = displayMode == MODE_CLAUDE ? APP_CLAUDE
      : displayMode == MODE_CODEX ? APP_CODEX : displayMode == MODE_CURSOR ? APP_CURSOR : -1;
  unsigned long interval = workingCount > 1 ? SWITCH_BOTH_MS : SWITCH_IDLE_MS;
  bool rotateNow = millis() - lastSwitchMs >= interval;
  ActiveApp desired = (ActiveApp)RotationPolicy::choose(eligible, working, needsInput,
      pinned, (int)currentApp, rotateNow);

  if (desired != currentApp) {
    currentApp = desired;
    lastSwitchMs = millis();
    return true;
  }
  return false;
}

// ---------- clock screen ----------

void drawClockScreen() {
  if (!clockChromeDrawn) {
    tft.fillScreen(TFT_BLACK);
    tft.setTextDatum(TC_DATUM);
    tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
    tft.setTextSize(1);
    tft.drawString("LOCAL TIME", SCREEN_CX, 28, 2);
    clockChromeDrawn = true;
    clockLastTime = "";
    clockLastDate = "";
    clockLastWeekday = "";
  }
  tft.setTextDatum(TC_DATUM);
  if (clockTime != clockLastTime) {
    clockLastTime = clockTime;
    tft.fillRect(0, 66, SCREEN_W, 64, TFT_BLACK);
    tft.setTextColor(TFT_CYAN, TFT_BLACK);
    tft.setTextSize(2);
    tft.drawString(clockTime, SCREEN_CX, 76, 2);
    tft.setTextSize(1);
  }
  if (clockDate != clockLastDate) {
    clockLastDate = clockDate;
    tft.fillRect(0, 148, SCREEN_W, 30, TFT_BLACK);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawString(clockDate, SCREEN_CX, 150, 4);
  }
  if (clockWeekday != clockLastWeekday) {
    clockLastWeekday = clockWeekday;
    tft.fillRect(0, 190, SCREEN_W, 24, TFT_BLACK);
    tft.setTextColor(TFT_YELLOW, TFT_BLACK);
    tft.drawString(clockWeekday, SCREEN_CX, 194, 2);
  }
}

bool handleClockPayload(const String &payload) {
  JsonDocument doc;
  if (deserializeJson(doc, payload)) return false;
  const char *timeValue = doc["time"] | (const char *)nullptr;
  const char *dateValue = doc["date"] | (const char *)nullptr;
  const char *weekdayValue = doc["weekday"] | (const char *)nullptr;
  if (!timeValue || !dateValue || !weekdayValue
      || strlen(timeValue) != 8 || strlen(dateValue) != 10 || strlen(weekdayValue) != 3) return false;
  clockTime = timeValue;
  clockDate = dateValue;
  clockWeekday = weekdayValue;
  if (displayMode == MODE_CLOCK) drawClockScreen();
  return true;
}

void pollClock() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/clock";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) handleClockPayload(http.getString());
  http.end();
}

// ---------- WiFi / bridge polling ----------

WiFiManager wifiManager;
enum WiFiFallbackState { WIFI_FALLBACK_OFF, WIFI_FALLBACK_CONNECTING, WIFI_FALLBACK_PORTAL, WIFI_FALLBACK_CONNECTED };
WiFiFallbackState wifiFallbackState = WIFI_FALLBACK_OFF;
unsigned long wifiFallbackStartedMs = 0;
unsigned long bootMs = 0;

void configModeCallback(WiFiManager *wm) {
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("WiFi setup needed", 8, 32, 2);
  tft.drawString("Connect phone to AP:", 8, 62, 2);
  tft.setTextColor(TFT_YELLOW, TFT_BLACK);
  tft.drawString(WIFI_PORTAL_AP_NAME, 8, 87, 2);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("then open 192.168.4.1", 8, 117, 2);
  tft.setTextColor(TFT_CYAN, TFT_BLACK);
  tft.drawString("Or: plug into the computer", 8, 155, 2);
  tft.drawString("via USB - no WiFi needed", 8, 178, 2);
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString("Firmware v" FW_VERSION, 8, 215, 2);
}

void beginWiFiFallback() {
  if (wifiFallbackState != WIFI_FALLBACK_OFF) return;
  wifiManager.setAPCallback(configModeCallback);
  wifiManager.setConfigPortalBlocking(false);
  WiFi.mode(WIFI_STA);
  WiFi.begin(); // reconnect the credentials already stored by WiFiManager
  wifiFallbackState = WIFI_FALLBACK_CONNECTING;
  wifiFallbackStartedMs = millis();
  mainUiShown = false;
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("USB disconnected", 8, 75, 2);
  tft.drawString("Connecting WiFi fallback...", 8, 105, 2);
}

void stopWiFiFallbackForUSB() {
  if (wifiFallbackState == WIFI_FALLBACK_OFF) return;
  if (wifiFallbackState == WIFI_FALLBACK_PORTAL) wifiManager.stopConfigPortal();
  if (webServerStarted) {
    webServer.stop();
    webServerStarted = false;
  }
  WiFi.disconnect(false);
  WiFi.mode(WIFI_OFF);
  wifiFallbackState = WIFI_FALLBACK_OFF;
}

void serviceWiFiFallback() {
  if (wiredActive()) {
    stopWiFiFallbackForUSB();
    return;
  }
  if (wifiFallbackState == WIFI_FALLBACK_OFF) {
    if (millis() - bootMs >= 5000UL) beginWiFiFallback();
    return;
  }
  if (wifiFallbackState == WIFI_FALLBACK_PORTAL) wifiManager.process();
  if (WiFi.status() == WL_CONNECTED) {
    if (wifiFallbackState == WIFI_FALLBACK_PORTAL) wifiManager.stopConfigPortal();
    wifiFallbackState = WIFI_FALLBACK_CONNECTED;
    if (!webServerStarted) {
      setupWebServer();
      webServerStarted = true;
      showMainUiIfNeeded();
      lastPollMs = 0;
    }
    return;
  }
  if (wifiFallbackState == WIFI_FALLBACK_CONNECTING && millis() - wifiFallbackStartedMs >= 10000UL) {
    WiFi.disconnect(false);
    wifiManager.startConfigPortal(WIFI_PORTAL_AP_NAME);
    wifiFallbackState = WIFI_FALLBACK_PORTAL;
  }
}

bool parseStatusJson(const String &payload) {
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) return false;

  JsonObject c = doc["claude"];
  if (!c.isNull()) {
    claudeStatus.status = c["status"] | "unknown";
    claudeStatus.tokensToday = c["tokens_today"] | 0;
    claudeStatus.sessionMin = c["session_min"] | 0;
    claudeStatus.sessionWindowMin = c["session_window_min"] | 300;
    claudeStatus.fiveHourPct = c["five_hour_pct"] | -1.0;
    claudeStatus.fiveHourResetMin = c["five_hour_reset_min"] | -1;
    claudeStatus.sevenDayPct = c["seven_day_pct"] | -1.0;
    claudeStatus.sevenDayResetMin = c["seven_day_reset_min"] | -1;
    claudeStatus.needsInput = c["needs_input"] | false;
    claudeStatus.eligible = c["eligible"] | false;
    claudeStatus.stale = c["stale"] | false;
  }

  JsonObject x = doc["codex"];
  if (!x.isNull()) {
    codexStatus.status = x["status"] | "unknown";
    codexStatus.tokensToday = x["tokens_today"] | 0;
    codexStatus.primaryPct = x["primary_pct"] | -1.0;
    codexStatus.primaryResetMin = x["primary_reset_min"] | -1;
    codexStatus.weeklyPct = x["weekly_pct"] | -1.0;
    codexStatus.weeklyResetMin = x["weekly_reset_min"] | -1;
    codexStatus.needsInput = x["needs_input"] | false;
    codexStatus.eligible = x["eligible"] | false;
    codexStatus.stale = x["stale"] | false;
  }
  JsonObject r = doc["cursor"];
  if (!r.isNull()) {
    cursorStatus.totalPct = r["total_pct"] | -1.0;
    cursorStatus.autoPct = r["auto_pct"] | -1.0;
    cursorStatus.apiPct = r["api_pct"] | -1.0;
    cursorStatus.billingResetMin = r["billing_reset_min"] | -1;
    cursorStatus.eligible = r["eligible"] | false;
    cursorStatus.stale = r["stale"] | false;
  }
  accountsChecked = doc["accounts_checked"] | false;
  if ((displayMode == MODE_CLAUDE && !claudeStatus.eligible)
      || (displayMode == MODE_CODEX && !codexStatus.eligible)
      || (displayMode == MODE_CURSOR && !cursorStatus.eligible)) displayMode = MODE_AUTO;
  return true;
}

DisplayMode effectiveMode() {
  return displayMode;
}

void pollBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) {
    Serial.printf("[bridge] skip poll: wifi=%d host='%s'\n", WiFi.status() == WL_CONNECTED, bridgeHost.c_str());
    return;
  }

  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + BRIDGE_DEFAULT_PATH;
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);

  if (!http.begin(client, url)) {
    Serial.println("[bridge] http.begin() failed");
    return;
  }
  int code = http.GET();
  Serial.printf("[bridge] GET %s -> %d\n", url.c_str(), code);
  if (code == HTTP_CODE_OK) {
    String payload = http.getString();
    if (parseStatusJson(payload)) {
      lastSuccessMs = millis();
      everPolled = true;
      Serial.printf("[bridge] claude=%s tok=%ld | codex=%s tok=%ld primary=%.0f%%\n",
                    claudeStatus.status.c_str(), claudeStatus.tokensToday,
                    codexStatus.status.c_str(), codexStatus.tokensToday, codexStatus.primaryPct);
    } else {
      Serial.println("[bridge] JSON parse failed");
    }
  } else {
    claudeStatus.status = "offline";
    codexStatus.status = "offline";
  }
  http.end();
  DisplayMode eff = effectiveMode();
  if (eff != MODE_CLOCK) {
    // Only a real app switch clears the screen; a plain data refresh paints
    // in place so the poll doesn't flash the whole display.
    if (updateActiveApp()) drawActiveApp();
    else refreshActiveApp();
  }
}

// ---------- USB serial protocol ----------
// Frame: A5 5A | version | type | seq LE | length LE | payload | CRC32 LE.
// CRC covers version through payload. Structured payloads are JSON; files and
// RGB565 resources are transferred as acknowledged binary chunks.
enum USBMessage : uint8_t {
  USB_HELLO = 0x01, USB_HELLO_ACK = 0x02, USB_HEARTBEAT = 0x03, USB_HEARTBEAT_ACK = 0x04,
  USB_STATUS = 0x10, USB_CLOCK = 0x13,
  USB_GET_INFO = 0x20, USB_DEVICE_INFO = 0x21, USB_COMMAND = 0x22, USB_GET_RESOURCE = 0x23,
  USB_RESOURCE_BEGIN = 0x30, USB_RESOURCE_CHUNK = 0x31, USB_RESOURCE_END = 0x32, USB_ACK = 0x7E
};
enum USBResource : uint8_t {
  USB_CLAUDE_GIF = 3, USB_CODEX_GIF = 4,
  USB_CLAUDE_SPRITE = 5, USB_CODEX_SPRITE = 6
};
const uint8_t USB_MAGIC_0 = 0xA5, USB_MAGIC_1 = 0x5A, USB_PROTOCOL_VERSION = 1;
const size_t USB_MAX_PAYLOAD = 1024;
const unsigned long USB_LINK_TIMEOUT_MS = 5000;
unsigned long lastUSBFrameMs = 0;
bool usbEverLinked = false;
uint8_t usbPayload[USB_MAX_PAYLOAD];
uint8_t usbHeader[8];
size_t usbHeaderLen = 0, usbPayloadLen = 0, usbExpectedLen = 0, usbCrcLen = 0;
uint8_t usbCrcBytes[4];

File usbTransferFile;
uint8_t usbTransferResource = 0;
uint8_t usbLastCompletedResource = 0;
uint32_t usbTransferExpected = 0, usbTransferReceived = 0;

bool wiredActive() { return usbEverLinked && (millis() - lastUSBFrameMs) < USB_LINK_TIMEOUT_MS; }

uint32_t usbCRC32Update(uint32_t crc, uint8_t byte) {
  crc ^= byte;
  for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320UL : 0);
  return crc;
}

uint32_t usbCRC32(const uint8_t *header, const uint8_t *payload, size_t len) {
  uint32_t crc = 0xFFFFFFFFUL;
  for (int i = 2; i < 8; i++) crc = usbCRC32Update(crc, header[i]);
  for (size_t i = 0; i < len; i++) crc = usbCRC32Update(crc, payload[i]);
  return crc ^ 0xFFFFFFFFUL;
}

void usbSendFrame(uint8_t type, uint16_t seq, const uint8_t *payload, uint16_t len) {
  uint8_t header[8] = {USB_MAGIC_0, USB_MAGIC_1, USB_PROTOCOL_VERSION, type,
                       (uint8_t)(seq & 0xFF), (uint8_t)(seq >> 8),
                       (uint8_t)(len & 0xFF), (uint8_t)(len >> 8)};
  uint32_t crc = usbCRC32(header, payload, len);
  Serial.write(header, sizeof(header));
  if (len) Serial.write(payload, len);
  uint8_t tail[4] = {(uint8_t)crc, (uint8_t)(crc >> 8), (uint8_t)(crc >> 16), (uint8_t)(crc >> 24)};
  Serial.write(tail, sizeof(tail));
}

void usbSendString(uint8_t type, uint16_t seq, const String &value) {
  usbSendFrame(type, seq, (const uint8_t *)value.c_str(), min(value.length(), USB_MAX_PAYLOAD));
}

void usbSendAck(uint16_t seq, uint8_t status = 0) {
  uint8_t payload[3] = {(uint8_t)(seq & 0xFF), (uint8_t)(seq >> 8), status};
  usbSendFrame(USB_ACK, 0, payload, sizeof(payload));
}

String usbPayloadString(const uint8_t *payload, size_t len) {
  String value;
  value.reserve(len);
  for (size_t i = 0; i < len; i++) value += (char)payload[i];
  return value;
}

// First data over either transport replaces the boot/portal screen.
void showMainUiIfNeeded() {
  if (mainUiShown) return;
  mainUiShown = true;
  drawStaticChrome();
  updateActiveApp();
  drawActiveApp();
}

void resetSpriteFromUSB(ActiveApp slot) {
  const char *path = slot == APP_CLAUDE ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  LittleFS.remove(path);
  spriteRev++;
  loadCustomSpriteState();
  if (slot == APP_CLAUDE) claudeFrame = 0; else codexFrame = 0;
  if (currentApp == slot) drawActiveApp();
}

bool handleUSBCommand(const uint8_t *payload, size_t len) {
  JsonDocument doc;
  if (deserializeJson(doc, payload, len)) return false;
  if (doc["brightness"].is<int>()) {
    brightness = constrain(doc["brightness"].as<int>(), 0, 100);
    applyBrightness();
    saveBrightness();
  }
  const char *mode = doc["display"] | (const char *)nullptr;
  if (mode) {
    String m(mode);
    if (m == "auto") displayMode = MODE_AUTO;
    else if (m == "claude") displayMode = MODE_CLAUDE;
    else if (m == "codex") displayMode = MODE_CODEX;
    else if (m == "cursor") displayMode = MODE_CURSOR;
    else if (m == "clock") displayMode = MODE_CLOCK;
    else return false;
  }
  const char *bridge = doc["bridge"] | (const char *)nullptr;
  if (bridge) { bridgeHost = bridge; bridgeHost.trim(); saveBridgeHost(bridgeHost); }
  const char *reset = doc["reset_sprite"] | (const char *)nullptr;
  if (reset) {
    if (!strcmp(reset, "claude")) resetSpriteFromUSB(APP_CLAUDE);
    else if (!strcmp(reset, "codex")) resetSpriteFromUSB(APP_CODEX);
    else return false;
  }
  return true;
}

const char *usbTransferTarget(uint8_t resource) {
  if (resource == USB_CLAUDE_GIF) return CLAUDE_GIF_FILE;
  if (resource == USB_CODEX_GIF) return CODEX_GIF_FILE;
  return nullptr;
}

bool beginUSBTransfer(const uint8_t *payload, size_t len) {
  if (len < 5 || !usbTransferTarget(payload[0])) return false;
  if (usbTransferFile) usbTransferFile.close();
  LittleFS.remove(USB_TRANSFER_FILE);
  usbTransferResource = payload[0];
  usbLastCompletedResource = 0;
  usbTransferExpected = (uint32_t)payload[1] | ((uint32_t)payload[2] << 8)
      | ((uint32_t)payload[3] << 16) | ((uint32_t)payload[4] << 24);
  usbTransferReceived = 0;
  usbTransferFile = LittleFS.open(USB_TRANSFER_FILE, "w");
  return (bool)usbTransferFile;
}

bool appendUSBTransfer(const uint8_t *payload, size_t len) {
  if (len < 5 || !usbTransferFile || payload[0] != usbTransferResource) return false;
  uint32_t offset = (uint32_t)payload[1] | ((uint32_t)payload[2] << 8)
      | ((uint32_t)payload[3] << 16) | ((uint32_t)payload[4] << 24);
  // An ACK can be lost even though the block was committed. Accept an exact
  // duplicate range so the Mac can retry that block without restarting.
  if (offset < usbTransferReceived && offset + len - 5 <= usbTransferReceived) return true;
  if (offset != usbTransferReceived || usbTransferReceived + len - 5 > usbTransferExpected) return false;
  size_t written = usbTransferFile.write(payload + 5, len - 5);
  usbTransferReceived += written;
  return written == len - 5;
}

bool finishUSBTransfer(uint8_t resource) {
  if (!usbTransferFile && resource == usbLastCompletedResource) return true;
  if (!usbTransferFile || resource != usbTransferResource) return false;
  usbTransferFile.close();
  if (usbTransferReceived != usbTransferExpected) { LittleFS.remove(USB_TRANSFER_FILE); return false; }
  const char *target = usbTransferTarget(resource);
  LittleFS.remove(target);
  if (!LittleFS.rename(USB_TRANSFER_FILE, target)) return false;
  bool ok = true;
  if (resource == USB_CLAUDE_GIF || resource == USB_CODEX_GIF) {
    ActiveApp slot = resource == USB_CLAUDE_GIF ? APP_CLAUDE : APP_CODEX;
    const char *binPath = slot == APP_CLAUDE ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
    int w = slot == APP_CLAUDE ? CLAUDE_SPRITE_W : CODEX_SPRITE_W;
    int h = slot == APP_CLAUDE ? CLAUDE_SPRITE_H : CODEX_SPRITE_H;
    ok = decodeGifToBin(target, binPath, w, h);
    LittleFS.remove(target);
    if (ok) {
      spriteRev++;
      loadCustomSpriteState();
      if (slot == APP_CLAUDE) claudeFrame = 0; else codexFrame = 0;
      if (currentApp == slot) drawActiveApp();
    }
  }
  usbTransferResource = 0;
  usbLastCompletedResource = resource;
  usbTransferExpected = usbTransferReceived = 0;
  return ok;
}

void sendSpriteResource(uint16_t seq, USBResource resource) {
  ActiveApp slot = resource == USB_CODEX_SPRITE ? APP_CODEX : APP_CLAUDE;
  bool custom = slot == APP_CLAUDE ? claudeCustom : codexCustom;
  const char *path = slot == APP_CLAUDE ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  int frames = slot == APP_CLAUDE ? claudeFrameCount() : codexFrameCount();
  int w = slot == APP_CLAUDE ? CLAUDE_SPRITE_W : CODEX_SPRITE_W;
  int h = slot == APP_CLAUDE ? CLAUDE_SPRITE_H : CODEX_SPRITE_H;
  size_t frameBytes = (size_t)w * h * 2;
  uint32_t total = 1 + (uint32_t)frames * frameBytes;
  uint8_t begin[5] = {(uint8_t)resource, (uint8_t)total, (uint8_t)(total >> 8),
                      (uint8_t)(total >> 16), (uint8_t)(total >> 24)};
  usbSendFrame(USB_RESOURCE_BEGIN, seq, begin, sizeof(begin));
  File file;
  if (custom) file = LittleFS.open(path, "r");
  const uint16_t *const *progmemFrames = slot == APP_CLAUDE ? claude_sprite_frames : codex_sprite_frames;
  uint8_t chunk[USB_MAX_PAYLOAD];
  uint32_t offset = 0;
  while (offset < total) {
    size_t count = min((uint32_t)(USB_MAX_PAYLOAD - 5), total - offset);
    chunk[0] = (uint8_t)resource;
    chunk[1] = (uint8_t)offset; chunk[2] = (uint8_t)(offset >> 8);
    chunk[3] = (uint8_t)(offset >> 16); chunk[4] = (uint8_t)(offset >> 24);
    if (custom) {
      file.seek(offset);
      file.read(chunk + 5, count);
    } else {
      for (size_t i = 0; i < count; i++) {
        uint32_t pos = offset + i;
        if (pos == 0) chunk[5 + i] = (uint8_t)frames;
        else {
          pos--;
          int frame = pos / frameBytes;
          size_t inFrame = pos % frameBytes;
          chunk[5 + i] = pgm_read_byte(((const uint8_t *)progmemFrames[frame]) + inFrame);
        }
      }
    }
    usbSendFrame(USB_RESOURCE_CHUNK, seq, chunk, count + 5);
    offset += count;
    yield();
  }
  if (file) file.close();
  uint8_t end = (uint8_t)resource;
  usbSendFrame(USB_RESOURCE_END, seq, &end, 1);
}

void handleUSBFrame(uint8_t type, uint16_t seq, const uint8_t *payload, size_t len) {
  lastUSBFrameMs = millis();
  usbEverLinked = true;
  if (type == USB_HELLO) { usbSendString(USB_HELLO_ACK, seq, buildDeviceInfoJson()); return; }
  if (type == USB_HEARTBEAT) { usbSendFrame(USB_HEARTBEAT_ACK, seq, nullptr, 0); return; }
  if (type == USB_STATUS) {
    if (parseStatusJson(usbPayloadString(payload, len))) {
      lastSuccessMs = millis(); everPolled = true; showMainUiIfNeeded();
      DisplayMode eff = effectiveMode();
      if (eff != MODE_CLOCK) {
        if (updateActiveApp()) drawActiveApp(); else refreshActiveApp();
      }
    }
    return;
  }
  if (type == USB_CLOCK) { handleClockPayload(usbPayloadString(payload, len)); return; }
  if (type == USB_GET_INFO) { usbSendString(USB_DEVICE_INFO, seq, buildDeviceInfoJson()); return; }
  if (type == USB_COMMAND) { usbSendAck(seq, handleUSBCommand(payload, len) ? 0 : 1); return; }
  if (type == USB_RESOURCE_BEGIN) { usbSendAck(seq, beginUSBTransfer(payload, len) ? 0 : 1); return; }
  if (type == USB_RESOURCE_CHUNK) { usbSendAck(seq, appendUSBTransfer(payload, len) ? 0 : 1); return; }
  if (type == USB_RESOURCE_END) {
    bool ok = len == 1 && finishUSBTransfer(payload[0]);
    usbSendAck(seq, ok ? 0 : 1);
    return;
  }
  if (type == USB_GET_RESOURCE && len == 1) {
    USBResource resource = (USBResource)payload[0];
    if (resource == USB_CLAUDE_SPRITE || resource == USB_CODEX_SPRITE) sendSpriteResource(seq, resource);
  }
}

void resetUSBParser() {
  usbHeaderLen = usbPayloadLen = usbExpectedLen = usbCrcLen = 0;
}

// Streaming parser resynchronizes on A5 5A, so ROM boot bytes and debug logs
// cannot become commands. A CRC failure drops only that frame.
void pumpSerial() {
  while (Serial.available()) {
    uint8_t byte = Serial.read();
    if (usbHeaderLen < 2) {
      if (usbHeaderLen == 0 && byte == USB_MAGIC_0) usbHeader[usbHeaderLen++] = byte;
      else if (usbHeaderLen == 1 && byte == USB_MAGIC_1) usbHeader[usbHeaderLen++] = byte;
      else usbHeaderLen = byte == USB_MAGIC_0 ? 1 : 0;
      continue;
    }
    if (usbHeaderLen < 8) {
      usbHeader[usbHeaderLen++] = byte;
      if (usbHeaderLen == 8) {
        usbExpectedLen = (size_t)usbHeader[6] | ((size_t)usbHeader[7] << 8);
        if (usbHeader[2] != USB_PROTOCOL_VERSION || usbExpectedLen > USB_MAX_PAYLOAD) resetUSBParser();
      }
      continue;
    }
    if (usbPayloadLen < usbExpectedLen) { usbPayload[usbPayloadLen++] = byte; continue; }
    usbCrcBytes[usbCrcLen++] = byte;
    if (usbCrcLen == 4) {
      uint32_t expected = (uint32_t)usbCrcBytes[0] | ((uint32_t)usbCrcBytes[1] << 8)
          | ((uint32_t)usbCrcBytes[2] << 16) | ((uint32_t)usbCrcBytes[3] << 24);
      uint32_t actual = usbCRC32(usbHeader, usbPayload, usbExpectedLen);
      if (expected == actual) {
        uint16_t seq = (uint16_t)usbHeader[4] | ((uint16_t)usbHeader[5] << 8);
        handleUSBFrame(usbHeader[3], seq, usbPayload, usbExpectedLen);
      }
      resetUSBParser();
    }
  }
}

// ---------- web admin ----------

String htmlEscape(const String &s) {
  String out = s;
  out.replace("&", "&amp;");
  out.replace("<", "&lt;");
  out.replace(">", "&gt;");
  out.replace("\"", "&quot;");
  return out;
}

void handleRoot() {
  String age = everPolled ? String((millis() - lastSuccessMs) / 1000) + "s ago" : "never";
  String html;
  html.reserve(3072);
  html += "<!DOCTYPE html><html><head><meta charset='utf-8'>";
  html += "<meta name='viewport' content='width=device-width, initial-scale=1'>";
  html += "<title>AI Clock 设置</title>";
  html += "<style>body{font-family:-apple-system,sans-serif;max-width:480px;margin:24px "
          "auto;padding:0 16px;color:#222} h1{font-size:20px} label{display:block;margin-top:16px;font-weight:600}"
          "input{width:100%;box-sizing:border-box;padding:8px;font-size:16px;margin-top:4px}"
          "button{margin-top:16px;padding:10px 20px;font-size:16px;background:#2563eb;color:#fff;"
          "border:none;border-radius:6px}"
          "table{margin-top:20px;border-collapse:collapse;width:100%}"
          "td{padding:4px 8px;border-bottom:1px solid #eee;font-size:14px}"
          ".dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}"
          "</style></head><body>";
  html += "<h1>AI Clock 设置</h1>";

  html += "<form method='POST' action='/save'>";
  html += "<label>Bridge host (ip:port)</label>";
  html += "<input name='bridge' value='" + htmlEscape(bridgeHost) + "' placeholder='192.168.1.181:8765'>";
  html += "<button type='submit'>保存</button>";
  html += "</form>";

  // Backlight brightness slider: applies live on release (PWM, persisted).
  html += "<h2 style='font-size:16px;margin-top:28px'>屏幕亮度</h2>";
  html += "<input type='range' min='0' max='100' value='" + String(brightness) + "' id='bri' "
          "oninput=\"document.getElementById('briv').textContent=this.value+'%'\" "
          "onchange=\"fetch('/api/brightness',{method:'POST',headers:{'Content-Type':"
          "'application/x-www-form-urlencoded'},body:'level='+this.value})\">";
  html += "<div style='font-size:13px;color:#555'>当前：<span id='briv'>" + String(brightness) +
          "%</span>（0 = 熄屏，设置立即生效并记住）</div>";

  // On-device GIF upload: replaces a character's animation without reflashing.
  html += "<h2 style='font-size:16px;margin-top:28px'>桌宠动画（上传 GIF）</h2>";
  html += "<p style='font-size:13px;color:#555'>上传一个 .gif，设备会在板上解码并缩放到对应角色的尺寸，"
          "立刻替换动画，无需重新编译或烧录。GIF 太大可能因内存不足解码失败，换小一点的即可。</p>";
  html += "<form id='gifForm' method='POST' enctype='multipart/form-data' onsubmit='return setGifAction()'>";
  html += "<label>角色</label>";
  html += "<select id='gifTarget'><option value='claude'>Claude</option><option value='codex'>Codex</option></select>";
  html += "<label>GIF 文件</label><input type='file' name='file' accept='.gif' required>";
  html += "<button type='submit'>上传并应用</button>";
  html += "</form>";
  html += "<script>function setGifAction(){"
          "document.getElementById('gifForm').action='/sprite/'+document.getElementById('gifTarget').value;"
          "return true;}</script>";

  html += "<table>";
  html += "<tr><td>WiFi SSID</td><td>" + htmlEscape(WiFi.SSID()) + "</td></tr>";
  html += "<tr><td>设备 IP</td><td>" + WiFi.localIP().toString() + "</td></tr>";
  html += "<tr><td>上次桥接更新</td><td>" + age + "</td></tr>";
  html += "<tr><td>Claude</td><td>" + htmlEscape(claudeStatus.status) + ", " +
          formatTokens(claudeStatus.tokensToday) + " tok</td></tr>";
  html += "<tr><td>Codex</td><td>" + htmlEscape(codexStatus.status) + ", " +
          formatTokens(codexStatus.tokensToday) + " tok, 5h left " + pctText(remainingPct(codexStatus.primaryPct)) +
          ", Wk left " + pctText(remainingPct(codexStatus.weeklyPct)) + "</td></tr>";
  html += "<tr><td>Cursor</td><td>Total left " +
          pctText(remainingPct(cursorStatus.totalPct)) + ", Auto left " +
          pctText(remainingPct(cursorStatus.autoPct)) + ", API left " +
          pctText(remainingPct(cursorStatus.apiPct)) + "</td></tr>";
  html += "</table>";

  html += "<form method='POST' action='/reset-wifi' onsubmit=\"return confirm('清除 WiFi "
          "设置并重启？设备会开启配网热点。');\">";
  html += "<button type='submit' style='background:#dc2626'>重置 WiFi</button>";
  html += "</form>";

  html += "</body></html>";
  webServer.send(200, "text/html", html);
}

void handleSave() {
  String newHost = webServer.arg("bridge");
  newHost.trim();
  bridgeHost = newHost;
  saveBridgeHost(bridgeHost);
  Serial.printf("[web] bridge host updated to '%s'\n", bridgeHost.c_str());
  webServer.sendHeader("Location", "/");
  webServer.send(303);
}

// ---------- JSON API for the Mac app ----------

const char *displayModeName(DisplayMode m) {
  if (m == MODE_CLAUDE) return "claude";
  if (m == MODE_CODEX) return "codex";
  if (m == MODE_CURSOR) return "cursor";
  if (m == MODE_CLOCK) return "clock";
  return "auto";
}

String buildDeviceInfoJson() {
  JsonDocument doc;
  doc["ip"] = WiFi.localIP().toString();
  doc["ssid"] = WiFi.SSID();
  doc["bridge"] = bridgeHost;
  doc["mode"] = displayModeName(displayMode);           // configured mode
  doc["effective"] = displayModeName(effectiveMode());   // what's on screen now
  doc["showing"] = currentApp == APP_CLAUDE ? "claude"
      : currentApp == APP_CODEX ? "codex" : currentApp == APP_CURSOR ? "cursor"
      : accountsChecked ? "none" : "checking";
  doc["last_update_s"] = everPolled ? (long)((millis() - lastSuccessMs) / 1000) : -1;
  doc["sprite_rev"] = spriteRev;
  doc["brightness"] = brightness;
  doc["wired"] = wiredActive(); // true = data currently arrives over USB serial
  doc["transport"] = wiredActive() ? "usb" : "wifi";
  doc["fw"] = FW_VERSION;
  JsonObject c = doc["claude"].to<JsonObject>();
  c["status"] = claudeStatus.status;
  c["custom_sprite"] = claudeCustom;
  c["w"] = CLAUDE_SPRITE_W;
  c["h"] = CLAUDE_SPRITE_H;
  JsonObject x = doc["codex"].to<JsonObject>();
  x["status"] = codexStatus.status;
  x["custom_sprite"] = codexCustom;
  x["w"] = CODEX_SPRITE_W;
  x["h"] = CODEX_SPRITE_H;
  JsonObject r = doc["cursor"].to<JsonObject>();
  r["eligible"] = cursorStatus.eligible;
  String out;
  serializeJson(doc, out);
  return out;
}

void handleApiInfo() {
  webServer.send(200, "application/json", buildDeviceInfoJson());
}

void handleApiDisplay() {
  String mode = webServer.arg("mode");
  if (mode == "auto") displayMode = MODE_AUTO;
  else if (mode == "claude") displayMode = MODE_CLAUDE;
  else if (mode == "codex") displayMode = MODE_CODEX;
  else if (mode == "cursor") displayMode = MODE_CURSOR;
  else if (mode == "clock") displayMode = MODE_CLOCK;
  else {
    webServer.send(400, "text/plain", "mode must be auto|claude|codex|cursor|clock");
    return;
  }
  Serial.printf("[api] display mode = %s\n", mode.c_str());
  if (displayMode == MODE_CLOCK) {
    clockChromeDrawn = false;
    lastClockPollMs = 0; // poll + draw on the next loop tick
  } else {
    updateActiveApp();
    drawActiveApp(); // unconditional: also repaints over a previous clock page
  }
  webServer.send(200, "text/plain", "ok");
}

void handleApiBrightness() {
  String levelArg = webServer.arg("level");
  if (levelArg.length() == 0) {
    webServer.send(400, "text/plain", "missing level (0-100)");
    return;
  }
  int level = levelArg.toInt();
  if (level < 0) level = 0;
  if (level > 100) level = 100;
  brightness = level;
  applyBrightness();
  saveBrightness();
  Serial.printf("[api] brightness = %d\n", brightness);
  webServer.send(200, "text/plain", "ok");
}

void handleApiBridge() {
  String newHost = webServer.arg("host");
  newHost.trim();
  if (newHost.length() == 0) {
    webServer.send(400, "text/plain", "missing host");
    return;
  }
  bridgeHost = newHost;
  saveBridgeHost(bridgeHost);
  Serial.printf("[api] bridge host = '%s'\n", bridgeHost.c_str());
  webServer.send(200, "text/plain", "ok");
  lastPollMs = 0; // poll the new bridge on the next loop tick
}

// Streams the animation currently in use for a slot, in the same wire format
// as the custom .bin: [1 byte frame count][RGB565 frames...]. Lets the Mac
// app mirror exactly what the device is showing (custom upload or built-in).
void handleSpriteRaw(ActiveApp slot) {
  bool custom = (slot == APP_CLAUDE) ? claudeCustom : codexCustom;
  const char *binPath = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  if (custom) {
    File f = LittleFS.open(binPath, "r");
    if (f) {
      webServer.streamFile(f, "application/octet-stream");
      f.close();
      return;
    }
  }
  int frames = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FRAMES : CODEX_SPRITE_FRAMES;
  int w = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_W : CODEX_SPRITE_W;
  int h = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_H : CODEX_SPRITE_H;
  const uint16_t *const *arr = (slot == APP_CLAUDE) ? claude_sprite_frames : codex_sprite_frames;
  size_t frameBytes = (size_t)w * h * 2;
  webServer.setContentLength(1 + (size_t)frames * frameBytes);
  webServer.send(200, "application/octet-stream", "");
  uint8_t cnt = (uint8_t)frames;
  webServer.sendContent((const char *)&cnt, 1);
  for (int i = 0; i < frames; i++) {
    webServer.sendContent_P((PGM_P)arr[i], frameBytes);
    yield();
  }
}

// Removes a custom sprite so the compiled-in default animation comes back.
void handleSpriteReset(ActiveApp slot) {
  const char *binPath = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  LittleFS.remove(binPath);
  spriteRev++;
  loadCustomSpriteState();
  if (slot == APP_CLAUDE) claudeFrame = 0;
  else codexFrame = 0;
  if (currentApp == slot) drawActiveApp();
  webServer.send(200, "text/plain", "ok");
}

void handleResetWifi() {
  webServer.send(200, "text/html", "<html><body>Resetting WiFi, device will restart...</body></html>");
  delay(200);
  WiFiManager wm;
  wm.resetSettings();
  ESP.restart();
}

// ---------- on-device GIF decode (AnimatedGIF) ----------
// AnimatedGIF hands us the image one horizontal line at a time (via the draw
// callback) at the GIF's native resolution, so we never need a full-canvas
// buffer. We nearest-neighbour rescale into the target slot size and stream the
// result straight to the .bin one target row at a time. Because the .bin can't
// hold a whole frame in RAM to composite against, GIFs that only re-encode a
// changed sub-rectangle (the common optimizer output, disposal method 1) are
// composited by reading the *previous frame's* rows back out of the .bin we're
// writing. (Disposal method 2 "restore to background" isn't distinguished -
// uncovered pixels keep the previous frame instead of clearing; fine for the
// looping character animations this is for.)

struct GifDecodeCtx {
  int canvasW, canvasH; // GIF native size
  int targetW, targetH; // slot size we're rescaling down to
  size_t rowBytes;      // targetW * 2
  File out;             // output .bin, written sequentially
  File prevFile;        // previous frame in the .bin, read sequentially for compositing
  bool hasPrev;         // false for frame 0 (nothing to composite over -> black)
  int producedRow;      // next target row still owed for the current frame
};

static File gifReadFile; // one decode runs at a time, so a single handle is fine

void *gifOpenCB(const char *fname, int32_t *pSize) {
  gifReadFile = LittleFS.open(fname, "r");
  if (!gifReadFile) return nullptr;
  *pSize = (int32_t)gifReadFile.size();
  return (void *)&gifReadFile;
}

void gifCloseCB(void *) {
  if (gifReadFile) gifReadFile.close();
}

int32_t gifReadCB(GIFFILE *pFile, uint8_t *pBuf, int32_t iLen) {
  File *f = (File *)pFile->fHandle;
  // AnimatedGIF's own SD example keeps this one-byte-short guard near EOF.
  if ((pFile->iSize - pFile->iPos) < iLen) iLen = pFile->iSize - pFile->iPos - 1;
  if (iLen <= 0) return 0;
  int32_t n = (int32_t)f->read(pBuf, iLen);
  pFile->iPos = (int32_t)f->position();
  return n;
}

int32_t gifSeekCB(GIFFILE *pFile, int32_t iPosition) {
  File *f = (File *)pFile->fHandle;
  f->seek(iPosition);
  pFile->iPos = iPosition;
  return iPosition;
}

// Loads the next previous-frame row into prevRowBuf (black if there's no
// previous frame). Reads are sequential and stay aligned with producedRow.
static void readPrevRow(GifDecodeCtx *ctx) {
  if (ctx->hasPrev)
    ctx->prevFile.read((uint8_t *)prevRowBuf, ctx->rowBytes);
  else
    memset(prevRowBuf, 0, ctx->rowBytes);
}

// Appends the current rowBuf as the next output row.
static void emitRow(GifDecodeCtx *ctx) {
  ctx->out.write((const uint8_t *)rowBuf, ctx->rowBytes);
  ctx->producedRow++;
}

// Emits a row that this frame doesn't touch: a straight copy of the previous
// frame (top/bottom gaps of a partial frame).
static void emitPrevRow(GifDecodeCtx *ctx) {
  readPrevRow(ctx);
  memcpy(rowBuf, prevRowBuf, ctx->rowBytes);
  emitRow(ctx);
}

// Rescales one decoded native line into target rows, compositing over the
// previous frame, and streams every target row it can now finalize.
void gifDrawCB(GIFDRAW *pDraw) {
  GifDecodeCtx *ctx = (GifDecodeCtx *)pDraw->pUser;
  int sy = pDraw->iY + pDraw->y; // absolute source line on the GIF canvas
  if (sy < 0 || sy >= ctx->canvasH) return;

  const uint8_t *pal = pDraw->pPalette24; // RGB888, 256 entries
  const uint8_t *src = pDraw->pPixels;    // palette indices, one per pixel of this line
  bool hasTrans = pDraw->ucHasTransparency;
  uint8_t transIdx = pDraw->ucTransparent;

  // Emit every target row whose nearest source line is <= sy and isn't done yet.
  while (ctx->producedRow < ctx->targetH) {
    int ty = ctx->producedRow;
    int srcRow = (int)((long)ty * ctx->canvasH / ctx->targetH);
    if (srcRow > sy) break;                       // needs a later source line
    if (srcRow < sy) { emitPrevRow(ctx); continue; } // source line was skipped -> previous frame

    // srcRow == sy: composite this source line over the previous frame's row.
    readPrevRow(ctx);
    memcpy(rowBuf, prevRowBuf, ctx->rowBytes);
    for (int tx = 0; tx < ctx->targetW; tx++) {
      int sx = (int)((long)tx * ctx->canvasW / ctx->targetW);
      int rel = sx - pDraw->iX;
      if (rel < 0 || rel >= pDraw->iWidth) continue; // outside this frame's rect: keep previous pixel
      uint8_t idx = src[rel];
      if (hasTrans && idx == transIdx) continue;     // transparent: keep previous pixel
      uint8_t r = pal[idx * 3 + 0], g = pal[idx * 3 + 1], b = pal[idx * 3 + 2];
      uint16_t val = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
      rowBuf[tx] = (uint16_t)(((val & 0xFF) << 8) | (val >> 8)); // byte-swap to match convert_sprites.py
    }
    emitRow(ctx);
  }
}

// Decodes gifPath into binPath in the [count][frames...] wire format the
// display path reads. Returns false on open/decode failure.
bool decodeGifToBin(const char *gifPath, const char *binPath, int targetW, int targetH) {
  // AnimatedGIF's internal state (~24KB of LZW/line/palette buffers) is big, so
  // allocate it on the heap only for the duration of a decode rather than
  // paying for it in .bss for the whole uptime.
  AnimatedGIF *gif = new AnimatedGIF();
  if (!gif) return false;
  gif->begin(GIF_PALETTE_RGB888);
  if (!gif->open(gifPath, gifOpenCB, gifCloseCB, gifReadCB, gifSeekCB, gifDrawCB)) {
    Serial.printf("[gif] open failed err=%d\n", gif->getLastError());
    delete gif;
    return false;
  }

  GifDecodeCtx ctx;
  ctx.canvasW = gif->getCanvasWidth();
  ctx.canvasH = gif->getCanvasHeight();
  ctx.targetW = targetW;
  ctx.targetH = targetH;
  ctx.rowBytes = (size_t)targetW * 2;
  ctx.hasPrev = false;
  size_t frameBytes = (size_t)targetW * targetH * 2;

  ctx.out = LittleFS.open(binPath, "w");
  if (!ctx.out) {
    gif->close();
    delete gif;
    return false;
  }
  ctx.out.write((uint8_t)0); // placeholder frame count, patched once we know the total

  uint8_t count = 0;
  int delayMs = 0, more = 1;
  while (count < MAX_CUSTOM_FRAMES) {
    ctx.producedRow = 0;
    ctx.hasPrev = false;
    if (count > 0) {
      ctx.out.flush(); // make the just-written previous frame visible to the read handle
      ctx.prevFile = LittleFS.open(binPath, "r");
      ctx.hasPrev = (bool)ctx.prevFile;
      if (ctx.hasPrev) ctx.prevFile.seek(1 + (size_t)(count - 1) * frameBytes);
    }

    more = gif->playFrame(false, &delayMs, &ctx);

    if (more >= 0) {
      // finalize any bottom rows this frame never touched
      while (ctx.producedRow < ctx.targetH) emitPrevRow(&ctx);
      count++;
    }
    if (ctx.prevFile) ctx.prevFile.close();
    if (more <= 0) break; // 0 = last frame, <0 = decode error
    yield();              // feed the WDT between frames
  }
  gif->close();
  delete gif;
  ctx.out.close();

  if (count == 0) {
    LittleFS.remove(binPath);
    return false;
  }
  File patch = LittleFS.open(binPath, "r+");
  if (patch) {
    patch.seek(0);
    patch.write(count);
    patch.close();
  }
  Serial.printf("[gif] decoded %d frame(s) %dx%d -> %dx%d\n", count, ctx.canvasW, ctx.canvasH, targetW, targetH);
  return true;
}

// ---------- sprite upload (raw .gif -> on-device decode) ----------
// ESP8266WebServer fully buffers a plain POST body into a heap String before
// the handler runs, which a whole GIF would blow RAM on - so we take the
// upload over its streaming multipart/HTTPUpload path, writing the raw .gif to
// LittleFS in small chunks, then decode it on the done callback.
File uploadFile;

void handleSpriteUploadChunk(const char *gifPath) {
  HTTPUpload &upload = webServer.upload();
  if (upload.status == UPLOAD_FILE_START) {
    uploadFile = LittleFS.open(gifPath, "w");
  } else if (upload.status == UPLOAD_FILE_WRITE) {
    if (uploadFile) uploadFile.write(upload.buf, upload.currentSize);
  } else if (upload.status == UPLOAD_FILE_END || upload.status == UPLOAD_FILE_ABORTED) {
    if (uploadFile) uploadFile.close();
  }
}

void handleSpriteUploadDone(ActiveApp slot) {
  const char *gifPath = (slot == APP_CLAUDE) ? CLAUDE_GIF_FILE : CODEX_GIF_FILE;
  const char *binPath = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_FILE : CODEX_SPRITE_FILE;
  int tw = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_W : CODEX_SPRITE_W;
  int th = (slot == APP_CLAUDE) ? CLAUDE_SPRITE_H : CODEX_SPRITE_H;

  bool ok = decodeGifToBin(gifPath, binPath, tw, th);
  LittleFS.remove(gifPath); // temp raw gif no longer needed once decoded

  spriteRev++;
  loadCustomSpriteState();
  if (slot == APP_CLAUDE) claudeFrame = 0;
  else codexFrame = 0;
  if (currentApp == slot) drawActiveApp();

  if (ok) {
    webServer.send(200, "text/plain", "ok");
    Serial.println("[sprite] gif decoded & applied");
  } else {
    webServer.send(500, "text/plain", "gif decode failed (too large or unsupported?)");
    Serial.println("[sprite] gif decode FAILED");
  }
}

void setupWebServer() {
  if (!webServerConfigured) {
    webServer.on("/", HTTP_GET, handleRoot);
    webServer.on("/save", HTTP_POST, handleSave);
    webServer.on("/reset-wifi", HTTP_POST, handleResetWifi);
    webServer.on("/api/info", HTTP_GET, handleApiInfo);
    webServer.on("/api/display", HTTP_POST, handleApiDisplay);
    webServer.on("/api/bridge", HTTP_POST, handleApiBridge);
    webServer.on("/api/brightness", HTTP_POST, handleApiBrightness);
    webServer.on("/sprite/claude/reset", HTTP_POST, []() { handleSpriteReset(APP_CLAUDE); });
    webServer.on("/sprite/codex/reset", HTTP_POST, []() { handleSpriteReset(APP_CODEX); });
    webServer.on("/sprite/claude/raw", HTTP_GET, []() { handleSpriteRaw(APP_CLAUDE); });
    webServer.on("/sprite/codex/raw", HTTP_GET, []() { handleSpriteRaw(APP_CODEX); });
    webServer.on(
        "/sprite/claude", HTTP_POST, []() { handleSpriteUploadDone(APP_CLAUDE); },
        []() { handleSpriteUploadChunk(CLAUDE_GIF_FILE); });
    webServer.on(
        "/sprite/codex", HTTP_POST, []() { handleSpriteUploadDone(APP_CODEX); },
        []() { handleSpriteUploadChunk(CODEX_GIF_FILE); });
    webServerConfigured = true;
  }
  webServer.begin();
  Serial.printf("[web] admin server listening on http://%s/\n", WiFi.localIP().toString().c_str());
}

// ---------- Arduino entry points ----------

void setup() {
  Serial.setRxBufferSize(4096);
  Serial.begin(460800);
  LittleFS.begin();
  loadBridgeHost();
  loadBrightness();
  loadCustomSpriteState();

  tft.init();
  tft.setRotation(0);
  tft.fillScreen(TFT_BLACK);
  analogWriteFreq(BRIGHTNESS_PWM_FREQ);
  analogWriteRange(100); // duty maps 1:1 to a 0-100 percentage
  applyBrightness();
  WiFi.mode(WIFI_OFF);
  bootMs = millis();
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("Waiting for USB...", 8, 85, 2);
  tft.setTextColor(TFT_CYAN, TFT_BLACK);
  tft.drawString("USB is the default link", 8, 115, 2);
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString("WiFi fallback in 5s", 8, 145, 2);
  tft.drawString("Firmware v" FW_VERSION, 8, 215, 2);
}

void loop() {
  pumpSerial();
  serviceWiFiFallback();
  if (webServerStarted) webServer.handleClient();
  if (!mainUiShown) return;

  unsigned long nowMs = millis();

  // On a transition, reset the incoming mode's chrome so it repaints cleanly,
  // and repaint the pet immediately when returning to it.
  DisplayMode eff = effectiveMode();
  if (eff != lastEffectiveMode) {
    lastEffectiveMode = eff;
    if (eff == MODE_CLOCK) {
      clockChromeDrawn = false;
      lastClockPollMs = 0;
      drawClockScreen();
    } else {
      updateActiveApp();
      drawActiveApp();
    }
  }

  if (eff == MODE_CLOCK) {
    if (nowMs - lastClockPollMs >= CLOCK_POLL_INTERVAL_MS) {
      lastClockPollMs = nowMs;
      if (!wiredActive()) pollClock();
    }
  } else {
    // sprite walk-cycle animation (only advances while that app is showing)
    if (nowMs - lastAnimMs >= ANIM_INTERVAL_MS) {
      lastAnimMs = nowMs;
      bool claudeWorking = claudeStatus.status == "working";
      bool codexWorking = codexStatus.status == "working";
      if (showingCd != CD_NONE) {
        // countdown owns the center area: no sprite frames over it
      } else if (currentApp == APP_CLAUDE && claudeWorking) {
        claudeFrame = (claudeFrame + 1) % claudeFrameCount();
        drawClaudeSprite(claudeFrame);
      } else if (currentApp == APP_CODEX && codexWorking) {
        codexFrame = (codexFrame + 1) % codexFrameCount();
        drawCodexSprite(codexFrame);
      } else if (currentApp == APP_CURSOR) {
        cursorFrame = (cursorFrame + 1) % CURSOR_SPRITE_FRAMES;
        drawCursorSprite(cursorFrame);
      }
    }

    // countdown seconds tick locally between bridge polls
    static unsigned long lastCdTickMs = 0;
    if (showingCd != CD_NONE && nowMs - lastCdTickMs >= 1000) {
      lastCdTickMs = nowMs;
      drawCountdown(false);
    }

    // "urgent" flash toggle (independent, faster cadence)
    if (nowMs - lastFlashMs >= FLASH_INTERVAL_MS) {
      lastFlashMs = nowMs;
      flashOn = !flashOn;
      if (bridgeStale()) {
        redrawRingOnly();
      } else if (currentAppNeedsInput()) {
        // approval needed: blink the whole border red, restore the quota ring
        // on the off-phase so it doesn't erase the normal chrome permanently
        if (flashOn) drawFullBorder(TFT_RED);
        else redrawRingOnly();
      }
    }

    // alternate which app is shown when neither/both are uniquely working
    if (updateActiveApp()) {
      drawActiveApp();
    }
  }

  // status poll continues in every mode (feeds /api/info and the web page).
  // Wired-first: while serial frames are flowing, skip HTTP polling entirely
  // (works around AP client isolation, and avoids double updates).
  if (nowMs - lastPollMs >= BRIDGE_POLL_INTERVAL_MS) {
    lastPollMs = nowMs;
    if (!wiredActive()) pollBridge();
  }
}
