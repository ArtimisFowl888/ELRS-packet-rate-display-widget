# ELRS Packet Rate Widget

Lua widget for EdgeTX radios that shows the currently selected ExpressLRS packet rate and, optionally, the telemetry ratio. It works with radios that have internal ExpressLRS modules (for example, Radiomaster TX12/GX12/TX15) as well as external transmitters such as the Radiomaster Gemini system.

## Features

- Automatically discovers the connected ExpressLRS transmitter module through CRSF telemetry.
- Scans the module parameter list to locate the **Packet Rate** selector and keeps the value updated.
- Displays a large, readable packet rate label (for example `250 Hz`, `333 Hz Full`, `No Telemetry`).
- Optional secondary line showing the module name, the raw packet-rate string, and (optionally) the telemetry ratio.
- Handles chunked CRSF parameter responses so it works on both internal and external modules.

## Installation

1. Copy the `WIDGETS/elrs_band` folder to the `WIDGETS` directory on your radio's SD card.
2. Restart the radio (or reload scripts) so EdgeTX detects the new widget.
3. Add the widget to a model's main view, choose `ELRS Packet Rate`, and resize/position it as desired.
4. (Optional) Adjust the widget options: set *ShowName* to 0 to hide the module/raw strings, or set *ShowTelem* to 0 to hide the telemetry ratio.

## How It Works

The widget listens for CRSF telemetry frames from the ExpressLRS transmitter module (`deviceId = 0xEE`). It issues the same parameter-chunk requests used by the official ExpressLRS Lua configurator, looking for the **Packet Rate** parameter and, when available, the **Telemetry Ratio** parameter. Once discovered, the widget refreshes those parameters periodically (default ~1.2 s) and renders the current selection. The raw value returned by the module is also available for display so you can see the exact string delivered by ExpressLRS.

If the widget cannot communicate with the module, it shows a status message such as `CRSF unavailable`, `Waiting for ELRS...`, or `Scanning for packet rate...`. When telemetry resumes, the packet rate label updates automatically.

## Notes & Limitations

- The widget requires a working CRSF telemetry link (`crossfireTelemetryPush/crossfireTelemetryPop` must be available). On simulators without CRSF support it will display *CRSF unavailable*.
- Only one widget instance performs the CRSF queries; multiple instances share the same data.
- Refresh timing assumes `getTime()` uses EdgeTX ticks (100 Hz). If you use the script in another environment, adjust `refreshInterval`, `scanSpacing`, and related constants in `main.lua`.
- The script does not attempt to change settings; it is strictly read-only.

## Testing

To verify on radio hardware:

1. Install the widget and place it on a model screen.
2. Launch the official ExpressLRS Lua configurator and change the packet rate (for example between `250 Hz` and `1000 Hz`).
3. Return to the main screen; the widget should update within ~1 s.
4. Switch the module off or disconnect CRSF to confirm the widget reports the loss of telemetry.

## Future Ideas

- Add a widget option to select an alternate device ID (for setups with multiple CRSF devices).
- Allow custom refresh intervals per widget instance.
- Provide small/large layout variants tailored to EdgeTX widget zone sizes.

Contributions and feedback are welcome! Copy or adapt the script to suit your specific radio setup.
