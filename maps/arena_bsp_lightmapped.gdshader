shader_type spatial;
// An imported map's surface, lit by the lighting its own map compiler baked and by
// nothing else. Ported from game-g2gfast's `g2g_bsp_lightmapped.gdshader`, without the
// flashlight and the pixel-art stand-ins, which are that game's.
//
// `unshaded` on purpose: the lightmap IS the lighting, and running it through Godot's
// lambert term as well would light every surface twice and wash its colour out.
//
// Opaque, and that is why there are two shaders. Godot puts a spatial shader in the
// transparent pass when it WRITES `ALPHA`, whatever it writes, and in that pass depth is
// not written and surfaces are sorted per surface rather than per pixel: a map drawn that
// way draws through itself. g2gfast shipped every imported map like that until a person
// compared a frame with the original. `arena_bsp_translucent.gdshader` is this file plus
// the ALPHA write, for the few surfaces the map's own material calls translucent.
render_mode unshaded, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D lightmap_tex : source_color, filter_linear, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// The second texture of a blend surface, shown by vertex alpha (COLOR.a). Only a surface
// whose manifest carries `texture2` and an `alpha_offset` sets it.
uniform sampler2D albedo2_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_albedo2 = false;
// How much of the albedo texture one unit of UV is: 1.0 for a texture the map carried,
// one over the grid squares in a tile for a surface drawn in arena's grid (whose UVs the
// importer wrote in 64-unit squares).
uniform float uv_scale = 1.0;
// The baked light is tone-mapped into an 8-bit atlas, so its darks clamp to black;
// `ambient` lifts them to where a player can see the geometry.
uniform float ambient : hint_range(0.0, 1.0) = 0.10;
uniform float light_boost : hint_range(0.0, 4.0) = 1.35;

void fragment() {
	vec4 base = texture(albedo_tex, UV * uv_scale) * tint;
	if (has_albedo2) {
		base = mix(base, texture(albedo2_tex, UV * uv_scale) * tint, clamp(COLOR.a, 0.0, 1.0));
	}
	vec3 lm = texture(lightmap_tex, UV2).rgb;
	ALBEDO = base.rgb * (lm * light_boost + ambient);
}
