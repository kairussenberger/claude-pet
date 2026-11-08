// Lifts the foreground subject out of an image with Vision and writes a tightly cropped PNG.
// usage: swift cutout.swift <in.png> <out.png>
import AppKit
import Vision
import CoreImage

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: cutout <in> <out>"); exit(1)
}
let handler = VNImageRequestHandler(cgImage: cg)
let req = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([req])
guard let obs = req.results?.first else { print("no subject found"); exit(1) }
print("instances:", obs.allInstances.count)
let buf = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
let ci = CIImage(cvPixelBuffer: buf)
let ctx = CIContext()
guard let out = ctx.createCGImage(ci, from: ci.extent) else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote", out.width, "x", out.height)
