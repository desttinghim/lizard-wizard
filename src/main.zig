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
const white = direct2d.common.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };
const black = direct2d.common.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 1 };

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

const App = struct {
    hwnd: w32.foundation.HWND,
    allocator: std.mem.Allocator,
    d2d_factory: *direct2d.ID2D1Factory,
    d2d_render_target: *direct2d.ID2D1HwndRenderTarget,
    d2d_brush_black: *direct2d.ID2D1SolidColorBrush,
    // d2d_brush_light_slate_gray: *direct2d.ID2D1SolidColorBrush,
    // d2d_brush_cornflower_blue: *direct2d.ID2D1SolidColorBrush,
    window_current_dpi: u32 = 0,
    d2d_bitmap_logo: *direct2d.ID2D1Bitmap,
    iwic_factory: *imaging.IWICImagingFactory,
    dwrite_factory: *w32.graphics.direct_write.IDWriteFactory,
    text_format: *w32.graphics.direct_write.IDWriteTextFormat,
    // gui_font: ?*w32.HFONT = null,
    // gui_font_bold: ?*w32.HFONT = null,

    var class_atom: u16 = 0;
    const class_name = w32.zig.L("GameDisk");

    fn register(h_instance: w32.foundation.HINSTANCE) !void {
        const WAM = w32.ui.windows_and_messaging;

        const app_icon = WAM.LoadIconW(h_instance, @ptrFromInt(@intFromEnum(ResourceID.icon)));

        const window_class = w32.ui.windows_and_messaging.WNDCLASSW{
            .style = w32.ui.windows_and_messaging.WNDCLASS_STYLES{
                .HREDRAW = 1,
                .VREDRAW = 1,
            },
            .lpfnWndProc = windowProc,
            .hInstance = h_instance,
            .hCursor = WAM.LoadCursorW(null, WAM.IDI_APPLICATION),
            .hIcon = app_icon,
            .hbrBackground = null,
            .lpszClassName = class_name,
            .lpszMenuName = null,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
        };
        const class_atom_res = w32.ui.windows_and_messaging.RegisterClassW(&window_class);
        class_atom = if (class_atom_res > 0) class_atom_res else return error.FailedToRegister;

        std.log.info("Class Name Pointer: {ptr}", .{&class_name});
        std.log.info("Class Atom: {x}", .{class_atom});
    }

    fn create(h_instance: w32.foundation.HINSTANCE, allocator: std.mem.Allocator) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        std.log.info("h_instance {*}", .{h_instance});
        std.log.info("self pointer {*}", .{self});

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

        const dwrite_factory = factory: {
            var dwrite_factory_opt: ?*w32.graphics.direct_write.IDWriteFactory = null;
            try CHECK(w32.graphics.direct_write.DWriteCreateFactory(
                w32.graphics.direct_write.DWRITE_FACTORY_TYPE_SHARED,
                w32.graphics.direct_write.IID_IDWriteFactory,
                @ptrCast(&dwrite_factory_opt),
            ));
            break :factory dwrite_factory_opt orelse return error.InitDWriteFactory;
        };

        const font_name = w32.zig.L("Verdana");
        const font_size = 50;
        const text_format = text_format: {
            var text_format_opt: ?*w32.graphics.direct_write.IDWriteTextFormat = null;
            try CHECK(dwrite_factory.IDWriteFactory_CreateTextFormat(
                font_name,
                null,
                w32.graphics.direct_write.DWRITE_FONT_WEIGHT_NORMAL,
                w32.graphics.direct_write.DWRITE_FONT_STYLE_NORMAL,
                w32.graphics.direct_write.DWRITE_FONT_STRETCH_NORMAL,
                font_size,
                w32.zig.L(""),
                &text_format_opt,
            ));
            break :text_format text_format_opt orelse return error.InitDWriteTextFormat;
        };
        _ = text_format.IDWriteTextFormat_SetTextAlignment(w32.graphics.direct_write.DWRITE_TEXT_ALIGNMENT_CENTER);
        _ = text_format.IDWriteTextFormat_SetParagraphAlignment(w32.graphics.direct_write.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

        try CHECK(w32.system.com.CoInitialize(null));

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

        const window_title = w32.zig.L("Hello from zig"); // Title
        std.log.info("window_title {*}", .{window_title});

        // Create window
        const hwnd = w32.ui.windows_and_messaging.CreateWindowExW(
            w32.ui.windows_and_messaging.WINDOW_EX_STYLE{},
            @ptrFromInt(class_atom),
            window_title,
            w32.ui.windows_and_messaging.WINDOW_STYLE{ .VISIBLE = TRUE, .THICKFRAME = TRUE },
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

        const dpi: f32 = @floatFromInt(GetWindowDPI(hwnd));
        // const x = 0;
        // const y = 0;
        // const width: i32 = @intFromFloat(Conf.window_min_width * (dpi / 96.0));
        // const height: i32 = @intFromFloat(Conf.window_min_height * (dpi / 96.0));

        // try CHECK_BOOL(w32.ui.windows_and_messaging.SetWindowPos(hwnd, null, x, y, width, height, .{
        //     .NOZORDER = TRUE,
        //     .NOACTIVATE = TRUE,
        //     .NOMOVE = TRUE,
        // }));
        _ = centerWindow(hwnd);
        try CHECK_BOOL(w32.ui.windows_and_messaging.ShowWindow(hwnd, .{ .SHOWNORMAL = TRUE }));
        try CHECK_BOOL(w32.graphics.gdi.UpdateWindow(hwnd));

        // Create Direct2D render objects
        var window_rect = std.mem.zeroes(w32.foundation.RECT);
        CHECK(w32.ui.windows_and_messaging.GetClientRect(
            hwnd,
            &window_rect,
        )) catch return error.GetClientRect;

        const render_target = render_target: {
            var render_target_opt: ?*direct2d.ID2D1HwndRenderTarget = null;
            CHECK(d2d_factory.ID2D1Factory_CreateHwndRenderTarget(
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

        const black_brush = black_brush: {
            var black_brush_opt: ?*direct2d.ID2D1SolidColorBrush = null;
            CHECK(render_target.ID2D1RenderTarget_CreateSolidColorBrush(
                &black,
                null,
                &black_brush_opt,
            )) catch return error.CreateSolidColorBrush;
            break :black_brush black_brush_opt orelse return error.CreateSolidColorBrush;
        };

        const bitmap_logo = try loadPNGAsGdiplusBitmap(@ptrCast(render_target), iwic_factory, h_instance, @intFromEnum(ResourceID.logo));

        self.* = .{
            .hwnd = hwnd,
            .allocator = allocator,
            .d2d_factory = d2d_factory,
            .d2d_render_target = render_target,
            .d2d_brush_black = black_brush,
            .window_current_dpi = @intFromFloat(dpi),
            .iwic_factory = iwic_factory,
            .d2d_bitmap_logo = bitmap_logo,
            .text_format = text_format,
            .dwrite_factory = dwrite_factory,
        };

        return self;
    }

    fn destroy(app: *App) void {
        _ = app.d2d_brush_black.IUnknown_Release();
        _ = app.d2d_render_target.IUnknown_Release();
        _ = app.d2d_factory.IUnknown_Release();
        app.allocator.destroy(app);
    }

    fn run(_: *App) !void {
        var msg = std.mem.zeroes(w32.ui.windows_and_messaging.MSG);
        while (w32.ui.windows_and_messaging.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = w32.ui.windows_and_messaging.TranslateMessage(&msg);
            _ = w32.ui.windows_and_messaging.DispatchMessageW(&msg);
        }
    }
};

pub fn windowProc(handle: w32.foundation.HWND, msg: u32, wparam: w32.foundation.WPARAM, lparam: w32.foundation.LPARAM) callconv(.C) w32.foundation.LRESULT {
    // std.log.info("windowProc handle {*}, msg {x}", .{ handle, msg });
    const app_opt: ?*App = @ptrFromInt(@as(usize, @intCast(w32.ui.windows_and_messaging.GetWindowLongPtrW(handle, w32.ui.windows_and_messaging.GWLP_USERDATA))));
    switch (msg) {
        w32.ui.windows_and_messaging.WM_CREATE => {
            std.log.info("WM_CREATE", .{});
            const create_struct: *w32.ui.windows_and_messaging.CREATESTRUCTW = @ptrFromInt(@as(usize, @intCast(lparam)));
            if (w32.ui.windows_and_messaging.SetWindowLongPtrW(handle, w32.ui.windows_and_messaging.GWLP_USERDATA, @intCast(@intFromPtr(create_struct.lpCreateParams))) == 0)
                return 1;

            return 0;
        },
        w32.ui.windows_and_messaging.WM_DESTROY => {
            std.log.info("WM_DESTROY", .{});
            w32.ui.windows_and_messaging.PostQuitMessage(0);
            return 0;
        },
        w32.ui.windows_and_messaging.WM_SIZE => {
            std.log.info("WM_SIZE", .{});
            const app = app_opt orelse return 0;
            var window_rect: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(handle, &window_rect)) catch return 1;

            const width = window_rect.right - window_rect.left;
            const height = window_rect.bottom - window_rect.top;

            CHECK(app.d2d_factory.ID2D1Factory_CreateHwndRenderTarget(
                &std.mem.zeroes(direct2d.D2D1_RENDER_TARGET_PROPERTIES),
                &.{
                    .hwnd = handle,
                    .pixelSize = direct2d.common.D2D_SIZE_U{ .width = @intCast(width), .height = @intCast(height) },
                    .presentOptions = direct2d.D2D1_PRESENT_OPTIONS_NONE,
                },
                @ptrCast(&app.d2d_render_target),
            )) catch return 1;
            return 0;
        },
        w32.ui.windows_and_messaging.WM_DPICHANGED => {
            std.log.info("WM_DPICHANGED", .{});
            const app = app_opt orelse return 0;
            std.debug.print("dpi changed event, wparam = {x}, lparam = {x}\n", .{ wparam, lparam });

            app.window_current_dpi = @truncate(wparam);

            var window_rect = std.mem.zeroes(w32.foundation.RECT);
            CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(handle, &window_rect)) catch return 1;
            CHECK_BOOL(w32.graphics.gdi.InvalidateRect(handle, &window_rect, FALSE)) catch return 1;

            const window_rect_new: *const w32.foundation.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
            const x = window_rect_new.left;
            const y = window_rect_new.top;
            const width = window_rect_new.right - x;
            const height = window_rect_new.bottom - y;

            std.debug.print("x = {}, y = {}, w = {}, h = {}\n", .{ x, y, width, height });

            CHECK_BOOL(w32.ui.windows_and_messaging.SetWindowPos(handle, null, x, y, width, height, .{ .NOZORDER = 1, .NOACTIVATE = 1 })) catch return 1;

            _ = centerWindow(handle);

            return 0;
        },
        w32.ui.windows_and_messaging.WM_PAINT => {
            // std.log.info("WM_PAINT", .{});
            const app = app_opt orelse return 0;
            const render_target = app.d2d_render_target;

            const hello_world = w32.zig.L("Hello, World!");

            render_target.ID2D1RenderTarget_BeginDraw();
            defer _ = render_target.ID2D1RenderTarget_EndDraw(null, null);

            _ = render_target.ID2D1RenderTarget_SetTransform(&identity);

            _ = render_target.ID2D1RenderTarget_Clear(&white);

            _ = render_target.ID2D1RenderTarget_DrawRectangle(
                &.{ .left = 10, .right = 100, .top = 10, .bottom = 100 },
                @ptrCast(app.d2d_brush_black),
                1.0,
                null,
            );

            _ = render_target.ID2D1RenderTarget_DrawBitmap(
                app.d2d_bitmap_logo,
                // &.{ .left = 110, .right = 200, .top = 10, .bottom = 100 },
                null,
                1,
                .LINEAR,
                null,
            );

            _ = render_target.ID2D1RenderTarget_DrawText(
                hello_world,
                hello_world.len,
                app.text_format,
                &direct2d.common.D2D_RECT_F{ .left = 100, .top = 100, .right = 200, .bottom = 200 },
                @ptrCast(app.d2d_brush_black),
                direct2d.D2D1_DRAW_TEXT_OPTIONS_NONE,
                w32.graphics.direct_write.DWRITE_MEASURING_MODE_NATURAL,
            );

            return 0;
        },
        w32.ui.windows_and_messaging.WM_COMMAND => {
            std.log.info("WM_COMMAND", .{});
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const h_instance = w32.system.library_loader.GetModuleHandleW(null) orelse return 1;

    try App.register(h_instance);

    const app = try App.create(h_instance, gpa.allocator());
    defer app.destroy();

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
    return switch (result) {
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
}

fn CHECK_UNWRAP(result: w32.foundation.HRESULT) !w32.foundation.HRESULT {
    try CHECK(result);
    return result;
}

fn CHECK_BOOL(result: w32.foundation.BOOL) !void {
    if (result == TRUE) return;
    const err = w32.foundation.GetLastError();

    const err_name = @tagName(err);
    std.log.err("Win32 Error encountered: {s}", .{err_name});

    return error.Unknown;
}

fn SafeRelease(interface: anytype) void {
    if (interface.* != null) {
        _ = interface.*.?.IUnknown_Release();
        interface.* = null;
    }
}

fn mulDiv(pixels: u32, current_dpi: u32, reference_dpi: u32) u32 {
    const scaled = pixels * current_dpi;
    return scaled / reference_dpi;
}

const Func_GetDpiForMonitor = *const fn (w32.graphics.gdi.HMONITOR, c_int, *c_uint, *c_uint) w32.foundation.HRESULT;

fn GetWindowDPI(hwnd: w32.foundation.HWND) u32 {
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
fn loadPNGAsGdiplusBitmap(
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

    const stream = stream: {
        var stream_opt: ?*imaging.IWICStream = null;
        CHECK(iwic_factory.IWICImagingFactory_CreateStream(&stream_opt)) catch
            return error.CouldNotCreateStream;
        break :stream stream_opt orelse return error.CouldNotCreateStream;
    };

    CHECK(stream.IWICStream_InitializeFromMemory(@ptrCast(resource), size)) catch
        return error.CouldNotInitializeStreamFromMemory;

    const decoder = decoder: {
        var decoder_opt: ?*imaging.IWICBitmapDecoder = null;
        CHECK(iwic_factory.IWICImagingFactory_CreateDecoderFromStream(
            @ptrCast(stream),
            null,
            imaging.WICDecodeMetadataCacheOnLoad,
            &decoder_opt,
        )) catch
            return error.CouldNotCreateDecoder;
        break :decoder decoder_opt orelse return error.CouldNotCreateDecoder;
    };

    const source = source: {
        var source_opt: ?*imaging.IWICBitmapSource = null;
        CHECK(decoder.IWICBitmapDecoder_GetFrame(0, @ptrCast(&source_opt))) catch
            return error.CouldNotGetFrame;
        break :source source_opt orelse return error.CouldNotGetFrame;
    };

    const converter = converter: {
        var converter_opt: ?*imaging.IWICFormatConverter = null;
        // Convert Image format to 32bppPBGRA
        // (DXGI_FORMAT_B8G8R8A8_UNORM + D2D1_ALPHA_MODE_PREMULTIPLIED)
        // In English: converts the image to 32bit with premultiplied alpha
        CHECK(iwic_factory.IWICImagingFactory_CreateFormatConverter(&converter_opt)) catch
            return error.CouldNotCreateFormatConverter;
        break :converter converter_opt orelse return error.CouldNotCreateFormatConverter;
    };

    var pixel_format: w32.zig.Guid = imaging.GUID_WICPixelFormat32bppPBGRA;

    // Initialize the converter
    CHECK(converter.IWICFormatConverter_Initialize(
        source,
        &pixel_format,
        .itmapDitherTypeNone, // TODO: report typo
        null,
        0,
        .itmapPaletteTypeMedianCut,
    )) catch
        return error.CouldNotInitializeConverter;

    // Create a D3D bitmap from the WIC bitmap
    const bitmap = bitmap: {
        var bitmap_opt: ?*direct2d.ID2D1Bitmap = null;
        CHECK(render_target.ID2D1RenderTarget_CreateBitmapFromWicBitmap(@ptrCast(converter), null, &bitmap_opt)) catch
            return error.CouldNotCreateD2DBitmap;
        break :bitmap bitmap_opt orelse return error.CouldNotCreateD2DBitmap;
    };

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
