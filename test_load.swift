import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO

let url = URL(fileURLWithPath: "Meshy_AI_shuttle_0227101350_texture.glb")
do {
    let scene = try SCNScene(url: url, options: nil)
    let outUrl = URL(fileURLWithPath: "Meshy_AI_shuttle_0227101350_texture.usda")
    let success = scene.write(to: outUrl, options: nil, delegate: nil, progressHandler: nil)
    print("Success: \(success)")
} catch {
    print("Error loading scene: \(error)")
}
