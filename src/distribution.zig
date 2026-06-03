const std = @import("std");

// Based on Gray's: "Quickly Generating Billion-Record Synthetic Databases"
// https://dl.acm.org/doi/pdf/10.1145/191843.191886

pub const ZipfGenerator = struct {
    const Self = @This();

    n: u64,
    theta: f64,
    alpha: f64,
    zeta_n: f64,
    eta: f64,

    pub fn Init(n_in: u64, theta: f64) Self {
        const n: u64 = n_in - 1;
        const zeta_n = CalcZeta(n, theta);
        return .{
            .n = n,
            .theta = theta,
            .alpha = 1 / (1 - theta),
            .zeta_n = zeta_n,
            .eta = (1 - std.math.pow(f64, 2 / @as(f64, @floatFromInt(n)), 1 - theta)) / (1 - (CalcZeta(2, theta) / zeta_n)),
        };
    }

    pub fn CalcZeta(n: u64, theta: f64) f64 {
        var res: f64 = 0;
        // Thx Simon ;)
        for (1..(n + 1)) |i| res += std.math.pow(f64, 1 / @as(f64, @floatFromInt(i)), theta);
        return res;
    }

    pub fn Rand(self: *Self, rng: *std.Random) u64 {
        const rand_float = rng.float(f64);
        const uz = rand_float * self.zeta_n;

        if (uz < 1) return 1;
        if (uz < (1 + std.math.pow(f64, 0.5, self.theta))) return 2;

        return 1 + (@as(u64, @intFromFloat(@as(f64, @floatFromInt(self.n)) * std.math.pow(f64, self.eta * rand_float - self.eta + 1, self.alpha))));
    }
};

pub const ScrambledZipfGenerator = struct {
    const Self = @This();

    min: u64,
    max: u64,
    n: u64,
    zipf: ZipfGenerator,

    pub fn Init(min: u64, max: u64, theta: f64) Self {
        return .{
            .min = min,
            .max = max,
            .n = max - min,
            .zipf = ZipfGenerator.Init(max - min, theta),
        };
    }

    pub fn Rand(self: *Self, rng: *std.Random) u64 {
        const res = std.mem.toBytes(self.zipf.Rand(rng));
        return self.min + (std.hash.Fnv1a_64.hash(&res) % self.n);
    }

    pub fn RandRange(self: *Self, rng: *std.Random, max_inclusive: u64) u64 {
        const res = std.mem.toBytes(self.zipf.Rand(rng));
        return self.min + (std.hash.Fnv1a_64.hash(&res) % (max_inclusive + 1));
    }
};

pub const UniformGenerator = struct {
    const Self = @This();
    pub fn RandRange(self: *Self, rng: *std.Random, max_inclusive: u64) u64 {
        _ = self;
        return rng.intRangeAtMost(u64, 0, max_inclusive);
    }
};

pub fn GenScramZipfSequence(min: u64, max: u64, theta: f64, rng: *std.Random, seq_len: u64, alloc: std.mem.Allocator) ![]u64 {
    const seq = try alloc.alloc(u64, seq_len);
    if (min == max) {
        for (seq) |*val| {
            val.* = min;
        }
        return seq;
    }
    var szipf = ScrambledZipfGenerator.Init(min, max, theta);
    for (seq) |*val| {
        val.* = szipf.Rand(rng);
    }
    return seq;
}
