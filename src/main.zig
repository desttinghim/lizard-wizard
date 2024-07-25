/// A customizable Win32 install wizard to be used on disks as an autorun application.
/// Inspired and loosely based on the "Writing a Wizard like it's 2020" series of articles,
/// available at https://building.enlyze.com/posts/writing-win32-apps-like-its-2020-part-1/

// Copyright (c) 2024 Louis Pearson
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

/// All configurable values have been put in this namespace.
const Conf = struct {
    const header_height = 70;
    const window_min_height = 500;
    const window_min_width = 700;
    const reference_dpi = 96;
};

const TRUE: w32.foundation.BOOL = 1;
const FALSE: w32.foundation.BOOL = 0;

const Global = struct {
    var window_current_dpi: u32 = 0;
    var logo_bitmap: ?*anyopaque = null;
    var gui_font: ?*w32.HFONT = null;
    var gui_font_bold: ?*w32.HFONT = null;
    var direct2d_factory: ?*direct2d.ID2D1Factory = null;
};

const ResourceID = enum(c_int) {
    icon = 1,

    logo = 100,

    back = 1000,
    next = 1001,
    cancel = 1002,

    firstpage_header = 2000,
    firstpage_subheader = 2001,
    firstpage_text = 2002,

    secondpage_header = 3000,
    secondpage_subheader = 3001,
    column1 = 3002,
    column2 = 3003,
};

const CommandID = enum(c_int) {
    back = 500,
    next = 501,
    cancel = 502,
    _,
};

pub fn windowProc(handle: w32.foundation.HWND, msg: u32, wparam: w32.foundation.WPARAM, lparam: w32.foundation.LPARAM) callconv(.C) w32.foundation.LRESULT {
    switch (msg) {
        w32.ui.windows_and_messaging.WM_DESTROY => {
            w32.ui.windows_and_messaging.PostQuitMessage(0);
            return 0;
        },
        w32.ui.windows_and_messaging.WM_SIZE => {
            return 0;
        },
        w32.ui.windows_and_messaging.WM_DPICHANGED => {
            std.debug.print("dpi changed event, wparam = {x}, lparam = {x}\n", .{ wparam, lparam });

            Global.window_current_dpi = @truncate(wparam);

            var window_rect: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.ui.windows_and_messaging.GetClientRect(handle, &window_rect);
            _ = w32.graphics.gdi.InvalidateRect(handle, &window_rect, FALSE);

            const window_rect_new: *const w32.foundation.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
            const x = window_rect_new.left;
            const y = window_rect_new.top;
            const width = window_rect_new.right - x;
            const height = window_rect_new.bottom - y;

            std.debug.print("x = {}, y = {}, w = {}, h = {}\n", .{ x, y, width, height });

            _ = w32.ui.windows_and_messaging.SetWindowPos(handle, null, x, y, width, height, .{ .NOZORDER = 1, .NOACTIVATE = 1 });

            _ = centerWindow(handle);

            return 0;
        },
        w32.ui.windows_and_messaging.WM_PAINT => {
            // Using gdi
            // var paint = w32.graphics.gdi.PAINTSTRUCT{
            //     .rcPaint = w32.foundation.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            //     .fErase = TRUE,
            //     .hdc = null,
            //     .fRestore = FALSE,
            //     .fIncUpdate = FALSE,
            //     .rgbReserved = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            // };
            // const hdc = w32.graphics.gdi.BeginPaint(handle, &paint);
            // _ = w32.graphics.gdi.FillRect(hdc, &paint.rcPaint, w32.graphics.gdi.GetStockObject(w32.graphics.gdi.WHITE_BRUSH));
            // _ = w32.graphics.gdi.EndPaint(handle, &paint);
            var window_rect: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.ui.windows_and_messaging.GetClientRect(handle, &window_rect);

            // Using direct2d
            // const hello_world = w32.zig.L("Hello, World!");

            const width = window_rect.right - window_rect.left;
            const height = window_rect.bottom - window_rect.top;

            var render_target_opt: ?*direct2d.ID2D1HwndRenderTarget = null;

            _ = Global.direct2d_factory.?.ID2D1Factory_CreateHwndRenderTarget(
                &DefaultRenderTargetProperties,
                &.{
                    .hwnd = handle,
                    .pixelSize = direct2d.common.D2D_SIZE_U{ .width = @intCast(width), .height = @intCast(height) },
                    .presentOptions = direct2d.D2D1_PRESENT_OPTIONS_NONE,
                },
                &render_target_opt,
            );

            const render_target = render_target_opt.?;

            {
                render_target.ID2D1RenderTarget_BeginDraw();
                defer _ = render_target.ID2D1RenderTarget_EndDraw(null, null);

                const identity = direct2d.common.D2D_MATRIX_3X2_F{
                    .Anonymous = .{
                        .m = .{
                            // zig fmt: off
                            1, 0,
                            0, 1,
                            0, 0,
                            // zig fmt: on 
                        }
                    }
                };
                _ = render_target.ID2D1RenderTarget_SetTransform(&identity);

                const white = direct2d.common.D2D1_COLOR_F{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
                _ = render_target.ID2D1RenderTarget_Clear(&white);

                const black = direct2d.common.D2D1_COLOR_F{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
                var black_brush: ?*direct2d.ID2D1SolidColorBrush = null;
                _ = render_target.ID2D1RenderTarget_CreateSolidColorBrush(&black, null, &black_brush);

                _ = render_target.ID2D1RenderTarget_DrawRectangle(
                    &.{ .left = 10, .right = 100, .top = 10, .bottom = 100 },
                    @ptrCast(black_brush),
                    1.0,
                    null,
                );

                // _ = render_target.ID2D1RenderTarget_DrawText(
                //     hello_world,
                //     std.mem.len(hello_world),
                //     text_format,
                //     direct2d.common.D2D_RECT_F{ .left = 0, .top = 0, .right = width, .bottom = height },
                //     black_brush,
                //     direct2d.D2D1_DRAW_TEXT_OPTIONS_NONE,
                //     w32.graphics.direct_write.DWRITE_MEASURING_MODE_NATURAL,
                // );
            }

            return 0;
        },
        w32.ui.windows_and_messaging.WM_COMMAND => {
            const value: c_uint = @truncate(wparam);
            const id: CommandID = @enumFromInt(value);
            switch (id) {
                .back => {},
                .next => {},
                .cancel => {},
                _ => {},
            }
            return 0;
        },
        else => {
            return w32.ui.windows_and_messaging.DefWindowProcW(handle, msg, wparam, lparam);
        },
    }
}

pub fn main() !u8 {
    const h_instance = w32.system.library_loader.GetModuleHandleW(null);
    const class_name = w32.zig.L("My window class");

    const window_class = w32.ui.windows_and_messaging.WNDCLASSW{
        .style = w32.ui.windows_and_messaging.WNDCLASS_STYLES{
            .HREDRAW = 1,
            .VREDRAW = 1,
        },
        .lpfnWndProc = windowProc,
        .hInstance = h_instance,
        .hCursor = null,
        .hIcon = null,
        .hbrBackground = null,
        .lpszClassName = class_name,
        .lpszMenuName = null,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
    };
    _ = w32.ui.windows_and_messaging.RegisterClassW(&window_class);

    var style = w32.ui.windows_and_messaging.WS_OVERLAPPEDWINDOW;
    style.VISIBLE = 1;

    const hwnd_opt = w32.ui.windows_and_messaging.CreateWindowExW(
        w32.ui.windows_and_messaging.WINDOW_EX_STYLE{},
        class_name,
        w32.zig.L("Hello from zig"),
        style,
        w32.ui.windows_and_messaging.CW_USEDEFAULT,
        w32.ui.windows_and_messaging.CW_USEDEFAULT,
        Conf.window_min_width,
        Conf.window_min_height,
        null,
        null,
        h_instance,
        null,
    );

    const hwnd = hwnd_opt orelse {
        switch (w32.foundation.GetLastError()) {
            else => {
                return 1;
            },
        }
    };

    Global.window_current_dpi = getWindowDPI(hwnd);
    if (!SUCCEEDED(direct2d.D2D1CreateFactory(
        direct2d.D2D1_FACTORY_TYPE_SINGLE_THREADED,
        direct2d.IID_ID2D1Factory,
        null,
        @ptrCast(&Global.direct2d_factory),
    ))) {
        return 1;
    }

    // Run message loop
    var msg = w32.ui.windows_and_messaging.MSG{
        .hwnd = null,
        .lParam = 0,
        .message = 0,
        .pt = w32.foundation.POINT{
            .x = 0,
            .y = 0,
        },
        .time = 0,
        .wParam = 0,
    };
    while (w32.ui.windows_and_messaging.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w32.ui.windows_and_messaging.TranslateMessage(&msg);
        _ = w32.ui.windows_and_messaging.DispatchMessageW(&msg);
    }

    return 0;
}

// Helper functions

fn SUCCEEDED(result: w32.foundation.HRESULT) bool {
    return result >= 0;
}

fn SafeRelease(interface: anytype) void {
    if (interface.* != null) {
        interface.*.Release();
        interface.* = null;
    }
}

fn mulDiv(pixels: u32, current_dpi: u32, reference_dpi: u32) u32 {
    const scaled = pixels * current_dpi;
    return scaled / reference_dpi;
}

const Func_GetDpiForMonitor = *const fn (w32.graphics.gdi.HMONITOR, c_int, *c_uint, *c_uint) w32.foundation.HRESULT;

fn getWindowDPI(hwnd: w32.foundation.HWND) u32 {
    shcore: {
        // Tries to get the DPI setting for the monitor where the given window is located.
        // This API is Windows 8.1+.
        const shcore = w32.system.library_loader.LoadLibraryW(w32.zig.L("shcore")) orelse break :shcore;
        const PGetDpiForMonitor = w32.system.library_loader.GetProcAddress(shcore, "GetDpiForMonitor") orelse break :shcore;
        const GetDpiForMonitor: Func_GetDpiForMonitor = @ptrCast(PGetDpiForMonitor);
        const monitor = w32.graphics.gdi.MonitorFromWindow(hwnd, w32.graphics.gdi.MONITOR_DEFAULTTOPRIMARY) orelse break :shcore;
        var ui_dpi_x: u32, var ui_dpi_y: u32 = .{ 0, 0 };
        const result = GetDpiForMonitor(monitor, 0, &ui_dpi_x, &ui_dpi_y);
        if (!SUCCEEDED(result)) break :shcore;
        return @intCast(result);
    }

    // We couldn't get the window's DPI above, so get the DPI of the primary monitor
    // using an API that is available in all Windows versions.
    const screen_dc = w32.graphics.gdi.GetDC(null);
    defer _ = w32.graphics.gdi.ReleaseDC(null, screen_dc);
    const dpi = w32.graphics.gdi.GetDeviceCaps(screen_dc, w32.graphics.gdi.LOGPIXELSX);
    return @intCast(dpi);
}

/// Centers window relative to the window's parent and ensures that the window is on screen.
/// If the parent is null, returns false.
fn centerWindow(hwnd: w32.foundation.HWND) bool {
    const parent = w32.ui.windows_and_messaging.GetParent(hwnd) orelse return false;

    var rect_window, var rect_parent = .{
        std.mem.zeroes(w32.foundation.RECT),
        std.mem.zeroes(w32.foundation.RECT),
    };

    _ = w32.ui.windows_and_messaging.GetWindowRect(hwnd, &rect_window);
    _ = w32.ui.windows_and_messaging.GetWindowRect(parent, &rect_parent);

    const width = rect_window.left - rect_window.right;
    const height = rect_window.bottom - rect_window.top;

    var x = @divTrunc(((rect_parent.right - rect_parent.left) - width), 2) + rect_parent.left;
    var y = @divTrunc(((rect_parent.bottom - rect_parent.top) - height), 2) + rect_parent.top;

    const screen_width = w32.ui.windows_and_messaging.GetSystemMetrics(w32.ui.windows_and_messaging.SM_CXSCREEN);
    const screen_height = w32.ui.windows_and_messaging.GetSystemMetrics(w32.ui.windows_and_messaging.SM_CYSCREEN);

    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + width > screen_width) x = screen_width - width;
    if (y + height > screen_height) y = screen_height - height;

    _ = w32.ui.windows_and_messaging.MoveWindow(hwnd, x, y, width, height, FALSE);

    return true;
}

/// Uses GDI+ to load a PNG as a bitmap.
fn loadPNGAsGdiplusBitmap(
    render_target: *direct2d.ID2D1RenderTarget,
    iwic_factory: *imaging.IWICImagingFactory,
    instance: w32.HINSTANCE,
    id: c_uint,
) !*w32.HBITMAP {
    const loader = w32.system.library_loader;

    // Find
    const resource_source = loader.FindResourceW(instance, id, w32.zig.L("PNG")) orelse return error.NotFound;
    // Size
    const size = loader.SizeofResource(instance, resource_source) orelse return error.ZeroSized;
    // Load
    const resource_loaded = loader.LoadResource(instance, resource_source) orelse return error.CouldNotLoad;
    // Lock
    const resource = loader.LockResource(resource_loaded) orelse return error.CouldNotLock;

    const stream = stream: {
        var stream_opt: ?*imaging.IWICStream = null;
        const result = iwic_factory.IWICImagingFactory_CreateStream(&stream_opt);
        if (!SUCCEEDED(result)) return error.CouldNotCreateStream;
        break :stream stream_opt orelse return error.CouldNotCreateStream;
    };

    {
        const result = stream.IWICStream_InitializeFromMemory(@ptrCast(resource), size);
        if (!SUCCEEDED(result)) return error.CouldNotInitializeStreamFromMemory;
    }

    const decoder = decoder: {
        var decoder_opt: ?*imaging.IWICBitmapDecoder = null;
        const result = iwic_factory.IWICImagingFactory_CreateDecoderFromStream(
            stream,
            null,
            imaging.WICDecodeMetadataCacheOnLoad,
            &decoder_opt,
        );
        if (!SUCCEEDED(result)) return error.CouldNotCreateDecoder;
        break :decoder decoder_opt orelse return error.CouldNotCreateDecoder;
    };

    const source = source: {
        var source_opt: ?*imaging.IWICBitmapSource = null;
        const result = decoder.IWICBitmapDecoder_GetFrame(0, &source_opt);
        if (!SUCCEEDED(result)) return error.CouldNotGetFrame;
        break :source source_opt orelse return error.CouldNotGetFrame;
    };

    const converter = converter: {
        var converter_opt: ?*imaging.IWICFormatConverter = null;
        // Convert Image format to 32bppPBGRA
        // (DXGI_FORMAT_B8G8R8A8_UNORM + D2D1_ALPHA_MODE_PREMULTIPLIED)
        // In English: converts the image to 32bit with premultiplied alpha
        const result = iwic_factory.IWICImagingFactory_CreateFormatConverter(&converter_opt);
        if (!SUCCEEDED(result)) return error.CouldNotCreateFormatConverter;
        break :converter converter_opt orelse return error.CouldNotCreateFormatConverter;
    };

    // Initialize the converter
    {
        const result = converter.IWICFormatConverter_Initialize(
            source,
            imaging.GUID_WICPixelFormat32bppPBGRA,
            .WICBitmapDitherTypeNone,
            null,
            0,
            .WICBitmapPaletteMedianCut,
        );
        if (!SUCCEEDED(result)) return error.CouldNotInitializeConverter;
    }

    // Create a D3D bitmap from the WIC bitmap
    const bitmap = bitmap: {
        var bitmap_opt: ?*direct2d.ID2D1Bitmap = null;
        const result = render_target.ID2D1RenderTarget_CreateBitmapFromWicBitmap(converter, null, &bitmap_opt);
        if (!SUCCEEDED(result)) return error.CouldNotCreateD2DBitmap;
        break :bitmap bitmap_opt orelse return error.CouldNotCreateD2DBitmap;
    };

    return bitmap;
}

/// Attempt to load an image from a file using the Windows Imaging Component (WIC) API.
fn loadBitmapFromFile(
    render_target: *direct2d.ID2D1RenderTarget,
    iwic_factory: *imaging.IWICImagingFactory,
    uri: []const u8,
    destination_width: u32,
    destination_height: u32,
) !*direct2d.ID2D1Bitmap {
    var decoder_opt: ?*imaging.IWICBitmapDecoder = null;
    {
        const result = iwic_factory.IWICImagingFactory_CreateDecoderFromFilename(
            uri,
            null,
            auth.SDDL_GENERIC_READ,
            imaging.WICDecodeMetadataCacheOnLoad,
            &decoder_opt,
        );
        if (!SUCCEEDED(result)) return error.FailedToCreateDecoder;
    }
    const decoder = decoder_opt orelse return error.FailedToCreateDecoder;
    defer SafeRelease(decoder);

    var source_opt: ?*imaging.IWICBitmapFrameDecode = null;
    {
        const result = decoder.IWICBitmapDecoder_GetFrame(0, &source_opt);
        if (!SUCCEEDED(result)) return error.FailedToCreateFrameDecoder;
    }
    const source = source_opt orelse return error.FailedToCreateFrameDecoder;
    defer SafeRelease(source);

    var converter_opt: ?*imaging.IWICFormatConverter = null;
    {
        // Convert Image format to 32bppPBGRA
        // (DXGI_FORMAT_B8G8R8A8_UNORM + D2D1_ALPHA_MODE_PREMULTIPLIED)
        // In English: converts the image to 32bit with premultiplied alpha
        const result = iwic_factory.IWICImagingFactory_CreateFormatConverter(&converter_opt);
        if (!SUCCEEDED(result)) return error.FailedToCreateFormatConverter;
    }
    const converter = converter_opt orelse return error.FailedToCreateFormatConverter;
    defer SafeRelease(converter);

    {
        const result = converter.IWICFormatConverter_Initialize(
            source,
            imaging.GUID_WICPixelFormat32bppPBGRA,
            imaging.WICBitmapDitherTypeNone,
            null,
            0.0,
            imaging.WICBitmapPaletteTypeMedianCut,
        );
        if (!SUCCEEDED(result)) return error.FailedToInitializeConverter;
    }

    var scaler_opt: ?*imaging.IWICBitmapScaler = null;
    {
        const result = iwic_factory.IWICImagingFactory_CreateBitmapScaler(&scaler_opt);
        if (!SUCCEEDED(result)) return error.FailedToCreateScaler;
    }
    const scaler = scaler_opt orelse return error.FailedToCreateScaler;
    defer SafeRelease(scaler);

    {
        const result = scaler.IWICBitmapScaler_Initialize(
            converter,
            destination_width,
            destination_height,
            imaging.WICBitmapInterpolationModeFant,
        );
        if (!SUCCEEDED(result)) return error.FailedToScaleImage;
    }

    var bitmap_opt: ?*direct2d.ID2D1Bitmap = null;
    {
        const result = render_target.ID2D1RenderTarget_CreateBitmapFromWicBitmap(scaler, null, &bitmap_opt);
        if (!SUCCEEDED(result)) return error.FailedToCreateD2DBitmap;
    }
    const bitmap = bitmap_opt orelse return error.FailedToCreateD2DBitmap;

    return bitmap;
}

const DefaultRenderTargetProperties = direct2d.D2D1_RENDER_TARGET_PROPERTIES{
    .type = direct2d.D2D1_RENDER_TARGET_TYPE_DEFAULT,
    .pixelFormat = .{
        .format = w32.graphics.dxgi.common.DXGI_FORMAT_UNKNOWN,
        .alphaMode = direct2d.common.D2D1_ALPHA_MODE_UNKNOWN,
    },
    .dpiX = 0,
    .dpiY = 0,
    .usage = direct2d.D2D1_RENDER_TARGET_USAGE_NONE,
    .minLevel = direct2d.D2D1_FEATURE_LEVEL_DEFAULT,
};

// We have 2 dependencies: the zig standard library and zigwin32.
// TODO: Copy the necessary functions from zigwin32 into this file. Or remove this comment.
const std = @import("std");
const w32 = @import("zigwin32");
const direct2d = w32.graphics.direct2d;
const imaging = w32.graphics.imaging;
const auth = w32.security.authorization;
