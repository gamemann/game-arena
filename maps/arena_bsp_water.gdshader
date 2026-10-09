shader_type spatial;
// A copy of game-g2gfast's g2g_bsp_water.gdshader: keep the two in step.
// Water an imported map did not ship a texture for: translucent, moving, lit by the map.
//
// The source game's water materials live in its own archives, never in a map, so every
// pool, canal and river on these maps was drawn as the opaque prototype grid -- a floor a
// player could not see into and then sank through. A stand-in from the art bundle would be
// a picture of water lying on top of it; this is a sheet of the map's own colour that the
// player sees through, so what is under the surface (the pool's floor, a ramp's foot,
// somebody swimming) stays readable, which is the part that matters in a movement game.
//
// `cull_disabled` because a swimmer looks UP at the same faces (the "_beneath" materials
// are the underside the mapper built for exactly that), and the transparent pass because
// it is see-through: ALPHA is written. `unshaded`, lit by the baked lightmap like the
// other two, for the reason at the top of `arena_bsp_lightmapped.gdshader`.
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D lightmap_tex : source_color, filter_linear, repeat_disable;
uniform vec4 tint : source_color = vec4(0.12, 0.38, 0.45, 1.0);
uniform float ambient : hint_range(0.0, 1.0) = 0.10;
uniform float light_boost : hint_range(0.0, 4.0) = 1.35;
// Opacity looking straight down, and at a grazing angle (water reflects more of the sky
// the flatter it is seen, so it hides more).
uniform float alpha_down : hint_range(0.0, 1.0) = 0.55;
uniform float alpha_grazing : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Two slow crossing swells and a finer chop, in world metres so a pool's ripples are
	// the same size whatever its UVs: enough motion to read as water, never a pattern that
	// reads as a texture.
	float swell = sin(world.x * 0.9 + TIME * 0.8) * sin(world.z * 0.7 - TIME * 0.6);
	float chop = sin((world.x + world.z) * 3.1 + TIME * 2.3) * sin((world.x - world.z) * 2.7 - TIME * 1.9);
	float ripple = 1.0 + 0.10 * swell + 0.05 * chop;
	vec3 lm = texture(lightmap_tex, UV2).rgb;
	ALBEDO = tint.rgb * ripple * (lm * light_boost + ambient);
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALPHA = mix(alpha_grazing, alpha_down, facing);
}
