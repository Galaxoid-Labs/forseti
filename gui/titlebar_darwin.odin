package gui

// macOS-only: give the dashboard window a transparent/unified titlebar. The
// titlebar background is made transparent and painted the same color as the
// dashboard, so it reads as one seamless surface — but WITHOUT extending the
// GL content under it (FullSizeContentView), which would push content under
// the traffic-light buttons and let GLFW's view swallow window drags. This
// way the ~28px titlebar strip stays a real, draggable macOS titlebar that
// simply matches the content color. Darwin-only via the _darwin.odin suffix;
// titlebar_other.odin stubs it elsewhere.

import NS "core:sys/darwin/Foundation"
import "base:intrinsics"

// Apply the transparent titlebar. `bg` is the dashboard background color
// (RGBA bytes) so the titlebar matches it. Call once after InitWindow.
apply_transparent_titlebar :: proc(bg: [4]u8) {
	app := NS.Application_sharedApplication()
	if app == nil {
		return
	}
	win := NS.Application_keyWindow(app)
	if win == nil {
		win = NS.Application_mainWindow(app)
	}
	if win == nil {
		wins := NS.Application_windows(app)
		if wins != nil && NS.Array_count(wins) > 0 {
			win = NS.Array_objectAs(wins, NS.Array_count(wins) - 1, ^NS.Window)
		}
	}
	if win == nil {
		return
	}

	color := NS.Color_colorWithSRGBRed(
		NS.Float(bg[0]) / 255.0,
		NS.Float(bg[1]) / 255.0,
		NS.Float(bg[2]) / 255.0,
		NS.Float(bg[3]) / 255.0,
	)
	NS.Window_setBackgroundColor(win, color)
	NS.Window_setTitlebarAppearsTransparent(win, true)
	NS.Window_setTitleVisibility(win, .Hidden)
}

// macOS-only: set the Dock (application) icon at runtime from embedded PNG
// bytes. This works for a CLI binary launched from Terminal — no .app bundle
// needed — so `btcnode --gui` and `btcnode-gui` both get a Dock icon without
// packaging. NSImage.initWithData: and NSApplication.setApplicationIconImage:
// aren't wrapped in core:sys/darwin/Foundation, so call them via the objc
// runtime directly (intrinsics.objc_send == the bindings' private msgSend).
set_dock_icon :: proc(png: []byte) {
	app := NS.Application_sharedApplication()
	if app == nil {
		return
	}
	data := NS.Data_initWithBytes(NS.Data_alloc(), png)
	if data == nil {
		return
	}
	img := intrinsics.objc_send(^NS.Image, NS.Image_alloc(), "initWithData:", data)
	if img == nil {
		return
	}
	intrinsics.objc_send(nil, app, "setApplicationIconImage:", img)
}
