const std = @import("std");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");
const zmath = @import("zmath");
const zstbi = @import("zstbi");
const gltf_loader = @import("gltf_loader");

const wgsl_vs = @embedFile("../shaders/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/fs.wgsl");

const types = @import("./types.zig");
const BufferDescriptor = types.BufferDescriptor;
const WindowContext = @import("./glue.zig").WindowContext;
const BindGroupDefinition = @import("./bind_group.zig").BindGroupDefinition;
const DepthTexture = @import("./depth_texture.zig").DepthTexture;
const ModelDescriptor = @import("./model_descriptor.zig").ModelDescriptor;
const Model = @import("./model.zig").Model;
const Scene = @import("./scene.zig").Scene;

const GraphicsContextState = @typeInfo(@TypeOf(zgpu.GraphicsContext.present)).@"fn".return_type.?;

pub const Engine = struct {
    pub const LoadedModelId = enum(u32) { _ };

    var is_instanced: bool = false;
    var next_loaded_model_id: u32 = 0;

    const Callbacks = struct {
        onUpdate: ?*const fn (engine: *Engine) void,
        onRender: ?*const fn (engine: *Engine, pass: wgpu.RenderPassEncoder) void,
    };

    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    window_context: WindowContext,
    callbacks: Callbacks,

    pipeline: zgpu.RenderPipelineHandle,
    bind_group_def: BindGroupDefinition,
    depth_texture: DepthTexture,
    texture_sampler: zgpu.SamplerHandle,

    models_hash: std.AutoHashMap(LoadedModelId, *Model),

    active_scene: ?*Scene,

    pub fn init(
        allocator: std.mem.Allocator,
        window_context: WindowContext,
        callbacks: Callbacks,
    ) !*Engine {
        if (Engine.is_instanced) {
            return error.EngineCanHaveOnlyOneInstance;
        }

        zstbi.init(allocator);

        const gctx = window_context.gctx;

        const bind_group_def = BindGroupDefinition.init(gctx);

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_def.bind_group_layout});
        defer gctx.releaseResource(pipeline_layout);

        const pipeline = pipeline: {
            const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
            defer vs_module.release();

            const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
            defer fs_module.release();

            const color_targets = [_]wgpu.ColorTargetState{.{
                .format = zgpu.GraphicsContext.swapchain_format,
            }};

            const vertex_buffers = [_]wgpu.VertexBufferLayout{
                // position
                .{
                    .array_stride = @sizeOf([3]f32),
                    .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 0 }},
                    .attribute_count = 1,
                },
                // normal
                .{
                    .array_stride = @sizeOf([3]f32),
                    .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 1 }},
                    .attribute_count = 1,
                },
                // texcoord
                .{
                    .array_stride = @sizeOf([2]f32),
                    .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 2 }},
                    .attribute_count = 1,
                },
            };

            const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
                .primitive = wgpu.PrimitiveState{
                    .front_face = .cw,
                    .cull_mode = .back,
                    .topology = .triangle_list,
                },
                .depth_stencil = &wgpu.DepthStencilState{
                    .format = .depth32_float,
                    .depth_write_enabled = true,
                    .depth_compare = .less,
                },
                .vertex = wgpu.VertexState{
                    .module = vs_module,
                    .entry_point = "main",
                    .buffers = &vertex_buffers,
                    .buffer_count = vertex_buffers.len,
                },
                .fragment = &wgpu.FragmentState{
                    .module = fs_module,
                    .entry_point = "main",
                    .targets = &color_targets,
                    .target_count = color_targets.len,
                },
            };
            break :pipeline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
        };

        const texture_sampler = gctx.createSampler(.{});

        const depth_texture = try DepthTexture.init(gctx);

        const engine = try allocator.create(Engine);
        engine.* = .{
            .allocator = allocator,
            .window_context = window_context,
            .callbacks = callbacks,
            .gctx = gctx,
            .pipeline = pipeline,
            .bind_group_def = bind_group_def,
            .depth_texture = depth_texture,
            .texture_sampler = texture_sampler,
            .models_hash = std.AutoHashMap(LoadedModelId, *Model).init(allocator),
            .active_scene = null,
        };
        Engine.is_instanced = true;
        return engine;
    }

    pub fn deinit(engine: *Engine) void {
        var iterator = engine.models_hash.iterator();
        while (iterator.next()) |entry| {
            const model_ptr = entry.value_ptr.*;
            model_ptr.deinit(engine.gctx);
            engine.allocator.destroy(model_ptr);
        }

        engine.models_hash.deinit();

        engine.bind_group_def.deinit();
        zstbi.deinit();
        engine.allocator.destroy(engine);
        Engine.is_instanced = false;
    }

    pub fn createScene(engine: *Engine) !*Scene {
        const scene = try Scene.init(engine, engine.allocator);

        if (engine.active_scene == null) {
            engine.active_scene = scene;
        }

        return scene;
    }

    pub fn update(engine: *Engine) void {
        if (engine.callbacks.onUpdate) |callback| {
            callback(engine);
        }
    }

    pub fn draw(engine: *Engine) GraphicsContextState {
        const gctx = engine.gctx;

        const fb_width = gctx.swapchain_descriptor.width;
        const fb_height = gctx.swapchain_descriptor.height;
        const t = @as(f32, @floatCast(gctx.stats.time));

        const cam_world_to_view = zmath.lookAtLh(
            zmath.f32x4(3.0, 3.0, -3.0, 1.0),
            zmath.f32x4(0.0, 0.0, 0.0, 1.0),
            zmath.f32x4(0.0, 1.0, 0.0, 0.0),
        );
        const cam_view_to_clip = zmath.perspectiveFovLh(
            0.25 * math.pi,
            @as(f32, @floatFromInt(fb_width)) / @as(f32, @floatFromInt(fb_height)),
            0.01,
            200.0,
        );
        const cam_world_to_clip = zmath.mul(cam_world_to_view, cam_view_to_clip);

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            pass: {
                const pipeline = gctx.lookupResource(engine.pipeline) orelse break :pass;

                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .clear,
                    .store_op = .store,
                }};
                const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                    .view = engine.depth_texture.view,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                    .depth_clear_value = 1.0,
                };
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachments = &color_attachments,
                    .color_attachment_count = color_attachments.len,
                    .depth_stencil_attachment = &depth_attachment,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                pass.setPipeline(pipeline);

                if (engine.active_scene) |scene| {
                    for (scene.game_objects.items) |game_object| {
                        const model = game_object.model;
                        const model_descriptor = model.model_descriptor;

                        model_descriptor.position.applyVertexBuffer(pass, 0);
                        model_descriptor.normal.applyVertexBuffer(pass, 1);
                        model_descriptor.texcoord.applyVertexBuffer(pass, 2);
                        model_descriptor.index.applyIndexBuffer(pass);

                        const object_to_world = zmath.mul(
                            zmath.rotationY(t),
                            zmath.translation(
                                game_object.position[0],
                                game_object.position[1],
                                game_object.position[2],
                            ),
                        );

                        const object_to_clip = zmath.mul(object_to_world, cam_world_to_clip);

                        const mem = gctx.uniformsAllocate(zmath.Mat, 1);
                        mem.slice[0] = zmath.transpose(object_to_clip);

                        pass.setBindGroup(0, model.bind_group_descriptor.bind_group, &.{mem.offset});
                        pass.drawIndexed(model_descriptor.index.elements_count * 3, 1, 0, 0, 0);
                    }
                }
            }

            if (engine.callbacks.onRender) |onRender| {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                }};
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachments = &color_attachments,
                    .color_attachment_count = color_attachments.len,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                onRender(engine, pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});

        const gctx_state = gctx.present();

        return gctx_state;
    }

    pub fn loadModel(engine: *Engine, model_name: []const u8) !LoadedModelId {
        const gctx = engine.gctx;

        const model_descriptor = try ModelDescriptor.init(gctx, engine.allocator, model_name);

        const bind_group_descriptor = try engine.bind_group_def.createBindGroup(
            engine.texture_sampler,
            model_descriptor.color_texture,
        );

        const model = try engine.allocator.create(Model);
        model.* = .{
            .model_descriptor = model_descriptor,
            .bind_group_descriptor = bind_group_descriptor,
        };

        const loaded_model_id: LoadedModelId = @enumFromInt(Engine.next_loaded_model_id);
        try engine.models_hash.put(loaded_model_id, model);
        Engine.next_loaded_model_id += 1;

        return loaded_model_id;
    }

    fn recreateDepthTexture(engine: *Engine) !void {
        // Release old depth texture.
        engine.depth_texture.deinit();
        // Create a new depth texture to match the new window size.
        engine.depth_texture = try DepthTexture.init(engine.gctx);
    }

    pub fn runLoop(engine: *Engine) !void {
        const window = engine.window_context.window;

        while (!window.shouldClose() and window.getKey(.escape) != .press) {
            zglfw.pollEvents();
            engine.update();
            const gctx_state = engine.draw();

            switch (gctx_state) {
                .normal_execution => {},
                .swap_chain_resized => {
                    try engine.recreateDepthTexture();
                },
            }
        }
    }
};
