#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <time.h>

// ================================================================
// PENGATURAN WIFI & IDENTITAS PASIEN
// ================================================================
const char* WIFI_SSID = "NAMA_WIFI_KAMU";
const char* WIFI_PASSWORD = "PASSWORD_WIFI";
#define DEVICE_ID "ESP32-ECG-PRO"
const char* NAMA_PASIEN = "Sugiono";

// ================================================================
// KREDENSIAL AWS IOT CORE
// ================================================================
const char* AWS_IOT_ENDPOINT = "xxxxxxxxxxxxxx-ats.iot.us-east-1.amazonaws.com";
#define MQTT_TOPIC "ecg/device/" DEVICE_ID "/data"

// --- PASTE 3 SERTIFIKAT AWS DI BAWAH INI ---
static const char AWS_CERT_CA[] PROGMEM = R"EOF(
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
)EOF";

static const char AWS_CERT_CRT[] PROGMEM = R"EOF(
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
)EOF";

static const char AWS_CERT_PRIVATE[] PROGMEM = R"EOF(
-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----
)EOF";

// ================================================================
// KONFIGURASI HARDWARE AD8232 
// ================================================================
#define ECG_PIN 36       // Pin Analog (ADC)
#define LO_PLUS_PIN 32   // Digital LO+
#define LO_MINUS_PIN 33  // Digital LO-

const int SAMPLE_RATE_HZ = 250; 
const unsigned long SAMPLE_INTERVAL_US = 1000000 / SAMPLE_RATE_HZ; // 4000 mikrosekon
const int TOTAL_SAMPLES = 1250; 

int ecgBuffer[TOTAL_SAMPLES];
int sampleIndex = 0;
unsigned long lastSampleTime = 0;
unsigned long lastLeadOffWarn = 0;
bool statusLeadOffSudahTerkirim = false;

WiFiClientSecure net;
PubSubClient client(net);

void connectWiFi() {
  Serial.print("Menghubungkan ke WiFi");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }
  Serial.println("\nWiFi Sukses Terhubung!");
}

void syncTime() {
  configTime(7 * 3600, 0, "pool.ntp.org", "time.nist.gov"); 
  time_t now = time(nullptr);
  while (now < 8 * 3600 * 2) { delay(500); now = time(nullptr); }
}

void connectAWS() {
  net.setCACert(AWS_CERT_CA);
  net.setCertificate(AWS_CERT_CRT);
  net.setPrivateKey(AWS_CERT_PRIVATE);
  client.setServer(AWS_IOT_ENDPOINT, 8883);
  
  // Buffer diperbesar menjadi 16KB untuk menampung JSON array berukuran besar
  client.setBufferSize(16384);

  while (!client.connected()) {
    if (client.connect(DEVICE_ID)) {
      Serial.println("SUKSES! Terhubung penuh ke AWS IoT Core.");
    } else { delay(2000); }
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(ECG_PIN, INPUT);
  pinMode(LO_PLUS_PIN, INPUT);
  pinMode(LO_MINUS_PIN, INPUT);

  connectWiFi();
  syncTime();
  connectAWS();
}

void loop() {
  if (!client.connected()) connectAWS();
  client.loop(); 

  // Deteksi Lead-Off 
  bool isLeadOff = (digitalRead(LO_PLUS_PIN) == 1 || digitalRead(LO_MINUS_PIN) == 1);

  if (isLeadOff) {
    // Hanya eksekusi publish MQTT jika alarm belum pernah dikirim
    if (!statusLeadOffSudahTerkirim) {
      Serial.println("[DARURAT] Elektroda lepas dari pasien!");
      JsonDocument doc;
      doc["device_id"] = DEVICE_ID;
      doc["nama_pasien"] = NAMA_PASIEN;
      doc["lead_off"] = true;
      doc["payload"].to<JsonArray>(); 
      
      String outputJson;
      serializeJson(doc, outputJson);
      client.publish(MQTT_TOPIC, outputJson.c_str());
      
      // Kunci bendera agar tidak mengirim pesan spam di siklus berikutnya
      statusLeadOffSudahTerkirim = true; 
    }
    // Jeda singkat untuk stabilitas, tidak perlu 2000ms karena sudah ada bendera
    delay(100); 
    sampleIndex = 0; // Reset buffer karena sinyal sedang tidak valid
    return;
  } else {
    // Jika sensor sudah terpasang kembali dengan benar, buka kunci benderanya
    statusLeadOffSudahTerkirim = false;
  }

  // Akuisisi Sinyal Non-blocking
  unsigned long currentMicros = micros();
  if (currentMicros - lastSampleTime >= SAMPLE_INTERVAL_US) {
    lastSampleTime = currentMicros;
    
    ecgBuffer[sampleIndex] = analogRead(ECG_PIN);
    sampleIndex++;

    if (sampleIndex >= TOTAL_SAMPLES) {
      JsonDocument doc;
      doc["device_id"] = DEVICE_ID;
      doc["nama_pasien"] = NAMA_PASIEN;
      doc["lead_off"] = false;
      
      JsonArray payload = doc["payload"].to<JsonArray>();
      for (int i = 0; i < TOTAL_SAMPLES; i++) {
        payload.add(ecgBuffer[i]);
      }

      String outputJson;
      serializeJson(doc, outputJson);
      
      if (client.publish(MQTT_TOPIC, outputJson.c_str())) {
         Serial.println("Berhasil mengirim " + String(TOTAL_SAMPLES) + " sampel data ke AWS.");
      } else {
         Serial.println("Gagal mengirim data. Coba cek ukuran buffer atau koneksi!");
      }
      
      sampleIndex = 0; 
    }
  }
}