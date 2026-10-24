const std = @import("std");
const c = @import("c");

extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn isatty(fd: c_int) c_int;

const txt = struct {
    pub const press_enter: [:0]const u8 = "Drück <Enter>   -   Hoch/Runter: Anzahl (1-3)";
    pub const sum = "Summe: ";
    pub const star = " + Stern";
    pub const bus = " + Bus";
};

const max_cubes = 3;
const default_cubes = 3;
const speed_die = 2;
const face_step: f32 = std.math.pi / 3.2;
const slices = 8;
const tex_size = 256;
const tile = tex_size * 2;
const sample_rate = 44100;
const start_len = 6000;
const stop_len = 12000;
const acc_part: f32 = 0.18;
const dec_part: f32 = 0.42;
const prof_total: f32 = acc_part / 2 + (1 - acc_part - dec_part) + dec_part / 3;
const overshoot: f32 = 0.32;
const cruise: f32 = 16;
const penta = [5]f32{ 1.0, 9.0 / 8.0, 5.0 / 4.0, 3.0 / 2.0, 5.0 / 3.0 };

var start_pcm: [start_len]i16 = undefined;
var stop_pcm: [stop_len]i16 = undefined;

const face_col = c.Color{ .r = 252, .g = 252, .b = 250, .a = 255 };
const edge_col = c.Color{ .r = 226, .g = 230, .b = 236, .a = 255 };
const digit_col = c.Color{ .r = 34, .g = 49, .b = 63, .a = 255 };
const speed_col = c.Color{ .r = 230, .g = 57, .b = 70, .a = 255 };
const star_col = c.Color{ .r = 255, .g = 196, .b = 30, .a = 255 };
const star_edge = c.Color{ .r = 214, .g = 140, .b = 0, .a = 255 };
const bus_body = c.Color{ .r = 255, .g = 183, .b = 3, .a = 255 };
const bus_stripe = c.Color{ .r = 251, .g = 113, .b = 0, .a = 255 };
const bus_glass = c.Color{ .r = 142, .g = 202, .b = 230, .a = 255 };
const bus_hub = c.Color{ .r = 200, .g = 205, .b = 212, .a = 255 };
const bus_light = c.Color{ .r = 255, .g = 244, .b = 200, .a = 255 };

const Reel = struct {
    from: f32 = 0,
    dist: f32 = 0,
    over: f32 = 0,
    t_start: f32 = -10,
    t_stop: f32 = -10,
    started: bool = true,
    stopped: bool = true,
};

fn draw_cent_text(text: [:0]const u8, x: i32, y: i32, size: i32, color: c.Color) void {
    const text_width = c.MeasureText(text, size);
    const text_x = x - @divFloor(text_width, 2);
    const text_y = y - @divFloor(size, 2);
    c.DrawText(text, @intCast(text_x), @intCast(text_y), size, color);
}

fn read_cubes() usize {
    if (isatty(0) != 0) return default_cubes;
    var buf: [32]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) return default_cubes;
    const s = std.mem.trim(u8, buf[0..@intCast(n)], " \r\n\t");
    const v = std.fmt.parseInt(usize, s, 10) catch default_cubes;
    return @min(@max(v, 1), max_cubes);
}

fn sum_label(buf: *[32:0]u8, value: i32, extra: []const u8) [:0]const u8 {
    var len: usize = txt.sum.len;
    @memcpy(buf[0..len], txt.sum);
    var digits: [12]u8 = undefined;
    var n: usize = 0;
    var v: u32 = @abs(value);
    while (true) {
        digits[n] = @intCast('0' + v % 10);
        n += 1;
        v /= 10;
        if (v == 0) break;
    }
    while (n > 0) {
        n -= 1;
        buf[len] = digits[n];
        len += 1;
    }
    @memcpy(buf[len .. len + extra.len], extra);
    len += extra.len;
    buf[len] = 0;
    return buf[0..len :0];
}

fn profile(u: f32) f32 {
    const a = acc_part;
    const b = dec_part;
    var p: f32 = 0;
    if (u < a) {
        p = u * u / (2 * a);
    } else if (u < 1 - b) {
        p = a / 2 + (u - a);
    } else {
        const q = 1 - (u - (1 - b)) / b;
        p = a / 2 + (1 - a - b) + b * (1 - q * q * q) / 3;
    }
    return p / prof_total;
}

fn reel_pos(r: Reel, t: f32) f32 {
    if (t <= r.t_start) return r.from;
    if (t < r.t_stop) {
        const u = (t - r.t_start) / (r.t_stop - r.t_start);
        const kick = -0.2 * @sin(std.math.clamp(u / 0.12, 0.0, 1.0) * std.math.pi);
        return r.from + (r.dist + r.over) * profile(u) + kick;
    }
    const s = t - r.t_stop;
    const k: f32 = 9;
    const w: f32 = 26;
    return r.from + r.dist + r.over * @exp(-k * s) * (@cos(w * s) + k / w * @sin(w * s));
}

fn noise() f32 {
    return @as(f32, @floatFromInt(c.GetRandomValue(-10000, 10000))) / 10000.0;
}

fn to_pcm(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v, -1.0, 1.0) * 30000.0);
}

fn synth() void {
    const two_pi: f32 = std.math.tau;
    for (&start_pcm, 0..) |*o, n| {
        const t = @as(f32, @floatFromInt(n)) / sample_rate;
        const env = @min(1.0, t * 500) * @exp(-t * 26);
        const ph = two_pi * (160 * t + 1800 * t * t);
        const tone = @sin(ph) + 0.35 * @sin(2 * ph) + 0.2 * @sin(3 * ph);
        const air = noise() * @exp(-t * 45) * 0.5;
        o.* = to_pcm(env * (0.45 * tone + air) * 0.8);
    }
    for (&stop_pcm, 0..) |*o, n| {
        const t = @as(f32, @floatFromInt(n)) / sample_rate;
        const thump = @sin(two_pi * (110 * t - 60 * t * t)) * @exp(-t * 20);
        const click = noise() * @exp(-t * 350);
        const ding = @sin(two_pi * 1320 * t) * @exp(-t * 16) * 0.22 +
            @sin(two_pi * 1980 * t) * @exp(-t * 24) * 0.12 +
            @sin(two_pi * 2640 * t) * @exp(-t * 30) * 0.06;
        o.* = to_pcm(0.7 * thump + 0.4 * click + ding);
    }
}

fn load_pcm(pcm: []i16) c.Sound {
    const wave = c.Wave{
        .frameCount = @intCast(pcm.len),
        .sampleRate = sample_rate,
        .sampleSize = 16,
        .channels = 1,
        .data = @ptrCast(pcm.ptr),
    };
    return c.LoadSoundFromWave(wave);
}

const Pen = struct {
    img: *c.Image,
    s: f32,
    oy: f32,
    r: i32,
    col: c.Color,

    fn dot(p: Pen, u: f32, v: f32) void {
        c.ImageDrawCircle(p.img, @intFromFloat(u * p.s), @intFromFloat(p.oy + v * p.s), p.r, p.col);
    }

    fn line(p: Pen, ua: f32, v0: f32, ub: f32, v1: f32) void {
        const du = ub - ua;
        const dv = v1 - v0;
        const n: usize = @intFromFloat(@max(1.0, @sqrt(du * du + dv * dv) * p.s / 2));
        for (0..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            p.dot(ua + du * t, v0 + dv * t);
        }
    }

    fn arc(p: Pen, cu: f32, cv: f32, rr: f32, a0: f32, a1: f32) void {
        const n: usize = @intFromFloat(@max(1.0, @abs(a1 - a0) * rr * p.s / 2));
        for (0..n + 1) |i| {
            const a = a0 + (a1 - a0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            p.dot(cu + rr * @cos(a), cv + rr * @sin(a));
        }
    }

    fn rect(p: Pen, u: f32, v: f32, w: f32, h: f32, col: c.Color) void {
        c.ImageDrawRectangle(p.img, @intFromFloat(u * p.s), @intFromFloat(p.oy + v * p.s), @intFromFloat(w * p.s), @intFromFloat(h * p.s), col);
    }

    fn circle(p: Pen, u: f32, v: f32, r: f32, col: c.Color) void {
        c.ImageDrawCircle(p.img, @intFromFloat(u * p.s), @intFromFloat(p.oy + v * p.s), @intFromFloat(r * p.s), col);
    }

    fn rrect(p: Pen, u: f32, v: f32, w: f32, h: f32, r: f32, col: c.Color) void {
        p.rect(u + r, v, w - 2 * r, h, col);
        p.rect(u, v + r, w, h - 2 * r, col);
        p.circle(u + r, v + r, r, col);
        p.circle(u + w - r, v + r, r, col);
        p.circle(u + r, v + h - r, r, col);
        p.circle(u + w - r, v + h - r, r, col);
    }

    fn poly(p: Pen, pts: []const [2]f32, col: c.Color) void {
        var lo = [2]f32{ 1, 1 };
        var hi = [2]f32{ 0, 0 };
        for (pts) |q| {
            lo = .{ @min(lo[0], q[0]), @min(lo[1], q[1]) };
            hi = .{ @max(hi[0], q[0]), @max(hi[1], q[1]) };
        }
        var y: i32 = @intFromFloat(p.oy + lo[1] * p.s);
        const y1: i32 = @intFromFloat(p.oy + hi[1] * p.s + 1);
        while (y <= y1) : (y += 1) {
            const v = (@as(f32, @floatFromInt(y)) + 0.5 - p.oy) / p.s;
            var x: i32 = @intFromFloat(lo[0] * p.s);
            const x1: i32 = @intFromFloat(hi[0] * p.s + 1);
            while (x <= x1) : (x += 1) {
                const u = (@as(f32, @floatFromInt(x)) + 0.5) / p.s;
                var inside = false;
                var j = pts.len - 1;
                for (pts, 0..) |a, i| {
                    const b = pts[j];
                    if ((a[1] > v) != (b[1] > v) and u < (b[0] - a[0]) * (v - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
                    j = i;
                }
                if (inside) c.ImageDrawPixel(p.img, x, y, col);
            }
        }
    }
};

fn draw_digit(p: Pen, d: usize) void {
    switch (d) {
        1 => {
            p.line(0.36, 0.27, 0.54, 0.15);
            p.line(0.54, 0.15, 0.54, 0.85);
            p.line(0.38, 0.85, 0.70, 0.85);
        },
        2 => {
            p.arc(0.5, 0.34, 0.18, -2.9, 0.45);
            p.line(0.5 + 0.18 * @cos(@as(f32, 0.45)), 0.34 + 0.18 * @sin(@as(f32, 0.45)), 0.32, 0.85);
            p.line(0.32, 0.85, 0.70, 0.85);
        },
        3 => {
            p.arc(0.5, 0.33, 0.17, -2.8, std.math.pi / 2.0);
            p.arc(0.5, 0.67, 0.18, -std.math.pi / 2.0, 2.8);
        },
        4 => {
            p.line(0.62, 0.85, 0.62, 0.15);
            p.line(0.62, 0.15, 0.28, 0.63);
            p.line(0.28, 0.63, 0.76, 0.63);
        },
        5 => {
            p.line(0.68, 0.15, 0.38, 0.15);
            p.line(0.38, 0.15, 0.36, 0.48);
            p.arc(0.5, 0.65, 0.2, -2.3, 2.6);
        },
        else => {
            p.arc(0.5, 0.66, 0.19, 0, std.math.tau);
            p.line(0.64, 0.14, 0.32, 0.62);
        },
    }
}

fn draw_star(p: Pen, outer: f32, inner: f32, col: c.Color) void {
    var pts: [10][2]f32 = undefined;
    for (0..10) |i| {
        const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 5.0;
        const r = if (i % 2 == 0) outer else inner;
        pts[i] = .{ 0.5 + r * @cos(a), 0.53 + r * @sin(a) };
    }
    p.poly(&pts, col);
}

fn draw_bus(p: Pen) void {
    p.rrect(0.12, 0.28, 0.76, 0.40, 0.06, bus_body);
    p.rect(0.12, 0.55, 0.76, 0.05, bus_stripe);
    for (0..5) |k| {
        p.rrect(0.18 + @as(f32, @floatFromInt(k)) * 0.115, 0.34, 0.085, 0.13, 0.015, bus_glass);
    }
    p.rrect(0.775, 0.34, 0.07, 0.18, 0.015, bus_glass);
    p.circle(0.30, 0.68, 0.08, digit_col);
    p.circle(0.70, 0.68, 0.08, digit_col);
    p.circle(0.30, 0.68, 0.032, bus_hub);
    p.circle(0.70, 0.68, 0.032, bus_hub);
    p.circle(0.855, 0.615, 0.02, bus_light);
}

fn make_strip(special: bool) c.Texture2D {
    const s: f32 = tile;
    var img = c.GenImageColor(tile, tile * 8, face_col);
    for (0..6) |k| {
        const oy = @as(f32, @floatFromInt(k)) * s;
        const pen = Pen{
            .img = &img,
            .s = s,
            .oy = oy,
            .r = @intFromFloat(s * 0.062),
            .col = if (special) speed_col else digit_col,
        };
        pen.rect(0, 0, 1, 0.02, edge_col);
        pen.rect(0, 0.98, 1, 0.02, edge_col);
        if (!special or k < 3) {
            draw_digit(pen, k + 1);
        } else if (k < 5) {
            draw_star(pen, 0.36, 0.15, star_edge);
            draw_star(pen, 0.30, 0.125, star_col);
        } else {
            draw_bus(pen);
        }
    }
    c.ImageResize(&img, tex_size, tex_size * 8);
    var tex = c.LoadTextureFromImage(img);
    c.UnloadImage(img);
    c.GenTextureMipmaps(&tex);
    c.SetTextureFilter(tex, c.TEXTURE_FILTER_TRILINEAR);
    return tex;
}

fn draw_reel(tex: c.Texture2D, x: f32, cy: f32, rad: f32, rw: f32, pos: f32, alpha: f32) void {
    const half = face_step / 2;
    const lim: f32 = std.math.pi / 2.0;
    const fs: f32 = tex_size;
    const base: i32 = @intFromFloat(@floor(pos));
    var k: i32 = base - 3;
    while (k <= base + 3) : (k += 1) {
        const theta = (pos - @as(f32, @floatFromInt(k))) * face_step;
        const face: f32 = @floatFromInt(@mod(k, 6));
        for (0..slices) |si| {
            const f0 = @as(f32, @floatFromInt(si)) / slices;
            const f1 = @as(f32, @floatFromInt(si + 1)) / slices;
            const a0 = @max(theta - half + face_step * f0, -lim);
            const a1 = @min(theta - half + face_step * f1, lim);
            if (a1 <= a0) continue;
            const v0 = (a0 - (theta - half)) / face_step;
            const v1 = (a1 - (theta - half)) / face_step;
            const y0 = cy + rad * @sin(a0);
            const y1 = cy + rad * @sin(a1);
            const mid = (a0 + a1) / 2;
            const light = @cos(mid);
            const spec = @exp(-(mid + 0.5) * (mid + 0.5) * 18) * 0.22;
            const b = std.math.clamp(0.12 + 0.88 * light + spec, 0.0, 1.0);
            const sc = 0.94 + 0.06 * light;
            const tint = c.Color{
                .r = @intFromFloat(b * 255),
                .g = @intFromFloat(b * 252),
                .b = @intFromFloat(b * 246),
                .a = @intFromFloat(alpha * 255),
            };
            c.DrawTexturePro(
                tex,
                .{ .x = 0, .y = (face + v0) * fs, .width = fs, .height = (v1 - v0) * fs },
                .{ .x = x - rw * sc / 2, .y = y0, .width = rw * sc, .height = y1 - y0 + 0.6 },
                .{ .x = 0, .y = 0 },
                0,
                tint,
            );
        }
    }
}

pub fn main() void {
    var cubes = read_cubes();

    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE | c.FLAG_MSAA_4X_HINT);
    c.InitWindow(800, 450, "gfx-slots");
    defer c.CloseWindow();
    c.SetTargetFPS(60);
    c.SetRandomSeed(@intCast(@as(i64, time(null)) & 0x7fffffff));

    c.InitAudioDevice();
    defer c.CloseAudioDevice();
    synth();
    const start_base = load_pcm(&start_pcm);
    defer c.UnloadSound(start_base);
    const stop_base = load_pcm(&stop_pcm);
    defer c.UnloadSound(stop_base);

    var start_snd: [max_cubes]c.Sound = undefined;
    var stop_snd: [max_cubes]c.Sound = undefined;
    for (0..max_cubes) |i| {
        const fi: f32 = @floatFromInt(i);
        start_snd[i] = c.LoadSoundAlias(start_base);
        stop_snd[i] = c.LoadSoundAlias(stop_base);
        c.SetSoundPitch(start_snd[i], 0.92 + 0.1 * fi);
        c.SetSoundVolume(start_snd[i], 0.55);
        c.SetSoundPitch(stop_snd[i], penta[i % 5]);
    }
    defer {
        for (0..max_cubes) |i| {
            c.UnloadSoundAlias(start_snd[i]);
            c.UnloadSoundAlias(stop_snd[i]);
        }
    }

    const strip = make_strip(false);
    defer c.UnloadTexture(strip);
    const speed_strip = make_strip(true);
    defer c.UnloadTexture(speed_strip);

    const bg_top = c.Color{ .r = 246, .g = 248, .b = 252, .a = 255 };
    const bg_bot = c.Color{ .r = 226, .g = 232, .b = 242, .a = 255 };
    const fg = c.Color{ .r = 52, .g = 64, .b = 84, .a = 255 };
    const housing = c.Color{ .r = 43, .g = 50, .b = 65, .a = 255 };
    const gold = c.Color{ .r = 255, .g = 183, .b = 3, .a = 255 };
    const red = c.Color{ .r = 230, .g = 57, .b = 70, .a = 255 };
    const black = c.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const white = c.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const shadow = c.Color{ .r = 0, .g = 0, .b = 0, .a = 28 };

    var reels: [max_cubes]Reel = @splat(.{});
    var values: [max_cubes]i32 = @splat(1);
    for (0..max_cubes) |i| {
        const v = c.GetRandomValue(1, 6);
        values[i] = v;
        reels[i].from = @floatFromInt(v - 1);
    }
    var rolled = false;

    while (!c.WindowShouldClose()) {
        const w = @as(i32, c.GetScreenWidth());
        const h = @as(i32, c.GetScreenHeight());
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const alt = c.IsKeyDown(c.KEY_LEFT_ALT);
        const now: f32 = @floatCast(c.GetTime());

        if (c.IsKeyPressed(c.KEY_UP) and cubes < max_cubes) cubes += 1;
        if (c.IsKeyPressed(c.KEY_DOWN) and cubes > 1) cubes -= 1;
        const n_f: f32 = @floatFromInt(cubes);

        if (c.IsKeyPressed(c.KEY_F11) or (c.IsKeyPressed(c.KEY_ENTER) and alt)) {
            c.ToggleFullscreen();
            if (!c.IsWindowFullscreen()) {
                c.SetWindowSize(800, 450);
            }
        } else if (c.IsKeyPressed(c.KEY_ENTER) and !alt) {
            const start_gap = @min(0.14, 1.0 / n_f);
            const stop_gap = @min(0.34, 2.4 / n_f);
            for (0..cubes) |i| {
                const fi: f32 = @floatFromInt(i);
                const v = c.GetRandomValue(1, 6);
                const from = @mod(reel_pos(reels[i], now), 6.0);
                const span = 1.25 + fi * (stop_gap - start_gap);
                const laps = @max(1.0, @round(cruise * span * prof_total / 6));
                values[i] = v;
                reels[i] = .{
                    .from = from,
                    .dist = laps * 6 + @mod(@as(f32, @floatFromInt(v - 1)) - from, 6.0),
                    .over = overshoot,
                    .t_start = now + fi * start_gap,
                    .t_stop = now + fi * start_gap + span,
                    .started = false,
                    .stopped = false,
                };
            }
            rolled = true;
        }

        for (0..cubes) |i| {
            if (!reels[i].started and now >= reels[i].t_start) {
                reels[i].started = true;
                c.PlaySound(start_snd[i]);
            }
            if (!reels[i].stopped and now >= reels[i].t_stop) {
                reels[i].stopped = true;
                c.PlaySound(stop_snd[i]);
            }
        }

        c.BeginDrawing();
        defer c.EndDrawing();
        defer c.DrawFPS(10, 10);
        c.DrawRectangleGradientV(0, 0, w, h, bg_top, bg_bot);

        const cell_w = fw / n_f;
        const k_face = 2 * @sin(face_step / 2);
        const rad = @min(fh * 0.27, cell_w * 0.76 / k_face);
        const rw = rad * k_face;
        const m = rw * 0.08;
        const cy = fh * 0.47;

        for (0..cubes) |i| {
            const fi: f32 = @floatFromInt(i);
            const x = cell_w * (fi + 0.5);
            const r = reels[i];
            const tex = if (i == speed_die) speed_strip else strip;
            const accent = if (i == speed_die) red else gold;
            const pos = reel_pos(r, now);
            const vel = (pos - reel_pos(r, now - 1.0 / 60.0)) * 60;
            const blur = std.math.clamp((@abs(vel) - 3) / 14, 0.0, 1.0);
            const since = now - r.t_stop;
            const glow: f32 = if (r.stopped and since >= 0 and since < 1.5) @exp(-since * 3) else 0;

            const frame = c.Rectangle{ .x = x - rw / 2 - m, .y = cy - rad - m, .width = rw + 2 * m, .height = 2 * rad + 2 * m };
            c.DrawEllipse(@intFromFloat(x), @intFromFloat(cy + rad + m * 2.2), rw * 0.6, m * 0.9, shadow);
            if (glow > 0) {
                const g = m * 1.4 * glow;
                c.DrawRectangleRounded(.{ .x = frame.x - g, .y = frame.y - g, .width = frame.width + 2 * g, .height = frame.height + 2 * g }, 0.2, 8, c.Fade(accent, glow * 0.7));
            }
            if (i == speed_die) {
                const g = m * 0.35;
                c.DrawRectangleRounded(.{ .x = frame.x - g, .y = frame.y - g, .width = frame.width + 2 * g, .height = frame.height + 2 * g }, 0.18, 8, red);
            }
            c.DrawRectangleRounded(frame, 0.16, 8, housing);
            c.DrawRectangleRec(.{ .x = x - rw / 2, .y = cy - rad, .width = rw, .height = 2 * rad }, black);

            draw_reel(tex, x, cy, rad, rw, pos, 1);
            if (blur > 0) {
                const dir: f32 = if (vel > 0) 1 else -1;
                for (1..4) |j| {
                    const fj: f32 = @floatFromInt(j);
                    draw_reel(tex, x, cy, rad, rw, pos - dir * fj * blur * 0.08, 0.3 * blur);
                }
            }

            const ix: i32 = @intFromFloat(x - rw / 2);
            const iy: i32 = @intFromFloat(cy - rad);
            const iw: i32 = @intFromFloat(rw);
            const ih: i32 = @intFromFloat(rad * 0.55);
            c.DrawRectangleGradientV(ix, iy, iw, ih, c.Fade(black, 0.45), c.Fade(black, 0));
            c.DrawRectangleGradientV(ix, @intFromFloat(cy + rad - rad * 0.55), iw, ih, c.Fade(black, 0), c.Fade(black, 0.45));
            c.DrawRectangleGradientH(ix, iy, @intFromFloat(rw * 0.25), @intFromFloat(2 * rad), c.Fade(white, 0.12), c.Fade(white, 0));

            const ps = m * 0.9;
            c.DrawPoly(.{ .x = frame.x + ps * 0.6, .y = cy }, 3, ps, 0, accent);
            c.DrawPoly(.{ .x = frame.x + frame.width - ps * 0.6, .y = cy }, 3, ps, 180, accent);
        }

        const hint_size: i32 = @max(10, @as(i32, @intFromFloat(fh * 0.05)));

        if (rolled) {
            var sum: i32 = 0;
            var extra: []const u8 = "";
            var last: f32 = 0;
            for (0..cubes) |i| {
                if (i == speed_die and values[i] > 3) {
                    extra = if (values[i] == 6) txt.bus else txt.star;
                } else {
                    sum += values[i];
                }
                last = @max(last, reels[i].t_stop);
            }
            const a = std.math.clamp((now - last - 0.3) / 0.3, 0.0, 1.0);
            if (a > 0) {
                var buf: [32:0]u8 = undefined;
                const label = sum_label(&buf, sum, extra);
                draw_cent_text(label, @divFloor(w, 2), @intFromFloat(fh * 0.1), @intFromFloat(@as(f32, @floatFromInt(hint_size)) * 1.4), c.Fade(fg, a));
            }
        }

        draw_cent_text(txt.press_enter, @divFloor(w, 2), @intFromFloat(fh * 0.9), hint_size, fg);
    }
}
