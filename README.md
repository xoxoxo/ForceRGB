# Rads macOS Mini Toolbox

A menu bar app with small fixes for an Apple Silicon Mac. There is no Dock icon.

## Force RGB over HDMI

macOS often picks YCbCr for HDMI monitors. System Settings calls that YPbPr. Text goes soft and colors look washed out. Force RGB tells the display the monitor only accepts RGB, and leaves its resolutions and refresh rates in place. The built-in display is left alone.

The menu bar shows **RGB** or **YPbPr**.

- **Force RGB** switches the link. The screen can go black for a moment. The first time a monitor switches, the app asks whether to keep RGB. If you don’t click **Keep** within 15 seconds, the original signal comes back and Keep Forcing RGB turns off. Each monitor is asked about only once.
- **Restore Original** puts the monitor’s original signal back.
- **Keep Forcing RGB** reapplies the change after wake or reconnect.
- **Open at Login** brings the app back after a restart. The change does not survive a reboot on its own.

```
"/Applications/Rads macOS Mini Toolbox.app/Contents/MacOS/RadsMiniToolbox" --status
```

This uses a private macOS display API, so a future system update can break it.

## App Window Fixer

**App Window Fixer…** lists every open window. Windows stuck between displays or off screen are listed first, in orange. Pick one, choose a display, then click **Center** or **Fill**, or type a position and size and click **Apply**. Double-click a window to center it. X and Y are measured from the top-left corner of the display, below the menu bar.

The map below the list shows each display in its own color, with its name and size. It shows only the window selected in the list, so a busy desktop stays readable. The display that window is over is highlighted, and the Display menu uses the same colors. Drag a window onto any display to move it, or drag its bottom-right corner to resize it; the real window follows as you drag. It snaps to display edges and centers unless you hold Option. Double-click it to fill the display it is on; double-click again to put it back. Click a window in the list or on the map to bring it forward; the panel stays on top of it.

macOS asks for Accessibility access the first time.

## Build

Xcode Command Line Tools are enough.

```
make
make install
```

`make install` copies the app to `/Applications` and opens it. It also removes the old `ForceRGB.app`. Use `make install PREFIX=~/Applications` to install it for your user only.

Accessibility access carries over between builds. If the app is switched on in Accessibility but still asks for access, that entry is from an older build: remove it with − and add the app again. To sign with a certificate, pass its name, for example `make install SIGN="Developer ID Application: …"`.
