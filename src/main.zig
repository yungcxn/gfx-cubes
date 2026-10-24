const c = @import("c");

pub fn main() void {
    c.InitWindow(800, 450, "gfx-cubes");
    defer c.CloseWindow();
    c.SetTargetFPS(60);

    const bg = c.Color{ .r = 245, .g = 245, .b = 245, .a = 255 };
    const fg = c.Color{ .r = 80, .g = 80, .b = 80, .a = 255 };

    while (!c.WindowShouldClose()) {
        c.BeginDrawing();
        defer c.EndDrawing();
        c.ClearBackground(bg);
        c.DrawText("Hello from Zig!", 190, 200, 20, fg);
        c.DrawFPS(10, 10);
    }
}
