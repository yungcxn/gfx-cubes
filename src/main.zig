const std = @import("std");
const c = @import("c");

extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn isatty(fd: c_int) c_int;

const txt = struct {
    pub const press_enter: [:0]const u8 = "Drück <Enter>   -   Hoch/Runter: Anzahl";
    pub const sum = "Summe: ";
};

const max_cubes = 32;
const default_cubes = 5;
const face_step: f32 = std.math.pi / 3.2;
const slices = 8;
const tex_size = 256;
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

const pip_layout = [6][]const [2]f32{
    &.{.{ 0.5, 0.5 }},
    &.{ .{ 0.28, 0.28 }, .{ 0.72, 0.72 } },
    &.{ .{ 0.28, 0.28 }, .{ 0.5, 0.5 }, .{ 0.72, 0.72 } },
    &.{ .{ 0.28, 0.28 }, .{ 0.72, 0.28 }, .{ 0.28, 0.72 }, .{ 0.72, 0.72 } },
    &.{ .{ 0.28, 0.28 }, .{ 0.72, 0.28 }, .{ 0.5, 0.5 }, .{ 0.28, 0.72 }, .{ 0.72, 0.72 } },
    &.{ .{ 0.28, 0.25 }, .{ 0.72, 0.25 }, .{ 0.28, 0.5 }, .{ 0.72, 0.5 }, .{ 0.28, 0.75 }, .{ 0.72, 0.75 } },
};

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

fn sum_label(buf: *[32:0]u8, value: i32) [:0]const u8 {
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

fn make_strip() c.Texture2D {
    const s: i32 = tex_size;
    const fs: f32 = tex_size;
    var img = c.GenImageColor(s, s * 8, c.Color{ .r = 250, .g = 248, .b = 242, .a = 255 });
    const pip = c.Color{ .r = 40, .g = 40, .b = 48, .a = 255 };
    const red = c.Color{ .r = 210, .g = 40, .b = 50, .a = 255 };
    const edge = c.Color{ .r = 196, .g = 192, .b = 184, .a = 255 };
    for (0..6) |k| {
        const y0: i32 = @as(i32, @intCast(k)) * s;
        c.ImageDrawRectangle(&img, 0, y0, s, 6, edge);
        c.ImageDrawRectangle(&img, 0, y0 + s - 6, s, 6, edge);
        const big = k == 0;
        const scale: f32 = if (big) 0.13 else 0.085;
        const r: i32 = @intFromFloat(fs * scale);
        for (pip_layout[k]) |p| {
            const px: i32 = @intFromFloat(p[0] * fs);
            const py: i32 = y0 + @as(i32, @intFromFloat(p[1] * fs));
            c.ImageDrawCircle(&img, px, py, r, if (big) red else pip);
        }
    }
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
        const fi: f32 = @floatFromInt(i % 8);
        start_snd[i] = c.LoadSoundAlias(start_base);
        stop_snd[i] = c.LoadSoundAlias(stop_base);
        c.SetSoundPitch(start_snd[i], 0.92 + 0.04 * fi);
        c.SetSoundVolume(start_snd[i], 0.55);
        c.SetSoundPitch(stop_snd[i], penta[i % 5]);
    }
    defer {
        for (0..max_cubes) |i| {
            c.UnloadSoundAlias(start_snd[i]);
            c.UnloadSoundAlias(stop_snd[i]);
        }
    }

    const strip = make_strip();
    defer c.UnloadTexture(strip);

    const bg = c.Color{ .r = 245, .g = 245, .b = 245, .a = 255 };
    const fg = c.Color{ .r = 80, .g = 80, .b = 80, .a = 255 };
    const housing = c.Color{ .r = 48, .g = 48, .b = 56, .a = 255 };
    const gold = c.Color{ .r = 232, .g = 182, .b = 60, .a = 255 };
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
        c.ClearBackground(bg);

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
            const pos = reel_pos(r, now);
            const vel = (pos - reel_pos(r, now - 1.0 / 60.0)) * 60;
            const blur = std.math.clamp((@abs(vel) - 3) / 14, 0.0, 1.0);
            const since = now - r.t_stop;
            const glow: f32 = if (r.stopped and since >= 0 and since < 1.5) @exp(-since * 3) else 0;

            const frame = c.Rectangle{ .x = x - rw / 2 - m, .y = cy - rad - m, .width = rw + 2 * m, .height = 2 * rad + 2 * m };
            c.DrawEllipse(@intFromFloat(x), @intFromFloat(cy + rad + m * 2.2), rw * 0.6, m * 0.9, shadow);
            if (glow > 0) {
                const g = m * 1.4 * glow;
                c.DrawRectangleRounded(.{ .x = frame.x - g, .y = frame.y - g, .width = frame.width + 2 * g, .height = frame.height + 2 * g }, 0.2, 8, c.Fade(gold, glow * 0.7));
            }
            c.DrawRectangleRounded(frame, 0.16, 8, housing);
            c.DrawRectangleRec(.{ .x = x - rw / 2, .y = cy - rad, .width = rw, .height = 2 * rad }, black);

            draw_reel(strip, x, cy, rad, rw, pos, 1);
            if (blur > 0) {
                const dir: f32 = if (vel > 0) 1 else -1;
                for (1..4) |j| {
                    const fj: f32 = @floatFromInt(j);
                    draw_reel(strip, x, cy, rad, rw, pos - dir * fj * blur * 0.08, 0.3 * blur);
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
            c.DrawPoly(.{ .x = frame.x + ps * 0.6, .y = cy }, 3, ps, 0, gold);
            c.DrawPoly(.{ .x = frame.x + frame.width - ps * 0.6, .y = cy }, 3, ps, 180, gold);
        }

        const hint_size: i32 = @max(10, @as(i32, @intFromFloat(fh * 0.05)));

        if (rolled) {
            var sum: i32 = 0;
            var last: f32 = 0;
            for (0..cubes) |i| {
                sum += values[i];
                last = @max(last, reels[i].t_stop);
            }
            const a = std.math.clamp((now - last - 0.3) / 0.3, 0.0, 1.0);
            if (a > 0) {
                var buf: [32:0]u8 = undefined;
                const label = sum_label(&buf, sum);
                draw_cent_text(label, @divFloor(w, 2), @intFromFloat(fh * 0.1), @intFromFloat(@as(f32, @floatFromInt(hint_size)) * 1.4), c.Fade(fg, a));
            }
        }

        draw_cent_text(txt.press_enter, @divFloor(w, 2), @intFromFloat(fh * 0.9), hint_size, fg);
    }
}
