/// # Lizard Wizard App Template
///
/// The Lizard Wizard App Template is a customizable Win32 install wizard meant to be used on
/// disks as an autorun application.
///
/// Inspired by and loosely based on the "Writing a Wizard like it's 2020" series of articles,
/// available at https://building.enlyze.com/posts/writing-win32-apps-like-its-2020-part-1/
///
/// ## Configuration
///

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
    const unified_control_padding = 10;
    const button_width = 90;
    const button_height = 23;
};

const TRUE: w32.foundation.BOOL = 1;
const FALSE: w32.foundation.BOOL = 0;

const RES = @cImport({
    @cInclude("resource.h");
});

const CommandID = enum(c_int) {
    back = 500,
    next = 501,
    cancel = 502,
    _,
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

    try CHECK(w32.system.com.CoInitialize(null));

    const app = try App.create(h_instance, gpa.allocator());
    defer app.destroy(gpa.allocator());

    try app.run();

    return 0;
}

const App = struct {
    hwnd: w32.foundation.HWND,
    h_instance: w32.foundation.HINSTANCE,
    allocator: std.mem.Allocator,

    window_current_dpi: i32 = 0,

    hwnd_line: w32.foundation.HWND,
    btn_back: w32.foundation.HWND,
    btn_next: w32.foundation.HWND,
    btn_cancel: w32.foundation.HWND,

    font_attr_gui: w32.graphics.gdi.LOGFONTW,
    font_attr_gui_bold: w32.graphics.gdi.LOGFONTW,
    font_gui: w32.graphics.gdi.HFONT,
    font_gui_bold: w32.graphics.gdi.HFONT,

    str_header: []const u16,
    str_subheader: []const u16,
    str_back: [*:0]const u16,
    str_next: [*:0]const u16,
    str_cancel: [*:0]const u16,

    bmp_logo: *gdip.Bitmap,

    page_current: *Page,
    page_one: *PageOne,
    page_two: *PageTwo,

    const class_name = w32.zig.L("GameDisk");
    const window_title = w32.zig.L("Hello from zig"); // Title

    fn create(h_instance: w32.foundation.HINSTANCE, allocator: std.mem.Allocator) !*App {
        const WAM = w32.ui.windows_and_messaging;

        const app_icon = WAM.LoadIconW(h_instance, @ptrFromInt(RES.IDI_ICON));

        const window_class = w32.ui.windows_and_messaging.WNDCLASSW{
            .style = w32.ui.windows_and_messaging.WNDCLASS_STYLES{
                .HREDRAW = 1,
                .VREDRAW = 1,
            },
            .lpfnWndProc = GetWndProcForType(App),
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

        self.allocator = allocator;
        self.h_instance = h_instance;

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

    fn set_header(app: *App, text_header: []const u16, text_subheader: []const u16) void {
        app.str_header = text_header;
        app.str_subheader = text_subheader;

        // Redraw the header.
        var rect_header = std.mem.zeroes(w32.foundation.RECT);
        CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(app.hwnd, &rect_header)) catch return;
        rect_header.bottom = mulDiv(Conf.header_height, app.window_current_dpi, Conf.reference_dpi);
        _ = w32.graphics.gdi.InvalidateRect(app.hwnd, &rect_header, FALSE);
    }

    fn enable_back_button(app: *App, is_enabled: bool) void {
        _ = w32.ui.input.keyboard_and_mouse.EnableWindow(app.btn_back, if (is_enabled) TRUE else FALSE);
    }

    fn enable_next_button(app: *App, is_enabled: bool) void {
        _ = w32.ui.input.keyboard_and_mouse.EnableWindow(app.btn_next, if (is_enabled) TRUE else FALSE);
    }

    fn SwitchPage(app: *App, new_page: *Page) void {
        app.page_current = new_page;
        _ = w32.ui.windows_and_messaging.ShowWindow(app.page_one.page.GetHWND(&app.page_one.page), .{});
        _ = w32.ui.windows_and_messaging.ShowWindow(app.page_two.page.GetHWND(&app.page_two.page), .{});
        new_page.SwitchTo(new_page);
    }

    fn destroy(app: *App, allocator: std.mem.Allocator) void {
        allocator.destroy(app);
    }

    fn run(app: *App) !void {
        var msg = std.mem.zeroes(w32.ui.windows_and_messaging.MSG);
        while (true) {
            const ret = w32.ui.windows_and_messaging.GetMessageW(&msg, null, 0, 0);
            if (ret > 0) {
                _ = w32.ui.windows_and_messaging.TranslateMessage(&msg);
                _ = w32.ui.windows_and_messaging.DispatchMessageW(&msg);
            } else if (ret == 0) {
                return;
            } else {
                const err = w32.foundation.GetLastError();
                const string = std.fmt.allocPrint(app.allocator, "GetMessageW failed, last error is {}", .{err}) catch return;
                defer app.allocator.free(string);
                const wstring = std.unicode.utf8ToUtf16LeAllocZ(app.allocator, string) catch return;
                defer app.allocator.free(wstring);
                _ = w32.ui.windows_and_messaging.MessageBoxW(null, wstring, window_title, .{ .ICONHAND = TRUE });
                return error.Unknown;
            }
        }
    }

    // Callbacks
    const WPARAM = w32.foundation.WPARAM;
    const LPARAM = w32.foundation.LPARAM;

    fn OnCommand(app: *App, wparam: WPARAM) !void {
        std.log.info("WM_COMMAND", .{});
        const value: c_uint = @truncate(wparam);
        const id: CommandID = @enumFromInt(value);
        switch (id) {
            .back => {
                if (app.page_current == &app.page_two.page) {
                    app.SwitchPage(&app.page_one.page);
                }
            },
            .next => {
                if (app.page_current == &app.page_one.page) {
                    app.SwitchPage(&app.page_two.page);
                }
            },
            .cancel => {
                _ = w32.ui.windows_and_messaging.DestroyWindow(app.hwnd);
            },
            _ => {},
        }
    }

    fn OnCreate(app: *App) !void {
        std.log.info("WM_CREATE", .{});
        // Fields other than hwnd and allocator are currently undefined, do not use them
        const hwnd = app.hwnd;
        const allocator = app.allocator;
        const h_instance = app.h_instance;

        // Get the DPI for the monitor where the window is shown
        const dpi = GetWindowDPI(hwnd);

        // Load resources
        const bitmap_logo = try loadPNGAsGdiplusBitmap(allocator, h_instance, RES.IDP_LOGO);

        // Query what the default system font is
        var ncm = std.mem.zeroes(w32.ui.windows_and_messaging.NONCLIENTMETRICSW);
        ncm.cbSize = @sizeOf(w32.ui.windows_and_messaging.NONCLIENTMETRICSW);
        _ = w32.ui.windows_and_messaging.SystemParametersInfoW(w32.ui.windows_and_messaging.SPI_GETNONCLIENTMETRICS, ncm.cbSize, &ncm, .{});

        var font_attr_gui = ncm.lfMessageFont;

        const gdi_font_gui = w32.graphics.gdi.CreateFontIndirectW(&font_attr_gui) orelse return error.InitGDIFont;

        var font_attr_gui_bold = font_attr_gui;
        font_attr_gui_bold.lfWeight = w32.graphics.gdi.FW_BOLD;

        const gdi_font_gui_bold = w32.graphics.gdi.CreateFontIndirectW(&font_attr_gui_bold) orelse return error.InitGDIFontBold;

        const empty_str = w32.zig.L("");
        // TODO: report lack of L for class names
        const WC_STATIC = w32.zig.L("Static");
        const WC_BUTTON = w32.zig.L("Button");

        // Create the line above the buttons
        const hwnd_line = w32.ui.windows_and_messaging.CreateWindowExW(
            .{},
            @ptrCast(WC_STATIC),
            empty_str,
            .{ .CHILD = 1, .VISIBLE = 1, ._12 = 1 }, // ._12 is the bit for the SS_SUNKEN style
            0,
            0,
            0,
            0,
            hwnd,
            null,
            null,
            null,
        ) orelse
            return error.CreateLine;

        // Create the bottom buttons
        const str_back = Resource.stringLoad(allocator, h_instance, RES.IDS_BACK) orelse return error.LoadString;
        const hwnd_back = w32.ui.windows_and_messaging.CreateWindowExW(
            .{},
            @ptrCast(WC_BUTTON),
            str_back,
            .{ .CHILD = 1, .VISIBLE = 1, .DISABLED = 1 },
            0,
            0,
            0,
            0,
            hwnd,
            @ptrFromInt(@intFromEnum(CommandID.back)),
            null,
            null,
        ) orelse
            return error.CreateBack;
        _ = w32.ui.windows_and_messaging.SendMessageW(hwnd_back, w32.ui.windows_and_messaging.WM_SETFONT, @intFromPtr(gdi_font_gui), @intCast(TRUE));

        const str_next = Resource.stringLoad(allocator, h_instance, RES.IDS_NEXT) orelse return error.LoadString;
        const hwnd_next = w32.ui.windows_and_messaging.CreateWindowExW(
            .{},
            @ptrCast(WC_BUTTON),
            str_next,
            .{ .CHILD = 1, .VISIBLE = 1, .DISABLED = 1 },
            0,
            0,
            0,
            0,
            hwnd,
            @ptrFromInt(@intFromEnum(CommandID.next)),
            null,
            null,
        ) orelse
            return error.CreateNext;
        _ = w32.ui.windows_and_messaging.SendMessageW(hwnd_next, w32.ui.windows_and_messaging.WM_SETFONT, @intFromPtr(gdi_font_gui), @intCast(TRUE));

        const str_cancel = Resource.stringLoad(allocator, h_instance, RES.IDS_CANCEL) orelse return error.LoadString;
        const hwnd_cancel = w32.ui.windows_and_messaging.CreateWindowExW(
            .{},
            @ptrCast(WC_BUTTON),
            str_cancel,
            .{ .CHILD = 1, .VISIBLE = 1 },
            0,
            0,
            0,
            0,
            hwnd,
            @ptrFromInt(@intFromEnum(CommandID.cancel)),
            null,
            null,
        ) orelse
            return error.CreateBack;
        _ = w32.ui.windows_and_messaging.SendMessageW(hwnd_cancel, w32.ui.windows_and_messaging.WM_SETFONT, @intFromPtr(gdi_font_gui), @intCast(TRUE));

        app.* = .{
            .h_instance = h_instance,
            .hwnd = hwnd,
            .allocator = allocator,
            .window_current_dpi = dpi,

            .font_attr_gui = font_attr_gui,
            .font_attr_gui_bold = font_attr_gui_bold,
            .font_gui = gdi_font_gui,
            .font_gui_bold = gdi_font_gui_bold,

            .hwnd_line = hwnd_line,
            .btn_back = hwnd_back,
            .btn_next = hwnd_next,
            .btn_cancel = hwnd_cancel,

            .str_header = w32.zig.L("Header"),
            .str_subheader = w32.zig.L("Subheader"),
            .str_back = str_back,
            .str_next = str_next,
            .str_cancel = str_cancel,

            .bmp_logo = bitmap_logo,

            .page_one = try PageOne.create(app),
            .page_two = try PageTwo.create(app),
            .page_current = &app.page_one.page,
        };

        // TODO: Create all pages
        app.SwitchPage(&app.page_one.page);

        // Set the main window size
        const dpif: f32 = @floatFromInt(app.window_current_dpi);
        const width: i32 = @intFromFloat(Conf.window_min_width * (dpif / 96.0));
        const height: i32 = @intFromFloat(Conf.window_min_height * (dpif / 96.0));
        try CHECK_BOOL(w32.ui.windows_and_messaging.SetWindowPos(hwnd, null, 0, 0, width, height, .{ .NOMOVE = TRUE }));

        // Show the window
        _ = w32.ui.windows_and_messaging.ShowWindow(hwnd, .{ .SHOWNORMAL = TRUE });
    }

    fn OnDestroy(app: *App) !void {
        std.log.info("WM_DESTROY", .{});
        w32.ui.windows_and_messaging.PostQuitMessage(0);
        app.allocator.free(std.mem.span(app.str_next));
        app.allocator.free(std.mem.span(app.str_back));
        app.allocator.free(std.mem.span(app.str_cancel));
    }

    fn OnDpiChanged(app: *App, wparam: WPARAM, lparam: LPARAM) !void {
        std.log.info("WM_DPICHANGED", .{});

        // New DPI is stores in the lower bits of wparam
        app.window_current_dpi = @truncate(@as(isize, @intCast(wparam)));

        // Redraw the entire window on every DPI change
        try CHECK_BOOL(w32.graphics.gdi.InvalidateRect(app.hwnd, null, FALSE));

        // Recalculate the main GUI font
        app.font_attr_gui.lfHeight = -mulDiv(10, app.window_current_dpi, Conf.reference_dpi);
        app.font_gui = w32.graphics.gdi.CreateFontIndirectW(&app.font_attr_gui) orelse return error.CreateFont;

        // Recalculate the bold GUI font
        app.font_attr_gui_bold.lfHeight = app.font_attr_gui.lfHeight;
        app.font_gui_bold = w32.graphics.gdi.CreateFontIndirectW(&app.font_attr_gui_bold) orelse return error.CreateFont;

        // Update the control fonts
        _ = (w32.ui.windows_and_messaging.SendMessageW(app.btn_back, w32.ui.windows_and_messaging.WM_SETFONT, @intFromPtr(app.font_gui), @intCast(TRUE)));
        _ = (w32.ui.windows_and_messaging.SendMessageW(app.btn_next, w32.ui.windows_and_messaging.WM_SETFONT, @intFromPtr(app.font_gui), @intCast(TRUE)));
        _ = (w32.ui.windows_and_messaging.SendMessageW(app.btn_cancel, w32.ui.windows_and_messaging.WM_SETFONT, @intFromPtr(app.font_gui), @intCast(TRUE)));

        // Update DPI for child windows
        app.page_one.page.UpdateDPI(&app.page_one.page);
        app.page_two.page.UpdateDPI(&app.page_two.page);

        // Use the suggested new window size
        const window_rect_new: *const w32.foundation.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
        const x = window_rect_new.left;
        const y = window_rect_new.top;
        const width = window_rect_new.right - x;
        const height = window_rect_new.bottom - y;
        try CHECK_BOOL(w32.ui.windows_and_messaging.SetWindowPos(app.hwnd, null, x, y, width, height, .{ .NOZORDER = 1, .NOACTIVATE = 1 }));
    }

    fn OnGetMinMaxInfo(app: *App, lparam: LPARAM) !void {
        std.log.info("WM_GETMINMAXINFO", .{});
        const min_max_info: *w32.ui.windows_and_messaging.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));

        min_max_info.ptMinTrackSize.x = mulDiv(Conf.window_min_width, app.window_current_dpi, Conf.reference_dpi);
        min_max_info.ptMinTrackSize.y = mulDiv(Conf.window_min_height, app.window_current_dpi, Conf.reference_dpi);
        std.log.info("min x: {}, min y: {}", .{ min_max_info.ptMinTrackSize.x, min_max_info.ptMinTrackSize.y });
    }

    fn OnPaint(app: *App) !void {
        // Get window rect
        var rect_window: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(app.hwnd, &rect_window));

        const white_brush: w32.graphics.gdi.HBRUSH = @ptrCast(w32.graphics.gdi.GetStockObject(w32.graphics.gdi.WHITE_BRUSH));

        // Begin double-buffered paint
        var paint = std.mem.zeroes(w32.graphics.gdi.PAINTSTRUCT);
        const dc = w32.graphics.gdi.BeginPaint(app.hwnd, &paint);
        defer _ = w32.graphics.gdi.EndPaint(app.hwnd, &paint);

        const dc_mem = w32.graphics.gdi.CreateCompatibleDC(dc);
        defer _ = w32.graphics.gdi.DeleteDC(dc_mem);

        const bitmap_mem = w32.graphics.gdi.CreateCompatibleBitmap(dc, rect_window.right, rect_window.bottom);
        defer _ = w32.graphics.gdi.DeleteObject(bitmap_mem);

        _ = w32.graphics.gdi.SelectObject(dc_mem, bitmap_mem);

        // Draw a white rectangle completely filling the header of the window.
        var rect_header = rect_window;
        rect_header.bottom = mulDiv(Conf.header_height, app.window_current_dpi, Conf.reference_dpi);
        _ = w32.graphics.gdi.FillRect(dc_mem, &rect_header, white_brush);

        // Draw the header text
        var rect_header_text = rect_header;
        rect_header_text.left = mulDiv(15, app.window_current_dpi, Conf.reference_dpi);
        rect_header_text.top = mulDiv(15, app.window_current_dpi, Conf.reference_dpi);
        _ = w32.graphics.gdi.SelectObject(dc_mem, app.font_gui_bold);
        _ = w32.graphics.gdi.DrawTextW(dc_mem, @ptrCast(app.str_header.ptr), @intCast(app.str_header.len), &rect_header_text, .{});

        // Draw the subheader text
        var rect_subheader_text = rect_header;
        rect_subheader_text.left = mulDiv(20, app.window_current_dpi, Conf.reference_dpi);
        rect_subheader_text.top = mulDiv(32, app.window_current_dpi, Conf.reference_dpi);
        _ = w32.graphics.gdi.SelectObject(dc_mem, app.font_gui);
        _ = w32.graphics.gdi.DrawTextW(dc_mem, @ptrCast(app.str_subheader.ptr), @intCast(app.str_subheader.len), &rect_subheader_text, .{});

        // Draw logo in upper right corner
        const logo_padding = mulDiv(5, app.window_current_dpi, Conf.reference_dpi);
        const dest_bitmap_height = rect_header.bottom - 2 * logo_padding;
        const dest_bitmap_width = @divFloor(@as(i32, @intCast(app.bmp_logo.GetWidth())) * dest_bitmap_height, @as(i32, @intCast(app.bmp_logo.GetHeight())));
        const dest_bitmap_x = rect_window.right - logo_padding - dest_bitmap_width;
        const dest_bitmap_y = logo_padding;

        const graphics = gdip.GpGraphics.CreateFromHDC(dc_mem) orelse return error.CreateGdipGraphics;
        graphics.DrawImageRectI(@ptrCast(app.bmp_logo), dest_bitmap_x, dest_bitmap_y, dest_bitmap_width, dest_bitmap_height);

        // Fill the rest of the window with the window background color.
        var rect_background = rect_window;
        rect_background.top = rect_header.bottom;
        _ = w32.graphics.gdi.FillRect(dc_mem, &rect_background, w32.graphics.gdi.GetSysColorBrush(@intFromEnum(w32.ui.windows_and_messaging.COLOR_BTNFACE)));

        _ = w32.graphics.gdi.BitBlt(dc, 0, 0, rect_window.right, rect_window.bottom, dc_mem, 0, 0, w32.graphics.gdi.SRCCOPY);
    }

    fn OnSize(app: *App) !void {
        std.log.info("WM_SIZE", .{});

        // Get window size
        var rect_window: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(app.hwnd, &rect_window));

        // Redraw header on every size change
        var rect_header = rect_window;
        rect_header.bottom = mulDiv(Conf.header_height, app.window_current_dpi, Conf.reference_dpi);
        _ = w32.graphics.gdi.InvalidateRect(app.hwnd, &rect_header, FALSE);

        // Update subwindow positions
        {
            // Move the buttons
            var hdwp = w32.ui.windows_and_messaging.BeginDeferWindowPos(6);
            if (hdwp == 0) return error.BeginDeferringWindowPos;
            defer _ = w32.ui.windows_and_messaging.EndDeferWindowPos(hdwp);

            const control_padding = mulDiv(Conf.unified_control_padding, app.window_current_dpi, Conf.reference_dpi);
            const button_height = mulDiv(Conf.button_height, app.window_current_dpi, Conf.reference_dpi);
            const button_width = mulDiv(Conf.button_width, app.window_current_dpi, Conf.reference_dpi);

            var button_x = rect_window.right - control_padding - button_width;
            const button_y = rect_window.bottom - control_padding - button_height;

            hdwp = w32.ui.windows_and_messaging.DeferWindowPos(hdwp, app.btn_cancel, null, button_x, button_y, button_width, button_height, .{});
            if (hdwp == 0) return error.DeferWindowPos;

            button_x = button_x - control_padding - button_width;
            hdwp = w32.ui.windows_and_messaging.DeferWindowPos(hdwp, app.btn_next, null, button_x, button_y, button_width, button_height, .{});
            if (hdwp == 0) return error.DeferWindowPos;

            button_x = button_x - button_width;
            hdwp = w32.ui.windows_and_messaging.DeferWindowPos(hdwp, app.btn_back, null, button_x, button_y, button_width, button_height, .{});
            if (hdwp == 0) return error.DeferWindowPos;

            // Move the line above the buttons
            const line_height = 2;
            const line_width = rect_window.right;
            const line_x = 0;
            const line_y = button_y - control_padding;

            hdwp = w32.ui.windows_and_messaging.DeferWindowPos(hdwp, app.hwnd_line, null, line_x, line_y, line_width, line_height, .{});
            if (hdwp == 0) return error.DeferWindowPos;

            // Move all page windows
            const page_x = control_padding;
            const page_y = rect_header.bottom + control_padding;
            const page_height = line_y - page_y - control_padding;
            const page_width = rect_window.right - page_x - control_padding;

            hdwp = w32.ui.windows_and_messaging.DeferWindowPos(hdwp, app.page_one.hwnd, null, page_x, page_y, page_width, page_height, .{});
            hdwp = w32.ui.windows_and_messaging.DeferWindowPos(hdwp, app.page_two.hwnd, null, page_x, page_y, page_width, page_height, .{});
            if (hdwp == 0) return error.DeferWindowPos;
        }
    }
};

const Page = struct {
    GetHWND: *const fn (*Page) w32.foundation.HWND,
    SwitchTo: *const fn (*Page) void,
    UpdateDPI: *const fn (*Page) void,

    fn FromStruct(comptime T: type) Page {
        return .{
            .GetHWND = &T.GetHWND,
            .SwitchTo = &T.SwitchTo,
            .UpdateDPI = &T.UpdateDPI,
        };
    }
};

const PageOne = struct {
    page: Page,
    hwnd: w32.foundation.HWND,
    main_window: *App,
    str_header: [:0]const u16,
    str_subheader: [:0]const u16,
    str_text: [:0]const u16,

    const class_name = w32.zig.L("PageOneWndClass");

    fn create(main_window: *App) !*PageOne {
        const WAM = w32.ui.windows_and_messaging;

        const window_class = w32.ui.windows_and_messaging.WNDCLASSW{
            .style = w32.ui.windows_and_messaging.WNDCLASS_STYLES{
                .HREDRAW = 1,
                .VREDRAW = 1,
            },
            .lpfnWndProc = GetWndProcForType(PageOne),
            .hInstance = main_window.h_instance,
            .hCursor = WAM.LoadCursorW(null, WAM.IDI_APPLICATION),
            .hIcon = null,
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

        const self = try main_window.allocator.create(PageOne);
        errdefer main_window.allocator.destroy(self);

        self.page = Page.FromStruct(PageOne);
        self.main_window = main_window;

        // Create window
        const hwnd = w32.ui.windows_and_messaging.CreateWindowExW(
            .{},
            @ptrFromInt(class_atom),
            w32.zig.L(""),
            w32.ui.windows_and_messaging.WINDOW_STYLE{
                .CHILD = TRUE,
                .CLIPCHILDREN = TRUE,
                .CLIPSIBLINGS = TRUE,
            },
            0,
            0,
            0,
            0,
            main_window.hwnd,
            null,
            main_window.h_instance,
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

    fn GetHWND(page: *Page) w32.foundation.HWND {
        const page_one: *PageOne = @fieldParentPtr("page", page);
        return page_one.hwnd;
    }

    fn SwitchTo(page: *Page) void {
        const page_one: *PageOne = @fieldParentPtr("page", page);
        page_one.main_window.set_header(page_one.str_header, page_one.str_subheader);
        page_one.main_window.enable_back_button(false);
        page_one.main_window.enable_next_button(true);
        _ = w32.ui.windows_and_messaging.ShowWindow(page_one.hwnd, .{ .SHOWNORMAL = TRUE });
    }

    fn UpdateDPI(page: *Page) void {
        const page_one: *PageOne = @fieldParentPtr("page", page);
        _ = page_one;
    }

    fn OnCreate(page_one: *PageOne) !void {
        page_one.* = .{
            .page = page_one.page,
            .hwnd = page_one.hwnd,
            .main_window = page_one.main_window,
            .str_header = Resource.stringLoad(page_one.main_window.allocator, page_one.main_window.h_instance, RES.IDS_FIRSTPAGE_HEADER) orelse return error.StringLoadError,
            .str_subheader = Resource.stringLoad(page_one.main_window.allocator, page_one.main_window.h_instance, RES.IDS_FIRSTPAGE_SUBHEADER) orelse return error.StringLoadError,
            .str_text = Resource.stringLoad(page_one.main_window.allocator, page_one.main_window.h_instance, RES.IDS_FIRSTPAGE_TEXT) orelse return error.StringLoadError,
        };
    }

    fn OnDestroy(page_one: *PageOne) !void {
        page_one.main_window.allocator.free(page_one.str_header);
        page_one.main_window.allocator.free(page_one.str_subheader);
        page_one.main_window.allocator.free(page_one.str_text);
        page_one.main_window.allocator.destroy(page_one);
    }

    fn OnPaint(page_one: *PageOne) !void {
        // Get window rect
        var rect_window: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(page_one.hwnd, &rect_window));

        // Begin double-buffered paint
        var paint = std.mem.zeroes(w32.graphics.gdi.PAINTSTRUCT);
        const dc = w32.graphics.gdi.BeginPaint(page_one.hwnd, &paint);
        defer _ = w32.graphics.gdi.EndPaint(page_one.hwnd, &paint);

        const dc_mem = w32.graphics.gdi.CreateCompatibleDC(dc);
        defer _ = w32.graphics.gdi.DeleteDC(dc_mem);

        const bitmap_mem = w32.graphics.gdi.CreateCompatibleBitmap(dc, rect_window.right, rect_window.bottom);
        defer _ = w32.graphics.gdi.DeleteObject(bitmap_mem);

        _ = w32.graphics.gdi.SelectObject(dc_mem, bitmap_mem);

        // Fill the window with the background color.
        _ = w32.graphics.gdi.FillRect(dc_mem, &rect_window, w32.graphics.gdi.GetSysColorBrush(@intFromEnum(w32.ui.windows_and_messaging.COLOR_BTNFACE)));

        // Draw the intro text.
        _ = w32.graphics.gdi.SelectObject(dc_mem, page_one.main_window.font_gui);
        _ = w32.graphics.gdi.SetBkColor(dc_mem, w32.ui.windows_and_messaging.GetSysColor(w32.ui.windows_and_messaging.COLOR_BTNFACE));
        _ = w32.graphics.gdi.DrawTextW(dc_mem, @ptrCast(page_one.str_text.ptr), @intCast(page_one.str_text.len), &rect_window, .{ .WORDBREAK = TRUE });

        _ = w32.graphics.gdi.BitBlt(dc, 0, 0, rect_window.right, rect_window.bottom, dc_mem, 0, 0, w32.graphics.gdi.SRCCOPY);
    }

    fn OnSize(page_one: *PageOne) !void {
        _ = w32.graphics.gdi.InvalidateRect(page_one.hwnd, null, FALSE);
    }
};

const PageTwo = struct {
    page: Page,
    hwnd: w32.foundation.HWND,
    main_window: *App,
    str_header: [:0]const u16,
    str_subheader: [:0]const u16,
    hwnd_list: w32.foundation.HWND,

    const class_name = w32.zig.L("PageTwoWndClass");

    fn create(main_window: *App) !*PageTwo {
        const WAM = w32.ui.windows_and_messaging;

        const window_class = w32.ui.windows_and_messaging.WNDCLASSW{
            .style = w32.ui.windows_and_messaging.WNDCLASS_STYLES{
                .HREDRAW = 1,
                .VREDRAW = 1,
            },
            .lpfnWndProc = GetWndProcForType(PageTwo),
            .hInstance = main_window.h_instance,
            .hCursor = WAM.LoadCursorW(null, WAM.IDI_APPLICATION),
            .hIcon = null,
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

        const self = try main_window.allocator.create(PageTwo);
        errdefer main_window.allocator.destroy(self);

        self.page = Page.FromStruct(PageTwo);
        self.main_window = main_window;

        // Create window
        const hwnd = w32.ui.windows_and_messaging.CreateWindowExW(
            .{},
            @ptrFromInt(class_atom),
            w32.zig.L(""),
            w32.ui.windows_and_messaging.WINDOW_STYLE{
                .CHILD = TRUE,
                .CLIPCHILDREN = TRUE,
                .CLIPSIBLINGS = TRUE,
            },
            0,
            0,
            0,
            0,
            main_window.hwnd,
            null,
            main_window.h_instance,
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

    fn GetHWND(page: *Page) w32.foundation.HWND {
        const page_two: *PageTwo = @fieldParentPtr("page", page);
        return page_two.hwnd;
    }

    fn SwitchTo(page: *Page) void {
        const page_two: *PageTwo = @fieldParentPtr("page", page);
        page_two.main_window.set_header(page_two.str_header, page_two.str_subheader);
        page_two.main_window.enable_back_button(true);
        page_two.main_window.enable_next_button(false);
        _ = w32.ui.windows_and_messaging.ShowWindow(page_two.hwnd, .{ .SHOWNORMAL = TRUE });
    }

    fn UpdateDPI(page: *Page) void {
        const page_two: *PageTwo = @fieldParentPtr("page", page);
        _ = page_two;
    }

    fn OnCreate(page_two: *PageTwo) !void {
        const list_view = w32.ui.windows_and_messaging.CreateWindowExW(
            .{ .CLIENTEDGE = 1 },
            w32.zig.L("SysListView32"),
            w32.zig.L(""),
            .{
                .CHILD = 1,
                .VISIBLE = 1,
                .ACTIVECAPTION = 1, // LVS_REPORT
                ._2 = 1, // LVS_SINGLESEL
            },
            0,
            0,
            0,
            0,
            page_two.hwnd,
            null,
            null,
            null,
        ) orelse return error.CreateListView;

        _ = w32.ui.windows_and_messaging.SendMessageW(
            list_view,
            w32.ui.controls.LVM_SETEXTENDEDLISTVIEWSTYLE,
            w32.ui.controls.LVS_EX_DOUBLEBUFFER | w32.ui.controls.LVS_EX_FULLROWSELECT,
            w32.ui.controls.LVS_EX_DOUBLEBUFFER | w32.ui.controls.LVS_EX_FULLROWSELECT,
        );

        var column = std.mem.zeroes(w32.ui.controls.LVCOLUMNW);
        column.mask = .{ .TEXT = 1 };

        const wstr_column = Resource.stringLoad(page_two.main_window.allocator, page_two.main_window.h_instance, RES.IDS_COLUMN1) orelse return error.StringLoadError;
        column.pszText = @constCast(wstr_column.ptr);
        _ = w32.ui.windows_and_messaging.SendMessageW(
            list_view,
            w32.ui.controls.LVM_INSERTCOLUMNW,
            0,
            @intCast(@intFromPtr(&column)),
        );

        const wstr_column2 = Resource.stringLoad(page_two.main_window.allocator, page_two.main_window.h_instance, RES.IDS_COLUMN2) orelse return error.StringLoadError;
        column.pszText = @constCast(wstr_column2.ptr);
        _ = w32.ui.windows_and_messaging.SendMessageW(
            list_view,
            w32.ui.controls.LVM_INSERTCOLUMNW,
            1,
            @intCast(@intFromPtr(&column)),
        );

        page_two.* = .{
            .page = page_two.page,
            .hwnd = page_two.hwnd,
            .main_window = page_two.main_window,
            .str_header = Resource.stringLoad(page_two.main_window.allocator, page_two.main_window.h_instance, RES.IDS_SECONDPAGE_HEADER) orelse return error.StringLoadError,
            .str_subheader = Resource.stringLoad(page_two.main_window.allocator, page_two.main_window.h_instance, RES.IDS_SECONDPAGE_SUBHEADER) orelse return error.StringLoadError,
            .hwnd_list = list_view,
        };
    }

    fn OnDestroy(page_two: *PageTwo) !void {
        page_two.main_window.allocator.free(page_two.str_header);
        page_two.main_window.allocator.free(page_two.str_subheader);
        page_two.main_window.allocator.destroy(page_two);
    }

    fn OnSize(page_two: *PageTwo) !void {
        var rect_window: w32.foundation.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        try CHECK_BOOL(w32.ui.windows_and_messaging.GetClientRect(page_two.hwnd, &rect_window));

        {
            var hdwp = w32.ui.windows_and_messaging.BeginDeferWindowPos(1);
            if (hdwp == 0) return error.BeginDeferringWindowPos;
            defer _ = w32.ui.windows_and_messaging.EndDeferWindowPos(hdwp);

            const list_x = 0;
            const list_y = 0;
            const list_width = rect_window.right;
            const list_height = rect_window.bottom;

            hdwp = w32.ui.windows_and_messaging.DeferWindowPos(hdwp, page_two.hwnd_list, null, list_x, list_y, list_width, list_height, .{});
        }

        // Adjust the list column widths
        const column_width = @divTrunc(rect_window.right, 3);
        _ = w32.ui.windows_and_messaging.SendMessageW(
            page_two.hwnd_list,
            w32.ui.controls.LVM_SETCOLUMNWIDTH,
            0,
            column_width,
        );
        _ = w32.ui.windows_and_messaging.SendMessageW(
            page_two.hwnd_list,
            w32.ui.controls.LVM_SETCOLUMNWIDTH,
            1,
            column_width,
        );
    }
};

// Helper functions
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

fn printLastError() void {
    const err = w32.foundation.GetLastError();

    const err_name = @tagName(err);
    std.log.err("Win32 Error encountered: {s}", .{err_name});
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace);
    }
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

fn GetWndProcForType(comptime T: type) w32.ui.windows_and_messaging.WNDPROC {
    return &(struct {
        fn _WndProc(
            handle: w32.foundation.HWND,
            msg: u32,
            wparam: w32.foundation.WPARAM,
            lparam: w32.foundation.LPARAM,
        ) callconv(.C) w32.foundation.LRESULT {
            const WAM = w32.ui.windows_and_messaging;

            instance: {
                const this = InstanceFromWndProc(T, handle, msg, lparam) catch break :instance;
                switch (msg) {
                    WAM.WM_COMMAND => if (@hasDecl(T, "OnCommand")) return ErrToLRESULT(this.OnCommand(wparam)),
                    WAM.WM_CREATE => if (@hasDecl(T, "OnCreate")) return ErrToLRESULT(this.OnCreate()),
                    WAM.WM_DESTROY => if (@hasDecl(T, "OnDestroy")) return ErrToLRESULT(this.OnDestroy()),
                    WAM.WM_DPICHANGED => if (@hasDecl(T, "OnDpiChanged")) return ErrToLRESULT(this.OnDpiChanged(wparam, lparam)),
                    WAM.WM_GETMINMAXINFO => if (@hasDecl(T, "OnGetMinMaxInfo")) return ErrToLRESULT(this.OnGetMinMaxInfo(lparam)),
                    WAM.WM_PAINT => if (@hasDecl(T, "OnPaint")) return ErrToLRESULT(this.OnPaint()),
                    WAM.WM_SIZE => if (@hasDecl(T, "OnSize")) return ErrToLRESULT(this.OnSize()),
                    else => {},
                }
            }

            if (false) std.log.info("Uncaught message {}", .{msg});

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
    })._WndProc;
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
        if (!w32.zig.SUCCEEDED(result)) break :shcore;
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

/// Uses the GDI+ Flat API to load a PNG resource as a bitmap.
fn loadPNGAsGdiplusBitmap(
    alloc: std.mem.Allocator,
    instance: w32.foundation.HINSTANCE,
    id: c_uint,
) !*gdip.Bitmap {
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

    const h_buffer = w32.system.memory.GlobalAlloc(.{ .MEM_MOVEABLE = TRUE }, @intCast(size));
    defer _ = w32.system.memory.GlobalFree(h_buffer);

    var bitmap = try gdip.Bitmap.new(alloc);
    if (h_buffer != 0) {
        const p_buffer_opt = w32.system.memory.GlobalLock(h_buffer);
        if (p_buffer_opt) |p_buffer| {
            defer _ = w32.system.memory.GlobalUnlock(@intCast(@intFromPtr(p_buffer)));
            @memcpy(@as([*]u8, @ptrCast(p_buffer))[0..size], @as([*]u8, @ptrCast(resource))[0..size]);

            var p_stream: ?*w32.system.com.IStream = null;
            if (w32.system.com.structured_storage.CreateStreamOnHGlobal(@intCast(@intFromPtr(p_buffer)), FALSE, &p_stream) == w32.foundation.S_OK) {
                _ = gdip.GdipCreateBitmapFromStream(p_stream.?, &bitmap);
                _ = p_stream.?.IUnknown.Release();
            }
        }
    }

    return bitmap;
}

const Resource = struct {
    fn stringLoad(alloc: std.mem.Allocator, h_instance: w32.foundation.HINSTANCE, u_id: u32) ?[:0]const u16 {
        var pointer: ?[*:0]u16 = null;
        const res = w32.ui.windows_and_messaging.LoadStringW(h_instance, u_id, @ptrCast(&pointer), 0);
        if (res == 0) return null;
        const char_count: usize = @intCast(res);
        const p = pointer orelse return null;
        const string = alloc.dupeZ(u16, p[0..char_count]) catch return null;
        return string;
    }
};

// We have 2 dependencies: the zig standard library and zigwin32.
const std = @import("std");
const w32 = @import("zigwin32");

// We need GdiPlus for loading our PNG files. Unfortunately, GdiPlus is
// exclusively a C++ API. It is based on a flat C API, but Microsoft
// will not give you support if you use it. They don't include it in
// the metadata that zigwin32 uses to generate it's bindings.
//
// Well, I don't really expect support from Microsoft and I'd rather
// not drag in C++, so I've manually defined the extern functions here.
const gdip = struct {
    const BitmapInternal = extern struct {
        image_type: c_int,
        image_format: c_int,
        num_of_frames: c_int,
        frames: *anyopaque,
        active_frame: c_int,
        active_bitmap_no: c_int,
        active_bitmap: *anyopaque,
        cairo_format: c_int,
        surface: *anyopaque,
    };
    const Bitmap = opaque {
        fn new(allocator: std.mem.Allocator) !*Bitmap {
            const ptr = try allocator.create(BitmapInternal);
            ptr.* = std.mem.zeroes(BitmapInternal);
            return @ptrCast(ptr);
        }

        fn GetWidth(bmp: *Bitmap) u32 {
            var val: u32 = 0;
            _ = GdipGetImageWidth(bmp, &val);
            return val;
        }

        fn GetHeight(bmp: *Bitmap) u32 {
            var val: u32 = 0;
            _ = GdipGetImageHeight(bmp, &val);
            return val;
        }

        fn AsImage(bmp: *Bitmap) *GpImage {
            return @ptrCast(bmp);
        }
    };
    const GpImage = opaque {};
    const GpGraphics = opaque {
        fn CreateFromHDC(hdc: w32.graphics.gdi.HDC) ?*GpGraphics {
            var graphics: ?*GpGraphics = null;
            _ = GdipCreateFromHDC(hdc, &graphics);
            return graphics;
        }

        fn DrawImageRectI(graphics: *GpGraphics, image: *GpImage, x: i32, y: i32, width: i32, height: i32) void {
            _ = GdipDrawImageRectI(graphics, image, x, y, width, height);
        }
    };
    const GpStatus = enum(c_int) {
        Ok = 0,
        GenericError = 1,
        InvalidParameter = 2,
        OutOfMemory = 3,
        ObjectBusy = 4,
        InsufficientBuffer = 5,
        NotImplemented = 6,
        Win32Error = 7,
        WrongState = 8,
        Aborted = 9,
        FileNotFound = 10,
        ValueOverflow = 11,
        AccessDenied = 12,
        UnknownImageFormat = 13,
        FontFamilyNotFound = 14,
        FontStyleNotFound = 15,
        NotTrueTypeFont = 16,
        UnsupportedGdiplusVersion = 17,
        GdiplusNotInitialized = 18,
        PropertyNotFound = 19,
        PropertyNotSupported = 20,
    };
    extern "gdiplus" fn GdipCreateBitmapFromStream(stream: *anyopaque, bitmap: **Bitmap) callconv(.C) GpStatus;
    extern "gdiplus" fn GdipGetImageWidth(image: *anyopaque, width: *u32) callconv(.C) GpStatus;
    extern "gdiplus" fn GdipGetImageHeight(image: *anyopaque, height: *u32) callconv(.C) GpStatus;
    extern "gdiplus" fn GdipCreateFromHDC(hdc: w32.graphics.gdi.HDC, graphics: *?*GpGraphics) callconv(.C) GpStatus;
    extern "gdiplus" fn GdipDrawImageRectI(graphics: *GpGraphics, image: *GpImage, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.C) GpStatus;
    extern "gdiplus" fn GdipDisposeImage(image: *anyopaque) callconv(.C) GpStatus;
};
