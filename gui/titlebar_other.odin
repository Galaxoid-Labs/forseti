#+build !darwin
package gui

// Non-macOS stub: the transparent/unified titlebar is a macOS-only styling.
apply_transparent_titlebar :: proc(bg: [4]u8) {}

// Non-macOS stub: the Dock icon is macOS-only (Linux/Windows use the raylib
// SetWindowIcon call in gui.odin instead).
set_dock_icon :: proc(png: []byte) {}
