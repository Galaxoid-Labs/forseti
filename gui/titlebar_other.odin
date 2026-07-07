#+build !darwin
package gui

// Non-macOS stub: the transparent/unified titlebar is a macOS-only styling.
apply_transparent_titlebar :: proc(bg: [4]u8) {}
