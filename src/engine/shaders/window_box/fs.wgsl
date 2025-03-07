@group(0) @binding(1) var<uniform> camera_position: vec4<f32>;
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

const t3: f32 = 1.0 / 3.0;

fn isInBound(uv: vec2<f32>) -> bool {
    return uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1;
}

@fragment fn main(
    @location(0) local_xy: vec2<f32>,
) -> @location(0) vec4<f32> {
    let dx = camera_position.x - local_xy.x;
    let dy = camera_position.y;
    // local_xy.y is actually z axis in the space of window
    let dz = camera_position.z - local_xy.y;

    // Calculation of parameters needed for left and right walls
    let a_xy_hor = dy / dx;
    let b_xy_hor = -a_xy_hor * local_xy.x;

    let a_xy_ver = dy / dz;
    let b_xy_ver = -a_xy_ver * local_xy.y;

    let u_left = b_xy_hor;
    let p_left = vec2(u_left, (u_left - b_xy_ver) / a_xy_ver);

    // Calculation of parameters needed for ceiling and floor
    let a_zy_hor = dy / dz;
    let b_zy_hor = -a_zy_hor * local_xy.y;

    let a_zy_ver = dy / dx;
    let b_zy_ver = -a_zy_ver * local_xy.x;

    var p = vec2(0.5, 0.5);

    if (isInBound(p_left)) {
        p = vec2(p_left.x, 1 + p_left.y);
    } else {
        let u_right = a_xy_hor + b_xy_hor;
        let p_right = vec2(1 - u_right, (u_right - b_xy_ver) / a_xy_ver);
        if (isInBound(p_right)) {
            p = vec2(2 + p_right.x, 1 + p_right.y);
        } else {
            let u_bottom = b_zy_hor;
            let p_bottom = vec2((u_bottom - b_zy_ver) / a_zy_ver, u_bottom);
            if (isInBound(p_bottom)) {
                p = vec2(1 + p_bottom.x, p_bottom.y);
            } else {
                let u_top = a_zy_hor + b_zy_hor;
                let p_top = vec2((u_top - b_zy_ver) / a_zy_ver, 1 - u_top);
                if (isInBound(p_top)) {
                    p = vec2(1 + p_top.x, 2 + p_top.y);
                } else {
                    let p_far = vec2((1 - b_xy_hor) / a_xy_hor, (1 - b_zy_hor) / a_zy_hor);
                    p = vec2(1 + p_far.x, 1 + p_far.y);
                }
            }
        }
    }

    var color = textureSample(color_texture, texture_sampler, vec2(t3 * p.x, 1 - t3 * p.y));

    let p_middle = vec2((0.5 - b_xy_hor) / a_xy_hor, (0.5 - b_zy_hor) / a_zy_hor);
    let middle_color = textureSample(color_texture, texture_sampler, vec2(p_middle.x * t3, 1 - (2 + p_middle.y) * t3));
    if (isInBound(p_middle)) {
        color = mix(color, middle_color, middle_color.a);
    }

    let front_color = textureSample(color_texture, texture_sampler, vec2(t3 * local_xy.x, 1 - t3 * local_xy.y));
    return mix(color, front_color, front_color.a);
}
