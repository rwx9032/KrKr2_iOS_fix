// XP3Compat CombinedSceneActivityControl -- DIAGNOSTIC ONLY, NOT SHIPPING.
//
// Control B: existing Scene+Engine pipeline without Bootstrap/Adaptive.
// Exactly:
//   CombinedSceneEngineProbe.m (production + DisplayProbe + EngineFrameProbe
//   + XP3SceneAdapter.m)
//   + EngineActivityProbe.m
//
// Do not include XP3SceneBootstrap or XP3AdaptiveGeometry in this control.

#include "CombinedSceneEngineProbe.m"
#include "EngineActivityProbe.m"
