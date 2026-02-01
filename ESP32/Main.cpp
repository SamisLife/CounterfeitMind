#include <Arduino.h>
#include <SPI.h>
#include <Adafruit_PN532.h>
#include <ArduinoJson.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <NimBLEDevice.h>


#include <Ed25519.h>
#include <mbedtls/base64.h>


#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890ab"
#define CHARACTERISTIC_UUID "abcdefab-1234-5678-1234-abcdefabcdef"


static const char* TREASURY_PUBKEY_B64 =
  "O2onvM62pC1io6jQKm8Nc2UyFXcd4kOmOsBIoYtZ2ik=";


#define TFT_SCK   18
#define TFT_MOSI  23
#define TFT_MISO  19  


#define TFT_CS   5
#define TFT_DC   22
#define TFT_RST  4
Adafruit_ST7789 tft(TFT_CS, TFT_DC, TFT_RST);


#define PN532_SCK   15
#define PN532_MOSI  19
#define PN532_MISO  2
#define PN532_SS    21

SPIClass PN532_SPI(HSPI);
Adafruit_PN532 nfc(PN532_SS, &PN532_SPI);


enum AppState {
  WAIT_FOR_APP,
  HAVE_APP_DATA_WAIT_NFC,
  SHOW_RESULT
};
AppState appState = WAIT_FOR_APP;


enum NfcHealth { NFC_DOWN, NFC_UP, NFC_SCANNING };
NfcHealth nfcHealth = NFC_DOWN;


String expSerial = "";
String expCurrency = "";
int expDenom = 0;
bool hasExpected = false;


unsigned long lastHealthMs = 0;
const unsigned long HEALTH_INTERVAL_MS = 500;

unsigned long lastStatusMs = 0;
const unsigned long STATUS_INTERVAL_MS = 250;


int lastScreenId = -1;


volatile bool bleHasNewPayload = false;
String blePayload = "";


unsigned long lastPnOkMs = 0;             
int pnFailStreak = 0;                      
const unsigned long PN_GRACE_MS = 1500;    


static bool b64decode(const char* b64, uint8_t* out, size_t outMax, size_t* outLen) {
  size_t olen = 0;
  int rc = mbedtls_base64_decode(
    out, outMax, &olen,
    (const unsigned char*)b64, strlen(b64)
  );
  if (rc != 0) return false;
  if (outLen) *outLen = olen;
  return true;
}


static String canonicalMessage(const String& serial, const String& currency, int value) {
  return "serial=" + serial + "|currency=" + currency + "|value=" + String(value);
}


static bool verifyTreasurySignature(
  const String& serial,
  const String& currency,
  int value,
  const String& sigB64
) {
  
  uint8_t pubkey[32];
  size_t pkLen = 0;
  if (!b64decode(TREASURY_PUBKEY_B64, pubkey, sizeof(pubkey), &pkLen) || pkLen != 32) {
    Serial.println("❌ Public key decode failed (need 32 bytes).");
    return false;
  }

  
  uint8_t sig[64];
  size_t sigLen = 0;
  if (!b64decode(sigB64.c_str(), sig, sizeof(sig), &sigLen) || sigLen != 64) {
    Serial.println("❌ Signature decode failed (need 64 bytes).");
    return false;
  }

  
  String msgStr = canonicalMessage(serial, currency, value);
  const uint8_t* msg = (const uint8_t*)msgStr.c_str();
  size_t msgLen = msgStr.length();

  bool ok = Ed25519::verify(sig, pubkey, msg, msgLen);
  return ok;
}


void deselectAll() {
  pinMode(TFT_CS, OUTPUT);
  pinMode(PN532_SS, OUTPUT);
  digitalWrite(TFT_CS, HIGH);
  digitalWrite(PN532_SS, HIGH);
}

inline void selectTFT() {
  digitalWrite(PN532_SS, HIGH);
}

inline void selectPN532() {
  digitalWrite(TFT_CS, HIGH);
}


void drawStatusBar(const char* msg) {
  selectTFT();
  tft.fillRect(0, 0, 240, 24, ST77XX_BLACK);

  uint16_t dot = ST77XX_RED;
  if (nfcHealth == NFC_UP) dot = ST77XX_GREEN;
  if (nfcHealth == NFC_SCANNING) dot = ST77XX_YELLOW;

  tft.fillCircle(10, 12, 6, dot);

  tft.setTextSize(1);
  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(24, 8);
  tft.print(msg);
}

void screenWaitForApp() {
  if (lastScreenId == 0) return;
  lastScreenId = 0;

  selectTFT();
  tft.fillScreen(ST77XX_BLACK);

  tft.setTextColor(ST77XX_CYAN);
  tft.setTextSize(3);
  tft.setCursor(12, 40);
  tft.println("Counterfeit");
  tft.setCursor(12, 78);
  tft.println("Mind");

  tft.setTextSize(2);
  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(12, 150);
  tft.println("Please capture");
  tft.setCursor(12, 175);
  tft.println("note with app");
}

void screenNfcDisconnected() {
  if (lastScreenId == 1) return;
  lastScreenId = 1;

  selectTFT();
  tft.fillScreen(ST77XX_BLACK);
  tft.setTextColor(ST77XX_RED);
  tft.setTextSize(2);
  tft.setCursor(12, 60);
  tft.println("NFC DISCONNECTED");

  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(12, 100);
  tft.println("Check wiring/pins");
  tft.setCursor(12, 125);
  tft.println("Auto-recovering");
}

void screenReadyToScanNfc() {
  if (lastScreenId == 2) return;
  lastScreenId = 2;

  selectTFT();
  tft.fillScreen(ST77XX_BLACK);

  tft.setTextColor(ST77XX_CYAN);
  tft.setTextSize(2);
  tft.setCursor(12, 24);
  tft.println("Got app data");

  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(12, 55);
  tft.println("Please scan the");
  tft.setCursor(12, 78);
  tft.println("banknote on NFC");

  tft.setTextSize(2);
  tft.setCursor(12, 120);
  tft.setTextColor(ST77XX_WHITE);
  tft.print("Serial: ");
  tft.setTextColor(ST77XX_GREEN);
  tft.println(expSerial);

  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(12, 150);
  tft.print("Curr: ");
  tft.setTextColor(ST77XX_YELLOW);
  tft.println(expCurrency);

  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(12, 180);
  tft.print("Value: ");
  tft.setTextColor(ST77XX_YELLOW);
  tft.println(expDenom);
}

void screenInfo(const char* line1, const char* line2) {
  lastScreenId = 9;
  selectTFT();
  tft.fillScreen(ST77XX_BLACK);

  tft.setTextColor(ST77XX_ORANGE);
  tft.setTextSize(2);
  tft.setCursor(12, 70);
  tft.println(line1);

  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(12, 105);
  tft.println(line2);

  tft.setCursor(12, 220);
  tft.println("Try again");
}

void screenResult(bool ok, const char* reason) {
  lastScreenId = 3;

  selectTFT();
  tft.fillScreen(ST77XX_BLACK);

  tft.setTextSize(3);
  tft.setCursor(18, 70);

  if (ok) {
    tft.setTextColor(ST77XX_GREEN);
    tft.println("VERIFIED");
    tft.setTextSize(2);
    tft.setTextColor(ST77XX_WHITE);
    tft.setCursor(18, 130);
    tft.println("Signature OK");
    tft.setCursor(18, 155);
    tft.println("Matches app");
  } else {
    tft.setTextColor(ST77XX_RED);
    tft.println("ALERT");
    tft.setTextSize(2);
    tft.setTextColor(ST77XX_WHITE);
    tft.setCursor(18, 130);
    tft.println(reason);
  }

  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(18, 220);
  tft.println("Scan another");
}


bool pn532FirmwareOk() {
  selectPN532();
  uint32_t v = nfc.getFirmwareVersion();
  if (v != 0) {
    lastPnOkMs = millis();
    pnFailStreak = 0;
    return true;
  }
  pnFailStreak++;
  return false;
}

bool pn532TryInit() {
  deselectAll();
  selectPN532();

  PN532_SPI.begin(PN532_SCK, PN532_MISO, PN532_MOSI, PN532_SS);
  PN532_SPI.setFrequency(1000000);

  nfc.begin();
  delay(25);

  if (!pn532FirmwareOk()) return false;

  nfc.SAMConfig();
  delay(10);
  lastPnOkMs = millis();
  pnFailStreak = 0;
  return true;
}

bool readPageWithRetry(uint8_t page, uint8_t *data, int retries = 10) {
  for (int i = 0; i < retries; i++) {
    selectPN532();
    if (nfc.ntag2xx_ReadPage(page, data)) {
      lastPnOkMs = millis();
      pnFailStreak = 0;
      return true;
    }
    delay(10);
  }
  pnFailStreak++;
  return false;
}


String extractJsonFromPages(const uint8_t *buf, int len) {
  int start = -1;
  int end = -1;

  for (int i = 0; i < len; i++) {
    if (buf[i] == '{') { start = i; break; }
  }
  if (start < 0) return "";

  for (int i = start; i < len; i++) {
    if (buf[i] == '}') end = i;
  }
  if (end < 0 || end <= start) return "";

  String out;
  out.reserve(end - start + 1);
  for (int i = start; i <= end; i++) {
    char c = (char)buf[i];
    if (c == 0) continue;
    out += c;
  }
  out.trim();
  return out;
}


bool verifyMatch(const String& serial, int value, const String& currency, const char** reason) {
  if (!hasExpected) { *reason = "No app data"; return false; }
  if (serial != expSerial) { *reason = "Serial mismatch"; return false; }
  if (currency != expCurrency) { *reason = "Currency mismatch"; return false; }
  if (value != expDenom) { *reason = "Value mismatch"; return false; }
  *reason = "OK";
  return true;
}


class RxCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& connInfo) override {
    (void)connInfo;
    std::string raw = c->getValue();
    String s;
    s.reserve(raw.size() + 1);
    for (size_t i = 0; i < raw.size(); i++) s += (char)raw[i];
    s.trim();
    blePayload = s;
    bleHasNewPayload = true;
  }
};

void setupBle() {
  NimBLEDevice::init("CounterEye");
  NimBLEDevice::setPower(ESP_PWR_LVL_P3);

  NimBLEServer* server = NimBLEDevice::createServer();
  NimBLEService* svc = server->createService(SERVICE_UUID);

  NimBLECharacteristic* ch = svc->createCharacteristic(
    CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );

  ch->setCallbacks(new RxCallbacks());
  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setMinInterval(0x80);
  adv->setMaxInterval(0x100);
  adv->start();

  Serial.println("BLE ready. Waiting for iPhone...");
}


void updateHealthAndUi() {
  unsigned long now = millis();

  if (now - lastHealthMs >= HEALTH_INTERVAL_MS) {
    lastHealthMs = now;

    if (nfcHealth != NFC_SCANNING) {
      bool ok = pn532FirmwareOk();
      if (!ok) pn532TryInit();

      bool recentlyOk = (now - lastPnOkMs) <= PN_GRACE_MS;
      if (recentlyOk) nfcHealth = NFC_UP;
      else nfcHealth = (pnFailStreak >= 3) ? NFC_DOWN : NFC_UP;

      if (nfcHealth == NFC_DOWN && appState == HAVE_APP_DATA_WAIT_NFC) {
        lastScreenId = -1;
        screenNfcDisconnected();
      }
    }
  }

  if (now - lastStatusMs >= STATUS_INTERVAL_MS) {
    lastStatusMs = now;

    const char* appMsg =
      (appState == WAIT_FOR_APP) ? "APP: capture" :
      (appState == HAVE_APP_DATA_WAIT_NFC) ? "APP: data OK" :
                                             "APP: result";

    const char* nfcMsg =
      (nfcHealth == NFC_DOWN) ? "NFC: disc" :
      (nfcHealth == NFC_SCANNING) ? "NFC: scan" :
                                    "NFC: ready";

    static char msg[64];
    snprintf(msg, sizeof(msg), "%s | %s", appMsg, nfcMsg);
    drawStatusBar(msg);
  }
}


void processBleIfAny() {
  if (!bleHasNewPayload) return;
  bleHasNewPayload = false;

  Serial.println("=== BLE RECEIVED ===");
  Serial.println(blePayload);
  Serial.println("====================");

  StaticJsonDocument<256> doc;
  DeserializationError err = deserializeJson(doc, blePayload);
  if (err) {
    Serial.print("BLE JSON error: ");
    Serial.println(err.c_str());
    return;
  }

  String type = String((const char*)(doc["type"] | "scan"));
  if (type != "scan") {
    Serial.println("BLE: ignoring non-scan payload");
    return;
  }

  expSerial   = String((const char*)(doc["serial"] | ""));
  expCurrency = String((const char*)(doc["currency"] | ""));
  expCurrency.trim();
  expCurrency.toUpperCase();
  expDenom    = (int)(doc["denomination"] | 0);

  hasExpected = expSerial.length() && expCurrency.length() && expDenom > 0;
  if (!hasExpected) {
    Serial.println("BLE missing fields");
    return;
  }

  appState = HAVE_APP_DATA_WAIT_NFC;
  lastScreenId = -1;

  if (nfcHealth == NFC_UP) screenReadyToScanNfc();
  else screenNfcDisconnected();
}


bool tryScanNfcOnce() {
  if (nfcHealth == NFC_DOWN) return false;

  uint8_t uid[7], uidLength;
  selectPN532();

  if (!nfc.readPassiveTargetID(PN532_MIFARE_ISO14443A, uid, &uidLength)) {
    return false;
  }

  lastPnOkMs = millis();
  pnFailStreak = 0;

  nfcHealth = NFC_SCANNING;
  drawStatusBar("APP: data OK | NFC: scanning...");
  delay(90);

  const uint8_t firstPage = 4;
  const uint8_t lastPage  = 80; 
  const int bufLen = (lastPage - firstPage + 1) * 4;

  uint8_t buf[bufLen];
  uint8_t pageData[4];
  int idx = 0;

  for (uint8_t page = firstPage; page <= lastPage; page++) {
    if (!readPageWithRetry(page, pageData)) {
      nfcHealth = NFC_UP;
      screenInfo("NFC read failed", "Try tag again");
      delay(900);
      lastScreenId = -1;
      screenReadyToScanNfc();
      return true;
    }
    for (int i = 0; i < 4; i++) buf[idx++] = pageData[i];
  }

  String text = extractJsonFromPages(buf, bufLen);
  if (text.length() == 0) {
    nfcHealth = NFC_UP;
    screenInfo("No JSON found", "Check NDEF write");
    delay(900);
    lastScreenId = -1;
    screenReadyToScanNfc();
    return true;
  }

  Serial.println("=== NFC JSON (extracted) ===");
  Serial.println(text);
  Serial.println("============================");

  StaticJsonDocument<1536> doc; 
  DeserializationError jerr = deserializeJson(doc, text);
  if (jerr) {
    nfcHealth = NFC_UP;
    screenInfo("Bad JSON", jerr.c_str());
    delay(1100);
    lastScreenId = -1;
    screenReadyToScanNfc();
    return true;
  }

  String nfcSerial   = String((const char*)(doc["serial"] | ""));
  String nfcCurrency = String((const char*)(doc["currency"] | ""));
  int nfcValue       = (int)(doc["value"] | 0);
  String sigB64      = String((const char*)(doc["sig"] | ""));

  nfcSerial.trim();
  nfcCurrency.trim();
  nfcCurrency.toUpperCase();
  sigB64.trim();

  if (sigB64.length() == 0) {
    appState = SHOW_RESULT;
    nfcHealth = NFC_UP;
    screenResult(false, "Missing sig");
    drawStatusBar("RESULT: ALERT");
    goto done_wait_remove;
  }

  
  {
    String msg = canonicalMessage(nfcSerial, nfcCurrency, nfcValue);
    Serial.print("Canonical message: ");
    Serial.println(msg);

    bool sigOk = verifyTreasurySignature(nfcSerial, nfcCurrency, nfcValue, sigB64);
    Serial.println(sigOk ? "✅ SIGNATURE VALID" : "❌ SIGNATURE INVALID");

    if (!sigOk) {
      appState = SHOW_RESULT;
      nfcHealth = NFC_UP;
      screenResult(false, "INVALID SIG");
      drawStatusBar("RESULT: ALERT");
      goto done_wait_remove;
    }
  }

  
  {
    const char* reason = "OK";
    bool matchOk = verifyMatch(nfcSerial, nfcValue, nfcCurrency, &reason);

    appState = SHOW_RESULT;
    nfcHealth = NFC_UP;

    if (matchOk) {
      screenResult(true, "OK");
      drawStatusBar("RESULT: VERIFIED");
    } else {
      screenResult(false, reason); 
      drawStatusBar("RESULT: MISMATCH");
    }
  }

done_wait_remove:
  
  unsigned long start = millis();
  while (millis() - start < 2500) {
    uint8_t tmpUid[7], tmpLen;
    selectPN532();
    bool stillThere = nfc.readPassiveTargetID(PN532_MIFARE_ISO14443A, tmpUid, &tmpLen);
    if (!stillThere) break;
    delay(40);
  }

  
  hasExpected = false;
  expSerial = ""; expCurrency = ""; expDenom = 0;
  appState = WAIT_FOR_APP;
  lastScreenId = -1;
  screenWaitForApp();
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(200);

  
  SPI.begin(TFT_SCK, TFT_MISO, TFT_MOSI);

  deselectAll();

  selectTFT();
  tft.init(240, 320);
  tft.setRotation(1);

  setupBle();

  
  bool ok = pn532TryInit();
  nfcHealth = ok ? NFC_UP : NFC_DOWN;

  appState = WAIT_FOR_APP;
  lastScreenId = -1;
  screenWaitForApp();

  if (!ok) {
    Serial.println("PN532 init failed (will auto-recover).");
  }
}

void loop() {
  processBleIfAny();
  updateHealthAndUi();

  if (appState == HAVE_APP_DATA_WAIT_NFC && nfcHealth != NFC_DOWN) {
    (void)tryScanNfcOnce();
    delay(20);
    return;
  }

  delay(10);
}
