const std = @import("std");

const Model = @import("./model.zig").Model;

pub const GameObjectInitParams = struct {
    position: [3]f32,
    model: *const Model,
};

pub const GameObject = struct {
    allocator: std.mem.Allocator,
    position: [3]f32,
    model: *const Model,
    _gc: ?*GameObject,

    pub fn init(allocator: std.mem.Allocator, params: GameObjectInitParams) !*GameObject {
        const game_object = try allocator.create(GameObject);
        errdefer allocator.destroy(game_object);

        game_object.*.allocator = allocator;
        game_object.*.position = params.position;
        game_object.*.model = params.model;
        game_object.*._gc = game_object;

        return game_object;
    }

    pub fn deinit(game_object: *GameObject) void {
        if (game_object._gc) |pointer| {
            game_object.allocator.destroy(pointer);
        }
    }
};
