// Reservation display for the Elecrow CrowPanel 2.13-inch ESP32-S3 e-paper HMI.
#include <Arduino.h>
#include <ArduinoJson.h>
#include <GxEPD2_BW.h>
#include <Preferences.h>
#include <PubSubClient.h>
#include <WiFi.h>

#include "Config.h"

namespace {
constexpr uint8_t EPD_BUSY = 9, EPD_RESET = 10, EPD_DC = 13, EPD_CS = 14;
constexpr uint8_t EPD_SCK = 12, EPD_MOSI = 11;
constexpr uint8_t MENU_BUTTON = 2, EXIT_BUTTON = 1;
constexpr uint8_t DIAL_LEFT = 6, DIAL_RIGHT = 4, DIAL_PRESS = 5;
constexpr uint32_t DEBOUNCE_MS = 180, RECONNECT_MS = 5000;
constexpr size_t MAX_SHOPS = 32, MAX_TOOLS = 96;

GxEPD2_BW<GxEPD2_213_BN, GxEPD2_213_BN::HEIGHT> display(
    GxEPD2_213_BN(EPD_CS, EPD_DC, EPD_RESET, EPD_BUSY));
WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);
Preferences preferences;

struct Reservation {
  bool present = false;
  String id, title, member, start, end;
};
struct KnownTool {
  String shop, tool;
};
enum class Screen { MAIN, CHOOSE_SHOP, CHOOSE_TOOL };
enum class Layout { COLUMNS, UP_NEXT };

Reservation currentReservation, upNextReservation;
String shops[MAX_SHOPS];
KnownTool tools[MAX_TOOLS];
size_t shopCount = 0, toolCount = 0, selectedShopIndex = 0;
size_t menuIndex = 0, pendingShopIndex = 0;
String selectedShop, selectedTool;
Screen screen = Screen::MAIN;
Layout layout = Layout::COLUMNS;
bool needsRedraw = true;
bool lastWifiConnected = false, lastMqttConnected = false;
uint32_t lastInputAt = 0, lastConnectAttemptAt = 0;

bool addShop(const String &shop) {
  if (shop.isEmpty()) return false;
  for (size_t i = 0; i < shopCount; ++i)
    if (shops[i] == shop) return false;
  if (shopCount >= MAX_SHOPS) return false;
  shops[shopCount++] = shop;
  return true;
}

bool addTool(const String &shop, const String &tool) {
  if (shop.isEmpty() || tool.isEmpty()) return false;
  addShop(shop);
  for (size_t i = 0; i < toolCount; ++i)
    if (tools[i].shop == shop && tools[i].tool == tool) return false;
  if (toolCount >= MAX_TOOLS) return false;
  tools[toolCount++] = {shop, tool};
  return true;
}

void loadConfiguredResources() {
  for (size_t i = 0; i < RESOURCE_COUNT; ++i) {
    String shop(RESOURCES[i].shop), tool(RESOURCES[i].tool ? RESOURCES[i].tool : "");
    addShop(shop);
    addTool(shop, tool);
  }
}

size_t toolsForShop(const String &shop) {
  size_t count = 0;
  for (size_t i = 0; i < toolCount; ++i)
    if (tools[i].shop == shop) ++count;
  return count;
}

String toolForShopAt(const String &shop, size_t index) {
  for (size_t i = 0; i < toolCount; ++i) {
    if (tools[i].shop != shop) continue;
    if (index-- == 0) return tools[i].tool;
  }
  return "";
}

String selectedTopic() {
  String topic = String(MQTT_TOPIC_PREFIX) + "/" + selectedShop;
  if (!selectedTool.isEmpty()) topic += "/" + selectedTool;
  return topic;
}

String selectionLabel() {
  return selectedTool.isEmpty() ? selectedShop : selectedShop + " / " + selectedTool;
}

void drawWrapped(const String &value, int16_t x, int16_t &y, uint8_t chars,
                 uint8_t lines) {
  String rest = value;
  for (uint8_t line = 0; line < lines && !rest.isEmpty(); ++line) {
    size_t take = min(static_cast<size_t>(chars), rest.length());
    if (take < rest.length()) {
      int split = rest.substring(0, take + 1).lastIndexOf(' ');
      if (split > 0) take = split;
    }
    display.setCursor(x, y);
    display.print(rest.substring(0, take));
    rest = rest.substring(take);
    rest.trim();
    y += 11;
  }
}

void drawStatus() {
  display.setTextSize(1);
  display.setCursor(171, 120);
  display.print(WiFi.status() == WL_CONNECTED ? "WiFi+" : "WiFi-");
  display.print(mqttClient.connected() ? " MQTT+" : " MQTT-");
}

void drawEmpty() {
  display.setTextSize(2);
  int16_t y = 45;
  drawWrapped(selectedShop, 8, y, 19, 2);
  if (!selectedTool.isEmpty()) {
    y += 8;
    drawWrapped(selectedTool, 8, y, 19, 2);
  } else {
    display.setTextSize(1);
    display.setCursor(8, y + 8);
    display.print("Entire Shop");
  }
  drawStatus();
}

void drawReservation(const char *heading, const Reservation &reservation,
                     int16_t x, int16_t width) {
  display.setTextSize(1);
  display.setCursor(x, 34);
  display.print(heading);
  display.drawFastHLine(x, 37, width, GxEPD_BLACK);
  int16_t y = 49;
  if (!reservation.present) {
    display.setCursor(x, y);
    display.print("None");
    return;
  }
  drawWrapped(reservation.title, x, y, 18, 2);
  display.setCursor(x, 74);
  display.print(reservation.member.substring(0, 18));
  display.setCursor(x, 91);
  display.print(reservation.start.substring(0, 19));
  display.setCursor(x, 105);
  display.print("to ");
  display.print(reservation.end.substring(0, 16));
}

void drawMain() {
  if (!currentReservation.present && !upNextReservation.present) {
    drawEmpty();
    return;
  }
  if (layout == Layout::UP_NEXT) {
    display.setTextSize(1);
    display.setCursor(5, 32);
    display.print("UP NEXT");
    display.setTextSize(2);
    int16_t y = 53;
    if (upNextReservation.present) {
      drawWrapped(upNextReservation.title, 5, y, 20, 2);
      display.setTextSize(1);
      display.setCursor(5, 91);
      display.print(upNextReservation.member.substring(0, 38));
      display.setCursor(5, 108);
      display.print(upNextReservation.start.substring(0, 38));
    } else {
      display.setCursor(5, y);
      display.print("None scheduled");
    }
    return;
  }
  display.drawFastVLine(124, 25, 96, GxEPD_BLACK);
  drawReservation("CURRENT", currentReservation, 2, 119);
  drawReservation("UP NEXT", upNextReservation, 129, 119);
}

void drawPicker() {
  bool choosingShop = screen == Screen::CHOOSE_SHOP;
  String heading = choosingShop ? "SELECT SHOP" : shops[pendingShopIndex];
  size_t count = choosingShop ? shopCount : toolsForShop(shops[pendingShopIndex]) + 1;
  display.setTextSize(1);
  display.setCursor(3, 29);
  display.print(heading.substring(0, 38));
  display.drawFastHLine(0, 34, 250, GxEPD_BLACK);
  for (int offset = -2; offset <= 2; ++offset) {
    int item = static_cast<int>(menuIndex) + offset;
    if (item < 0 || item >= static_cast<int>(count)) continue;
    int16_t y = 70 + offset * 17;
    display.setCursor(5, y);
    display.print(offset == 0 ? "> " : "  ");
    String label = choosingShop ? shops[item]
                                : (item == 0 ? "Entire Shop"
                                             : toolForShopAt(shops[pendingShopIndex], item - 1));
    display.print(label.substring(0, 36));
  }
}

void paint(bool saved = false) {
  display.setFullWindow();
  display.firstPage();
  do {
    display.fillScreen(GxEPD_WHITE);
    display.setTextColor(GxEPD_BLACK);
    display.setTextSize(1);
    display.setCursor(2, 10);
    display.print(selectionLabel().substring(0, 38));
    display.drawFastHLine(0, 17, 250, GxEPD_BLACK);
    if (saved) {
      display.setTextSize(3);
      display.setCursor(78, 78);
      display.print("SAVED");
    } else if (screen == Screen::MAIN) {
      drawMain();
    } else {
      drawPicker();
    }
  } while (display.nextPage());
  display.hibernate();
  needsRedraw = false;
}

Reservation parseReservation(const byte *payload, unsigned int length) {
  Reservation result;
  JsonDocument document;
  if (deserializeJson(document, payload, length) || document["status"] != "approved")
    return result;
  result.present = true;
  result.id = document["id"] | "";
  result.title = document["title"] | "Untitled";
  result.start = document["start_at_short"] | "";
  result.end = document["end_at_short"] | "";
  result.member = String(document["member"]["first_name"] | "") + " " +
                  String(document["member"]["last_name"] | "");
  result.member.trim();
  return result;
}

bool learnTopic(String topic) {
  String prefix = String(MQTT_TOPIC_PREFIX) + "/";
  if (!topic.startsWith(prefix)) return false;
  topic.remove(0, prefix.length());
  if (topic.endsWith("/UpNext")) topic.remove(topic.length() - 7);
  int slash = topic.indexOf('/');
  if (slash < 0) return addShop(topic);
  String shop = topic.substring(0, slash), tool = topic.substring(slash + 1);
  if (tool.indexOf('/') >= 0) return false;
  return addTool(shop, tool);
}

void mqttMessage(char *topic, byte *payload, unsigned int length) {
  bool learned = learnTopic(topic);
  String incoming(topic), currentTopic = selectedTopic();
  bool isUpNext = incoming == currentTopic + "/UpNext";
  if (isUpNext || incoming == currentTopic) {
    Reservation parsed;
    if (length) parsed = parseReservation(payload, length);
    Reservation &previous = isUpNext ? upNextReservation : currentReservation;
    bool changed = parsed.present != previous.present || parsed.id != previous.id ||
                   parsed.title != previous.title || parsed.member != previous.member ||
                   parsed.start != previous.start || parsed.end != previous.end;
    if (isUpNext)
      upNextReservation = parsed;
    else
      currentReservation = parsed;
    if (changed) needsRedraw = true;
  } else if (learned && screen != Screen::MAIN) {
    needsRedraw = true;
  }
}

void subscribe() {
  if (!mqttClient.connected()) return;
  String wildcard = String(MQTT_TOPIC_PREFIX) + "/#";
  mqttClient.subscribe(wildcard.c_str(), 1);
}

void requestSelectedRetainedMessage() {
  if (!mqttClient.connected()) return;
  String upNextTopic = selectedTopic() + "/UpNext";
  mqttClient.subscribe(upNextTopic.c_str(), 1);
}

void saveSettings() {
  paint();  // Show the selected resource immediately before saving.
  JsonDocument document;
  JsonArray resourceList = document["resources"].to<JsonArray>();
  for (size_t i = 0; i < shopCount; ++i) {
    JsonObject item = resourceList.add<JsonObject>();
    item["shop"] = shops[i];
    item["tool"] = "";
  }
  for (size_t i = 0; i < toolCount; ++i) {
    JsonObject item = resourceList.add<JsonObject>();
    item["shop"] = tools[i].shop;
    item["tool"] = tools[i].tool;
  }
  String encoded;
  serializeJson(document, encoded);
  preferences.putString("shop", selectedShop);
  preferences.putString("tool", selectedTool);
  preferences.putUChar("layout", static_cast<uint8_t>(layout));
  preferences.putString("resources", encoded);
  paint(true);
  delay(2000);
  paint();
}

void restoreSettings() {
  String encoded = preferences.getString("resources", "");
  JsonDocument document;
  if (!deserializeJson(document, encoded)) {
    for (JsonObject item : document["resources"].as<JsonArray>()) {
      addShop(item["shop"] | "");
      addTool(item["shop"] | "", item["tool"] | "");
    }
  }
  selectedShop = preferences.getString("shop", shopCount ? shops[0] : "");
  selectedTool = preferences.getString("tool", "");
  layout = preferences.getUChar("layout", 0) == 1 ? Layout::UP_NEXT : Layout::COLUMNS;
  addShop(selectedShop);
  addTool(selectedShop, selectedTool);
}

bool pressed(uint8_t pin) { return digitalRead(pin) == LOW; }

void selectCurrentMenuItem() {
  if (screen == Screen::CHOOSE_SHOP) {
    if (!shopCount) return;
    pendingShopIndex = menuIndex;
    menuIndex = 0;
    screen = Screen::CHOOSE_TOOL;
  } else {
    selectedShop = shops[pendingShopIndex];
    selectedTool = menuIndex == 0 ? "" : toolForShopAt(selectedShop, menuIndex - 1);
    currentReservation = Reservation{};
    upNextReservation = Reservation{};
    screen = Screen::MAIN;
    requestSelectedRetainedMessage();
  }
  needsRedraw = true;
}

void handleButtons() {
  if (millis() - lastInputAt < DEBOUNCE_MS) return;
  int direction = pressed(DIAL_RIGHT) ? 1 : (pressed(DIAL_LEFT) ? -1 : 0);
  if (direction && screen != Screen::MAIN) {
    size_t count = screen == Screen::CHOOSE_SHOP
                       ? shopCount
                       : toolsForShop(shops[pendingShopIndex]) + 1;
    if (count) menuIndex = (menuIndex + count + direction) % count;
    needsRedraw = true;
  } else if (pressed(DIAL_PRESS)) {
    if (screen == Screen::MAIN) {
      screen = Screen::CHOOSE_SHOP;
      menuIndex = 0;
    } else {
      selectCurrentMenuItem();
    }
    needsRedraw = true;
  } else if (pressed(MENU_BUTTON)) {
    if (screen == Screen::MAIN)
      layout = layout == Layout::COLUMNS ? Layout::UP_NEXT : Layout::COLUMNS;
    else
      screen = Screen::MAIN;
    needsRedraw = true;
  } else if (pressed(EXIT_BUTTON)) {
    saveSettings();
    while (pressed(EXIT_BUTTON)) delay(10);
  } else {
    return;
  }
  lastInputAt = millis();
}

void connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  uint32_t startedAt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startedAt < 20000) delay(100);
}

void connectMqtt() {
  if (WiFi.status() != WL_CONNECTED || mqttClient.connected() ||
      millis() - lastConnectAttemptAt < RECONNECT_MS) return;
  lastConnectAttemptAt = millis();
  String clientId = String("upnext-") + WiFi.macAddress();
  bool connected = MQTT_USERNAME[0] == '\0'
                       ? mqttClient.connect(clientId.c_str())
                       : mqttClient.connect(clientId.c_str(), MQTT_USERNAME, MQTT_PASSWORD);
  if (connected) subscribe();
}

void trackConnections() {
  bool wifi = WiFi.status() == WL_CONNECTED, mqtt = mqttClient.connected();
  if (wifi != lastWifiConnected || mqtt != lastMqttConnected) {
    lastWifiConnected = wifi;
    lastMqttConnected = mqtt;
    needsRedraw = true;
  }
}
}  // namespace

void setup() {
  Serial.begin(115200);
  static_assert(RESOURCE_COUNT > 0, "Configure at least one resource");
  for (uint8_t pin : {DIAL_LEFT, DIAL_RIGHT, DIAL_PRESS, MENU_BUTTON, EXIT_BUTTON})
    pinMode(pin, INPUT_PULLUP);
  SPI.begin(EPD_SCK, -1, EPD_MOSI, EPD_CS);
  display.init(115200, true, 2, false);
  display.setRotation(UPNEXT_FLIP_180 ? 3 : 1);
  preferences.begin("upnext", false);
  loadConfiguredResources();
  restoreSettings();
  mqttClient.setServer(MQTT_HOST, MQTT_PORT);
  mqttClient.setCallback(mqttMessage);
  mqttClient.setBufferSize(2048);
  connectWifi();
  lastConnectAttemptAt = millis() - RECONNECT_MS;
  connectMqtt();
  trackConnections();
  paint();
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) connectWifi();
  connectMqtt();
  mqttClient.loop();
  trackConnections();
  handleButtons();
  if (needsRedraw) paint();
  delay(10);
}
