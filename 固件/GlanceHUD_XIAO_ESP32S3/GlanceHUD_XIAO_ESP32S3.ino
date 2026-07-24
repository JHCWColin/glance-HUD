#include <Arduino.h>
#include <Wire.h>

#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ArduinoJson.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

namespace {

constexpr char kDeviceName[] = "GlanceHUD";

constexpr char kServiceUuid[] = "B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C001";
constexpr char kWriteCharacteristicUuid[] = "B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C002";
constexpr char kNotifyCharacteristicUuid[] = "B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C003";

constexpr uint8_t kOledWidth = 64;
constexpr uint8_t kOledHeight = 32;
constexpr int8_t kOledResetPin = -1;
constexpr uint8_t kOledSdaPin = 5;  // XIAO D4
constexpr uint8_t kOledSclPin = 6;  // XIAO D5

constexpr size_t kCharsPerLine = 10;
constexpr uint8_t kDisplayLineHeight = 8;
constexpr uint8_t kDisplayLineCount = 4;
constexpr size_t kMaxRxBufferLength = 1024;
constexpr uint16_t kJsonCapacity = 512;
constexpr unsigned long kTransientDisplayMs = 3000UL;

Adafruit_SSD1306 gDisplay(kOledWidth, kOledHeight, &Wire, kOledResetPin);

BLEServer* gBleServer = nullptr;
BLECharacteristic* gWriteCharacteristic = nullptr;
BLECharacteristic* gNotifyCharacteristic = nullptr;

bool gDisplayReady = false;
bool gBleConnected = false;
bool gRestartAdvertisingRequested = false;
bool gLastTransientVisible = false;
uint8_t gDisplayAddress = 0x3C;

String gIncomingBuffer;

String gClockText = "--:--";
String gDateText = "---- -- --";
String gWeatherText = "--";
String gBatteryText = "--%";
String gMessageText = "Waiting...";

String gTransientTitle;
String gTransientBody;
unsigned long gTransientUntilMs = 0;

void logLine(const String& message) {
  Serial.println(message);
}

String trimForDisplay(const String& text, size_t maxChars) {
  if (text.length() <= maxChars) {
    return text;
  }

  if (maxChars <= 3) {
    return text.substring(0, maxChars);
  }

  return text.substring(0, maxChars - 3) + "...";
}

String centeredText(const String& text) {
  String trimmed = trimForDisplay(text, kCharsPerLine);
  if (trimmed.length() >= kCharsPerLine) {
    return trimmed;
  }

  const size_t padding = (kCharsPerLine - trimmed.length()) / 2;
  String result;
  result.reserve(kCharsPerLine);
  for (size_t i = 0; i < padding; ++i) {
    result += ' ';
  }
  result += trimmed;
  return result;
}

void drawLine(uint8_t lineIndex, const String& text, bool centered = false) {
  if (!gDisplayReady || lineIndex >= kDisplayLineCount) {
    return;
  }

  String finalText = centered ? centeredText(text) : trimForDisplay(text, kCharsPerLine);
  int16_t x = 0;
  if (centered) {
    x = (kOledWidth - static_cast<int16_t>(finalText.length() * 6)) / 2;
    if (x < 0) {
      x = 0;
    }
  }
  const int16_t y = lineIndex * kDisplayLineHeight;
  gDisplay.setCursor(x, y);
  gDisplay.print(finalText);
}

void drawWrappedText(uint8_t startLine, const String& text, uint8_t maxLines) {
  for (uint8_t i = 0; i < maxLines; ++i) {
    const size_t start = i * kCharsPerLine;
    if (start >= text.length()) {
      break;
    }

    String chunk = text.substring(start, start + kCharsPerLine);
    if (i == maxLines - 1) {
      chunk = trimForDisplay(text.substring(start), kCharsPerLine);
    }

    drawLine(startLine + i, chunk, false);
  }
}

bool transientVisible() {
  return static_cast<long>(gTransientUntilMs - millis()) > 0;
}

void renderDisplay() {
  if (!gDisplayReady) {
    return;
  }

  gDisplay.clearDisplay();
  gDisplay.setTextSize(1);
  gDisplay.setTextColor(SSD1306_WHITE);
  gDisplay.setTextWrap(false);

  if (transientVisible()) {
    drawLine(0, gTransientTitle, true);
    drawWrappedText(1, gTransientBody, 3);
  } else if (!gBleConnected) {
    drawLine(0, "GlanceHUD", true);
    drawLine(2, "Waiting...", true);
  } else {
    drawLine(0, gClockText, true);
    drawLine(1, gDateText, false);
    drawLine(2, "W:" + gWeatherText + " B:" + gBatteryText, false);
    drawLine(3, gMessageText.length() > 0 ? gMessageText : "Connected", false);
  }

  gDisplay.display();
}

void showTransient(const String& title, const String& body) {
  gTransientTitle = trimForDisplay(title, kCharsPerLine);
  gTransientBody = body;
  gTransientUntilMs = millis() + kTransientDisplayMs;
  renderDisplay();
}

void sendNotify(const String& payload) {
  if (!gBleConnected || gNotifyCharacteristic == nullptr) {
    return;
  }

  gNotifyCharacteristic->setValue(reinterpret_cast<const uint8_t*>(payload.c_str()), payload.length());
  gNotifyCharacteristic->notify();
}

void sendNotifyEvent(const String& eventName, const String& detailKey, const String& detailValue) {
  StaticJsonDocument<192> doc;
  doc["event"] = eventName;
  if (detailKey.length() > 0) {
    doc[detailKey] = detailValue;
  }

  String payload;
  serializeJson(doc, payload);
  payload += '\n';
  sendNotify(payload);
}

String packetTitleForType(const String& type) {
  if (type == "clock") {
    return "CLOCK";
  }
  if (type == "date") {
    return "DATE";
  }
  if (type == "weather") {
    return "WEATHER";
  }
  if (type == "battery") {
    return "BATTERY";
  }
  if (type == "message") {
    return "MESSAGE";
  }
  return "PAYLOAD";
}

void applyPayload(const String& type, const String& text) {
  if (type == "clock") {
    gClockText = text;
  } else if (type == "date") {
    gDateText = text;
  } else if (type == "weather") {
    gWeatherText = text;
  } else if (type == "battery") {
    gBatteryText = text;
  } else if (type == "message") {
    gMessageText = text;
  }
}

void processJsonLine(const String& jsonLine) {
  logLine("Received JSON: " + jsonLine);

  StaticJsonDocument<kJsonCapacity> doc;
  DeserializationError error = deserializeJson(doc, jsonLine);
  if (error) {
    logLine("JSON parse failed: " + String(error.c_str()));
    showTransient("JSON ERROR", trimForDisplay(String(error.c_str()), kCharsPerLine * 3));
    sendNotifyEvent("json_error", "reason", error.c_str());
    return;
  }

  if (!doc["type"].is<const char*>() || !doc["text"].is<const char*>()) {
    logLine("JSON parse failed: missing type or text");
    showTransient("JSON ERROR", "Need type/text");
    sendNotifyEvent("json_error", "reason", "missing_type_or_text");
    return;
  }

  const String type = doc["type"].as<const char*>();
  const String text = doc["text"].as<const char*>();

  if (type != "clock" && type != "date" && type != "weather" && type != "battery" && type != "message") {
    logLine("JSON parse failed: unsupported type " + type);
    showTransient("JSON ERROR", "Bad type: " + trimForDisplay(type, 6));
    sendNotifyEvent("json_error", "reason", "unsupported_type");
    return;
  }

  applyPayload(type, text);

  logLine("JSON parsed successfully: type=" + type + ", text=" + text);
  showTransient(packetTitleForType(type), text);
  sendNotifyEvent("json_ok", "type", type);
}

void consumeIncomingBytes(const uint8_t* data, size_t length) {
  for (size_t i = 0; i < length; ++i) {
    const char ch = static_cast<char>(data[i]);

    if (ch == '\r') {
      continue;
    }

    if (ch == '\n') {
      String line = gIncomingBuffer;
      gIncomingBuffer = "";
      line.trim();
      if (line.length() > 0) {
        processJsonLine(line);
      }
      continue;
    }

    if (gIncomingBuffer.length() >= kMaxRxBufferLength) {
      logLine("RX buffer overflow, clearing pending data");
      gIncomingBuffer = "";
      showTransient("RX ERROR", "Buffer reset");
      sendNotifyEvent("json_error", "reason", "rx_buffer_overflow");
      continue;
    }

    gIncomingBuffer += ch;
  }
}

bool i2cAddressResponds(uint8_t address) {
  Wire.beginTransmission(address);
  return Wire.endTransmission() == 0;
}

uint8_t detectDisplayAddress() {
  if (i2cAddressResponds(0x3C)) {
    return 0x3C;
  }
  if (i2cAddressResponds(0x3D)) {
    return 0x3D;
  }
  return 0x3C;
}

void initializeDisplay() {
  Wire.begin(kOledSdaPin, kOledSclPin);
  Wire.setClock(400000);

  gDisplayAddress = detectDisplayAddress();
  if (!gDisplay.begin(SSD1306_SWITCHCAPVCC, gDisplayAddress)) {
    logLine("OLED init failed");
    gDisplayReady = false;
    return;
  }

  gDisplayReady = true;
  logLine("OLED init OK at I2C address 0x" + String(gDisplayAddress, HEX));
  renderDisplay();
}

void startAdvertising() {
  BLEDevice::startAdvertising();
  logLine("BLE advertising started");
}

class GlanceHudServerCallbacks final : public BLEServerCallbacks {
 public:
  void onConnect(BLEServer* server) override {
    (void)server;
    gBleConnected = true;
    gRestartAdvertisingRequested = false;
    logLine("BLE connected");
    showTransient("BLE", "Connected");
    renderDisplay();
  }

  void onDisconnect(BLEServer* server) override {
    (void)server;
    gBleConnected = false;
    gRestartAdvertisingRequested = true;
    gIncomingBuffer = "";
    logLine("BLE disconnected");
    showTransient("BLE", "Disconnected");
    renderDisplay();
  }
};

class GlanceHudWriteCallbacks final : public BLECharacteristicCallbacks {
 public:
  void onWrite(BLECharacteristic* characteristic) override {
    if (characteristic == nullptr) {
      return;
    }

    const String value = characteristic->getValue();
    if (value.length() == 0) {
      return;
    }

    consumeIncomingBytes(reinterpret_cast<const uint8_t*>(value.c_str()), value.length());
  }
};

void initializeBle() {
  BLEDevice::init(kDeviceName);

  gBleServer = BLEDevice::createServer();
  gBleServer->setCallbacks(new GlanceHudServerCallbacks());

  BLEService* service = gBleServer->createService(kServiceUuid);

  gWriteCharacteristic = service->createCharacteristic(
      kWriteCharacteristicUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  gWriteCharacteristic->setCallbacks(new GlanceHudWriteCallbacks());

  gNotifyCharacteristic = service->createCharacteristic(
      kNotifyCharacteristicUuid,
      BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ);
  gNotifyCharacteristic->addDescriptor(new BLE2902());
  gNotifyCharacteristic->setValue("Waiting...\n");

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMinPreferred(0x12);

  startAdvertising();
}

}  // namespace

void setup() {
  Serial.begin(115200);
  unsigned long serialWaitStart = millis();
  while (!Serial && (millis() - serialWaitStart) < 3000UL) {
    delay(10);
  }

  logLine("");
  logLine("GlanceHUD firmware boot");
  logLine("Board: Seeed Studio XIAO ESP32-S3");
  logLine("OLED wiring: SDA=GPIO5(D4), SCL=GPIO6(D5)");

  initializeDisplay();
  showTransient("GlanceHUD", "Waiting...");
  initializeBle();
}

void loop() {
  if (gRestartAdvertisingRequested) {
    delay(150);
    startAdvertising();
    gRestartAdvertisingRequested = false;
  }

  const bool transientNow = transientVisible();
  if (gLastTransientVisible && !transientNow) {
    renderDisplay();
  }
  gLastTransientVisible = transientNow;

  delay(10);
}
