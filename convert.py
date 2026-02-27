import bpy
import sys

# clear all objects
bpy.ops.wm.read_factory_settings(use_empty=True)

# import GLB
glb_path = "Sources/MusicalWallpaper/Resources/Meshy_AI_shuttle_0227101350_texture.glb"
bpy.ops.import_scene.gltf(filepath=glb_path)

# export USDA
usdz_path = "Sources/MusicalWallpaper/Resources/Meshy_AI_shuttle_0227101350_texture.usdz"
bpy.ops.wm.usd_export(filepath=usdz_path, export_normals=True, export_materials=True)
