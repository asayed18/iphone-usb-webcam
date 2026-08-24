# UsbCam — iPhone as USB webcam for Windows (native, no Mac needed)

Native iOS app streams the iPhone camera as H.264 MPEG-TS over a **USB cable**
(TCP-over-USB via usbmuxd/iproxy) into OBS. OBS Virtual Camera exposes it to
Zoom/Teams/etc. Target: 1080p60 / 4K30, 8–50 Mbps manual bitrate, full manual
controls (ISO, shutter, WB, focus, zoom, lens pick).

iPhone 14 Pro Max (Lightning = USB2 ~480 Mbps) → practical ceiling: 4K30 @
~25–40 Mbps or 1080p60 comfortably.

## Architecture

```
[iPhone app]
  AVCaptureSession (manual controls)
  → VideoToolbox HW H.264 (Baseline, no B-frames, low latency)
  → minimal MPEG-TS muxer (PAT/PMT resend, PCR on video PID)
  → TCP listener on phone localhost :9750        [Network.framework]
        ▲ usbmuxd tunnel over Lightning cable
[Windows: iproxy.exe 9750→9750]                  [libimobiledevice]
[OBS Media Source tcp://127.0.0.1:9750]
[OBS "Start Virtual Camera"] → any video app sees "OBS Virtual Camera"
```

Only custom code = the iOS app (`ios/`). Everything else is off-the-shelf.

## One-time Windows setup

1. Install **Apple Devices** (Win11) or iTunes — provides USB drivers.
2. Install **Sideloadly** — https://sideloadly.io (signs the IPA with your free Apple ID).
3. Download libimobiledevice Windows binaries; copy `iproxy.exe` into `windows/`.
4. Install OBS Studio.

## Build the IPA (no Mac required)

1. Push this repo to GitHub (Actions run on macOS runner).
2. Workflow `build-ipa` produces artifact **UsbCam-unsigned-ipa** → download.

## Install on your iPhone

1. Plug iPhone into PC by cable.
2. Sideloadly → drag `UsbCam.ipa` → enter your Apple ID → Start.
3. On iPhone: Settings → Privacy & Security → Developer Mode → ON (reboot).
4. Settings → General → VPN & Device Management → trust your Apple ID cert.
5. Launch UsbCam.

Note: free Apple ID signature expires after **7 days** — re-run Sideloadly weekly.

## Run

1. iPhone: open UsbCam → grant camera permission → tap **STREAM**.
2. Keep app foreground + screen on (iOS kills background capture).
3. Plug in cable (or keep plugged), run `windows\run-webcam.bat`.
4. OBS → Sources → Media Source → uncheck Local File → input:
   `tcp://127.0.0.1:9750` → OK.
5. Controls → **Start Virtual Camera**.
6. Zoom/Meet/Teams → camera = **OBS Virtual Camera**.

## Controls

| Control | Notes |
|---|---|
| Lens picker | 0.5x ultra-wide / 1x wide / 3x tele |
| STREAM | starts encoder + TCP server (:9750) |
| Manual toggle | ISO, shutter ms, WB temp, focus position sliders |
| Zoom | up to 12x digital |
| Bitrate | 8–50 Mbps (default 20) |
| 4K toggle | switches active format (applies immediately) |

## Known limits / next steps

- Video-only v1 — audio not muxed yet (use PC mic, or add AAC ADTS PID later).
- PCR only on IDR frames (~2 s GOP) — fine for ffmpeg/OBS; add periodic PCR if
  players complain.
- No backpressure handling: slow clients get dropped frames at TCP layer only;
  single client assumed.
- Screen must stay on; consider Guided Access to lock UI during use.
