shader_type spatial;
// The translucent twin of `arena_bsp_lightmapped.gdshader`: identical but for the ALPHA
// write at the end, which is the whole difference, because writing ALPHA at all is what
// puts a spatial shader in the transparent pass. Only a surface whose map material said
// `$translucent` or `$alphatest` (glass, a grate, a masked sign) gets this one; see the
// other file for why everything else must not.
render_mode unshaded, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D lightmap_tex : source_color, filter_linear, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float uv_scale = 1.0;
uniform float ambient : hint_range(0.0, 1.0) = 0.10;
uniform float light_boost : hint_range(0.0, 4.0) = 1.35;

void fragment() {
	vec4 base = texture(albedo_tex, UV * uv_scale) * tint;
	vec3 lm = texture(lightmap_tex, UV2).rgb;
	ALBEDO = base.rgb * (lm * light_boost + ambient);
	ALPHA = base.a;
}
