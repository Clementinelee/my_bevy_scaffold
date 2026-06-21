project_name=$1

cargo new $project_name
cd $project_name

cargo add bevy -F bevy/dynamic_linking

echo "" >> Cargo.toml
echo '[profile.dev.package."*"]
opt-level = 3

[profile.dev.package.wgpu-types]
debug-assertions = false

[profile.release]
opt-level = 3
lto = "thin"
codegen-units = 1
strip = "debuginfo"' >> Cargo.toml

curl https://raw.githubusercontent.com/bevyengine/bevy/main/examples/3d/3d_scene.rs > src/main.rs
