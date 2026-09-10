shader_type spatial;
render_mode cull_back;

// One tintable channel per part, written per instance by DotAvatarBuilder so two
// players wearing the same part never recolour each other. Instance uniforms are
// the whole reason this is a shader and not a StandardMaterial3D: a material is a
// resource, and two players sharing one part would share it, so recolouring either
// would recolour both.
//
// Deliberately a second copy of game-g2gfast's rather than a shared file. Nothing is
// shared between games in this family that is not an addon, and a shader that lived
// in one game and was loaded by another would be a dependency neither declares.
instance uniform vec4 dot_avatar_tint_0 : source_color = vec4(0.75, 0.75, 0.78, 1.0);

void fragment() {
	ALBEDO = dot_avatar_tint_0.rgb;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
}
