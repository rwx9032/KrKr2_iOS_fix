// XP3Compat OfflineContinuation -- DIAGNOSTIC / TEST ONLY, NEVER SHIPPED.
//
// Single translation unit, same composition as the d89 diagnostic build
// (production core + DisplayProbe + EngineFrameProbe + Adaptive + Activity
// + Scene adapter), with two additions that are each behind their own
// Info.plist opt-in:
//
//   * XP3SceneContextAdapter.m      (read-only context probe + opt-in window handoff)
//   * XP3AdaptiveGeometryKeepDesign.m (opt-in "keep the app's design resolution")
//
// Include order matters: the production core installs first, the read-only
// Display/Engine probes define the XP3EF* guards used by the Adaptive and
// Activity files, and the scene delegate class must exist before UIKit reads
// UISceneDelegateClassName from the manifest.
//
// Nothing here is compiled into the shipping dylib. Production sources and the
// formal XP3Compat.dylib are only read, never modified.

#include "../../../Sources/XP3Compat.m"
#include "../../DisplayLab/DisplayProbe.m"
#include "../../DisplayLab/EngineFrameProbe.m"
#include "XP3AdaptiveGeometryKeepDesign.m"
#include "../../SceneLab/EngineActivityProbe.m"
#include "XP3SceneContextAdapter.m"
