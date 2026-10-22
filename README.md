# Force RGB

A menu bar app that makes an Apple Silicon Mac send **RGB** over HDMI instead of **YPbPr**.

macOS often picks YCbCr for HDMI monitors. System Settings calls that YPbPr. Text goes soft and colors look washed out. Force RGB tells the display the monitor only accepts RGB, and leaves its resolutions and refresh rates in place.

The menu bar shows **RGB** or **YPbPr**. There is no Dock icon.

- **Force RGB** switches the link. The screen can go black for a moment.
- **Restore Original** puts the monitor’s original signal back.
- **Keep Forcing RGB** reapplies the change after wake or reconnect.
- **Open at Login** brings it back after a restart. The change does not survive a reboot on its own.

```
/Applications/ForceRGB.app/Contents/MacOS/ForceRGB --status
```

## Build

Xcode Command Line Tools are enough.

```
make
make install
```

`make install` copies the app to `/Applications` and opens it. The built-in display is left alone.

This uses a private macOS display API, so a future system update can break it.
