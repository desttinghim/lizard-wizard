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

const identity = direct2d.common.D2D_MATRIX_3X2_F{ .Anonymous = .{ .m = .{
    1, 0,
    0, 1,
    0, 0,
} } };
const white = direct2d.common.D2D_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };
const black = direct2d.common.D2D_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 1 };

const RES = @cImport({
    @cInclude("resource.h");
});
const ResourceID = enum(c_int) {
    icon = RES.IDI_ICON,

    logo = RES.IDP_LOGO,

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

const App = struct {
    hwnd: w32.foundation.HWND,

    d2d_factory: *direct2d.ID2D1Factory,
    iwic_factory: *imaging.IWICImagingFactory,
    dwrite_factory: *w32.graphics.direct_write.IDWriteFactory,
    dwrite_gdi_interop: *w32.graphics.direct_write.IDWriteGdiInterop,

    d2d_render_target: *direct2d.ID2D1HwndRenderTarget,
    d2d_brush_black: *direct2d.ID2D1SolidColorBrush,
    window_current_dpi: i32 = 0,
    d2d_bitmap_logo: *direct2d.ID2D1Bitmap,
    // text_format: *w32.graphics.direct_write.IDWriteTextFormat,

    font_attr_gui: w32.graphics.gdi.LOGFONTW,
    font_attr_gui_bold: w32.graphics.gdi.LOGFONTW,
    font_gui: *w32.graphics.direct_write.IDWriteFont,
    font_gui_bold: *w32.graphics.direct_write.IDWriteFont,

    const class_name = w32.zig.L("GameDisk");
    const window_title = w32.zig.L("Hello from zig"); // Title

    fn create(h_instance: w32.foundation.HINSTANCE, allocator: std.mem.Allocator) !*App {
        const WAM = w32.ui.windows_and_messaging;

        const app_icon = WAM.LoadIconW(h_instance, @ptrFromInt(@intFromEnum(ResourceID.icon)));

        const window_class = w32.ui.windows_and_messaging.WNDCLASSW{
            .style = w32.ui.windows_and_messaging.WNDCLASS_STYLES{
                .HREDRAW = 1,
                .VREDRAW = 1,
            },
            .lpfnWndProc = _WndProc,
            .hInstance = h_instance,
            .hCursor = WAM.LoadCursorW(null, WAM.IDI_APPLICATION),
            .hIcon = app_icon,
            .hbrBackground = w32.graphics.gdi.GetSysColorBrush(@intFromEnum(w32.ui.windows_and_messaging.COLOR_BTNFACE)),
            .lpszClassName = class_name,
            .lpszMenuName = null,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
        };
        const class_atom = atom: {
            const res = WAM.RegisterClassW(&window_class);
            if (res <= 0) return error.FailedToRegisterClass;
            break :atom res;
        };

        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        // Create window
        const hwnd = w32.ui.windows_and_messaging.CreateWindowExW(
            w32.ui.windows_and_messaging.WINDOW_EX_STYLE{},
            @ptrFromInt(class_atom),
            window_title,
            w32.ui.windows_and_messaging.WINDOW_STYLE{
                // .OVERLAPPED = TRUE,
                // .CAPTION = TRUE,
                .SYSMENU = TRUE,
                .THICKFRAME = TRUE,
                .MINIMIZE = TRUE,
                .MAXIMIZE = TRUE,
                .CLIPCHILDREN = TRUE,
                .CLIPSIBLINGS = TRUE,
            },
            w32.ui.windows_and_messaging.CW_USEDEFAULT,
            w32.ui.windows_and_messaging.CW_USEDEFAULT,
            Conf.window_min_width,
            Conf.window_min_height,
            null,
            null,
            h_instance,
            self,
        ) orelse {
            const err = w32.foundation.GetLastError();
            std.log.err("{s}", .{@tagName(err)});

            // TODO: Handle specific errors with GetLastError()
            return error.CouldNotCreateWindow;
        };

        std.log.info("created window handle {}", .{hwnd});

        return self;
    }

    fn destroy(app: *App, allocator: std.mem.Allocator) void {
        _ = app.d2d_brush_black.IUnknown.Release();
        _ = app.d2d_render_target.IUnknown.Release();
        _ = app.d2d_factory.IUnknown.Release();
        allocator.destroy(app);
    }

    fn run(_: *App) !void {
        var msg = std.mem.zeroes(w32.ui.windows_and_messaging.MSG);
        while (w32.ui.windows_and_messaging.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = w32.ui.windows_and_messaging.TranslateMessage(&msg);
            _ = w32.ui.windows_and_messaging.DispatchMessageW(&msg);
        }
    }

    fn _WndProc(
        handle: w32.foundation.HWND,
        msg: u32,
        wparam: w32.foundation.WPARAM,
        lparam: w32.foundation.LPARAM,
    ) callconv(.C) w32.foundation.LRESULT {
        const WAM = w32.ui.windows_and_messaging;

        instance: {
            const app = InstanceFromWndProc(App, handle, msg, lparam) catch break :instance;
            switch (msg) {
                WAM.WM_COMMAND => return ErrToLRESULT(app.OnCommand(wparam)),
                WAM.WM_CREATE => return ErrToLRESULT(app.OnCreate()),
                WAM.WM_DESTROY => return ErrToLRESULT(app.OnDestroy()),
                WAM.WM_DPICHANGED => return ErrToLRESULT(app.OnDpiChanged(wparam, lparam)),
                WAM.WM_GETMINMAXINFO => return ErrToLRESULT(app.OnGetMinMaxInfo(lparam)),
                WAM.WM_PAINT => return ErrToLRESULT(app.OnPaint()),
                WAM.WM_SIZE => return ErrToLRESULT(app.OnSize()),
                else => {},
            }
        }

        std.log.info("Uncaught message {}", .{msg});

        return WAM.DefWindowProcW(handle, msg, wparam, lparam);
    }

    fn ErrToLRESULT(maybe_err: anytype) w32.foundation.LRESULT {
        if (maybe_err) {
            return 0;
        } else |err| {
            // TODO: Log error
            std.log.err("Error in callback: {!}", .{err});
            return 1;
        }
    }

    // Callbacks
    const WPARAM = w32.foundation.WPARAM;
    const LPARAM = w32.foundation.LPARAM;

    fn OnCommand(app: *App, wparam: WPARAM) !void {
        _ = app;
        std.log.info("WM_COMMAND", .{});
        const value: c_uint = @truncate(wparam);
        const id: CommandID = @enumFromInt(value);
        switch (id) {
            .back => {},
            .next => {},
            .cancel => {},
            _ => {},
        }
    }

    fn OnCreate(app: *App) !void {
        std.log.info("WM_CREATE", .{});
        // Fields other than hwnd are currently undefined, do not use them
        std.log.info("oncreate window handle {}", .{app.hwnd});
        const hwnd = app.hwnd;
        const h_instance = w32.system.library_loader.GetModuleHandleW(null) orelse return error.RetrievingHInstance;

        // Device independent setup
        const d2d_factory = factory: {
            var d2d_factory_opt: ?*direct2d.ID2D1Factory = null;
            CHECK(direct2d.D2D1CreateFactory(
                direct2d.D2D1_FACTORY_TYPE_SINGLE_THREADED,
                direct2d.IID_ID2D1Factory,
                null,
                @ptrCast(&d2d_factory_opt),
            )) catch return error.InitD2DFactory;
            break :factory d2d_factory_opt orelse return error.InitD2DFactory;
        };
        std.log.info("d2d_factory created {}", .{d2d_factory});

        const dwrite_factory = factory: {
            var dwrite_factory_opt: ?*w32.graphics.direct_write.IDWriteFactory = null;
            CHECK(w32.graphics.direct_write.DWriteCreateFactory(
                w32.graphics.direct_write.DWRITE_FACTORY_TYPE_SHARED,
                w32.graphics.direct_write.IID_IDWriteFactory,
                @ptrCast(&dwrite_factory_opt),
            )) catch return error.InitDWriteFactory;
            break :factory dwrite_factory_opt orelse return error.InitDWriteFactory;
        };
        std.log.info("dwrite_factory created {}", .{dwrite_factory});

        const iwic_factory = factory: {
            var iwic_factory_opt: ?*imaging.IWICImagingFactory = null;
            CHECK(w32.system.com.CoCreateInstance(
                @alignCast(@ptrCast(&imaging.CLSID_WICImagingFactory.Bytes)),
                null,
                w32.system.com.CLSCTX_INPROC_SERVER,
                @alignCast(@ptrCast(&imaging.IID_IWICImagingFactory.Bytes)),
                @ptrCast(&iwic_factory_opt),
            )) catch return error.InitIWICFactory;
            break :factory iwic_factory_opt orelse return error.InitIWICFactory;
        };
        std.log.info("iwic_factory created {}", .{iwic_factory});

        const dwrite_gdi_interop = interop: {
            var option: ?*w32.graphics.direct_write.IDWriteGdiInterop = null;
            CHECK(dwrite_factory.GetGdiInterop(&option)) catch return error.InitDWriteGDIInterop;
            break :interop option orelse return error.InitDWriteGDIInterop;
        };
        std.log.info("dwrite_gdi_interop created {}", .{dwrite_gdi_interop});

        // Get the DPI for the monitor where the window is shown
        const dpi = GetWindowDPI(hwnd);

        // Create Direct2D render objects
        var window_rect = std.mem.zeroes(w32.foundation.RECT);
        CHECK(w32.ui.windows_and_messaging.GetClientRect(
            hwnd,
            &window_rect,
        )) catch return error.GetClientRect;

        const render_target = render_target: {
            var render_target_opt: ?*direct2d.ID2D1HwndRenderTarget = null;
            CHECK(d2d_factory.CreateHwndRenderTarget(
                &std.mem.zeroes(direct2d.D2D1_RENDER_TARGET_PROPERTIES),
                &.{
                    .hwnd = hwnd,
                    .pixelSize = direct2d.common.D2D_SIZE_U{
                        .width = @intCast(window_rect.right - window_rect.left),
                        .height = @intCast(window_rect.bottom - window_rect.top),
                    },
                    .presentOptions = direct2d.D2D1_PRESENT_OPTIONS_NONE,
                },
                &render_target_opt,
            )) catch return error.CreateHwndRenderTarget;
            break :render_target render_target_opt orelse return error.CreateHwndRenderTarget;
        };
        std.log.info("render_target created {}", .{render_target});

        const black_brush = black_brush: {
            var black_brush_opt: ?*direct2d.ID2D1SolidColorBrush = null;
            CHECK(render_target.ID2D1RenderTarget.CreateSolidColorBrush(
                &black,
                null,
                &black_brush_opt,
            )) catch return error.CreateSolidColorBrush;
            break :black_brush black_brush_opt orelse return error.CreateSolidColorBrush;
        };

        // Load resources
        const bitmap_logo = try loadPNGAsD2DBitmap(@ptrCast(render_target), iwic_factory, h_instance, @intFromEnum(ResourceID.logo));
        std.log.info("bitmap_logo {}", .{bitmap_logo});

        // Load up the font we'll need for the GUI

        var ncm = std.mem.zeroes(w32.ui.windows_and_messaging.NONCLIENTMETRICSW);
        ncm.cbSize = @sizeOf(w32.ui.windows_and_messaging.NONCLIENTMETRICSW);
        _ = w32.ui.windows_and_messaging.SystemParametersInfoW(w32.ui.windows_and_messaging.SPI_GETNONCLIENTMETRICS, ncm.cbSize, &ncm, .{});

        // const hdc = w32.graphics.gdi.GetDC(app.hwnd);
        // var log_font = std.mem.zeroes(w32.graphics.gdi.LOGFONTW);
        // // log_font.lfCharSet = w32.graphics.gdi.DEFAULT_CHARSET;
        // _ = w32.graphics.gdi.EnumFontFamiliesExW(hdc, &log_font, &_FontEnumProc, 0, 0);

        // We'll store the LOGFONTW struct in case we need to recreate the font
        // var font_attr_gui = std.mem.zeroInit(w32.graphics.gdi.LOGFONTW, .{
        //     .lfHeight = -mulDiv(10, dpi, Conf.reference_dpi),
        //     .lfCharSet = w32.graphics.gdi.ANSI_CHARSET,
        // });
        // const face_name = w32.zig.L("MS Shell Dlg 2");
        // @memcpy(font_attr_gui.lfFaceName[0..face_name.len], face_name);

        var font_attr_gui = ncm.lfMessageFont;

        // Make a copy of the LOGFONTW struct
        var font_attr_gui_bold = font_attr_gui;
        font_attr_gui_bold.lfWeight = w32.graphics.gdi.FW_BOLD;

        std.log.info("Font {}", .{std.unicode.fmtUtf16Le(std.mem.sliceTo(&font_attr_gui.lfFaceName, 0))});

        const font_gui = font_gui: {
            var option: ?*w32.graphics.direct_write.IDWriteFont = null;
            CHECK(dwrite_gdi_interop.CreateFontFromLOGFONT(&font_attr_gui, &option)) catch
                return error.InitDWriteFontGui;
            break :font_gui option orelse return error.InitDWriteFontGui;
        };
        std.log.info("font_gui {}", .{font_gui});

        const font_gui_bold = font_gui: {
            var option: ?*w32.graphics.direct_write.IDWriteFont = null;
            CHECK(dwrite_gdi_interop.CreateFontFromLOGFONT(&font_attr_gui_bold, &option)) catch
                return error.InitDWriteFontGuiBold;
            break :font_gui option orelse return error.InitDWriteFontGuiBold;
        };
        std.log.info("font_gui_bold {}", .{font_gui_bold});

        // const empty_str = w32.zig.L("");
        // const WC_STATIC = w32.ui.controls.WC_STATICW;
        // const WC_BUTTON = w32.ui.controls.WC_BUTTONW;

        // TODO
        // // Create the line above the buttons
        // const hwnd_line = w32.ui.windows_and_messaging.CreateWindowExW(.{}, WC_STATIC, empty_str, .{ .CHILD = 1, .VISIBLE = 1, .SUNKEN = 1 }, 0, 0, 0, 0, hwnd, ResourceID.back, null, null) orelse
        //     return error.CreateLine;

        // // Create the bottom buttons
        // const hwnd_line = w32.ui.windows_and_messaging.CreateWindowExW(.{}, WC_BUTTON, empty_str, .{ .CHILD = 1, .VISIBLE = 1, .SUNKEN = 1 }, 0, 0, 0, 0, hwnd, ResourceID.back, null, null) orelse
        //     return error.CreateBack;

        app.* = .{
            .hwnd = hwnd,
            .window_current_dpi = dpi,

            .d2d_factory = d2d_factory,
            .dwrite_factory = dwrite_factory,
            .dwrite_gdi_interop = dwrite_gdi_interop,
            .iwic_factory = iwic_factory,

            .d2d_render_target = render_target,
            .d2d_bitmap_logo = bitmap_logo,

            .d2d_brush_black = black_brush,
            .font_attr_gui = font_attr_gui,
            .font_attr_gui_bold = font_attr_gui_bold,
            .font_gui = font_gui,
            .font_gui_bold = font_gui_bold,
        };

        // Create all pages

        // Set the main window size
        const dpif: f32 = @floatFromInt(app.window_current_dpi);
        const width: i32 = @intFromFloat(Conf.window_min_width * (dpif / 96.0));
        const height: i32 = @intFromFloat(Conf.window_min_height * (dpif / 96.0));

        try CHECK_BOOL(w32.ui.windows_and_messaging.SetWindowPos(hwnd, null, 0, 0, width, height, .{
            // .NOZORDER = TRUE,
            // .NOACTIVATE = TRUE,
            .NOMOVE = TRUE,
        }));
        // _ = centerWindow(hwnd);
        _ = w32.ui.windows_and_messaging.ShowWindow(hwnd, .{ .SHOWNORMAL = TRUE });
        // try CHECK_BOOL(w32.graphics.gdi.UpdateWindow(hwnd));
    }

    fn _FontEnumProc(
        log_font_opt: ?*const w32.graphics.gdi.LOGFONTW,
        text_metric: ?*const w32.graphics.gdi.TEXTMETRICW,
        font_type: u32,
        lparam: w32.foundation.LPARAM,
    ) callconv(std.os.windows.WINAPI) c_int {
        const log_font = log_font_opt orelse {
            std.log.info("NULL log font", .{});
            return 1;
        };
        _ = text_metric;
        _ = font_type;
        _ = lparam;
        std.log.info("Font {}", .{std.unicode.fmtUtf16Le(std.mem.sliceTo(&log_font.lfFaceName, 0))});
        return 1;
    }

    fn OnDestroy(app: *App) !void {
        std.log.info("WM_DESTROY", .{});
        _ = app;
        w32.ui.windows_and_messaging.PostQuitMessage(0);
    }

    fn OnDpiChanged(app: *App, wparam: WPARAM, lparam: LPARAM) !void {
        _ = wparam;
        std.log.info("WM_DPICHANGED", .{});

        app.window_current_dpi = GetWindowDPI(app.hwnd);

        var window_rect = std.mem.zeroes(w32.foundation.RECT);
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(app.hwnd, &window_rect));
        try CHECK_BOOL(w32.graphics.gdi.InvalidateRect(app.hwnd, &window_rect, FALSE));

        const window_rect_new: *const w32.foundation.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
        const x = window_rect_new.left;
        const y = window_rect_new.top;
        const width = window_rect_new.right - x;
        const height = window_rect_new.bottom - y;

        try CHECK_BOOL(w32.ui.windows_and_messaging.SetWindowPos(app.hwnd, null, x, y, width, height, .{ .NOZORDER = 1, .NOACTIVATE = 1 }));

        _ = centerWindow(app.hwnd);
    }

    fn OnGetMinMaxInfo(app: *App, lparam: LPARAM) !void {
        std.log.info("WM_GETMINMAXINFO", .{});
        _ = app;
        _ = lparam;
    }

    fn OnPaint(app: *App) !void {
        std.log.info("WM_PAINT", .{});
        // const hello_world = w32.zig.L("Hello, World!");

        {
            const render_target = app.d2d_render_target;

            render_target.ID2D1RenderTarget.BeginDraw();
            defer _ = render_target.ID2D1RenderTarget.EndDraw(null, null);

            _ = render_target.ID2D1RenderTarget.SetTransform(&identity);

            _ = render_target.ID2D1RenderTarget.Clear(&white);

            _ = render_target.ID2D1RenderTarget.DrawRectangle(
                &.{ .left = 10, .right = 100, .top = 10, .bottom = 100 },
                @ptrCast(app.d2d_brush_black),
                1.0,
                null,
            );

            _ = render_target.ID2D1RenderTarget.DrawBitmap(
                app.d2d_bitmap_logo,
                &.{ .left = 10, .right = 100, .top = 10, .bottom = 100 },
                1,
                .LINEAR,
                null,
            );

            // _ = render_target.ID2D1RenderTarget.DrawText(
            //     hello_world,
            //     hello_world.len,
            //     app.text_format,
            //     &direct2d.common.D2D_RECT_F{ .left = 10, .top = 10, .right = 200, .bottom = 200 },
            //     @ptrCast(app.d2d_brush_black),
            //     direct2d.D2D1_DRAW_TEXT_OPTIONS_NONE,
            //     w32.graphics.direct_write.DWRITE_MEASURING_MODE_NATURAL,
            // );
        }
    }

    fn OnSize(app: *App) !void {
        std.log.info("WM_SIZE", .{});

        var window_rect: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(app.hwnd, &window_rect));
        // std.log.info("got window rect: {}, {}, {}, {}", .{ window_rect.left, window_rect.right, window_rect.top, window_rect.bottom });

        const width = window_rect.right - window_rect.left;
        const height = window_rect.bottom - window_rect.top;

        try CHECK(app.d2d_factory.CreateHwndRenderTarget(
            &std.mem.zeroes(direct2d.D2D1_RENDER_TARGET_PROPERTIES),
            &.{
                .hwnd = app.hwnd,
                .pixelSize = direct2d.common.D2D_SIZE_U{ .width = @intCast(width), .height = @intCast(height) },
                .presentOptions = direct2d.D2D1_PRESENT_OPTIONS_NONE,
            },
            @ptrCast(&app.d2d_render_target),
        ));
    }
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const h_instance = w32.system.library_loader.GetModuleHandleW(null) orelse return 1;

    // Initialize the standard controls
    // Required for at least Windows XP
    var icc = std.mem.zeroes(w32.ui.controls.INITCOMMONCONTROLSEX);
    icc.dwSize = @sizeOf(w32.ui.controls.INITCOMMONCONTROLSEX);
    icc.dwICC = .{ .STANDARD_CLASSES = TRUE, .LISTVIEW_CLASSES = TRUE };
    try CHECK_BOOL(w32.ui.controls.InitCommonControlsEx(&icc));

    // Initialize COM (needed for IWIC)
    try CHECK(w32.system.com.CoInitialize(null));

    const app = try App.create(h_instance, gpa.allocator());
    defer app.destroy(gpa.allocator());

    try app.run();

    return 0;
}

// Helper functions

fn SUCCEEDED(result: w32.foundation.HRESULT) bool {
    return result >= 0;
}

const Win32Error = error{
    NotImplemented,
    NoSuchInterface,
    InvalidPointer,
    OperationAborted,
    UnspecifiedFailure,
    UnexpectedFailure,
    AccessDenied,
    InvalidHandle,
    OutOfMemory,
    InvalidArgument,
};
fn CHECK(result: w32.foundation.HRESULT) !void {
    if (result >= 0) return;
    const err = switch (result) {
        w32.foundation.E_NOTIMPL => error.NotImplemented,
        w32.foundation.E_NOINTERFACE => error.NoSuchInterface,
        w32.foundation.E_POINTER => error.InvalidPointer,
        w32.foundation.E_ABORT => error.OperationAborted,
        w32.foundation.E_FAIL => error.UnspecifiedFailure,
        w32.foundation.E_UNEXPECTED => error.UnexpectedFailure,
        w32.foundation.E_ACCESSDENIED => error.AccessDenied,
        w32.foundation.E_HANDLE => error.InvalidHandle,
        w32.foundation.E_OUTOFMEMORY => error.OutOfMemory,
        w32.foundation.E_INVALIDARG => error.InvalidArgument,
        else => error.Unknown,
    };

    std.log.info("HRESULT Error Code {}", .{result});

    return err;
}

fn CHECK_UNWRAP(result: w32.foundation.HRESULT) !w32.foundation.HRESULT {
    try CHECK(result);
    return result;
}

fn CHECK_BOOL(result: w32.foundation.BOOL) !void {
    if (result == TRUE) return;
    const err = w32.foundation.GetLastError();

    const err_name = @tagName(err);
    std.log.err("Win32 Error encountered: {} (result), {s}", .{ result, err_name });
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace);
    }

    if (err == .NO_ERROR) return;

    return error.Unknown;
}

fn InstanceFromWndProc(comptime T: type, hwnd: w32.foundation.HWND, msg: u32, lparam: w32.foundation.LPARAM) !*T {
    if (msg == w32.ui.windows_and_messaging.WM_CREATE) {
        const unsigned_lparam: usize = @intCast(lparam);
        const create_struct: *w32.ui.windows_and_messaging.CREATESTRUCTW = @ptrFromInt(unsigned_lparam);
        const pointer: *T = @alignCast(@ptrCast(create_struct.lpCreateParams));

        pointer.hwnd = hwnd;

        _ = w32.ui.windows_and_messaging.SetWindowLongPtrW(
            hwnd,
            w32.ui.windows_and_messaging.GWLP_USERDATA,
            @intCast(@intFromPtr(pointer)),
        );

        return pointer;
    } else {
        const userdata = w32.ui.windows_and_messaging.GetWindowLongPtrW(hwnd, w32.ui.windows_and_messaging.GWLP_USERDATA);
        if (userdata == 0) return error.CouldNotGetUserdata;
        const unsigned: usize = @intCast(userdata);
        const pointer: *T = @ptrFromInt(unsigned);
        return pointer;
    }
}

fn SafeRelease(interface: anytype) void {
    if (interface.* != null) {
        _ = interface.*.?.IUnknown.Release();
        interface.* = null;
    }
}

fn mulDiv(pixels: i32, current_dpi: i32, reference_dpi: i32) i32 {
    const scaled = pixels * current_dpi;
    return @divTrunc(scaled, reference_dpi);
}

const Func_GetDpiForMonitor = *const fn (w32.graphics.gdi.HMONITOR, c_int, *c_uint, *c_uint) w32.foundation.HRESULT;

fn GetWindowDPI(hwnd: w32.foundation.HWND) i32 {
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
        std.log.info("got dpi for monitor: {}, {}, {}", .{ result, ui_dpi_x, ui_dpi_y });
        return @intCast(ui_dpi_x);
    }

    // We couldn't get the window's DPI above, so get the DPI of the primary monitor
    // using an API that is available in all Windows versions.
    const screen_dc = w32.graphics.gdi.GetDC(null);
    defer _ = w32.graphics.gdi.ReleaseDC(null, screen_dc);

    const dpi_x = w32.graphics.gdi.GetDeviceCaps(screen_dc, w32.graphics.gdi.LOGPIXELSX);
    const dpi_y = w32.graphics.gdi.GetDeviceCaps(screen_dc, w32.graphics.gdi.LOGPIXELSY);
    std.log.info("got dpi for primary monitor: {}, {}", .{ dpi_x, dpi_y });
    return dpi_x;
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

    const width = rect_window.right - rect_window.left;
    const height = rect_window.top - rect_window.bottom;

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

/// Uses GDI+ to load a PNG resource as a bitmap.
fn loadPNGAsD2DBitmap(
    render_target: *direct2d.ID2D1RenderTarget,
    iwic_factory: *imaging.IWICImagingFactory,
    instance: w32.foundation.HINSTANCE,
    id: c_uint,
) !*direct2d.ID2D1Bitmap {
    const loader = w32.system.library_loader;

    // Find
    const resource_source = loader.FindResourceW(instance, @ptrFromInt(id), w32.zig.L("PNG")) orelse return error.NotFound;
    // Size
    const size = loader.SizeofResource(instance, resource_source);
    if (size == 0) return error.ZeroSized;
    // Load
    const resource_loaded = loader.LoadResource(instance, resource_source);
    if (resource_loaded == 0) return error.CouldNotLoad;
    // Lock
    const resource = loader.LockResource(resource_loaded) orelse return error.CouldNotLock;
    defer _ = loader.FreeResource(resource_loaded);

    const stream = stream: {
        var stream_opt: ?*imaging.IWICStream = null;
        CHECK(iwic_factory.CreateStream(&stream_opt)) catch
            return error.CouldNotCreateStream;
        break :stream stream_opt orelse return error.CouldNotCreateStream;
    };

    CHECK(stream.InitializeFromMemory(@ptrCast(resource), size)) catch
        return error.CouldNotInitializeStreamFromMemory;
    defer _ = stream.IUnknown.Release();

    const decoder = decoder: {
        var decoder_opt: ?*imaging.IWICBitmapDecoder = null;
        CHECK(iwic_factory.CreateDecoderFromStream(
            @ptrCast(stream),
            null,
            imaging.WICDecodeMetadataCacheOnLoad,
            &decoder_opt,
        )) catch
            return error.CouldNotCreateDecoder;
        break :decoder decoder_opt orelse return error.CouldNotCreateDecoder;
    };
    defer _ = decoder.IUnknown.Release();

    const source = source: {
        var source_opt: ?*imaging.IWICBitmapSource = null;
        CHECK(decoder.GetFrame(0, @ptrCast(&source_opt))) catch
            return error.CouldNotGetFrame;
        break :source source_opt orelse return error.CouldNotGetFrame;
    };
    defer _ = source.IUnknown.Release();

    const converter = converter: {
        var converter_opt: ?*imaging.IWICFormatConverter = null;
        // Convert Image format to 32bppPBGRA
        // (DXGI_FORMAT_B8G8R8A8_UNORM + D2D1_ALPHA_MODE_PREMULTIPLIED)
        // In English: converts the image to 32bit with premultiplied alpha
        CHECK(iwic_factory.CreateFormatConverter(&converter_opt)) catch
            return error.CouldNotCreateFormatConverter;
        break :converter converter_opt orelse return error.CouldNotCreateFormatConverter;
    };
    defer _ = converter.IUnknown.Release();

    var pixel_format: w32.zig.Guid = imaging.GUID_WICPixelFormat32bppPBGRA;

    // Initialize the converter
    CHECK(converter.Initialize(
        source,
        &pixel_format,
        .itmapDitherTypeNone, // TODO: report typo
        null,
        0,
        .itmapPaletteTypeMedianCut,
    )) catch
        return error.CouldNotInitializeConverter;

    // Create a D2D bitmap from the WIC bitmap
    const bitmap = bitmap: {
        var bitmap_opt: ?*direct2d.ID2D1Bitmap = null;
        CHECK(render_target.CreateBitmapFromWicBitmap(@ptrCast(converter), null, &bitmap_opt)) catch
            return error.CouldNotCreateD2DBitmap;
        break :bitmap bitmap_opt orelse return error.CouldNotCreateD2DBitmap;
    };

    return bitmap;
}

const Resource = struct {
    fn stringLoad(h_instance: w32.foundation.HINSTANCE, u_id: u32) ?[]const u16 {
        var pointer: ?[*]const u16 = null;
        const char_count = w32.ui.windows_and_messaging.LoadStringW(h_instance, u_id, &pointer, 0);
        if (char_count == 0) return null;
        return pointer[0..char_count];
    }
};

// We have 2 dependencies: the zig standard library and zigwin32.
// TODO: Copy the necessary functions from zigwin32 into this file. Or remove this comment.
const std = @import("std");
const w32 = @import("zigwin32");
const direct2d = w32.graphics.direct2d;
const imaging = w32.graphics.imaging;
const auth = w32.security.authorization;
