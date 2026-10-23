# ESP32 UpNext display

This Arduino application targets the **Elecrow CrowPanel ESP32 2.13-inch
E-paper HMI Display (122×250, hardware V1.0)**. It connects to the reservation
daemon and shows current and upcoming reservations.

## Arduino IDE setup

1. Install the Espressif **ESP32** board package and select **ESP32S3 Dev Module**.
2. Install **GxEPD2**, **PubSubClient**, and **ArduinoJson 7** with Library Manager.
3. Copy `Config.h.example` to `Config.h`; enter credentials and seed the resource
   list. Set `UPNEXT_FLIP_180` to `true` if the display is mounted upside down.
4. Open `UpNext.ino` and upload with USB CDC On Boot enabled.

The hardware V1.0 pin assignments are e-paper SCK 12, MOSI 11, reset 10, DC 13,
CS 14, busy 9; dial left/right/press 6/4/5; MENU 2; and EXIT 1.

## Operation

The configured resources are immediately available. The application subscribes
to `MQTT_TOPIC_PREFIX/#` and learns additional shops and tools from observed
reservation topics. Press the dial to choose a shop, turn and press it, then
choose `Entire Shop` or a known tool. MENU cancels selection. On the main screen,
MENU switches between the two-column current/UpNext view and the full-screen
UpNext view.

EXIT persists the selected shop/tool, layout, and all learned resources. A
`SAVED` acknowledgement appears for two seconds. Selections and learned names
survive restart. E-paper is refreshed only after displayed data, selection,
layout, or connection state changes.

Resource names must exactly match MongoDB shop/tool names. MQTT subscriptions
use QoS 1 and the payload buffer is 2048 bytes.
