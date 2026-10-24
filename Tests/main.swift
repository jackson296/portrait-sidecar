import Foundation
let devices = [(1668,2224),(2048,2732),(1488,2266),(1640,2360),(2064,2752),(1668,2388)]
for (w,h) in devices {
 let options = WorkspaceOptions.presets(nativeWidth:w,nativeHeight:h)
 precondition(options.count == 4)
 precondition(options[1].width == w/2 && options[1].height == h/2)
 for p in options {
  precondition(p.width > 0 && p.height > p.width)
  precondition(abs(Double(p.width)/Double(p.height) - Double(w)/Double(h)) < 0.002)
 }
 precondition(zip(options,options.dropFirst()).allSatisfy { $0.width < $1.width && $0.height < $1.height })
 precondition(options == WorkspaceOptions.presets(nativeWidth:h,nativeHeight:w))
}
precondition(WorkspaceOptions.presets(nativeWidth:0,nativeHeight:0).isEmpty)
print("Workspace presets passed: native Retina size, aspect ratio, ordering, and rotated inputs across six iPad resolutions.")
